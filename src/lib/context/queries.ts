import { createClient } from "@/lib/supabase/server";
import type { ContextWorkspace } from "@/lib/context/types";

export async function getContextWorkspace(
  operationId: string,
): Promise<ContextWorkspace> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_context_workspace", {
    target_operation_id: operationId,
  });

  if (error || !data) {
    throw new Error("Não foi possível carregar o Contexto publicado.");
  }

  return data as unknown as ContextWorkspace;
}
