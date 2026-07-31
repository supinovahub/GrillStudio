import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const ownerPassword = `Preview-${randomUUID()}-A1!`;
const changedPassword = `Changed-${randomUUID()}-B2!`;
const suffix = randomUUID().slice(0, 8);
const ownerEmail = `owner-${suffix}@example.com`;
const brokerEmail = `broker-${suffix}@example.com`;
const outsiderEmail = `outsider-${suffix}@example.com`;
const pendingEmail = `pending-${suffix}@example.com`;

let admin: SupabaseClient;
let ownerId = "";
let brokerId = "";
let outsiderId = "";
let pendingId = "";
let ownerOrganizationId = "";
let ownerOperationId = "";
let outsiderOrganizationId = "";
let outsiderOperationId = "";
let confirmationTokenHash = "";

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

async function createMembershipFixture({
  email,
  organizationId,
  operationId,
  role = "owner",
  status,
}: {
  email: string;
  organizationId: string;
  operationId: string;
  role?: "owner" | "manager" | "broker";
  status: "active" | "pending";
}) {
  const { data, error } = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    password: ownerPassword,
  });
  if (error) {
    throw new Error(`Could not create synthetic Auth fixture: ${error.code}`);
  }

  const membershipId = randomUUID();
  await insertFixture("memberships", {
    id: membershipId,
    organization_id: organizationId,
    role,
    status,
    user_id: data.user.id,
  });
  await insertFixture("membership_operations", {
    membership_id: membershipId,
    operation_id: operationId,
    organization_id: organizationId,
  });

  return data.user.id;
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

  const url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL");
  const serviceRoleKey = requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY");
  admin = createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  ownerOrganizationId = randomUUID();
  ownerOperationId = randomUUID();
  outsiderOrganizationId = randomUUID();
  outsiderOperationId = randomUUID();

  for (const [organizationId, operationId, name, slug] of [
    [
      ownerOrganizationId,
      ownerOperationId,
      `Imobiliária Sintética ${suffix}`,
      `preview-owner-${suffix}`,
    ],
    [
      outsiderOrganizationId,
      outsiderOperationId,
      `Imobiliária Isolada ${suffix}`,
      `preview-outsider-${suffix}`,
    ],
  ]) {
    await insertFixture("organizations", {
      id: organizationId,
      name,
      slug,
    });
    await insertFixture("operations", {
      id: operationId,
      is_default: true,
      name: `Operação Sintética ${suffix}`,
      organization_id: organizationId,
    });
    await insertFixture("operation_settings", {
      operation_id: operationId,
      organization_id: organizationId,
    });
  }

  const { data: ownerLink, error: ownerError } =
    await admin.auth.admin.generateLink({
      email: ownerEmail,
      password: ownerPassword,
      type: "signup",
    });
  if (ownerError) {
    throw new Error(`Could not create confirmation link: ${ownerError.code}`);
  }

  ownerId = ownerLink.user.id;
  confirmationTokenHash = ownerLink.properties.hashed_token;
  const ownerMembershipId = randomUUID();
  await insertFixture("memberships", {
    id: ownerMembershipId,
    organization_id: ownerOrganizationId,
    role: "owner",
    status: "active",
    user_id: ownerId,
  });
  await insertFixture("membership_operations", {
    membership_id: ownerMembershipId,
    operation_id: ownerOperationId,
    organization_id: ownerOrganizationId,
  });

  outsiderId = await createMembershipFixture({
    email: outsiderEmail,
    operationId: outsiderOperationId,
    organizationId: outsiderOrganizationId,
    status: "active",
  });
  brokerId = await createMembershipFixture({
    email: brokerEmail,
    operationId: ownerOperationId,
    organizationId: ownerOrganizationId,
    role: "broker",
    status: "active",
  });
  pendingId = await createMembershipFixture({
    email: pendingEmail,
    operationId: ownerOperationId,
    organizationId: ownerOrganizationId,
    status: "pending",
  });

  await insertFixture("system_pauses", {
    activated_by: outsiderId,
    correlation_id: randomUUID(),
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
    origin: "automatic",
    reason: "Pausa sintética para validar isolamento entre Imobiliárias",
    trace_id: randomUUID(),
  });
});

test.afterAll(async () => {
  if (!admin) {
    return;
  }

  for (const operationId of [ownerOperationId, outsiderOperationId]) {
    if (operationId) {
      await admin
        .from("membership_operations")
        .delete()
        .eq("operation_id", operationId);
      await admin.from("system_pauses").delete().eq("operation_id", operationId);
      await admin.from("operation_settings").delete().eq("operation_id", operationId);
      await admin.from("operations").delete().eq("id", operationId);
    }
  }

  for (const userId of [ownerId, brokerId, outsiderId, pendingId]) {
    if (userId) {
      await admin.auth.admin.deleteUser(userId);
    }
  }

  for (const organizationId of [
    ownerOrganizationId,
    outsiderOrganizationId,
  ]) {
    if (organizationId) {
      await admin.from("organizations").delete().eq("id", organizationId);
    }
  }
});

