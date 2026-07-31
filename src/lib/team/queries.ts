import { createClient } from "@/lib/supabase/server";
import type {
  InvitationEntry,
  TeamManagement,
} from "@/lib/team/types";

export async function getTeamManagement(
  operationId: string,
): Promise<TeamManagement> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_team_management", {
    target_operation_id: operationId,
  });

  if (error || !data) {
    throw new Error("Não foi possível carregar a equipe.");
  }

  return data as unknown as TeamManagement;
}

export async function getInvitationEntry(
  token: string,
): Promise<InvitationEntry | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_invitation_entry", {
    invitation_token: token,
  });

  if (error) {
    throw new Error("Não foi possível validar o convite.");
  }

  return (data[0] as InvitationEntry | undefined) ?? null;
}
