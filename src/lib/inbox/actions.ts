"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { safeInternalPath } from "@/lib/auth/redirects";
import { getRequestContext } from "@/lib/auth/context";
import type { ConversationMode } from "@/lib/inbox/types";
import { writeLog } from "@/lib/observability";
import { createClient } from "@/lib/supabase/server";

function field(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function command(formData: FormData) {
  const conversationId = field(formData, "conversation_id");
  const expectedVersion = Number.parseInt(
    field(formData, "expected_version"),
    10,
  );
  const returnTo = safeInternalPath(
    field(formData, "return_to") || `/app/atendimentos/${conversationId}`,
  );
  if (
    !conversationId ||
    !Number.isInteger(expectedVersion) ||
    expectedVersion < 1
  ) {
    redirect(`${returnTo}?resultado=comando-invalido`);
  }
  return { conversationId, expectedVersion, returnTo };
}

function resultPath(path: string, result: string): string {
  const url = new URL(path, "http://grillstudio.local");
  url.searchParams.set("resultado", result);
  return `${url.pathname}${url.search}`;
}

export async function assumeConversationAction(formData: FormData) {
  const { conversationId, expectedVersion, returnTo } = command(formData);
  const context = await getRequestContext();
  const supabase = await createClient();
  const { error } = await supabase.rpc("assume_conversation", {
    expected_version: expectedVersion,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_conversation_id: conversationId,
  });
  writeLog("conversation.assumed", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });
  revalidatePath("/app/atendimentos");
  revalidatePath(`/app/atendimentos/${conversationId}`);
  redirect(
    resultPath(
      returnTo,
      error?.code === "40001"
        ? "versao-desatualizada"
        : error
          ? "comando-negado"
          : "assumido",
    ),
  );
}

export async function pauseConversationAction(formData: FormData) {
  const { conversationId, expectedVersion, returnTo } = command(formData);
  const pauseReason = field(formData, "pause_reason");
  const context = await getRequestContext();
  if (!pauseReason) redirect(resultPath(returnTo, "motivo-obrigatorio"));
  const supabase = await createClient();
  const { error } = await supabase.rpc("pause_conversation", {
    expected_version: expectedVersion,
    pause_reason: pauseReason,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_conversation_id: conversationId,
  });
  writeLog("conversation.paused", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });
  revalidatePath("/app/atendimentos");
  revalidatePath(`/app/atendimentos/${conversationId}`);
  redirect(resultPath(returnTo, error ? "comando-negado" : "pausado"));
}

export async function returnConversationAction(formData: FormData) {
  const { conversationId, expectedVersion, returnTo } = command(formData);
  const mode = field(formData, "automation_mode") as ConversationMode;
  const context = await getRequestContext();
  if (!["shadow", "assisted", "production"].includes(mode)) {
    redirect(resultPath(returnTo, "comando-invalido"));
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(
    "return_conversation_to_pedro",
    {
      expected_version: expectedVersion,
      request_correlation_id: context.correlationId,
      request_trace_id: context.traceId,
      return_action: "resume_service",
      target_automation_mode: mode,
      target_conversation_id: conversationId,
    },
  );
  const result = data as unknown as { pending_return?: boolean } | null;
  writeLog("conversation.returned", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });
  revalidatePath("/app/atendimentos");
  revalidatePath(`/app/atendimentos/${conversationId}`);
  redirect(
    resultPath(
      returnTo,
      error
        ? "comando-negado"
        : result?.pending_return
          ? "devolucao-pendente"
          : "devolvido",
    ),
  );
}

export async function sendHumanMessageAction(formData: FormData) {
  const { conversationId, expectedVersion, returnTo } = command(formData);
  const messageText = field(formData, "message_text");
  const commandId = field(formData, "command_id");
  const context = await getRequestContext();
  if (
    !messageText ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      commandId,
    )
  ) {
    redirect(resultPath(returnTo, "mensagem-vazia"));
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc("send_human_message", {
    command_id: commandId,
    expected_version: expectedVersion,
    message_text: messageText,
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_conversation_id: conversationId,
  });
  writeLog("message.outbound_captured", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });
  revalidatePath("/app/atendimentos");
  revalidatePath(`/app/atendimentos/${conversationId}`);
  redirect(resultPath(returnTo, error ? "mensagem-negada" : "mensagem-enviada"));
}
