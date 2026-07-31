import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const suffix = randomUUID().slice(0, 8);
const password = `Preview-${randomUUID()}-A1!`;
const ownerEmail = `pipeline-owner-${suffix}@example.com`;
const brokerEmail = `pipeline-broker-${suffix}@example.com`;
const dualRoleEmail = `pipeline-dual-${suffix}@example.com`;
const outsiderEmail = `pipeline-outsider-${suffix}@example.com`;

let admin: SupabaseClient;
let owner: SupabaseClient;
let broker: SupabaseClient;
let dualRole: SupabaseClient;
let outsider: SupabaseClient;
let database: Sql;
let organizationId = "";
let operationId = "";
let ownerId = "";
let ownerMembershipId = "";
let brokerId = "";
let brokerMembershipId = "";
let dualRoleId = "";
let dualRoleMembershipId = "";
let sameOrganizationSecondOperationId = "";
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
    conversation_id?: string;
    opportunity_id: string;
    ownership_type?: "human";
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

async function contactVersion(contactId: string): Promise<number> {
  const result = await admin
    .from("contacts")
    .select("version")
    .eq("id", contactId)
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
  sameOrganizationSecondOperationId = randomUUID();

  const ownerIdentity = await createAuthenticatedClient(ownerEmail);
  owner = ownerIdentity.client;
  ownerId = ownerIdentity.userId;
  const brokerIdentity = await createAuthenticatedClient(brokerEmail);
  broker = brokerIdentity.client;
  brokerId = brokerIdentity.userId;
  const dualRoleIdentity = await createAuthenticatedClient(dualRoleEmail);
  dualRole = dualRoleIdentity.client;
  dualRoleId = dualRoleIdentity.userId;
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
  await insertFixture("operations", {
    id: sameOrganizationSecondOperationId,
    is_default: false,
    name: `Operação Mesma Imobiliária ${suffix}`,
    organization_id: organizationId,
  });
  await insertFixture("operation_settings", {
    operation_id: sameOrganizationSecondOperationId,
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

  dualRoleMembershipId = randomUUID();
  await insertFixture("memberships", {
    can_receive_calls: true,
    id: dualRoleMembershipId,
    organization_id: organizationId,
    role: "manager",
    status: "active",
    user_id: dualRoleId,
  });
  await insertFixture("membership_roles", {
    membership_id: dualRoleMembershipId,
    organization_id: organizationId,
    role: "broker",
  });
  await insertFixture("membership_operations", {
    membership_id: dualRoleMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insertFixture("staff_profiles", {
    full_name: "Gestor e Corretor",
    membership_id: dualRoleMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511777777777",
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

  for (const targetOperationId of [
    operationId,
    sameOrganizationSecondOperationId,
    outsiderOperationId,
  ]) {
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

test("serializes concurrent exact-phone registrations into one Contact and distinct Opportunities", async () => {
  const concurrentPhone = "(11) 94440-9090";
  const attempts = await Promise.all(
    Array.from({ length: 8 }, (_, index) =>
      owner.rpc("create_manual_lead", {
        amount_scope_value: "total",
        internal_note_value: "",
        lead_name: `Concorrente ${index}`,
        lead_source: "concorrência sintética",
        participant_name: "",
        participant_phone_original: "",
        pedro_context_value: "",
        phone_original: concurrentPhone,
        registration_action: "register",
        request_correlation_id: randomUUID(),
        request_trace_id: randomUUID(),
        target_operation_id: operationId,
        unit_count_value: 1,
      }),
    ),
  );
  for (const attempt of attempts) {
    expect(attempt.error).toBeNull();
  }

  const payloads = attempts.map((attempt) => attempt.data as {
    contact_id: string;
    opportunity_id: string;
  });
  expect(new Set(payloads.map((payload) => payload.contact_id)).size).toBe(1);
  expect(
    new Set(payloads.map((payload) => payload.opportunity_id)).size,
  ).toBe(8);

  const phoneRows = await admin
    .from("contact_phones")
    .select("contact_id")
    .eq("organization_id", organizationId)
    .eq("e164", "+5511944409090");
  expect(phoneRows.data).toHaveLength(1);
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

test("manual assume creates one human-owned Conversation without egress or commercial assignment", async () => {
  const lead = await createManualLead({
    action: "assume",
    name: "Lead assumido sem envio",
    phone: "(11) 96660-0001",
  });

  expect(lead.stage).toBe("in_service");
  expect(lead.conversation_id).toBeTruthy();
  expect(lead.ownership_type).toBe("human");

  const opportunity = await admin
    .from("opportunities")
    .select("assigned_membership_id, stage")
    .eq("id", lead.opportunity_id)
    .single();
  expect(opportunity.data).toEqual({
    assigned_membership_id: null,
    stage: "in_service",
  });

  const conversations = await admin
    .from("conversations")
    .select(
      "assigned_membership_id, contact_id, opportunity_id, ownership_type, status",
    )
    .eq("opportunity_id", lead.opportunity_id);
  expect(conversations.data).toEqual([
    {
      assigned_membership_id: ownerMembershipId,
      contact_id: lead.contact_id,
      opportunity_id: lead.opportunity_id,
      ownership_type: "human",
      status: "active",
    },
  ]);

  const ownershipAudit = await database`
    select after_state
    from audit.audit_events
    where target_id = ${lead.conversation_id!}::uuid
      and action = 'conversation.assumed_on_manual_registration'
  `;
  expect(ownershipAudit).toHaveLength(1);
  expect(ownershipAudit[0].after_state).toEqual(
    expect.objectContaining({ egress_created: false }),
  );
});

test("keeps generic transitions pre-Call and fails closed for T21/T24 stages", async () => {
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

  const withoutT21Command = await transition(
    lead.opportunity_id,
    "call_scheduled",
    2,
  );
  expect(withoutT21Command.error?.code).toBe("23514");
  expect(withoutT21Command.error?.message).toContain("domain command");

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
  await insertFixture("call_assignments", {
    call_id: assignedCallId,
    membership_id: brokerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });

  const callScheduled = await transition(
    lead.opportunity_id,
    "call_scheduled",
    2,
  );
  expect(callScheduled.error?.code).toBe("23514");

  const brokerVisible = await broker
    .from("opportunities")
    .select("id, stage")
    .eq("id", lead.opportunity_id);
  expect(brokerVisible.data).toEqual([]);

  const negotiation = await transition(
    lead.opportunity_id,
    "negotiation",
    3,
    "Call concluída com interesse",
    false,
    broker,
  );
  expect(negotiation.error?.code).toBe("42501");

  for (const [index, callStatus] of ["completed", "no_show"].entries()) {
    const postCallLead = await createManualLead({
      name: `Perda pós-Call ${callStatus}`,
      phone: `(11) 9100${index}-4040`,
    });
    const started = await transition(
      postCallLead.opportunity_id,
      "in_service",
      1,
    );
    expect(started.error).toBeNull();
    await insertFixture("calls", {
      id: randomUUID(),
      operation_id: operationId,
      opportunity_id: postCallLead.opportunity_id,
      organization_id: organizationId,
      scheduled_for: new Date(Date.now() - 3_600_000).toISOString(),
      status: callStatus,
    });

    const genericLoss = await transition(
      postCallLead.opportunity_id,
      "lost",
      2,
      "Decisão depois da Call",
      true,
    );
    expect(genericLoss.error?.code).toBe("23514");
    expect(genericLoss.error?.message).toContain("T24");
    const unchanged = await admin
      .from("opportunities")
      .select("stage")
      .eq("id", postCallLead.opportunity_id)
      .single();
    expect(unchanged.data?.stage).toBe("in_service");
  }

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
  expect(current.data?.stage).toBe("in_service");
});

test("tracks time in the current stage independently and keeps stage history append-only", async () => {
  const lead = await createManualLead({
    name: "Relógio de Etapa",
    phone: "(11) 95550-6060",
  });
  const initial = await admin
    .from("opportunities")
    .select("stage_entered_at")
    .eq("id", lead.opportunity_id)
    .single();
  expect(initial.data?.stage_entered_at).toBeTruthy();

  await admin
    .from("opportunities")
    .update({ assigned_membership_id: brokerMembershipId })
    .eq("id", lead.opportunity_id);
  const afterAssignment = await admin
    .from("opportunities")
    .select("stage_entered_at")
    .eq("id", lead.opportunity_id)
    .single();
  expect(afterAssignment.data?.stage_entered_at).toBe(
    initial.data?.stage_entered_at,
  );

  const moved = await transition(
    lead.opportunity_id,
    "in_service",
    await opportunityVersion(lead.opportunity_id),
  );
  expect(moved.error).toBeNull();
  const afterStage = await admin
    .from("opportunities")
    .select("stage_entered_at")
    .eq("id", lead.opportunity_id)
    .single();
  expect(
    new Date(afterStage.data!.stage_entered_at).getTime(),
  ).toBeGreaterThanOrEqual(
    new Date(initial.data!.stage_entered_at).getTime(),
  );

  const history = await admin
    .from("opportunity_stage_history")
    .select("id")
    .eq("opportunity_id", lead.opportunity_id)
    .limit(1)
    .single();
  const updateHistory = await admin
    .from("opportunity_stage_history")
    .update({ reason: "tentativa de reescrita" })
    .eq("id", history.data!.id);
  expect(updateHistory.error?.code).toBe("42501");
  const deleteHistory = await admin
    .from("opportunity_stage_history")
    .delete()
    .eq("id", history.data!.id);
  expect(deleteHistory.error?.code).toBe("42501");
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
    view_scope: "my_pipeline",
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
  const ownerCrossTransition = await transition(
    outsiderOpportunityId,
    "in_service",
    999,
  );
  expect(ownerCrossTransition.error?.code).toBe("42501");
  const brokerStaleTransition = await transition(
    hiddenLead.opportunity_id,
    "in_service",
    999,
    "",
    false,
    broker,
  );
  expect(brokerStaleTransition.error?.code).toBe("42501");
  const outsiderOwnList = await outsider.rpc("get_lead_list", {
    target_operation_id: outsiderOperationId,
    view_scope: "operation",
  });
  expect(
    (outsiderOwnList.data as Array<{ id: string }>).map((lead) => lead.id),
  ).toContain(outsiderOpportunityId);
});

test("my_pipeline stays personal and redacted for dual-role users and requires a coherent active Call assignment", async () => {
  const contactId = randomUUID();
  const opportunityId = randomUUID();
  const callId = randomUUID();
  await insertFixture("contacts", {
    display_name: "Identidade protegida no pipeline pessoal",
    id: contactId,
    organization_id: organizationId,
  });
  await insertFixture("contact_phones", {
    contact_id: contactId,
    e164: "+5511666611111",
    is_primary: true,
    organization_id: organizationId,
    original_value: "(11) 66666-1111",
  });
  await insertFixture("opportunities", {
    assigned_membership_id: dualRoleMembershipId,
    contact_id: contactId,
    id: opportunityId,
    operation_id: operationId,
    organization_id: organizationId,
    source_type: "meta",
    stage: "call_scheduled",
  });
  await insertFixture("calls", {
    assigned_membership_id: dualRoleMembershipId,
    id: callId,
    operation_id: operationId,
    opportunity_id: opportunityId,
    organization_id: organizationId,
    scheduled_for: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    status: "scheduled",
  });
  await insertFixture("call_assignments", {
    call_id: callId,
    membership_id: dualRoleMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });

  const operationView = await dualRole.rpc("get_pipeline_board", {
    target_operation_id: operationId,
    view_scope: "operation",
  });
  expect(operationView.error).toBeNull();
  const fullCard = (
    operationView.data as {
      cards: Array<Record<string, unknown>>;
    }
  ).cards.find((card) => card.id === opportunityId);
  expect(fullCard).toEqual(
    expect.objectContaining({
      display_name: "Identidade protegida no pipeline pessoal",
      phone_e164: "+5511666611111",
      redacted: false,
      view_scope: "operation",
    }),
  );

  const personalView = await dualRole.rpc("get_pipeline_board", {
    target_operation_id: operationId,
    view_scope: "my_pipeline",
  });
  expect(personalView.error).toBeNull();
  const personalCard = (
    personalView.data as {
      cards: Array<Record<string, unknown>>;
    }
  ).cards.find((card) => card.id === opportunityId);
  expect(personalCard).toEqual(
    expect.objectContaining({
      contact_id: null,
      display_name: null,
      phone_e164: null,
      redacted: true,
      source_type: null,
      view_scope: "my_pipeline",
    }),
  );

  const brokerDirectRead = await broker
    .from("contacts")
    .select("id")
    .eq("id", contactId);
  expect(brokerDirectRead.data).toEqual([]);
  const brokerDetail = await broker.rpc("get_lead_detail", {
    target_opportunity_id: opportunityId,
  });
  expect(brokerDetail.error?.code).toBe("42501");

  const divergentContactId = randomUUID();
  const divergentOpportunityId = randomUUID();
  const divergentCallId = randomUUID();
  await insertFixture("contacts", {
    display_name: "Atribuição divergente",
    id: divergentContactId,
    organization_id: organizationId,
  });
  await insertFixture("opportunities", {
    assigned_membership_id: dualRoleMembershipId,
    contact_id: divergentContactId,
    id: divergentOpportunityId,
    operation_id: operationId,
    organization_id: organizationId,
    stage: "call_scheduled",
  });
  await insertFixture("calls", {
    assigned_membership_id: brokerMembershipId,
    id: divergentCallId,
    operation_id: operationId,
    opportunity_id: divergentOpportunityId,
    organization_id: organizationId,
    scheduled_for: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    status: "scheduled",
  });
  await insertFixture("call_assignments", {
    call_id: divergentCallId,
    membership_id: brokerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  const divergentView = await dualRole.rpc("get_pipeline_board", {
    target_operation_id: operationId,
    view_scope: "my_pipeline",
  });
  expect(
    (
      divergentView.data as {
        cards: Array<{ id: string }>;
      }
    ).cards.some((card) => card.id === divergentOpportunityId),
  ).toBe(false);
});

test("keeps Contact access and merge authorization isolated between Operations in the same organization", async () => {
  const visible = await createManualLead({
    name: "Contato da Operação autorizada",
    phone: "(11) 95550-1010",
  });
  const secondOperationContactId = randomUUID();
  const secondOperationOpportunityId = randomUUID();
  await insertFixture("contacts", {
    display_name: "Contato de outra Operação",
    id: secondOperationContactId,
    organization_id: organizationId,
  });
  await insertFixture("contact_phones", {
    contact_id: secondOperationContactId,
    e164: "+5511955502020",
    is_primary: true,
    organization_id: organizationId,
    original_value: "(11) 95550-2020",
  });
  await insertFixture("opportunities", {
    contact_id: secondOperationContactId,
    id: secondOperationOpportunityId,
    operation_id: sameOrganizationSecondOperationId,
    organization_id: organizationId,
    stage: "new",
  });

  const crossOperationContact = await owner
    .from("contacts")
    .select("id")
    .eq("id", secondOperationContactId);
  expect(crossOperationContact.data).toEqual([]);
  const crossOperationPhone = await owner
    .from("contact_phones")
    .select("id")
    .eq("contact_id", secondOperationContactId);
  expect(crossOperationPhone.data).toEqual([]);

  const candidates = await owner.rpc("get_contact_merge_candidates", {
    excluded_contact_id: visible.contact_id,
    target_operation_id: operationId,
  });
  expect(candidates.error).toBeNull();
  expect(
    (candidates.data as Array<{ id: string }>).some(
      (candidate) => candidate.id === secondOperationContactId,
    ),
  ).toBe(false);

  const forbiddenMerge = await owner.rpc("merge_contacts", {
    duplicate_contact_id: secondOperationContactId,
    expected_duplicate_version: await contactVersion(
      secondOperationContactId,
    ),
    expected_primary_version: await contactVersion(visible.contact_id),
    primary_contact_id: visible.contact_id,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(forbiddenMerge.error?.code).toBe("42501");
});

test("keeps observations and source details behind the management detail RPC", async () => {
  const lead = await createManualLead({
    name: "Detalhes variáveis protegidos",
    phone: "(11) 95550-3030",
    source: "origem protegida",
  });

  const directObservations = await owner
    .from("contact_phone_observations")
    .select("*")
    .eq("contact_id", lead.contact_id);
  expect(directObservations.error?.code).toBe("42501");
  const directSources = await owner
    .from("source_attributions")
    .select("*")
    .eq("opportunity_id", lead.opportunity_id);
  expect(directSources.error?.code).toBe("42501");

  const detail = await owner.rpc("get_lead_detail", {
    target_opportunity_id: lead.opportunity_id,
  });
  expect(detail.error).toBeNull();
  expect(detail.data).toEqual(
    expect.objectContaining({
      phones: [
        expect.objectContaining({
          observations: [
            expect.objectContaining({
              original_value: "(11) 95550-3030",
            }),
          ],
        }),
      ],
      sources: [
        expect.objectContaining({ source_type: "origem protegida" }),
      ],
    }),
  );
});

test("rejects divergent organization, Operation, Contact and Opportunity aggregate references", async () => {
  const first = await createManualLead({
    name: "Agregado A",
    phone: "(11) 95550-4040",
  });
  const second = await createManualLead({
    name: "Agregado B",
    phone: "(11) 95550-5050",
  });

  const divergentConversation = await admin.from("conversations").insert({
    contact_id: first.contact_id,
    operation_id: operationId,
    opportunity_id: second.opportunity_id,
    organization_id: organizationId,
    ownership_type: "pedro",
  });
  expect(divergentConversation.error?.code).toBe("23503");

  const divergentSource = await admin.from("source_attributions").insert({
    contact_id: first.contact_id,
    operation_id: sameOrganizationSecondOperationId,
    opportunity_id: first.opportunity_id,
    organization_id: organizationId,
    source_type: "divergente",
  });
  expect(divergentSource.error?.code).toBe("23503");
});

test("manual merge is versioned, reversible and preserves identity, opt-out, origins and histories", async () => {
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
    expected_duplicate_version: await contactVersion(duplicate.contact_id),
    expected_primary_version: await contactVersion(primary.contact_id),
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
    expected_duplicate_version: await contactVersion(duplicate.contact_id),
    expected_primary_version: await contactVersion(primary.contact_id),
    primary_contact_id: primary.contact_id,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(merged.error).toBeNull();
  const mergeResult = merged.data as {
    contact_merge_id: string;
    duplicate_version: number;
    primary_version: number;
  };

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

  const staleReversal = await owner.rpc("reverse_contact_merge", {
    expected_duplicate_version: mergeResult.duplicate_version + 1,
    expected_primary_version: mergeResult.primary_version,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_contact_merge_id: mergeResult.contact_merge_id,
  });
  expect(staleReversal.error?.code).toBe("40001");

  const reversed = await owner.rpc("reverse_contact_merge", {
    expected_duplicate_version: mergeResult.duplicate_version,
    expected_primary_version: mergeResult.primary_version,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_contact_merge_id: mergeResult.contact_merge_id,
  });
  expect(reversed.error).toBeNull();
  expect(reversed.data).toEqual(
    expect.objectContaining({
      contact_merge_id: mergeResult.contact_merge_id,
      reversed: true,
    }),
  );

  const restoredContact = await admin
    .from("contacts")
    .select("merged_into_contact_id, status")
    .eq("id", duplicate.contact_id)
    .single();
  expect(restoredContact.data).toEqual({
    merged_into_contact_id: null,
    status: "active",
  });
  const restoredPhones = await admin
    .from("contact_phones")
    .select("e164")
    .eq("contact_id", duplicate.contact_id);
  expect(restoredPhones.data).toEqual([{ e164: duplicate.phone_e164 }]);
  const restoredOpportunities = await admin
    .from("opportunities")
    .select("id")
    .eq("contact_id", duplicate.contact_id);
  expect(restoredOpportunities.data).toEqual([
    { id: duplicate.opportunity_id },
  ]);

  const secondReversal = await owner.rpc("reverse_contact_merge", {
    expected_duplicate_version: mergeResult.duplicate_version + 1,
    expected_primary_version: mergeResult.primary_version + 1,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_contact_merge_id: mergeResult.contact_merge_id,
  });
  expect(secondReversal.error?.code).toBe("23514");

  const secondMerge = await owner.rpc("merge_contacts", {
    duplicate_contact_id: duplicate.contact_id,
    expected_duplicate_version: await contactVersion(duplicate.contact_id),
    expected_primary_version: await contactVersion(primary.contact_id),
    primary_contact_id: primary.contact_id,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(secondMerge.error).toBeNull();
  const secondMergeResult = secondMerge.data as {
    contact_merge_id: string;
  };
  expect(secondMergeResult.contact_merge_id).not.toBe(
    mergeResult.contact_merge_id,
  );

  const mergeCycles = await database<
    { active_merge_id: string; merge_count: number; reversal_count: number }[]
  >`
    select
      active_merge.contact_merge_id as active_merge_id,
      (
        select count(*)::int
        from public.contact_merges as merge_log
        where merge_log.merged_contact_id = ${duplicate.contact_id}
      ) as merge_count,
      (
        select count(*)::int
        from public.contact_merge_reversals as reversal
        join public.contact_merges as merge_log
          on merge_log.id = reversal.contact_merge_id
        where merge_log.merged_contact_id = ${duplicate.contact_id}
      ) as reversal_count
    from private.active_contact_merges as active_merge
    where active_merge.merged_contact_id = ${duplicate.contact_id}
  `;
  expect(mergeCycles).toEqual([
    {
      active_merge_id: secondMergeResult.contact_merge_id,
      merge_count: 2,
      reversal_count: 1,
    },
  ]);
});

test("reversal aborts atomically when any snapshotted aggregate changed after merge", async () => {
  const aggregateKinds = [
    "phone",
    "phone_observation",
    "participant",
    "source",
    "opportunity",
    "conversation",
    "opt_out",
  ] as const;

  for (const [index, aggregateKind] of aggregateKinds.entries()) {
    const serial = String(1200 + index);
    const primary = await createManualLead({
      name: `Snapshot principal ${aggregateKind}`,
      phone: `(11) 93000-${serial}`,
      source: "snapshot-primary",
    });
    const duplicate = await createManualLead({
      name: `Snapshot duplicado ${aggregateKind}`,
      phone: `(11) 94000-${serial}`,
      source: "snapshot-duplicate",
    });
    const participantId = randomUUID();
    const conversationId = randomUUID();
    const optOutId = randomUUID();
    await insertFixture("opportunity_participants", {
      contact_id: duplicate.contact_id,
      display_name: `Participante ${aggregateKind}`,
      id: participantId,
      opportunity_id: duplicate.opportunity_id,
      organization_id: organizationId,
    });
    await insertFixture("conversations", {
      closed_at: new Date().toISOString(),
      contact_id: duplicate.contact_id,
      id: conversationId,
      operation_id: operationId,
      opportunity_id: duplicate.opportunity_id,
      organization_id: organizationId,
      status: "closed",
    });
    await insertFixture("opt_outs", {
      contact_id: duplicate.contact_id,
      id: optOutId,
      organization_id: organizationId,
      phone_e164: duplicate.phone_e164,
      reason: `Opt-out original ${aggregateKind}`,
    });

    const duplicatePhone = await admin
      .from("contact_phones")
      .select("id")
      .eq("contact_id", duplicate.contact_id)
      .single();
    expect(duplicatePhone.error).toBeNull();
    const duplicateObservation = await admin
      .from("contact_phone_observations")
      .select("id")
      .eq("contact_id", duplicate.contact_id)
      .single();
    expect(duplicateObservation.error).toBeNull();
    const duplicateSource = await admin
      .from("source_attributions")
      .select("id")
      .eq("opportunity_id", duplicate.opportunity_id)
      .single();
    expect(duplicateSource.error).toBeNull();

    const merged = await owner.rpc("merge_contacts", {
      duplicate_contact_id: duplicate.contact_id,
      expected_duplicate_version: await contactVersion(duplicate.contact_id),
      expected_primary_version: await contactVersion(primary.contact_id),
      primary_contact_id: primary.contact_id,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
    });
    expect(merged.error, aggregateKind).toBeNull();
    const mergeResult = merged.data as {
      contact_merge_id: string;
      duplicate_version: number;
      primary_version: number;
    };

    if (aggregateKind === "phone") {
      const tamper = await admin
        .from("contact_phones")
        .update({ verified_at: new Date().toISOString() })
        .eq("id", duplicatePhone.data!.id);
      expect(tamper.error).toBeNull();
    } else if (aggregateKind === "phone_observation") {
      const tamper = await admin
        .from("contact_phone_observations")
        .update({ source_type: "alterado-depois-da-fusao" })
        .eq("id", duplicateObservation.data!.id);
      expect(tamper.error).toBeNull();
    } else if (aggregateKind === "participant") {
      const tamper = await admin
        .from("opportunity_participants")
        .update({ display_name: "Participante alterado" })
        .eq("id", participantId);
      expect(tamper.error).toBeNull();
    } else if (aggregateKind === "source") {
      const tamper = await admin
        .from("source_attributions")
        .delete()
        .eq("id", duplicateSource.data!.id);
      expect(tamper.error).toBeNull();
    } else if (aggregateKind === "opportunity") {
      const tamper = await admin
        .from("opportunities")
        .update({ source_type: "alterado-depois-da-fusao" })
        .eq("id", duplicate.opportunity_id);
      expect(tamper.error).toBeNull();
    } else if (aggregateKind === "conversation") {
      const tamper = await admin
        .from("conversations")
        .update({ updated_at: new Date(Date.now() + 60_000).toISOString() })
        .eq("id", conversationId);
      expect(tamper.error).toBeNull();
    } else {
      const tamper = await admin
        .from("opt_outs")
        .update({ reason: "Pedido de não contato alterado depois da fusão" })
        .eq("id", optOutId);
      expect(tamper.error).toBeNull();
    }

    const reversal = await owner.rpc("reverse_contact_merge", {
      expected_duplicate_version: mergeResult.duplicate_version,
      expected_primary_version: mergeResult.primary_version,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_contact_merge_id: mergeResult.contact_merge_id,
    });
    expect(reversal.error?.code, aggregateKind).toBe("23514");
    expect(reversal.error?.message, aggregateKind).toContain(
      "aggregate changed",
    );

    const unchangedContact = await admin
      .from("contacts")
      .select("merged_into_contact_id, status")
      .eq("id", duplicate.contact_id)
      .single();
    expect(unchangedContact.data, aggregateKind).toEqual({
      merged_into_contact_id: primary.contact_id,
      status: "merged",
    });
    const unchangedOpportunity = await admin
      .from("opportunities")
      .select("contact_id")
      .eq("id", duplicate.opportunity_id)
      .single();
    expect(unchangedOpportunity.data?.contact_id, aggregateKind).toBe(
      primary.contact_id,
    );

    if (aggregateKind === "opt_out") {
      const preservedOptOut = await admin
        .from("opt_outs")
        .select("reason")
        .eq("id", optOutId)
        .single();
      expect(preservedOptOut.data?.reason).toBe(
        "Pedido de não contato alterado depois da fusão",
      );
    }
  }
});

test("canonical Contact locks make reciprocal merge races deterministic without deadlock", async () => {
  const first = await createManualLead({
    name: "Fusão concorrente A",
    phone: "(11) 95550-7070",
  });
  const second = await createManualLead({
    name: "Fusão concorrente B",
    phone: "(11) 95550-8080",
  });
  const firstVersion = await contactVersion(first.contact_id);
  const secondVersion = await contactVersion(second.contact_id);

  const [firstDirection, secondDirection] = await Promise.all([
    owner.rpc("merge_contacts", {
      duplicate_contact_id: second.contact_id,
      expected_duplicate_version: secondVersion,
      expected_primary_version: firstVersion,
      primary_contact_id: first.contact_id,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
    }),
    owner.rpc("merge_contacts", {
      duplicate_contact_id: first.contact_id,
      expected_duplicate_version: firstVersion,
      expected_primary_version: secondVersion,
      primary_contact_id: second.contact_id,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
    }),
  ]);

  expect(
    [firstDirection, secondDirection].filter((result) => result.error === null),
  ).toHaveLength(1);
  expect(
    [firstDirection, secondDirection].filter((result) => result.error !== null),
  ).toHaveLength(1);
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
  expect((await transition(
    postCall.opportunity_id,
    "lost",
    1,
    "Desistiu depois da Call",
  )).error).toBeNull();
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
    status: "completed",
  });
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

  const purchasedContactId = randomUUID();
  const purchasedOpportunityId = randomUUID();
  await insertFixture("contacts", {
    display_name: "Venda concluída",
    id: purchasedContactId,
    organization_id: organizationId,
  });
  await insertFixture("opportunities", {
    assigned_membership_id: brokerMembershipId,
    contact_id: purchasedContactId,
    id: purchasedOpportunityId,
    operation_id: operationId,
    organization_id: organizationId,
    stage: "purchased",
  });
  const purchasedReopen = await admin.rpc("reopen_opportunity_on_inbound", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_opportunity_id: purchasedOpportunityId,
  });
  expect(purchasedReopen.data).toBe("sale_closed");
  const purchasedTransition = await transition(
    purchasedOpportunityId,
    "lost",
    await opportunityVersion(purchasedOpportunityId),
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
