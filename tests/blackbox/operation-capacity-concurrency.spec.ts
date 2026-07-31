import { expect, test } from "@playwright/test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

let database: Sql;
let organizationId = "";
let operationId = "";
let conversationIds: string[] = [];

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for Preview black-box`);
  return value;
}

test.describe.configure({ mode: "serial", timeout: 90_000 });

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
    max: 100,
    prepare: false,
  });
  organizationId = randomUUID();
  operationId = randomUUID();

  await database`
    insert into public.organizations (id, name, slug)
    values (
      ${organizationId}::uuid,
      'T07 Concurrent Synthetic',
      ${`t07-concurrent-${organizationId.slice(0, 8)}`}
    )
  `;
  await database`
    insert into public.operations (
      id, organization_id, name, is_default
    )
    values (
      ${operationId}::uuid,
      ${organizationId}::uuid,
      'T07 Concurrent Synthetic',
      true
    )
  `;
  await database`
    insert into public.operation_settings (
      operation_id, organization_id
    )
    values (${operationId}::uuid, ${organizationId}::uuid)
  `;

  const conversations = await database<Array<{ id: string }>>`
    with generated as (
      select generate_series(1, 100) as item
    ),
    contacts as (
      insert into public.contacts (organization_id, display_name)
      select
        ${organizationId}::uuid,
        'Concurrent Lead ' || item
      from generated
      returning id
    ),
    opportunities as (
      insert into public.opportunities (
        organization_id,
        operation_id,
        contact_id,
        stage,
        source_type
      )
      select
        ${organizationId}::uuid,
        ${operationId}::uuid,
        contact.id,
        'new',
        't07_concurrency'
      from contacts as contact
      returning id, contact_id
    )
    insert into public.conversations (
      organization_id,
      operation_id,
      contact_id,
      opportunity_id,
      status,
      ownership_type,
      automation_mode,
      capacity_state
    )
    select
      ${organizationId}::uuid,
      ${operationId}::uuid,
      opportunity.contact_id,
      opportunity.id,
      'active',
      'pedro',
      'shadow',
      'excluded'
    from opportunities as opportunity
    returning id
  `;
  conversationIds = conversations.map((conversation) => conversation.id);
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

test("cem admissões concorrentes preservam teto, FIFO e zero deadlock", async () => {
  const before = await database<Array<{ deadlocks: number }>>`
    select deadlocks::integer
    from pg_stat_database
    where datname = current_database()
  `;
  const startedAt = performance.now();

  await Promise.all(
    conversationIds.map((conversationId, index) =>
      database`
        select private.apply_operation_capacity_command(
          ${operationId}::uuid,
          ${conversationId}::uuid,
          'admit_inbound',
          'inbound',
          'new_inbound',
          null,
          '2026-07-31T12:00:00Z'::timestamptz,
          ${`concurrent-admission:${index}`},
          null,
          null,
          ${randomUUID()}::uuid,
          ${randomUUID()}::uuid
        )
      `,
    ),
  );
  const elapsedMs = performance.now() - startedAt;

  const aggregate = await database<
    Array<{
      active_conversations: number;
      automatic_pause_reason: string;
      automatic_proactive_paused: boolean;
      backlog: number;
      fifo_max: number;
      fifo_min: number;
      slots: number;
      waiting_conversations: number;
    }>
  >`
    select
      (
        select count(*)::integer
        from private.conversation_capacity_slots
        where operation_id = ${operationId}::uuid
      ) as slots,
      (
        select count(*)::integer
        from private.operation_capacity_backlog
        where operation_id = ${operationId}::uuid
          and status = 'waiting'
      ) as backlog,
      (
        select min(fifo_sequence)::integer
        from private.operation_capacity_backlog
        where operation_id = ${operationId}::uuid
          and status = 'waiting'
      ) as fifo_min,
      (
        select max(fifo_sequence)::integer
        from private.operation_capacity_backlog
        where operation_id = ${operationId}::uuid
          and status = 'waiting'
      ) as fifo_max,
      (
        select count(*)::integer
        from public.conversations
        where operation_id = ${operationId}::uuid
          and capacity_state = 'active'
      ) as active_conversations,
      (
        select count(*)::integer
        from public.conversations
        where operation_id = ${operationId}::uuid
          and capacity_state = 'waiting'
      ) as waiting_conversations,
      state.automatic_proactive_paused,
      state.automatic_pause_reason
    from private.operation_capacity_state as state
    where state.operation_id = ${operationId}::uuid
  `;
  const after = await database<Array<{ deadlocks: number }>>`
    select deadlocks::integer
    from pg_stat_database
    where datname = current_database()
  `;

  expect(aggregate[0]).toEqual({
    active_conversations: 30,
    automatic_pause_reason: "high_demand",
    automatic_proactive_paused: true,
    backlog: 70,
    fifo_max: 70,
    fifo_min: 1,
    slots: 30,
    waiting_conversations: 70,
  });
  expect(after[0]!.deadlocks - before[0]!.deadlocks).toBe(0);
  expect(elapsedMs).toBeLessThan(45_000);

  const identityTargets = await database<
    Array<{ admitted_id: string; waiting_id: string }>
  >`
    select
      (
        select conversation_id
        from private.conversation_capacity_slots
        where operation_id = ${operationId}::uuid
        order by conversation_id
        limit 1
      ) as admitted_id,
      (
        select conversation_id
        from private.operation_capacity_backlog
        where operation_id = ${operationId}::uuid
          and status = 'waiting'
        order by fifo_sequence
        limit 1
      ) as waiting_id
  `;
  await expect(
    database`
      update private.conversation_capacity_slots
      set conversation_id = ${identityTargets[0]!.waiting_id}::uuid
      where conversation_id = ${identityTargets[0]!.admitted_id}::uuid
    `,
  ).rejects.toMatchObject({ code: "23514" });
});

test("retomada automática exige cinco minutos e nenhum inbound atrasado", async () => {
  const admitted = await database<Array<{ conversation_id: string }>>`
    select conversation_id
    from private.conversation_capacity_slots
    where operation_id = ${operationId}::uuid
    order by conversation_id
  `;
  for (const slot of admitted.slice(8)) {
    await database`
      select private.apply_operation_capacity_command(
        ${operationId}::uuid,
        ${slot.conversation_id}::uuid,
        'prepare_human',
        null,
        null,
        null,
        '2026-07-31T13:00:00Z'::timestamptz,
        null,
        null,
        null,
        ${randomUUID()}::uuid,
        ${randomUUID()}::uuid
      )
    `;
  }

  const heldByDelayedInbound = await database<
    Array<{ result: { automatic_proactive_paused: boolean } }>
  >`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      null,
      'evaluate_resume',
      null,
      null,
      null,
      '2026-07-31T13:06:00Z'::timestamptz,
      null,
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  expect(
    heldByDelayedInbound[0]!.result.automatic_proactive_paused,
  ).toBe(true);

  const waiting = await database<Array<{ conversation_id: string }>>`
    select conversation_id
    from private.operation_capacity_backlog
    where operation_id = ${operationId}::uuid
      and status = 'waiting'
    order by fifo_sequence
  `;
  for (const backlog of waiting) {
    await database`
      select private.apply_operation_capacity_command(
        ${operationId}::uuid,
        ${backlog.conversation_id}::uuid,
        'prepare_human',
        null,
        null,
        null,
        '2026-07-31T13:06:00Z'::timestamptz,
        null,
        null,
        null,
        ${randomUUID()}::uuid,
        ${randomUUID()}::uuid
      )
    `;
  }

  const resumed = await database<
    Array<{
      automatic_proactive_paused: boolean;
      manual_proactive_paused: boolean;
      slots: number;
    }>
  >`
    select
      state.automatic_proactive_paused,
      state.manual_proactive_paused,
      (
        select count(*)::integer
        from private.conversation_capacity_slots
        where operation_id = ${operationId}::uuid
      ) as slots
    from private.operation_capacity_state as state
    where state.operation_id = ${operationId}::uuid
  `;
  expect(resumed[0]).toEqual({
    automatic_proactive_paused: false,
    manual_proactive_paused: false,
    slots: 8,
  });
});