test("confirms email, protects the session, and renders an unequivocal Preview shell", async ({
  page,
}) => {
  const anonymousResponse = await page.goto("/app/central");
  await expect(page).toHaveURL(/\/entrar\?next=%2Fapp%2Fcentral$/);
  await expect(page.getByRole("heading", { name: "Entre na sua Operação" })).toBeVisible();

  expect(anonymousResponse?.headers()["x-trace-id"]).toMatch(
    /^[0-9a-f-]{36}$/,
  );
  expect(anonymousResponse?.headers()["x-correlation-id"]).toMatch(
    /^[0-9a-f-]{36}$/,
  );

  await page.goto(
    `/auth/confirm?token_hash=${confirmationTokenHash}&type=signup&next=/app/central`,
  );

  await expect(page).toHaveURL(/\/app\/central$/);
  await expect(
    page.getByRole("heading", { name: "Fundação da Operação" }),
  ).toBeVisible();
  await expect(page.getByText(`Imobiliária Sintética ${suffix}`).first()).toBeVisible();
  await expect(page.getByText(`Operação Sintética ${suffix}`).first()).toBeVisible();
  await expect(
    page
      .getByText(
        `Preview segura — PR #${requiredEnvironment("GITHUB_PR_NUMBER")}`,
      )
      .first(),
  ).toBeVisible();
  await expect(page.getByText("Produção desligada").first()).toBeVisible();
  await expect(page.getByText("Dados sintéticos · sem egressos reais")).toBeVisible();

  const manifest = await page.request.get("/manifest.webmanifest");
  expect(manifest.ok()).toBe(true);
  await expect
    .poll(() => page.context().serviceWorkers().length)
    .toBeGreaterThan(0);
});

