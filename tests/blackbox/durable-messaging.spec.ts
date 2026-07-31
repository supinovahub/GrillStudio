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
  const accepted = await Promise.all(
    Array.from({ length: 100 }, (_, index) =>
      accept(
        event(
          `ordered-${String(index + 1).padStart(3, "0")}`,
          chatId,
          index + 1,
        ),
      ),
    ),
  );
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
