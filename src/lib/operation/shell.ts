import { createClient } from "@/lib/supabase/server";
import type { OperationShell } from "@/types/database";

export async function getOperationShell(): Promise<OperationShell | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_operation_shell");

  if (error) {
    throw new Error("Não foi possível carregar a Operação.");
  }

  return data[0] ?? null;
}
