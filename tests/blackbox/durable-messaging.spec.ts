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
let ownerMembershipId = "";
let ownerUserId = "";

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

async function createReplayFenceFixture(label: string) {
  await database`select pgmq.purge_queue('inbound_whatsapp')`;
  const chatId = `replay-fence-${label}-${suffix}`;
  const firstMessageId = `replay-fence-${label}-n-${suffix}`;
  const secondMessageId = `replay-fence-${label}-n1-${suffix}`;
  const first = await accept(event(firstMessageId, chatId, 1));
  expect(first.error).toBeNull();
  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      ${(first.data as { queue_message_id: number }).queue_message_id},
      60
    )
  `;
  const second = await accept(event(secondMessageId, chatId, 2));
  expect(second.error).toBeNull();
  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      ${(second.data as { queue_message_id: number }).queue_message_id},
      60
    )
  `;

  return database.begin(async (sql) => {
    const inboxes = await sql<
      Array<{
        correlation_id: string;
        id: string;
        organization_id: string;
        provider_event_id: string;
        queue_message_id: number;
        stream_key: string;
        stream_sequence: number;
        trace_id: string;
      }>
    >`
      select
        id,
        organization_id,
        provider_event_id,
        queue_message_id,
        stream_key,
        stream_sequence,
        trace_id,
        correlation_id
      from private.webhook_inbox
      where connection_id = ${connectionId}::uuid
        and provider_event_id in (${firstMessageId}, ${secondMessageId})
      order by stream_sequence
      for update
    `;
    const oldInbox = inboxes[0]!;
    const envelope = {
      correlation_id: oldInbox.correlation_id,
      inbox_id: oldInbox.id,
      operation_id: operationId,
      organization_id: oldInbox.organization_id,
      stream_key: oldInbox.stream_key,
      stream_sequence: Number(oldInbox.stream_sequence),
      trace_id: oldInbox.trace_id,
    };
    const letters = await sql<Array<{ id: string }>>`
      select private.dead_letter_queue_message(
        'inbound_whatsapp',
        ${oldInbox.queue_message_id},
        ${oldInbox.id}::uuid,
        ${`webhook:${connectionId}:${oldInbox.provider_event_id}`},
        ${sql.json(envelope)}::jsonb,
        1,
        'non_retryable',
        'synthetic_replay_fence',
        ${organizationId}::uuid,
        ${operationId}::uuid,
        ${oldInbox.trace_id}::uuid,
        ${oldInbox.correlation_id}::uuid
      ) as id
    `;
    await sql`
      update private.webhook_inbox
      set
        status = 'dead',
        attempts = 1,
        last_error_class = 'non_retryable',
        last_error_code = 'synthetic_replay_fence',
        updated_at = now()
      where id = ${oldInbox.id}::uuid
    `;
    return {
      deadLetterId: letters[0]!.id,
      firstInboxId: oldInbox.id,
      firstMessageId,
      secondInboxId: inboxes[1]!.id,
      secondMessageId,
    };
  });
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
  const createdOwner = await admin.auth.admin.createUser({
    email: `t06-owner-${suffix}@example.com`,
    email_confirm: true,
    password: `T06-${suffix}-synthetic-password`,
  });
  expect(createdOwner.error).toBeNull();
  ownerUserId = createdOwner.data.user!.id;
  ownerMembershipId = randomUUID();
  const insertedOwner = await admin.from("memberships").insert({
    id: ownerMembershipId,
    organization_id: organizationId,
    role: "owner",
    status: "active",
    user_id: ownerUserId,
  });
  expect(insertedOwner.error).toBeNull();
  const insertedOwnerOperation = await admin
    .from("membership_operations")
    .insert({
      membership_id: ownerMembershipId,
      operation_id: operationId,
      organization_id: organizationId,
    });
  expect(insertedOwnerOperation.error).toBeNull();
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
  if (ownerUserId) {
    await admin?.auth.admin.deleteUser(ownerUserId);
  }
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
  const deadlocksBefore = await database<Array<{ total: number }>>`
    select deadlocks::integer as total
    from pg_stat_database
    where datname = current_database()
  `;
  const concurrencyStartedAt = Date.now();
  const accepted = [];
  let accepting = true;
  const concurrentWorker = (async () => {
    while (accepting) {
      await drain(100);
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  })();
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
  accepting = false;
  await concurrentWorker;
  const concurrencyElapsedMs = Date.now() - concurrencyStartedAt;
  const deadlocksAfter = await database<Array<{ total: number }>>`
    select deadlocks::integer as total
    from pg_stat_database
    where datname = current_database()
  `;
  expect(
    accepted
      .filter((result) => result.error)
      .map((result) => ({
        code: result.error!.code,
        message: result.error!.message,
      })),
  ).toEqual([]);
  expect(deadlocksAfter[0]!.total - deadlocksBefore[0]!.total).toBe(0);
  expect(concurrencyElapsedMs).toBeLessThan(30_000);

  for (let recoveryRound = 0; recoveryRound < 100; recoveryRound += 1) {
    await database`
      select pgmq.set_vt(
        'inbound_whatsapp',
        queued.msg_id,
        0
      )
      from pgmq.q_inbound_whatsapp as queued
      join private.webhook_inbox as inbox
        on inbox.id = (queued.message ->> 'inbox_id')::uuid
      where inbox.connection_id = ${connectionId}::uuid
        and inbox.provider_event_id like 'ordered-%'
    `;
    await drain(100);
    const progress = await database<Array<{ total: number }>>`
      select count(*)::integer as total
      from public.messages
      where connection_id = ${connectionId}::uuid
        and provider_message_id like 'ordered-%'
    `;
    if (progress[0]!.total === 100) break;
  }
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
  const acceptedQueueMessageId = (
    accepted.data as { queue_message_id: number }
  ).queue_message_id;
  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      ${acceptedQueueMessageId},
      60
    )
  `;

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
      ${database.json(envelope)}::jsonb,
      60
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
    await database`
      select pgmq.set_vt(
        'inbound_whatsapp',
        queued.msg_id,
        0
      )
      from pgmq.q_inbound_whatsapp as queued
      where queued.message ->> 'inbox_id' = ${inbox.id}
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

