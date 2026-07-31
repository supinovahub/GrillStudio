import { expect, test } from "@playwright/test";
import {
  createClient,
  type SupabaseClient,
} from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import {
  institutionalFields,
  type InstitutionalField,
} from "../../src/lib/context/types";
import { validatePreviewEnvironment } from "../../src/lib/environment";
import type { Database, Json } from "../../src/types/database";

const suffix = randomUUID().slice(0, 8);
const password = `Preview-${randomUUID()}-A1!`;
const ownerEmail = `context-owner-${suffix}@example.com`;
const managerEmail = `context-manager-${suffix}@example.com`;
const brokerEmail = `context-broker-${suffix}@example.com`;
const pendingEmail = `context-pending-${suffix}@example.com`;
const outsiderEmail = `context-outsider-${suffix}@example.com`;

let admin: SupabaseClient<Database>;
let owner: SupabaseClient<Database>;
let manager: SupabaseClient<Database>;
let broker: SupabaseClient<Database>;
let pending: SupabaseClient<Database>;
let outsider: SupabaseClient<Database>;
let database: Sql;
let ownerId = "";
let managerId = "";
let organizationId = "";
let operationId = "";
let factualVersionId = "";
let behavioralVersionId = "";
let publishedFactualVersion = 0;
let publishedBehavioralVersion = 0;

