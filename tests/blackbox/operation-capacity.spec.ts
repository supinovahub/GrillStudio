import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

let database: Sql;
let organizationId = "";
let operationId = "";

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for Preview black-box`);
  return value;
}

test.describe.configure({ mode: "serial" });

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

  database = postgres(requiredEnvironment("DATABASE_URL"), {
    max: 2,
    prepare: false,
  });
  organizationId = randomUUID();
  operationId = randomUUID();

  await database`
    insert into public.organizations (id, name, slug)
    values (
      ${organizationId}::uuid,
      'T07 Synthetic',
      ${`t07-${organizationId.slice(0, 8)}`}
    )
  `;
  await database`
    insert into public.operations (
      id,
      organization_id,
      name,
      is_default
    )
    values (
      ${operationId}::uuid,
      ${organizationId}::uuid,
      'T07 Synthetic',
      true
    )
  `;
  await database`
    insert into public.operation_settings (
      operation_id,
      organization_id
    )
    values (
      ${operationId}::uuid,
      ${organizationId}::uuid
    )
  `;
});

test.afterAll(async () => {
  if (database) {
    await database`
      delete from public.operations
      where id = ${operationId}::uuid
    `;
    await database`
      delete from public.organizations
      where id = ${organizationId}::uuid
    `;
    await database.end();
  }
});

test("aplica janelas semiabertas no fuso da Operação", async () => {
  const boundaries = await database<
    Array<{
      inbound_at_five: boolean;
      inbound_at_midnight: boolean;
      inbound_at_235959: boolean;
      next_inbound_open: Date;
      proactive_at_202959: boolean;
      proactive_at_2030: boolean;
    }>
  >`
    select
      private.is_operation_inbound_open(
        ${operationId}::uuid,
        '2026-07-31T08:00:00Z'::timestamptz
      ) as inbound_at_five,
      private.is_operation_inbound_open(
        ${operationId}::uuid,
        '2026-08-01T02:59:59Z'::timestamptz
      ) as inbound_at_235959,
      private.is_operation_inbound_open(
        ${operationId}::uuid,
        '2026-08-01T03:00:00Z'::timestamptz
      ) as inbound_at_midnight,
      private.is_operation_proactive_open(
        ${operationId}::uuid,
        '2026-07-31T23:29:59Z'::timestamptz
      ) as proactive_at_202959,
      private.is_operation_proactive_open(
        ${operationId}::uuid,
        '2026-07-31T23:30:00Z'::timestamptz
      ) as proactive_at_2030,
      private.next_operation_window_open(
        ${operationId}::uuid,
        '2026-08-01T03:00:00Z'::timestamptz,
        'inbound'
      ) as next_inbound_open
  `;

  expect(boundaries[0]).toEqual({
    inbound_at_five: true,
    inbound_at_midnight: false,
    inbound_at_235959: true,
    next_inbound_open: new Date("2026-08-01T08:00:00.000Z"),
    proactive_at_202959: true,
    proactive_at_2030: false,
  });
});

test("usa o fuso canônico da Operação e falha fechado nos limites", async () => {
  await database`
    update public.operations
    set timezone = 'America/Manaus'
    where id = ${operationId}::uuid
  `;

  const boundaries = await database<
    Array<{
      inbound_at_five: boolean;
      inbound_at_midnight: boolean;
      next_inbound_open: Date;
      null_inbound_open: boolean;
      null_next_open: Date | null;
    }>
  >`
    select
      private.is_operation_inbound_open(
        ${operationId}::uuid,
        '2026-07-31T09:00:00Z'::timestamptz
      ) as inbound_at_five,
      private.is_operation_inbound_open(
        ${operationId}::uuid,
        '2026-08-01T04:00:00Z'::timestamptz
      ) as inbound_at_midnight,
      private.next_operation_window_open(
        ${operationId}::uuid,
        '2026-08-01T04:00:00Z'::timestamptz,
        'inbound'
      ) as next_inbound_open,
      private.is_operation_inbound_open(
        ${operationId}::uuid,
        null
      ) as null_inbound_open,
      private.next_operation_window_open(
        ${operationId}::uuid,
        null,
        'inbound'
      ) as null_next_open
  `;

  expect(boundaries[0]).toEqual({
    inbound_at_five: true,
    inbound_at_midnight: false,
    next_inbound_open: new Date("2026-08-01T09:00:00.000Z"),
    null_inbound_open: false,
    null_next_open: null,
  });

  await expect(
    database`
      update public.operation_settings
      set inbound_close_minute = inbound_open_minute
      where operation_id = ${operationId}::uuid
    `,
  ).rejects.toMatchObject({ code: "23514" });
  await expect(
    database`
      update public.operations
      set timezone = 'Mars/Olympus_Mons'
      where id = ${operationId}::uuid
    `,
  ).rejects.toMatchObject({ code: "22023" });

  await database`
    update public.operations
    set timezone = 'America/Sao_Paulo'
    where id = ${operationId}::uuid
  `;
});

test("não enfileira opt-out nem inventa ranking para pending return", async () => {
  const policy = await database<
    Array<{
      demand_delay: number;
      long_delay: number;
      opt_out_priority: number | null;
      ordered_priorities: Array<number | null>;
      pending_return_priority: number | null;
      short_delay: number;
    }>
  >`
    select
      array[
        private.capacity_priority_for_kind('urgent_call'),
        private.capacity_priority_for_kind('sleeping_return'),
        private.capacity_priority_for_kind('active_reply'),
        private.capacity_priority_for_kind('new_inbound'),
        private.capacity_priority_for_kind('followup'),
        private.capacity_priority_for_kind('campaign')
      ]::integer[] as ordered_priorities,
      private.capacity_priority_for_kind('opt_out') as opt_out_priority,
      private.capacity_priority_for_kind(
        'pending_return'
      ) as pending_return_priority,
      private.capacity_delay_seconds('short', false) as short_delay,
      private.capacity_delay_seconds('long', false) as long_delay,
      private.capacity_delay_seconds('long', true) as demand_delay
  `;

  expect(policy[0]).toEqual({
    demand_delay: 3,
    long_delay: 42,
    opt_out_priority: null,
    ordered_priorities: [1, 3, 4, 5, 6, 7],
    pending_return_priority: null,
    short_delay: 8,
  });
});

test("fixa FIFO monotônico e referências tenant-aware no catálogo", async () => {
  const contract = await database<
    Array<{
      batch_fk: string;
      fifo_key: string;
      message_fk: string;
      revision_fk: string;
      source_fk: string;
    }>
  >`
    select
      pg_get_constraintdef(fifo.oid) as fifo_key,
      pg_get_constraintdef(source.oid) as source_fk,
      pg_get_constraintdef(batch.oid) as batch_fk,
      pg_get_constraintdef(message.oid) as message_fk,
      pg_get_constraintdef(revision.oid) as revision_fk
    from pg_constraint as fifo
    cross join pg_constraint as source
    cross join pg_constraint as batch
    cross join pg_constraint as message
    cross join pg_constraint as revision
    where fifo.conname =
        'operation_capacity_backlog_operation_fifo_key'
      and source.conname =
        'operation_capacity_backlog_source_message_tenant_fkey'
      and batch.conname =
        'pedro_response_batch_messages_batch_tenant_fkey'
      and message.conname =
        'pedro_response_batch_messages_message_tenant_fkey'
      and revision.conname =
        'provider_message_revisions_target_message_tenant_fkey'
  `;

  expect(contract).toHaveLength(1);
  expect(contract[0].source_fk).toContain(
    "organization_id, operation_id, conversation_id, source_message_id",
  );
  expect(contract[0].batch_fk).toContain(
    "organization_id, operation_id, conversation_id, batch_id",
  );
  expect(contract[0].message_fk).toContain(
    "organization_id, operation_id, conversation_id, message_id",
  );
  expect(contract[0].revision_fk).toContain(
    "organization_id, operation_id, connection_id, target_message_id, target_provider_message_id",
  );
  expect(contract[0].fifo_key).toContain(
    "UNIQUE (operation_id, fifo_sequence)",
  );
});

test("inicializa estado sem expor tabelas privadas", async () => {
  const boundary = await database<
    Array<{
      state_rows: number;
      service_backlog: boolean;
      service_batches: boolean;
      service_slots: boolean;
    }>
  >`
    select
      (
        select count(*)::integer
        from private.operation_capacity_state
        where operation_id = ${operationId}::uuid
      ) as state_rows,
      has_table_privilege(
        'service_role',
        'private.conversation_capacity_slots',
        'SELECT'
      ) as service_slots,
      has_table_privilege(
        'service_role',
        'private.operation_capacity_backlog',
        'SELECT'
      ) as service_backlog,
      has_table_privilege(
        'service_role',
        'private.pedro_response_batches',
        'SELECT'
      ) as service_batches
  `;

  expect(boundary[0]).toEqual({
    service_backlog: false,
    service_batches: false,
    service_slots: false,
    state_rows: 1,
  });

  let invalidTimezoneCode = "";
  try {
    await database`
      update public.operation_settings
      set timezone_name = 'Invalid/T07'
      where operation_id = ${operationId}::uuid
    `;
  } catch (error) {
    invalidTimezoneCode = (error as { code?: string }).code ?? "";
  }
  expect(invalidTimezoneCode).toBe("22023");
});
