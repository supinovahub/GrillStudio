import { expect, test } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { validatePreviewEnvironment } from "../../src/lib/environment";

const ownerPassword = `Preview-${randomUUID()}-A1!`;
const changedPassword = `Changed-${randomUUID()}-B2!`;
const suffix = randomUUID().slice(0, 8);
const ownerEmail = `owner-${suffix}@example.com`;
const brokerEmail = `broker-${suffix}@example.com`;
const managerEmail = `manager-${suffix}@example.com`;
const rlsManagerEmail = `rls-manager-${suffix}@example.com`;
const outsiderEmail = `outsider-${suffix}@example.com`;
const pendingEmail = `pending-${suffix}@example.com`;

let admin: SupabaseClient;
let database: Sql;
let ownerId = "";
let brokerId = "";
let managerId = "";
let rlsManagerId = "";
let outsiderId = "";
let pendingId = "";
let unassignedUserId = "";
let ownerOrganizationId = "";
let ownerOperationId = "";
let ownerMembershipId = "";
let secondaryOperationId = "";
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
  database = postgres(requiredEnvironment("DATABASE_URL"), {
    max: 4,
    prepare: false,
  });

  ownerOrganizationId = randomUUID();
  ownerOperationId = randomUUID();
  secondaryOperationId = randomUUID();
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
  await insertFixture("operations", {
    id: secondaryOperationId,
    is_default: false,
    name: `Operação sem atribuição ${suffix}`,
    organization_id: ownerOrganizationId,
  });

  ownerId = await createMembershipFixture({
    email: ownerEmail,
    operationId: ownerOperationId,
    organizationId: ownerOrganizationId,
    role: "owner",
    status: "active",
  });
  const ownerMembership = await admin
    .from("memberships")
    .select("id")
    .eq("user_id", ownerId)
    .single();
  if (ownerMembership.error) {
    throw new Error(
      `Could not read synthetic owner membership: ${ownerMembership.error.code}`,
    );
  }
  ownerMembershipId = ownerMembership.data.id;

  const { data: managerLink, error: managerError } =
    await admin.auth.admin.generateLink({
      email: managerEmail,
      password: ownerPassword,
      type: "signup",
    });
  if (managerError) {
    throw new Error(`Could not create confirmation link: ${managerError.code}`);
  }

  managerId = managerLink.user.id;
  confirmationTokenHash = managerLink.properties.hashed_token;
  const managerMembershipId = randomUUID();
  await insertFixture("memberships", {
    id: managerMembershipId,
    organization_id: ownerOrganizationId,
    role: "manager",
    status: "active",
    user_id: managerId,
  });
  await insertFixture("membership_operations", {
    membership_id: managerMembershipId,
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
  rlsManagerId = await createMembershipFixture({
    email: rlsManagerEmail,
    operationId: ownerOperationId,
    organizationId: ownerOrganizationId,
    role: "manager",
    status: "active",
  });
  pendingId = await createMembershipFixture({
    email: pendingEmail,
    operationId: ownerOperationId,
    organizationId: ownerOrganizationId,
    status: "pending",
  });
  const { data: unassignedUser, error: unassignedUserError } =
    await admin.auth.admin.createUser({
      email: `unassigned-${suffix}@example.com`,
      email_confirm: true,
      password: ownerPassword,
    });
  if (unassignedUserError) {
    throw new Error(
      `Could not create unassigned Auth fixture: ${unassignedUserError.code}`,
    );
  }
  unassignedUserId = unassignedUser.user.id;

  await insertFixture("system_pauses", {
    activated_by: outsiderId,
    correlation_id: randomUUID(),
    operation_id: outsiderOperationId,
    organization_id: outsiderOrganizationId,
    origin: "automatic",
    reason: "Pausa sintética para validar isolamento entre Imobiliárias",
    trace_id: randomUUID(),
  });
  await insertFixture("system_pauses", {
    activated_by: ownerId,
    correlation_id: randomUUID(),
    operation_id: ownerOperationId,
    organization_id: ownerOrganizationId,
    origin: "manual",
    reason: "Pausa sintética já resolvida",
    resolved_at: new Date().toISOString(),
    status: "resolved",
    trace_id: randomUUID(),
  });
});

