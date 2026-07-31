import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

let admin: SupabaseClient;
let owner: SupabaseClient;
let database: Sql;
let organizationId = "";
let operationId = "";
let ownerMembershipId = "";
let connectionId = "";
let createdUserId = "";

const password = "T07-durable-preview-only!42";

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for Preview black-box`);
  return value;
}

async function createConversation(options?: {
  connection?: boolean;
  ownership?: "human" | "pedro";
}) {
  const contactId = randomUUID();
  const opportunityId = randomUUID();
  const conversationId = randomUUID();
  const ownership = options?.ownership ?? "pedro";

  await database`
    insert into public.contacts (id, organization_id, display_name)
    values (${contactId}::uuid, ${organizationId}::uuid, 'T07 Durable Lead')
  `;
  await database`
    insert into public.opportunities (
      id, organization_id, operation_id, contact_id, stage, source_type
    )
    values (
      ${opportunityId}::uuid,
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${contactId}::uuid,
      'new',
      't07_durable'
    )
  `;
  await database`
    insert into public.conversations (
      id,
      organization_id,
      operation_id,
      contact_id,
      opportunity_id,
      connection_id,
      provider_chat_id,
      status,
      ownership_type,
      assigned_membership_id,
      automation_mode,
      capacity_state
    )
    values (
      ${conversationId}::uuid,
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${contactId}::uuid,
      ${opportunityId}::uuid,
      ${options?.connection ? connectionId : null}::uuid,
      ${options?.connection ? `chat-${conversationId}` : null},
      'active',
      ${ownership},
      ${ownership === "human" ? ownerMembershipId : null}::uuid,
      'shadow',
      'excluded'
    )
  `;
  return conversationId;
}

test.describe.configure({ mode: "serial", timeout: 60_000 });

test.beforeAll(async () => {
  const environment = validatePreviewEnvironment({
    appEnvironment: process.env.APP_ENVIRONMENT,
    expectedGitBranch: process.env.APP_EXPECTED_GIT_BRANCH,
    expectedProjectRef: process.env.APP_EXPECTED_SUPABASE_PROJECT_REF,
    gitBranch: process.env.GIT_BRANCH,
    prNumber: process.env.GITHUB_PR_NUMBER,
    supabaseBranchName: process.env.SUPABASE_BRANCH_NAME,
    supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL,
  });
  expect(environment.tone).toBe("preview");

  admin = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  database = postgres(requiredEnvironment("DATABASE_URL"), {
    max: 5,
    prepare: false,
  });

  const email = `t07-durable-${randomUUID()}@example.test`;
  const created = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    password,
  });
  if (created.error) throw new Error(created.error.message);
  createdUserId = created.data.user.id;

  owner = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const signedIn = await owner.auth.signInWithPassword({ email, password });
  if (signedIn.error) throw new Error(signedIn.error.message);

  organizationId = randomUUID();
  operationId = randomUUID();
  ownerMembershipId = randomUUID();
  connectionId = randomUUID();

  await database`
    insert into public.organizations (id, name, slug)
    values (
      ${organizationId}::uuid,
      'T07 Durable Synthetic',
      ${`t07-durable-${organizationId.slice(0, 8)}`}
    )
  `;
  await database`
    insert into public.operations (
      id, organization_id, name, is_default
    )
    values (
      ${operationId}::uuid,
      ${organizationId}::uuid,
      'T07 Durable Synthetic',
      true
    )
  `;
  await database`
    insert into public.operation_settings (
      operation_id, organization_id
    )
    values (${operationId}::uuid, ${organizationId}::uuid)
  `;
  await database`
    insert into public.memberships (
      id, organization_id, user_id, role, status
    )
    values (
      ${ownerMembershipId}::uuid,
      ${organizationId}::uuid,
      ${createdUserId}::uuid,
      'owner',
      'active'
    )
  `;
  await database`
    insert into public.membership_operations (
      membership_id, organization_id, operation_id
    )
    values (
      ${ownerMembershipId}::uuid,
      ${organizationId}::uuid,
      ${operationId}::uuid
    )
  `;
  await database`
    insert into public.whatsapp_connections (
      id,
      organization_id,
      operation_id,
      adapter_type,
      provider_connection_id,
      display_name,
      is_test
    )
    values (
      ${connectionId}::uuid,
      ${organizationId}::uuid,
      ${operationId}::uuid,
      'simulator',
      't07-durable',
      'T07 Durable',
      true
    )
  `;
});

test.afterAll(async () => {
  if (database) {
    await database`
      delete from public.operations where id = ${operationId}::uuid
    `;
    await database`
      delete from public.organizations where id = ${organizationId}::uuid
    `;
    await database.end();
  }
  if (createdUserId) {
    await admin.auth.admin.deleteUser(createdUserId);
  }
});

test("separa execução agendada da mutação de capacidade", async () => {
  const contract = await database<
    Array<{
      capacity_cron: number;
      emitter_mutates_capacity: boolean;
      durable_worker_consumes_capacity: boolean;
      maintenance_jobs: number;
    }>
  >`
    select
      position(
        'consume_capacity_commands'
        in pg_get_functiondef(
          'private.run_durable_workers(integer)'::regprocedure
        )
      ) > 0 as durable_worker_consumes_capacity,
      position(
        'apply_operation_capacity_command'
        in pg_get_functiondef(
          'private.emit_capacity_command_from_job()'::regprocedure
        )
      ) > 0 as emitter_mutates_capacity,
      (
        select count(*)::integer
        from cron.job
        where jobname = 't07-capacity-command-consumer-1s'
      ) as capacity_cron,
      (
        select count(*)::integer
        from public.scheduled_jobs
        where operation_id = ${operationId}::uuid
          and job_type = 't07.capacity_maintenance'
          and status in ('pending', 'leased', 'published')
      ) as maintenance_jobs
  `;

  expect(contract[0]).toEqual({
    capacity_cron: 1,
    durable_worker_consumes_capacity: false,
    emitter_mutates_capacity: false,
    maintenance_jobs: 1,
  });
});

test("reanálise durável conclui pending return sem criar rank", async () => {
  const conversationId = await createConversation({ ownership: "human" });
  await database`
    update public.conversations
    set
      pending_return = true,
      pending_return_target_mode = 'shadow',
      pending_return_action = 'resume_service',
      pending_return_requested_at = now(),
      pending_return_requested_by_membership_id =
        ${ownerMembershipId}::uuid,
      pending_return_requested_version = version,
      updated_at = now()
    where id = ${conversationId}::uuid
  `;

  const commandId = randomUUID();
  await database`
    select private.enqueue_capacity_command(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      null,
      null,
      null,
      'maintenance',
      jsonb_build_object('test_command_id', ${commandId}::uuid),
      ${`t07-test-maintenance:${commandId}`},
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  await database`
    select private.process_capacity_command(command.id)
    from private.operation_capacity_commands as command
    where command.operation_id = ${operationId}::uuid
      and command.effect_key = ${`t07-test-maintenance:${commandId}`}
  `;
  await database`select private.consume_capacity_commands(25)`;

  const state = await database<
    Array<{
      backlog: number;
      ownership_type: string;
      pending_return: boolean;
      slots: number;
    }>
  >`
    select
      conversation.ownership_type,
      conversation.pending_return,
      (
        select count(*)::integer
        from private.conversation_capacity_slots as slot
        where slot.conversation_id = conversation.id
      ) as slots,
      (
        select count(*)::integer
        from private.operation_capacity_backlog as backlog
        where backlog.conversation_id = conversation.id
      ) as backlog
    from public.conversations as conversation
    where conversation.id = ${conversationId}::uuid
  `;

  expect(state[0]).toEqual({
    backlog: 0,
    ownership_type: "pedro",
    pending_return: false,
    slots: 1,
  });
});