test("replay N vence, adia N+1 e preserva ordem N,N+1", async () => {
  const fixture = await createReplayFenceFixture("replay-wins");
  let releaseReplay!: () => void;
  let replayReached!: () => void;
  const release = new Promise<void>((resolve) => {
    releaseReplay = resolve;
  });
  const reached = new Promise<void>((resolve) => {
    replayReached = resolve;
  });
  const replay = database.begin(async (sql) => {
    await sql`set local statement_timeout = '5s'`;
    await sql`set local lock_timeout = '4s'`;
    await sql`
      select set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'role',
          'authenticated',
          'sub',
          ${ownerUserId}::text
        )::text,
        true
      )
    `;
    const result = await sql<Array<{ result: { status: string } }>>`
      select public.replay_dead_letter(
        ${fixture.deadLetterId}::uuid,
        gen_random_uuid(),
        gen_random_uuid()
      ) as result
    `;
    replayReached();
    await release;
    return result[0]!.result;
  });
  await reached;

  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      queued.msg_id,
      0
    )
    from pgmq.q_inbound_whatsapp as queued
    where queued.message ->> 'inbox_id' = ${fixture.secondInboxId}
  `;
  const worker = await database.begin(async (sql) => {
    await sql`set local statement_timeout = '5s'`;
    await sql`
      select set_config(
        'request.jwt.claims',
        '{"role":"service_role"}',
        true
      )
    `;
    const result = await sql<
      Array<{
        result: {
          dead_lettered: number;
          deferred: number;
          processed: number;
        };
      }>
    >`
      select private.consume_inbound_whatsapp(
        1,
        gen_random_uuid(),
        5
      ) as result
    `;
    return result[0]!.result;
  });
  expect(worker).toEqual(
    expect.objectContaining({
      dead_lettered: 0,
      deferred: 1,
      processed: 0,
    }),
  );
  releaseReplay();
  expect(await replay).toEqual(expect.objectContaining({ status: "replayed" }));

  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      queued.msg_id,
      0
    )
    from pgmq.q_inbound_whatsapp as queued
    where queued.message ->> 'inbox_id' in (
      ${fixture.firstInboxId},
      ${fixture.secondInboxId}
    )
  `;
  await drain(10);
  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      queued.msg_id,
      0
    )
    from pgmq.q_inbound_whatsapp as queued
    where queued.message ->> 'inbox_id' in (
      ${fixture.firstInboxId},
      ${fixture.secondInboxId}
    )
  `;
  await drain(10);

  const order = await database<Array<{ provider_message_id: string }>>`
    select provider_message_id
    from public.messages
    where connection_id = ${connectionId}::uuid
      and provider_message_id in (
        ${fixture.firstMessageId},
        ${fixture.secondMessageId}
      )
    order by inbound_stream_sequence
  `;
  expect(order.map((message) => message.provider_message_id)).toEqual([
    fixture.firstMessageId,
    fixture.secondMessageId,
  ]);
});

test("worker N+1 vence e replay N espera antes de rejeitar stale", async () => {
  const fixture = await createReplayFenceFixture("worker-wins");
  await database`
    select pgmq.set_vt(
      'inbound_whatsapp',
      queued.msg_id,
      0
    )
    from pgmq.q_inbound_whatsapp as queued
    where queued.message ->> 'inbox_id' = ${fixture.secondInboxId}
  `;
  let releaseWorker!: () => void;
  let workerReached!: () => void;
  const release = new Promise<void>((resolve) => {
    releaseWorker = resolve;
  });
  const reached = new Promise<void>((resolve) => {
    workerReached = resolve;
  });
  const worker = database.begin(async (sql) => {
    await sql`set local statement_timeout = '5s'`;
    await sql`
      select set_config(
        'request.jwt.claims',
        '{"role":"service_role"}',
        true
      )
    `;
    const result = await sql<
      Array<{ result: { dead_lettered: number; processed: number } }>
    >`
      select private.consume_inbound_whatsapp(
        1,
        gen_random_uuid(),
        5
      ) as result
    `;
    workerReached();
    await release;
    return result[0]!.result;
  });
  await reached;

  let replaySettled = false;
  const replay = database
    .begin(async (sql) => {
      await sql`set local statement_timeout = '5s'`;
      await sql`set local lock_timeout = '4s'`;
      await sql`
        select set_config(
          'request.jwt.claims',
          jsonb_build_object(
            'role',
            'authenticated',
            'sub',
            ${ownerUserId}::text
          )::text,
          true
        )
      `;
      const result = await sql<
        Array<{ result: { reason: string; status: string } }>
      >`
        select public.replay_dead_letter(
          ${fixture.deadLetterId}::uuid,
          gen_random_uuid(),
          gen_random_uuid()
        ) as result
      `;
      return result[0]!.result;
    })
    .finally(() => {
      replaySettled = true;
    });
  await new Promise((resolve) => setTimeout(resolve, 250));
  expect(replaySettled).toBe(false);
  releaseWorker();

  expect(await worker).toEqual(
    expect.objectContaining({ dead_lettered: 0, processed: 1 }),
  );
  expect(await replay).toEqual(
    expect.objectContaining({
      reason: "later_inbound_already_applied",
      status: "rejected_stale",
    }),
  );
  const messages = await database<Array<{ provider_message_id: string }>>`
    select provider_message_id
    from public.messages
    where connection_id = ${connectionId}::uuid
      and provider_message_id in (
        ${fixture.firstMessageId},
        ${fixture.secondMessageId}
      )
    order by inbound_stream_sequence
  `;
  expect(messages.map((message) => message.provider_message_id)).toEqual([
    fixture.secondMessageId,
  ]);
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
    for (let recoveryAttempt = 0; recoveryAttempt < 5; recoveryAttempt += 1) {
      const pending = await sql<Array<{ count: number }>>`
        select count(*)::integer as count
        from public.scheduled_jobs
        where aggregate_id = ${aggregateId}::uuid
          and status <> 'completed'
      `;
      if (pending[0]!.count === 0) {
        break;
      }
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
    }

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

test("reconciliation forjada não altera outbound vivo e o efeito ainda executa", async () => {
  const fixtureInbound = await accept(
    event(
      `forged-reconciliation-seed-${suffix}`,
      `forged-reconciliation-chat-${suffix}`,
    ),
  );
  expect(fixtureInbound.error).toBeNull();
  await drain();

  await database.begin(async (sql) => {
    await sql`select pgmq.purge_queue('outbound_whatsapp')`;
    await sql`select pgmq.purge_queue('reconciliation')`;
    const conversations = await sql<
      Array<{ id: string; version: number }>
    >`
      with target as (
        select id
        from public.conversations
        where connection_id = ${connectionId}::uuid
        order by opened_at, id
        limit 1
        for update
      )
      update public.conversations as conversation
      set
        status = 'active',
        ownership_type = 'human',
        assigned_membership_id = ${ownerMembershipId}::uuid,
        sleeping_since = null,
        closed_at = null,
        is_paused = false,
        pending_return = false,
        updated_at = now()
      from target
      where conversation.id = target.id
      returning conversation.id, conversation.version
    `;
    const conversation = conversations[0]!;
    const messageId = randomUUID();
    const commandId = randomUUID();
    await sql`
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
        idempotency_key,
        created_by_type,
        created_by_membership_id
      )
      values (
        ${messageId}::uuid,
        ${organizationId}::uuid,
        ${operationId}::uuid,
        ${conversation.id}::uuid,
        ${connectionId}::uuid,
        'outbound',
        'text',
        'Synthetic outbound binding',
        'queued',
        ${commandId}::uuid,
        'human',
        ${ownerMembershipId}::uuid
      )
    `;
    const events = await sql<Array<{ id: string }>>`
      with next_sequence as (
        select private.next_aggregate_sequence(
          ${organizationId}::uuid,
          ${operationId}::uuid,
          'conversation',
          ${conversation.id}::uuid
        ) as value
      ),
      payload as (
        select jsonb_build_object(
          'message_id',
          ${messageId}::uuid,
          'conversation_id',
          ${conversation.id}::uuid,
          'connection_id',
          ${connectionId}::uuid
        ) as value
      )
      insert into private.outbox_events (
        organization_id,
        operation_id,
        event_type,
        aggregate_type,
        aggregate_id,
        aggregate_version,
        aggregate_sequence,
        actor_type,
        actor_reference,
        target_queue,
        idempotency_key,
        payload_hash,
        payload,
        trace_id,
        correlation_id
      )
      select
        ${organizationId}::uuid,
        ${operationId}::uuid,
        'message.send_requested.v1',
        'conversation',
        ${conversation.id}::uuid,
        ${conversation.version},
        next_sequence.value,
        'user',
        ${ownerMembershipId},
        'outbound_whatsapp',
        ${`binding:${commandId}`},
        encode(
          sha256(convert_to(payload.value::text, 'UTF8')),
          'hex'
        ),
        payload.value,
        gen_random_uuid(),
        gen_random_uuid()
      from next_sequence, payload
      returning id
    `;
    const eventId = events[0]!.id;
    await sql`select private.dispatch_outbox_events(100)`;
    await sql`select private.consume_reconciliation_detailed(100)`;
    const forged = await sql<Array<{ id: number }>>`
      select pgmq.send(
        'reconciliation',
        jsonb_build_object('outbox_event_id', ${eventId}::uuid),
        0
      ) as id
    `;
    const consumed = await sql<
      Array<{
        result: {
          dead_lettered: number;
          processed: number;
        };
      }>
    >`
      select private.consume_reconciliation_detailed(1) as result
    `;
    expect(consumed[0]!.result).toEqual(
      expect.objectContaining({
        dead_lettered: 1,
        processed: 0,
      }),
    );

    const preserved = await sql<
      Array<{
        dead_letter_id: string;
        failure_code: string;
        outbound_queued: number;
        status: string;
      }>
    >`
      select
        event.status,
        (
          select count(*)::integer
          from pgmq.q_outbound_whatsapp as queued
          where queued.msg_id = event.queue_message_id
        ) as outbound_queued,
        (
          select letter.id
          from private.dead_letters as letter
          where letter.source_queue = 'reconciliation'
            and letter.source_message_id = ${forged[0]!.id}
        ) as dead_letter_id,
        (
          select letter.failure_code
          from private.dead_letters as letter
          where letter.source_queue = 'reconciliation'
            and letter.source_message_id = ${forged[0]!.id}
        ) as failure_code
      from private.outbox_events as event
      where event.id = ${eventId}::uuid
    `;
    expect(preserved[0]).toEqual({
      dead_letter_id: expect.any(String),
      failure_code: "queue_binding_mismatch",
      outbound_queued: 1,
      status: "published",
    });

    const canonicalBeforeReplay = await sql`
      select
        event.status,
        event.target_queue,
        event.queue_message_id,
        (
          select count(*)::integer
          from pgmq.q_outbound_whatsapp as queued
          where queued.msg_id = event.queue_message_id
        ) as outbound_queued,
        (
          select count(*)::integer
          from private.effect_ledger as effect
          where effect.organization_id = event.organization_id
            and effect.operation_id = event.operation_id
            and effect.effect_key = event.idempotency_key
        ) as effects
      from private.outbox_events as event
      where event.id = ${eventId}::uuid
    `;
    await sql`
      select set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'role', 'authenticated',
          'sub', ${ownerUserId}::text
        )::text,
        true
      )
    `;
    const rejectedReplay = await sql<Array<{ result: { status: string } }>>`
      select public.replay_dead_letter(
        ${preserved[0]!.dead_letter_id}::uuid,
        gen_random_uuid(),
        gen_random_uuid()
      ) as result
    `;
    expect(rejectedReplay[0]!.result.status).toBe(
      "rejected_non_replayable",
    );
    const canonicalAfterReplay = await sql`
      select
        event.status,
        event.target_queue,
        event.queue_message_id,
        (
          select count(*)::integer
          from pgmq.q_outbound_whatsapp as queued
          where queued.msg_id = event.queue_message_id
        ) as outbound_queued,
        (
          select count(*)::integer
          from private.effect_ledger as effect
          where effect.organization_id = event.organization_id
            and effect.operation_id = event.operation_id
            and effect.effect_key = event.idempotency_key
        ) as effects
      from private.outbox_events as event
      where event.id = ${eventId}::uuid
    `;
    expect(canonicalAfterReplay).toEqual(canonicalBeforeReplay);

    await sql`
      select set_config(
        'request.jwt.claims',
        '{"role":"service_role"}',
        true
      )
    `;
    await sql`
      select private.consume_outbound_whatsapp(
        1,
        gen_random_uuid(),
        30
      )
    `;
    const completed = await sql<
      Array<{ event_status: string; message_status: string }>
    >`
      select
        event.status as event_status,
        message.status as message_status
      from private.outbox_events as event
      join public.messages as message
        on message.id::text = event.payload ->> 'message_id'
      where event.id = ${eventId}::uuid
    `;
    expect(completed[0]).toEqual({
      event_status: "completed",
      message_status: "captured",
    });
  });
});

test("replay preserva DLQ quando efeito pode estar em voo", async () => {
  const fixtureInbound = await accept(
    event(
      `uncertain-effect-seed-${suffix}`,
      `uncertain-effect-chat-${suffix}`,
    ),
  );
  expect(fixtureInbound.error).toBeNull();
  await drain();

  await database.begin(async (sql) => {
    await sql`select pgmq.purge_queue('outbound_whatsapp')`;
    const conversations = await sql<
      Array<{ id: string; version: number }>
    >`
      select id, version
      from public.conversations
      where connection_id = ${connectionId}::uuid
      order by opened_at, id
      limit 1
    `;
    const conversation = conversations[0]!;
    const fixtures: Array<{
      deadLetterId: string;
      eventId: string;
      state: "outcome_unknown" | "request_started";
    }> = [];

    for (const effectState of [
      "request_started",
      "outcome_unknown",
    ] as const) {
      const messageId = randomUUID();
      const commandId = randomUUID();
      await sql`
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
          idempotency_key,
          created_by_type,
          created_by_membership_id
        )
        values (
          ${messageId}::uuid,
          ${organizationId}::uuid,
          ${operationId}::uuid,
          ${conversation.id}::uuid,
          ${connectionId}::uuid,
          'outbound',
          'text',
          ${`Synthetic ${effectState}`},
          'queued',
          ${commandId}::uuid,
          'human',
          ${ownerMembershipId}::uuid
        )
      `;
      const events = await sql<
        Array<{
          correlation_id: string;
          id: string;
          idempotency_key: string;
          payload_hash: string;
          queue_message_id: number;
          trace_id: string;
        }>
      >`
        with next_sequence as (
          select private.next_aggregate_sequence(
            ${organizationId}::uuid,
            ${operationId}::uuid,
            'conversation',
            ${conversation.id}::uuid
          ) as value
        ),
        payload as (
          select jsonb_build_object(
            'message_id',
            ${messageId}::uuid,
            'conversation_id',
            ${conversation.id}::uuid,
            'connection_id',
            ${connectionId}::uuid
          ) as value
        )
        insert into private.outbox_events (
          organization_id,
          operation_id,
          event_type,
          aggregate_type,
          aggregate_id,
          aggregate_version,
          aggregate_sequence,
          actor_type,
          actor_reference,
          target_queue,
          idempotency_key,
          payload_hash,
          payload,
          trace_id,
          correlation_id
        )
        select
          ${organizationId}::uuid,
          ${operationId}::uuid,
          'message.send_requested.v1',
          'conversation',
          ${conversation.id}::uuid,
          ${conversation.version},
          next_sequence.value,
          'user',
          ${ownerMembershipId},
          'outbound_whatsapp',
          ${`uncertain:${effectState}:${commandId}`},
          encode(
            sha256(convert_to(payload.value::text, 'UTF8')),
            'hex'
          ),
          payload.value,
          gen_random_uuid(),
          gen_random_uuid()
        from next_sequence, payload
        returning
          id,
          idempotency_key,
          payload_hash,
          queue_message_id,
          trace_id,
          correlation_id
      `;
      const event = events[0]!;
      await sql`select private.dispatch_outbox_events(100)`;
      const published = await sql<
        Array<{
          correlation_id: string;
          idempotency_key: string;
          payload_hash: string;
          queue_message_id: number;
          trace_id: string;
        }>
      >`
        select
          idempotency_key,
          payload_hash,
          queue_message_id,
          trace_id,
          correlation_id
        from private.outbox_events
        where id = ${event.id}::uuid
      `;
      const current = published[0]!;
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
          started_at
        )
        values (
          ${organizationId}::uuid,
          ${operationId}::uuid,
          ${current.idempotency_key},
          'message.send_requested.v1',
          ${current.payload_hash},
          ${effectState},
          ${current.trace_id}::uuid,
          ${current.correlation_id}::uuid,
          now()
        )
      `;
      const letters = await sql<Array<{ id: string }>>`
        select private.dead_letter_queue_message(
          'outbound_whatsapp',
          ${current.queue_message_id},
          ${event.id}::uuid,
          ${current.idempotency_key},
          (
            select queued.message
            from pgmq.q_outbound_whatsapp as queued
            where queued.msg_id = ${current.queue_message_id}
          ),
          1,
          'unknown',
          ${`synthetic_${effectState}`},
          ${organizationId}::uuid,
          ${operationId}::uuid,
          ${current.trace_id}::uuid,
          ${current.correlation_id}::uuid
        ) as id
      `;
      await sql`
        update private.outbox_events
        set
          status = 'dead',
          attempts = 1,
          last_error_class = 'unknown',
          last_error_code = ${`synthetic_${effectState}`},
          updated_at = now()
        where id = ${event.id}::uuid
      `;
      fixtures.push({
        deadLetterId: letters[0]!.id,
        eventId: event.id,
        state: effectState,
      });
    }

    await sql`
      select set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'role',
          'authenticated',
          'sub',
          ${ownerUserId}::text
        )::text,
        true
      )
    `;
    for (const fixture of fixtures) {
      const replayed = await sql<
        Array<{ result: { reason: string; status: string } }>
      >`
        select public.replay_dead_letter(
          ${fixture.deadLetterId}::uuid,
          gen_random_uuid(),
          gen_random_uuid()
        ) as result
      `;
      expect(replayed[0]!.result).toEqual(
        expect.objectContaining({
          reason: "effect_outcome_requires_reconciliation",
          status: "rejected_outcome_unknown",
        }),
      );
      const preserved = await sql<
        Array<{
          alert_status: string;
          event_status: string;
          letter_status: string;
          queued: number;
        }>
      >`
        select
          event.status as event_status,
          letter.status as letter_status,
          alert.status as alert_status,
          (
            select count(*)::integer
            from pgmq.q_outbound_whatsapp as queued
            where queued.message ->> 'outbox_event_id' = event.id::text
          ) as queued
        from private.outbox_events as event
        join private.dead_letters as letter
          on letter.envelope_id = event.id
        join private.durable_processing_alerts as alert
          on alert.dead_letter_id = letter.id
        where event.id = ${fixture.eventId}::uuid
          and letter.id = ${fixture.deadLetterId}::uuid
      `;
      expect(preserved[0]).toEqual({
        alert_status: "open",
        event_status: "dead",
        letter_status: "pending",
        queued: 0,
      });
    }
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