test.describe.configure({ mode: "serial" });

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required for the Preview black-box suite`);
  }
  return value;
}

function rpcObject(value: Json | null): Record<string, Json | undefined> {
  expect(value).not.toBeNull();
  expect(Array.isArray(value)).toBe(false);
  expect(typeof value).toBe("object");
  return value as Record<string, Json | undefined>;
}

async function createSyntheticUser(email: string) {
  const result = await admin.auth.admin.createUser({
    email,
    email_confirm: true,
    password,
  });
  expect(result.error).toBeNull();
  return result.data.user!.id;
}

async function signedInClient(email: string) {
  const client = createClient<Database>(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const result = await client.auth.signInWithPassword({ email, password });
  expect(result.error).toBeNull();
  return client;
}

async function insertFixture<
  T extends keyof Database["public"]["Tables"],
>(
  table: T,
  values: Database["public"]["Tables"][T]["Insert"],
) {
  const { error } = await admin.from(table).insert(values as never);
  expect(error, `fixture ${table}`).toBeNull();
}

async function contextWorkspace(client: SupabaseClient<Database>) {
  const result = await client.rpc("get_context_workspace", {
    target_operation_id: operationId,
  });
  expect(result.error).toBeNull();
  return rpcObject(result.data);
}

function profileFields() {
  return Object.fromEntries(
    institutionalFields.map(([key]) => {
      const required: Record<string, string> = {
        creci_pj: "12345",
        creci_uf: "SP",
        trade_name: `Studios Sintéticos ${suffix}`,
      };
      const value = required[key] ?? "";
      const entry: InstitutionalField = {
        confirmed_at: value ? "2026-07-30" : null,
        confirmed_by_owner: Boolean(value),
        disclosure: "on_request",
        public_source_url: value
          ? "https://example.com/consulta-publica"
          : "",
        source: value ? "Documento sintético do teste" : "",
        valid_until: null,
        value,
      };
      return [key, entry];
    }),
  );
}

function personaPayload(
  draft: Record<string, Json | undefined>,
  overrides: Partial<Record<string, Json>> = {},
) {
  const identity = rpcObject(draft.identity as Json);
  const biography = rpcObject(draft.biography as Json);
  const style = rpcObject(draft.style_rules as Json);
  const instructions = rpcObject(draft.instructions as Json);

  return {
    persona_biography: {
      ...biography,
      ...(overrides.biography as Record<string, Json> | undefined),
    },
    persona_identity: {
      ...identity,
      ...(overrides.identity as Record<string, Json> | undefined),
    },
    persona_instructions: instructions,
    persona_style_rules: {
      ...style,
      ...(overrides.style_rules as Record<string, Json> | undefined),
    },
  };
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

  admin = createClient<Database>(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  database = postgres(requiredEnvironment("DATABASE_URL"), {
    max: 2,
    prepare: false,
  });

  ownerId = await createSyntheticUser(ownerEmail);
  managerId = await createSyntheticUser(managerEmail);
  const brokerId = await createSyntheticUser(brokerEmail);
  const pendingId = await createSyntheticUser(pendingEmail);
  const outsiderId = await createSyntheticUser(outsiderEmail);

  organizationId = randomUUID();
  operationId = randomUUID();
  const ownerMembershipId = randomUUID();
  const managerMembershipId = randomUUID();
  const brokerMembershipId = randomUUID();
  const pendingMembershipId = randomUUID();
  const outsiderOrganizationId = randomUUID();
  const outsiderOperationId = randomUUID();
  const outsiderMembershipId = randomUUID();

  await insertFixture("organizations", {
    id: organizationId,
    name: `Imobiliária Contexto ${suffix}`,
    slug: `preview-context-${suffix}`,
  });
  await insertFixture("operations", {
    id: operationId,
    is_default: true,
    name: `Operação Contexto ${suffix}`,
    organization_id: organizationId,
  });
  await insertFixture("operation_settings", {
    operation_id: operationId,
    organization_id: organizationId,
  });

  for (const membership of [
    {
      id: ownerMembershipId,
      role: "owner",
      status: "active",
      user_id: ownerId,
    },
    {
      id: managerMembershipId,
      role: "manager",
      status: "active",
      user_id: managerId,
    },
    {
      id: brokerMembershipId,
      role: "broker",
      status: "active",
      user_id: brokerId,
    },
    {
      id: pendingMembershipId,
      role: "broker",
      status: "pending",
      user_id: pendingId,
    },
  ] as const) {
    await insertFixture("memberships", {
      ...membership,
      organization_id: organizationId,
    });
    await insertFixture("membership_operations", {
      membership_id: membership.id,
      operation_id: operationId,
      organization_id: organizationId,
    });
  }

  for (const permission of [
    "publish_knowledge",
    "train_pedro",
    "publish_learning",
  ] as const) {
    await insertFixture("membership_permissions", {
      granted_by_user_id: ownerId,
      membership_id: managerMembershipId,
      organization_id: organizationId,
      permission,
    });
  }

  await insertFixture("organizations", {
    id: outsiderOrganizationId,
    name: `Imobiliária Externa ${suffix}`,
    slug: `preview-context-outsider-${suffix}`,
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

  owner = await signedInClient(ownerEmail);
  manager = await signedInClient(managerEmail);
  broker = await signedInClient(brokerEmail);
  pending = await signedInClient(pendingEmail);
  outsider = await signedInClient(outsiderEmail);
});

test("Dono prepares a fact-free initial package and RLS isolates Context", async () => {
  const initialized = await owner.rpc("initialize_context_drafts", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(initialized.error).toBeNull();
  expect(rpcObject(initialized.data).ok).toBe(true);

  const workspace = await contextWorkspace(owner);
  const factual = rpcObject(workspace.factual_draft as Json);
  const behavioral = rpcObject(workspace.behavioral_draft as Json);
  const fields = rpcObject(factual.fields as Json);
  const identity = rpcObject(behavioral.identity as Json);

  factualVersionId = factual.id as string;
  behavioralVersionId = behavioral.id as string;
  expect(rpcObject(fields.trade_name as Json).value).toBe("");
  expect(identity.full_name).toBe("");
  expect(identity.creci).toBe("");
  expect(
    rpcObject(behavioral.biography as Json).professional_experience,
  ).toBe("");
  expect(
    rpcObject(behavioral.style_rules as Json)
      .never_invent_personal_experience,
  ).toBe(true);

  const managerRead = await manager
    .from("persona_versions")
    .select("id")
    .eq("operation_id", operationId);
  expect(managerRead.error).toBeNull();
  expect(managerRead.data).toHaveLength(1);

  for (const client of [broker, pending, outsider]) {
    const read = await client
      .from("persona_versions")
      .select("id")
      .eq("operation_id", operationId);
    expect(read.error).toBeNull();
    expect(read.data).toEqual([]);
  }

  const anonymous = createClient<Database>(
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_URL"),
    requiredEnvironment("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"),
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
  const anonymousRead = await anonymous.from("persona_versions").select("id");
  expect(anonymousRead.error?.code).toBe("42501");
});

test("Gestor prepares style but cannot change identity", async () => {
  const workspace = await contextWorkspace(manager);
  const behavioral = rpcObject(workspace.behavioral_draft as Json);
  const attemptedIdentity = {
    ...rpcObject(behavioral.identity as Json),
    full_name: "Identidade indevida",
  };
  const payload = personaPayload(behavioral, {
    identity: attemptedIdentity,
  });
  const result = await manager.rpc("save_persona_draft", {
    expected_version: behavioral.version as number,
    ...payload,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_version_id: behavioral.id as string,
  });
  expect(result.error).toBeNull();
  expect(rpcObject(result.data).reason).toBe("identity_owner_only");

  const [audit] = await database<
    { action: string; after_state: { reason: string } }[]
  >`
    select action, after_state
    from audit.audit_events
    where operation_id = ${operationId}
      and action = 'context.persona_identity_change_denied'
    order by created_at desc
    limit 1
  `;
  expect(audit?.action).toBe("context.persona_identity_change_denied");
  expect(audit?.after_state.reason).toBe("owner_only");
});

test("validation reports required institutional and professional facts", async () => {
  const workspace = await contextWorkspace(owner);
  const factual = rpcObject(workspace.factual_draft as Json);
  const behavioral = rpcObject(workspace.behavioral_draft as Json);
  const validation = await owner.rpc("validate_context_drafts", {
    behavioral_expected_version: behavioral.version as number,
    behavioral_version_id: behavioral.id as string,
    factual_expected_version: factual.version as number,
    factual_version_id: factual.id as string,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(validation.error).toBeNull();
  const result = rpcObject(validation.data);
  expect(result.ok).toBe(false);
  expect(result.reason).toBe("validation_failed");
  expect(result.factual_errors).toEqual(
    expect.arrayContaining([
      "Informe o nome comercial.",
      "Informe o CRECI PJ.",
      "Informe a UF do CRECI PJ.",
    ]),
  );
  expect(result.behavioral_errors).toEqual(
    expect.arrayContaining([
      "Informe o nome completo da Persona.",
      "Informe o CRECI da Persona que se apresenta como Corretor.",
      "Informe a UF do CRECI da Persona.",
    ]),
  );

  const blocked = await admin.rpc(
    "set_context_production_after_reauthentication",
    {
      actor_user_id: ownerId,
      enable_production: true,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
    },
  );
  expect(blocked.error).toBeNull();
  expect(rpcObject(blocked.data).reason).toBe("production_gate");
});

test("Dono publishes separate immutable factual and behavioral versions", async () => {
  let workspace = await contextWorkspace(owner);
  let factual = rpcObject(workspace.factual_draft as Json);
  let behavioral = rpcObject(workspace.behavioral_draft as Json);

  const savedProfile = await owner.rpc("save_institutional_profile_draft", {
    expected_version: factual.version as number,
    profile_fields: profileFields(),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_version_id: factual.id as string,
  });
  expect(savedProfile.error).toBeNull();
  expect(rpcObject(savedProfile.data).ok).toBe(true);

  const persona = personaPayload(behavioral, {
    identity: {
      city: "São Paulo",
      creci: "99999",
      creci_uf: "SP",
      full_name: "Pedro de Teste",
      presents_as_broker: true,
      professional_role: "Corretor",
    },
  });
  const savedPersona = await owner.rpc("save_persona_draft", {
    expected_version: behavioral.version as number,
    ...persona,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_version_id: behavioral.id as string,
  });
  expect(savedPersona.error).toBeNull();
  expect(rpcObject(savedPersona.data).ok).toBe(true);

  workspace = await contextWorkspace(owner);
  factual = rpcObject(workspace.factual_draft as Json);
  behavioral = rpcObject(workspace.behavioral_draft as Json);
  const validation = await owner.rpc("validate_context_drafts", {
    behavioral_expected_version: behavioral.version as number,
    behavioral_version_id: behavioral.id as string,
    factual_expected_version: factual.version as number,
    factual_version_id: factual.id as string,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(validation.error).toBeNull();
  expect(rpcObject(validation.data).ok).toBe(true);

  workspace = await contextWorkspace(owner);
  factual = rpcObject(workspace.factual_draft as Json);
  behavioral = rpcObject(workspace.behavioral_draft as Json);
  publishedFactualVersion = factual.version as number;
  publishedBehavioralVersion = behavioral.version as number;
  const publication = await owner.rpc("publish_context", {
    behavioral_expected_version: publishedBehavioralVersion,
    behavioral_version_id: behavioral.id as string,
    factual_expected_version: publishedFactualVersion,
    factual_version_id: factual.id as string,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(publication.error).toBeNull();
  expect(rpcObject(publication.data).ok).toBe(true);

  workspace = await contextWorkspace(owner);
  const active = rpcObject(workspace.active_publication as Json);
  expect(active.behavioral_version_id).toBe(behavioralVersionId);
  expect(active.factual_version_id).toBe(factualVersionId);
  expect((active.behavioral_hash as string)).toHaveLength(64);
  expect((active.factual_hash as string)).toHaveLength(64);
  expect((active.combined_hash as string)).toHaveLength(64);
  expect(rpcObject(workspace.readiness as Json).ready).toBe(true);
});

test("published versions reject mutation and the supported attempt is audited", async () => {
  const direct = await owner
    .from("institutional_profile_versions")
    .update({ fields: {} })
    .eq("id", factualVersionId);
  expect(direct.error?.code).toBe("42501");

  const privileged = await admin
    .from("institutional_profile_versions")
    .update({ fields: {} })
    .eq("id", factualVersionId);
  expect(privileged.error?.message).toContain(
    "published context versions are immutable",
  );

  const supported = await owner.rpc("save_institutional_profile_draft", {
    expected_version: publishedFactualVersion + 1,
    profile_fields: profileFields(),
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_version_id: factualVersionId,
  });
  expect(supported.error).toBeNull();
  expect(rpcObject(supported.data).reason).toBe("published_immutable");

  const [audit] = await database<{ action: string }[]>`
    select action
    from audit.audit_events
    where operation_id = ${operationId}
      and action = 'context.published_version_modification_denied'
    order by created_at desc
    limit 1
  `;
  expect(audit?.action).toBe(
    "context.published_version_modification_denied",
  );
});

test("only the reauthenticated Dono boundary enables production from published facts", async () => {
  const enabled = await admin.rpc(
    "set_context_production_after_reauthentication",
    {
      actor_user_id: ownerId,
      enable_production: true,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
    },
  );
  expect(enabled.error).toBeNull();
  expect(rpcObject(enabled.data).ok).toBe(true);

  const managerAttempt = await admin.rpc(
    "set_context_production_after_reauthentication",
    {
      actor_user_id: managerId,
      enable_production: false,
      request_correlation_id: randomUUID(),
      request_trace_id: randomUUID(),
      target_operation_id: operationId,
    },
  );
  expect(managerAttempt.error?.code).toBe("P0002");

  const settings = await admin
    .from("operation_settings")
    .select("production_enabled")
    .eq("operation_id", operationId)
    .single();
  expect(settings.data?.production_enabled).toBe(true);
});

test("Gestor with published-learning permission can publish style without changing identity", async () => {
  const created = await manager.rpc("create_context_drafts", {
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(created.error).toBeNull();
  expect(rpcObject(created.data).ok).toBe(true);

  let workspace = await contextWorkspace(manager);
  let factual = rpcObject(workspace.factual_draft as Json);
  let behavioral = rpcObject(workspace.behavioral_draft as Json);
  const persona = personaPayload(behavioral, {
    style_rules: {
      ...rpcObject(behavioral.style_rules as Json),
      tone: "natural, breve e humano",
    },
  });
  const saved = await manager.rpc("save_persona_draft", {
    expected_version: behavioral.version as number,
    ...persona,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
    target_version_id: behavioral.id as string,
  });
  expect(saved.error).toBeNull();
  expect(rpcObject(saved.data).ok).toBe(true);

  workspace = await contextWorkspace(manager);
  factual = rpcObject(workspace.factual_draft as Json);
  behavioral = rpcObject(workspace.behavioral_draft as Json);
  const validation = await manager.rpc("validate_context_drafts", {
    behavioral_expected_version: behavioral.version as number,
    behavioral_version_id: behavioral.id as string,
    factual_expected_version: factual.version as number,
    factual_version_id: factual.id as string,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(validation.error).toBeNull();
  expect(rpcObject(validation.data).ok).toBe(true);

  workspace = await contextWorkspace(manager);
  factual = rpcObject(workspace.factual_draft as Json);
  behavioral = rpcObject(workspace.behavioral_draft as Json);
  const published = await manager.rpc("publish_context", {
    behavioral_expected_version: behavioral.version as number,
    behavioral_version_id: behavioral.id as string,
    factual_expected_version: factual.version as number,
    factual_version_id: factual.id as string,
    request_correlation_id: randomUUID(),
    request_trace_id: randomUUID(),
    target_operation_id: operationId,
  });
  expect(published.error).toBeNull();
  expect(rpcObject(published.data).ok).toBe(true);

  const finalWorkspace = await contextWorkspace(manager);
  expect(finalWorkspace.history).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ publication_number: 1 }),
      expect.objectContaining({ publication_number: 2 }),
    ]),
  );
});

test("Dono sees the functional Context slice in the PWA", async ({ page }) => {
  await page.goto("/entrar?next=%2Fapp%2Fpedro%2Fpersonas");
  await page.getByLabel("E-mail").fill(ownerEmail);
  await page.getByLabel("Senha", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Entrar" }).click();

  await expect(page).toHaveURL(/\/app\/pedro\/personas$/);
  await expect(
    page.getByRole("heading", {
      name: "Perfil institucional e Persona",
    }),
  ).toBeVisible();
  await expect(page.getByText("Publicação #2").first()).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Contexto obrigatório completo" }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Criar nova versão" }).click();
  await expect(page.getByText("Nova versão criada")).toBeVisible();
  await expect(
    page.getByText("Informado e confirmado pelo dono").first(),
  ).toBeVisible();
});
