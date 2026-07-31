"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { safeInternalPath } from "@/lib/auth/redirects";
import { getRequestContext } from "@/lib/auth/context";
import {
  isPipelineStage,
  type PipelineStage,
} from "@/lib/leads/types";
import { writeLog } from "@/lib/observability";
import { createClient } from "@/lib/supabase/server";

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function resultPath(
  path: string,
  result: string,
): string {
  const url = new URL(safeInternalPath(path), "http://grillstudio.local");
  url.searchParams.set("resultado", result);
  return `${url.pathname}${url.search}`;
}

export async function createManualLeadAction(formData: FormData) {
  const operationId = field(formData, "operation_id");
  const leadName = field(formData, "lead_name");
  const phoneOriginal = field(formData, "phone_original");
  const leadSource = field(formData, "lead_source");
  const registrationAction = field(formData, "registration_action");
  const pedroContext = field(formData, "pedro_context");
  const internalNote = field(formData, "internal_note");
  const participantName = field(formData, "participant_name");
  const participantPhone = field(formData, "participant_phone");
  const amountScope = field(formData, "amount_scope");
  const unitCount = Number.parseInt(field(formData, "unit_count"), 10);
  const context = await getRequestContext();

  if (
    !operationId ||
    !phoneOriginal ||
    !leadSource ||
    !["register", "assume", "request_proactive"].includes(
      registrationAction,
    ) ||
    !["total", "per_unit"].includes(amountScope) ||
    !Number.isInteger(unitCount) ||
    unitCount < 1 ||
    unitCount > 100
  ) {
    redirect("/app/leads?resultado=cadastro-invalido");
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_manual_lead", {
    amount_scope_value: amountScope,
    internal_note_value: internalNote,
    lead_name: leadName,
    lead_source: leadSource,
    participant_name: participantName,
    participant_phone_original: participantPhone,
    pedro_context_value: pedroContext,
    phone_original: phoneOriginal,
    registration_action: registrationAction,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
    unit_count_value: unitCount,
  });

  writeLog("lead.manual_created", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error || !data) {
    const result = error?.message.includes("DDD")
      ? "telefone-sem-ddd"
      : error?.code === "42501"
        ? "cadastro-negado"
        : "cadastro-invalido";
    redirect(`/app/leads?resultado=${result}`);
  }

  const created = data as unknown as { opportunity_id: string };
  revalidatePath("/app/leads");
  revalidatePath("/app/kanban");
  redirect(`/app/leads/${created.opportunity_id}?resultado=lead-criado`);
}

export async function transitionOpportunityAction(formData: FormData) {
  const opportunityId = field(formData, "opportunity_id");
  const targetStageValue = field(formData, "target_stage");
  const transitionReason = field(formData, "transition_reason");
  const expectedVersion = Number.parseInt(
    field(formData, "expected_version"),
    10,
  );
  const humanDecision = formData.get("human_decision") === "on";
  const returnTo = safeInternalPath(field(formData, "return_to") || "/app/kanban");
  const context = await getRequestContext();

  if (
    !opportunityId ||
    !isPipelineStage(targetStageValue) ||
    !Number.isInteger(expectedVersion) ||
    expectedVersion < 1
  ) {
    redirect(resultPath(returnTo, "transicao-invalida"));
  }

  const targetStage: PipelineStage = targetStageValue;
  const supabase = await createClient();
  const { error } = await supabase.rpc("transition_opportunity", {
    expected_version: expectedVersion,
    human_decision: humanDecision,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_opportunity_id: opportunityId,
    target_stage: targetStage,
    transition_reason: transitionReason,
  });

  writeLog("opportunity.stage_changed", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    const result =
      error.code === "40001"
        ? "versao-desatualizada"
        : error.message.includes("call must be assigned")
          ? "call-sem-responsavel"
          : error.message.includes("loss reason")
            ? "motivo-obrigatorio"
            : "transicao-negada";
    redirect(resultPath(returnTo, result));
  }

  revalidatePath("/app/leads");
  revalidatePath(`/app/leads/${opportunityId}`);
  revalidatePath("/app/kanban");
  revalidatePath("/app/meu-pipeline");
  redirect(resultPath(returnTo, "etapa-alterada"));
}

export async function mergeContactsAction(formData: FormData) {
  const primaryContactId = field(formData, "primary_contact_id");
  const duplicateContactRef = field(formData, "duplicate_contact_ref");
  const [duplicateContactId, duplicateVersionValue] =
    duplicateContactRef.split(":");
  const expectedPrimaryVersion = Number.parseInt(
    field(formData, "expected_primary_version"),
    10,
  );
  const expectedDuplicateVersion = Number.parseInt(
    duplicateVersionValue || "",
    10,
  );
  const operationId = field(formData, "operation_id");
  const opportunityId = field(formData, "opportunity_id");
  const context = await getRequestContext();
  const returnTo = `/app/leads/${opportunityId}`;

  if (
    !primaryContactId ||
    !duplicateContactId ||
    !operationId ||
    !opportunityId ||
    !Number.isInteger(expectedPrimaryVersion) ||
    expectedPrimaryVersion < 1 ||
    !Number.isInteger(expectedDuplicateVersion) ||
    expectedDuplicateVersion < 1
  ) {
    redirect(resultPath(returnTo, "fusao-invalida"));
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("merge_contacts", {
    duplicate_contact_id: duplicateContactId,
    expected_duplicate_version: expectedDuplicateVersion,
    expected_primary_version: expectedPrimaryVersion,
    primary_contact_id: primaryContactId,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  writeLog("contact.merged", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    redirect(
      resultPath(
        returnTo,
        error.message.includes("active conversations")
          ? "fusao-bloqueada-conversas"
          : "fusao-negada",
      ),
    );
  }

  revalidatePath("/app/leads");
  revalidatePath("/app/kanban");
  revalidatePath(returnTo);
  redirect(resultPath(returnTo, "contatos-fundidos"));
}