test("payload expirado resolve DLQ e replay rejeita sem republicar", async () => {
  const messageId = `payload-expiry-${suffix}`;
  const accepted = await accept(event(messageId, `payload-expiry-${suffix}`));
  expect(accepted.error).toBeNull();

  await database.begin(async (sql) => {
    const inboxes = await sql<
      Array<{
        correlation_id: string;
        id: string;
        organization_id: string;
        queue_message_id: number;
        stream_key: string;
        stream_sequence: number;
        trace_id: string;
      }>
    >`
      select
        id,
        organization_id,
        queue_message_id,
        stream_key,
        stream_sequence,
        trace_id,
        correlation_id
      from private.webhook_inbox
      where connection_id = ${connectionId}::uuid
        and provider_event_id = ${messageId}
      for update
    `;
    const inbox = inboxes[0]!;
    const envelope = {
      correlation_id: inbox.correlation_id,
      inbox_id: inbox.id,
      operation_id: operationId,
      organization_id: inbox.organization_id,
      stream_key: inbox.stream_key,
      stream_sequence: Number(inbox.stream_sequence),
      trace_id: inbox.trace_id,
    };
    const letters = await sql<Array<{ id: string }>>`
      select private.dead_letter_queue_message(
        'inbound_whatsapp',
        ${inbox.queue_message_id},
        ${inbox.id}::uuid,
        ${`webhook:${connectionId}:${messageId}`},
        ${sql.json(envelope)}::jsonb,
        1,
        'non_retryable',
        'synthetic_payload_expiry',
        ${organizationId}::uuid,
        ${operationId}::uuid,
        ${inbox.trace_id}::uuid,
        ${inbox.correlation_id}::uuid
      ) as id
    `;
    const deadLetterId = letters[0]!.id;
    await sql`
      update private.dead_letters
      set created_at = now() - interval '100 years'
      where id = ${deadLetterId}::uuid
    `;
    await sql`
      select private.dead_letter_queue_message(
        'inbound_whatsapp',
        sent.msg_id,
        ${inbox.id}::uuid,
        ${`webhook:${connectionId}:${messageId}:extra:`}
          || fixture.ordinal::text,
        ${sql.json(envelope)}::jsonb,
        1,
        'non_retryable',
        'synthetic_payload_expiry',
        ${organizationId}::uuid,
        ${operationId}::uuid,
        ${inbox.trace_id}::uuid,
        ${inbox.correlation_id}::uuid
      )
      from generate_series(1, 2) as fixture(ordinal)
      cross join lateral pgmq.send(
        'inbound_whatsapp',
        jsonb_build_object(
          'inbox_id',
          ${inbox.id}::uuid,
          'fixture_ordinal',
          fixture.ordinal
        ),
        0
      ) as sent(msg_id)
    `;
    await sql`
      update private.webhook_inbox
      set
        status = 'dead',
        attempts = 1,
        processed_at = null,
        last_error_class = 'non_retryable',
        last_error_code = 'synthetic_payload_expiry',
        updated_at = now() - interval '100 years'
      where id = ${inbox.id}::uuid
    `;
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
    const boundedPrune = await sql<
      Array<{
        result: {
          pending_replays_expired: number;
          raw_webhooks_purged: number;
        };
      }>
    >`
      select private.prune_durable_sensitive_material(1) as result
    `;
    expect(boundedPrune[0]!.result).toEqual(
      expect.objectContaining({
        pending_replays_expired: 1,
      }),
    );
    const boundedState = await sql<
      Array<{
        open_alerts: number;
        pending_letters: number;
        purged: boolean;
        resolved_alerts: number;
        resolved_letters: number;
      }>
    >`
      select
        count(*) filter (
          where letter.status = 'pending'
        )::integer as pending_letters,
        count(*) filter (
          where letter.status = 'resolved'
        )::integer as resolved_letters,
        count(*) filter (
          where alert.status = 'open'
        )::integer as open_alerts,
        count(*) filter (
          where alert.status = 'resolved'
        )::integer as resolved_alerts,
        inbox.raw_payload_purged_at is not null as purged
      from private.webhook_inbox as inbox
      join private.dead_letters as letter
        on letter.envelope_id = inbox.id
        and letter.source_queue = 'inbound_whatsapp'
      join private.durable_processing_alerts as alert
        on alert.dead_letter_id = letter.id
      where inbox.id = ${inbox.id}::uuid
      group by inbox.raw_payload_purged_at
    `;
    expect(boundedState[0]).toEqual({
      open_alerts: 2,
      pending_letters: 2,
      purged: false,
      resolved_alerts: 1,
      resolved_letters: 1,
    });

    const pruned = await sql<
      Array<{
        result: {
          pending_replays_expired: number;
          raw_webhooks_purged: number;
        };
      }>
    >`
      select private.prune_durable_sensitive_material(100) as result
    `;
    expect(pruned[0]!.result.pending_replays_expired).toBeGreaterThanOrEqual(2);
    expect(pruned[0]!.result.raw_webhooks_purged).toBeGreaterThanOrEqual(1);

    await sql`
      select set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'role',
          'authenticated',
          'sub',
          ${ownerUserId}::text
        )::text,
        true
      )
    `;
    const replayed = await sql<
      Array<{ result: { reason: string; status: string } }>
    >`
      select public.replay_dead_letter(
        ${deadLetterId}::uuid,
        gen_random_uuid(),
        gen_random_uuid()
      ) as result
    `;
    expect(replayed[0]!.result).toEqual(
      expect.objectContaining({
        reason: "payload_expired",
        status: "rejected_expired",
      }),
    );

    const state = await sql<
      Array<{
        alert_status: string;
        letter_status: string;
        normalized_payload: unknown;
        queued: number;
        resolution_reason: string;
      }>
    >`
      select
        inbox.normalized_payload,
        letter.status as letter_status,
        letter.resolution_reason,
        alert.status as alert_status,
        (
          select count(*)::integer
          from pgmq.q_inbound_whatsapp as queued
          where queued.message ->> 'inbox_id' = inbox.id::text
        ) as queued
      from private.webhook_inbox as inbox
      join private.dead_letters as letter
        on letter.envelope_id = inbox.id
      join private.durable_processing_alerts as alert
        on alert.dead_letter_id = letter.id
      where inbox.id = ${inbox.id}::uuid
        and letter.id = ${deadLetterId}::uuid
    `;
    expect(state[0]).toEqual({
      alert_status: "resolved",
      letter_status: "resolved",
      normalized_payload: {},
      queued: 0,
      resolution_reason: "payload_expired",
    });
  });
});

