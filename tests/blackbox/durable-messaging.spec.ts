import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const suffix = randomUUID().slice(0, 8);
let admin: SupabaseClient;
let database: Sql;
let organizationId = "";
let operationId = "";
let connectionId = "";

test.describe.configure({ mode: "serial" });

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for Preview black-box`);
  return value;
}

function event(messageId: string, chatId: string, ordinal = 0) {
  return {
    provider: "simulator",
    provider_message_id: messageId,
    provider_chat_id: chatId,
    occurred_at: new Date(Date.now() + ordinal * 1_000).toISOString(),
    kind: "text",
    text: `Synthetic durable message ${ordinal}`,
    identity: {
      aliases: [{ type: "simulator_user", value: `user-${chatId}` }],
      display_name: "Synthetic Durable",
      phone_original: null,
    },
  };
}

async function accept(
  normalizedEvent: ReturnType<typeof event>,
  rawBody = JSON.stringify(normalizedEvent),
) {
  return admin.rpc("ingest_simulated_inbound", {
    normalized_event: normalizedEvent,
    raw_body: rawBody,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_connection_id: connectionId,
  });
}

async function drain(maximumMessages = 100) {
  const result = await admin.rpc("run_durable_workers", {
    maximum_messages: maximumMessages,
  });
  expect(result.error).toBeNull();
}

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
    max: 4,
    prepare: false,
  });

  organizationId = randomUUID();
  operationId = randomUUID();
  connectionId = randomUUID();
  const insertedOrganization = await admin.from("organizations").insert({
    id: organizationId,
    name: `T06 Synthetic ${suffix}`,
    slug: `t06-synthetic-${suffix}`,
  });
  expect(insertedOrganization.error).toBeNull();
  const insertedOperation = await admin.from("operations").insert({
    id: operationId,
    is_default: true,
    name: `T06 Synthetic ${suffix}`,
    organization_id: organizationId,
  });
  expect(insertedOperation.error).toBeNull();
  const insertedSettings = await admin.from("operation_settings").insert({
    operation_id: operationId,
    organization_id: organizationId,
  });
  expect(insertedSettings.error).toBeNull();
  const insertedConnection = await admin.from("whatsapp_connections").insert({
    adapter_type: "simulator",
    display_name: "T06 Synthetic",
    id: connectionId,
    is_test: true,
    operation_id: operationId,
    organization_id: organizationId,
    provider_connection_id: `t06-${suffix}`,
  });
  expect(insertedConnection.error).toBeNull();
});

test.afterAll(async () => {
  await database?.end();
});

test("dez webhooks iguais produzem um efeito e raw divergente conflita", async () => {
  const normalized = event("duplicate-001", "duplicate-chat");
  const results = await Promise.all(
    Array.from({ length: 10 }, () => accept(normalized)),
  );
  expect(results.every((result) => !result.error)).toBe(true);
  expect(
    results.filter(
      (result) => (result.data as { status: string }).status === "accepted",
    ),
  ).toHaveLength(1);
  expect(
    results.filter(
      (result) => (result.data as { status: string }).status === "duplicate",
    ),
  ).toHaveLength(9);

  await drain();
  const counts = await database<Array<{ inbox: number; messages: number }>>`
    select
      (
        select count(*)::integer
        from private.webhook_inbox
        where connection_id = ${connectionId}::uuid
          and provider_event_id = 'duplicate-001'
      ) as inbox,
      (
        select count(*)::integer
        from public.messages
        where connection_id = ${connectionId}::uuid
          and provider_message_id = 'duplicate-001'
      ) as messages
  `;
  expect(counts[0]).toEqual({ inbox: 1, messages: 1 });

  const divergent = await accept(
    normalized,
    JSON.stringify({ ...normalized, discarded_by_adapter: "different" }),
  );
  expect(divergent.error).not.toBeNull();
  expect(divergent.error?.code).toBe("40001");
});

test("dois consumidores preservam a ordem canônica de cem mensagens", async () => {
  const chatId = `ordered-${suffix}`;
  const accepted = [];
  for (let index = 0; index < 100; index += 1) {
    accepted.push(
      await accept(
        event(
          `ordered-${String(index + 1).padStart(3, "0")}`,
          chatId,
          index + 1,
        ),
      ),
    );
  }
  expect(accepted.every((result) => !result.error)).toBe(true);

  await Promise.all([drain(100), drain(100)]);
  const order = await database<
    Array<{
      correctly_ordered: number;
      leaked_leases: number;
      maximum_sequence: number;
      total: number;
      unique_sequences: number;
    }>
  >`
    with ordered as (
      select message.provider_message_id, message.inbound_stream_sequence
      from public.messages as message
      where message.connection_id = ${connectionId}::uuid
        and message.provider_message_id like 'ordered-%'
    )
    select
      count(*)::integer as total,
      count(distinct inbound_stream_sequence)::integer as unique_sequences,
      max(inbound_stream_sequence)::integer as maximum_sequence,
      count(*) filter (
        where provider_message_id =
          'ordered-' || lpad(inbound_stream_sequence::text, 3, '0')
      )::integer as correctly_ordered,
      (
        select count(*)::integer
        from private.conversation_processing_leases
        where operation_id = ${operationId}::uuid
      ) as leaked_leases
    from ordered
  `;
  expect(order[0]).toEqual({
    correctly_ordered: 100,
    leaked_leases: 0,
    maximum_sequence: 100,
    total: 100,
    unique_sequences: 100,
  });
});

test("redelivery depois do efeito durável não duplica a mensagem", async () => {
  const rows = await database<
    Array<{
      correlation_id: string;
      id: string;
      organization_id: string;
      stream_key: string;
      stream_sequence: number;
      trace_id: string;
    }>
  >`
    select
      id, organization_id, stream_key, stream_sequence,
      trace_id, correlation_id
    from private.webhook_inbox
    where connection_id = ${connectionId}::uuid
      and provider_event_id = 'duplicate-001'
  `;
  const inbox = rows[0]!;
  await database`
    select pgmq.send(
      'inbound_whatsapp',
      jsonb_build_object(
        'inbox_id', ${inbox.id}::uuid,
        'organization_id', ${inbox.organization_id}::uuid,
        'operation_id', ${operationId}::uuid,
        'stream_key', ${inbox.stream_key},
        'stream_sequence', ${inbox.stream_sequence},
        'trace_id', ${inbox.trace_id}::uuid,
        'correlation_id', ${inbox.correlation_id}::uuid
      )
    )
  `;
  await drain();

  const messages = await database<Array<{ count: number }>>`
    select count(*)::integer as count
    from public.messages
    where connection_id = ${connectionId}::uuid
      and provider_message_id = 'duplicate-001'
  `;
  expect(messages[0]!.count).toBe(1);
});

test("ação agendada conclui uma vez e redelivery reconcilia sem novo efeito", async () => {
  await database.begin(async (sql) => {
    const aggregateId = randomUUID();
    const traceId = randomUUID();
    const correlationId = randomUUID();
    const jobs = await sql<
      Array<{
        aggregate_sequence: number;
        effect_key: string;
        id: string;
      }>
    >`
      insert into public.scheduled_jobs (
        organization_id,
        operation_id,
        job_type,
        aggregate_type,
        aggregate_id,
        aggregate_version,
        target_queue,
        run_at,
        dedupe_key,
        payload,
        trace_id,
        correlation_id
      )
      values (
        ${organizationId}::uuid,
        ${operationId}::uuid,
        'synthetic.acceptance',
        'synthetic_aggregate',
        ${aggregateId}::uuid,
        1,
        'scheduled_actions',
        now(),
        ${`scheduled-once-${suffix}`},
        ${sql.json({ fixture: "t06-no-content" })},
        ${traceId}::uuid,
        ${correlationId}::uuid
      )
      returning id, effect_key, aggregate_sequence
    `;
    const job = jobs[0]!;

    await sql`select private.dispatch_due_scheduled_jobs(10)`;
    await sql`
      select private.consume_scheduled_actions(10, gen_random_uuid(), 30)
    `;

    const firstPass = await sql<
      Array<{
        effects: number;
        executions: number;
        status: string;
      }>
    >`
      select
        job.status,
        (
          select count(*)::integer
          from private.scheduled_job_executions as execution
          where execution.scheduled_job_id = job.id
        ) as executions,
        (
          select count(*)::integer
          from private.effect_ledger as effect
          where effect.organization_id = job.organization_id
            and effect.operation_id = job.operation_id
            and effect.effect_key = job.effect_key
            and effect.state = 'effect_recorded'
        ) as effects
      from public.scheduled_jobs as job
      where job.id = ${job.id}::uuid
    `;
    expect(firstPass[0]).toEqual({
      effects: 1,
      executions: 1,
      status: "completed",
    });

    await sql`
      select pgmq.send(
        'scheduled_actions',
        jsonb_build_object(
          'scheduled_job_id', job.id,
          'organization_id', job.organization_id,
          'operation_id', job.operation_id,
          'aggregate_type', job.aggregate_type,
          'aggregate_id', job.aggregate_id,
          'aggregate_version', job.aggregate_version,
          'aggregate_sequence', job.aggregate_sequence,
          'effect_key', job.effect_key,
          'trace_id', job.trace_id,
          'correlation_id', job.correlation_id
        )
      )
      from public.scheduled_jobs as job
      where job.id = ${job.id}::uuid
    `;
    await sql`
      select private.consume_scheduled_actions(10, gen_random_uuid(), 30)
    `;

    const redelivery = await sql<
      Array<{ effects: number; executions: number; status: string }>
    >`
      select
        job.status,
        (
          select count(*)::integer
          from private.scheduled_job_executions as execution
          where execution.scheduled_job_id = job.id
        ) as executions,
        (
          select count(*)::integer
          from private.effect_ledger as effect
          where effect.organization_id = job.organization_id
            and effect.operation_id = job.operation_id
            and effect.effect_key = job.effect_key
        ) as effects
      from public.scheduled_jobs as job
      where job.id = ${job.id}::uuid
    `;
    expect(redelivery[0]).toEqual({
      effects: 1,
      executions: 1,
      status: "completed",
    });
  });
});

test("predecessor lento não consome o orçamento nem manda sucessor para DLQ", async () => {
  await database.begin(async (sql) => {
    const aggregateId = randomUUID();
    const traceId = randomUUID();
    const correlationId = randomUUID();
    const jobs = await sql<
      Array<{
        aggregate_sequence: number;
        id: string;
        queue_message_id: number | null;
      }>
    >`
      insert into public.scheduled_jobs (
        organization_id,
        operation_id,
        job_type,
        aggregate_type,
        aggregate_id,
        aggregate_version,
        target_queue,
        run_at,
        max_attempts,
        dedupe_key,
        payload,
        trace_id,
        correlation_id
      )
      values
        (
          ${organizationId}::uuid,
          ${operationId}::uuid,
          'synthetic.slow-predecessor',
          'synthetic_aggregate',
          ${aggregateId}::uuid,
          1,
          'scheduled_actions',
          now(),
          2,
          ${`scheduled-slow-1-${suffix}`},
          ${sql.json({ fixture: "t06-no-content" })},
          ${traceId}::uuid,
          ${correlationId}::uuid
        ),
        (
          ${organizationId}::uuid,
          ${operationId}::uuid,
          'synthetic.slow-successor',
          'synthetic_aggregate',
          ${aggregateId}::uuid,
          2,
          'scheduled_actions',
          now(),
          2,
          ${`scheduled-slow-2-${suffix}`},
          ${sql.json({ fixture: "t06-no-content" })},
          ${traceId}::uuid,
          ${correlationId}::uuid
        )
      returning id, aggregate_sequence, queue_message_id
    `;
    expect(jobs.map((job) => job.aggregate_sequence)).toEqual([1, 2]);

    await sql`select private.dispatch_due_scheduled_jobs(10)`;
    const published = await sql<
      Array<{
        aggregate_sequence: number;
        id: string;
        queue_message_id: number;
      }>
    >`
      select id, aggregate_sequence, queue_message_id
      from public.scheduled_jobs
      where aggregate_id = ${aggregateId}::uuid
      order by aggregate_sequence
    `;
    const predecessor = published[0]!;
    const successor = published[1]!;

    await sql`
      select *
      from pgmq.set_vt(
        'scheduled_actions',
        ${predecessor.queue_message_id},
        120
      )
    `;
    for (let attempt = 0; attempt < 10; attempt += 1) {
      await sql`
        select *
        from pgmq.set_vt(
          'scheduled_actions',
          ${successor.queue_message_id},
          0
        )
      `;
      await sql`
        select private.consume_scheduled_actions(1, gen_random_uuid(), 5)
      `;
    }

    const contended = await sql<
      Array<{
        attempts: number;
        contention_count: number;
        dead_letters: number;
        status: string;
      }>
    >`
      select
        job.status,
        job.attempts,
        job.contention_count,
        (
          select count(*)::integer
          from private.dead_letters as letter
          where letter.envelope_id = job.id
        ) as dead_letters
      from public.scheduled_jobs as job
      where job.id = ${successor.id}::uuid
    `;
    expect(contended[0]).toEqual({
      attempts: 0,
      contention_count: 10,
      dead_letters: 0,
      status: "published",
    });

    await sql`
      select *
      from pgmq.set_vt(
        'scheduled_actions',
        ${predecessor.queue_message_id},
        0
      )
    `;
    await sql`
      select *
      from pgmq.set_vt(
        'scheduled_actions',
        ${successor.queue_message_id},
        0
      )
    `;
    await sql`
      select private.consume_scheduled_actions(10, gen_random_uuid(), 30)
    `;

    const completed = await sql<
      Array<{ executions: number; statuses: string[] }>
    >`
      select
        array_agg(job.status order by job.aggregate_sequence) as statuses,
        (
          select count(*)::integer
          from private.scheduled_job_executions as execution
          where execution.aggregate_id = ${aggregateId}::uuid
        ) as executions
      from public.scheduled_jobs as job
      where job.aggregate_id = ${aggregateId}::uuid
    `;
    expect(completed[0]).toEqual({
      executions: 2,
      statuses: ["completed", "completed"],
    });
  });
});
