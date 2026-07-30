"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { getRequestContext } from "@/lib/auth/context";
import { writeLog } from "@/lib/observability";
import { createClient } from "@/lib/supabase/server";

export async function activateGlobalPauseAction(formData: FormData) {
  const operationId = formData.get("operation_id");
  const confirmed = formData.get("confirmation") === "on";
  const context = await getRequestContext();

  if (typeof operationId !== "string" || !operationId || !confirmed) {
    redirect("/app/central?kill-switch=confirmacao-obrigatoria");
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc("activate_global_pause", {
    request_correlation_id: context.correlationId,
    request_trace_id: context.traceId,
    target_operation_id: operationId,
  });

  writeLog("pedro.global_pause_activated", {
    ...context,
    outcome: error ? "denied" : "succeeded",
  });

  if (error) {
    redirect("/app/central?kill-switch=negado");
  }

  revalidatePath("/app/central");
  redirect("/app/central?kill-switch=acionado");
}