test("retenção limita arquivos PGMQ e permite resolver alerta de infraestrutura", async () => {
  await database.begin(async (sql) => {
    await sql`
      do $probe$
      declare
        queue_name text;
        archived_message_id bigint;
      begin
        foreach queue_name in array array[
          'inbound_whatsapp',
          'outbound_whatsapp',
          'scheduled_actions',
          'reconciliation',
          'dead_letter'
        ]
        loop
          archived_message_id := pgmq.send(
            queue_name,
            jsonb_build_object('probe', gen_random_uuid()),
            0
          );
          perform pgmq.archive(queue_name, archived_message_id);
          execute format(
            'update pgmq.%I set archived_at = now() - interval '
              || '''8 days'' where msg_id = $1',
            'a_' || queue_name
          )
          using archived_message_id;
        end loop;
      end
      $probe$
    `;
    const archivePrune = await sql<
      Array<{
        result: {
          a_dead_letter: number;
          a_inbound_whatsapp: number;
          a_outbound_whatsapp: number;
          a_reconciliation: number;
          a_scheduled_actions: number;
          total: number;
        };
      }>
    >`
      select private.prune_t06_queue_archives(
        interval '7 days',
        5
      ) as result
    `;
    expect(archivePrune[0]!.result).toEqual({
      a_dead_letter: 1,
      a_inbound_whatsapp: 1,
      a_outbound_whatsapp: 1,
      a_reconciliation: 1,
      a_scheduled_actions: 1,
      total: 5,
    });

    await sql`
      do $probe$
      declare
        archived_message_id bigint;
      begin
        for fixture_index in 1..3 loop
          archived_message_id := pgmq.send(
            'scheduled_actions',
            jsonb_build_object(
              'probe',
              gen_random_uuid(),
              'fixture_index',
              fixture_index
            ),
            0
          );
          perform pgmq.archive('scheduled_actions', archived_message_id);
          update pgmq.a_scheduled_actions
          set archived_at = now() - interval '8 days'
          where msg_id = archived_message_id;
        end loop;
      end
      $probe$
    `;
    const hotQueuePrune = await sql<
      Array<{
        result: {
          a_scheduled_actions: number;
          total: number;
        };
      }>
    >`
      select private.prune_t06_queue_archives(
        interval '7 days',
        2
      ) as result
    `;
    expect(hotQueuePrune[0]!.result).toEqual(
      expect.objectContaining({
        a_scheduled_actions: 2,
        total: 2,
      }),
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
    let rejectedCode = "";
    try {
      await sql.savepoint(async (savepoint) => {
        await savepoint`
          select public.resolve_infrastructure_durable_alert(
            ${alertId}::uuid,
            null,
            ${correlationId}::uuid
          )
        `;
      });
    } catch (error) {
      rejectedCode = (error as { code?: string }).code ?? "";
    }
    expect(rejectedCode).toBe("22023");
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
        service_audits: number;
      }>
    >`
      select
        alert.status as alert_status,
        alert.resolution_source,
        alert.resolution_trace_id,
        alert.resolution_correlation_id,
        letter.status as dead_letter_status,
        (
          select count(*)::integer
          from private.infrastructure_durable_alert_resolutions as audit
          where audit.alert_id = alert.id
            and audit.resolution_trace_id = ${traceId}::uuid
            and audit.resolution_correlation_id = ${correlationId}::uuid
        ) as service_audits
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
      service_audits: 1,
    });
  });
});

test("resolução e redelivery de alerta de infraestrutura não invertem locks", async () => {
  const deadLetterId = randomUUID();
  const envelopeId = randomUUID();
  const traceId = randomUUID();
  const correlationId = randomUUID();
  const sourceMessageId = (
    800000000000000000n + BigInt(Date.now())
  ).toString();

  await database`
    select private.dead_letter_queue_message(
      'reconciliation',
      ${sourceMessageId}::bigint,
      ${envelopeId}::uuid,
      ${`synthetic:infrastructure-concurrency:${suffix}`},
      '{}'::jsonb,
      1,
      'infrastructure',
      'synthetic_infrastructure_concurrency',
      null,
      null,
      ${traceId}::uuid,
      ${correlationId}::uuid
    )
  `;
  const fixture = await database<Array<{ alert_id: string }>>`
    select alert.id as alert_id
    from private.durable_processing_alerts as alert
    join private.dead_letters as letter
      on letter.id = alert.dead_letter_id
    where letter.source_queue = 'reconciliation'
      and letter.source_message_id = ${sourceMessageId}::bigint
  `;
  const alertId = fixture[0]!.alert_id;
  const deadlocksBefore = await database<Array<{ total: number }>>`
    select deadlocks::integer as total
    from pg_stat_database
    where datname = current_database()
  `;

  for (let attempt = 0; attempt < 20; attempt += 1) {
    await Promise.all([
      database.begin(async (sql) => {
        await sql`
          select set_config(
            'request.jwt.claims',
            '{"role":"service_role"}',
            true
          )
        `;
        await sql`
          select public.resolve_infrastructure_durable_alert(
            ${alertId}::uuid,
            gen_random_uuid(),
            gen_random_uuid()
          )
        `;
      }),
      database.begin(async (sql) => {
        await sql`
          select private.dead_letter_queue_message(
            'reconciliation',
            ${sourceMessageId}::bigint,
            ${envelopeId}::uuid,
            ${`synthetic:infrastructure-concurrency:${suffix}`},
            '{}'::jsonb,
            ${attempt + 2},
            'infrastructure',
            'synthetic_infrastructure_concurrency',
            null,
            null,
            ${traceId}::uuid,
            ${correlationId}::uuid
          )
        `;
      }),
    ]);
  }

  const deadlocksAfter = await database<Array<{ total: number }>>`
    select deadlocks::integer as total
    from pg_stat_database
    where datname = current_database()
  `;
  expect(deadlocksAfter[0]!.total - deadlocksBefore[0]!.total).toBe(0);

  await database.begin(async (sql) => {
    await sql`
      select pgmq.archive('dead_letter', queued.msg_id)
      from pgmq.q_dead_letter as queued
      where queued.message ->> 'dead_letter_id' = ${deadLetterId}::text
    `;
    await sql`
      delete from private.dead_letters
      where source_queue = 'reconciliation'
        and source_message_id = ${sourceMessageId}::bigint
    `;
  });
});
