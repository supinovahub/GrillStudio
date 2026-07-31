import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const suffix = randomUUID().slice(0, 8);
const password = `Preview-${randomUUID()}-A1!`;
const ownerEmail = `team-owner-${suffix}@example.com`;
const invitedEmail = `team-broker-${suffix}@example.com`;

let admin: SupabaseClient;
let owner: SupabaseClient;
let database: Sql;
let ownerId = "";
let ownerMembershipId = "";
let organizationId = "";
let operationId = "";
let individualInvitationToken = "";
let managerId = "";
let managerMembershipId = "";
let brokerId = "";
let brokerMembershipId = "";
let outsiderOrganizationId = "";
let outsiderOperationId = "";
const createdUserIds: string[] = [];

test.describe.configure({ mode: "serial" });

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required for the Preview black-box suite`);
  }
  return value;
}

async function insertFixture(table: string, values: Record<string, unknown>) {
  const { error } = await admin.from(table).insert(values);
  if (error) {
    throw new Error(`Could not create synthetic ${table} fixture: ${error.code}`);
  }
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
  ownerMembershipId = randomUUID();
  const { data, error } = await admin.auth.admin.createUser({
    email: ownerEmail,
    email_confirm: true,
    password,
  });
  if (error) {
    throw new Error(`Could not create synthetic owner: ${error.code}`);
  }
  ownerId = data.user.id;
  createdUserIds.push(ownerId);

  await insertFixture("organizations", {
    id: organizationId,
    name: `Imobiliária Equipe ${suffix}`,
    slug: `preview-team-${suffix}`,
  });
  await insertFixture("operations", {
    id: operationId,
    is_default: true,
    name: `Operação Equipe ${suffix}`,
    organization_id: organizationId,
  });
  await insertFixture("operation_settings", {
    operation_id: operationId,
    organization_id: organizationId,
  });
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

  owner = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const { error: signInError } = await owner.auth.signInWithPassword({
    email: ownerEmail,
    password,
  });
  if (signInError) {
    throw new Error(`Could not authenticate synthetic owner: ${signInError.code}`);
  }
});

test.afterAll(async () => {
  if (!admin) {
    return;
  }

  for (const targetOperationId of [operationId, outsiderOperationId]) {
    if (!targetOperationId) {
      continue;
    }
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
  for (const targetOrganizationId of [
    organizationId,
    outsiderOrganizationId,
  ]) {
    if (targetOrganizationId) {
      await admin.from("organizations").delete().eq("id", targetOrganizationId);
    }
  }
  if (database) {
    await database.end();
  }
});

test("Dono creates an invitation through the protected Supabase boundary", async () => {
  const { data, error } = await owner.rpc("create_individual_invitation", {
    invite_email: invitedEmail,
    invite_operation_id: operationId,
    invite_roles: ["broker"],
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
  });

  expect(error).toBeNull();
  expect(data).toEqual([
    expect.objectContaining({
      email: invitedEmail,
      predefined_roles: ["broker"],
    }),
  ]);
  individualInvitationToken = data![0].token;
});

test("general invitation link pauses and regeneration invalidates its previous address", async () => {
  const context = {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
  };
  const created = await owner.rpc("create_general_invitation_link", {
    ...context,
    target_operation_id: operationId,
  });
  expect(created.error).toBeNull();
  const original = created.data![0];

  const anonymous = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const activeEntry = await anonymous.rpc("get_invitation_entry", {
    invitation_token: original.token,
  });
  expect(activeEntry.data).toEqual([
    expect.objectContaining({
      invitation_kind: "general",
      link_status: "active",
    }),
  ]);

  const paused = await owner.rpc("set_general_invitation_link_status", {
    ...context,
    target_link_id: original.id,
    target_status: "paused",
  });
  expect(paused.error).toBeNull();
  const pausedReservation = await admin.rpc(
    "reserve_invitation_registration",
    {
      registration_email: `paused-${suffix}@example.com`,
      registration_token: original.token,
      request_fingerprint: randomUUID().replaceAll("-", ""),
    },
  );
  expect(pausedReservation.error).toBeNull();
  expect(pausedReservation.data).toEqual([]);

  const regenerated = await owner.rpc("regenerate_general_invitation_link", {
    ...context,
    target_link_id: original.id,
  });
  expect(regenerated.error).toBeNull();
  expect(regenerated.data![0].token).not.toBe(original.token);

  const previousEntry = await anonymous.rpc("get_invitation_entry", {
    invitation_token: original.token,
  });
  expect(previousEntry.data?.[0].link_status).toBe("replaced");
  const replacementEntry = await anonymous.rpc("get_invitation_entry", {
    invitation_token: regenerated.data![0].token,
  });
  expect(replacementEntry.data?.[0].link_status).toBe("active");
});

test("registration stays pending until confirmed and Dono can grant cumulative roles", async () => {
  const managerEmail = `team-manager-${suffix}@example.com`;
  const reservation = await admin.rpc("reserve_invitation_registration", {
    registration_email: invitedEmail,
    registration_token: individualInvitationToken,
    request_fingerprint: randomUUID().replaceAll("-", ""),
  });
  expect(reservation.error).toBeNull();
  expect(reservation.data).toEqual([
    expect.objectContaining({
      invitation_kind: "individual",
      predefined_roles: ["broker"],
    }),
  ]);

  const authUser = await admin.auth.admin.createUser({
    email: invitedEmail,
    email_confirm: false,
    password,
  });
  expect(authUser.error).toBeNull();
  managerId = authUser.data.user!.id;
  createdUserIds.push(managerId);

  const completion = await admin.rpc("complete_invitation_registration", {
    registration_email: invitedEmail,
    registration_full_name: "Gestora Sintética",
    registration_token: individualInvitationToken,
    registration_user_id: managerId,
    registration_whatsapp: "+5511999999999",
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
  });
  expect(completion.error).toBeNull();
  managerMembershipId = completion.data!;

  const prematureApproval = await owner.rpc("approve_membership", {
    approved_permissions: ["manage_members"],
    approved_roles: ["manager", "broker"],
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_membership_id: managerMembershipId,
    target_operation_id: operationId,
  });
  expect(prematureApproval.error?.message).toContain(
    "member email is not confirmed",
  );

  const confirmation = await admin.auth.admin.updateUserById(managerId, {
    email_confirm: true,
  });
  expect(confirmation.error).toBeNull();

  const pendingWorkspace = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const pendingSignIn = await pendingWorkspace.auth.signInWithPassword({
    email: invitedEmail,
    password,
  });
  expect(pendingSignIn.error).toBeNull();
  const pendingAccess = await pendingWorkspace.rpc("get_member_workspace_v2");
  expect(pendingAccess.error).toBeNull();
  expect(pendingAccess.data).toEqual([]);
  for (const table of [
    "membership_roles",
    "membership_permissions",
    "staff_profiles",
    "opportunities",
    "calls",
    "call_offers",
    "call_assignments",
  ]) {
    const pendingRead = await pendingWorkspace.from(table).select("*");
    expect(pendingRead.error, `${table}: pending`).toBeNull();
    expect(pendingRead.data, `${table}: pending`).toEqual([]);
  }

  const approval = await owner.rpc("approve_membership", {
    approved_permissions: ["manage_members"],
    approved_roles: ["manager", "broker"],
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_membership_id: managerMembershipId,
    target_operation_id: operationId,
  });
  expect(approval.error).toBeNull();

  const manager = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  await manager.auth.signInWithPassword({ email: invitedEmail, password });
  const workspace = await manager.rpc("get_member_workspace_v2");
  expect(workspace.data).toEqual([
    expect.objectContaining({
      can_manage_members: true,
      member_permissions: ["manage_members"],
      member_role: "manager",
      member_roles: ["broker", "manager"],
    }),
  ]);

  const managerBrokerInvite = await manager.rpc(
    "create_individual_invitation",
    {
      invite_email: managerEmail,
      invite_operation_id: operationId,
      invite_roles: ["broker"],
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
    },
  );
  expect(managerBrokerInvite.error).toBeNull();
  const forbiddenManagerInvite = await manager.rpc(
    "create_individual_invitation",
    {
      invite_email: `forbidden-manager-${suffix}@example.com`,
      invite_operation_id: operationId,
      invite_roles: ["manager"],
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
    },
  );
  expect(forbiddenManagerInvite.error?.code).toBe("42501");

  const propertyTransferAttempt = await manager
    .from("memberships")
    .update({ user_id: managerId })
    .eq("id", ownerMembershipId);
  expect(propertyTransferAttempt.error?.code).toBe("42501");
  const permissionEscalationAttempt = await manager
    .from("membership_permissions")
    .insert({
      granted_by_user_id: managerId,
      membership_id: managerMembershipId,
      organization_id: organizationId,
      permission: "manage_privacy",
    });
  expect(permissionEscalationAttempt.error?.code).toBe("42501");
});

test("anonymous, pending, revoked, cross-Imobiliária and Corretor scopes are denied", async () => {
  const brokerEmail = `team-active-broker-${suffix}@example.com`;
  const brokerUser = await admin.auth.admin.createUser({
    email: brokerEmail,
    email_confirm: true,
    password,
  });
  expect(brokerUser.error).toBeNull();
  brokerId = brokerUser.data.user!.id;
  createdUserIds.push(brokerId);
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
    full_name: "Corretor Sintético",
    membership_id: brokerMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511888888888",
  });

  const url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL");
  const key = requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  const anonymous = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const broker = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await broker.auth.signInWithPassword({ email: brokerEmail, password });

  for (const table of [
    "membership_roles",
    "membership_permissions",
    "staff_profiles",
    "opportunities",
    "calls",
    "call_offers",
    "call_assignments",
  ]) {
    const anonymousRead = await anonymous.from(table).select("*");
    expect(anonymousRead.error?.code, `${table}: anonymous`).toBe("42501");
  }
  for (const table of ["invitation_links", "invitations"]) {
    const anonymousRead = await anonymous.from(table).select("*");
    expect(anonymousRead.error?.code, `${table}: anonymous`).toBe("42501");
    const brokerRead = await broker.from(table).select("*");
    expect(brokerRead.error?.code, `${table}: broker`).toBe("42501");
  }

  const teamAttempt = await broker.rpc("get_team_management", {
    target_operation_id: operationId,
  });
  expect(teamAttempt.error?.code).toBe("42501");

  const directDeactivation = await owner.rpc(
    "deactivate_membership_after_reauthentication",
    {
      actor_user_id: ownerId,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_membership_id: brokerMembershipId,
      target_operation_id: operationId,
    },
  );
  expect(directDeactivation.error?.code).toBe("42501");

  outsiderOrganizationId = randomUUID();
  outsiderOperationId = randomUUID();
  const outsiderMembershipId = randomUUID();
  const outsiderOpportunityId = randomUUID();
  const outsiderContactId = randomUUID();
  const outsiderEmail = `team-outsider-${suffix}@example.com`;
  const outsiderUser = await admin.auth.admin.createUser({
    email: outsiderEmail,
    email_confirm: true,
    password,
  });
  expect(outsiderUser.error).toBeNull();
  const outsiderId = outsiderUser.data.user!.id;
  createdUserIds.push(outsiderId);
  await insertFixture("organizations", {
    id: outsiderOrganizationId,
    name: `Imobiliária Externa ${suffix}`,
    slug: `preview-team-outsider-${suffix}`,
  });
  await insertFixture("operations", {
    id: outsiderOperationId,
    is_default: true,
    name: `Operação Externa ${suffix}`,
    organization_id: outsiderOrganizationId,
  });
  await insertFixture("operation_settings", {
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
  });
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
  await insertFixture("contacts", {
    display_name: "Contato Externo Sintético",
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

  const outsider = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await outsider.auth.signInWithPassword({ email: outsiderEmail, password });
  const outsiderOwnRead = await outsider
    .from("opportunities")
    .select("id")
    .eq("id", outsiderOpportunityId);
  expect(outsiderOwnRead.data).toEqual([{ id: outsiderOpportunityId }]);
  const ownerCrossRead = await owner
    .from("opportunities")
    .select("id")
    .eq("id", outsiderOpportunityId);
  expect(ownerCrossRead.data).toEqual([]);
  const brokerCrossRead = await broker
    .from("opportunities")
    .select("id")
    .eq("id", outsiderOpportunityId);
  expect(brokerCrossRead.data).toEqual([]);
});

test("deactivation revokes sessions, stops Offers and returns human work without random reassignment", async () => {
  const opportunityId = randomUUID();
  const contactId = randomUUID();
  const callId = randomUUID();
  const assignmentId = randomUUID();
  await insertFixture("contacts", {
    display_name: "Contato de Desativação Sintético",
    id: contactId,
    organization_id: organizationId,
  });
  await insertFixture("opportunities", {
    assigned_membership_id: brokerMembershipId,
    contact_id: contactId,
    id: opportunityId,
    operation_id: operationId,
    organization_id: organizationId,
    stage: "negotiation",
  });
  await insertFixture("calls", {
    assigned_membership_id: brokerMembershipId,
    id: callId,
    operation_id: operationId,
    opportunity_id: opportunityId,
    organization_id: organizationId,
    scheduled_for: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
    status: "scheduled",
  });
  await insertFixture("call_assignments", {
    call_id: callId,
    id: assignmentId,
    membership_id: brokerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insertFixture("call_offers", {
    call_id: callId,
    operation_id: operationId,
    organization_id: organizationId,
    recipient_membership_id: brokerMembershipId,
    status: "pending",
  });

  const url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL");
  const key = requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  const firstSession = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const secondSession = createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const firstSignIn = await firstSession.auth.signInWithPassword({
    email: `team-active-broker-${suffix}@example.com`,
    password,
  });
  const secondSignIn = await secondSession.auth.signInWithPassword({
    email: `team-active-broker-${suffix}@example.com`,
    password,
  });
  expect(firstSignIn.error).toBeNull();
  expect(secondSignIn.error).toBeNull();

  const impact = await owner.rpc("get_member_deactivation_impact", {
    target_membership_id: brokerMembershipId,
    target_operation_id: operationId,
  });
  expect(impact.data).toEqual([
    {
      calls_within_one_hour: 1,
      future_calls: 1,
      post_call_opportunities: 1,
    },
  ]);

  const deactivation = await admin.rpc(
    "deactivate_membership_after_reauthentication",
    {
      actor_user_id: ownerId,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_membership_id: brokerMembershipId,
      target_operation_id: operationId,
    },
  );
  expect(deactivation.error).toBeNull();
  expect(deactivation.data).toEqual([
    expect.objectContaining({
      calls_within_one_hour: 1,
      future_calls: 1,
      post_call_opportunities: 1,
    }),
  ]);

  const membership = await admin
    .from("memberships")
    .select("can_receive_calls, status")
    .eq("id", brokerMembershipId)
    .single();
  expect(membership.data).toEqual({
    can_receive_calls: false,
    status: "revoked",
  });
  const call = await admin
    .from("calls")
    .select("assigned_membership_id, status")
    .eq("id", callId)
    .single();
  expect(call.data).toEqual({
    assigned_membership_id: null,
    status: "distributing",
  });
  const opportunity = await admin
    .from("opportunities")
    .select("assigned_membership_id")
    .eq("id", opportunityId)
    .single();
  expect(opportunity.data?.assigned_membership_id).toBeNull();
  const assignment = await admin
    .from("call_assignments")
    .select("revoke_reason, revoked_at")
    .eq("id", assignmentId)
    .single();
  expect(assignment.data?.revoke_reason).toBe("member_deactivated");
  expect(assignment.data?.revoked_at).toBeTruthy();
  const offer = await admin
    .from("call_offers")
    .select("status")
    .eq("call_id", callId)
    .single();
  expect(offer.data?.status).toBe("recipient_revoked");

  const forbiddenOffer = await admin.from("call_offers").insert({
    call_id: callId,
    operation_id: operationId,
    organization_id: organizationId,
    recipient_membership_id: brokerMembershipId,
  });
  expect(forbiddenOffer.error?.code).toBe("23514");

  for (const table of [
    "memberships",
    "membership_roles",
    "membership_permissions",
    "staff_profiles",
    "opportunities",
    "calls",
    "call_offers",
    "call_assignments",
  ]) {
    const revokedRead = await firstSession.from(table).select("*");
    expect(revokedRead.error, `${table}: revoked`).toBeNull();
    expect(revokedRead.data, `${table}: revoked`).toEqual([]);
  }

  for (const session of [firstSignIn.data.session, secondSignIn.data.session]) {
    expect(session?.refresh_token).toBeTruthy();
    const refresh = await firstSession.auth.refreshSession({
      refresh_token: session!.refresh_token,
    });
    expect(refresh.error).not.toBeNull();
    expect(refresh.data.session).toBeNull();
  }

  const auditRows = await database<
    { action: string; after_state: { reauthenticated: boolean } }[]
  >`select action, after_state
    from audit.audit_events
    where target_id = ${brokerMembershipId}
      and action = 'member.deactivated'`;
  expect(auditRows).toHaveLength(1);
  expect(auditRows[0]).toEqual(
    expect.objectContaining({
      action: "member.deactivated",
      after_state: expect.objectContaining({ reauthenticated: true }),
    }),
  );
});

test("Dono creates an individual invitation with a predefined Corretor role", async ({
  page,
}) => {
  await page.goto(
    "/entrar?next=%2Fapp%2Fconfiguracoes%2Fequipe",
  );
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Entrar" }).click();

  await expect(page).toHaveURL(/\/app\/configuracoes\/equipe$/);
  await expect(
    page.getByRole("heading", { name: "Equipe e papéis" }),
  ).toBeVisible();

  await page.getByLabel("E-mail do convite").fill(invitedEmail);
  await page.getByRole("checkbox", { name: "Corretor" }).check();
  await page
    .getByRole("button", { name: "Criar convite individual" })
    .click();

  await expect(page.getByText(invitedEmail)).toBeVisible();
  await expect(page.getByText("Corretor predefinido")).toBeVisible();

  const invitationLink = page.getByRole("link", {
    name: `Abrir convite de ${invitedEmail}`,
  });
  await expect(invitationLink).toHaveAttribute("href", /\/convite\/[0-9a-f-]{36}$/);
});

test("sensitive deactivation requires the Dono password and revokes every session", async ({
  page,
}) => {
  const sensitiveBrokerEmail = `sensitive-broker-${suffix}@example.com`;
  const sensitiveBrokerMembershipId = randomUUID();
  const sensitiveBrokerUser = await admin.auth.admin.createUser({
    email: sensitiveBrokerEmail,
    email_confirm: true,
    password,
  });
  expect(sensitiveBrokerUser.error).toBeNull();
  const sensitiveBrokerId = sensitiveBrokerUser.data.user!.id;
  createdUserIds.push(sensitiveBrokerId);
  await insertFixture("memberships", {
    can_receive_calls: true,
    id: sensitiveBrokerMembershipId,
    organization_id: organizationId,
    role: "broker",
    status: "active",
    user_id: sensitiveBrokerId,
  });
  await insertFixture("membership_operations", {
    membership_id: sensitiveBrokerMembershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });
  await insertFixture("staff_profiles", {
    full_name: "Corretor de Confirmação",
    membership_id: sensitiveBrokerMembershipId,
    organization_id: organizationId,
    whatsapp: "+5511777777777",
  });

  const peer = createClient(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const peerSignIn = await peer.auth.signInWithPassword({
    email: sensitiveBrokerEmail,
    password,
  });
  expect(peerSignIn.error).toBeNull();
  const peerRefreshToken = peerSignIn.data.session?.refresh_token;
  expect(peerRefreshToken).toBeTruthy();

  await page.goto(
    "/entrar?next=%2Fapp%2Fconfiguracoes%2Fequipe",
  );
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Entrar" }).click();
  await expect(page).toHaveURL(/\/app\/configuracoes\/equipe$/);

  let brokerCard = page
    .locator("article")
    .filter({ hasText: "Corretor de Confirmação" });
  await expect(brokerCard).toBeVisible();
  await brokerCard
    .locator("summary")
    .filter({ hasText: "Ver impacto e desativar" })
    .click();
  await brokerCard.getByLabel("Confirme sua senha").fill("senha-incorreta");
  await brokerCard
    .getByRole("checkbox", {
      name: /Entendo o impacto e quero desativar Corretor de Confirmação/,
    })
    .check();
  await brokerCard.getByRole("button", { name: "Desativar Membro" }).click();
  await expect(
    page.getByText("A senha informada não confirmou sua identidade."),
  ).toBeVisible();
  const stillActive = await admin
    .from("memberships")
    .select("status")
    .eq("id", sensitiveBrokerMembershipId)
    .single();
  expect(stillActive.data?.status).toBe("active");

  brokerCard = page
    .locator("article")
    .filter({ hasText: "Corretor de Confirmação" });
  await expect(brokerCard).toBeVisible();
  await brokerCard
    .locator("summary")
    .filter({ hasText: "Ver impacto e desativar" })
    .click();
  await brokerCard.getByLabel("Confirme sua senha").fill(password);
  await brokerCard
    .getByRole("checkbox", {
      name: /Entendo o impacto e quero desativar Corretor de Confirmação/,
    })
    .check();
  await brokerCard.getByRole("button", { name: "Desativar Membro" }).click();
  await expect(
    page.getByText(
      "Membro desativado, sessões revogadas e responsabilidades devolvidas.",
    ),
  ).toBeVisible();

  const revoked = await admin
    .from("memberships")
    .select("status")
    .eq("id", sensitiveBrokerMembershipId)
    .single();
  expect(revoked.data?.status).toBe("revoked");
  const refresh = await peer.auth.refreshSession({
    refresh_token: peerRefreshToken!,
  });
  expect(refresh.error).not.toBeNull();
  expect(refresh.data.session).toBeNull();
});
