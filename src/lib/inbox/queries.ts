import type {
  ConversationDetail,
  InboxConversation,
} from "@/lib/inbox/types";
import { createClient } from "@/lib/supabase/server";

export async function getInboxList(
  operationId: string,
): Promise<InboxConversation[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_inbox_list", {
    target_operation_id: operationId,
  });
  if (error || !data) {
    throw new Error("Não foi possível carregar os Atendimentos.");
  }
  return data as unknown as InboxConversation[];
}

export async function getConversationDetail(
  conversationId: string,
): Promise<ConversationDetail | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_conversation_detail", {
    target_conversation_id: conversationId,
  });
  if (error) {
    if (error.code === "P0002") return null;
    throw new Error("Não foi possível carregar a Conversa.");
  }
  return data as unknown as ConversationDetail;
}
