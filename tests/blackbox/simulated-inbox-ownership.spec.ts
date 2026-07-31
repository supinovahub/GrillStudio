import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const suffix = randomUUID().slice(0, 8);
const password = `Preview-${randomUUID()}-A1!`;
const ownerEmail = `inbox-owner-${suffix}@example.com`;
const managerEmail = `inbox-manager-${suffix}@example.com`;
const brokerEmail = `inbox-broker-${suffix}@example.com`;
const outsiderEmail = `inbox-outsider-${suffix}@example.com`;
const createdUserIds: string[] = [];

let admin: SupabaseClient;
let owner: SupabaseClient;
let manager: SupabaseClient;
let broker: SupabaseClient;
let outsider: SupabaseClient;
let database: Sql;
let organizationId = "";
let operationId = "";
let ownerId = "";
let ownerMembershipId = "";
let managerMembershipId = "";
let secondOperationId = "";
let outsiderOrganizationId = "";
let outsiderOperationId = "";
let connectionId = "";
let conversationId = "";

test.describe.configure({ mode: "serial" });

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for Preview black-box`);
  return value;
}

async function createAuthenticatedClient(email: string) {
  const created = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    password,
  });
  if (created.error) throw new Error(created.error.message);
  createdUserIds.push(created.data.user.id);
  const client = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const signedIn = await client.auth.signInWithPassword({ email, password });
  if (signedIn.error) throw new Error(signedIn.error.message);
  return { client, userId: created.data.user.id };
}

async function insert(table: string, values: Record<string, unknown>) {
  const result = await admin.from(table).insert(values);
  if (result.error) {
    throw new Error(`${table}: ${result.error.code} ${result.error.message}`);
  }
}

function inbound(
  messageId: string,
  chatId: string,
  alias: string,
  phone?: string,
) {
  return {
    provider: "simulator",
    provider_message_id: messageId,
    provider_chat_id: chatId,
    occurred_at: new Date().toISOString(),
    kind: "text",
    text: `Mensagem ${messageId}`,
    identity: {
      aliases: [{ type: "simulator_user", value: alias }],
      display_name: `Lead ${alias}`,
      phone_original: phone ?? null,
    },
  };
}

async function ingest(
  messageId: string,
  chatId = "chat-primary",
  alias = "lead-primary",
  phone?: string,
) {
  const normalizedEvent = inbound(messageId, chatId, alias, phone);
  const accepted = await admin.rpc("ingest_simulated_inbound", {
    normalized_event: normalizedEvent,
    raw_body: JSON.stringify(normalizedEvent),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_connection_id: connectionId,
  });
  if (accepted.error || (accepted.data as { status?: string })?.status === "duplicate") {
    return accepted;
  }

  const worker = await admin.rpc("run_durable_workers", {
    maximum_messages: 25,
  });
  if (worker.error) return worker;

  const messages = await database<
    Array<{
      contact_id: string;
      conversation_id: string;
      message_id: string;
      opportunity_id: string;
      ownership_type: string;
      requires_human_review: boolean;
      version: number;
    }>
  >`
    select
      conversation.contact_id,
      conversation.id as conversation_id,
      message.id as message_id,
      conversation.opportunity_id,
      conversation.ownership_type,
      conversation.requires_human_review,
      conversation.version
    from public.messages as message
    join public.conversations as conversation
      on conversation.id = message.conversation_id
    where message.connection_id = ${connectionId}::uuid
      and message.provider_message_id = ${messageId}
  `;
  if (messages[0]) {
    return {
      data: {
        ...messages[0],
        status: "received",
      },
      error: null,
    };
  }

  const reviews = await database<Array<{ reason: string }>>`
    select reason
    from private.simulator_inbound_reviews
    where connection_id = ${connectionId}::uuid
      and provider_message_id = ${messageId}
  `;
  return {
    data: {
      reason: reviews[0]?.reason,
      status: "requires_review",
    },
    error: null,
  };
}

async function version(targetConversationId: string): Promise<number> {
  const rows = await database<{ version: number }[]>`
    select version
    from public.conversations
    where id = ${targetConversationId}::uuid
  `;
  return Number(rows[0]!.version);
}

async function assume(
  client: SupabaseClient,
  targetConversationId: string,
  expectedVersion: number,
) {
  return client.rpc("assume_conversation", {
    expected_version: expectedVersion,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: targetConversationId,
  });
}

async function pause(
  client: SupabaseClient,
  targetConversationId: string,
  expectedVersion: number,
  reason: string,
) {
  return client.rpc("pause_conversation", {
    expected_version: expectedVersion,
    pause_reason: reason,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: targetConversationId,
  });
}

async function returnToPedro(
  client: SupabaseClient,
  targetConversationId: string,
  expectedVersion: number,
  mode = "shadow",
) {
  return client.rpc("return_conversation_to_pedro", {
    expected_version: expectedVersion,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    return_action: "resume_service",
    target_automation_mode: mode,
    target_conversation_id: targetConversationId,
  });
}

async function createManagerFixture(label: string, whatsapp: string) {
  const email = `inbox-${label}-${randomUUID().slice(0, 8)}@example.com`;
  const identity = await createAuthenticatedClient(email);
  const membershipId = randomUUID();
  await insert("memberships", {
    id: membershipId,
    organization_id: organizationId,
    role: "manager",
    status: "active",
    user_id: identity.userId,
  });
  await insert("membership_operations", {
    membership_id: membershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insert("membership_permissions", {
    granted_by_user_id: ownerId,
    membership_id: membershipId,
    organization_id: organizationId,
    permission: "manage_conversations",
  });
  await insert("staff_profiles", {
    full_name: `Gestor ${label}`,
    membership_id: membershipId,
    organization_id: organizationId,
    whatsapp,
  });
  return { client: identity.client, membershipId };
}

async function waitForMembershipOwnershipLock(membershipId: string) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    const rows = await database<Array<{ acquired: boolean }>>`
      select pg_try_advisory_xact_lock(
        hashtextextended(
          'membership-ownership:' || ${membershipId}::text,
          0
        )
      ) as acquired
    `;
    if (!rows[0]!.acquired) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Conversation command did not acquire Membership lock");
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
    max: 2,
    prepare: false,
  });

  const ownerIdentity = await createAuthenticatedClient(ownerEmail);
  owner = ownerIdentity.client;
  ownerId = ownerIdentity.userId;
  const managerIdentity = await createAuthenticatedClient(managerEmail);
  manager = managerIdentity.client;
  const brokerIdentity = await createAuthenticatedClient(brokerEmail);
  broker = brokerIdentity.client;
  const outsiderIdentity = await createAuthenticatedClient(outsiderEmail);
  outsider = outsiderIdentity.client;

  organizationId = randomUUID();
  operationId = randomUUID();
  connectionId = randomUUID();
  secondOperationId = randomUUID();
  outsiderOrganizationId = randomUUID();
  outsiderOperationId = randomUUID();
  ownerMembershipId = randomUUID();
  managerMembershipId = randomUUID();

  await insert("organizations", {
    id: organizationId,
    name: `Imobiliária Inbox ${suffix}`,
    slug: `preview-inbox-${suffix}`,
  });
  await insert("operations", {
    id: operationId,
    is_default: true,
    name: `Operação Inbox ${suffix}`,
    organization_id: organizationId,
  });
  await insert("operation_settings", {
    operation_id: operationId,
    organization_id: organizationId,
    production_enabled: false,
  });
  await insert("operations", {
    id: secondOperationId,
    is_default: false,
    name: `Operação sem acesso ${suffix}`,
    organization_id: organizationId,
  });
  await insert("operation_settings", {
    operation_id: secondOperationId,
    organization_id: organizationId,
  });
  await insert("memberships", {
    id: ownerMembershipId,
    organization_id: organizationId,
    role: "owner",
    status: "active",
    user_id: ownerId,
  });
  await insert("membership_operations", {
    membership_id: ownerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insert("staff_profiles", {
    full_name: "Dono Inbox",
    membership_id: ownerMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511999990001",
  });
  await insert("memberships", {
    id: managerMembershipId,
    organization_id: organizationId,
    role: "manager",
    status: "active",
    user_id: managerIdentity.userId,
  });
  await insert("membership_operations", {
    membership_id: managerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insert("membership_permissions", {
    granted_by_user_id: ownerId,
    membership_id: managerMembershipId,
    organization_id: organizationId,
    permission: "manage_conversations",
  });
  await insert("staff_profiles", {
    full_name: "Gestor Inbox",
    membership_id: managerMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511999990002",
  });
  const brokerMembershipId = randomUUID();
  await insert("memberships", {
    id: brokerMembershipId,
    organization_id: organizationId,
    role: "broker",
    status: "active",
    user_id: brokerIdentity.userId,
  });
  await insert("membership_operations", {
    membership_id: brokerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insert("staff_profiles", {
    full_name: "Corretor Inbox",
    membership_id: brokerMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511999990003",
  });
  await insert("organizations", {
    id: outsiderOrganizationId,
    name: `Imobiliária externa ${suffix}`,
    slug: `preview-inbox-outsider-${suffix}`,
  });
  await insert("operations", {
    id: outsiderOperationId,
    is_default: true,
    name: `Operação externa ${suffix}`,
    organization_id: outsiderOrganizationId,
  });
  await insert("operation_settings", {
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
  });
  const outsiderMembershipId = randomUUID();
  await insert("memberships", {
    id: outsiderMembershipId,
    organization_id: outsiderOrganizationId,
    role: "owner",
    status: "active",
    user_id: outsiderIdentity.userId,
  });
  await insert("membership_operations", {
    membership_id: outsiderMembershipId,
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
  });
  await insert("whatsapp_connections", {
    adapter_type: "simulator",
    display_name: "Simulador Preview",
    id: connectionId,
    is_test: true,
    operation_id: operationId,
    organization_id: organizationId,
    provider_connection_id: `preview-${suffix}`,
  });
});

test.afterAll(async () => {
  if (!admin) return;
  for (const userId of createdUserIds) {
    await admin.auth.admin.deleteUser(userId);
  }
  await admin
    .from("operations")
    .delete()
    .in("id", [operationId, secondOperationId, outsiderOperationId]);
  await admin.from("organizations").delete().eq("id", organizationId);
  await admin
    .from("organizations")
    .delete()
    .eq("id", outsiderOrganizationId);
  await database.end();
});

test("materializa inbound idempotente e prende a Conversa à origem", async () => {
  const first = await ingest("message-primary");
  expect(first.error).toBeNull();
  const received = first.data as {
    conversation_id: string;
    ownership_type: string;
    status: string;
  };
  expect(received.status).toBe("received");
  expect(received.ownership_type).toBe("pedro");
  conversationId = received.conversation_id;

  const duplicate = await ingest("message-primary");
  expect(duplicate.error).toBeNull();
  expect((duplicate.data as { status: string }).status).toBe("duplicate");

  const rows = await database<
    Array<{
      connection_id: string;
      message_count: number;
      provider_chat_id: string;
    }>
  >`
    select
      conversation.connection_id,
      conversation.provider_chat_id,
      count(message.id)::integer as message_count
    from public.conversations as conversation
    join public.messages as message
      on message.conversation_id = conversation.id
    where conversation.id = ${conversationId}::uuid
    group by conversation.id
  `;
  expect(rows[0]).toMatchObject({
    connection_id: connectionId,
    message_count: 1,
    provider_chat_id: "chat-primary",
  });

  const inboundAudit = await database<Array<{ count: number }>>`
    select count(*)::integer as count
    from audit.audit_events
    where action = 'message.inbound_received'
      and target_id = (
        select id
        from public.messages
        where conversation_id = ${conversationId}::uuid
          and provider_message_id = 'message-primary'
      )
      and after_state ->> 'provider_message_id_hash' is not null
      and after_state::text not like '%message-primary%'
  `;
  expect(inboundAudit[0]!.count).toBe(1);

  const inbox = await owner.rpc("get_inbox_list", {
    target_operation_id: operationId,
  });
  expect(inbox.error).toBeNull();
  expect(inbox.data).toEqual(
    expect.arrayContaining([
      expect.objectContaining({
        connection_id: connectionId,
        id: conversationId,
        origin: "simulator",
        ownership_type: "pedro",
      }),
    ]),
  );
});

test("Ownership versiona, pausa só Pedro e audita sem texto livre", async () => {
  const startingVersion = await version(conversationId);
  const assumed = await assume(owner, conversationId, startingVersion);
  expect(assumed.error).toBeNull();
  expect(assumed.data).toEqual(
    expect.objectContaining({
      owner_membership_id: ownerMembershipId,
      ownership_type: "human",
    }),
  );

  const stale = await assume(owner, conversationId, startingVersion);
  expect(stale.error).not.toBeNull();

  const production = await returnToPedro(
    owner,
    conversationId,
    await version(conversationId),
    "production",
  );
  expect(production.error?.message).toContain("production mode gate is closed");

  const returned = await returnToPedro(
    owner,
    conversationId,
    await version(conversationId),
  );
  expect(returned.error).toBeNull();
  expect(returned.data).toEqual(
    expect.objectContaining({ ownership_type: "pedro", pending_return: false }),
  );

  const pauseInbound = await ingest(
    "message-pause",
    "chat-pause",
    "lead-pause",
  );
  expect(pauseInbound.error).toBeNull();
  const pauseTargetId = (pauseInbound.data as { conversation_id: string })
    .conversation_id;
  const pauseReason = "Revisar CPF 123.456.789-00 antes de continuar";
  const paused = await pause(
    owner,
    pauseTargetId,
    await version(pauseTargetId),
    pauseReason,
  );
  expect(paused.error).toBeNull();
  expect(paused.data).toEqual(
    expect.objectContaining({
      is_paused: true,
      owner_membership_id: ownerMembershipId,
      ownership_type: "human",
    }),
  );

  const responseWhilePaused = await owner.rpc("send_human_message", {
    command_id: randomUUID(),
    expected_version: await version(pauseTargetId),
    message_text: "O gestor continua respondendo com Pedro pausado.",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: pauseTargetId,
  });
  expect(responseWhilePaused.error).toBeNull();

  const pausedState = await database<
    Array<{ is_paused: boolean; pause_reason: string }>
  >`
    select is_paused, pause_reason
    from public.conversations
    where id = ${pauseTargetId}::uuid
  `;
  expect(pausedState[0]).toEqual({
    is_paused: true,
    pause_reason: pauseReason,
  });

  const pauseAudit = await database<
    Array<{ after_state: Record<string, unknown> }>
  >`
    select after_state
    from audit.audit_events
    where target_id = ${pauseTargetId}::uuid
      and action = 'conversation.paused'
  `;
  expect(pauseAudit).toHaveLength(1);
  expect(pauseAudit[0]!.after_state).toMatchObject({
    operational_reason_recorded: true,
    reason_code: "human_requested_pause",
  });
  expect(JSON.stringify(pauseAudit[0]!.after_state)).not.toContain(pauseReason);
  expect(JSON.stringify(pauseAudit[0]!.after_state)).not.toContain(
    "123.456.789-00",
  );

  const commandAudit = await database<
    Array<{ action: string; count: number }>
  >`
    select action, count(*)::integer as count
    from audit.audit_events
    where (
      target_id = ${conversationId}::uuid
      and action in (
        'conversation.assumed',
        'conversation.returned_to_pedro'
      )
    ) or (
      target_id = ${pauseTargetId}::uuid
      and action = 'conversation.paused'
    )
    group by action
  `;
  expect(commandAudit).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ action: "conversation.assumed" }),
      expect.objectContaining({ action: "conversation.paused" }),
      expect.objectContaining({ action: "conversation.returned_to_pedro" }),
    ]),
  );
});

test("nega broker, gestor sem permissão, outsider e cross-operation", async () => {
  const brokerInbox = await broker.rpc("get_inbox_list", {
    target_operation_id: operationId,
  });
  expect(brokerInbox.error?.code).toBe("42501");

  const permissionRemoved = await admin
    .from("membership_permissions")
    .delete()
    .eq("membership_id", managerMembershipId)
    .eq("permission", "manage_conversations");
  expect(permissionRemoved.error).toBeNull();
  const managerInbox = await manager.rpc("get_inbox_list", {
    target_operation_id: operationId,
  });
  expect(managerInbox.error?.code).toBe("42501");
  await insert("membership_permissions", {
    granted_by_user_id: ownerId,
    membership_id: managerMembershipId,
    organization_id: organizationId,
    permission: "manage_conversations",
  });

  const outsiderInbox = await outsider.rpc("get_inbox_list", {
    target_operation_id: operationId,
  });
  expect(outsiderInbox.error?.code).toBe("42501");
  const crossOperation = await owner.rpc("get_inbox_list", {
    target_operation_id: secondOperationId,
  });
  expect(crossOperation.error?.code).toBe("42501");

  const brokerRows = await broker
    .from("messages")
    .select("id")
    .eq("conversation_id", conversationId);
  expect(brokerRows.error).toBeNull();
  expect(brokerRows.data).toEqual([]);
  const brokerWrite = await broker.from("messages").insert({
    connection_id: connectionId,
    conversation_id: conversationId,
    created_by_type: "human",
    direction: "outbound",
    idempotency_key: randomUUID(),
    kind: "text",
    operation_id: operationId,
    organization_id: organizationId,
    status: "captured",
  });
  expect(brokerWrite.error).not.toBeNull();
});

test("duas assunções concorrentes produzem um único escritor", async () => {
  const incoming = await ingest(
    "message-concurrency",
    "chat-concurrency",
    "lead-concurrency",
  );
  expect(incoming.error).toBeNull();
  const targetId = (incoming.data as { conversation_id: string })
    .conversation_id;
  const expectedVersion = await version(targetId);
  const results = await Promise.all([
    assume(owner, targetId, expectedVersion),
    assume(manager, targetId, expectedVersion),
  ]);
  expect(results.filter((result) => !result.error)).toHaveLength(1);
  expect(results.filter((result) => result.error)).toHaveLength(1);

  const writer = await database<
    Array<{ assigned_membership_id: string; ownership_type: string }>
  >`
    select ownership_type, assigned_membership_id
    from public.conversations
    where id = ${targetId}::uuid
  `;
  expect(writer[0]!.ownership_type).toBe("human");
  expect([ownerMembershipId, managerMembershipId]).toContain(
    writer[0]!.assigned_membership_id,
  );
});

test("origem é imutável e uma segunda conexão não repina a primeira", async () => {
  const secondConnectionId = randomUUID();
  await insert("whatsapp_connections", {
    adapter_type: "simulator",
    display_name: "Segundo simulador",
    id: secondConnectionId,
    is_test: true,
    operation_id: operationId,
    organization_id: organizationId,
    provider_connection_id: `preview-second-${suffix}`,
  });

  const mutation = await database`
    update public.conversations
    set connection_id = ${secondConnectionId}::uuid
    where id = ${conversationId}::uuid
  `.catch((error: unknown) => error);
  expect(mutation).toBeInstanceOf(Error);

  const secondConnectionEvent = inbound(
    "message-second-connection",
    "chat-primary",
    "lead-primary",
  );
  const result = await admin.rpc("ingest_simulated_inbound", {
    normalized_event: secondConnectionEvent,
    raw_body: JSON.stringify(secondConnectionEvent),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_connection_id: secondConnectionId,
  });
  expect(result.error).toBeNull();
  expect((result.data as { status: string }).status).toBe("accepted");
  const secondWorker = await admin.rpc("run_durable_workers", {
    maximum_messages: 25,
  });
  expect(secondWorker.error).toBeNull();
  const secondConversation = await database<Array<{ id: string }>>`
    select id
    from public.conversations
    where connection_id = ${secondConnectionId}::uuid
      and provider_chat_id = 'chat-primary'
      and status in ('active', 'sleeping')
  `;
  const secondConversationId = secondConversation[0]!.id;
  expect(secondConversationId).not.toBe(conversationId);

  const origins = await database<
    Array<{ connection_id: string; id: string }>
  >`
    select id, connection_id
    from public.conversations
    where id in (
      ${conversationId}::uuid,
      ${secondConversationId}::uuid
    )
    order by id
  `;
  expect(origins).toEqual(
    expect.arrayContaining([
      { connection_id: connectionId, id: conversationId },
      { connection_id: secondConnectionId, id: secondConversationId },
    ]),
  );

  const sharedPhone = "+55 11 98765-4321";
  const primaryPhoneEvent = inbound(
    "message-phone-race-primary",
    "chat-phone-race-primary",
    "lead-phone-race-primary",
    sharedPhone,
  );
  const secondaryPhoneEvent = inbound(
    "message-phone-race-secondary",
    "chat-phone-race-secondary",
    "lead-phone-race-secondary",
    sharedPhone,
  );
  const concurrentIdentity = await Promise.all([
    admin.rpc("ingest_simulated_inbound", {
      normalized_event: primaryPhoneEvent,
      raw_body: JSON.stringify(primaryPhoneEvent),
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_connection_id: connectionId,
    }),
    admin.rpc("ingest_simulated_inbound", {
      normalized_event: secondaryPhoneEvent,
      raw_body: JSON.stringify(secondaryPhoneEvent),
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_connection_id: secondConnectionId,
    }),
  ]);
  expect(concurrentIdentity.every((item) => item.error === null)).toBe(true);
  expect(
    concurrentIdentity.map((item) => (item.data as { status: string }).status),
  ).toEqual(["accepted", "accepted"]);
  const identityWorker = await admin.rpc("run_durable_workers", {
    maximum_messages: 25,
  });
  expect(identityWorker.error).toBeNull();

  const canonicalIdentity = await database<
    Array<{ contacts: number; identities: number; phones: number }>
  >`
    select
      count(distinct identity.contact_id)::integer as contacts,
      count(distinct identity.id)::integer as identities,
      count(distinct phone.id)::integer as phones
    from public.contact_phones as phone
    join public.provider_identities as identity
      on identity.contact_id = phone.contact_id
    where phone.organization_id = ${organizationId}::uuid
      and phone.e164 = '+5511987654321'
      and identity.connection_id in (
        ${connectionId}::uuid,
        ${secondConnectionId}::uuid
      )
  `;
  expect(canonicalIdentity[0]).toEqual({
    contacts: 1,
    identities: 2,
    phones: 1,
  });
});

test("conflito alias/telefone exige revisão sem auto-merge", async () => {
  const aliasContactId = randomUUID();
  const phoneContactId = randomUUID();
  const identityId = randomUUID();
  await insert("contacts", {
    display_name: "Contato por alias",
    id: aliasContactId,
    organization_id: organizationId,
  });
  await insert("contacts", {
    display_name: "Contato por telefone",
    id: phoneContactId,
    organization_id: organizationId,
  });
  await insert("contact_phones", {
    contact_id: phoneContactId,
    e164: "+5511999990020",
    is_primary: true,
    organization_id: organizationId,
    original_value: "+55 11 99999-0020",
  });
  await insert("provider_identities", {
    connection_id: connectionId,
    contact_id: aliasContactId,
    first_seen_at: new Date().toISOString(),
    id: identityId,
    last_seen_at: new Date().toISOString(),
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insert("provider_identity_aliases", {
    alias_type: "simulator_user",
    alias_value: "identity-conflict",
    connection_id: connectionId,
    operation_id: operationId,
    organization_id: organizationId,
    provider_identity_id: identityId,
    valid_from: new Date().toISOString(),
  });

  const result = await ingest(
    "message-identity-conflict",
    "chat-identity-conflict",
    "identity-conflict",
    "+55 11 99999-0020",
  );
  expect(result.error).toBeNull();
  const targetId = (result.data as { conversation_id: string })
    .conversation_id;
  const review = await database<
    Array<{
      contact_id: string;
      is_paused: boolean;
      requires_human_review: boolean;
      review_reason: string;
    }>
  >`
    select
      contact_id,
      is_paused,
      requires_human_review,
      review_reason
    from public.conversations
    where id = ${targetId}::uuid
  `;
  expect(review[0]).toEqual({
    contact_id: aliasContactId,
    is_paused: true,
    requires_human_review: true,
    review_reason: "identity_phone_conflict",
  });
  const contacts = await database<Array<{ id: string; status: string }>>`
    select id, status
    from public.contacts
    where id in (${aliasContactId}::uuid, ${phoneContactId}::uuid)
    order by id
  `;
  expect(contacts).toHaveLength(2);
  expect(contacts.every((contact) => contact.status === "active")).toBe(true);

  await insert("opportunities", {
    contact_id: aliasContactId,
    operation_id: operationId,
    organization_id: organizationId,
    source_type: "ambiguity_fixture",
    stage: "new",
  });
  const ambiguous = await ingest(
    "message-ambiguous-opportunity",
    "chat-ambiguous-opportunity",
    "identity-conflict",
  );
  expect(ambiguous.error).toBeNull();
  expect(ambiguous.data).toEqual(
    expect.objectContaining({
      reason: "ambiguous_opportunity",
      status: "requires_review",
    }),
  );
  const storedReview = await database<Array<{ count: number }>>`
    select count(*)::integer as count
    from private.simulator_inbound_reviews
    where connection_id = ${connectionId}::uuid
      and provider_message_id = 'message-ambiguous-opportunity'
      and reason = 'ambiguous_opportunity'
  `;
  expect(storedReview[0]!.count).toBe(1);
});

test("lost usa o helper T04 e purchased permanece fechado", async () => {
  const lostContactId = randomUUID();
  const lostOpportunityId = randomUUID();
  const lostIdentityId = randomUUID();
  const purchasedContactId = randomUUID();
  const purchasedOpportunityId = randomUUID();
  const purchasedIdentityId = randomUUID();

  for (const fixture of [
    {
      alias: "lost-return",
      contactId: lostContactId,
      identityId: lostIdentityId,
      opportunityId: lostOpportunityId,
      stage: "lost",
    },
    {
      alias: "purchased-return",
      contactId: purchasedContactId,
      identityId: purchasedIdentityId,
      opportunityId: purchasedOpportunityId,
      stage: "purchased",
    },
  ]) {
    await insert("contacts", {
      display_name: fixture.alias,
      id: fixture.contactId,
      organization_id: organizationId,
    });
    await insert("opportunities", {
      contact_id: fixture.contactId,
      id: fixture.opportunityId,
      loss_reason: fixture.stage === "lost" ? "Sem resposta" : null,
      operation_id: operationId,
      organization_id: organizationId,
      source_type: "terminal_fixture",
      stage: fixture.stage,
    });
    await insert("provider_identities", {
      connection_id: connectionId,
      contact_id: fixture.contactId,
      first_seen_at: new Date().toISOString(),
      id: fixture.identityId,
      last_seen_at: new Date().toISOString(),
      operation_id: operationId,
      organization_id: organizationId,
    });
    await insert("provider_identity_aliases", {
      alias_type: "simulator_user",
      alias_value: fixture.alias,
      connection_id: connectionId,
      operation_id: operationId,
      organization_id: organizationId,
      provider_identity_id: fixture.identityId,
      valid_from: new Date().toISOString(),
    });
  }

  const lost = await ingest(
    "message-lost-return",
    "chat-lost-return",
    "lost-return",
  );
  expect(lost.error).toBeNull();
  expect((lost.data as { opportunity_id: string }).opportunity_id).toBe(
    lostOpportunityId,
  );
  const lostStage = await database<Array<{ stage: string }>>`
    select stage
    from public.opportunities
    where id = ${lostOpportunityId}::uuid
  `;
  expect(lostStage[0]!.stage).toBe("in_service");

  const purchased = await ingest(
    "message-purchased-return",
    "chat-purchased-return",
    "purchased-return",
  );
  expect(purchased.error).toBeNull();
  expect((purchased.data as { opportunity_id: string }).opportunity_id).not.toBe(
    purchasedOpportunityId,
  );
  const purchasedStage = await database<Array<{ stage: string }>>`
    select stage
    from public.opportunities
    where id = ${purchasedOpportunityId}::uuid
  `;
  expect(purchasedStage[0]!.stage).toBe("purchased");
});

test("pin CAS de um cadastro manual preserva o humano", async () => {
  const manual = await owner.rpc("create_manual_lead", {
    amount_scope_value: "per_unit",
    internal_note_value: "",
    lead_name: "Lead manual",
    lead_source: "teste sintético",
    participant_name: "",
    participant_phone_original: "",
    pedro_context_value: "",
    phone_original: "+5511999990010",
    registration_action: "assume",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    unit_count_value: 1,
  });
  expect(manual.error).toBeNull();
  const manualIds = manual.data as {
    conversation_id: string;
    opportunity_id: string;
  };

  const received = await ingest(
    "message-manual",
    "chat-manual",
    "lead-manual",
    "+55 (11) 99999-0010",
  );
  expect(received.error).toBeNull();
  expect(received.data).toEqual(
    expect.objectContaining({
      conversation_id: manualIds.conversation_id,
      ownership_type: "human",
    }),
  );

  const pinned = await database<
    Array<{ assigned_membership_id: string; connection_id: string }>
  >`
    select assigned_membership_id, connection_id
    from public.conversations
    where id = ${manualIds.conversation_id}::uuid
  `;
  expect(pinned[0]).toEqual({
    assigned_membership_id: ownerMembershipId,
    connection_id: connectionId,
  });
});

test("retorno cheio fica pendente e resposta humana cancela uma única vez", async () => {
  await database`
    with generated as (
      select generate_series(1, 30) as item
    ),
    contacts as (
      insert into public.contacts (organization_id, display_name)
      select ${organizationId}::uuid, 'Capacidade ' || item
      from generated
      returning id
    ),
    opportunities as (
      insert into public.opportunities (
        organization_id, operation_id, contact_id, stage, source_type
      )
      select
        ${organizationId}::uuid,
        ${operationId}::uuid,
        contact.id,
        'new',
        'capacity_fixture'
      from contacts as contact
      returning id, contact_id
    )
    insert into public.conversations (
      organization_id, operation_id, contact_id, opportunity_id,
      status, ownership_type, automation_mode
    )
    select
      ${organizationId}::uuid,
      ${operationId}::uuid,
      opportunity.contact_id,
      opportunity.id,
      'active',
      'pedro',
      'shadow'
    from opportunities as opportunity
  `;

  const assumed = await assume(owner, conversationId, await version(conversationId));
  expect(assumed.error).toBeNull();
  const pending = await returnToPedro(
    owner,
    conversationId,
    await version(conversationId),
  );
  expect(pending.error).toBeNull();
  expect(pending.data).toEqual(
    expect.objectContaining({ ownership_type: "human", pending_return: true }),
  );

  const commandId = randomUUID();
  const expectedVersion = await version(conversationId);
  const first = await owner.rpc("send_human_message", {
    command_id: commandId,
    expected_version: expectedVersion,
    message_text: "Resposta sintética idempotente",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: conversationId,
  });
  expect(first.error).toBeNull();
  expect(first.data).toEqual(
    expect.objectContaining({ pending_cancelled: true, status: "queued" }),
  );

  const outboundWorker = await admin.rpc("run_durable_workers", {
    maximum_messages: 25,
  });
  expect(outboundWorker.error).toBeNull();

  const duplicate = await owner.rpc("send_human_message", {
    command_id: commandId,
    expected_version: expectedVersion,
    message_text: "Resposta sintética idempotente",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: conversationId,
  });
  expect(duplicate.error).toBeNull();
  expect(duplicate.data).toEqual(expect.objectContaining({ status: "duplicate" }));

  async function replayStatus(client: SupabaseClient, messageText: string) {
    const session = await client.auth.getSession();
    expect(session.error).toBeNull();
    const accessToken = session.data.session?.access_token;
    expect(accessToken).toBeTruthy();
    return fetch(
      `${requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL")}/rest/v1/rpc/send_human_message`,
      {
        body: JSON.stringify({
          command_id: commandId,
          expected_version: expectedVersion,
          message_text: messageText,
          request_correlation_id: randomUUID(),
          request_trace_id: randomUUID(),
          target_conversation_id: conversationId,
        }),
        headers: {
          apikey: requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
          authorization: `Bearer ${accessToken}`,
          "content-type": "application/json",
        },
        method: "POST",
      },
    );
  }

  const divergentPayload = await replayStatus(
    owner,
    "Mesmo command_id com outro conteúdo",
  );
  expect(divergentPayload.status).toBe(409);
  const divergentActor = await replayStatus(
    manager,
    "Resposta sintética idempotente",
  );
  expect(divergentActor.status).toBe(409);

  const counts = await database<Array<{ captures: number; messages: number }>>`
    select
      (
        select count(*)::integer
        from private.simulator_outbound_captures
        where conversation_id = ${conversationId}::uuid
      ) as captures,
      (
        select count(*)::integer
        from public.messages
        where conversation_id = ${conversationId}::uuid
          and idempotency_key = ${commandId}::uuid
      ) as messages
  `;
  expect(counts[0]).toEqual({ captures: 1, messages: 1 });
  const captureBoundary = await database<
    Array<{
      columns: string[];
      egress_attempted: boolean;
      provider_chat_id: string;
    }>
  >`
    select
      (
        select array_agg(column_name order by ordinal_position)
        from information_schema.columns
        where table_schema = 'private'
          and table_name = 'simulator_outbound_captures'
      ) as columns,
      capture.provider_chat_id,
      (audit.after_state ->> 'egress_attempted')::boolean
        as egress_attempted
    from private.simulator_outbound_captures as capture
    join audit.audit_events as audit
      on audit.target_id = capture.message_id
      and audit.action = 'message.outbound_captured'
    where capture.conversation_id = ${conversationId}::uuid
      and capture.message_id = (
        select id
        from public.messages
        where conversation_id = ${conversationId}::uuid
          and idempotency_key = ${commandId}::uuid
      )
  `;
  expect(captureBoundary[0]!.columns).not.toContain("recipient");
  expect(captureBoundary[0]).toMatchObject({
    egress_attempted: false,
    provider_chat_id: "chat-primary",
  });

  const secondCommand = randomUUID();
  const exactBoundary = "x".repeat(12_000);
  const second = await owner.rpc("send_human_message", {
    command_id: secondCommand,
    expected_version: await version(conversationId),
    message_text: exactBoundary,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: conversationId,
  });
  expect(second.error).toBeNull();

  const storedBoundary = await database<Array<{ body: string }>>`
    select body
    from public.messages
    where conversation_id = ${conversationId}::uuid
      and idempotency_key = ${secondCommand}::uuid
  `;
  expect(storedBoundary[0]!.body).toBe(exactBoundary);

  await database`
    update public.conversations
    set version = version + 1, updated_at = now()
    where id = ${conversationId}::uuid
  `;
  const staleWorker = await admin.rpc("run_durable_workers", {
    maximum_messages: 25,
  });
  expect(staleWorker.error).toBeNull();
  const suppressed = await database<
    Array<{
      audit_status: string;
      captures: number;
      effect_state: string;
      message_status: string;
      outbox_status: string;
    }>
  >`
    select
      message.status as message_status,
      event.status as outbox_status,
      effect.state as effect_state,
      audit.after_state ->> 'status' as audit_status,
      (
        select count(*)::integer
        from private.simulator_outbound_captures as capture
        where capture.message_id = message.id
      ) as captures
    from public.messages as message
    join private.outbox_events as event
      on event.payload ->> 'message_id' = message.id::text
    join private.effect_ledger as effect
      on effect.organization_id = event.organization_id
      and effect.operation_id = event.operation_id
      and effect.effect_key = event.idempotency_key
    join audit.audit_events as audit
      on audit.target_id = message.id
      and audit.action = 'message.outbound_suppressed'
    where message.conversation_id = ${conversationId}::uuid
      and message.idempotency_key = ${secondCommand}::uuid
  `;
  expect(suppressed[0]).toEqual({
    audit_status: "suppressed",
    captures: 0,
    effect_state: "suppressed",
    message_status: "suppressed",
    outbox_status: "completed",
  });

  const replayCommand = randomUUID();
  const replayQueued = await owner.rpc("send_human_message", {
    command_id: replayCommand,
    expected_version: await version(conversationId),
    message_text: "Comando sintético para replay",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: conversationId,
  });
  expect(replayQueued.error).toBeNull();
  const replayFixture = await database.begin(async (sql) => {
    await sql`select private.dispatch_outbox_events(25)`;
    const events = await sql<
      Array<{
        aggregate_id: string;
        aggregate_sequence: number;
        aggregate_type: string;
        aggregate_version: number;
        correlation_id: string;
        effect_key: string;
        id: string;
        operation_id: string;
        organization_id: string;
        queue_message_id: number;
        trace_id: string;
      }>
    >`
      select
        event.id,
        event.organization_id,
        event.operation_id,
        event.aggregate_type,
        event.aggregate_id,
        event.aggregate_version,
        event.aggregate_sequence,
        event.idempotency_key as effect_key,
        event.queue_message_id,
        event.trace_id,
        event.correlation_id
      from private.outbox_events as event
      join public.messages as message
        on message.id::text = event.payload ->> 'message_id'
      where message.idempotency_key = ${replayCommand}::uuid
      for update of event
    `;
    const event = events[0]!;
    const letters = await sql<Array<{ dead_letter_id: string }>>`
      select private.dead_letter_queue_message(
        'outbound_whatsapp',
        ${event.queue_message_id},
        ${event.id}::uuid,
        ${event.effect_key},
        jsonb_build_object(
          'outbox_event_id', ${event.id}::uuid,
          'organization_id', ${event.organization_id}::uuid,
          'operation_id', ${event.operation_id}::uuid,
          'aggregate_type', ${event.aggregate_type},
          'aggregate_id', ${event.aggregate_id}::uuid,
          'aggregate_version', ${event.aggregate_version},
          'aggregate_sequence', ${event.aggregate_sequence},
          'effect_key', ${event.effect_key},
          'trace_id', ${event.trace_id}::uuid,
          'correlation_id', ${event.correlation_id}::uuid
        ),
        1,
        'non_retryable',
        'synthetic_replay_fixture',
        ${event.organization_id}::uuid,
        ${event.operation_id}::uuid,
        ${event.trace_id}::uuid,
        ${event.correlation_id}::uuid
      ) as dead_letter_id
    `;
    await sql`
      update private.outbox_events
      set
        status = 'dead',
        attempts = 1,
        last_error_class = 'non_retryable',
        last_error_code = 'synthetic_replay_fixture',
        updated_at = now()
      where id = ${event.id}::uuid
    `;
    return {
      deadLetterId: letters[0]!.dead_letter_id,
      eventId: event.id,
    };
  });
  const replayed = await owner.rpc("replay_dead_letter", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_dead_letter_id: replayFixture.deadLetterId,
  });
  expect(replayed.error).toBeNull();
  expect(replayed.data).toEqual(expect.objectContaining({ status: "replayed" }));
  const replayState = await database<
    Array<{ alert_status: string; attempts: number; event_status: string }>
  >`
    select
      event.status as event_status,
      event.attempts,
      alert.status as alert_status
    from private.outbox_events as event
    join private.dead_letters as letter
      on letter.envelope_id = event.id
    join private.durable_processing_alerts as alert
      on alert.dead_letter_id = letter.id
    where event.id = ${replayFixture.eventId}::uuid
  `;
  expect(replayState[0]).toEqual({
    alert_status: "resolved",
    attempts: 0,
    event_status: "published",
  });
  const replayWorker = await admin.rpc("run_durable_workers", {
    maximum_messages: 25,
  });
  expect(replayWorker.error).toBeNull();

  const tooLong = await owner.rpc("send_human_message", {
    command_id: randomUUID(),
    expected_version: await version(conversationId),
    message_text: "y".repeat(12_001),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: conversationId,
  });
  expect(tooLong.error?.code).toBe("22001");
});