test("proativo respeita menos de dez, um por minuto e retry idempotente", async () => {
  const targets = await database<Array<{ id: string }>>`
    select id
    from public.conversations
    where operation_id = ${operationId}::uuid
      and capacity_state = 'excluded'
      and ownership_type = 'pedro'
      and not is_paused
    order by id
    limit 3
  `;
  const firstEffect = "proactive:first";
  const secondEffect = "proactive:second";

  const first = await database<Array<{ result: { outcome: string } }>>`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${targets[0]!.id}::uuid,
      'admit_proactive',
      'campaign',
      'campaign',
      null,
      '2026-07-31T14:00:00Z'::timestamptz,
      ${firstEffect},
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  const firstRetry = await database<
    Array<{ result: { outcome: string; status: string } }>
  >`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${targets[0]!.id}::uuid,
      'admit_proactive',
      'campaign',
      'campaign',
      null,
      '2026-07-31T14:00:20Z'::timestamptz,
      ${firstEffect},
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  const secondWaiting = await database<
    Array<{ result: { outcome: string } }>
  >`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${targets[1]!.id}::uuid,
      'admit_proactive',
      'campaign',
      'campaign',
      null,
      '2026-07-31T14:00:30Z'::timestamptz,
      ${secondEffect},
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  const secondRetry = await database<
    Array<{ result: { outcome: string; status: string } }>
  >`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${targets[1]!.id}::uuid,
      'admit_proactive',
      'campaign',
      'campaign',
      null,
      '2026-07-31T14:01:00Z'::timestamptz,
      ${secondEffect},
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  const secondAdmitted = await database<
    Array<{ result: { outcome: string } }>
  >`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${targets[1]!.id}::uuid,
      'admit_backlog',
      'campaign',
      'campaign',
      null,
      '2026-07-31T14:01:00Z'::timestamptz,
      'admit-backlog:proactive-second:1',
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;
  const tenthBlocked = await database<
    Array<{ result: { outcome: string } }>
  >`
    select private.apply_operation_capacity_command(
      ${operationId}::uuid,
      ${targets[2]!.id}::uuid,
      'admit_proactive',
      'campaign',
      'campaign',
      null,
      '2026-07-31T14:02:00Z'::timestamptz,
      'proactive:tenth',
      null,
      null,
      ${randomUUID()}::uuid,
      ${randomUUID()}::uuid
    ) as result
  `;

  expect(first[0]!.result.outcome).toBe("admitted");
  expect(firstRetry[0]!.result).toMatchObject({
    outcome: "admitted",
    status: "duplicate",
  });
  expect(secondWaiting[0]!.result.outcome).toBe("waiting");
  expect(secondRetry[0]!.result).toMatchObject({
    outcome: "waiting",
    status: "duplicate",
  });
  expect(secondAdmitted[0]!.result.outcome).toBe("admitted");
  expect(tenthBlocked[0]!.result.outcome).toBe("waiting");

  const final = await database<Array<{ slots: number; waiting: number }>>`
    select
      (
        select count(*)::integer
        from private.conversation_capacity_slots
        where operation_id = ${operationId}::uuid
      ) as slots,
      (
        select count(*)::integer
        from private.operation_capacity_backlog
        where operation_id = ${operationId}::uuid
          and status = 'waiting'
      ) as waiting
  `;
  expect(final[0]).toEqual({ slots: 10, waiting: 1 });
});
