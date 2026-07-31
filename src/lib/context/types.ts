import type { Json } from "@/types/database";

export const institutionalFields = [
  ["trade_name", "Nome comercial", "Nome que Pedro pode informar ao lead."],
  ["legal_name", "Razão social", "Nome empresarial registrado."],
  ["creci_pj", "CRECI PJ", "Número profissional da imobiliária."],
  ["creci_uf", "UF do CRECI PJ", "Estado do registro profissional."],
  ["cnpj", "CNPJ", "Cadastro nacional da pessoa jurídica."],
  ["address", "Endereço", "Endereço institucional aprovado."],
  ["phone", "Telefone", "Canal telefônico institucional."],
  ["website", "Site", "Endereço oficial na internet."],
  ["instagram", "Instagram", "Perfil institucional aprovado."],
  ["email", "E-mail", "E-mail institucional aprovado."],
  ["business_hours", "Horário", "Horário oficial de atendimento."],
  [
    "privacy_contact",
    "Contato de privacidade",
    "Canal para solicitações de privacidade.",
  ],
] as const;

export type InstitutionalFieldKey = (typeof institutionalFields)[number][0];

export type InstitutionalField = {
  confirmed_at: string | null;
  confirmed_by_owner: boolean;
  disclosure: "never" | "on_request" | "when_needed";
  public_source_url: string;
  source: string;
  valid_until: string | null;
  value: string;
};

export type ContextDraft = {
  content_hash: string | null;
  diff_snapshot: Json | null;
  id: string;
  status: "draft" | "validating";
  validated_at: string | null;
  validation_errors: string[];
  version: number;
  version_number: number;
};

export type FactualDraft = ContextDraft & {
  fields: Record<InstitutionalFieldKey, InstitutionalField>;
};

export type BehavioralDraft = ContextDraft & {
  biography: Record<string, Json | undefined>;
  identity: Record<string, Json | undefined>;
  instructions: Record<string, Json | undefined>;
  persona_id: string;
  protected_rules: Record<string, Json | undefined>;
  style_rules: Record<string, Json | undefined>;
};

export type ContextPublication = {
  behavioral_hash: string;
  behavioral_version_id: string;
  combined_hash: string;
  factual_hash: string;
  factual_version_id: string;
  id: string;
  publication_number: number;
  published_at: string;
  published_by_user_id: string;
};

export type ContextReadiness = {
  errors: string[];
  publication_id?: string;
  ready: boolean;
  warnings: string[];
};

export type ContextWorkspace = {
  active_publication: ContextPublication | null;
  actor: {
    can_edit_institutional: boolean;
    can_edit_persona: boolean;
    can_coordinate_context: boolean;
    can_publish_context: boolean;
    can_publish_learning: boolean;
    can_validate_context: boolean;
    is_owner: boolean;
  };
  behavioral_draft: BehavioralDraft | null;
  factual_draft: FactualDraft | null;
  history: ContextPublication[];
  production_enabled: boolean;
  readiness: ContextReadiness;
};