test("replay inbound antigo é reconciliado quando a sequência já avançou", async () => {
  const replayChat = `chat-stale-replay-${suffix}`;
  const firstMessageId = `message-stale-replay-1-${suffix}`;
  const secondMessageId = `message-stale-replay-2-${suffix}`;
  const first = await ingest(
    firstMessageId,
    replayChat,
    `lead-stale-replay-${suffix}`,
  );
  expect(first.error).toBeNull();
  const second = await ingest(
    secondMessageId,
    replayChat,
    `lead-stale-replay-${suffix}`,
  );
  expect(second.error).toBeNull();

  const fixture = await database.begin(async (sql) => {
    const inboxes = await sql<
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
        and provider_event_id in (${firstMessageId}, ${secondMessageId})
      order by stream_sequence
      for update
    `;
    const oldInbox = inboxes[0]!;
    const queueRows = await sql<Array<{ msg_id: number }>>`
      select sent.msg_id
      from pgmq.send(
        'inbound_whatsapp',
        jsonb_build_object(
          'inbox_id', ${oldInbox.id}::uuid,
          'organization_id', ${oldInbox.organization_id}::uuid,
          'operation_id', ${operationId}::uuid,
          'stream_key', ${oldInbox.stream_key},
          'stream_sequence', ${oldInbox.stream_sequence},
          'trace_id', ${oldInbox.trace_id}::uuid,
          'correlation_id', ${oldInbox.correlation_id}::uuid
        )
      ) as sent(msg_id)
    `;
    const queueMessageId = queueRows[0]!.msg_id;
    await sql`
      update private.webhook_inbox
      set
        status = 'dead',
        attempts = 1,
        queue_message_id = ${queueMessageId},
        last_error_class = 'non_retryable',
        last_error_code = 'synthetic_stale_replay',
        updated_at = now()
      where id = ${oldInbox.id}::uuid
    `;
    const letters = await sql<Array<{ dead_letter_id: string }>>`
      select private.dead_letter_queue_message(
        'inbound_whatsapp',
        ${queueMessageId},
        ${oldInbox.id}::uuid,
        ${`webhook:${connectionId}:${firstMessageId}`},
        jsonb_build_object(
          'inbox_id', ${oldInbox.id}::uuid,
          'organization_id', ${oldInbox.organization_id}::uuid,
          'operation_id', ${operationId}::uuid,
          'stream_key', ${oldInbox.stream_key},
          'stream_sequence', ${oldInbox.stream_sequence},
          'trace_id', ${oldInbox.trace_id}::uuid,
          'correlation_id', ${oldInbox.correlation_id}::uuid
        ),
        1,
        'non_retryable',
        'synthetic_stale_replay',
        ${oldInbox.organization_id}::uuid,
        ${operationId}::uuid,
        ${oldInbox.trace_id}::uuid,
        ${oldInbox.correlation_id}::uuid
      ) as dead_letter_id
    `;
    return {
      deadLetterId: letters[0]!.dead_letter_id,
      inboxId: oldInbox.id,
    };
  });

  const replayed = await owner.rpc("replay_dead_letter", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_dead_letter_id: fixture.deadLetterId,
  });
  expect(replayed.error).toBeNull();
  expect(replayed.data).toEqual(
    expect.objectContaining({
      reason: "later_inbound_already_applied",
      status: "rejected_stale",
    }),
  );

  const state = await database<
    Array<{
      alert_status: string;
      inbox_status: string;
      messages: number;
    }>
  >`
    select
      inbox.status as inbox_status,
      alert.status as alert_status,
      (
        select count(*)::integer
        from public.messages as message
        where message.connection_id = ${connectionId}::uuid
          and message.provider_message_id in (
            ${firstMessageId},
            ${secondMessageId}
          )
      ) as messages
    from private.webhook_inbox as inbox
    join private.dead_letters as letter
      on letter.envelope_id = inbox.id
    join private.durable_processing_alerts as alert
      on alert.dead_letter_id = letter.id
    where inbox.id = ${fixture.inboxId}::uuid
  `;
  expect(state[0]).toEqual({
    alert_status: "resolved",
    inbox_status: "dead",
    messages: 2,
  });
});

test("desativar humano transfere Ownership e invalida devolução pendente", async () => {
  const inboundResult = await ingest(
    "message-deactivation",
    "chat-deactivation",
    "lead-deactivation",
  );
  expect(inboundResult.error).toBeNull();
  const targetId = (inboundResult.data as { conversation_id: string })
    .conversation_id;
  const assumed = await assume(manager, targetId, await version(targetId));
  expect(assumed.error).toBeNull();
  const pending = await returnToPedro(
    manager,
    targetId,
    await version(targetId),
  );
  expect(pending.error).toBeNull();
  expect(pending.data).toEqual(expect.objectContaining({ pending_return: true }));

  const deactivated = await admin.rpc(
    "deactivate_membership_after_reauthentication",
    {
      actor_user_id: ownerId,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_membership_id: managerMembershipId,
      target_operation_id: operationId,
    },
  );
  expect(deactivated.error).toBeNull();

  const transferred = await database<
    Array<{
      assigned_membership_id: string;
      pending_return: boolean;
      pending_return_target_mode: string | null;
    }>
  >`
    select
      assigned_membership_id,
      pending_return,
      pending_return_target_mode
    from public.conversations
    where id = ${targetId}::uuid
  `;
  expect(transferred[0]).toEqual({
    assigned_membership_id: ownerMembershipId,
    pending_return: false,
    pending_return_target_mode: null,
  });

  const audit = await database<Array<{ count: number }>>`
    select count(*)::integer as count
    from audit.audit_events
    where target_id = ${targetId}::uuid
      and action = 'conversation.pending_return_invalidated'
  `;
  expect(audit[0]!.count).toBe(1);

  async function raceDeactivationAgainstCommand(
    kind: "assume" | "pause",
    whatsapp: string,
  ) {
    const raceManager = await createManagerFixture(
      `race-${kind}`,
      whatsapp,
    );
    const raceInbound = await ingest(
      `message-deactivation-race-${kind}`,
      `chat-deactivation-race-${kind}`,
      `lead-deactivation-race-${kind}`,
    );
    expect(raceInbound.error).toBeNull();
    const raceConversationId = (
      raceInbound.data as { conversation_id: string }
    ).conversation_id;
    const expectedVersion = await version(raceConversationId);

    let releaseRowLock!: () => void;
    let confirmRowLock!: () => void;
    const release = new Promise<void>((resolve) => {
      releaseRowLock = resolve;
    });
    const rowLocked = new Promise<void>((resolve) => {
      confirmRowLock = resolve;
    });
    const blocker = database.begin(async (transaction) => {
      await transaction`
        select id
        from public.conversations
        where id = ${raceConversationId}::uuid
        for update
      `;
      confirmRowLock();
      await release;
    });

    await rowLocked;
    const command =
      kind === "assume"
        ? assume(raceManager.client, raceConversationId, expectedVersion)
        : pause(
            raceManager.client,
            raceConversationId,
            expectedVersion,
            "Revisão concorrente",
          );

    try {
      await waitForMembershipOwnershipLock(raceManager.membershipId);
      const deactivation = admin.rpc(
        "deactivate_membership_after_reauthentication",
        {
          actor_user_id: ownerId,
          request_correlation_id: randomUUID(),
          request_trace_id: randomUUID(),
          target_membership_id: raceManager.membershipId,
          target_operation_id: operationId,
        },
      );
      releaseRowLock();
      await blocker;
      const [commandResult, deactivationResult] = await Promise.all([
        command,
        deactivation,
      ]);
      expect(commandResult.error).toBeNull();
      expect(deactivationResult.error).toBeNull();
    } finally {
      releaseRowLock();
      await blocker.catch(() => undefined);
    }

    const finalOwner = await database<
      Array<{
        assigned_membership_id: string;
        membership_status: string;
        ownership_type: string;
      }>
    >`
      select
        conversation.assigned_membership_id,
        membership.status as membership_status,
        conversation.ownership_type
      from public.conversations as conversation
      join public.memberships as membership
        on membership.id = conversation.assigned_membership_id
      where conversation.id = ${raceConversationId}::uuid
    `;
    expect(finalOwner[0]).toEqual({
      assigned_membership_id: ownerMembershipId,
      membership_status: "active",
      ownership_type: "human",
    });

    const deactivatedMembership = await database<Array<{ status: string }>>`
      select status
      from public.memberships
      where id = ${raceManager.membershipId}::uuid
    `;
    expect(deactivatedMembership[0]!.status).toBe("revoked");

    const rejectedInactiveOwner = await database`
      update public.conversations
      set
        assigned_membership_id = ${raceManager.membershipId}::uuid,
        ownership_type = 'human',
        version = version + 1
      where id = ${raceConversationId}::uuid
      returning assigned_membership_id
    `.catch((error: unknown) => error);
    expect(rejectedInactiveOwner).toBeInstanceOf(Error);
  }

  await raceDeactivationAgainstCommand("assume", "+5511999990031");
  await raceDeactivationAgainstCommand("pause", "+5511999990032");
});

test("Inbox renderiza lista, mensagens, contexto e Ownership no desktop e celular", async ({
  page,
}) => {
  await page.setViewportSize({ height: 900, width: 1440 });
  await page.goto("/entrar?next=%2Fapp%2Fatendimentos");
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Entrar" }).click();
  await expect(page).toHaveURL(/\/app\/atendimentos$/);
  await expect(
    page.getByRole("heading", { name: "Atendimentos" }),
  ).toBeVisible();
  const primaryLink = page.locator(
    `a[href="/app/atendimentos/${conversationId}"]`,
  );
  await expect(primaryLink).toBeVisible();
  await primaryLink.click();
  await expect(page).toHaveURL(
    new RegExp(`/app/atendimentos/${conversationId}$`),
  );
  await expect(page.getByText("Mensagem message-primary")).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Oportunidade" }),
  ).toBeVisible();
  await expect(page.getByRole("heading", { name: "Ownership" })).toBeVisible();
  await expect(page.getByText("Conexão fixa")).toBeVisible();

  const desktopList = page.getByLabel("Conversas abertas");
  const thread = page.getByLabel("Mensagens");
  const context = page.getByLabel("Contexto operacional");
  await expect(desktopList).toBeVisible();
  await expect(thread).toBeVisible();
  await expect(context).toBeVisible();
  const [listBox, threadBox, contextBox] = await Promise.all([
    desktopList.boundingBox(),
    thread.boundingBox(),
    context.boundingBox(),
  ]);
  expect(listBox).not.toBeNull();
  expect(threadBox).not.toBeNull();
  expect(contextBox).not.toBeNull();
  expect(listBox!.x).toBeLessThan(threadBox!.x);
  expect(threadBox!.x).toBeLessThan(contextBox!.x);
  const threadPrecedesContext = await page.evaluate(() => {
    const threadElement = document.querySelector(".conversation-thread");
    const contextElement = document.querySelector(".conversation-context");
    return Boolean(
      threadElement &&
        contextElement &&
        threadElement.compareDocumentPosition(contextElement) &
          Node.DOCUMENT_POSITION_FOLLOWING,
    );
  });
  expect(threadPrecedesContext).toBe(true);

  await page.setViewportSize({ height: 768, width: 1024 });
  await page.goto("/app/atendimentos");
  await expect(primaryLink).toBeVisible();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= document.documentElement.clientWidth,
    ),
  ).toBe(true);
  await primaryLink.click();
  await expect(page.getByText("Mensagem message-primary")).toBeVisible();
  await expect(thread).toBeVisible();
  await expect(context).toBeHidden();
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= document.documentElement.clientWidth,
    ),
  ).toBe(true);
  await page
    .getByRole("link", { name: "Ver contexto e Ownership" })
    .click();
  await expect(thread).toBeHidden();
  await expect(context).toBeVisible();
  await page.getByRole("link", { name: "Voltar para conversa" }).click();
  await expect(thread).toBeVisible();
  await expect(context).toBeHidden();

  await page.setViewportSize({ height: 844, width: 390 });
  await page.goto("/app/atendimentos");
  await expect(primaryLink).toBeVisible();
  await primaryLink.click();
  await expect(page.getByText("Mensagem message-primary")).toBeVisible();
  await expect(thread).toBeVisible();
  await expect(context).toBeHidden();
  await expect(page.getByText(/Ownership:/)).toBeVisible();
  await page
    .getByRole("link", { name: "Ver contexto e Ownership" })
    .click();
  await expect(page).toHaveURL(/painel=contexto/);
  await expect(thread).toBeHidden();
  await expect(context).toBeVisible();
  await expect(page.getByText("Contexto para Pedro")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Ownership" })).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Voltar para conversa" }),
  ).toBeVisible();

  const pausedHumanConversation = await database<Array<{ id: string }>>`
    select id
    from public.conversations
    where operation_id = ${operationId}::uuid
      and ownership_type = 'human'
      and assigned_membership_id = ${ownerMembershipId}::uuid
      and is_paused
      and status in ('active', 'sleeping')
    order by updated_at desc
    limit 1
  `;
  await page.goto(`/app/atendimentos/${pausedHumanConversation[0]!.id}`);
  await expect(page.getByLabel("Responder como humano")).toBeVisible();

  const pedroConversation = await database<Array<{ id: string }>>`
    select id
    from public.conversations
    where operation_id = ${operationId}::uuid
      and ownership_type = 'pedro'
      and status in ('active', 'sleeping')
    order by updated_at desc
    limit 1
  `;
  await page.goto(`/app/atendimentos/${pedroConversation[0]!.id}`);
  await expect(
    page.getByRole("button", { name: "Assumir", exact: true }),
  ).toBeVisible();
});

test("route HTTP real usa apenas token sintético da Preview", async ({
  request,
}) => {
  const token = process.env.SIMULATOR_INGRESS_TOKEN;
  test.skip(!token, "Preview harness não forneceu SIMULATOR_INGRESS_TOKEN");
  const response = await request.post("/api/simulator/whatsapp/inbound", {
    data: {
      connection_id: connectionId,
      chat: { id: "chat-http-route" },
      identity: {
        aliases: [
          { type: "simulator_user", value: "lead-http-route" },
        ],
      },
      message: {
        id: `message-http-${suffix}`,
        kind: "text",
        text: "Inbound pelo route da Preview",
      },
    },
    headers: { authorization: `Bearer ${token}` },
  });
  expect(response.status()).toBe(202);
  expect(await response.json()).toEqual(
    expect.objectContaining({ status: "accepted" }),
  );
});
