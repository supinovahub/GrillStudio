export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      membership_operations: {
        Row: {
          created_at: string
          membership_id: string
          operation_id: string
          organization_id: string
        }
        Insert: {
          created_at?: string
          membership_id: string
          operation_id: string
          organization_id: string
        }
        Update: {
          created_at?: string
          membership_id?: string
          operation_id?: string
          organization_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "membership_operations_organization_id_membership_id_fkey"
            columns: ["organization_id", "membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "membership_operations_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      memberships: {
        Row: {
          created_at: string
          id: string
          organization_id: string
          role: string
          status: string
          updated_at: string
          user_id: string
          version: number
        }
        Insert: {
          created_at?: string
          id?: string
          organization_id: string
          role: string
          status?: string
          updated_at?: string
          user_id: string
          version?: number
        }
        Update: {
          created_at?: string
          id?: string
          organization_id?: string
          role?: string
          status?: string
          updated_at?: string
          user_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "memberships_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      operation_settings: {
        Row: {
          created_at: string
          operation_id: string
          organization_id: string
          production_enabled: boolean
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          operation_id: string
          organization_id: string
          production_enabled?: boolean
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          operation_id?: string
          organization_id?: string
          production_enabled?: boolean
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "operation_settings_operation_id_fkey"
            columns: ["operation_id"]
            isOneToOne: true
            referencedRelation: "operations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operation_settings_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      operations: {
        Row: {
          created_at: string
          id: string
          is_default: boolean
          name: string
          organization_id: string
          status: string
          timezone: string
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          id?: string
          is_default?: boolean
          name: string
          organization_id: string
          status?: string
          timezone?: string
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          id?: string
          is_default?: boolean
          name?: string
          organization_id?: string
          status?: string
          timezone?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "operations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          id: string
          name: string
          slug: string
          status: string
          timezone: string
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          slug: string
          status?: string
          timezone?: string
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          slug?: string
          status?: string
          timezone?: string
        }
        Relationships: []
      }
      system_pauses: {
        Row: {
          activated_at: string
          activated_by: string
          correlation_id: string
          id: string
          operation_id: string
          organization_id: string
          origin: string
          reason: string
          resolved_at: string | null
          scope: string
          status: string
          trace_id: string
          version: number
        }
        Insert: {
          activated_at?: string
          activated_by: string
          correlation_id: string
          id?: string
          operation_id: string
          organization_id: string
          origin?: string
          reason: string
          resolved_at?: string | null
          scope?: string
          status?: string
          trace_id: string
          version?: number
        }
        Update: {
          activated_at?: string
          activated_by?: string
          correlation_id?: string
          id?: string
          operation_id?: string
          organization_id?: string
          origin?: string
          reason?: string
          resolved_at?: string | null
          scope?: string
          status?: string
          trace_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "system_pauses_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      approve_membership: {
        Args: {
          approved_permissions: string[]
          approved_roles: string[]
          request_correlation_id: string
          request_trace_id: string
          target_membership_id: string
          target_operation_id: string
        }
        Returns: Json
      }
      activate_global_pause: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: {
          global_pause: boolean
          production_enabled: boolean
        }[]
      }
      complete_invitation_registration: {
        Args: {
          registration_email: string
          registration_full_name: string
          registration_token: string
          registration_user_id: string
          registration_whatsapp: string
          request_correlation_id: string
          request_trace_id: string
        }
        Returns: string
      }
      create_general_invitation_link: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: {
          id: string
          status: string
          token: string
        }[]
      }
      create_individual_invitation: {
        Args: {
          invite_email: string
          invite_operation_id: string
          invite_roles: string[]
          request_correlation_id: string
          request_trace_id: string
        }
        Returns: {
          email: string
          id: string
          predefined_roles: string[]
          status: string
          token: string
        }[]
      }
      deactivate_membership_after_reauthentication: {
        Args: {
          actor_user_id: string
          request_correlation_id: string
          request_trace_id: string
          target_membership_id: string
          target_operation_id: string
        }
        Returns: {
          calls_within_one_hour: number
          future_calls: number
          post_call_opportunities: number
          revoked_sessions: number
        }[]
      }
      get_invitation_entry: {
        Args: {
          invitation_token: string
        }
        Returns: {
          invitation_kind: string
          link_status: string
          organization_name: string
        }[]
      }
      get_member_deactivation_impact: {
        Args: {
          target_membership_id: string
          target_operation_id: string
        }
        Returns: {
          calls_within_one_hour: number
          future_calls: number
          post_call_opportunities: number
        }[]
      }
      get_member_workspace: {
        Args: never
        Returns: {
          global_pause: boolean
          member_role: string
          operation_id: string
          operation_name: string
          organization_id: string
          organization_name: string
          production_enabled: boolean
        }[]
      }
      get_member_workspace_v2: {
        Args: never
        Returns: {
          can_manage_members: boolean
          global_pause: boolean
          member_permissions: string[]
          member_role: string
          member_roles: string[]
          operation_id: string
          operation_name: string
          organization_id: string
          organization_name: string
          production_enabled: boolean
        }[]
      }
      get_operation_shell: {
        Args: never
        Returns: {
          can_use_kill_switch: boolean
          global_pause: boolean
          member_role: string
          operation_id: string
          operation_name: string
          organization_id: string
          organization_name: string
          production_enabled: boolean
        }[]
      }
      get_team_management: {
        Args: {
          target_operation_id: string
        }
        Returns: Json
      }
      regenerate_general_invitation_link: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_link_id: string
        }
        Returns: {
          id: string
          status: string
          token: string
        }[]
      }
      reserve_invitation_registration: {
        Args: {
          registration_email: string
          registration_token: string
          request_fingerprint: string
        }
        Returns: {
          invitation_kind: string
          operation_id: string
          organization_id: string
          predefined_roles: string[]
        }[]
      }
      set_general_invitation_link_status: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_link_id: string
          target_status: string
        }
        Returns: {
          id: string
          status: string
          token: string
        }[]
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const

// Application aliases derived from the generated RPC contracts above.
export type MemberWorkspace =
  Database["public"]["Functions"]["get_member_workspace_v2"]["Returns"][number]

export type OperationShell =
  Database["public"]["Functions"]["get_operation_shell"]["Returns"][number]
