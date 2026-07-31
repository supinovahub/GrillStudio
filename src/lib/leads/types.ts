export const pipelineStages = [
  { key: "new", label: "Novo" },
  { key: "in_service", label: "Em atendimento" },
  { key: "call_scheduled", label: "Call agendada" },
  { key: "negotiation", label: "Em negociação" },
  { key: "proposal_reservation", label: "Proposta/Reserva" },
  { key: "documentation", label: "Documentação" },
  { key: "payment", label: "Pagamento" },
  { key: "purchased", label: "Comprado" },
  { key: "lost", label: "Perdido" },
] as const;

export type PipelineStage = (typeof pipelineStages)[number]["key"];

export const pipelineStageLabels = Object.fromEntries(
  pipelineStages.map((stage) => [stage.key, stage.label]),
) as Record<PipelineStage, string>;

export type LeadSummary = {
  amount_scope: "per_unit" | "total";
  assigned_membership_id: string | null;
  assigned_name: string | null;
  contact_id: string;
  created_at: string;
  display_name: string | null;
  has_opt_out: boolean;
  id: string;
  phone_e164: string;
  phone_original: string;
  source_type: string;
  stage: PipelineStage;
  unit_count: number;
  updated_at: string;
  version: number;
};

export type PipelineBoard = {
  cards: LeadSummary[];
  stages: Array<{
    key: PipelineStage;
    label: string;
  }>;
};

export type LeadPhone = {
  e164: string;
  id: string;
  is_primary: boolean;
  observations: Array<{
    observed_at: string;
    original_value: string;
    source_type: string;
  }>;
  original_value: string;
};

export type LeadDetail = {
  amount_scope: "per_unit" | "total";
  assigned_membership_id: string | null;
  assigned_name: string | null;
  contact_id: string;
  contact_status: "active" | "merged";
  conversations: Array<{
    id: string;
    opened_at: string;
    ownership_type: "human" | "pedro";
    status: "active" | "closed" | "sleeping";
  }>;
  created_at: string;
  display_name: string | null;
  has_opt_out: boolean;
  history: Array<{
    actor_user_id: string | null;
    created_at: string;
    from_stage: PipelineStage | null;
    id: string;
    reason: string | null;
    to_stage: PipelineStage;
  }>;
  id: string;
  internal_note: string | null;
  loss_reason: string | null;
  participants: Array<{
    display_name: string;
    id: string;
    phone_e164: string | null;
    phone_original: string | null;
    role: "advisor" | "co_buyer" | "family" | "other";
  }>;
  pedro_context: string | null;
  phones: LeadPhone[];
  proactive_request: {
    authorization_confirmed: boolean;
    id: string;
    requested_at: string;
    status: "approved" | "cancelled" | "requested" | "scheduled";
  } | null;
  source_type: string;
  sources: Array<{
    attributed_at: string;
    id: string;
    source_label: string | null;
    source_type: string;
  }>;
  stage: PipelineStage;
  unit_count: number;
  updated_at: string;
  version: number;
};

export type ContactMergeCandidate = {
  active_conversations: number;
  display_name: string | null;
  id: string;
  phone_e164: string | null;
  phone_original: string | null;
};

export function isPipelineStage(value: string): value is PipelineStage {
  return pipelineStages.some((stage) => stage.key === value);
}
