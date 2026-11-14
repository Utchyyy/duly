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
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      approval_queue: {
        Row: {
          created_at: string
          created_by: string | null
          draft: Json
          final_draft: Json | null
          id: string
          kind: string
          org_id: string
          reject_reason: string | null
          result_brief_id: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          source: Json
          status: Database["public"]["Enums"]["approval_status"]
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          draft?: Json
          final_draft?: Json | null
          id?: string
          kind?: string
          org_id: string
          reject_reason?: string | null
          result_brief_id?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          source?: Json
          status?: Database["public"]["Enums"]["approval_status"]
        }
        Update: {
          created_at?: string
          created_by?: string | null
          draft?: Json
          final_draft?: Json | null
          id?: string
          kind?: string
          org_id?: string
          reject_reason?: string | null
          result_brief_id?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          source?: Json
          status?: Database["public"]["Enums"]["approval_status"]
        }
        Relationships: [
          {
            foreignKeyName: "approval_queue_result_brief_id_fkey"
            columns: ["result_brief_id"]
            isOneToOne: false
            referencedRelation: "briefs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "approval_queue_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_log: {
        Row: {
          actor: string | null
          at: string
          brief_id: string | null
          changes: Json
          id: number
          job_id: string | null
          op: string
          org_ids: string[]
          quote_id: string | null
          row_id: string | null
          source: string
          summary: string
          table_name: string
        }
        Insert: {
          actor?: string | null
          at?: string
          brief_id?: string | null
          changes?: Json
          id?: number
          job_id?: string | null
          op: string
          org_ids?: string[]
          quote_id?: string | null
          row_id?: string | null
          source?: string
          summary: string
          table_name: string
        }
        Update: {
          actor?: string | null
          at?: string
          brief_id?: string | null
          changes?: Json
          id?: number
          job_id?: string | null
          op?: string
          org_ids?: string[]
          quote_id?: string | null
          row_id?: string | null
          source?: string
          summary?: string
          table_name?: string
        }
        Relationships: []
      }
      area_results: {
        Row: {
          area_id: string
          done_at: string | null
          done_by: string | null
          done_by_operative: boolean
          job_id: string
          standard_id: string
          verdict: string | null
          verdict_at: string | null
          verdict_by: string | null
        }
        Insert: {
          area_id: string
          done_at?: string | null
          done_by?: string | null
          done_by_operative?: boolean
          job_id: string
          standard_id: string
          verdict?: string | null
          verdict_at?: string | null
          verdict_by?: string | null
        }
        Update: {
          area_id?: string
          done_at?: string | null
          done_by?: string | null
          done_by_operative?: boolean
          job_id?: string
          standard_id?: string
          verdict?: string | null
          verdict_at?: string | null
          verdict_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "area_results_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      brief_versions: {
        Row: {
          brief_id: string
          created_at: string
          lateness_tolerance_min: number | null
          locked_at: string | null
          locked_by: string | null
          notes: string | null
          preferred_days: string[] | null
          preferred_start: string | null
          schedule: Json
          version: number
          visits_per_week: number | null
        }
        Insert: {
          brief_id: string
          created_at?: string
          lateness_tolerance_min?: number | null
          locked_at?: string | null
          locked_by?: string | null
          notes?: string | null
          preferred_days?: string[] | null
          preferred_start?: string | null
          schedule?: Json
          version: number
          visits_per_week?: number | null
        }
        Update: {
          brief_id?: string
          created_at?: string
          lateness_tolerance_min?: number | null
          locked_at?: string | null
          locked_by?: string | null
          notes?: string | null
          preferred_days?: string[] | null
          preferred_start?: string | null
          schedule?: Json
          version?: number
          visits_per_week?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "brief_versions_brief_id_fkey"
            columns: ["brief_id"]
            isOneToOne: false
            referencedRelation: "briefs"
            referencedColumns: ["id"]
          },
        ]
      }
      briefs: {
        Row: {
          buyer_org_id: string
          created_at: string
          created_by: string | null
          current_version: number
          id: string
          site_id: string
          status: Database["public"]["Enums"]["brief_status"]
          title: string
        }
        Insert: {
          buyer_org_id: string
          created_at?: string
          created_by?: string | null
          current_version?: number
          id?: string
          site_id: string
          status?: Database["public"]["Enums"]["brief_status"]
          title: string
        }
        Update: {
          buyer_org_id?: string
          created_at?: string
          created_by?: string | null
          current_version?: number
          id?: string
          site_id?: string
          status?: Database["public"]["Enums"]["brief_status"]
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "briefs_buyer_org_id_fkey"
            columns: ["buyer_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "briefs_site_id_fkey"
            columns: ["site_id"]
            isOneToOne: false
            referencedRelation: "sites"
            referencedColumns: ["id"]
          },
        ]
      }
      contracts: {
        Row: {
          billing: string
          brief_id: string
          brief_version: number
          buyer_org_id: string
          created_at: string
          currency: string
          ends_on: string | null
          id: string
          loyalty: Json | null
          monthly_value: number | null
          payment_terms_days: number
          quality_target: number
          quote_id: string | null
          service_terms: Json
          site_id: string
          sla_response_hours: number
          starts_on: string | null
          status: Database["public"]["Enums"]["contract_status"]
          vendor_org_id: string
        }
        Insert: {
          billing?: string
          brief_id: string
          brief_version: number
          buyer_org_id: string
          created_at?: string
          currency?: string
          ends_on?: string | null
          id?: string
          loyalty?: Json | null
          monthly_value?: number | null
          payment_terms_days?: number
          quality_target?: number
          quote_id?: string | null
          service_terms?: Json
          site_id: string
          sla_response_hours?: number
          starts_on?: string | null
          status?: Database["public"]["Enums"]["contract_status"]
          vendor_org_id: string
        }
        Update: {
          billing?: string
          brief_id?: string
          brief_version?: number
          buyer_org_id?: string
          created_at?: string
          currency?: string
          ends_on?: string | null
          id?: string
          loyalty?: Json | null
          monthly_value?: number | null
          payment_terms_days?: number
          quality_target?: number
          quote_id?: string | null
          service_terms?: Json
          site_id?: string
          sla_response_hours?: number
          starts_on?: string | null
          status?: Database["public"]["Enums"]["contract_status"]
          vendor_org_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "contracts_brief_id_brief_version_fkey"
            columns: ["brief_id", "brief_version"]
            isOneToOne: false
            referencedRelation: "brief_versions"
            referencedColumns: ["brief_id", "version"]
          },
          {
            foreignKeyName: "contracts_buyer_org_id_fkey"
            columns: ["buyer_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contracts_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contracts_site_id_fkey"
            columns: ["site_id"]
            isOneToOne: false
            referencedRelation: "sites"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "contracts_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      dbs_applications: {
        Row: {
          admin_notes: string | null
          certificate_reference: string | null
          certificate_type:
            | Database["public"]["Enums"]["dbs_certificate_type"]
            | null
          created_at: string
          form_data: Json
          id: string
          path: Database["public"]["Enums"]["dbs_path"]
          status: Database["public"]["Enums"]["dbs_status"]
          update_service_id: string | null
          updated_at: string
          worker_id: string
        }
        Insert: {
          admin_notes?: string | null
          certificate_reference?: string | null
          certificate_type?:
            | Database["public"]["Enums"]["dbs_certificate_type"]
            | null
          created_at?: string
          form_data?: Json
          id?: string
          path: Database["public"]["Enums"]["dbs_path"]
          status?: Database["public"]["Enums"]["dbs_status"]
          update_service_id?: string | null
          updated_at?: string
          worker_id: string
        }
        Update: {
          admin_notes?: string | null
          certificate_reference?: string | null
          certificate_type?:
            | Database["public"]["Enums"]["dbs_certificate_type"]
            | null
          created_at?: string
          form_data?: Json
          id?: string
          path?: Database["public"]["Enums"]["dbs_path"]
          status?: Database["public"]["Enums"]["dbs_status"]
          update_service_id?: string | null
          updated_at?: string
          worker_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "dbs_applications_worker_id_fkey"
            columns: ["worker_id"]
            isOneToOne: false
            referencedRelation: "workers"
            referencedColumns: ["id"]
          },
        ]
      }
      evidence: {
        Row: {
          plan_item_id: string | null
          area_id: string
          created_at: string
          id: string
          job_id: string
          kind: Database["public"]["Enums"]["evidence_kind"]
          lat: number | null
          lng: number | null
          storage_path: string
          taken_at: string | null
          uploaded_by: string | null
          within_geofence: boolean | null
        }
        Insert: {
          plan_item_id?: string | null
          area_id: string
          created_at?: string
          id?: string
          job_id: string
          kind: Database["public"]["Enums"]["evidence_kind"]
          lat?: number | null
          lng?: number | null
          storage_path: string
          taken_at?: string | null
          uploaded_by?: string | null
          within_geofence?: boolean | null
        }
        Update: {
          plan_item_id?: string | null
          area_id?: string
          created_at?: string
          id?: string
          job_id?: string
          kind?: Database["public"]["Enums"]["evidence_kind"]
          lat?: number | null
          lng?: number | null
          storage_path?: string
          taken_at?: string | null
          uploaded_by?: string | null
          within_geofence?: boolean | null
        }
        Relationships: [
          {
            foreignKeyName: "evidence_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      issues: {
        Row: {
          plan_item_id: string | null
          plan_label: string | null
          created_at: string
          description: string
          id: string
          job_id: string | null
          kind: Database["public"]["Enums"]["issue_kind"]
          raised_by: string
          resolution: string | null
          resolved_at: string | null
          site_id: string | null
          sla_due_at: string | null
          status: Database["public"]["Enums"]["issue_status"]
        }
        Insert: {
          plan_item_id?: string | null
          plan_label?: string | null
          created_at?: string
          description: string
          id?: string
          job_id?: string | null
          kind: Database["public"]["Enums"]["issue_kind"]
          raised_by?: string
          resolution?: string | null
          resolved_at?: string | null
          site_id?: string | null
          sla_due_at?: string | null
          status?: Database["public"]["Enums"]["issue_status"]
        }
        Update: {
          plan_item_id?: string | null
          plan_label?: string | null
          created_at?: string
          description?: string
          id?: string
          job_id?: string | null
          kind?: Database["public"]["Enums"]["issue_kind"]
          raised_by?: string
          resolution?: string | null
          resolved_at?: string | null
          site_id?: string | null
          sla_due_at?: string | null
          status?: Database["public"]["Enums"]["issue_status"]
        }
        Relationships: [
          {
            foreignKeyName: "issues_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "issues_site_id_fkey"
            columns: ["site_id"]
            isOneToOne: false
            referencedRelation: "sites"
            referencedColumns: ["id"]
          },
        ]
      }
      job_assignments: {
        Row: {
          created_at: string
          job_id: string
          role: string
          user_id: string
        }
        Insert: {
          created_at?: string
          job_id: string
          role?: string
          user_id: string
        }
        Update: {
          created_at?: string
          job_id?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "job_assignments_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      job_events: {
        Row: {
          actor: string | null
          at: string
          data: Json
          id: number
          job_id: string
          kind: string
          lat: number | null
          lng: number | null
          within_geofence: boolean | null
        }
        Insert: {
          actor?: string | null
          at?: string
          data?: Json
          id?: never
          job_id: string
          kind: string
          lat?: number | null
          lng?: number | null
          within_geofence?: boolean | null
        }
        Update: {
          actor?: string | null
          at?: string
          data?: Json
          id?: never
          job_id?: string
          kind?: string
          lat?: number | null
          lng?: number | null
          within_geofence?: boolean | null
        }
        Relationships: [
          {
            foreignKeyName: "job_events_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      jobs: {
        Row: {
          brief_id: string
          brief_version: number
          buyer_org_id: string
          contract_id: string | null
          created_at: string
          currency: string
          id: string
          quote_id: string | null
          scheduled_end: string
          scheduled_start: string
          site_id: string
          status: Database["public"]["Enums"]["job_status"]
          updated_at: string
          value: number | null
          vendor_org_id: string
        }
        Insert: {
          brief_id: string
          brief_version: number
          buyer_org_id: string
          contract_id?: string | null
          created_at?: string
          currency?: string
          id?: string
          quote_id?: string | null
          scheduled_end: string
          scheduled_start: string
          site_id: string
          status?: Database["public"]["Enums"]["job_status"]
          updated_at?: string
          value?: number | null
          vendor_org_id: string
        }
        Update: {
          brief_id?: string
          brief_version?: number
          buyer_org_id?: string
          contract_id?: string | null
          created_at?: string
          currency?: string
          id?: string
          quote_id?: string | null
          scheduled_end?: string
          scheduled_start?: string
          site_id?: string
          status?: Database["public"]["Enums"]["job_status"]
          updated_at?: string
          value?: number | null
          vendor_org_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "jobs_brief_id_brief_version_fkey"
            columns: ["brief_id", "brief_version"]
            isOneToOne: false
            referencedRelation: "brief_versions"
            referencedColumns: ["brief_id", "version"]
          },
          {
            foreignKeyName: "jobs_buyer_org_id_fkey"
            columns: ["buyer_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_site_id_fkey"
            columns: ["site_id"]
            isOneToOne: false
            referencedRelation: "sites"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "jobs_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      markets: {
        Row: {
          code: string
          created_at: string
          currency: string
          data_region: string
          locale: string
          name: string
          postcode_pattern: string | null
          tax_name: string | null
          tax_rate: number | null
          timezone: string
        }
        Insert: {
          code: string
          created_at?: string
          currency: string
          data_region: string
          locale: string
          name: string
          postcode_pattern?: string | null
          tax_name?: string | null
          tax_rate?: number | null
          timezone?: string
        }
        Update: {
          code?: string
          created_at?: string
          currency?: string
          data_region?: string
          locale?: string
          name?: string
          postcode_pattern?: string | null
          tax_name?: string | null
          tax_rate?: number | null
          timezone?: string
        }
        Relationships: []
      }
      memberships: {
        Row: {
          created_at: string
          org_id: string
          role: Database["public"]["Enums"]["member_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          org_id: string
          role: Database["public"]["Enums"]["member_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          org_id?: string
          role?: Database["public"]["Enums"]["member_role"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "memberships_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_settings: {
        Row: {
          email_enabled: boolean
          email_muted: string[]
          updated_at: string
          user_id: string
        }
        Insert: {
          email_enabled?: boolean
          email_muted?: string[]
          updated_at?: string
          user_id: string
        }
        Update: {
          email_enabled?: boolean
          email_muted?: string[]
          updated_at?: string
          user_id?: string
        }
        Relationships: []
      }
      notifications: {
        Row: {
          body: string
          category: string
          created_at: string
          dedupe_key: string | null
          email_attempts: number
          email_error: string | null
          email_next_at: string | null
          email_sent_at: string | null
          email_status: string
          event: string
          id: string
          link: string | null
          org_id: string | null
          read_at: string | null
          title: string
          user_id: string
        }
        Insert: {
          body?: string
          category: string
          created_at?: string
          dedupe_key?: string | null
          email_attempts?: number
          email_error?: string | null
          email_next_at?: string | null
          email_sent_at?: string | null
          email_status?: string
          event: string
          id?: string
          link?: string | null
          org_id?: string | null
          read_at?: string | null
          title: string
          user_id: string
        }
        Update: {
          body?: string
          category?: string
          created_at?: string
          dedupe_key?: string | null
          email_attempts?: number
          email_error?: string | null
          email_next_at?: string | null
          email_sent_at?: string | null
          email_status?: string
          event?: string
          id?: string
          link?: string | null
          org_id?: string | null
          read_at?: string | null
          title?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notifications_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      organisations: {
        Row: {
          companies_house_no: string | null
          created_at: string
          id: string
          kind: Database["public"]["Enums"]["org_kind"]
          market: string
          name: string
          segment: string | null
          verification_tier: number
        }
        Insert: {
          companies_house_no?: string | null
          created_at?: string
          id?: string
          kind: Database["public"]["Enums"]["org_kind"]
          market?: string
          name: string
          segment?: string | null
          verification_tier?: number
        }
        Update: {
          companies_house_no?: string | null
          created_at?: string
          id?: string
          kind?: Database["public"]["Enums"]["org_kind"]
          market?: string
          name?: string
          segment?: string | null
          verification_tier?: number
        }
        Relationships: [
          {
            foreignKeyName: "organisations_market_fkey"
            columns: ["market"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "organisations_segment_fkey"
            columns: ["segment"]
            isOneToOne: false
            referencedRelation: "segments"
            referencedColumns: ["code"]
          },
        ]
      }
      payments: {
        Row: {
          amount: number
          contract_id: string | null
          created_at: string
          currency: string
          due_at: string | null
          id: string
          job_id: string | null
          kind: Database["public"]["Enums"]["payment_kind"]
          note: string | null
          paid_at: string | null
          period: string | null
          provider: string
          provider_ref: string | null
          status: string
        }
        Insert: {
          amount: number
          contract_id?: string | null
          created_at?: string
          currency?: string
          due_at?: string | null
          id?: string
          job_id?: string | null
          kind: Database["public"]["Enums"]["payment_kind"]
          note?: string | null
          paid_at?: string | null
          period?: string | null
          provider: string
          provider_ref?: string | null
          status?: string
        }
        Update: {
          amount?: number
          contract_id?: string | null
          created_at?: string
          currency?: string
          due_at?: string | null
          id?: string
          job_id?: string | null
          kind?: Database["public"]["Enums"]["payment_kind"]
          note?: string | null
          paid_at?: string | null
          period?: string | null
          provider?: string
          provider_ref?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_contract_id_fkey"
            columns: ["contract_id"]
            isOneToOne: false
            referencedRelation: "contracts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      plan_results: {
        Row: {
          done: boolean
          done_at: string | null
          done_by: string | null
          job_id: string
          plan_item_id: string
          verdict: string | null
          verdict_at: string | null
          verdict_by: string | null
        }
        Insert: {
          done?: boolean
          done_at?: string | null
          done_by?: string | null
          job_id: string
          plan_item_id: string
          verdict?: string | null
          verdict_at?: string | null
          verdict_by?: string | null
        }
        Update: {
          done?: boolean
          done_at?: string | null
          done_by?: string | null
          job_id?: string
          plan_item_id?: string
          verdict?: string | null
          verdict_at?: string | null
          verdict_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "plan_results_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
        ]
      }
      policies: {
        Row: {
          balance_release_hours: number
          created_at: string
          first_release_on: string
          first_release_pct: number
          lateness_tolerance_min: number
          market: string
          min_verification_tier: number
          payment_model: string
          platform_fee_pct: number | null
          ranking_weights: Json
          reclean_window_hours: number
          segment: string
          standards_library: string | null
        }
        Insert: {
          balance_release_hours?: number
          created_at?: string
          first_release_on?: string
          first_release_pct?: number
          lateness_tolerance_min?: number
          market: string
          min_verification_tier?: number
          payment_model: string
          platform_fee_pct?: number | null
          ranking_weights?: Json
          reclean_window_hours?: number
          segment: string
          standards_library?: string | null
        }
        Update: {
          balance_release_hours?: number
          created_at?: string
          first_release_on?: string
          first_release_pct?: number
          lateness_tolerance_min?: number
          market?: string
          min_verification_tier?: number
          payment_model?: string
          platform_fee_pct?: number | null
          ranking_weights?: Json
          reclean_window_hours?: number
          segment?: string
          standards_library?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "policies_market_fkey"
            columns: ["market"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "policies_segment_fkey"
            columns: ["segment"]
            isOneToOne: false
            referencedRelation: "segments"
            referencedColumns: ["code"]
          },
        ]
      }
      profiles: {
        Row: {
          created_at: string
          full_name: string | null
          id: string
          phone: string | null
        }
        Insert: {
          created_at?: string
          full_name?: string | null
          id: string
          phone?: string | null
        }
        Update: {
          created_at?: string
          full_name?: string | null
          id?: string
          phone?: string | null
        }
        Relationships: []
      }
      quotes: {
        Row: {
          brief_id: string
          brief_version: number
          created_at: string
          currency: string
          id: string
          lines: Json
          status: Database["public"]["Enums"]["quote_status"]
          submitted_at: string | null
          total: number | null
          urgency: string
          valid_until: string | null
          vendor_org_id: string
        }
        Insert: {
          brief_id: string
          brief_version: number
          created_at?: string
          currency?: string
          id?: string
          lines?: Json
          status?: Database["public"]["Enums"]["quote_status"]
          submitted_at?: string | null
          total?: number | null
          urgency?: string
          valid_until?: string | null
          vendor_org_id: string
        }
        Update: {
          brief_id?: string
          brief_version?: number
          created_at?: string
          currency?: string
          id?: string
          lines?: Json
          status?: Database["public"]["Enums"]["quote_status"]
          submitted_at?: string | null
          total?: number | null
          urgency?: string
          valid_until?: string | null
          vendor_org_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "quotes_brief_id_brief_version_fkey"
            columns: ["brief_id", "brief_version"]
            isOneToOne: false
            referencedRelation: "brief_versions"
            referencedColumns: ["brief_id", "version"]
          },
          {
            foreignKeyName: "quotes_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      schedule_templates: {
        Row: {
          created_at: string
          id: string
          name: string
          sections: Json
          segment: string | null
          updated_at: string
          vendor_org_id: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          name: string
          sections?: Json
          segment?: string | null
          updated_at?: string
          vendor_org_id?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          name?: string
          sections?: Json
          segment?: string | null
          updated_at?: string
          vendor_org_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "schedule_templates_segment_fkey"
            columns: ["segment"]
            isOneToOne: false
            referencedRelation: "segments"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "schedule_templates_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      segments: {
        Row: {
          code: string
          created_at: string
          description: string | null
          name: string
        }
        Insert: {
          code: string
          created_at?: string
          description?: string | null
          name: string
        }
        Update: {
          code?: string
          created_at?: string
          description?: string | null
          name?: string
        }
        Relationships: []
      }
      shift_events: {
        Row: {
          event_type: string
          id: string
          notes: string | null
          occurred_at: string
          shift_id: string
          worker_id: string | null
        }
        Insert: {
          event_type: string
          id?: string
          notes?: string | null
          occurred_at?: string
          shift_id: string
          worker_id?: string | null
        }
        Update: {
          event_type?: string
          id?: string
          notes?: string | null
          occurred_at?: string
          shift_id?: string
          worker_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shift_events_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_events_worker_id_fkey"
            columns: ["worker_id"]
            isOneToOne: false
            referencedRelation: "workers"
            referencedColumns: ["id"]
          },
        ]
      }
      shifts: {
        Row: {
          created_at: string
          end_time: string
          filled_by: string | null
          hourly_pay: number
          id: string
          job_id: string | null
          shift_date: string
          start_time: string
          status: Database["public"]["Enums"]["shift_status"]
          town_id: number
          vendor_org_id: string
        }
        Insert: {
          created_at?: string
          end_time: string
          filled_by?: string | null
          hourly_pay: number
          id?: string
          job_id?: string | null
          shift_date: string
          start_time: string
          status?: Database["public"]["Enums"]["shift_status"]
          town_id: number
          vendor_org_id: string
        }
        Update: {
          created_at?: string
          end_time?: string
          filled_by?: string | null
          hourly_pay?: number
          id?: string
          job_id?: string | null
          shift_date?: string
          start_time?: string
          status?: Database["public"]["Enums"]["shift_status"]
          town_id?: number
          vendor_org_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shifts_filled_by_fkey"
            columns: ["filled_by"]
            isOneToOne: false
            referencedRelation: "workers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_job_id_fkey"
            columns: ["job_id"]
            isOneToOne: false
            referencedRelation: "jobs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_town_id_fkey"
            columns: ["town_id"]
            isOneToOne: false
            referencedRelation: "towns"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      sites: {
        Row: {
          access_notes: string | null
          address_line1: string | null
          created_at: string
          floor_area_m2: number | null
          geofence_m: number
          id: string
          lat: number | null
          lng: number | null
          name: string
          org_id: string
          postcode: string | null
          town: string | null
        }
        Insert: {
          access_notes?: string | null
          address_line1?: string | null
          created_at?: string
          floor_area_m2?: number | null
          geofence_m?: number
          id?: string
          lat?: number | null
          lng?: number | null
          name: string
          org_id: string
          postcode?: string | null
          town?: string | null
        }
        Update: {
          access_notes?: string | null
          address_line1?: string | null
          created_at?: string
          floor_area_m2?: number | null
          geofence_m?: number
          id?: string
          lat?: number | null
          lng?: number | null
          name?: string
          org_id?: string
          postcode?: string | null
          town?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sites_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      standards_library: {
        Row: {
          area_type: string
          created_at: string
          id: string
          segment: string
          text: string
        }
        Insert: {
          area_type: string
          created_at?: string
          id?: string
          segment: string
          text: string
        }
        Update: {
          area_type?: string
          created_at?: string
          id?: string
          segment?: string
          text?: string
        }
        Relationships: [
          {
            foreignKeyName: "standards_library_segment_fkey"
            columns: ["segment"]
            isOneToOne: false
            referencedRelation: "segments"
            referencedColumns: ["code"]
          },
        ]
      }
      towns: {
        Row: {
          id: number
          lat: number
          lng: number
          market: string
          name: string
        }
        Insert: {
          id?: never
          lat: number
          lng: number
          market?: string
          name: string
        }
        Update: {
          id?: never
          lat?: number
          lng?: number
          market?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "towns_market_fkey"
            columns: ["market"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["code"]
          },
        ]
      }
      vendor_profiles: {
        Row: {
          add_ons: Json
          base_lat: number | null
          base_lng: number | null
          description: string | null
          hourly_rate: number | null
          org_id: string
          service_radius_km: number
          updated_at: string
          urgency_pct: Json
        }
        Insert: {
          add_ons?: Json
          base_lat?: number | null
          base_lng?: number | null
          description?: string | null
          hourly_rate?: number | null
          org_id: string
          service_radius_km?: number
          updated_at?: string
          urgency_pct?: Json
        }
        Update: {
          add_ons?: Json
          base_lat?: number | null
          base_lng?: number | null
          description?: string | null
          hourly_rate?: number | null
          org_id?: string
          service_radius_km?: number
          updated_at?: string
          urgency_pct?: Json
        }
        Relationships: [
          {
            foreignKeyName: "vendor_profiles_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: true
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      vendor_scores: {
        Row: {
          computed_at: string
          dispute_rate: number | null
          jobs_completed: number
          on_time_rate: number | null
          org_id: string
          plan_followed_rate: number | null
          quality_score: number | null
          repeat_client_rate: number | null
          right_first_time_rate: number | null
          standards_met_rate: number | null
        }
        Insert: {
          computed_at?: string
          dispute_rate?: number | null
          jobs_completed?: number
          on_time_rate?: number | null
          org_id: string
          plan_followed_rate?: number | null
          quality_score?: number | null
          repeat_client_rate?: number | null
          right_first_time_rate?: number | null
          standards_met_rate?: number | null
        }
        Update: {
          computed_at?: string
          dispute_rate?: number | null
          jobs_completed?: number
          on_time_rate?: number | null
          org_id?: string
          plan_followed_rate?: number | null
          quality_score?: number | null
          repeat_client_rate?: number | null
          right_first_time_rate?: number | null
          standards_met_rate?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "vendor_scores_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: true
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      verification_claims: {
        Row: {
          created_at: string
          evidence_path: string | null
          id: string
          kind: Database["public"]["Enums"]["claim_kind"]
          notes: string | null
          org_id: string
          reference: string | null
          status: Database["public"]["Enums"]["claim_status"]
          subject_user_id: string | null
          valid_until: string | null
          verified_at: string | null
          verified_by: string | null
        }
        Insert: {
          created_at?: string
          evidence_path?: string | null
          id?: string
          kind: Database["public"]["Enums"]["claim_kind"]
          notes?: string | null
          org_id: string
          reference?: string | null
          status?: Database["public"]["Enums"]["claim_status"]
          subject_user_id?: string | null
          valid_until?: string | null
          verified_at?: string | null
          verified_by?: string | null
        }
        Update: {
          created_at?: string
          evidence_path?: string | null
          id?: string
          kind?: Database["public"]["Enums"]["claim_kind"]
          notes?: string | null
          org_id?: string
          reference?: string | null
          status?: Database["public"]["Enums"]["claim_status"]
          subject_user_id?: string | null
          valid_until?: string | null
          verified_at?: string | null
          verified_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "verification_claims_org_id_fkey"
            columns: ["org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      wiix_screens: {
        Row: {
          capability: number | null
          commute_tolerance: number | null
          reliability: number | null
          screened_at: string
          shift_fit: number | null
          wiix_score: number
          worker_id: string
        }
        Insert: {
          capability?: number | null
          commute_tolerance?: number | null
          reliability?: number | null
          screened_at?: string
          shift_fit?: number | null
          wiix_score: number
          worker_id: string
        }
        Update: {
          capability?: number | null
          commute_tolerance?: number | null
          reliability?: number | null
          screened_at?: string
          shift_fit?: number | null
          wiix_score?: number
          worker_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "wiix_screens_worker_id_fkey"
            columns: ["worker_id"]
            isOneToOne: true
            referencedRelation: "workers"
            referencedColumns: ["id"]
          },
        ]
      }
      work_plan_templates: {
        Row: {
          created_at: string
          description: string | null
          id: string
          legend: Json
          name: string
          plan: Json
          segment: string | null
          vendor_org_id: string | null
        }
        Insert: {
          created_at?: string
          description?: string | null
          id?: string
          legend: Json
          name: string
          plan: Json
          segment?: string | null
          vendor_org_id?: string | null
        }
        Update: {
          created_at?: string
          description?: string | null
          id?: string
          legend?: Json
          name?: string
          plan?: Json
          segment?: string | null
          vendor_org_id?: string | null
        }
        Relationships: []
      }
      work_schedules: {
        Row: {
          brief_id: string
          created_at: string
          created_by: string | null
          id: string
          legend: Json
          locked_at: string | null
          plan: Json
          quote_id: string
          status: string
          submitted_at: string | null
          updated_at: string
          vendor_org_id: string
        }
        Insert: {
          brief_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          legend: Json
          locked_at?: string | null
          plan: Json
          quote_id: string
          status?: string
          submitted_at?: string | null
          updated_at?: string
          vendor_org_id?: string
        }
        Update: {
          brief_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          legend?: Json
          locked_at?: string | null
          plan?: Json
          quote_id?: string
          status?: string
          submitted_at?: string | null
          updated_at?: string
          vendor_org_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_schedules_brief_id_fkey"
            columns: ["brief_id"]
            isOneToOne: false
            referencedRelation: "briefs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_schedules_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: true
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_schedules_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
      workers: {
        Row: {
          available_early: boolean
          available_evening: boolean
          created_at: string
          dbs_cleared: boolean
          full_name: string
          home_town_id: number | null
          id: string
          max_commute_km: number
          phone: string | null
          user_id: string | null
          vendor_org_id: string | null
        }
        Insert: {
          available_early?: boolean
          available_evening?: boolean
          created_at?: string
          dbs_cleared?: boolean
          full_name: string
          home_town_id?: number | null
          id?: string
          max_commute_km?: number
          phone?: string | null
          user_id?: string | null
          vendor_org_id?: string | null
        }
        Update: {
          available_early?: boolean
          available_evening?: boolean
          created_at?: string
          dbs_cleared?: boolean
          full_name?: string
          home_town_id?: number | null
          id?: string
          max_commute_km?: number
          phone?: string | null
          user_id?: string | null
          vendor_org_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "workers_home_town_id_fkey"
            columns: ["home_town_id"]
            isOneToOne: false
            referencedRelation: "towns"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "workers_vendor_org_id_fkey"
            columns: ["vendor_org_id"]
            isOneToOne: false
            referencedRelation: "organisations"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      platform_operations: {
        Args: { p_from: string; p_to: string }
        Returns: {
          avg_late_minutes: number
          complaints_per_100: number
          first_time_right_rate: number
          on_time_rate: number
          open_issues: number
          photos_on_site_rate: number
          plan_followed_rate: number
          sla_breaches: number
          time_vs_plan: number
          vendor_name: string
          vendor_org_id: string
          visits: number
        }[]
      }
      vendor_operations: {
        Args: { p_vendor: string; p_from: string; p_to: string }
        Returns: {
          avg_hours_to_resolve: number
          avg_late_minutes: number
          avg_on_site_minutes: number
          avg_planned_minutes: number
          complaints_per_100: number
          first_time_right_rate: number
          on_time_rate: number
          open_issues: number
          photos_on_site_rate: number
          plan_followed_rate: number
          sla_breaches: number
          time_vs_plan: number
          visits: number
        }[]
      }
      vendor_problem_areas: {
        Args: { p_vendor: string; p_from: string; p_to: string }
        Returns: {
          area: string
          complaints: number
          last_reported: string
        }[]
      }
      vendor_visits: {
        Args: { p_vendor: string; p_from: string; p_to: string }
        Returns: {
          complaints: number
          first_time_right: boolean
          job_id: string
          late_minutes: number
          on_site_minutes: number
          on_time: boolean
          planned_areas: number
          planned_minutes: number
          scheduled_start: string
          site_name: string
          status: string
          ticked_areas: number
        }[]
      }
      visit_area_times: {
        Args: { p_job: string }
        Returns: {
          done_at: string
          group_name: string
          item_id: string
          item_name: string
          method: string
          minutes_since_previous: number
          planned_minutes: number
          sequence_no: number
        }[]
      }
      visit_measures: {
        Args: { p_job: string }
        Returns: {
          accepted_at: string
          checked_in_at: string
          completed_at: string
          complaints: number
          first_time_right: boolean
          hours_to_accept: number
          job_id: string
          late_minutes: number
          on_site_minutes: number
          on_time: boolean
          photos: number
          photos_on_site: number
          planned_areas: number
          planned_minutes: number
          scheduled_start: string
          status: string
          tolerance_minutes: number
          ticked_areas: number
          uses_plan: boolean
          vendor_org_id: string
        }[]
      }
      admin_case_timeline: {
        Args: { p_brief?: string; p_job?: string; p_limit?: number; p_org?: string }
        Returns: {
          actor_email: string
          actor_id: string
          actor_name: string
          at: string
          brief_id: string
          changes: Json
          job_id: string
          kind: string
          lat: number
          lng: number
          op: string
          org_ids: string[]
          quote_id: string
          source: string
          summary: string
          table_name: string
          within_geofence: boolean
        }[]
      }
      accept_quote: {
        Args: { p_quote: string; p_start: string }
        Returns: string
      }
      add_member: {
        Args: {
          p_email: string
          p_org: string
          p_role: Database["public"]["Enums"]["member_role"]
        }
        Returns: string
      }
      approve_brief_draft: {
        Args: {
          p_draft: Json
          p_item: string
          p_site?: string
          p_site_lat?: number
          p_site_lng?: number
        }
        Returns: string
      }
      approve_job: { Args: { p_job: string }; Returns: undefined }
      check_in: {
        Args: { p_job: string; p_lat: number; p_lng: number }
        Returns: Json
      }
      commute_band: {
        Args: { km: number }
        Returns: {
          band: string
          note: string
          paid_minutes: number
        }[]
      }
      complete_job: {
        Args: { p_job: string; p_lat?: number; p_lng?: number }
        Returns: undefined
      }
      corridor_suggestions: {
        Args: never
        Returns: {
          band: string
          deficit: number
          from_town: string
          km: number
          paid_minutes: number
          surplus_avail: number
          to_town: string
        }[]
      }
      create_buyer_org: {
        Args: { p_name: string; p_segment: string }
        Returns: string
      }
      decline_quote: { Args: { p_quote: string }; Returns: undefined }
      demand_by_town: {
        Args: never
        Returns: {
          balance: number
          open_shifts: number
          status: string
          town: string
          workers: number
        }[]
      }
      haversine_km: {
        Args: { lat1: number; lat2: number; lon1: number; lon2: number }
        Returns: number
      }
      job_plan_day: {
        Args: { p_job: string }
        Returns: string
      }
      mark_notifications_read: {
        Args: { p_ids?: string[] }
        Returns: number
      }
      mark_payment_paid: {
        Args: { p_payment: string; p_reference: string }
        Returns: undefined
      }
      offer_shift: {
        Args: { p_shift: string; p_worker: string }
        Returns: undefined
      }
      org_member_emails: {
        Args: { p_org: string }
        Returns: {
          email: string
          full_name: string
          role: Database["public"]["Enums"]["member_role"]
          user_id: string
        }[]
      }
      price_quote: {
        Args: {
          p_brief: string
          p_urgency?: string
          p_vendor: string
          p_version: number
        }
        Returns: Json
      }
      rank_candidates: {
        Args: { p_shift_id: string }
        Returns: {
          band: string
          cross_town: boolean
          full_name: string
          home_town: string
          km: number
          note: string
          paid_minutes: number
          rank_score: number
          wiix_score: number
          worker_id: string
        }[]
      }
      rank_vendors: {
        Args: { p_site: string }
        Returns: {
          hourly_rate: number
          km: number
          name: string
          org_id: string
          quality_score: number
          rank: number
          verification_tier: number
        }[]
      }
      reject_brief_draft: {
        Args: { p_item: string; p_reason?: string }
        Returns: undefined
      }
      respond_to_shift: {
        Args: { p_accept: boolean; p_shift: string }
        Returns: undefined
      }
      schedule_visits: {
        Args: { p_contract: string; p_weeks?: number }
        Returns: number
      }
      submit_quote: {
        Args: { p_quote: string; p_valid_days?: number }
        Returns: Json
      }
      worker_claim_notification_emails: {
        Args: { p_limit?: number }
        Returns: {
          body: string
          category: string
          created_at: string
          email: string
          id: string
          link: string
          title: string
        }[]
      }
      worker_finish_notification_email: {
        Args: { p_error?: string; p_id: string; p_sent: boolean }
        Returns: undefined
      }
    }
    Enums: {
      approval_status: "pending" | "approved" | "rejected"
      brief_status: "draft" | "locked" | "archived"
      claim_kind:
        | "companies_house"
        | "public_liability_insurance"
        | "dbs"
        | "right_to_work"
        | "iso_9001"
        | "chas"
        | "safecontractor"
        | "other"
      claim_status:
        | "self_declared"
        | "pending"
        | "verified"
        | "rejected"
        | "expired"
      contract_status: "draft" | "active" | "paused" | "ended"
      dbs_certificate_type: "basic" | "standard" | "enhanced"
      dbs_path: "new_check" | "existing_certificate"
      dbs_status:
        | "submitted_by_worker"
        | "sent_to_ucheck"
        | "cleared"
        | "not_cleared"
        | "withdrawn"
      evidence_kind: "photo_before" | "photo_after" | "robot_log" | "other"
      issue_kind:
        | "quality"
        | "damage"
        | "conduct"
        | "no_show"
        | "access"
        | "safeguarding"
        | "other"
      issue_status:
        | "open"
        | "vendor_fix"
        | "partial_refund"
        | "mediation"
        | "resolved"
      job_status:
        | "requested"
        | "matched"
        | "en_route"
        | "on_site"
        | "in_progress"
        | "completed"
        | "quality_verified"
        | "paid"
        | "cancelled"
        | "disputed"
      member_role:
        | "owner"
        | "approver"
        | "viewer"
        | "vendor_admin"
        | "dispatcher"
        | "operative"
        | "platform_admin"
      org_kind: "buyer" | "vendor" | "platform"
      payment_kind:
        | "escrow_hold"
        | "release"
        | "refund"
        | "payout"
        | "direct_debit"
        | "service_credit"
        | "platform_fee"
        | "invoice"
      quote_status:
        | "invited"
        | "submitted"
        | "accepted"
        | "declined"
        | "expired"
        | "withdrawn"
      shift_status:
        | "open"
        | "offered"
        | "filled"
        | "completed"
        | "cancelled"
        | "no_show"
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
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
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
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
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      approval_status: ["pending", "approved", "rejected"],
      brief_status: ["draft", "locked", "archived"],
      claim_kind: [
        "companies_house",
        "public_liability_insurance",
        "dbs",
        "right_to_work",
        "iso_9001",
        "chas",
        "safecontractor",
        "other",
      ],
      claim_status: [
        "self_declared",
        "pending",
        "verified",
        "rejected",
        "expired",
      ],
      contract_status: ["draft", "active", "paused", "ended"],
      dbs_certificate_type: ["basic", "standard", "enhanced"],
      dbs_path: ["new_check", "existing_certificate"],
      dbs_status: [
        "submitted_by_worker",
        "sent_to_ucheck",
        "cleared",
        "not_cleared",
        "withdrawn",
      ],
      evidence_kind: ["photo_before", "photo_after", "robot_log", "other"],
      issue_kind: [
        "quality",
        "damage",
        "conduct",
        "no_show",
        "access",
        "safeguarding",
        "other",
      ],
      issue_status: [
        "open",
        "vendor_fix",
        "partial_refund",
        "mediation",
        "resolved",
      ],
      job_status: [
        "requested",
        "matched",
        "en_route",
        "on_site",
        "in_progress",
        "completed",
        "quality_verified",
        "paid",
        "cancelled",
        "disputed",
      ],
      member_role: [
        "owner",
        "approver",
        "viewer",
        "vendor_admin",
        "dispatcher",
        "operative",
        "platform_admin",
      ],
      org_kind: ["buyer", "vendor", "platform"],
      payment_kind: [
        "escrow_hold",
        "release",
        "refund",
        "payout",
        "direct_debit",
        "service_credit",
        "platform_fee",
        "invoice",
      ],
      quote_status: [
        "invited",
        "submitted",
        "accepted",
        "declined",
        "expired",
        "withdrawn",
      ],
      shift_status: [
        "open",
        "offered",
        "filled",
        "completed",
        "cancelled",
        "no_show",
      ],
    },
  },
} as const
