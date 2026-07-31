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

test("mantém prioridades e atrasos como política fixa do MVP", async () => {
  const policy = await database<
    Array<{
      demand_delay: number;
      long_delay: number;
      ordered_priorities: number[];
      short_delay: number;
    }>
  >`
    select
      array[
        private.capacity_priority_for_kind('urgent_call'),
        private.capacity_priority_for_kind('opt_out'),
        private.capacity_priority_for_kind('sleeping_return'),
        private.capacity_priority_for_kind('active_reply'),
        private.capacity_priority_for_kind('new_inbound'),
        private.capacity_priority_for_kind('followup'),
        private.capacity_priority_for_kind('campaign')
      ]::integer[] as ordered_priorities,
      private.capacity_delay_seconds('short', false) as short_delay,
      private.capacity_delay_seconds('long', false) as long_delay,
      private.capacity_delay_seconds('long', true) as demand_delay
  `;

  expect(policy[0]).toEqual({
    demand_delay: 3,
    long_delay: 42,
    ordered_priorities: [1, 2, 3, 4, 5, 6, 7],
    short_delay: 8,
  });
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