test.afterAll(async () => {
  if (!admin) {
    return;
  }

  for (const operationId of [
    ownerOperationId,
    secondaryOperationId,
    outsiderOperationId,
  ]) {
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

  for (const userId of [
    ownerId,
    brokerId,
    managerId,
    rlsManagerId,
    outsiderId,
    pendingId,
    unassignedUserId,
  ]) {
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

  if (database) {
    await database.end();
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
  await page.goto("/app/hoje");
  await expect(page).toHaveURL(/\/entrar\?next=%2Fapp%2Fhoje$/);
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

test("verifies foundation indexes and concurrent uniqueness invariants", async () => {
  const requiredIndexes = [
    "audit_events_operation_created_at_idx",
    "membership_operations_operation_id_idx",
    "memberships_one_owner_per_organization",
    "memberships_user_id_idx",
    "operations_one_default_per_organization",
    "system_pauses_one_active_per_operation",
  ];
  const indexRows = await database<
    { indexname: string }[]
  >`select indexname
    from pg_indexes
    where schemaname in ('public', 'audit')
      and indexname = any (${requiredIndexes})
    order by indexname`;
  expect(indexRows.map(({ indexname }) => indexname)).toEqual(
    [...requiredIndexes].sort(),
  );

  const organizationId = randomUUID();
  const operationIds = [randomUUID(), randomUUID()];
  const concurrentUserIds: string[] = [];

  await insertFixture("organizations", {
    id: organizationId,
    name: `Imobiliária concorrente ${suffix}`,
    slug: `preview-concurrent-${suffix}`,
  });

  try {
    const operationResults = await Promise.all(
      operationIds.map((operationId, index) =>
        admin.from("operations").insert({
          id: operationId,
          is_default: true,
          name: `Operação concorrente ${index + 1}`,
          organization_id: organizationId,
        }),
      ),
    );
    expect(operationResults.filter(({ error }) => !error)).toHaveLength(1);
    expect(
      operationResults.filter(({ error }) => error?.code === "23505"),
    ).toHaveLength(1);
    const winningOperationId =
      operationIds[operationResults.findIndex(({ error }) => !error)];
    expect(winningOperationId).toBeTruthy();

    await insertFixture("operation_settings", {
      operation_id: winningOperationId,
      organization_id: organizationId,
    });

    for (const index of [1, 2]) {
      const { data, error } = await admin.auth.admin.createUser({
        email: `concurrent-${index}-${suffix}@example.com`,
        email_confirm: true,
        password: ownerPassword,
      });
      expect(error).toBeNull();
      expect(data.user).not.toBeNull();
      concurrentUserIds.push(data.user!.id);
    }

    const membershipResults = await Promise.all(
      concurrentUserIds.map((userId) =>
        admin.from("memberships").insert({
          id: randomUUID(),
          organization_id: organizationId,
          role: "owner",
          status: "active",
          user_id: userId,
        }),
      ),
    );
    expect(membershipResults.filter(({ error }) => !error)).toHaveLength(1);
    expect(
      membershipResults.filter(({ error }) => error?.code === "23505"),
    ).toHaveLength(1);

    const pauseResults = await Promise.all(
      concurrentUserIds.map((userId) =>
        admin.from("system_pauses").insert({
          activated_by: userId,
          correlation_id: randomUUID(),
          operation_id: winningOperationId,
          organization_id: organizationId,
          origin: "automatic",
          reason: "Validação concorrente sintética",
          trace_id: randomUUID(),
        }),
      ),
    );
    expect(pauseResults.filter(({ error }) => !error)).toHaveLength(1);
    expect(
      pauseResults.filter(({ error }) => error?.code === "23505"),
    ).toHaveLength(1);
  } finally {
    await admin
      .from("system_pauses")
      .delete()
      .eq("organization_id", organizationId);
    await admin
      .from("operation_settings")
      .delete()
      .eq("organization_id", organizationId);
    await admin.from("operations").delete().eq("organization_id", organizationId);
    for (const userId of concurrentUserIds) {
      await admin.auth.admin.deleteUser(userId);
    }
    await admin.from("organizations").delete().eq("id", organizationId);
  }
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

  const manager = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  await manager.auth.signInWithPassword({
    email: rlsManagerEmail,
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
    expect(
      anonymousRead.error?.code,
      `${probe.table}: anonymous read`,
    ).toBe("42501");
    expect(anonymousRead.data).toBeNull();

    const pendingRead = await pending.from(probe.table).select("*");
    expect(pendingRead.error, `${probe.table}: pending read`).toBeNull();
    expect(pendingRead.data).toEqual([]);

    const crossRead = await owner
      .from(probe.table)
      .select("*")
      .eq(probe.filter, probe.crossValue);
    expect(crossRead.error, `${probe.table}: cross-organization read`).toBeNull();
    expect(crossRead.data).toEqual([]);

    const ownerRead = await owner
      .from(probe.table)
      .select("*")
      .eq(probe.filter, probe.ownValue);
    expect(ownerRead.error, `${probe.table}: owner read`).toBeNull();
    expect(ownerRead.data?.length, `${probe.table}: owner positive scope`).toBeGreaterThan(0);

    const managerRead = await manager
      .from(probe.table)
      .select("*")
      .eq(probe.filter, probe.ownValue);
    expect(managerRead.error, `${probe.table}: manager read`).toBeNull();
    expect(
      managerRead.data?.length,
      `${probe.table}: manager positive scope`,
    ).toBeGreaterThan(0);
  }

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

  for (const probe of probes.slice(0, 4)) {
    const brokerRead = await broker
      .from(probe.table)
      .select("*")
      .eq(probe.filter, probe.ownValue);
    expect(brokerRead.error, `${probe.table}: broker read`).toBeNull();
    expect(
      brokerRead.data?.length,
      `${probe.table}: broker positive scope`,
    ).toBeGreaterThan(0);
  }

  const mutationProbes = [
    {
      filter: "id",
      insert: {
        id: randomUUID(),
        name: `Imobiliária negada ${suffix}`,
        slug: `preview-denied-${randomUUID().slice(0, 8)}`,
      },
      table: "organizations",
      update: { name: `Imobiliária Sintética ${suffix}` },
      value: ownerOrganizationId,
    },
    {
      filter: "id",
      insert: {
        id: randomUUID(),
        name: "Operação negada",
        organization_id: ownerOrganizationId,
      },
      table: "operations",
      update: { name: `Operação Sintética ${suffix}` },
      value: ownerOperationId,
    },
    {
      filter: "id",
      insert: {
        id: randomUUID(),
        organization_id: ownerOrganizationId,
        role: "broker",
        status: "active",
        user_id: unassignedUserId,
      },
      table: "memberships",
      update: { status: "active" },
      value: ownerMembershipId,
    },
    {
      filter: "membership_id",
      insert: {
        membership_id: ownerMembershipId,
        operation_id: secondaryOperationId,
        organization_id: ownerOrganizationId,
      },
      table: "membership_operations",
      update: { organization_id: ownerOrganizationId },
      value: ownerMembershipId,
    },
    {
      filter: "operation_id",
      insert: {
        operation_id: secondaryOperationId,
        organization_id: ownerOrganizationId,
        production_enabled: false,
      },
      table: "operation_settings",
      update: { production_enabled: false },
      value: secondaryOperationId,
    },
    {
      filter: "operation_id",
      insert: {
        activated_by: ownerId,
        correlation_id: randomUUID(),
        operation_id: ownerOperationId,
        organization_id: ownerOrganizationId,
        origin: "manual",
        reason: "Mutação válida que o cliente não pode executar",
        trace_id: randomUUID(),
      },
      table: "system_pauses",
      update: { reason: "Mutação negada" },
      value: ownerOperationId,
    },
  ] as const;

  for (const probe of mutationProbes) {
    const table = probe.table as string;
    const insertAttempt = await owner
      .from(table)
      .insert(probe.insert as never);
    expect(insertAttempt.error?.code, `${probe.table}: insert`).toBe("42501");

    const updateAttempt = await owner
      .from(table)
      .update(probe.update as never)
      .eq(probe.filter, probe.value);
    expect(updateAttempt.error?.code, `${probe.table}: update`).toBe("42501");

    const deleteAttempt = await owner
      .from(table)
      .delete()
      .eq(probe.filter, probe.value);
    expect(deleteAttempt.error?.code, `${probe.table}: delete`).toBe("42501");
  }

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

test("requests and completes password recovery through the synthetic allowlist", async ({
  page,
}) => {
  await page.goto("/recuperar-senha");
  await expect(page.getByRole("heading", { name: "Redefina sua senha" })).toBeVisible();
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByRole("button", { name: "Enviar instruções" }).click();
  await expect(
    page.getByText(
      "Se o e-mail estiver cadastrado, as instruções chegarão em instantes.",
    ),
  ).toBeVisible();

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
