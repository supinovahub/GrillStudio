import { createClient } from "@/lib/supabase/server";
import type {
  ContactMergeCandidate,
  LeadDetail,
  LeadSummary,
  PipelineBoard,
} from "@/lib/leads/types";

export async function getLeadList(
  operationId: string,
): Promise<LeadSummary[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_lead_list", {
    target_operation_id: operationId,
  });

  if (error || !data) {
    throw new Error("Não foi possível carregar os Leads.");
  }

  return data as unknown as LeadSummary[];
}

export async function getPipelineBoard(
  operationId: string,
): Promise<PipelineBoard> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_pipeline_board", {
    target_operation_id: operationId,
  });

  if (error || !data) {
    throw new Error("Não foi possível carregar o pipeline.");
  }

  return data as unknown as PipelineBoard;
}

export async function getLeadDetail(
  opportunityId: string,
): Promise<LeadDetail | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_lead_detail", {
    target_opportunity_id: opportunityId,
  });

  if (error) {
    if (error.code === "P0002") {
      return null;
    }
    throw new Error("Não foi possível carregar o Lead.");
  }

  return data as unknown as LeadDetail;
}

export async function getContactMergeCandidates(
  operationId: string,
  excludedContactId: string,
): Promise<ContactMergeCandidate[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(
    "get_contact_merge_candidates",
    {
      excluded_contact_id: excludedContactId,
      target_operation_id: operationId,
    },
  );

  if (error || !data) {
    throw new Error("Não foi possível carregar possíveis duplicados.");
  }

  return data as unknown as ContactMergeCandidate[];
}
