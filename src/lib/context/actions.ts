"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { getRequestContext } from "@/lib/auth/context";
import {
  institutionalFields,
  type InstitutionalField,
  type InstitutionalFieldKey,
} from "@/lib/context/types";
import { writeLog } from "@/lib/observability";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/types/database";

const contextPath = "/app/pedro/personas";

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function contextRedirect(result: string): never {
  redirect(`${contextPath}?resultado=${result}`);
}

function contextIds(formData: FormData) {
  return {
    behavioralId: field(formData, "behavioral_version_id"),
    behavioralVersion: Number(field(formData, "behavioral_expected_version")),
    factualId: field(formData, "factual_version_id"),
    factualVersion: Number(field(formData, "factual_expected_version")),
    operationId: field(formData, "operation_id"),
  };
}

function rpcSucceeded(value: Json): boolean {
  return Boolean(
    value &&
      typeof value === "object" &&
      !Array.isArray(value) &&
      value.ok === true,
  );
}

export async function initializeContextAction(formData: FormData) {
  const operationId = field(formData, "operation_id");
  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("initialize_context_drafts", {
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  writeLog("context.initialized", {
    ...context,
    outcome: error || !rpcSucceeded(data) ? "denied" : "succeeded",
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("preparo-negado");
  }

  revalidatePath(contextPath);
  contextRedirect("pacote-preparado");
}

export async function createContextDraftAction(formData: FormData) {
  const operationId = field(formData, "operation_id");
  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_context_drafts", {
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("rascunho-negado");
  }

  revalidatePath(contextPath);
  contextRedirect("rascunho-criado");
}

export async function saveInstitutionalDraftAction(formData: FormData) {
  const { factualId, factualVersion, operationId } = contextIds(formData);
  const profileFields = Object.fromEntries(
    institutionalFields.map(([key]) => {
      const value: InstitutionalField = {
        confirmed_at: field(formData, `${key}_confirmed_at`) || null,
        confirmed_by_owner:
          formData.get(`${key}_confirmed_by_owner`) === "on",
        disclosure: field(formData, `${key}_disclosure`) as
          | "never"
          | "on_request"
          | "when_needed",
        public_source_url: field(formData, `${key}_public_source_url`),
        source: field(formData, `${key}_source`),
        valid_until: field(formData, `${key}_valid_until`) || null,
        value: field(formData, `${key}_value`),
      };
      return [key satisfies InstitutionalFieldKey, value];
    }),
  );
  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(
    "save_institutional_profile_draft",
    {
      expected_version: factualVersion,
      profile_fields: profileFields,
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      target_operation_id: operationId,
      target_version_id: factualId,
    },
  );

  writeLog("context.institutional_draft_saved", {
    ...context,
    outcome: error || !rpcSucceeded(data) ? "denied" : "succeeded",
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("salvamento-negado");
  }

  revalidatePath(contextPath);
  contextRedirect("institucional-salvo");
}

function booleanField(formData: FormData, name: string): boolean {
  return formData.get(name) === "on";
}

export async function savePersonaDraftAction(formData: FormData) {
  const { behavioralId, behavioralVersion, operationId } =
    contextIds(formData);
  const identity = {
    city: field(formData, "persona_city"),
    creci: field(formData, "persona_creci"),
    creci_uf: field(formData, "persona_creci_uf"),
    full_name: field(formData, "persona_full_name"),
    presents_as_broker: booleanField(formData, "persona_presents_as_broker"),
    professional_role: field(formData, "persona_professional_role"),
  };
  const biography = {
    approved_routine: field(formData, "persona_approved_routine"),
    interests: field(formData, "persona_interests"),
    professional_experience: field(
      formData,
      "persona_professional_experience",
    ),
    team: field(formData, "persona_team"),
  };
  const styleRules = {
    controlled_abbreviations: ["vc", "ta", "pra"],
    humor_after_rapport: booleanField(
      formData,
      "persona_humor_after_rapport",
    ),
    language: "pt-BR",
    never_invent_personal_experience: true,
    one_question_at_a_time: true,
    tone: field(formData, "persona_tone"),
  };
  let instructions: Json = {};
  try {
    instructions = JSON.parse(field(formData, "persona_instructions"));
  } catch {
    contextRedirect("persona-invalida");
  }

  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_persona_draft", {
    expected_version: behavioralVersion,
    persona_biography: biography,
    persona_identity: identity,
    persona_instructions: instructions,
    persona_style_rules: styleRules,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
    target_version_id: behavioralId,
  });

  writeLog("context.persona_draft_saved", {
    ...context,
    outcome: error || !rpcSucceeded(data) ? "denied" : "succeeded",
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("persona-negada");
  }

  revalidatePath(contextPath);
  contextRedirect("persona-salva");
}

export async function validateContextAction(formData: FormData) {
  const {
    behavioralId,
    behavioralVersion,
    factualId,
    factualVersion,
    operationId,
  } = contextIds(formData);
  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("validate_context_drafts", {
    behavioral_expected_version: behavioralVersion,
    behavioral_version_id: behavioralId,
    factual_expected_version: factualVersion,
    factual_version_id: factualId,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  if (error) {
    contextRedirect("validacao-negada");
  }

  revalidatePath(contextPath);
  contextRedirect(
    rpcSucceeded(data) ? "validacao-aprovada" : "validacao-pendente",
  );
}

export async function publishContextAction(formData: FormData) {
  const {
    behavioralId,
    behavioralVersion,
    factualId,
    factualVersion,
    operationId,
  } = contextIds(formData);
  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("publish_context", {
    behavioral_expected_version: behavioralVersion,
    behavioral_version_id: behavioralId,
    factual_expected_version: factualVersion,
    factual_version_id: factualId,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  writeLog("context.published", {
    ...context,
    outcome: error || !rpcSucceeded(data) ? "denied" : "succeeded",
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("publicacao-negada");
  }

  revalidatePath(contextPath);
  revalidatePath("/app/central");
  contextRedirect("contexto-publicado");
}

export async function archiveContextDraftAction(formData: FormData) {
  const { behavioralId, factualId, operationId } = contextIds(formData);
  const context = await getRequestContext();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("archive_context_drafts", {
    behavioral_version_id: behavioralId,
    factual_version_id: factualId,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("arquivamento-negado");
  }

  revalidatePath(contextPath);
  contextRedirect("rascunho-arquivado");
}

export async function setContextProductionAction(formData: FormData) {
  const operationId = field(formData, "operation_id");
  const password = field(formData, "password");
  const enableProduction = field(formData, "enable_production") === "true";
  const confirmed = formData.get("confirmation") === "on";
  const context = await getRequestContext();

  if (!operationId || !password || !confirmed) {
    contextRedirect("producao-confirmacao-obrigatoria");
  }

  const supabase = await createClient();
  const { data: userData, error: userError } = await supabase.auth.getUser();
  const email = userData.user?.email;
  if (userError || !userData.user || !email) {
    redirect("/entrar");
  }

  const { error: reauthenticationError } =
    await supabase.auth.signInWithPassword({ email, password });
  if (reauthenticationError) {
    contextRedirect("senha-incorreta");
  }

  const admin = createAdminClient();
  const { data, error } = await admin.rpc(
    "set_context_production_after_reauthentication",
    {
      actor_user_id: userData.user.id,
      enable_production: enableProduction,
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      target_operation_id: operationId,
    },
  );

  writeLog("context.production_changed", {
    ...context,
    outcome: error || !rpcSucceeded(data) ? "denied" : "succeeded",
  });

  if (error || !rpcSucceeded(data)) {
    contextRedirect("producao-bloqueada");
  }

  revalidatePath(contextPath);
  revalidatePath("/app/central");
  contextRedirect(enableProduction ? "producao-habilitada" : "producao-desligada");
}
