export type Json =
  | boolean
  | number
  | string
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type OperationShell = {
  can_use_kill_switch: boolean;
  global_pause: boolean;
  member_role: "owner" | "manager" | "broker";
  operation_id: string;
  operation_name: string;
  organization_id: string;
  organization_name: string;
  production_enabled: boolean;
};

export type MemberWorkspace = Pick<
  OperationShell,
  | "member_role"
  | "operation_id"
  | "operation_name"
  | "organization_id"
  | "organization_name"
>;

type OrganizationRow = {
  created_at: string;
  id: string;
  name: string;
  slug: string;
  status: "active" | "suspended" | "closed";
  timezone: string;
};

type OperationRow = {
  created_at: string;
  id: string;
  is_default: boolean;
  name: string;
  organization_id: string;
  status: "active" | "suspended" | "closed";
  timezone: string;
  updated_at: string;
  version: number;
};

type MembershipRow = {
  created_at: string;
  id: string;
  organization_id: string;
  role: "owner" | "manager" | "broker";
  status: "pending" | "active" | "suspended" | "revoked";
  updated_at: string;
  user_id: string;
  version: number;
};

type MembershipOperationRow = {
  created_at: string;
  membership_id: string;
  operation_id: string;
  organization_id: string;
};

type OperationSettingsRow = {
  created_at: string;
  operation_id: string;
  organization_id: string;
  production_enabled: boolean;
  updated_at: string;
  version: number;
};

type SystemPauseRow = {
  activated_at: string;
  activated_by: string;
  correlation_id: string;
  id: string;
  operation_id: string;
  organization_id: string;
  origin: "manual" | "automatic";
  reason: string;
  resolved_at: string | null;
  scope: "operation";
  status: "active" | "resolved";
  trace_id: string;
  version: number;
};

type TableDefinition<
  Row,
  Insert extends Partial<Row>,
  Update extends Partial<Row>,
  Relationships extends unknown[] = [],
> = {
  Insert: Insert;
  Relationships: Relationships;
  Row: Row;
  Update: Update;
};

export type Database = {
  public: {
    Tables: {
      membership_operations: TableDefinition<
        MembershipOperationRow,
        {
          created_at?: string;
          membership_id: string;
          operation_id: string;
          organization_id: string;
        },
        Partial<MembershipOperationRow>
      >;
      memberships: TableDefinition<
        MembershipRow,
        {
          created_at?: string;
          id?: string;
          organization_id: string;
          role: MembershipRow["role"];
          status?: MembershipRow["status"];
          updated_at?: string;
          user_id: string;
          version?: number;
        },
        Partial<MembershipRow>
      >;
      operation_settings: TableDefinition<
        OperationSettingsRow,
        {
          created_at?: string;
          operation_id: string;
          organization_id: string;
          production_enabled?: boolean;
          updated_at?: string;
          version?: number;
        },
        Partial<OperationSettingsRow>
      >;
      operations: TableDefinition<
        OperationRow,
        {
          created_at?: string;
          id?: string;
          is_default?: boolean;
          name: string;
          organization_id: string;
          status?: OperationRow["status"];
          timezone?: string;
          updated_at?: string;
          version?: number;
        },
        Partial<OperationRow>
      >;
      organizations: TableDefinition<
        OrganizationRow,
        {
          created_at?: string;
          id?: string;
          name: string;
          slug: string;
          status?: OrganizationRow["status"];
          timezone?: string;
        },
        Partial<OrganizationRow>
      >;
      system_pauses: TableDefinition<
        SystemPauseRow,
        {
          activated_at?: string;
          activated_by: string;
          correlation_id: string;
          id?: string;
          operation_id: string;
          organization_id: string;
          origin?: SystemPauseRow["origin"];
          reason: string;
          resolved_at?: string | null;
          scope?: SystemPauseRow["scope"];
          status?: SystemPauseRow["status"];
          trace_id: string;
          version?: number;
        },
        Partial<SystemPauseRow>
      >;
    };
    Views: Record<never, never>;
    Functions: {
      activate_global_pause: {
        Args: {
          request_correlation_id: string;
          request_trace_id: string;
          target_operation_id: string;
        };
        Returns: {
          global_pause: boolean;
          production_enabled: boolean;
        }[];
      };
      get_operation_shell: {
        Args: Record<PropertyKey, never>;
        Returns: OperationShell[];
      };
      get_member_workspace: {
        Args: Record<PropertyKey, never>;
        Returns: MemberWorkspace[];
      };
    };
    Enums: Record<never, never>;
    CompositeTypes: Record<never, never>;
  };
};
