import { createClient } from "@/lib/supabase/server";
import type { MemberWorkspace, OperationShell } from "@/types/database";

export async function getMemberWorkspace(): Promise<MemberWorkspace | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_member_workspace");

  if (error) {
    throw new Error("Não foi possível carregar a área de trabalho.");
  }

  return data[0] ?? null;
}

export async function getOperationShell(): Promise<OperationShell | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_operation_shell");

  if (error) {
    throw new Error("Não foi possível carregar a Operação.");
  }

  return data[0] ?? null;
}
