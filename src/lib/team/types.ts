export const managerPermissions = [
  ["manage_members", "Gerenciar Membros"],
  ["publish_knowledge", "Publicar Conhecimento"],
  ["train_pedro", "Treinar Pedro"],
  ["publish_learning", "Publicar aprendizado"],
  ["manage_campaigns", "Gerenciar Campanhas de reativação"],
  ["view_financial_data", "Ver dados financeiros"],
  ["export_data", "Exportar dados"],
  ["manage_privacy", "Gerenciar privacidade"],
  ["receive_urgent_call_alerts", "Receber alertas urgentes de Call"],
  ["configure_operation", "Configurar a Operação"],
  ["manage_conversations", "Assumir e transferir Conversas"],
] as const;

export type MemberRole = "owner" | "manager" | "broker";
export type ManagerPermission = (typeof managerPermissions)[number][0];

export type TeamMember = {
  can_receive_calls: boolean;
  email: string;
  email_confirmed: boolean;
  full_name: string | null;
  id: string;
  impact: {
    calls_within_one_hour: number;
    future_calls: number;
    post_call_opportunities: number;
  };
  is_preferred_receiver: boolean;
  permissions: ManagerPermission[];
  predefined_roles: Exclude<MemberRole, "owner">[];
  roles: MemberRole[];
  status: "active" | "pending" | "revoked" | "suspended";
  user_id: string;
  whatsapp: string | null;
};

export type TeamInvitation = {
  created_at: string;
  email: string;
  id: string;
  predefined_roles: Exclude<MemberRole, "owner">[];
  status: "active";
  token: string;
};

export type GeneralInvitationLink = {
  id: string;
  status: "active" | "paused";
  token: string;
};

export type TeamManagement = {
  actor: {
    is_owner: boolean;
    membership_id: string;
  };
  general_link: GeneralInvitationLink | null;
  invitations: TeamInvitation[];
  members: TeamMember[];
};

export type InvitationEntry = {
  invitation_kind: "general" | "individual";
  link_status: "active" | "claimed" | "paused" | "replaced" | "revoked";
  organization_name: string;
};
