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
  return admin.rpc("ingest_simulated_inbound", {
    normalized_event: inbound(messageId, chatId, alias, phone),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_connection_id: connectionId,
  });
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

test("assumir usa versão e produção permanece fechada", async () => {
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

  const result = await admin.rpc("ingest_simulated_inbound", {
    normalized_event: inbound(
      "message-second-connection",
      "chat-primary",
      "lead-primary",
    ),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_connection_id: secondConnectionId,
  });
  expect(result.error).toBeNull();
  const secondConversationId = (
    result.data as { conversation_id: string }
  ).conversation_id;
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
    expect.objectContaining({ pending_cancelled: true, status: "captured" }),
  );

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
  const second = await owner.rpc("send_human_message", {
    command_id: secondCommand,
    expected_version: await version(conversationId),
    message_text: "Outra resposta sintética",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_conversation_id: conversationId,
  });
  expect(second.error).toBeNull();
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

  const deactivated = await owner.rpc(
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
});

test("Inbox renderiza lista, mensagens, contexto e Ownership no desktop e celular", async ({
  page,
}) => {
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

  await page.setViewportSize({ height: 844, width: 390 });
  await page.goto("/app/atendimentos");
  await expect(primaryLink).toBeVisible();
  await primaryLink.click();
  await expect(page.getByText("Mensagem message-primary")).toBeVisible();
  await expect(page.getByText("Contexto para Pedro")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Ownership" })).toBeVisible();
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
    expect.objectContaining({ status: "received" }),
  );
});
