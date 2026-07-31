import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const suffix = randomUUID().slice(0, 8);
const password = `Preview-${randomUUID()}-A1!`;
const ownerEmail = `pipeline-owner-${suffix}@example.com`;
const brokerEmail = `pipeline-broker-${suffix}@example.com`;
const outsiderEmail = `pipeline-outsider-${suffix}@example.com`;

let admin: SupabaseClient;
let owner: SupabaseClient;
let broker: SupabaseClient;
let outsider: SupabaseClient;
let database: Sql;
let organizationId = "";
let operationId = "";
let ownerId = "";
let ownerMembershipId = "";
let brokerId = "";
let brokerMembershipId = "";
let outsiderOrganizationId = "";
let outsiderOperationId = "";
let outsiderId = "";
const createdUserIds: string[] = [];

test.describe.configure({ mode: "serial" });

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required for the Preview black-box suite`);
  }
  return value;
}

async function insertFixture(
  table: string,
  values: Record<string, unknown>,
) {
  const { error } = await admin.from(table).insert(values);
  if (error) {
    throw new Error(
      `Could not create synthetic ${table} fixture: ${error.code} ${error.message}`,
    );
  }
}

async function createAuthenticatedClient(
  email: string,
): Promise<{ client: SupabaseClient; userId: string }> {
  const user = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    password,
  });
  if (user.error) {
    throw new Error(`Could not create synthetic user: ${user.error.code}`);
  }
  createdUserIds.push(user.data.user.id);
  const client = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const signIn = await client.auth.signInWithPassword({ email, password });
  if (signIn.error) {
    throw new Error(`Could not authenticate synthetic user: ${signIn.error.code}`);
  }
  return { client, userId: user.data.user.id };
}

async function createManualLead({
  action = "register",
  context = "",
  internalNote = "",
  name,
  participantName = "",
  participantPhone = "",
  phone,
  source = "indicação",
  units = 1,
}: {
  action?: "assume" | "register" | "request_proactive";
  context?: string;
  internalNote?: string;
  name: string;
  participantName?: string;
  participantPhone?: string;
  phone: string;
  source?: string;
  units?: number;
}) {
  const result = await owner.rpc("create_manual_lead", {
    amount_scope_value: units > 1 ? "total" : "per_unit",
    internal_note_value: internalNote,
    lead_name: name,
    lead_source: source,
    participant_name: participantName,
    participant_phone_original: participantPhone,
    pedro_context_value: context,
    phone_original: phone,
    registration_action: action,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    unit_count_value: units,
  });
  expect(result.error).toBeNull();
  return result.data as {
    contact_id: string;
    opportunity_id: string;
    phone_e164: string;
    stage: string;
  };
}

async function transition(
  opportunityId: string,
  targetStage: string,
  expectedVersion: number,
  reason = "",
  humanDecision = false,
  client: SupabaseClient = owner,
) {
  return client.rpc("transition_opportunity", {
    expected_version: expectedVersion,
    human_decision: humanDecision,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_opportunity_id: opportunityId,
    target_stage: targetStage,
    transition_reason: reason,
  });
}

async function opportunityVersion(opportunityId: string): Promise<number> {
  const result = await admin
    .from("opportunities")
    .select("version")
    .eq("id", opportunityId)
    .single();
  expect(result.error).toBeNull();
  return result.data!.version;
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

  organizationId = randomUUID();
  operationId = randomUUID();
  outsiderOrganizationId = randomUUID();
  outsiderOperationId = randomUUID();

  const ownerIdentity = await createAuthenticatedClient(ownerEmail);
  owner = ownerIdentity.client;
  ownerId = ownerIdentity.userId;
  const brokerIdentity = await createAuthenticatedClient(brokerEmail);
  broker = brokerIdentity.client;
  brokerId = brokerIdentity.userId;
  const outsiderIdentity = await createAuthenticatedClient(outsiderEmail);
  outsider = outsiderIdentity.client;
  outsiderId = outsiderIdentity.userId;

  await insertFixture("organizations", {
    id: organizationId,
    name: `Imobiliária Pipeline ${suffix}`,
    slug: `preview-pipeline-${suffix}`,
  });
  await insertFixture("operations", {
    id: operationId,
    is_default: true,
    name: `Operação Pipeline ${suffix}`,
    organization_id: organizationId,
  });
  await insertFixture("operation_settings", {
    operation_id: operationId,
    organization_id: organizationId,
  });

  ownerMembershipId = randomUUID();
  await insertFixture("memberships", {
    id: ownerMembershipId,
    organization_id: organizationId,
    role: "owner",
    status: "active",
    user_id: ownerId,
  });
  await insertFixture("membership_operations", {
    membership_id: ownerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });

  brokerMembershipId = randomUUID();
  await insertFixture("memberships", {
    can_receive_calls: true,
    id: brokerMembershipId,
    organization_id: organizationId,
    role: "broker",
    status: "active",
    user_id: brokerId,
  });
  await insertFixture("membership_operations", {
    membership_id: brokerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insertFixture("staff_profiles", {
    full_name: "Corretor Pipeline",
    membership_id: brokerMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511888888888",
  });

  await insertFixture("organizations", {
    id: outsiderOrganizationId,
    name: `Imobiliária Isolada ${suffix}`,
    slug: `preview-pipeline-outsider-${suffix}`,
  });
  await insertFixture("operations", {
    id: outsiderOperationId,
    is_default: true,
    name: `Operação Isolada ${suffix}`,
    organization_id: outsiderOrganizationId,
  });
  await insertFixture("operation_settings", {
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
  });
  const outsiderMembershipId = randomUUID();
  await insertFixture("memberships", {
    id: outsiderMembershipId,
    organization_id: outsiderOrganizationId,
    role: "owner",
    status: "active",
    user_id: outsiderId,
  });
  await insertFixture("membership_operations", {
    membership_id: outsiderMembershipId,
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
  });
});

test.afterAll(async () => {
  if (!admin) {
    return;
  }

  for (const targetOperationId of [operationId, outsiderOperationId]) {
    await admin
      .from("membership_operations")
      .delete()
      .eq("operation_id", targetOperationId);
    await admin
      .from("operation_settings")
      .delete()
      .eq("operation_id", targetOperationId);
    await admin.from("operations").delete().eq("id", targetOperationId);
  }
  for (const userId of createdUserIds) {
    await admin.auth.admin.deleteUser(userId);
  }
  await admin.from("organizations").delete().eq("id", organizationId);
  await admin
    .from("organizations")
    .delete()
    .eq("id", outsiderOrganizationId);
  await database.end();
});

test("keeps anonymous access closed and denies direct client writes", async () => {
  const anonymous = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );

  const anonymousRead = await anonymous.from("contacts").select("id").limit(1);
  expect(anonymousRead.error?.code).toBe("42501");

  const directWrite = await owner.from("contacts").insert({
    display_name: "Tentativa sem RPC",
    organization_id: organizationId,
  });
  expect(directWrite.error?.code).toBe("42501");
});

test("normalizes E.164 server-side, preserves original values and deduplicates only exact phones", async () => {
  const usLead = await createManualLead({
    name: "Contato +1",
    phone: "+1 (415) 555-2671",
  });
  expect(usLead.phone_e164).toBe("+14155552671");

  const first = await createManualLead({
    name: "Contato Brasileiro",
    phone: "(11) 99999-1234",
  });
  expect(first.phone_e164).toBe("+5511999991234");

  const samePhone = await createManualLead({
    name: "Mesmo Contato",
    phone: "55 11 99999-1234",
    source: "evento",
  });
  expect(samePhone.contact_id).toBe(first.contact_id);
  expect(samePhone.opportunity_id).not.toBe(first.opportunity_id);

  const observations = await admin
    .from("contact_phone_observations")
    .select("original_value")
    .eq("contact_id", first.contact_id)
    .order("observed_at");
  expect(observations.error).toBeNull();
  expect(observations.data?.map((item) => item.original_value)).toEqual([
    "(11) 99999-1234",
    "55 11 99999-1234",
  ]);

  const localWithoutDdd = await owner.rpc("create_manual_lead", {
    amount_scope_value: "total",
    internal_note_value: "",
    lead_name: "Sem DDD",
    lead_source: "teste",
    participant_name: "",
    participant_phone_original: "",
    pedro_context_value: "",
    phone_original: "99999-1234",
    registration_action: "register",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    unit_count_value: 1,
  });
  expect(localWithoutDdd.error?.code).toBe("22023");
  expect(localWithoutDdd.error?.message).toContain("DDD");

  const duplicateRows = await database`
    select e164, count(*)::int as total
    from public.contact_phones
    where organization_id = ${organizationId}
    group by e164
    having count(*) > 1
  `;
  expect(duplicateRows).toEqual([]);
});

test("keeps Contact, Opportunity and Participant separate and does not send proactive requests", async () => {
  const lead = await createManualLead({
    action: "request_proactive",
    context: "Prefere conversa curta no fim da tarde.",
    internalNote: "Não mencionar a origem interna desta indicação.",
    name: "Compradora com Participante",
    participantName: "Co-comprador",
    participantPhone: "(11) 98888-7777",
    phone: "(11) 97777-6666",
    units: 3,
  });

  const opportunity = await admin
    .from("opportunities")
    .select("contact_id, unit_count, amount_scope, pedro_context")
    .eq("id", lead.opportunity_id)
    .single();
  expect(opportunity.data).toEqual({
    amount_scope: "total",
    contact_id: lead.contact_id,
    pedro_context: "Prefere conversa curta no fim da tarde.",
    unit_count: 3,
  });

  const participants = await admin
    .from("opportunity_participants")
    .select("display_name, opportunity_id, phone_e164");
  expect(participants.data).toContainEqual({
    display_name: "Co-comprador",
    opportunity_id: lead.opportunity_id,
    phone_e164: "+5511988887777",
  });

  const request = await admin
    .from("proactive_approach_requests")
    .select("authorization_confirmed, status")
    .eq("opportunity_id", lead.opportunity_id)
    .single();
  expect(request.data).toEqual({
    authorization_confirmed: false,
    status: "requested",
  });
  const conversations = await admin
    .from("conversations")
    .select("id")
    .eq("opportunity_id", lead.opportunity_id);
  expect(conversations.data).toEqual([]);

  const detail = await owner.rpc("get_lead_detail", {
    target_opportunity_id: lead.opportunity_id,
  });
  expect(detail.error).toBeNull();
  expect(detail.data).toEqual(
    expect.objectContaining({
      internal_note: "Não mencionar a origem interna desta indicação.",
      pedro_context: "Prefere conversa curta no fim da tarde.",
    }),
  );
});

test("rejects invalid or stale transitions and keeps current stage equal to the latest history", async () => {
  const lead = await createManualLead({
    name: "Pipeline Protegido",
    phone: "(11) 96666-5555",
  });

  const directUpdate = await owner
    .from("opportunities")
    .update({ stage: "negotiation" })
    .eq("id", lead.opportunity_id);
  expect(directUpdate.error?.code).toBe("42501");

  const stale = await transition(lead.opportunity_id, "in_service", 99);
  expect(stale.error?.code, JSON.stringify(stale.error)).toBe("40001");

  const invalid = await transition(lead.opportunity_id, "negotiation", 1);
  expect(invalid.error?.code).toBe("23514");

  const inService = await transition(lead.opportunity_id, "in_service", 1);
  expect(inService.error).toBeNull();

  const withoutCall = await transition(
    lead.opportunity_id,
    "call_scheduled",
    2,
  );
  expect(withoutCall.error?.code).toBe("23514");
  expect(withoutCall.error?.message).toContain("call must be assigned");

  await admin
    .from("opportunities")
    .update({ assigned_membership_id: brokerMembershipId })
    .eq("id", lead.opportunity_id);
  const assignedCallId = randomUUID();
  await insertFixture("calls", {
    assigned_membership_id: brokerMembershipId,
    id: assignedCallId,
    operation_id: operationId,
    opportunity_id: lead.opportunity_id,
    organization_id: organizationId,
    scheduled_for: new Date(Date.now() + 86_400_000).toISOString(),
    status: "scheduled",
  });

  const callScheduled = await transition(
    lead.opportunity_id,
    "call_scheduled",
    2,
  );
  expect(callScheduled.error).toBeNull();

  const brokerVisible = await broker
    .from("opportunities")
    .select("id, stage")
    .eq("id", lead.opportunity_id);
  expect(brokerVisible.data).toEqual([
    { id: lead.opportunity_id, stage: "call_scheduled" },
  ]);

  const negotiation = await transition(
    lead.opportunity_id,
    "negotiation",
    3,
    "Call concluída com interesse",
    false,
    broker,
  );
  expect(negotiation.error).toBeNull();

  const current = await admin
    .from("opportunities")
    .select("stage")
    .eq("id", lead.opportunity_id)
    .single();
  const history = await admin
    .from("opportunity_stage_history")
    .select("to_stage")
    .eq("opportunity_id", lead.opportunity_id)
    .order("created_at", { ascending: false })
    .limit(1)
    .single();
  expect(history.data?.to_stage).toBe(current.data?.stage);
  expect(current.data?.stage).toBe("negotiation");
});

test("list, detail and Kanban apply organization and broker scope through RLS", async () => {
  const hiddenLead = await createManualLead({
    name: "Ainda não liberado",
    phone: "(11) 95555-4444",
  });
  await admin
    .from("opportunities")
    .update({ assigned_membership_id: brokerMembershipId })
    .eq("id", hiddenLead.opportunity_id);

  const brokerNewRead = await broker
    .from("opportunities")
    .select("id")
    .eq("id", hiddenLead.opportunity_id);
  expect(brokerNewRead.data).toEqual([]);
  const brokerNewBoard = await broker.rpc("get_pipeline_board", {
    target_operation_id: operationId,
  });
  const newCards = (
    brokerNewBoard.data as { cards: Array<{ id: string }> }
  ).cards;
  expect(newCards.some((card) => card.id === hiddenLead.opportunity_id)).toBe(
    false,
  );

  const outsiderContactId = randomUUID();
  const outsiderOpportunityId = randomUUID();
  await insertFixture("contacts", {
    display_name: "Contato Isolado",
    id: outsiderContactId,
    organization_id: outsiderOrganizationId,
  });
  await insertFixture("opportunities", {
    contact_id: outsiderContactId,
    id: outsiderOpportunityId,
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
    stage: "new",
  });

  const ownerCrossRead = await owner
    .from("opportunities")
    .select("id")
    .eq("id", outsiderOpportunityId);
  expect(ownerCrossRead.data).toEqual([]);
  const ownerCrossDetail = await owner.rpc("get_lead_detail", {
    target_opportunity_id: outsiderOpportunityId,
  });
  expect(ownerCrossDetail.error?.code).toBe("42501");
  const outsiderOwnList = await outsider.rpc("get_lead_list", {
    target_operation_id: outsiderOperationId,
  });
  expect(
    (outsiderOwnList.data as Array<{ id: string }>).map((lead) => lead.id),
  ).toContain(outsiderOpportunityId);
});

test("manual merge blocks two active conversations and preserves identity, opt-out, origins and histories", async () => {
  const primary = await createManualLead({
    name: "Contato Principal",
    phone: "(11) 94444-3333",
    source: "portal",
  });
  const duplicate = await createManualLead({
    name: "Contato Duplicado",
    phone: "(11) 93333-2222",
    source: "evento",
  });
  await insertFixture("opt_outs", {
    contact_id: primary.contact_id,
    organization_id: organizationId,
    phone_e164: primary.phone_e164,
    reason: "Pediu para não chamar",
  });
  await insertFixture("opt_outs", {
    contact_id: duplicate.contact_id,
    organization_id: organizationId,
    phone_e164: duplicate.phone_e164,
    reason: "Opt-out também registrado",
  });
  const primaryConversationId = randomUUID();
  const duplicateConversationId = randomUUID();
  await insertFixture("conversations", {
    contact_id: primary.contact_id,
    id: primaryConversationId,
    operation_id: operationId,
    opportunity_id: primary.opportunity_id,
    organization_id: organizationId,
    status: "active",
  });
  await insertFixture("conversations", {
    contact_id: duplicate.contact_id,
    id: duplicateConversationId,
    operation_id: operationId,
    opportunity_id: duplicate.opportunity_id,
    organization_id: organizationId,
    status: "active",
  });

  const blocked = await owner.rpc("merge_contacts", {
    duplicate_contact_id: duplicate.contact_id,
    primary_contact_id: primary.contact_id,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(blocked.error?.code).toBe("23514");
  expect(blocked.error?.message).toContain("active conversations");

  await admin
    .from("conversations")
    .update({
      sleeping_since: new Date().toISOString(),
      status: "sleeping",
    })
    .eq("id", duplicateConversationId);

  const merged = await owner.rpc("merge_contacts", {
    duplicate_contact_id: duplicate.contact_id,
    primary_contact_id: primary.contact_id,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(merged.error).toBeNull();

  const mergedContact = await admin
    .from("contacts")
    .select("merged_into_contact_id, status")
    .eq("id", duplicate.contact_id)
    .single();
  expect(mergedContact.data).toEqual({
    merged_into_contact_id: primary.contact_id,
    status: "merged",
  });

  const phones = await admin
    .from("contact_phones")
    .select("e164")
    .eq("contact_id", primary.contact_id);
  expect(phones.data?.map((phone) => phone.e164).sort()).toEqual(
    [primary.phone_e164, duplicate.phone_e164].sort(),
  );
  const movedOpportunities = await admin
    .from("opportunities")
    .select("id")
    .eq("contact_id", primary.contact_id);
  expect(movedOpportunities.data?.map((item) => item.id)).toEqual(
    expect.arrayContaining([
      primary.opportunity_id,
      duplicate.opportunity_id,
    ]),
  );
  const movedSources = await admin
    .from("source_attributions")
    .select("source_type")
    .eq("contact_id", primary.contact_id);
  expect(movedSources.data?.map((source) => source.source_type)).toEqual(
    expect.arrayContaining(["portal", "evento"]),
  );
  const optOuts = await admin
    .from("opt_outs")
    .select("status")
    .eq("contact_id", primary.contact_id);
  expect(optOuts.data).toHaveLength(2);
  expect(optOuts.data?.some((optOut) => optOut.status === "active")).toBe(true);
  const histories = await admin
    .from("opportunity_stage_history")
    .select("opportunity_id")
    .in("opportunity_id", [
      primary.opportunity_id,
      duplicate.opportunity_id,
    ]);
  expect(
    new Set(histories.data?.map((history) => history.opportunity_id)),
  ).toEqual(new Set([primary.opportunity_id, duplicate.opportunity_id]));
});

test("reopens pre-call loss automatically, requires a human after call and never reopens Comprado", async () => {
  const beforeCall = await createManualLead({
    name: "Retorno antes da Call",
    phone: "(11) 92222-1111",
  });
  const lostBeforeCall = await transition(
    beforeCall.opportunity_id,
    "lost",
    1,
    "Sem resposta após a cadência",
  );
  expect(lostBeforeCall.error).toBeNull();
  const automaticReopen = await admin.rpc("reopen_opportunity_on_inbound", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_opportunity_id: beforeCall.opportunity_id,
  });
  expect(automaticReopen.data).toBe("reopened");

  const postCall = await createManualLead({
    name: "Retorno depois da Call",
    phone: "(11) 91111-0000",
  });
  expect(
    (await transition(postCall.opportunity_id, "in_service", 1)).error,
  ).toBeNull();
  await admin
    .from("opportunities")
    .update({ assigned_membership_id: brokerMembershipId })
    .eq("id", postCall.opportunity_id);
  const postCallId = randomUUID();
  await insertFixture("calls", {
    assigned_membership_id: brokerMembershipId,
    id: postCallId,
    operation_id: operationId,
    opportunity_id: postCall.opportunity_id,
    organization_id: organizationId,
    scheduled_for: new Date(Date.now() - 3_600_000).toISOString(),
    status: "scheduled",
  });
  expect(
    (await transition(postCall.opportunity_id, "call_scheduled", 2)).error,
  ).toBeNull();
  await admin
    .from("calls")
    .update({ status: "completed" })
    .eq("id", postCallId);
  expect(
    (
      await transition(
        postCall.opportunity_id,
        "negotiation",
        3,
        "Call realizada",
      )
    ).error,
  ).toBeNull();
  expect(
    (
      await transition(
        postCall.opportunity_id,
        "lost",
        4,
        "Desistiu depois da Call",
      )
    ).error,
  ).toBeNull();
  const postCallReopen = await admin.rpc("reopen_opportunity_on_inbound", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_opportunity_id: postCall.opportunity_id,
  });
  expect(postCallReopen.data).toBe("human_review_required");
  const stillLost = await admin
    .from("opportunities")
    .select("stage")
    .eq("id", postCall.opportunity_id)
    .single();
  expect(stillLost.data?.stage).toBe("lost");

  const purchased = await createManualLead({
    name: "Venda concluída",
    phone: "(11) 90000-9999",
  });
  expect(
    (await transition(purchased.opportunity_id, "in_service", 1)).error,
  ).toBeNull();
  await admin
    .from("opportunities")
    .update({ assigned_membership_id: brokerMembershipId })
    .eq("id", purchased.opportunity_id);
  const purchasedCallId = randomUUID();
  await insertFixture("calls", {
    assigned_membership_id: brokerMembershipId,
    id: purchasedCallId,
    operation_id: operationId,
    opportunity_id: purchased.opportunity_id,
    organization_id: organizationId,
    scheduled_for: new Date().toISOString(),
    status: "scheduled",
  });
  const scheduledPurchase = await transition(
    purchased.opportunity_id,
    "call_scheduled",
    await opportunityVersion(purchased.opportunity_id),
    "Call atribuída",
  );
  expect(scheduledPurchase.error).toBeNull();
  await admin
    .from("calls")
    .update({ status: "completed" })
    .eq("id", purchasedCallId);
  for (const [stage, reason] of [
    ["negotiation", "Call realizada"],
    ["proposal_reservation", "Reserva iniciada"],
    ["documentation", "Documentação recebida"],
    ["payment", "Pagamento iniciado"],
    ["purchased", "Compra confirmada"],
  ] as const) {
    const version = await opportunityVersion(purchased.opportunity_id);
    const result = await transition(
      purchased.opportunity_id,
      stage,
      version,
      reason,
    );
    expect(result.error, stage).toBeNull();
  }
  const purchasedReopen = await admin.rpc("reopen_opportunity_on_inbound", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_opportunity_id: purchased.opportunity_id,
  });
  expect(purchasedReopen.data).toBe("sale_closed");
  const purchasedTransition = await transition(
    purchased.opportunity_id,
    "lost",
    await opportunityVersion(purchased.opportunity_id),
    "Tentativa indevida",
  );
  expect(purchasedTransition.error?.code).toBe("23514");
});

test("creates a manual Lead in the authenticated UI and renders it on the Kanban", async ({
  page,
}) => {
  const displayName = `Lead visual ${suffix}`;

  await page.goto("/entrar");
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Entrar" }).click();
  await expect(page).toHaveURL(/\/app\/central$/);

  await page.goto("/app/leads");
  await expect(page.getByRole("heading", { name: "Leads" })).toBeVisible();
  await page.getByLabel("Como podemos chamar").fill(displayName);
  await page
    .getByLabel("WhatsApp", { exact: true })
    .fill("(11) 98887-1234");
  await page.getByLabel("Origem").fill("Validação visual");
  await page.getByRole("button", { name: "Cadastrar Lead" }).click();

  await expect(page).toHaveURL(/\/app\/leads\/[0-9a-f-]+\?resultado=lead-criado$/);
  await expect(page.getByRole("heading", { name: displayName })).toBeVisible();
  await expect(page.getByText("Lead cadastrado sem iniciar qualquer envio.")).toBeVisible();

  await page.goto("/app/kanban");
  await expect(page.getByRole("heading", { name: "Kanban" })).toBeVisible();
  await expect(page.getByText(displayName)).toBeVisible();
});

test("audits every domain mutation covered by this slice", async () => {
  const actions = await database`
    select action, count(*)::int as total
    from audit.audit_events
    where organization_id = ${organizationId}
      and action in (
        'lead.manual_created',
        'opportunity.stage_changed',
        'contact.merged',
        'opportunity.inbound_reactivated',
        'opportunity.inbound_reactivation_requires_human'
      )
    group by action
  `;
  const counts = new Map(
    actions.map((row) => [row.action as string, row.total as number]),
  );
  expect(counts.get("lead.manual_created")).toBeGreaterThan(0);
  expect(counts.get("opportunity.stage_changed")).toBeGreaterThan(0);
  expect(counts.get("contact.merged")).toBeGreaterThan(0);
  expect(counts.get("opportunity.inbound_reactivated")).toBeGreaterThan(0);
  expect(
    counts.get("opportunity.inbound_reactivation_requires_human"),
  ).toBeGreaterThan(0);
});
