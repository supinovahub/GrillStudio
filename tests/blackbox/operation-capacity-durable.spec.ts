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

async function createAdmittedConversation() {
  const conversationId = await createConversation({ connection: true });
  await database`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${conversationId}::uuid,
      'admit_inbound',
      'inbound',
      'new_inbound',
      null,
      now(),
      ${`t07-test-admit:${conversationId}`},
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  return conversationId;
}

async function insertProviderMessage(
  conversationId: string,
  options?: {
    body?: string;
    kind?: "audio" | "document" | "image" | "text" | "video";
    occurredAtSql?: "now" | "past";
  },
) {
  const messageId = randomUUID();
  const occurredAt = options?.occurredAtSql === "past" ? "past" : "now";
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
      ${options?.kind ?? "text"},
      ${options?.body ?? "mensagem do lead"},
      'received',
      ${`provider-${messageId}`},
      case
        when ${occurredAt} = 'past' then now() - interval '31 seconds'
        else now()
      end,
      'provider'
    )
  `;
  return messageId;
}

async function responseBatchId(conversationId: string) {
  const rows = await database<Array<{ id: string }>>`
    select id
    from private.pedro_response_batches
    where conversation_id = ${conversationId}::uuid
      and status in (
        'collecting', 'delaying', 'ready', 'processing', 'completed'
      )
  `;
  return rows[0]!.id;
}

