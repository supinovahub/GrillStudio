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
      call_assignments: {
        Row: {
          assigned_at: string
          call_id: string
          created_at: string
          id: string
          membership_id: string
          operation_id: string
          organization_id: string
          revoke_reason: string | null
          revoked_at: string | null
        }
        Insert: {
          assigned_at?: string
          call_id: string
          created_at?: string
          id?: string
          membership_id: string
          operation_id: string
          organization_id: string
          revoke_reason?: string | null
          revoked_at?: string | null
        }
        Update: {
          assigned_at?: string
          call_id?: string
          created_at?: string
          id?: string
          membership_id?: string
          operation_id?: string
          organization_id?: string
          revoke_reason?: string | null
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "call_assignments_operation_call_fkey"
            columns: ["organization_id", "operation_id", "call_id"]
            isOneToOne: false
            referencedRelation: "calls"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "call_assignments_organization_id_call_id_fkey"
            columns: ["organization_id", "call_id"]
            isOneToOne: false
            referencedRelation: "calls"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "call_assignments_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "call_assignments_organization_id_membership_id_fkey"
            columns: ["organization_id", "membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "call_assignments_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      call_offers: {
        Row: {
          call_id: string
          created_at: string
          expires_at: string | null
          id: string
          operation_id: string
          organization_id: string
          recipient_membership_id: string
          sent_at: string | null
          status: string
          updated_at: string
        }
        Insert: {
          call_id: string
          created_at?: string
          expires_at?: string | null
          id?: string
          operation_id: string
          organization_id: string
          recipient_membership_id: string
          sent_at?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          call_id?: string
          created_at?: string
          expires_at?: string | null
          id?: string
          operation_id?: string
          organization_id?: string
          recipient_membership_id?: string
          sent_at?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "call_offers_operation_call_fkey"
            columns: ["organization_id", "operation_id", "call_id"]
            isOneToOne: false
            referencedRelation: "calls"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "call_offers_organization_id_call_id_fkey"
            columns: ["organization_id", "call_id"]
            isOneToOne: false
            referencedRelation: "calls"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "call_offers_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "call_offers_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "call_offers_organization_id_recipient_membership_id_fkey"
            columns: ["organization_id", "recipient_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      calls: {
        Row: {
          assigned_membership_id: string | null
          created_at: string
          id: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          scheduled_for: string
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          assigned_membership_id?: string | null
          created_at?: string
          id?: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          scheduled_for: string
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          assigned_membership_id?: string | null
          created_at?: string
          id?: string
          operation_id?: string
          opportunity_id?: string
          organization_id?: string
          scheduled_for?: string
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "calls_operation_opportunity_fkey"
            columns: ["organization_id", "operation_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "calls_organization_id_assigned_membership_id_fkey"
            columns: ["organization_id", "assigned_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "calls_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "calls_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "calls_organization_id_opportunity_id_fkey"
            columns: ["organization_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      contact_merge_reversals: {
        Row: {
          contact_merge_id: string
          correlation_id: string
          created_at: string
          id: string
          merged_version_before: number
          operation_id: string
          organization_id: string
          reversed_by_membership_id: string
          reversed_by_user_id: string
          survivor_version_before: number
          trace_id: string
        }
        Insert: {
          contact_merge_id: string
          correlation_id: string
          created_at?: string
          id?: string
          merged_version_before: number
          operation_id: string
          organization_id: string
          reversed_by_membership_id: string
          reversed_by_user_id: string
          survivor_version_before: number
          trace_id: string
        }
        Update: {
          contact_merge_id?: string
          correlation_id?: string
          created_at?: string
          id?: string
          merged_version_before?: number
          operation_id?: string
          organization_id?: string
          reversed_by_membership_id?: string
          reversed_by_user_id?: string
          survivor_version_before?: number
          trace_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_merge_reversals_organization_id_contact_merge_id_fkey"
            columns: ["organization_id", "contact_merge_id"]
            isOneToOne: false
            referencedRelation: "contact_merges"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "contact_merge_reversals_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "contact_merge_reversals_organization_id_reversed_by_member_fkey"
            columns: ["organization_id", "reversed_by_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      contact_merges: {
        Row: {
          correlation_id: string
          created_at: string
          id: string
          merged_by_membership_id: string
          merged_by_user_id: string
          merged_contact_id: string
          merged_version_before: number
          operation_id: string
          organization_id: string
          snapshot: Json
          survivor_contact_id: string
          survivor_version_before: number
          trace_id: string
        }
        Insert: {
          correlation_id: string
          created_at?: string
          id?: string
          merged_by_membership_id: string
          merged_by_user_id: string
          merged_contact_id: string
          merged_version_before: number
          operation_id: string
          organization_id: string
          snapshot: Json
          survivor_contact_id: string
          survivor_version_before: number
          trace_id: string
        }
        Update: {
          correlation_id?: string
          created_at?: string
          id?: string
          merged_by_membership_id?: string
          merged_by_user_id?: string
          merged_contact_id?: string
          merged_version_before?: number
          operation_id?: string
          organization_id?: string
          snapshot?: Json
          survivor_contact_id?: string
          survivor_version_before?: number
          trace_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_merges_organization_id_merged_by_membership_id_fkey"
            columns: ["organization_id", "merged_by_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "contact_merges_organization_id_merged_contact_id_fkey"
            columns: ["organization_id", "merged_contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "contact_merges_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "contact_merges_organization_id_survivor_contact_id_fkey"
            columns: ["organization_id", "survivor_contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      contact_phone_observations: {
        Row: {
          contact_id: string
          contact_phone_id: string
          id: string
          observed_at: string
          organization_id: string
          original_value: string
          source_type: string
        }
        Insert: {
          contact_id: string
          contact_phone_id: string
          id?: string
          observed_at?: string
          organization_id: string
          original_value: string
          source_type: string
        }
        Update: {
          contact_id?: string
          contact_phone_id?: string
          id?: string
          observed_at?: string
          organization_id?: string
          original_value?: string
          source_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "contact_phone_observations_contact_phone_fkey"
            columns: ["organization_id", "contact_id", "contact_phone_id"]
            isOneToOne: false
            referencedRelation: "contact_phones"
            referencedColumns: ["organization_id", "contact_id", "id"]
          },
          {
            foreignKeyName: "contact_phone_observations_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "contact_phone_observations_organization_id_contact_phone_i_fkey"
            columns: ["organization_id", "contact_phone_id"]
            isOneToOne: false
            referencedRelation: "contact_phones"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      contact_phones: {
        Row: {
          contact_id: string
          created_at: string
          e164: string
          id: string
          is_primary: boolean
          organization_id: string
          original_value: string
          verified_at: string | null
        }
        Insert: {
          contact_id: string
          created_at?: string
          e164: string
          id?: string
          is_primary?: boolean
          organization_id: string
          original_value: string
          verified_at?: string | null
        }
        Update: {
          contact_id?: string
          created_at?: string
          e164?: string
          id?: string
          is_primary?: boolean
          organization_id?: string
          original_value?: string
          verified_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "contact_phones_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      contacts: {
        Row: {
          created_at: string
          display_name: string | null
          id: string
          merged_into_contact_id: string | null
          organization_id: string
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          display_name?: string | null
          id?: string
          merged_into_contact_id?: string | null
          organization_id: string
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          display_name?: string | null
          id?: string
          merged_into_contact_id?: string | null
          organization_id?: string
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "contacts_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contacts_organization_id_merged_into_contact_id_fkey"
            columns: ["organization_id", "merged_into_contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      context_publications: {
        Row: {
          behavioral_hash: string
          behavioral_snapshot: Json
          behavioral_version_id: string
          combined_hash: string
          factual_hash: string
          factual_snapshot: Json
          factual_version_id: string
          id: string
          operation_id: string
          organization_id: string
          publication_number: number
          published_at: string
          published_by_user_id: string
        }
        Insert: {
          behavioral_hash: string
          behavioral_snapshot: Json
          behavioral_version_id: string
          combined_hash: string
          factual_hash: string
          factual_snapshot: Json
          factual_version_id: string
          id?: string
          operation_id: string
          organization_id: string
          publication_number: number
          published_at?: string
          published_by_user_id: string
        }
        Update: {
          behavioral_hash?: string
          behavioral_snapshot?: Json
          behavioral_version_id?: string
          combined_hash?: string
          factual_hash?: string
          factual_snapshot?: Json
          factual_version_id?: string
          id?: string
          operation_id?: string
          organization_id?: string
          publication_number?: number
          published_at?: string
          published_by_user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "context_publications_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "context_publications_organization_id_operation_id_behavior_fkey"
            columns: [
              "organization_id",
              "operation_id",
              "behavioral_version_id",
            ]
            isOneToOne: false
            referencedRelation: "persona_versions"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "context_publications_organization_id_operation_id_factual__fkey"
            columns: ["organization_id", "operation_id", "factual_version_id"]
            isOneToOne: false
            referencedRelation: "institutional_profile_versions"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "context_publications_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      conversations: {
        Row: {
          assigned_membership_id: string | null
          automation_mode: string
          closed_at: string | null
          connection_id: string | null
          contact_id: string
          id: string
          is_paused: boolean
          last_inbound_at: string | null
          last_outbound_at: string | null
          opened_at: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          ownership_type: string
          pause_reason: string | null
          paused_at: string | null
          paused_by_membership_id: string | null
          pending_return: boolean
          pending_return_action: string | null
          pending_return_requested_at: string | null
          pending_return_requested_by_membership_id: string | null
          pending_return_requested_version: number | null
          pending_return_target_mode: string | null
          provider_chat_id: string | null
          requires_human_review: boolean
          review_reason: string | null
          sleeping_since: string | null
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          assigned_membership_id?: string | null
          automation_mode?: string
          closed_at?: string | null
          connection_id?: string | null
          contact_id: string
          id?: string
          is_paused?: boolean
          last_inbound_at?: string | null
          last_outbound_at?: string | null
          opened_at?: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          ownership_type?: string
          pause_reason?: string | null
          paused_at?: string | null
          paused_by_membership_id?: string | null
          pending_return?: boolean
          pending_return_action?: string | null
          pending_return_requested_at?: string | null
          pending_return_requested_by_membership_id?: string | null
          pending_return_requested_version?: number | null
          pending_return_target_mode?: string | null
          provider_chat_id?: string | null
          requires_human_review?: boolean
          review_reason?: string | null
          sleeping_since?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          assigned_membership_id?: string | null
          automation_mode?: string
          closed_at?: string | null
          connection_id?: string | null
          contact_id?: string
          id?: string
          is_paused?: boolean
          last_inbound_at?: string | null
          last_outbound_at?: string | null
          opened_at?: string
          operation_id?: string
          opportunity_id?: string
          organization_id?: string
          ownership_type?: string
          pause_reason?: string | null
          paused_at?: string | null
          paused_by_membership_id?: string | null
          pending_return?: boolean
          pending_return_action?: string | null
          pending_return_requested_at?: string | null
          pending_return_requested_by_membership_id?: string | null
          pending_return_requested_version?: number | null
          pending_return_target_mode?: string | null
          provider_chat_id?: string | null
          requires_human_review?: boolean
          review_reason?: string | null
          sleeping_since?: string | null
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "conversations_contact_opportunity_fkey"
            columns: ["organization_id", "contact_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "contact_id", "id"]
          },
          {
            foreignKeyName: "conversations_operation_connection_fkey"
            columns: ["organization_id", "operation_id", "connection_id"]
            isOneToOne: false
            referencedRelation: "whatsapp_connections"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "conversations_operation_opportunity_fkey"
            columns: ["organization_id", "operation_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "conversations_organization_id_assigned_membership_id_fkey"
            columns: ["organization_id", "assigned_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversations_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversations_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversations_organization_id_opportunity_id_fkey"
            columns: ["organization_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversations_paused_by_membership_fkey"
            columns: ["organization_id", "paused_by_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "conversations_pending_return_by_membership_fkey"
            columns: [
              "organization_id",
              "pending_return_requested_by_membership_id",
            ]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      institutional_profile_versions: {
        Row: {
          archived_at: string | null
          archived_by_user_id: string | null
          baseline_version_id: string | null
          content_hash: string | null
          created_at: string
          created_by_user_id: string
          diff_snapshot: Json | null
          fields: Json
          id: string
          operation_id: string
          organization_id: string
          published_at: string | null
          published_by_user_id: string | null
          status: string
          updated_at: string
          validated_at: string | null
          validated_by_user_id: string | null
          validation_errors: Json
          version: number
          version_number: number
        }
        Insert: {
          archived_at?: string | null
          archived_by_user_id?: string | null
          baseline_version_id?: string | null
          content_hash?: string | null
          created_at?: string
          created_by_user_id: string
          diff_snapshot?: Json | null
          fields?: Json
          id?: string
          operation_id: string
          organization_id: string
          published_at?: string | null
          published_by_user_id?: string | null
          status?: string
          updated_at?: string
          validated_at?: string | null
          validated_by_user_id?: string | null
          validation_errors?: Json
          version?: number
          version_number: number
        }
        Update: {
          archived_at?: string | null
          archived_by_user_id?: string | null
          baseline_version_id?: string | null
          content_hash?: string | null
          created_at?: string
          created_by_user_id?: string
          diff_snapshot?: Json | null
          fields?: Json
          id?: string
          operation_id?: string
          organization_id?: string
          published_at?: string | null
          published_by_user_id?: string | null
          status?: string
          updated_at?: string
          validated_at?: string | null
          validated_by_user_id?: string | null
          validation_errors?: Json
          version?: number
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "institutional_profile_versio_organization_id_operation_id_fkey1"
            columns: ["organization_id", "operation_id", "baseline_version_id"]
            isOneToOne: false
            referencedRelation: "institutional_profile_versions"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "institutional_profile_version_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "institutional_profile_versions_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      invitation_links: {
        Row: {
          created_at: string
          created_by_user_id: string
          id: string
          operation_id: string
          organization_id: string
          replaced_by_id: string | null
          status: string
          token: string
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          created_by_user_id: string
          id?: string
          operation_id: string
          organization_id: string
          replaced_by_id?: string | null
          status?: string
          token?: string
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          created_by_user_id?: string
          id?: string
          operation_id?: string
          organization_id?: string
          replaced_by_id?: string | null
          status?: string
          token?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "invitation_links_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitation_links_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "invitation_links_replaced_by_id_fkey"
            columns: ["replaced_by_id"]
            isOneToOne: false
            referencedRelation: "invitation_links"
            referencedColumns: ["id"]
          },
        ]
      }
      invitations: {
        Row: {
          claimed_at: string | null
          claimed_by_membership_id: string | null
          created_at: string
          created_by_user_id: string
          email: string
          id: string
          operation_id: string
          organization_id: string
          predefined_roles: string[]
          revoked_at: string | null
          status: string
          token: string
          version: number
        }
        Insert: {
          claimed_at?: string | null
          claimed_by_membership_id?: string | null
          created_at?: string
          created_by_user_id: string
          email: string
          id?: string
          operation_id: string
          organization_id: string
          predefined_roles: string[]
          revoked_at?: string | null
          status?: string
          token?: string
          version?: number
        }
        Update: {
          claimed_at?: string | null
          claimed_by_membership_id?: string | null
          created_at?: string
          created_by_user_id?: string
          email?: string
          id?: string
          operation_id?: string
          organization_id?: string
          predefined_roles?: string[]
          revoked_at?: string | null
          status?: string
          token?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "invitations_organization_id_claimed_by_membership_id_fkey"
            columns: ["organization_id", "claimed_by_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "invitations_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invitations_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
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
      membership_permissions: {
        Row: {
          created_at: string
          granted_by_user_id: string
          membership_id: string
          organization_id: string
          permission: string
        }
        Insert: {
          created_at?: string
          granted_by_user_id: string
          membership_id: string
          organization_id: string
          permission: string
        }
        Update: {
          created_at?: string
          granted_by_user_id?: string
          membership_id?: string
          organization_id?: string
          permission?: string
        }
        Relationships: [
          {
            foreignKeyName: "membership_permissions_organization_id_membership_id_fkey"
            columns: ["organization_id", "membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      membership_roles: {
        Row: {
          created_at: string
          membership_id: string
          organization_id: string
          role: string
        }
        Insert: {
          created_at?: string
          membership_id: string
          organization_id: string
          role: string
        }
        Update: {
          created_at?: string
          membership_id?: string
          organization_id?: string
          role?: string
        }
        Relationships: [
          {
            foreignKeyName: "membership_roles_organization_id_membership_id_fkey"
            columns: ["organization_id", "membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      memberships: {
        Row: {
          can_receive_calls: boolean
          created_at: string
          id: string
          is_preferred_receiver: boolean
          organization_id: string
          role: string | null
          status: string
          updated_at: string
          user_id: string
          version: number
        }
        Insert: {
          can_receive_calls?: boolean
          created_at?: string
          id?: string
          is_preferred_receiver?: boolean
          organization_id: string
          role?: string | null
          status?: string
          updated_at?: string
          user_id: string
          version?: number
        }
        Update: {
          can_receive_calls?: boolean
          created_at?: string
          id?: string
          is_preferred_receiver?: boolean
          organization_id?: string
          role?: string | null
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
      messages: {
        Row: {
          body: string | null
          connection_id: string
          conversation_id: string
          created_at: string
          created_by_membership_id: string | null
          created_by_type: string
          direction: string
          id: string
          idempotency_key: string | null
          inbound_stream_sequence: number | null
          kind: string
          operation_id: string
          organization_id: string
          provider_message_id: string | null
          provider_occurred_at: string | null
          status: string
        }
        Insert: {
          body?: string | null
          connection_id: string
          conversation_id: string
          created_at?: string
          created_by_membership_id?: string | null
          created_by_type: string
          direction: string
          id?: string
          idempotency_key?: string | null
          inbound_stream_sequence?: number | null
          kind?: string
          operation_id: string
          organization_id: string
          provider_message_id?: string | null
          provider_occurred_at?: string | null
          status: string
        }
        Update: {
          body?: string | null
          connection_id?: string
          conversation_id?: string
          created_at?: string
          created_by_membership_id?: string | null
          created_by_type?: string
          direction?: string
          id?: string
          idempotency_key?: string | null
          inbound_stream_sequence?: number | null
          kind?: string
          operation_id?: string
          organization_id?: string
          provider_message_id?: string | null
          provider_occurred_at?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "messages_organization_id_created_by_membership_id_fkey"
            columns: ["organization_id", "created_by_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "messages_organization_id_operation_id_connection_id_fkey"
            columns: ["organization_id", "operation_id", "connection_id"]
            isOneToOne: false
            referencedRelation: "whatsapp_connections"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "messages_organization_id_operation_id_conversation_id_conn_fkey"
            columns: [
              "organization_id",
              "operation_id",
              "conversation_id",
              "connection_id",
            ]
            isOneToOne: false
            referencedRelation: "conversations"
            referencedColumns: [
              "organization_id",
              "operation_id",
              "id",
              "connection_id",
            ]
          },
        ]
      }
      operation_settings: {
        Row: {
          active_context_publication_id: string | null
          created_at: string
          operation_id: string
          organization_id: string
          production_enabled: boolean
          updated_at: string
          version: number
        }
        Insert: {
          active_context_publication_id?: string | null
          created_at?: string
          operation_id: string
          organization_id: string
          production_enabled?: boolean
          updated_at?: string
          version?: number
        }
        Update: {
          active_context_publication_id?: string | null
          created_at?: string
          operation_id?: string
          organization_id?: string
          production_enabled?: boolean
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "operation_settings_active_context_publication_fkey"
            columns: [
              "organization_id",
              "operation_id",
              "active_context_publication_id",
            ]
            isOneToOne: false
            referencedRelation: "context_publications"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
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
      opportunities: {
        Row: {
          amount_scope: string
          assigned_membership_id: string | null
          contact_id: string
          created_at: string
          id: string
          loss_reason: string | null
          operation_id: string
          organization_id: string
          pedro_context: string | null
          source_type: string
          stage: string
          stage_entered_at: string
          unit_count: number
          updated_at: string
          version: number
        }
        Insert: {
          amount_scope?: string
          assigned_membership_id?: string | null
          contact_id: string
          created_at?: string
          id?: string
          loss_reason?: string | null
          operation_id: string
          organization_id: string
          pedro_context?: string | null
          source_type?: string
          stage?: string
          stage_entered_at?: string
          unit_count?: number
          updated_at?: string
          version?: number
        }
        Update: {
          amount_scope?: string
          assigned_membership_id?: string | null
          contact_id?: string
          created_at?: string
          id?: string
          loss_reason?: string | null
          operation_id?: string
          organization_id?: string
          pedro_context?: string | null
          source_type?: string
          stage?: string
          stage_entered_at?: string
          unit_count?: number
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "opportunities_organization_contact_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "opportunities_organization_id_assigned_membership_id_fkey"
            columns: ["organization_id", "assigned_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "opportunities_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "opportunities_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      opportunity_participants: {
        Row: {
          consent_context: string | null
          contact_id: string | null
          created_at: string
          display_name: string
          id: string
          opportunity_id: string
          organization_id: string
          phone_e164: string | null
          phone_original: string | null
          role: string
        }
        Insert: {
          consent_context?: string | null
          contact_id?: string | null
          created_at?: string
          display_name: string
          id?: string
          opportunity_id: string
          organization_id: string
          phone_e164?: string | null
          phone_original?: string | null
          role?: string
        }
        Update: {
          consent_context?: string | null
          contact_id?: string | null
          created_at?: string
          display_name?: string
          id?: string
          opportunity_id?: string
          organization_id?: string
          phone_e164?: string | null
          phone_original?: string | null
          role?: string
        }
        Relationships: [
          {
            foreignKeyName: "opportunity_participants_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "opportunity_participants_organization_id_opportunity_id_fkey"
            columns: ["organization_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      opportunity_stage_history: {
        Row: {
          actor_membership_id: string | null
          actor_user_id: string | null
          correlation_id: string
          created_at: string
          from_stage: string | null
          id: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          reason: string | null
          to_stage: string
          trace_id: string
        }
        Insert: {
          actor_membership_id?: string | null
          actor_user_id?: string | null
          correlation_id: string
          created_at?: string
          from_stage?: string | null
          id?: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          reason?: string | null
          to_stage: string
          trace_id: string
        }
        Update: {
          actor_membership_id?: string | null
          actor_user_id?: string | null
          correlation_id?: string
          created_at?: string
          from_stage?: string | null
          id?: string
          operation_id?: string
          opportunity_id?: string
          organization_id?: string
          reason?: string | null
          to_stage?: string
          trace_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "opportunity_stage_history_operation_opportunity_fkey"
            columns: ["organization_id", "operation_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "opportunity_stage_history_organization_id_actor_membership_fkey"
            columns: ["organization_id", "actor_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "opportunity_stage_history_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "opportunity_stage_history_organization_id_opportunity_id_fkey"
            columns: ["organization_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      opt_outs: {
        Row: {
          contact_id: string
          created_at: string
          id: string
          organization_id: string
          phone_e164: string | null
          reason: string | null
          requested_at: string
          revoked_at: string | null
          status: string
        }
        Insert: {
          contact_id: string
          created_at?: string
          id?: string
          organization_id: string
          phone_e164?: string | null
          reason?: string | null
          requested_at?: string
          revoked_at?: string | null
          status?: string
        }
        Update: {
          contact_id?: string
          created_at?: string
          id?: string
          organization_id?: string
          phone_e164?: string | null
          reason?: string | null
          requested_at?: string
          revoked_at?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "opt_outs_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
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
      persona_versions: {
        Row: {
          archived_at: string | null
          archived_by_user_id: string | null
          baseline_version_id: string | null
          biography: Json
          content_hash: string | null
          created_at: string
          created_by_user_id: string
          diff_snapshot: Json | null
          id: string
          identity: Json
          instructions: Json
          operation_id: string
          organization_id: string
          persona_id: string
          protected_rules: Json
          published_at: string | null
          published_by_user_id: string | null
          status: string
          style_rules: Json
          updated_at: string
          validated_at: string | null
          validated_by_user_id: string | null
          validation_errors: Json
          version: number
          version_number: number
        }
        Insert: {
          archived_at?: string | null
          archived_by_user_id?: string | null
          baseline_version_id?: string | null
          biography?: Json
          content_hash?: string | null
          created_at?: string
          created_by_user_id: string
          diff_snapshot?: Json | null
          id?: string
          identity?: Json
          instructions?: Json
          operation_id: string
          organization_id: string
          persona_id: string
          protected_rules?: Json
          published_at?: string | null
          published_by_user_id?: string | null
          status?: string
          style_rules?: Json
          updated_at?: string
          validated_at?: string | null
          validated_by_user_id?: string | null
          validation_errors?: Json
          version?: number
          version_number: number
        }
        Update: {
          archived_at?: string | null
          archived_by_user_id?: string | null
          baseline_version_id?: string | null
          biography?: Json
          content_hash?: string | null
          created_at?: string
          created_by_user_id?: string
          diff_snapshot?: Json | null
          id?: string
          identity?: Json
          instructions?: Json
          operation_id?: string
          organization_id?: string
          persona_id?: string
          protected_rules?: Json
          published_at?: string | null
          published_by_user_id?: string | null
          status?: string
          style_rules?: Json
          updated_at?: string
          validated_at?: string | null
          validated_by_user_id?: string | null
          validation_errors?: Json
          version?: number
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "persona_versions_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "persona_versions_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "persona_versions_organization_id_operation_id_persona_id_b_fkey"
            columns: [
              "organization_id",
              "operation_id",
              "persona_id",
              "baseline_version_id",
            ]
            isOneToOne: false
            referencedRelation: "persona_versions"
            referencedColumns: [
              "organization_id",
              "operation_id",
              "persona_id",
              "id",
            ]
          },
          {
            foreignKeyName: "persona_versions_organization_id_operation_id_persona_id_fkey"
            columns: ["organization_id", "operation_id", "persona_id"]
            isOneToOne: false
            referencedRelation: "personas"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
        ]
      }
      personas: {
        Row: {
          created_at: string
          created_by_user_id: string
          id: string
          internal_name: string
          operation_id: string
          organization_id: string
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          created_at?: string
          created_by_user_id: string
          id?: string
          internal_name: string
          operation_id: string
          organization_id: string
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          created_at?: string
          created_by_user_id?: string
          id?: string
          internal_name?: string
          operation_id?: string
          organization_id?: string
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "personas_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "personas_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      proactive_approach_requests: {
        Row: {
          authorization_confirmed: boolean
          context: string | null
          id: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          requested_at: string
          requested_by_user_id: string
          status: string
        }
        Insert: {
          authorization_confirmed?: boolean
          context?: string | null
          id?: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          requested_at?: string
          requested_by_user_id: string
          status?: string
        }
        Update: {
          authorization_confirmed?: boolean
          context?: string | null
          id?: string
          operation_id?: string
          opportunity_id?: string
          organization_id?: string
          requested_at?: string
          requested_by_user_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "proactive_approach_requests_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "proactive_approach_requests_organization_id_opportunity_id_fkey"
            columns: ["organization_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "proactive_requests_operation_opportunity_fkey"
            columns: ["organization_id", "operation_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
        ]
      }
      provider_identities: {
        Row: {
          connection_id: string
          contact_id: string
          created_at: string
          display_name: string | null
          first_seen_at: string
          id: string
          last_seen_at: string
          operation_id: string
          organization_id: string
          updated_at: string
          version: number
        }
        Insert: {
          connection_id: string
          contact_id: string
          created_at?: string
          display_name?: string | null
          first_seen_at: string
          id?: string
          last_seen_at: string
          operation_id: string
          organization_id: string
          updated_at?: string
          version?: number
        }
        Update: {
          connection_id?: string
          contact_id?: string
          created_at?: string
          display_name?: string | null
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          operation_id?: string
          organization_id?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "provider_identities_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "provider_identities_organization_id_operation_id_connectio_fkey"
            columns: ["organization_id", "operation_id", "connection_id"]
            isOneToOne: false
            referencedRelation: "whatsapp_connections"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
        ]
      }
      provider_identity_aliases: {
        Row: {
          alias_type: string
          alias_value: string
          connection_id: string
          created_at: string
          id: string
          operation_id: string
          organization_id: string
          provider_identity_id: string
          valid_from: string
          valid_until: string | null
        }
        Insert: {
          alias_type: string
          alias_value: string
          connection_id: string
          created_at?: string
          id?: string
          operation_id: string
          organization_id: string
          provider_identity_id: string
          valid_from: string
          valid_until?: string | null
        }
        Update: {
          alias_type?: string
          alias_value?: string
          connection_id?: string
          created_at?: string
          id?: string
          operation_id?: string
          organization_id?: string
          provider_identity_id?: string
          valid_from?: string
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "provider_identity_aliases_organization_id_operation_id_con_fkey"
            columns: [
              "organization_id",
              "operation_id",
              "connection_id",
              "provider_identity_id",
            ]
            isOneToOne: false
            referencedRelation: "provider_identities"
            referencedColumns: [
              "organization_id",
              "operation_id",
              "connection_id",
              "id",
            ]
          },
        ]
      }
      scheduled_jobs: {
        Row: {
          aggregate_id: string
          aggregate_sequence: number
          aggregate_type: string
          aggregate_version: number | null
          attempts: number
          causation_id: string | null
          completed_at: string | null
          contention_count: number
          correlation_id: string
          created_at: string
          dedupe_key: string
          effect_key: string
          id: string
          job_type: string
          last_error_class: string | null
          last_error_code: string | null
          lease_token: string | null
          lease_until: string | null
          max_attempts: number
          operation_id: string
          organization_id: string
          payload: Json
          published_at: string | null
          queue_message_id: number | null
          run_at: string
          status: string
          target_queue: string
          trace_id: string
          updated_at: string
        }
        Insert: {
          aggregate_id: string
          aggregate_sequence: number
          aggregate_type: string
          aggregate_version?: number | null
          attempts?: number
          causation_id?: string | null
          completed_at?: string | null
          contention_count?: number
          correlation_id: string
          created_at?: string
          dedupe_key: string
          effect_key: string
          id?: string
          job_type: string
          last_error_class?: string | null
          last_error_code?: string | null
          lease_token?: string | null
          lease_until?: string | null
          max_attempts?: number
          operation_id: string
          organization_id: string
          payload?: Json
          published_at?: string | null
          queue_message_id?: number | null
          run_at: string
          status?: string
          target_queue: string
          trace_id: string
          updated_at?: string
        }
        Update: {
          aggregate_id?: string
          aggregate_sequence?: number
          aggregate_type?: string
          aggregate_version?: number | null
          attempts?: number
          causation_id?: string | null
          completed_at?: string | null
          contention_count?: number
          correlation_id?: string
          created_at?: string
          dedupe_key?: string
          effect_key?: string
          id?: string
          job_type?: string
          last_error_class?: string | null
          last_error_code?: string | null
          lease_token?: string | null
          lease_until?: string | null
          max_attempts?: number
          operation_id?: string
          organization_id?: string
          payload?: Json
          published_at?: string | null
          queue_message_id?: number | null
          run_at?: string
          status?: string
          target_queue?: string
          trace_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "scheduled_jobs_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      source_attributions: {
        Row: {
          attributed_at: string
          contact_id: string
          created_at: string
          details: Json
          id: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          source_label: string | null
          source_type: string
        }
        Insert: {
          attributed_at?: string
          contact_id: string
          created_at?: string
          details?: Json
          id?: string
          operation_id: string
          opportunity_id: string
          organization_id: string
          source_label?: string | null
          source_type: string
        }
        Update: {
          attributed_at?: string
          contact_id?: string
          created_at?: string
          details?: Json
          id?: string
          operation_id?: string
          opportunity_id?: string
          organization_id?: string
          source_label?: string | null
          source_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "source_attributions_contact_opportunity_fkey"
            columns: ["organization_id", "contact_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "contact_id", "id"]
          },
          {
            foreignKeyName: "source_attributions_operation_opportunity_fkey"
            columns: ["organization_id", "operation_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "operation_id", "id"]
          },
          {
            foreignKeyName: "source_attributions_organization_id_contact_id_fkey"
            columns: ["organization_id", "contact_id"]
            isOneToOne: false
            referencedRelation: "contacts"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "source_attributions_organization_id_operation_id_fkey"
            columns: ["organization_id", "operation_id"]
            isOneToOne: false
            referencedRelation: "operations"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "source_attributions_organization_id_opportunity_id_fkey"
            columns: ["organization_id", "opportunity_id"]
            isOneToOne: false
            referencedRelation: "opportunities"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      staff_profiles: {
        Row: {
          created_at: string
          creci: string | null
          full_name: string
          membership_id: string
          organization_id: string
          updated_at: string
          whatsapp: string
        }
        Insert: {
          created_at?: string
          creci?: string | null
          full_name: string
          membership_id: string
          organization_id: string
          updated_at?: string
          whatsapp: string
        }
        Update: {
          created_at?: string
          creci?: string | null
          full_name?: string
          membership_id?: string
          organization_id?: string
          updated_at?: string
          whatsapp?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_profiles_organization_id_membership_id_fkey"
            columns: ["organization_id", "membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["organization_id", "id"]
          },
        ]
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
      whatsapp_connections: {
        Row: {
          adapter_type: string
          capabilities: Json
          created_at: string
          display_address: string | null
          display_name: string
          id: string
          inbound_enabled: boolean
          is_test: boolean
          operation_id: string
          organization_id: string
          provider_connection_id: string
          status: string
          updated_at: string
          version: number
        }
        Insert: {
          adapter_type: string
          capabilities?: Json
          created_at?: string
          display_address?: string | null
          display_name: string
          id?: string
          inbound_enabled?: boolean
          is_test?: boolean
          operation_id: string
          organization_id: string
          provider_connection_id: string
          status?: string
          updated_at?: string
          version?: number
        }
        Update: {
          adapter_type?: string
          capabilities?: Json
          created_at?: string
          display_address?: string | null
          display_name?: string
          id?: string
          inbound_enabled?: boolean
          is_test?: boolean
          operation_id?: string
          organization_id?: string
          provider_connection_id?: string
          status?: string
          updated_at?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "whatsapp_connections_organization_id_operation_id_fkey"
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
      archive_context_drafts: {
        Args: {
          behavioral_version_id: string
          factual_version_id: string
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: Json
      }
      assume_conversation: {
        Args: {
          expected_version: number
          request_correlation_id: string
          request_trace_id: string
          target_conversation_id: string
        }
        Returns: Json
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
      create_context_drafts: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: Json
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
      create_manual_lead: {
        Args: {
          amount_scope_value: string
          internal_note_value: string
          lead_name: string
          lead_source: string
          participant_name: string
          participant_phone_original: string
          pedro_context_value: string
          phone_original: string
          registration_action: string
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
          unit_count_value: number
        }
        Returns: Json
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
      get_contact_merge_candidates: {
        Args: { excluded_contact_id: string; target_operation_id: string }
        Returns: Json
      }
      get_context_workspace: {
        Args: { target_operation_id: string }
        Returns: Json
      }
      get_conversation_detail: {
        Args: { target_conversation_id: string }
        Returns: Json
      }
      get_cron_runtime_health: { Args: never; Returns: Json }
      get_durable_processing_alerts: {
        Args: { maximum_alerts?: number; target_operation_id: string }
        Returns: {
          alert_id: string
          correlation_id: string
          created_at: string
          dead_letter_id: string
          effect_key_hash: string
          failure_class: string
          failure_code: string
          resolved_at: string
          scheduled_job_id: string
          severity: string
          source_queue: string
          status: string
          trace_id: string
        }[]
      }
      get_durable_processing_health: {
        Args: { target_operation_id: string }
        Returns: Json
      }
      get_inbox_list: { Args: { target_operation_id: string }; Returns: Json }
      get_invitation_entry: {
        Args: { invitation_token: string }
        Returns: {
          invitation_kind: string
          link_status: string
          organization_name: string
        }[]
      }
      get_lead_detail: {
        Args: { target_opportunity_id: string }
        Returns: Json
      }
      get_lead_list: {
        Args: { target_operation_id: string; view_scope: string }
        Returns: Json
      }
      get_member_deactivation_impact: {
        Args: { target_membership_id: string; target_operation_id: string }
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
      get_pipeline_board: {
        Args: { target_operation_id: string; view_scope: string }
        Returns: Json
      }
      get_team_management: {
        Args: { target_operation_id: string }
        Returns: Json
      }
      ingest_simulated_inbound: {
        Args: {
          normalized_event: Json
          raw_body: string
          request_correlation_id: string
          request_trace_id: string
          target_connection_id: string
        }
        Returns: Json
      }
      initialize_context_drafts: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: Json
      }
      merge_contacts: {
        Args: {
          duplicate_contact_id: string
          expected_duplicate_version: number
          expected_primary_version: number
          primary_contact_id: string
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: Json
      }
      pause_conversation: {
        Args: {
          expected_version: number
          pause_reason: string
          request_correlation_id: string
          request_trace_id: string
          target_conversation_id: string
        }
        Returns: Json
      }
      publish_context: {
        Args: {
          behavioral_expected_version: number
          behavioral_version_id: string
          factual_expected_version: number
          factual_version_id: string
          request_correlation_id: string
          request_trace_id: string
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
      reopen_opportunity_on_inbound: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_opportunity_id: string
        }
        Returns: string
      }
      replay_dead_letter: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_dead_letter_id: string
        }
        Returns: Json
      }
      replay_dead_letter_t06_base: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_dead_letter_id: string
        }
        Returns: Json
      }
      replay_dead_letter_t06_nonreplayable_base: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_dead_letter_id: string
        }
        Returns: Json
      }
      replay_dead_letter_t06_payload_expiry_base: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_dead_letter_id: string
        }
        Returns: Json
      }
      replay_dead_letter_t06_review_base: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_dead_letter_id: string
        }
        Returns: Json
      }
      replay_dead_letter_t06_stream_fenced_base: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_dead_letter_id: string
        }
        Returns: Json
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
      resolve_infrastructure_durable_alert: {
        Args: {
          request_correlation_id: string
          request_trace_id: string
          target_alert_id: string
        }
        Returns: Json
      }
      return_conversation_to_pedro: {
        Args: {
          expected_version: number
          request_correlation_id: string
          request_trace_id: string
          return_action: string
          target_automation_mode: string
          target_conversation_id: string
        }
        Returns: Json
      }
      reverse_contact_merge: {
        Args: {
          expected_duplicate_version: number
          expected_primary_version: number
          request_correlation_id: string
          request_trace_id: string
          target_contact_merge_id: string
        }
        Returns: Json
      }
      run_durable_workers: {
        Args: { maximum_messages?: number }
        Returns: Json
      }
      save_institutional_profile_draft: {
        Args: {
          expected_version: number
          profile_fields: Json
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
          target_version_id: string
        }
        Returns: Json
      }
      save_persona_draft: {
        Args: {
          expected_version: number
          persona_biography: Json
          persona_identity: Json
          persona_instructions: Json
          persona_style_rules: Json
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
          target_version_id: string
        }
        Returns: Json
      }
      send_human_message: {
        Args: {
          command_id: string
          expected_version: number
          message_text: string
          request_correlation_id: string
          request_trace_id: string
          target_conversation_id: string
        }
        Returns: Json
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
      transition_opportunity: {
        Args: {
          expected_version: number
          human_decision: boolean
          request_correlation_id: string
          request_trace_id: string
          target_opportunity_id: string
          target_stage: string
          transition_reason: string
        }
        Returns: Json
      }
      validate_context_drafts: {
        Args: {
          behavioral_expected_version: number
          behavioral_version_id: string
          factual_expected_version: number
          factual_version_id: string
          request_correlation_id: string
          request_trace_id: string
          target_operation_id: string
        }
        Returns: Json
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