test("batch persiste delay e revisão mantém original imutável", async () => {
  const conversationId = await createConversation({ connection: true });
  const messageId = randomUUID();
  await database`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${conversationId}::uuid,
      'admit_inbound',
      'inbound',
      'new_inbound',
      null,
      now(),
      ${`t07-test-batch-admit:${conversationId}`},
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  await database`
    insert into public.messages (
      id,
      organization_id,
      operation_id,
      conversation_id,
      connection_id,
      direction,
      kind,
      body,
      status,
      provider_message_id,
      provider_occurred_at,
      created_by_type
    )
    values (
      ${messageId}::uuid,
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${conversationId}::uuid,
      ${connectionId}::uuid,
      'inbound',
      'text',
      'original',
      'received',
      ${`provider-${messageId}`},
      now() - interval '31 seconds',
      'provider'
    )
  `;

  const batches = await database<Array<{ id: string }>>`
    select id
    from private.pedro_response_batches
    where conversation_id = ${conversationId}::uuid
  `;
  const batchId = batches[0]!.id;
  const maintenanceKey = `t07-test-batch-maintenance:${batchId}`;
  await database`
    select private.enqueue_capacity_command(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      null,
      null,
      null,
      'maintenance',
      jsonb_build_object('batch_id', ${batchId}::uuid),
      ${maintenanceKey},
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  await database`
    select private.process_capacity_command(command.id)
    from private.operation_capacity_commands as command
    where command.operation_id = ${operationId}::uuid
      and command.effect_key = ${maintenanceKey}
  `;
  await database`select private.consume_capacity_commands(25)`;

  const delayed = await database<
    Array<{ delay_seconds: number; status: string }>
  >`
    select status, delay_seconds
    from private.pedro_response_batches
    where id = ${batchId}::uuid
  `;
  expect(delayed[0]!.status).toBe("delaying");
  expect(delayed[0]!.delay_seconds).toBeGreaterThanOrEqual(12);
  expect(delayed[0]!.delay_seconds).toBeLessThanOrEqual(35);

  await database`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`edit-${messageId}`},
      ${`provider-${messageId}`},
      'edit',
      'editada',
      now(),
      ${"a".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const edited = await database<
    Array<{ active_body: string; body: string; revision: number }>
  >`
    select
      body,
      revision,
      private.message_active_body(id) as active_body
    from public.messages
    where id = ${messageId}::uuid
  `;
  expect(edited[0]).toEqual({
    active_body: "editada",
    body: "original",
    revision: 2,
  });

  await database`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`delete-${messageId}`},
      ${`provider-${messageId}`},
      'delete',
      null,
      now(),
      ${"b".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const deleted = await database<
    Array<{
      active_body: string | null;
      body: string;
      included: boolean;
      revision: number;
    }>
  >`
    select
      message.body,
      message.revision,
      private.message_active_body(message.id) as active_body,
      batch_message.included
    from public.messages as message
    join private.pedro_response_batch_messages as batch_message
      on batch_message.message_id = message.id
    where message.id = ${messageId}::uuid
  `;
  expect(deleted[0]).toEqual({
    active_body: null,
    body: "original",
    included: false,
    revision: 3,
  });
});

test("owner pausa e retoma apenas o gate manual", async () => {
  const paused = await owner.rpc("set_operation_proactive_pause", {
    paused: true,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_reason: "teste black-box",
  });
  expect(paused.error).toBeNull();

  const whilePaused = await owner.rpc("get_operation_capacity_status", {
    target_operation_id: operationId,
  });
  expect(whilePaused.error).toBeNull();
  expect(
    (whilePaused.data as { manual_proactive_paused: boolean })
      .manual_proactive_paused,
  ).toBe(true);

  const resumed = await owner.rpc("set_operation_proactive_pause", {
    paused: false,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_reason: null,
  });
  expect(resumed.error).toBeNull();

  const after = await owner.rpc("get_operation_capacity_status", {
    target_operation_id: operationId,
  });
  expect(after.error).toBeNull();
  expect(
    (after.data as {
      automatic_proactive_paused: boolean;
      manual_proactive_paused: boolean;
    }).manual_proactive_paused,
  ).toBe(false);
});