test("routes the Corretor to Hoje and refuses Central settings", async ({
  page,
}) => {
  await page.goto("/entrar");
  await page.getByLabel("E-mail").fill(brokerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(ownerPassword);
  await page.getByRole("button", { name: "Entrar" }).click();

  await expect(page).toHaveURL(/\/app\/hoje$/);
  await expect(page.getByRole("heading", { name: `Operação Sintética ${suffix}` })).toBeVisible();
  await expect(page.getByText("Hoje · Corretor")).toBeVisible();

  await page.goto("/app/central");
  await expect(page).toHaveURL(/\/sem-permissao$/);
  await expect(
    page.getByRole("heading", {
      name: "A Central não está disponível para este perfil",
    }),
  ).toBeVisible();
});

test("enforces every exposed table boundary and denies all client writes", async () => {
  const url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL");
  const publishableKey = requiredEnvironment(
    "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  );

  const anonymous = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const owner = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await owner.auth.signInWithPassword({
    email: ownerEmail,
    password: ownerPassword,
  });

  const pending = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await pending.auth.signInWithPassword({
    email: pendingEmail,
    password: ownerPassword,
  });

  const outsider = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await outsider.auth.signInWithPassword({
    email: outsiderEmail,
    password: ownerPassword,
  });

  const broker = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await broker.auth.signInWithPassword({
    email: brokerEmail,
    password: ownerPassword,
  });

  const probes = [
    {
      crossValue: outsiderOrganizationId,
      filter: "id",
      ownValue: ownerOrganizationId,
      table: "organizations",
    },
    {
      crossValue: outsiderOperationId,
      filter: "id",
      ownValue: ownerOperationId,
      table: "operations",
    },
    {
      crossValue: outsiderOrganizationId,
      filter: "organization_id",
      ownValue: ownerOrganizationId,
      table: "memberships",
    },
    {
      crossValue: outsiderOperationId,
      filter: "operation_id",
      ownValue: ownerOperationId,
      table: "membership_operations",
    },
    {
      crossValue: outsiderOperationId,
      filter: "operation_id",
      ownValue: ownerOperationId,
      table: "operation_settings",
    },
    {
      crossValue: outsiderOperationId,
      filter: "operation_id",
      ownValue: ownerOperationId,
      table: "system_pauses",
    },
  ] as const;

  for (const probe of probes) {
    const anonymousRead = await anonymous.from(probe.table).select("*");
    expect(anonymousRead.error, `${probe.table}: anonymous read`).toBeNull();
    expect(anonymousRead.data).toEqual([]);

    const pendingRead = await pending.from(probe.table).select("*");
    expect(pendingRead.error, `${probe.table}: pending read`).toBeNull();
    expect(pendingRead.data).toEqual([]);

    const crossRead = await owner
      .from(probe.table)
      .select("*")
      .eq(probe.filter, probe.crossValue);
    expect(crossRead.error, `${probe.table}: cross-organization read`).toBeNull();
    expect(crossRead.data).toEqual([]);

    const insertAttempt = await owner.from(probe.table).insert({});
    expect(insertAttempt.error, `${probe.table}: insert`).not.toBeNull();

    const updateAttempt = await owner
      .from(probe.table)
      .update({})
      .eq(probe.filter, probe.ownValue);
    expect(updateAttempt.error, `${probe.table}: update`).not.toBeNull();

    const deleteAttempt = await owner
      .from(probe.table)
      .delete()
      .eq(probe.filter, probe.ownValue);
    expect(deleteAttempt.error, `${probe.table}: delete`).not.toBeNull();
  }

  const ownerSettings = await owner
    .from("operation_settings")
    .select("operation_id")
    .eq("operation_id", ownerOperationId);
  expect(ownerSettings.data).toEqual([{ operation_id: ownerOperationId }]);

  const outsiderPause = await outsider
    .from("system_pauses")
    .select("origin, reason")
    .eq("operation_id", outsiderOperationId);
  expect(outsiderPause.data).toEqual([
    {
      origin: "automatic",
      reason: "Pausa sintética para validar isolamento entre Imobiliárias",
    },
  ]);

  const brokerSettings = await broker
    .from("operation_settings")
    .select("operation_id")
    .eq("operation_id", ownerOperationId);
  expect(brokerSettings.data).toEqual([]);
  const brokerPause = await broker
    .from("system_pauses")
    .select("id")
    .eq("operation_id", ownerOperationId);
  expect(brokerPause.data).toEqual([]);

  const reassignmentAttempt = await owner
    .from("operations")
    .update({ organization_id: outsiderOrganizationId })
    .eq("id", ownerOperationId);
  expect(reassignmentAttempt.error).not.toBeNull();
});

test("allows the Dono to contain Pedro and manage sessions", async ({ page }) => {
  const url = requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL");
  const publishableKey = requiredEnvironment(
    "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  );

  await page.goto("/entrar");
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(ownerPassword);
  await page.getByRole("button", { name: "Entrar" }).click();

  const secondary = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: secondarySignIn, error: secondarySignInError } =
    await secondary.auth.signInWithPassword({
      email: ownerEmail,
      password: ownerPassword,
    });
  expect(secondarySignInError).toBeNull();
  const secondaryRefreshToken = secondarySignIn.session?.refresh_token;
  expect(secondaryRefreshToken).toBeTruthy();

  await page.getByText("Acionar kill switch", { exact: true }).click();
  await page
    .getByRole("checkbox", { name: "Entendo o impacto desta contenção." })
    .check();
  await page.getByRole("button", { name: "Confirmar pausa global" }).click();
  await expect(page.getByText("Pausa global ativa")).toBeVisible();
  await expect(page.getByText("Pedro: Pausa global")).toBeVisible();

  const pause = await admin
    .from("system_pauses")
    .select("origin, reason, status")
    .eq("operation_id", ownerOperationId)
    .single();
  expect(pause.error).toBeNull();
  expect(pause.data).toEqual({
    origin: "manual",
    reason: "Kill switch acionado pela interface",
    status: "active",
  });

  await page.locator(".profile-menu summary").click();
  await page.getByRole("button", { name: "Encerrar outras sessões" }).click();
  await expect(page.getByText("As outras sessões foram encerradas.")).toBeVisible();

  const secondaryRefresh = await secondary.auth.refreshSession({
    refresh_token: secondaryRefreshToken!,
  });
  expect(secondaryRefresh.error).not.toBeNull();
  expect(secondaryRefresh.data.session).toBeNull();

  const globalPeer = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: globalPeerSignIn, error: globalPeerSignInError } =
    await globalPeer.auth.signInWithPassword({
      email: ownerEmail,
      password: ownerPassword,
    });
  expect(globalPeerSignInError).toBeNull();
  const globalPeerRefreshToken = globalPeerSignIn.session?.refresh_token;
  expect(globalPeerRefreshToken).toBeTruthy();

  await page.locator(".profile-menu summary").click();
  await page.getByRole("button", { name: "Encerrar todas as sessões" }).click();
  await expect(page).toHaveURL(/\/entrar\?sessao=encerrada$/);

  const globalPeerRefresh = await globalPeer.auth.refreshSession({
    refresh_token: globalPeerRefreshToken!,
  });
  expect(globalPeerRefresh.error).not.toBeNull();
  expect(globalPeerRefresh.data.session).toBeNull();
});

test("completes password recovery without sending external email", async ({
  page,
}) => {
  await page.goto("/recuperar-senha");
  await expect(page.getByRole("heading", { name: "Redefina sua senha" })).toBeVisible();

  const { data, error } = await admin.auth.admin.generateLink({
    email: ownerEmail,
    type: "recovery",
  });
  if (error) {
    throw new Error(`Could not create recovery link: ${error.code}`);
  }

  await page.goto(
    `/auth/confirm?token_hash=${data.properties.hashed_token}&type=recovery&next=/redefinir-senha`,
  );
  await expect(page.getByRole("heading", { name: "Crie uma nova senha" })).toBeVisible();
  await page.getByLabel("Nova senha", { exact: true }).fill(changedPassword);
  await page.getByLabel("Repita a nova senha").fill(changedPassword);
  await page.getByRole("button", { name: "Salvar nova senha" }).click();
  await expect(page).toHaveURL(/\/entrar\?senha=alterada$/);

  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(changedPassword);
  await page.getByRole("button", { name: "Entrar" }).click();
  await expect(page).toHaveURL(/\/app\/central$/);
});
