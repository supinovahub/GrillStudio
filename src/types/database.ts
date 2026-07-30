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

export type Database = {
  public: {
    Tables: Record<never, never>;
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
    };
    Enums: Record<never, never>;
    CompositeTypes: Record<never, never>;
  };
};
