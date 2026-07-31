import type { PipelineStage } from "@/lib/leads/types";

export type ConversationMode = "shadow" | "assisted" | "production";
export type ConversationOwnership = "pedro" | "human";

export type InboxConversation = {
  id: string;
  contact_id: string;
  opportunity_id: string;
  display_name: string | null;
  stage: PipelineStage;
  source_type: string;
  status: "active" | "sleeping";
  ownership_type: ConversationOwnership;
  assigned_membership_id: string | null;
  assigned_name: string | null;
  is_owned_by_actor: boolean;
  automation_mode: ConversationMode;
  is_paused: boolean;
  pending_return: boolean;
  requires_human_review: boolean;
  review_reason: string | null;
  connection_id: string | null;
  connection_name: string | null;
  connection_address: string | null;
  origin: "simulator" | "uazapi" | "meta_cloud" | null;
  last_message: string;
  last_message_kind: string | null;
  last_message_direction: "inbound" | "outbound" | null;
  last_message_at: string;
  updated_at: string;
  version: number;
};

export type ConversationMessage = {
  id: string;
  direction: "inbound" | "outbound";
  kind: string;
  body: string | null;
  status: string;
  occurred_at: string;
  created_by_type: "provider" | "human";
};

export type ConversationDetail = {
  id: string;
  contact: {
    id: string;
    display_name: string | null;
    phones: Array<{ id: string; e164: string; is_primary: boolean }>;
  };
  opportunity: {
    id: string;
    stage: PipelineStage;
    source_type: string;
    pedro_context: string | null;
    unit_count: number;
    amount_scope: "total" | "per_unit";
    version: number;
  };
  connection: {
    id: string;
    name: string;
    display_address: string | null;
    adapter_type: "simulator" | "uazapi" | "meta_cloud";
    is_test: boolean;
  } | null;
  status: "active" | "sleeping";
  ownership_type: ConversationOwnership;
  assigned_membership_id: string | null;
  assigned_name: string | null;
  is_owned_by_actor: boolean;
  automation_mode: ConversationMode;
  allowed_return_modes: ConversationMode[];
  is_paused: boolean;
  pause_reason: string | null;
  pending_return: boolean;
  pending_return_target_mode: ConversationMode | null;
  requires_human_review: boolean;
  review_reason: string | null;
  opened_at: string;
  updated_at: string;
  version: number;
  messages: ConversationMessage[];
};
