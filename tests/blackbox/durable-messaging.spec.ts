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
      pending_outbox: number;
      reconciliation_backlog: number;
      total: number;
      unique_sequences: number;
    }>
  >`
    with ordered as (
      select
        message.id,
        message.provider_message_id,
        message.inbound_stream_sequence
      from public.messages as message
      where message.connection_id = ${connectionId}::uuid
        and message.provider_message_id like 'ordered-%'
    )
    select
      count(*)::integer as total,
      count(distinct inbound_stream_sequence)::integer
        as unique_sequences,
      max(inbound_stream_sequence)::integer as maximum_sequence,
      count(*) filter (
        where provider_message_id =
          'ordered-' || lpad(inbound_stream_sequence::text, 3, '0')
      )::integer as correctly_ordered,
      (
        select count(*)::integer
        from private.conversation_processing_leases
        where operation_id = ${operationId}::uuid
      ) as leaked_leases,
      (
        select count(*)::integer
        from private.outbox_events as event
        join ordered as ordered_message
          on ordered_message.id::text = event.payload ->> 'message_id'
        where event.status <> 'completed'
      ) as pending_outbox,
      (
        select count(*)::integer
        from pgmq.q_reconciliation as queued
        join private.outbox_events as event
          on event.id = (queued.message ->> 'outbox_event_id')::uuid
        join ordered as ordered_message
          on ordered_message.id::text = event.payload ->> 'message_id'
      ) as reconciliation_backlog
    from ordered
  `;
  expect(order[0]).toEqual({
    correctly_ordered: 100,
    leaked_leases: 0,
    maximum_sequence: 100,
    pending_outbox: 0,
    reconciliation_backlog: 0,
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
  const envelope = {
    correlation_id: inbox.correlation_id,
    inbox_id: inbox.id,
    operation_id: operationId,
    organization_id: inbox.organization_id,
    stream_key: inbox.stream_key,
    stream_sequence: inbox.stream_sequence,
    trace_id: inbox.trace_id,
  };
  await database`
    select pgmq.send(
      'inbound_whatsapp',
      ${database.json(envelope)}::jsonb
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

test("redelivery físico concorrente adia sem deadlock nem consumir tentativas", async () => {
  const messageId = `physical-redelivery-${suffix}`;
  const accepted = await accept(
    event(messageId, `physical-redelivery-chat-${suffix}`),
  );
  expect(accepted.error).toBeNull();

  const inboxes = await database<
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
      id,
      organization_id,
      stream_key,
      stream_sequence,
      trace_id,
      correlation_id
    from private.webhook_inbox
    where connection_id = ${connectionId}::uuid
      and provider_event_id = ${messageId}
  `;
  const inbox = inboxes[0]!;
  const envelope = {
    correlation_id: inbox.correlation_id,
    inbox_id: inbox.id,
    operation_id: operationId,
    organization_id: inbox.organization_id,
    stream_key: inbox.stream_key,
    stream_sequence: inbox.stream_sequence,
    trace_id: inbox.trace_id,
  };
  await database`
    select pgmq.send(
      'inbound_whatsapp',
      ${database.json(envelope)}::jsonb
    )
  `;

  await database.begin(async (lockSql) => {
    await lockSql`
      select stream.stream_key
      from private.stream_sequences as stream
      where stream.organization_id = ${organizationId}::uuid
        and stream.operation_id = ${operationId}::uuid
        and stream.stream_key = ${inbox.stream_key}
      for update
    `;

    const deferred = await Promise.all(
      Array.from({ length: 2 }, () =>
        database.begin(async (workerSql) => {
          await workerSql`set local statement_timeout = '5s'`;
          const result = await workerSql<
            Array<{ result: { deferred: number } }>
          >`
            select private.consume_inbound_whatsapp(
              1,
              gen_random_uuid(),
              5
            ) as result
          `;
          return result[0]!.result.deferred;
        }),
      ),
    );
    expect(deferred.reduce((total, value) => total + value, 0)).toBe(2);
  });

  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      queued.msg_id,
      0
    )
    from pgmq.q_inbound_whatsapp as queued
    where queued.message ->> 'inbox_id' = ${inbox.id}
  `;
  await Promise.all([drain(10), drain(10)]);

  const state = await database<
    Array<{
      alerts: number;
      attempts: number;
      contention_count: number;
      messages: number;
      queued: number;
    }>
  >`
    select
      inbox.attempts,
      inbox.contention_count,
      (
        select count(*)::integer
        from public.messages as message
        where message.connection_id = ${connectionId}::uuid
          and message.provider_message_id = ${messageId}
      ) as messages,
      (
        select count(*)::integer
        from pgmq.q_inbound_whatsapp as queued
        where queued.message ->> 'inbox_id' = inbox.id::text
      ) as queued,
      (
        select count(*)::integer
        from private.dead_letters as letter
        where letter.envelope_id = inbox.id
      ) as alerts
    from private.webhook_inbox as inbox
    where inbox.id = ${inbox.id}::uuid
  `;
  expect(state[0]).toEqual({
    alerts: 0,
    attempts: 0,
    contention_count: 2,
    messages: 1,
    queued: 0,
  });
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
    expect(jobs.map((job) => Number(job.aggregate_sequence))).toEqual([1, 2]);

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

test("cascade torna envelope órfão e worker o quarentena sem travar a fila", async () => {
  await database.begin(async (sql) => {
    const orphanConnectionId = randomUUID();
    const rawEvent = event(
      `orphan-${suffix}`,
      `orphan-chat-${suffix}`,
    );
    await sql`
      insert into public.whatsapp_connections (
        id,
        organization_id,
        operation_id,
        adapter_type,
        provider_connection_id,
        display_name,
        status,
        is_test
      )
      values (
        ${orphanConnectionId}::uuid,
        ${organizationId}::uuid,
        ${operationId}::uuid,
        'simulator',
        ${`orphan-${suffix}`},
        'T06 Orphan Synthetic',
        'active',
        true
      )
    `;
    await sql`
      select set_config(
        'request.jwt.claims',
        '{"role":"service_role"}',
        true
      )
    `;
    const accepted = await sql<
      Array<{ accepted: { inbox_id: string; queue_message_id: number } }>
    >`
      select public.ingest_simulated_inbound(
        ${orphanConnectionId}::uuid,
        ${sql.json(rawEvent)},
        ${JSON.stringify(rawEvent)},
        ${randomUUID()}::uuid,
        ${randomUUID()}::uuid
      ) as accepted
    `;
    const queueMessageId = accepted[0]!.accepted.queue_message_id;

    await sql`
      delete from public.whatsapp_connections
      where id = ${orphanConnectionId}::uuid
    `;
    await sql`select private.run_durable_workers(10)`;

    const quarantined = await sql<
      Array<{
        alerts: number;
        failure_code: string;
        inbox_exists: boolean;
        status: string;
      }>
    >`
      select
        letter.status,
        letter.failure_code,
        exists (
          select 1
          from private.webhook_inbox as inbox
          where inbox.id = letter.envelope_id
        ) as inbox_exists,
        (
          select count(*)::integer
          from private.durable_processing_alerts as alert
          where alert.dead_letter_id = letter.id
        ) as alerts
      from private.dead_letters as letter
      where letter.source_queue = 'inbound_whatsapp'
        and letter.source_message_id = ${queueMessageId}
    `;
    expect(quarantined[0]).toEqual({
      alerts: 1,
      failure_code: "artifact_missing",
      inbox_exists: false,
      status: "pending",
    });
  });
});

test("poison em reconciliation é limitado ao batch e não aborta o runner", async () => {
  await database.begin(async (sql) => {
    const inboundPoison = await sql<Array<{ msg_id: number }>>`
      select sent.msg_id
      from pgmq.send(
        'inbound_whatsapp',
        jsonb_build_object('inbox_id', 'not-a-uuid')
      ) as sent(msg_id)
    `;
    const outboundPoison = await sql<Array<{ msg_id: number }>>`
      select sent.msg_id
      from pgmq.send(
        'outbound_whatsapp',
        jsonb_build_object('outbox_event_id', 'not-a-uuid')
      ) as sent(msg_id)
    `;
    const messages = await sql<Array<{ msg_id: number }>>`
      select sent.msg_id
      from generate_series(1, 50) as fixture(ordinal)
      cross join lateral pgmq.send(
        'reconciliation',
        jsonb_build_object(
          'outbox_event_id', 'not-a-uuid',
          'fixture_ordinal', fixture.ordinal
        )
      ) as sent(msg_id)
    `;
    const messageIds = messages.map((message) => message.msg_id);
    const startedAt = Date.now();
    const results = await sql<
      Array<{
        result: {
          dead_letter_signals: number;
          reconciliation: {
            dead_lettered: number;
            processed: number;
          };
          reconciled: number;
        };
      }>
    >`
      select private.run_durable_workers(10) as result
    `;
    const elapsedMs = Date.now() - startedAt;

    const quarantined = await sql<Array<{ count: number }>>`
      select count(*)::integer as count
      from private.dead_letters
      where source_queue = 'reconciliation'
        and source_message_id = any(${messageIds}::bigint[])
    `;
    const queuePoisons = await sql<
      Array<{ inbound: number; outbound: number }>
    >`
      select
        count(*) filter (
          where source_queue = 'inbound_whatsapp'
            and source_message_id = ${inboundPoison[0]!.msg_id}
        )::integer as inbound,
        count(*) filter (
          where source_queue = 'outbound_whatsapp'
            and source_message_id = ${outboundPoison[0]!.msg_id}
        )::integer as outbound
      from private.dead_letters
    `;
    const infrastructureAlerts = await sql<Array<{ count: number }>>`
      select count(*)::integer as count
      from public.get_durable_processing_alerts(
        ${operationId}::uuid,
        100
      ) as alert
      where alert.dead_letter_id in (
        select letter.id
        from private.dead_letters as letter
        where (
          letter.source_queue = 'inbound_whatsapp'
          and letter.source_message_id = ${inboundPoison[0]!.msg_id}
        )
        or (
          letter.source_queue = 'outbound_whatsapp'
          and letter.source_message_id = ${outboundPoison[0]!.msg_id}
        )
      )
    `;
    const classifications = await sql<
      Array<{ scheduled: string; worker: string }>
    >`
      select
        private.classify_worker_failure('40001') as worker,
        private.classify_scheduled_failure('40P01') as scheduled
    `;
    expect(quarantined[0]!.count).toBe(10);
    expect(queuePoisons[0]).toEqual({ inbound: 1, outbound: 1 });
    expect(infrastructureAlerts[0]!.count).toBe(2);
    expect(classifications[0]).toEqual({
      scheduled: "contention",
      worker: "contention",
    });
    expect(results[0]!.result.reconciled).toBe(0);
    expect(results[0]!.result.reconciliation).toEqual(
      expect.objectContaining({
        dead_lettered: 10,
        processed: 0,
      }),
    );
    expect(results[0]!.result.dead_letter_signals).toBe(12);
    expect(elapsedMs).toBeLessThan(15_000);
  });
});

test("retenção apaga todo payload terminal e preserva hashes canônicos", async () => {
  await database.begin(async (sql) => {
    const before = await sql<
      Array<{ id: string; payload_hash: string; raw_body_hash: string }>
    >`
      select id, payload_hash, raw_body_hash
      from private.webhook_inbox
      where connection_id = ${connectionId}::uuid
        and provider_event_id = 'duplicate-001'
    `;
    const inbox = before[0]!;
    await sql`
      insert into private.durable_retention_policies (
        organization_id,
        operation_id,
        webhook_raw_retention
      )
      values (
        ${organizationId}::uuid,
        ${operationId}::uuid,
        interval '1 hour'
      )
      on conflict (organization_id, operation_id)
      do update set webhook_raw_retention = excluded.webhook_raw_retention
    `;
    await sql`
      update private.webhook_inbox
      set
        status = 'dead',
        processed_at = null,
        normalized_payload = '{"sensitive":"must-purge"}'::jsonb,
        updated_at = now() - interval '2 hours'
      where id = ${inbox.id}::uuid
    `;
    await sql`select private.prune_durable_sensitive_material(100)`;

    const after = await sql<
      Array<{
        payload_hash: string;
        purged: boolean;
        raw_body: string | null;
        raw_body_hash: string;
        raw_payload: unknown;
        normalized_payload: unknown;
      }>
    >`
      select
        raw_body,
        raw_body_hash,
        payload_hash,
        raw_payload,
        normalized_payload,
        raw_payload_purged_at is not null as purged
      from private.webhook_inbox
      where id = ${inbox.id}::uuid
    `;
    expect(after[0]).toEqual({
      payload_hash: inbox.payload_hash,
      purged: true,
      raw_body: null,
      raw_body_hash: inbox.raw_body_hash,
      raw_payload: {},
      normalized_payload: {},
    });
  });
});

test("retenção limita arquivos PGMQ e permite resolver alerta de infraestrutura", async () => {
  await database.begin(async (sql) => {
    const archived = await sql<Array<{ msg_id: number }>>`
      select pgmq.send(
        'dead_letter'::text,
        jsonb_build_object('probe', ${randomUUID()}::text),
        0
      ) as msg_id
    `;
    const archivedMessageId = archived[0]!.msg_id;
    await sql`
      select pgmq.archive(
        'dead_letter'::text,
        ${archivedMessageId}::bigint
      )
    `;
    await sql`
      update pgmq.a_dead_letter
      set archived_at = now() - interval '8 days'
      where msg_id = ${archivedMessageId}
    `;
    const archivePrune = await sql<
      Array<{ result: { a_dead_letter: number; total: number } }>
    >`
      select private.prune_t06_queue_archives(
        interval '7 days',
        10
      ) as result
    `;
    expect(archivePrune[0]!.result).toEqual(
      expect.objectContaining({ a_dead_letter: 1, total: 1 }),
    );

    const deadLetterId = randomUUID();
    const alertId = randomUUID();
    const traceId = randomUUID();
    const correlationId = randomUUID();
    await sql`
      insert into private.dead_letters (
        id,
        source_queue,
        source_message_id,
        envelope_id,
        effect_key,
        redacted_envelope,
        attempts,
        failure_class,
        failure_code,
        trace_id,
        correlation_id
      )
      values (
        ${deadLetterId}::uuid,
        'reconciliation',
        ${(900000000000000000n + BigInt(Date.now())).toString()}::bigint,
        ${randomUUID()}::uuid,
        'synthetic:infrastructure',
        '{}'::jsonb,
        1,
        'infrastructure',
        'synthetic_infrastructure',
        ${traceId}::uuid,
        ${correlationId}::uuid
      )
    `;
    await sql`
      insert into private.durable_processing_alerts (
        id,
        dead_letter_id,
        source_queue,
        severity,
        failure_class,
        failure_code,
        effect_key_hash,
        trace_id,
        correlation_id
      )
      values (
        ${alertId}::uuid,
        ${deadLetterId}::uuid,
        'reconciliation',
        'critical',
        'infrastructure',
        'synthetic_infrastructure',
        encode(
          sha256(convert_to('synthetic:infrastructure', 'UTF8')),
          'hex'
        ),
        ${traceId}::uuid,
        ${correlationId}::uuid
      )
    `;
    await sql`
      select set_config(
        'request.jwt.claims',
        '{"role":"service_role"}',
        true
      )
    `;
    const resolved = await sql<Array<{ result: { status: string } }>>`
      select public.resolve_infrastructure_durable_alert(
        ${alertId}::uuid,
        ${traceId}::uuid,
        ${correlationId}::uuid
      ) as result
    `;
    expect(resolved[0]!.result.status).toBe("resolved");

    const audited = await sql<
      Array<{
        alert_status: string;
        dead_letter_status: string;
        resolution_correlation_id: string;
        resolution_source: string;
        resolution_trace_id: string;
      }>
    >`
      select
        alert.status as alert_status,
        alert.resolution_source,
        alert.resolution_trace_id,
        alert.resolution_correlation_id,
        letter.status as dead_letter_status
      from private.durable_processing_alerts as alert
      join private.dead_letters as letter
        on letter.id = alert.dead_letter_id
      where alert.id = ${alertId}::uuid
    `;
    expect(audited[0]).toEqual({
      alert_status: "resolved",
      dead_letter_status: "resolved",
      resolution_correlation_id: correlationId,
      resolution_source: "service_role",
      resolution_trace_id: traceId,
    });
  });
});
