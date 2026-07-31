import { createClient } from "@/lib/supabase/server";

export type ActiveMemberRole = "owner" | "manager" | "broker";

export async function getActiveMemberRole(): Promise<ActiveMemberRole | null> {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("memberships")
    .select("role")
    .eq("status", "active")
    .limit(1)
    .maybeSingle();

  if (error) {
    throw new Error("Não foi possível verificar a permissão da conta.");
  }

  return data?.role ?? null;
}