async function forceResponseBatchReady(batchId: string) {
  await database`
    update private.pedro_response_batches
    set
      status = 'ready',
      delay_seconds = 4,
      delay_due_at = greatest(grouping_due_at, now()),
      ready_at = now(),
      updated_at = now(),
      version = version + 1
    where id = ${batchId}::uuid
      and status = 'collecting'
  `;
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
  expect(delayed[0]!.delay_seconds).toBeGreaterThanOrEqual(4);
  expect(delayed[0]!.delay_seconds).toBeLessThanOrEqual(12);

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

test("inbound durante delay cria sucessor sem abortar a mensagem", async () => {
  const conversationId = await createAdmittedConversation();
  await insertProviderMessage(conversationId, {
    body: "primeira mensagem",
    occurredAtSql: "past",
  });
  const firstBatchId = await responseBatchId(conversationId);
  await database`
    update private.pedro_response_batches
    set
      status = 'delaying',
      delay_seconds = 12,
      delay_due_at = greatest(grouping_due_at, now()) + interval '1 minute',
      updated_at = now(),
      version = version + 1
    where id = ${firstBatchId}::uuid
  `;

  const secondMessageId = await insertProviderMessage(conversationId, {
    body: "mandei um pdf tb",
    kind: "document",
  });
  const state = await database<
    Array<{
      delay_class: string;
      messages: number;
      old_status: string;
      successor_id: string;
    }>
  >`
    select
      old.status as old_status,
      old.superseded_by_batch_id as successor_id,
      successor.delay_class,
      (
        select count(*)::integer
        from private.pedro_response_batch_messages as batch_message
        where batch_message.batch_id = successor.id
      ) as messages
    from private.pedro_response_batches as old
    join private.pedro_response_batches as successor
      on successor.id = old.superseded_by_batch_id
    where old.id = ${firstBatchId}::uuid
  `;
  const persisted = await database<Array<{ persisted: boolean }>>`
    select exists (
      select 1 from public.messages where id = ${secondMessageId}::uuid
    ) as persisted
  `;

  expect(persisted[0]!.persisted).toBe(true);
  expect(state[0]).toMatchObject({
    delay_class: "long",
    messages: 2,
    old_status: "cancelled",
  });
  expect(state[0]!.successor_id).toBeTruthy();
});

test("lease expirado é recuperado e completion stale nunca vence", async () => {
  const conversationId = await createAdmittedConversation();
  await insertProviderMessage(conversationId, { body: "quero saber mais" });
  const batchId = await responseBatchId(conversationId);
  await forceResponseBatchReady(batchId);
  await database`
    update private.pedro_response_batches
    set status = 'cancelled', cancelled_at = now(), updated_at = now()
    where operation_id = ${operationId}::uuid
      and id <> ${batchId}::uuid
      and status in ('ready', 'processing', 'completed')
  `;

  const workerOne = randomUUID();
  const firstClaim = await admin.rpc("service_claim_next_response_batch", {
    lease_seconds: 15,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_worker_id: workerOne,
  });
  expect(firstClaim.error).toBeNull();
  const first = firstClaim.data as {
    effect_key: string;
    input_hash: string;
    lease_token: string;
    status: string;
  };
  expect(first.status).toBe("processing");

  await database`
    update private.pedro_response_batches
    set processing_lease_until = now() - interval '1 second'
    where id = ${batchId}::uuid
  `;
  const workerTwo = randomUUID();
  const reclaimed = await database<
    Array<{
      result: {
        effect_key: string;
        input_hash: string;
        lease_token: string;
        status: string;
      };
    }>
  >`
    select private.claim_ready_response_batch(
      ${operationId}::uuid,
      ${batchId}::uuid,
      ${first.effect_key},
      ${workerTwo}::uuid,
      30,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  expect(reclaimed[0]!.result.status).toBe("reclaimed");

  await expect(
    database`
      select private.complete_response_batch(
        ${operationId}::uuid,
        ${batchId}::uuid,
        ${first.effect_key},
        ${workerOne}::uuid,
        ${first.lease_token}::uuid,
        ${first.input_hash},
        ${randomUUID()}::uuid,
        ${randomUUID()}::uuid
      )
    `,
  ).rejects.toMatchObject({ code: "40001" });

  const second = reclaimed[0]!.result;
  await database`
    select private.complete_response_batch(
      ${operationId}::uuid,
      ${batchId}::uuid,
      ${second.effect_key},
      ${workerTwo}::uuid,
      ${second.lease_token}::uuid,
      ${second.input_hash},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  await database`
    update private.pedro_response_batches
    set processing_lease_until = now() - interval '1 second'
    where id = ${batchId}::uuid
  `;

  const workerThree = randomUUID();
  const recoveredCompletion = await admin.rpc(
    "service_claim_next_response_batch",
    {
      lease_seconds: 30,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
      target_worker_id: workerThree,
    },
  );
  expect(recoveredCompletion.error).toBeNull();
  const completed = recoveredCompletion.data as {
    effect_key: string;
    lease_token: string;
    status: string;
  };
  expect(completed.status).toBe("completed");

  const consumed = await admin.rpc("service_consume_response_batch", {
    target_batch_id: batchId,
    target_effect_key: completed.effect_key,
    target_lease_token: completed.lease_token,
    target_operation_id: operationId,
    target_worker_id: workerThree,
  });
  expect(consumed.error).toBeNull();
  expect((consumed.data as { status: string }).status).toBe("consumed");

  const denied = await owner.rpc("service_claim_next_response_batch", {
    lease_seconds: 30,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_worker_id: randomUUID(),
  });
  expect(denied.error).not.toBeNull();
});

test("claim cancela batch após handoff, pausa ou opt-out", async () => {
  const cases = [
    { expectedReason: "human_owned", gate: "handoff" },
    { expectedReason: "conversation_paused", gate: "pause" },
    { expectedReason: "active_opt_out", gate: "optout" },
  ] as const;

  for (const scenario of cases) {
    const conversationId = await createAdmittedConversation();
    await insertProviderMessage(conversationId, {
      body: `mensagem antes de ${scenario.gate}`,
    });
    const batchId = await responseBatchId(conversationId);
    await forceResponseBatchReady(batchId);

    const versionRows = await database<Array<{ version: number }>>`
      select version
      from public.conversations
      where id = ${conversationId}::uuid
    `;
    if (scenario.gate === "handoff") {
      const assumed = await owner.rpc("assume_conversation", {
        expected_version: versionRows[0]!.version,
        request_correlation_id: randomUUID(),
        request_trace_id: randomUUID(),
        target_conversation_id: conversationId,
      });
      expect(assumed.error).toBeNull();
    } else if (scenario.gate === "pause") {
      const paused = await owner.rpc("pause_conversation", {
        expected_version: versionRows[0]!.version,
        pause_reason: "teste de fence do batch",
        request_correlation_id: randomUUID(),
        request_trace_id: randomUUID(),
        target_conversation_id: conversationId,
      });
      expect(paused.error).toBeNull();
      await database`
        update public.conversations
        set
          ownership_type = 'pedro',
          assigned_membership_id = null,
          updated_at = now(),
          version = version + 1
        where id = ${conversationId}::uuid
      `;
    } else {
      await database`
        insert into public.opt_outs (
          organization_id, contact_id, status, reason
        )
        select
          conversation.organization_id,
          conversation.contact_id,
          'active',
          'teste de fence do batch'
        from public.conversations as conversation
        where conversation.id = ${conversationId}::uuid
      `;
    }

    const claim = await database<
      Array<{ result: { reason: string; status: string } }>
    >`
      select private.claim_ready_response_batch(
        ${operationId}::uuid,
        ${batchId}::uuid,
        ${`ineligible:${scenario.gate}:${batchId}`},
        ${randomUUID()}::uuid,
        30,
        ${randomUUID()}::uuid,
        ${randomUUID()}::uuid
      ) as result
    `;
    expect(claim[0]!.result).toMatchObject({
      reason: scenario.expectedReason,
      status: "cancelled",
    });

    const batch = await database<Array<{ status: string }>>`
      select status
      from private.pedro_response_batches
      where id = ${batchId}::uuid
    `;
    expect(batch[0]!.status).toBe("cancelled");
  }
});

test("novo inbound e edit durante processing invalidam o snapshot", async () => {
  const conversationId = await createAdmittedConversation();
  const messageId = await insertProviderMessage(conversationId, {
    body: "texto original",
  });
  const batchId = await responseBatchId(conversationId);
  await forceResponseBatchReady(batchId);
  const workerId = randomUUID();
  const claimed = await database<
    Array<{
      result: {
        effect_key: string;
        input_hash: string;
        lease_token: string;
      };
    }>
  >`
    select private.claim_ready_response_batch(
      ${operationId}::uuid,
      ${batchId}::uuid,
      ${`snapshot:${batchId}`},
      ${workerId}::uuid,
      30,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  const snapshot = claimed[0]!.result;

  await database`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`processing-edit-${messageId}`},
      ${`provider-${messageId}`},
      'edit',
      'texto alterado durante geração',
      now(),
      ${"c".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  await expect(
    database`
      select private.complete_response_batch(
        ${operationId}::uuid,
        ${batchId}::uuid,
        ${snapshot.effect_key},
        ${workerId}::uuid,
        ${snapshot.lease_token}::uuid,
        ${snapshot.input_hash},
        ${randomUUID()}::uuid,
        ${randomUUID()}::uuid
      )
    `,
  ).rejects.toMatchObject({ code: "55000" });

  const afterEdit = await database<
    Array<{ old_status: string; successor_messages: number }>
  >`
    select
      old.status as old_status,
      (
        select count(*)::integer
        from private.pedro_response_batch_messages as batch_message
        where batch_message.batch_id = old.superseded_by_batch_id
      ) as successor_messages
    from private.pedro_response_batches as old
    where old.id = ${batchId}::uuid
  `;
  expect(afterEdit[0]).toEqual({
    old_status: "cancelled",
    successor_messages: 1,
  });

  const successorId = await responseBatchId(conversationId);
  await database`
    update private.pedro_response_batches
    set
      status = 'delaying',
      delay_seconds = 4,
      delay_due_at = greatest(grouping_due_at, now()) + interval '1 minute',
      updated_at = now(),
      version = version + 1
    where id = ${successorId}::uuid
  `;
  const inboundId = await insertProviderMessage(conversationId, {
    body: "mais uma coisa",
  });
  const persisted = await database<Array<{ persisted: boolean }>>`
    select exists (
      select 1 from public.messages where id = ${inboundId}::uuid
    ) as persisted
  `;
  expect(persisted[0]!.persisted).toBe(true);
});

test("revisão usa relógio do provedor, é idempotente e reinicia grouping", async () => {
  const conversationId = await createAdmittedConversation();
  const messageId = await insertProviderMessage(conversationId, {
    body: "texto inicial",
  });
  const batchId = await responseBatchId(conversationId);
  await database`
    update private.pedro_response_batches
    set grouping_due_at = now() + interval '2 seconds'
    where id = ${batchId}::uuid
  `;
  const before = await database<Array<{ grouping_due_at: string }>>`
    select grouping_due_at
    from private.pedro_response_batches
    where id = ${batchId}::uuid
  `;
  await database`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`first-edit-${messageId}`},
      ${`provider-${messageId}`},
      'edit',
      'texto mais novo',
      now(),
      ${"d".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const after = await database<Array<{ grouping_due_at: string }>>`
    select grouping_due_at
    from private.pedro_response_batches
    where id = ${batchId}::uuid
  `;
  expect(Date.parse(after[0]!.grouping_due_at)).toBeGreaterThan(
    Date.parse(before[0]!.grouping_due_at),
  );

  await database`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`new-delete-${messageId}`},
      ${`provider-${messageId}`},
      'delete',
      null,
      now() + interval '2 seconds',
      ${"e".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const stale = await database<
    Array<{ result: { stale_reason: string; status: string } }>
  >`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`late-edit-${messageId}`},
      ${`provider-${messageId}`},
      'edit',
      'não pode ressuscitar',
      now() + interval '1 second',
      ${"f".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  expect(stale[0]!.result).toMatchObject({
    stale_reason: "older_provider_time",
    status: "stale",
  });

  const duplicateEvent = `duplicate-delete-${messageId}`;
  const duplicateOccurredAt = new Date(Date.now() + 60_000).toISOString();
  const duplicateResults = await Promise.all(
    [randomUUID(), randomUUID()].map((traceId) =>
      database<Array<{ result: { status: string } }>>`
        select private.apply_provider_message_revision(
          ${organizationId}::uuid,
          ${operationId}::uuid,
          ${connectionId}::uuid,
          ${duplicateEvent},
          ${`provider-${messageId}`},
          'delete',
          null,
          ${duplicateOccurredAt}::timestamptz,
          ${"1".repeat(64)},
          ${traceId}::uuid,
          ${randomUUID()}::uuid
        ) as result
      `,
    ),
  );
  expect(
    duplicateResults.map((rows) => rows[0]!.result.status).sort(),
  ).toEqual(["applied", "duplicate"]);

  const final = await database<
    Array<{
      active_body: string | null;
      deleted: boolean;
      ignored: number;
      watermark_kind: string;
    }>
  >`
    select
      private.message_active_body(message.id) as active_body,
      message.deleted_at is not null as deleted,
      message.provider_revision_kind as watermark_kind,
      (
        select count(*)::integer
        from private.provider_message_revisions as revision
        where revision.target_message_id = message.id
          and not revision.is_applied
      ) as ignored
    from public.messages as message
    where message.id = ${messageId}::uuid
  `;
  expect(final[0]).toEqual({
    active_body: null,
    deleted: true,
    ignored: 1,
    watermark_kind: "delete",
  });
});

test("revisões no mesmo instante convergem por chave com delete dominante", async () => {
  const conversationId = await createAdmittedConversation();
  const messageId = await insertProviderMessage(conversationId, {
    body: "valor inicial",
  });
  const providerOccurredAt = new Date(Date.now() + 60_000).toISOString();
  const highEditKey = `z-edit-${messageId}`;
  const lowEditKey = `a-edit-${messageId}`;

  await database`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${highEditKey},
      ${`provider-${messageId}`},
      'edit',
      'edição de maior chave',
      ${providerOccurredAt}::timestamptz,
      ${"2".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const lowerEdit = await database<
    Array<{ result: { stale_reason: string; status: string } }>
  >`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${lowEditKey},
      ${`provider-${messageId}`},
      'edit',
      'edição de menor chave',
      ${providerOccurredAt}::timestamptz,
      ${"3".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  expect(lowerEdit[0]!.result).toMatchObject({
    stale_reason: "same_provider_time_lower_event_key",
    status: "stale",
  });

  const deleteResult = await database<
    Array<{ result: { status: string } }>
  >`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`a-delete-${messageId}`},
      ${`provider-${messageId}`},
      'delete',
      null,
      ${providerOccurredAt}::timestamptz,
      ${"4".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  expect(deleteResult[0]!.result.status).toBe("applied");

  const editAfterDelete = await database<
    Array<{ result: { stale_reason: string; status: string } }>
  >`
    select private.apply_provider_message_revision(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${connectionId}::uuid,
      ${`zz-edit-after-delete-${messageId}`},
      ${`provider-${messageId}`},
      'edit',
      'não pode vencer delete no mesmo instante',
      ${providerOccurredAt}::timestamptz,
      ${"5".repeat(64)},
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  expect(editAfterDelete[0]!.result).toMatchObject({
    stale_reason: "delete_dominates_same_provider_time",
    status: "stale",
  });

  const converged = await database<
    Array<{
      active_body: string | null;
      deleted: boolean;
      watermark_event: string;
      watermark_kind: string;
    }>
  >`
    select
      private.message_active_body(message.id) as active_body,
      message.deleted_at is not null as deleted,
      message.provider_revision_event_id as watermark_event,
      message.provider_revision_kind as watermark_kind
    from public.messages as message
    where message.id = ${messageId}::uuid
  `;
  expect(converged[0]).toEqual({
    active_body: null,
    deleted: true,
    watermark_event: `a-delete-${messageId}`,
    watermark_kind: "delete",
  });
});

test("backlog diferido usa clock atual, aplica backoff e comando failed rearma", async () => {
  const conversationId = await createConversation({ connection: true });
  await database`
    update public.operation_settings
    set proactive_open_minute = 0, proactive_close_minute = 1440
    where operation_id = ${operationId}::uuid
  `;
  const backlog = await database<Array<{ id: string }>>`
    select (private.capacity_enqueue_waiting(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${conversationId}::uuid,
      null,
      'campaign',
      now(),
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )).id
  `;
  const pause = await owner.rpc("set_operation_proactive_pause", {
    paused: true,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_reason: "teste de backoff",
  });
  expect(pause.error).toBeNull();

  const commandKey = `t07-test-drain:${backlog[0]!.id}`;
  await database`
    select private.enqueue_capacity_command(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      null,
      ${conversationId}::uuid,
      ${backlog[0]!.id}::uuid,
      'drain_backlog',
      jsonb_build_object(
        'backlog_id', ${backlog[0]!.id}::uuid,
        'conversation_id', ${conversationId}::uuid,
        'backlog_kind', 'campaign',
        'observed_at', '2026-07-31T00:00:00Z'::timestamptz
      ),
      ${commandKey},
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const deferred = await database<
    Array<{ result: { status: string }; run_at: string }>
  >`
    with processed as (
      select private.process_capacity_command(command.id) as result
      from private.operation_capacity_commands as command
      where command.effect_key = ${commandKey}
    )
    select processed.result, command.run_at
    from processed
    join private.operation_capacity_commands as command
      on command.effect_key = ${commandKey}
  `;
  expect(deferred[0]!.result.status).toBe("deferred");
  expect(Date.parse(deferred[0]!.run_at)).toBeGreaterThan(Date.now());

  const unpause = await owner.rpc("set_operation_proactive_pause", {
    paused: false,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_reason: null,
  });
  expect(unpause.error).toBeNull();
  await database`
    update private.operation_capacity_backlog
    set eligible_at = now()
    where id = ${backlog[0]!.id}::uuid
  `;
  await database`
    update private.operation_capacity_commands
    set run_at = now()
    where effect_key = ${commandKey}
  `;
  const admitted = await database<Array<{ result: { outcome: string } }>>`
    select private.process_capacity_command(command.id) as result
    from private.operation_capacity_commands as command
    where command.effect_key = ${commandKey}
  `;
  expect(admitted[0]!.result.outcome).toBe("admitted");

  const rearmKey = `t07-test-rearm:${randomUUID()}`;
  const stablePayload = { stable: true };
  await database`
    select private.enqueue_capacity_command(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      null,
      null,
      null,
      'maintenance',
      ${database.json(stablePayload)}::jsonb,
      ${rearmKey},
      now() + interval '1 day',
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  await database`
    update private.operation_capacity_commands
    set status = 'failed', attempts = 8, last_error_code = '40001'
    where effect_key = ${rearmKey}
  `;
  await database`
    select private.enqueue_capacity_command(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      null,
      null,
      null,
      'maintenance',
      ${database.json(stablePayload)}::jsonb,
      ${rearmKey},
      now() + interval '1 day',
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )
  `;
  const rearmed = await database<
    Array<{ attempts: number; last_error_code: string | null; status: string }>
  >`
    select status, attempts, last_error_code
    from private.operation_capacity_commands
    where effect_key = ${rearmKey}
  `;
  expect(rearmed[0]).toEqual({
    attempts: 0,
    last_error_code: null,
    status: "pending",
  });
  await database`
    update public.operation_settings
    set proactive_open_minute = 510, proactive_close_minute = 1230
    where operation_id = ${operationId}::uuid
  `;
});

test("alta demanda começa após dois minutos e termina após cooldown", async () => {
  const conversationId = await createConversation({ connection: true });
  const backlog = await database<Array<{ id: string }>>`
    select (private.capacity_enqueue_waiting(
      ${organizationId}::uuid,
      ${operationId}::uuid,
      ${conversationId}::uuid,
      null,
      'new_inbound',
      now() - interval '119 seconds',
      now() + interval '1 day',
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )).id
  `;
  const beforeThreshold = await database<
    Array<{ high_demand: boolean }>
  >`
    select (private.capacity_refresh_operation_state(
      ${operationId}::uuid,
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )).high_demand
  `;
  expect(beforeThreshold[0]!.high_demand).toBe(false);

  await database`
    update private.operation_capacity_backlog
    set arrived_at = now() - interval '121 seconds'
    where id = ${backlog[0]!.id}::uuid
  `;
  const delayed = await database<
    Array<{ automatic_proactive_paused: boolean; high_demand: boolean }>
  >`
    select
      refreshed.high_demand,
      refreshed.automatic_proactive_paused
    from private.capacity_refresh_operation_state(
      ${operationId}::uuid,
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as refreshed
  `;
  expect(delayed[0]).toEqual({
    automatic_proactive_paused: true,
    high_demand: true,
  });

  await database`
    update private.operation_capacity_backlog
    set arrived_at = now(), updated_at = now()
    where id = ${backlog[0]!.id}::uuid
  `;
  const cooling = await database<Array<{ high_demand: boolean }>>`
    select (private.capacity_refresh_operation_state(
      ${operationId}::uuid,
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )).high_demand
  `;
  expect(cooling[0]!.high_demand).toBe(true);

  await database`
    update private.operation_capacity_state
    set high_demand_recovery_since = now() - interval '301 seconds'
    where operation_id = ${operationId}::uuid
  `;
  const recovered = await database<Array<{ high_demand: boolean }>>`
    select (private.capacity_refresh_operation_state(
      ${operationId}::uuid,
      now(),
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    )).high_demand
  `;
  expect(recovered[0]!.high_demand).toBe(false);
  const freshStillWaiting = await database<Array<{ waiting: boolean }>>`
    select exists (
      select 1
      from private.operation_capacity_backlog
      where id = ${backlog[0]!.id}::uuid
        and status = 'waiting'
    ) as waiting
  `;
  expect(freshStillWaiting[0]!.waiting).toBe(true);
});

test("consumer durable usa SKIP LOCKED e limita uma Operação por rodada", async () => {
  const contract = await database<
    Array<{
      declared_snapshot: boolean;
      fair_by_operation: boolean;
      skip_locked: boolean;
    }>
  >`
    select
      position(
        'for update of state skip locked'
        in lower(pg_get_functiondef(
          'private.consume_capacity_commands(integer)'::regprocedure
        ))
      ) > 0 as skip_locked,
      position(
        'claimed_operation_ids'
        in pg_get_functiondef(
          'private.consume_capacity_commands(integer)'::regprocedure
        )
      ) > 0 as fair_by_operation,
      position(
        'snapshot_record private.operation_capacity_commands%rowtype'
        in pg_get_functiondef(
          'private.process_capacity_command(uuid)'::regprocedure
        )
      ) > 0 as declared_snapshot
  `;
  expect(contract[0]).toEqual({
    declared_snapshot: true,
    fair_by_operation: true,
    skip_locked: true,
  });
});

test("loop de maintenance compacta histórico com limite explícito", async () => {
  const compacted = await database.begin(async (sql) => {
    const compactOperationId = randomUUID();
    await sql`
      insert into public.operations (
        id, organization_id, name, is_default
      )
      values (
        ${compactOperationId}::uuid,
        ${organizationId}::uuid,
        'T07 Maintenance Compaction',
        false
      )
    `;

    for (const index of [1, 2, 3]) {
      await sql`
        select private.schedule_t07_job(
          ${organizationId}::uuid,
          ${compactOperationId}::uuid,
          't07.capacity_maintenance',
          'operation_capacity',
          ${compactOperationId}::uuid,
          now() + interval '1 day',
          ${`t07:test-maintenance:${compactOperationId}:${index}`},
          jsonb_build_object('operation_id', ${compactOperationId}::uuid),
          ${randomUUID()}::uuid,
          ${randomUUID()}::uuid
        )
      `;
    }

    await sql`
      insert into private.effect_ledger (
        organization_id,
        operation_id,
        effect_key,
        effect_type,
        request_hash,
        state,
        trace_id,
        correlation_id,
        recorded_at
      )
      select
        job.organization_id,
        job.operation_id,
        job.effect_key,
        't07.capacity_maintenance',
        repeat('a', 64),
        'effect_recorded',
        gen_random_uuid(),
        gen_random_uuid(),
        now()
      from public.scheduled_jobs as job
      where job.operation_id = ${compactOperationId}::uuid
        and job.job_type = 't07.capacity_maintenance'
    `;
    await sql`
      update public.scheduled_jobs
      set status = 'completed', completed_at = now(), updated_at = now()
      where operation_id = ${compactOperationId}::uuid
        and job_type = 't07.capacity_maintenance'
    `;

    const result = await sql<
      Array<{
        result: { deleted_effects: number; deleted_jobs: number };
      }>
    >`
      select private.compact_t07_capacity_maintenance_history(
        ${compactOperationId}::uuid,
        2,
        10
      ) as result
    `;
    const remaining = await sql<
      Array<{ effects: number; jobs: number }>
    >`
      select
        (
          select count(*)::integer
          from public.scheduled_jobs
          where operation_id = ${compactOperationId}::uuid
            and job_type = 't07.capacity_maintenance'
        ) as jobs,
        (
          select count(*)::integer
          from private.effect_ledger
          where operation_id = ${compactOperationId}::uuid
            and effect_type = 't07.capacity_maintenance'
        ) as effects
    `;

    await sql`
      delete from public.operations
      where id = ${compactOperationId}::uuid
    `;
    return { remaining: remaining[0]!, result: result[0]!.result };
  });

  expect(compacted).toEqual({
    remaining: { effects: 2, jobs: 2 },
    result: { deleted_effects: 2, deleted_jobs: 2 },
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
