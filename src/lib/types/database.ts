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
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      audit_log: {
        Row: {
          action: string
          actor_operator_id: string | null
          actor_role: string
          actor_shipper_user_id: string | null
          actor_staff_id: string | null
          after_json: Json | null
          before_json: Json | null
          created_at: string
          id: string
          ip_address: unknown
          reason_code: string | null
          record_id: string
          subject_importer_id: string | null
          subject_shipper_id: string | null
          table_name: string
          timestamp: string
          user_agent: string | null
        }
        Insert: {
          action: string
          actor_operator_id?: string | null
          actor_role: string
          actor_shipper_user_id?: string | null
          actor_staff_id?: string | null
          after_json?: Json | null
          before_json?: Json | null
          created_at?: string
          id?: string
          ip_address?: unknown
          reason_code?: string | null
          record_id: string
          subject_importer_id?: string | null
          subject_shipper_id?: string | null
          table_name: string
          timestamp?: string
          user_agent?: string | null
        }
        Update: {
          action?: string
          actor_operator_id?: string | null
          actor_role?: string
          actor_shipper_user_id?: string | null
          actor_staff_id?: string | null
          after_json?: Json | null
          before_json?: Json | null
          created_at?: string
          id?: string
          ip_address?: unknown
          reason_code?: string | null
          record_id?: string
          subject_importer_id?: string | null
          subject_shipper_id?: string | null
          table_name?: string
          timestamp?: string
          user_agent?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_log_actor_operator_id_fkey"
            columns: ["actor_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_actor_shipper_user_id_fkey"
            columns: ["actor_shipper_user_id"]
            isOneToOne: false
            referencedRelation: "shipper_users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_actor_staff_id_fkey"
            columns: ["actor_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_subject_importer_id_fkey"
            columns: ["subject_importer_id"]
            isOneToOne: false
            referencedRelation: "importer_balance_vw"
            referencedColumns: ["importer_id"]
          },
          {
            foreignKeyName: "audit_log_subject_importer_id_fkey"
            columns: ["subject_importer_id"]
            isOneToOne: false
            referencedRelation: "importers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_log_subject_shipper_id_fkey"
            columns: ["subject_shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      countries: {
        Row: {
          active: boolean
          currency_id: string
          id: string
          iso_code: string
          name: string
        }
        Insert: {
          active?: boolean
          currency_id: string
          id?: string
          iso_code: string
          name: string
        }
        Update: {
          active?: boolean
          currency_id?: string
          id?: string
          iso_code?: string
          name?: string
        }
        Relationships: [
          {
            foreignKeyName: "countries_currency_id_fkey"
            columns: ["currency_id"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["id"]
          },
        ]
      }
      couriers: {
        Row: {
          active: boolean
          added_by_staff_id: string | null
          created_at: string
          id: string
          name: string
          tracking_url_template: string | null
        }
        Insert: {
          active?: boolean
          added_by_staff_id?: string | null
          created_at?: string
          id?: string
          name: string
          tracking_url_template?: string | null
        }
        Update: {
          active?: boolean
          added_by_staff_id?: string | null
          created_at?: string
          id?: string
          name?: string
          tracking_url_template?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "couriers_added_by_staff_id_fkey"
            columns: ["added_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      currencies: {
        Row: {
          active: boolean
          code: string
          id: string
          symbol: string | null
        }
        Insert: {
          active?: boolean
          code: string
          id?: string
          symbol?: string | null
        }
        Update: {
          active?: boolean
          code?: string
          id?: string
          symbol?: string | null
        }
        Relationships: []
      }
      dispute_images: {
        Row: {
          dispute_id: string
          id: string
          image_url: string
          uploaded_at: string
          uploaded_by_operator_id: string
        }
        Insert: {
          dispute_id: string
          id?: string
          image_url: string
          uploaded_at?: string
          uploaded_by_operator_id: string
        }
        Update: {
          dispute_id?: string
          id?: string
          image_url?: string
          uploaded_at?: string
          uploaded_by_operator_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "dispute_images_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dispute_images_uploaded_by_operator_id_fkey"
            columns: ["uploaded_by_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      dispute_lines: {
        Row: {
          amount_impact_gbp: number
          created_at: string
          dispute_id: string
          id: string
          line_status: string
          qty_impact: number
          resolution_method: string | null
          resolved_at: string | null
          resolved_via_child_order_id: string | null
          supplier_invoice_line_id: string
        }
        Insert: {
          amount_impact_gbp: number
          created_at?: string
          dispute_id: string
          id?: string
          line_status: string
          qty_impact: number
          resolution_method?: string | null
          resolved_at?: string | null
          resolved_via_child_order_id?: string | null
          supplier_invoice_line_id: string
        }
        Update: {
          amount_impact_gbp?: number
          created_at?: string
          dispute_id?: string
          id?: string
          line_status?: string
          qty_impact?: number
          resolution_method?: string | null
          resolved_at?: string | null
          resolved_via_child_order_id?: string | null
          supplier_invoice_line_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "dispute_lines_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dispute_lines_resolved_via_child_order_id_fkey"
            columns: ["resolved_via_child_order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "dispute_lines_resolved_via_child_order_id_fkey"
            columns: ["resolved_via_child_order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dispute_lines_supplier_invoice_line_id_fkey"
            columns: ["supplier_invoice_line_id"]
            isOneToOne: false
            referencedRelation: "supplier_invoice_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      dispute_messages: {
        Row: {
          body: string
          counterparty: string
          created_at: string
          dispute_id: string
          generated_by: string
          id: string
          message_type: string
          sent_at: string | null
          sop_version_applied: string | null
          subject: string | null
        }
        Insert: {
          body: string
          counterparty: string
          created_at?: string
          dispute_id: string
          generated_by: string
          id?: string
          message_type: string
          sent_at?: string | null
          sop_version_applied?: string | null
          subject?: string | null
        }
        Update: {
          body?: string
          counterparty?: string
          created_at?: string
          dispute_id?: string
          generated_by?: string
          id?: string
          message_type?: string
          sent_at?: string | null
          sop_version_applied?: string | null
          subject?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "dispute_messages_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
        ]
      }
      dispute_notes: {
        Row: {
          author_id: string
          author_type: string
          created_at: string
          dispute_id: string
          id: string
          note_text: string
        }
        Insert: {
          author_id: string
          author_type: string
          created_at?: string
          dispute_id: string
          id?: string
          note_text: string
        }
        Update: {
          author_id?: string
          author_type?: string
          created_at?: string
          dispute_id?: string
          id?: string
          note_text?: string
        }
        Relationships: [
          {
            foreignKeyName: "dispute_notes_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
        ]
      }
      disputes: {
        Row: {
          amount_impact_gbp: number
          comments_initial: string | null
          customer_credit_note_sales_invoice_id: string | null
          desired_outcome: string
          id: string
          issue_type: string
          liable_party: string
          order_id: string
          raised_at: string
          raised_by_operator_id: string
          refund_approved_at: string | null
          refund_approved_by_staff_id: string | null
          refund_settlement_mode: string | null
          replacement_child_order_id: string | null
          resolved_at: string | null
          reviewed_at: string | null
          reviewed_by_staff_id: string | null
          sop_version: string
          stage_detected: string
          status: string
        }
        Insert: {
          amount_impact_gbp: number
          comments_initial?: string | null
          customer_credit_note_sales_invoice_id?: string | null
          desired_outcome: string
          id?: string
          issue_type: string
          liable_party?: string
          order_id: string
          raised_at?: string
          raised_by_operator_id: string
          refund_approved_at?: string | null
          refund_approved_by_staff_id?: string | null
          refund_settlement_mode?: string | null
          replacement_child_order_id?: string | null
          resolved_at?: string | null
          reviewed_at?: string | null
          reviewed_by_staff_id?: string | null
          sop_version: string
          stage_detected: string
          status?: string
        }
        Update: {
          amount_impact_gbp?: number
          comments_initial?: string | null
          customer_credit_note_sales_invoice_id?: string | null
          desired_outcome?: string
          id?: string
          issue_type?: string
          liable_party?: string
          order_id?: string
          raised_at?: string
          raised_by_operator_id?: string
          refund_approved_at?: string | null
          refund_approved_by_staff_id?: string | null
          refund_settlement_mode?: string | null
          replacement_child_order_id?: string | null
          resolved_at?: string | null
          reviewed_at?: string | null
          reviewed_by_staff_id?: string | null
          sop_version?: string
          stage_detected?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "disputes_customer_credit_note_sales_invoice_id_fkey"
            columns: ["customer_credit_note_sales_invoice_id"]
            isOneToOne: false
            referencedRelation: "sales_invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "disputes_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "disputes_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "disputes_raised_by_operator_id_fkey"
            columns: ["raised_by_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "disputes_refund_approved_by_staff_id_fkey"
            columns: ["refund_approved_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "disputes_replacement_child_order_id_fkey"
            columns: ["replacement_child_order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "disputes_replacement_child_order_id_fkey"
            columns: ["replacement_child_order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "disputes_reviewed_by_staff_id_fkey"
            columns: ["reviewed_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      dva_reconciliation: {
        Row: {
          dispute_id: string | null
          dva_statement_line_id: string
          fx_diff_gbp: number | null
          fx_diff_posted_to_sage_at: string | null
          id: string
          notes: string | null
          order_id: string | null
          reconciled_at: string
          reconciled_by_staff_id: string
          reconciled_gbp_amount: number
          reconciliation_type: string
          sage_fx_journal_ref: string | null
          supplier_invoice_id: string | null
        }
        Insert: {
          dispute_id?: string | null
          dva_statement_line_id: string
          fx_diff_gbp?: number | null
          fx_diff_posted_to_sage_at?: string | null
          id?: string
          notes?: string | null
          order_id?: string | null
          reconciled_at?: string
          reconciled_by_staff_id: string
          reconciled_gbp_amount: number
          reconciliation_type: string
          sage_fx_journal_ref?: string | null
          supplier_invoice_id?: string | null
        }
        Update: {
          dispute_id?: string | null
          dva_statement_line_id?: string
          fx_diff_gbp?: number | null
          fx_diff_posted_to_sage_at?: string | null
          id?: string
          notes?: string | null
          order_id?: string | null
          reconciled_at?: string
          reconciled_by_staff_id?: string
          reconciled_gbp_amount?: number
          reconciliation_type?: string
          sage_fx_journal_ref?: string | null
          supplier_invoice_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "dva_reconciliation_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dva_reconciliation_dva_statement_line_id_fkey"
            columns: ["dva_statement_line_id"]
            isOneToOne: true
            referencedRelation: "dva_statement_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dva_reconciliation_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "dva_reconciliation_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dva_reconciliation_reconciled_by_staff_id_fkey"
            columns: ["reconciled_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dva_reconciliation_supplier_invoice_id_fkey"
            columns: ["supplier_invoice_id"]
            isOneToOne: false
            referencedRelation: "supplier_invoices"
            referencedColumns: ["id"]
          },
        ]
      }
      dva_statement_lines: {
        Row: {
          amount_gbp_equivalent: number
          amount_local_ccy: number
          auth_id_ref: string | null
          card_markup_pct_applied: number
          created_at: string
          direction: string
          dva_statement_id: string
          fx_rate_applied: number
          id: string
          line_order: number
          local_ccy: string
          match_status: string
          reference_raw: string
          retailer_name_ref: string | null
          statement_date: string
        }
        Insert: {
          amount_gbp_equivalent: number
          amount_local_ccy: number
          auth_id_ref?: string | null
          card_markup_pct_applied: number
          created_at?: string
          direction: string
          dva_statement_id: string
          fx_rate_applied: number
          id?: string
          line_order: number
          local_ccy: string
          match_status?: string
          reference_raw: string
          retailer_name_ref?: string | null
          statement_date: string
        }
        Update: {
          amount_gbp_equivalent?: number
          amount_local_ccy?: number
          auth_id_ref?: string | null
          card_markup_pct_applied?: number
          created_at?: string
          direction?: string
          dva_statement_id?: string
          fx_rate_applied?: number
          id?: string
          line_order?: number
          local_ccy?: string
          match_status?: string
          reference_raw?: string
          retailer_name_ref?: string | null
          statement_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "dva_statement_lines_dva_statement_id_fkey"
            columns: ["dva_statement_id"]
            isOneToOne: false
            referencedRelation: "dva_statements"
            referencedColumns: ["id"]
          },
        ]
      }
      dva_statements: {
        Row: {
          csv_url: string
          id: string
          importer_id: string
          parse_errors_json: Json | null
          parse_status: string
          source_bank: string
          statement_period_from: string
          statement_period_to: string
          uploaded_at: string
          uploaded_by_staff_id: string
        }
        Insert: {
          csv_url: string
          id?: string
          importer_id: string
          parse_errors_json?: Json | null
          parse_status?: string
          source_bank: string
          statement_period_from: string
          statement_period_to: string
          uploaded_at?: string
          uploaded_by_staff_id: string
        }
        Update: {
          csv_url?: string
          id?: string
          importer_id?: string
          parse_errors_json?: Json | null
          parse_status?: string
          source_bank?: string
          statement_period_from?: string
          statement_period_to?: string
          uploaded_at?: string
          uploaded_by_staff_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "dva_statements_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importer_balance_vw"
            referencedColumns: ["importer_id"]
          },
          {
            foreignKeyName: "dva_statements_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dva_statements_uploaded_by_staff_id_fkey"
            columns: ["uploaded_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      fx_rates: {
        Row: {
          country_id: string
          created_at: string
          entered_by_staff_id: string
          id: string
          quote_card_markup_pct: number
          quote_rate: number
          rate_date: string
          settlement_card_markup_pct: number
          settlement_rate: number
        }
        Insert: {
          country_id: string
          created_at?: string
          entered_by_staff_id: string
          id?: string
          quote_card_markup_pct: number
          quote_rate: number
          rate_date: string
          settlement_card_markup_pct: number
          settlement_rate: number
        }
        Update: {
          country_id?: string
          created_at?: string
          entered_by_staff_id?: string
          id?: string
          quote_card_markup_pct?: number
          quote_rate?: number
          rate_date?: string
          settlement_card_markup_pct?: number
          settlement_rate?: number
        }
        Relationships: [
          {
            foreignKeyName: "fx_rates_country_id_fkey"
            columns: ["country_id"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fx_rates_entered_by_staff_id_fkey"
            columns: ["entered_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      hubs: {
        Row: {
          active: boolean
          country_id: string
          created_at: string
          full_address: string
          id: string
          name: string
          postcode: string | null
          receiving_contact_name: string | null
          receiving_contact_phone: string | null
          shipper_id: string | null
        }
        Insert: {
          active?: boolean
          country_id: string
          created_at?: string
          full_address: string
          id?: string
          name: string
          postcode?: string | null
          receiving_contact_name?: string | null
          receiving_contact_phone?: string | null
          shipper_id?: string | null
        }
        Update: {
          active?: boolean
          country_id?: string
          created_at?: string
          full_address?: string
          id?: string
          name?: string
          postcode?: string | null
          receiving_contact_name?: string | null
          receiving_contact_phone?: string | null
          shipper_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "hubs_country_id_fkey"
            columns: ["country_id"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "hubs_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      importer_credit_ledger: {
        Row: {
          amount_gbp: number
          amount_local_ccy: number
          created_at: string
          created_by_staff_id: string | null
          direction: string
          effective_at: string
          entry_type: string
          id: string
          importer_id: string
          linked_dispute_id: string | null
          linked_order_id: string | null
          local_ccy: string
          notes: string | null
          source_id: string
          source_table: string
        }
        Insert: {
          amount_gbp: number
          amount_local_ccy: number
          created_at?: string
          created_by_staff_id?: string | null
          direction: string
          effective_at: string
          entry_type: string
          id?: string
          importer_id: string
          linked_dispute_id?: string | null
          linked_order_id?: string | null
          local_ccy: string
          notes?: string | null
          source_id: string
          source_table: string
        }
        Update: {
          amount_gbp?: number
          amount_local_ccy?: number
          created_at?: string
          created_by_staff_id?: string | null
          direction?: string
          effective_at?: string
          entry_type?: string
          id?: string
          importer_id?: string
          linked_dispute_id?: string | null
          linked_order_id?: string | null
          local_ccy?: string
          notes?: string | null
          source_id?: string
          source_table?: string
        }
        Relationships: [
          {
            foreignKeyName: "importer_credit_ledger_created_by_staff_id_fkey"
            columns: ["created_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "importer_credit_ledger_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importer_balance_vw"
            referencedColumns: ["importer_id"]
          },
          {
            foreignKeyName: "importer_credit_ledger_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "importer_credit_ledger_linked_dispute_id_fkey"
            columns: ["linked_dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "importer_credit_ledger_linked_order_id_fkey"
            columns: ["linked_order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "importer_credit_ledger_linked_order_id_fkey"
            columns: ["linked_order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
        ]
      }
      importers: {
        Row: {
          active: boolean
          address: string | null
          company_name: string
          country_id: string
          created_at: string
          dva_card_last_4: string | null
          gcb_dva_ref: string | null
          id: string
          onboarded_via_signup_token_id: string | null
          sage_customer_code: string | null
          shipper_id: string
          trading_name: string | null
        }
        Insert: {
          active?: boolean
          address?: string | null
          company_name: string
          country_id: string
          created_at?: string
          dva_card_last_4?: string | null
          gcb_dva_ref?: string | null
          id?: string
          onboarded_via_signup_token_id?: string | null
          sage_customer_code?: string | null
          shipper_id: string
          trading_name?: string | null
        }
        Update: {
          active?: boolean
          address?: string | null
          company_name?: string
          country_id?: string
          created_at?: string
          dva_card_last_4?: string | null
          gcb_dva_ref?: string | null
          id?: string
          onboarded_via_signup_token_id?: string | null
          sage_customer_code?: string | null
          shipper_id?: string
          trading_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "importers_country_id_fkey"
            columns: ["country_id"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "importers_onboarded_via_signup_token_id_fkey"
            columns: ["onboarded_via_signup_token_id"]
            isOneToOne: false
            referencedRelation: "signup_tokens"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "importers_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      installation: {
        Row: {
          active_shipper_id: string | null
          created_at: string
          default_tenant_branding_id: string | null
          deployment_mode: string
          id: string
          markup_enabled_global: boolean
          netp_status: boolean
          platform_name_override: string | null
          uk_vat_number: string | null
          updated_at: string
          vat_return_frequency: string | null
        }
        Insert: {
          active_shipper_id?: string | null
          created_at?: string
          default_tenant_branding_id?: string | null
          deployment_mode: string
          id?: string
          markup_enabled_global?: boolean
          netp_status?: boolean
          platform_name_override?: string | null
          uk_vat_number?: string | null
          updated_at?: string
          vat_return_frequency?: string | null
        }
        Update: {
          active_shipper_id?: string | null
          created_at?: string
          default_tenant_branding_id?: string | null
          deployment_mode?: string
          id?: string
          markup_enabled_global?: boolean
          netp_status?: boolean
          platform_name_override?: string | null
          uk_vat_number?: string | null
          updated_at?: string
          vat_return_frequency?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "installation_active_shipper_id_fkey"
            columns: ["active_shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "installation_default_tenant_branding_id_fkey"
            columns: ["default_tenant_branding_id"]
            isOneToOne: false
            referencedRelation: "shipper_branding"
            referencedColumns: ["id"]
          },
        ]
      }
      markup_categories: {
        Row: {
          active: boolean
          category_name: string
          created_at: string
          default_markup_pct: number
          id: string
          shipper_id: string | null
        }
        Insert: {
          active?: boolean
          category_name: string
          created_at?: string
          default_markup_pct: number
          id?: string
          shipper_id?: string | null
        }
        Update: {
          active?: boolean
          category_name?: string
          created_at?: string
          default_markup_pct?: number
          id?: string
          shipper_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "markup_categories_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      match_suggestions: {
        Row: {
          accepted_at: string | null
          accepted_by_staff_id: string | null
          confidence: string
          dva_statement_line_id: string
          id: string
          rejected_reason: string | null
          suggested_match_id: string
          suggested_match_type: string
          variance_days: number | null
          variance_gbp: number | null
        }
        Insert: {
          accepted_at?: string | null
          accepted_by_staff_id?: string | null
          confidence: string
          dva_statement_line_id: string
          id?: string
          rejected_reason?: string | null
          suggested_match_id: string
          suggested_match_type: string
          variance_days?: number | null
          variance_gbp?: number | null
        }
        Update: {
          accepted_at?: string | null
          accepted_by_staff_id?: string | null
          confidence?: string
          dva_statement_line_id?: string
          id?: string
          rejected_reason?: string | null
          suggested_match_id?: string
          suggested_match_type?: string
          variance_days?: number | null
          variance_gbp?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "match_suggestions_accepted_by_staff_id_fkey"
            columns: ["accepted_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "match_suggestions_dva_statement_line_id_fkey"
            columns: ["dva_statement_line_id"]
            isOneToOne: false
            referencedRelation: "dva_statement_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      operator_importers: {
        Row: {
          granted_at: string
          id: string
          importer_id: string
          operator_id: string
          relationship_type: string
          revoked_at: string | null
        }
        Insert: {
          granted_at?: string
          id?: string
          importer_id: string
          operator_id: string
          relationship_type: string
          revoked_at?: string | null
        }
        Update: {
          granted_at?: string
          id?: string
          importer_id?: string
          operator_id?: string
          relationship_type?: string
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "operator_importers_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importer_balance_vw"
            referencedColumns: ["importer_id"]
          },
          {
            foreignKeyName: "operator_importers_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "operator_importers_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      operators: {
        Row: {
          active: boolean
          auth_user_id: string | null
          created_at: string
          email: string
          full_name: string
          id: string
          last_login_at: string | null
          phone: string | null
        }
        Insert: {
          active?: boolean
          auth_user_id?: string | null
          created_at?: string
          email: string
          full_name: string
          id?: string
          last_login_at?: string | null
          phone?: string | null
        }
        Update: {
          active?: boolean
          auth_user_id?: string | null
          created_at?: string
          email?: string
          full_name?: string
          id?: string
          last_login_at?: string | null
          phone?: string | null
        }
        Relationships: []
      }
      order_category_lines: {
        Row: {
          amount_inc_vat_gbp: number
          created_at: string
          id: string
          markup_category_id: string
          markup_gbp_calculated: number
          markup_pct_applied: number
          order_id: string
          qty: number
        }
        Insert: {
          amount_inc_vat_gbp: number
          created_at?: string
          id?: string
          markup_category_id: string
          markup_gbp_calculated: number
          markup_pct_applied: number
          order_id: string
          qty: number
        }
        Update: {
          amount_inc_vat_gbp?: number
          created_at?: string
          id?: string
          markup_category_id?: string
          markup_gbp_calculated?: number
          markup_pct_applied?: number
          order_id?: string
          qty?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_category_lines_markup_category_id_fkey"
            columns: ["markup_category_id"]
            isOneToOne: false
            referencedRelation: "markup_categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_category_lines_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "order_category_lines_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
        ]
      }
      orders: {
        Row: {
          actual_shipping_gbp: number | null
          bundled_final_gbp: number | null
          bundled_quote_gbp: number | null
          completed_at: string | null
          content_locked_at: string | null
          created_at: string
          destination_hub_id: string
          estimated_shipping_gbp: number | null
          funded_at: string | null
          id: string
          importer_id: string
          markup_applied_gbp: number | null
          operator_id: string
          order_ref: string
          order_total_gbp_declared: number
          order_total_gbp_reconciled: number | null
          order_type: string
          parent_order_id: string | null
          payment_auth_id: string | null
          quote_card_markup_pct: number | null
          quote_fx_rate: number | null
          quote_total_ghs: number | null
          retailer_id: string
          screenshot_url: string | null
          shipper_id: string
          sop_version: string
          status: string
          total_qty_declared: number
          tracking_locked_at: string | null
          updated_at: string
        }
        Insert: {
          actual_shipping_gbp?: number | null
          bundled_final_gbp?: number | null
          bundled_quote_gbp?: number | null
          completed_at?: string | null
          content_locked_at?: string | null
          created_at?: string
          destination_hub_id: string
          estimated_shipping_gbp?: number | null
          funded_at?: string | null
          id?: string
          importer_id: string
          markup_applied_gbp?: number | null
          operator_id: string
          order_ref: string
          order_total_gbp_declared: number
          order_total_gbp_reconciled?: number | null
          order_type?: string
          parent_order_id?: string | null
          payment_auth_id?: string | null
          quote_card_markup_pct?: number | null
          quote_fx_rate?: number | null
          quote_total_ghs?: number | null
          retailer_id: string
          screenshot_url?: string | null
          shipper_id: string
          sop_version: string
          status?: string
          total_qty_declared: number
          tracking_locked_at?: string | null
          updated_at?: string
        }
        Update: {
          actual_shipping_gbp?: number | null
          bundled_final_gbp?: number | null
          bundled_quote_gbp?: number | null
          completed_at?: string | null
          content_locked_at?: string | null
          created_at?: string
          destination_hub_id?: string
          estimated_shipping_gbp?: number | null
          funded_at?: string | null
          id?: string
          importer_id?: string
          markup_applied_gbp?: number | null
          operator_id?: string
          order_ref?: string
          order_total_gbp_declared?: number
          order_total_gbp_reconciled?: number | null
          order_type?: string
          parent_order_id?: string | null
          payment_auth_id?: string | null
          quote_card_markup_pct?: number | null
          quote_fx_rate?: number | null
          quote_total_ghs?: number | null
          retailer_id?: string
          screenshot_url?: string | null
          shipper_id?: string
          sop_version?: string
          status?: string
          total_qty_declared?: number
          tracking_locked_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "orders_destination_hub_id_fkey"
            columns: ["destination_hub_id"]
            isOneToOne: false
            referencedRelation: "hubs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importer_balance_vw"
            referencedColumns: ["importer_id"]
          },
          {
            foreignKeyName: "orders_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_parent_order_id_fkey"
            columns: ["parent_order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "orders_parent_order_id_fkey"
            columns: ["parent_order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      payout_requests: {
        Row: {
          amount_gbp: number
          amount_local_ccy: number
          approved_at: string | null
          approved_by_staff_id: string | null
          beneficiary_reference: string | null
          created_at: string
          dispute_id: string
          id: string
          importer_id: string
          local_ccy: string
          notes: string | null
          paid_at: string | null
          payout_method: string
          proof_url: string | null
          status: string
        }
        Insert: {
          amount_gbp: number
          amount_local_ccy: number
          approved_at?: string | null
          approved_by_staff_id?: string | null
          beneficiary_reference?: string | null
          created_at?: string
          dispute_id: string
          id?: string
          importer_id: string
          local_ccy: string
          notes?: string | null
          paid_at?: string | null
          payout_method: string
          proof_url?: string | null
          status?: string
        }
        Update: {
          amount_gbp?: number
          amount_local_ccy?: number
          approved_at?: string | null
          approved_by_staff_id?: string | null
          beneficiary_reference?: string | null
          created_at?: string
          dispute_id?: string
          id?: string
          importer_id?: string
          local_ccy?: string
          notes?: string | null
          paid_at?: string | null
          payout_method?: string
          proof_url?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "payout_requests_approved_by_staff_id_fkey"
            columns: ["approved_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payout_requests_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payout_requests_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importer_balance_vw"
            referencedColumns: ["importer_id"]
          },
          {
            foreignKeyName: "payout_requests_importer_id_fkey"
            columns: ["importer_id"]
            isOneToOne: false
            referencedRelation: "importers"
            referencedColumns: ["id"]
          },
        ]
      }
      retailer_account_access: {
        Row: {
          granted_at: string
          granted_by_staff_id: string
          id: string
          operator_id: string
          retailer_account_id: string
          revoked_at: string | null
        }
        Insert: {
          granted_at?: string
          granted_by_staff_id: string
          id?: string
          operator_id: string
          retailer_account_id: string
          revoked_at?: string | null
        }
        Update: {
          granted_at?: string
          granted_by_staff_id?: string
          id?: string
          operator_id?: string
          retailer_account_id?: string
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "retailer_account_access_granted_by_staff_id_fkey"
            columns: ["granted_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "retailer_account_access_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "retailer_account_access_retailer_account_id_fkey"
            columns: ["retailer_account_id"]
            isOneToOne: false
            referencedRelation: "retailer_accounts"
            referencedColumns: ["id"]
          },
        ]
      }
      retailer_accounts: {
        Row: {
          account_email: string
          account_username: string | null
          card_last_4: string | null
          card_vault_ref: string | null
          created_at: string
          credential_delivery_method: string
          credentials_vault_ref: string | null
          delivery_address_locked_to_hub_id: string
          id: string
          last_login_at: string | null
          last_login_by_operator_id: string | null
          retailer_id: string
          shipper_id: string | null
          status: string
        }
        Insert: {
          account_email: string
          account_username?: string | null
          card_last_4?: string | null
          card_vault_ref?: string | null
          created_at?: string
          credential_delivery_method: string
          credentials_vault_ref?: string | null
          delivery_address_locked_to_hub_id: string
          id?: string
          last_login_at?: string | null
          last_login_by_operator_id?: string | null
          retailer_id: string
          shipper_id?: string | null
          status: string
        }
        Update: {
          account_email?: string
          account_username?: string | null
          card_last_4?: string | null
          card_vault_ref?: string | null
          created_at?: string
          credential_delivery_method?: string
          credentials_vault_ref?: string | null
          delivery_address_locked_to_hub_id?: string
          id?: string
          last_login_at?: string | null
          last_login_by_operator_id?: string | null
          retailer_id?: string
          shipper_id?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "retailer_accounts_delivery_address_locked_to_hub_id_fkey"
            columns: ["delivery_address_locked_to_hub_id"]
            isOneToOne: false
            referencedRelation: "hubs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "retailer_accounts_last_login_by_operator_id_fkey"
            columns: ["last_login_by_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "retailer_accounts_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "retailer_accounts_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      retailer_sops: {
        Row: {
          active: boolean
          claim_email: string | null
          claim_portal_url: string | null
          claim_procedure_notes: string | null
          deprecated_date: string | null
          effective_date: string
          escalation_path: string | null
          id: string
          retailer_id: string
          version: string
        }
        Insert: {
          active?: boolean
          claim_email?: string | null
          claim_portal_url?: string | null
          claim_procedure_notes?: string | null
          deprecated_date?: string | null
          effective_date: string
          escalation_path?: string | null
          id?: string
          retailer_id: string
          version: string
        }
        Update: {
          active?: boolean
          claim_email?: string | null
          claim_portal_url?: string | null
          claim_procedure_notes?: string | null
          deprecated_date?: string | null
          effective_date?: string
          escalation_path?: string | null
          id?: string
          retailer_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "retailer_sops_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
        ]
      }
      retailers: {
        Row: {
          account_email_template: string | null
          created_at: string
          global_enabled: boolean
          id: string
          name: string
          website_url: string | null
        }
        Insert: {
          account_email_template?: string | null
          created_at?: string
          global_enabled?: boolean
          id?: string
          name: string
          website_url?: string | null
        }
        Update: {
          account_email_template?: string | null
          created_at?: string
          global_enabled?: boolean
          id?: string
          name?: string
          website_url?: string | null
        }
        Relationships: []
      }
      sage_config: {
        Row: {
          ap_retailer_nominal_code: string
          ap_shipper_nominal_code: string
          ar_nominal_code: string
          cogs_goods_nominal_code: string
          cogs_shipping_nominal_code: string
          created_at: string
          created_by_staff_id: string
          default_purchase_tax_code: string
          default_sales_tax_code: string
          effective_from: string
          effective_to: string | null
          fx_gain_loss_nominal_code: string
          id: string
          installation_id: string
          outside_scope_tax_code: string | null
          reason_for_change: string | null
          sage_api_credentials_vault_ref: string
          sage_tenant_id: string
          sales_adjustment_zero_rating_nominal_code: string
          sales_exports_nominal_code: string
          vat_adjustments_nominal_code: string
          vat_input_nominal_code: string
          vat_liability_nominal_code: string
          vat_output_nominal_code: string
          version_number: number
        }
        Insert: {
          ap_retailer_nominal_code: string
          ap_shipper_nominal_code: string
          ar_nominal_code: string
          cogs_goods_nominal_code: string
          cogs_shipping_nominal_code: string
          created_at?: string
          created_by_staff_id: string
          default_purchase_tax_code?: string
          default_sales_tax_code?: string
          effective_from: string
          effective_to?: string | null
          fx_gain_loss_nominal_code: string
          id?: string
          installation_id: string
          outside_scope_tax_code?: string | null
          reason_for_change?: string | null
          sage_api_credentials_vault_ref: string
          sage_tenant_id: string
          sales_adjustment_zero_rating_nominal_code: string
          sales_exports_nominal_code: string
          vat_adjustments_nominal_code: string
          vat_input_nominal_code: string
          vat_liability_nominal_code: string
          vat_output_nominal_code: string
          version_number: number
        }
        Update: {
          ap_retailer_nominal_code?: string
          ap_shipper_nominal_code?: string
          ar_nominal_code?: string
          cogs_goods_nominal_code?: string
          cogs_shipping_nominal_code?: string
          created_at?: string
          created_by_staff_id?: string
          default_purchase_tax_code?: string
          default_sales_tax_code?: string
          effective_from?: string
          effective_to?: string | null
          fx_gain_loss_nominal_code?: string
          id?: string
          installation_id?: string
          outside_scope_tax_code?: string | null
          reason_for_change?: string | null
          sage_api_credentials_vault_ref?: string
          sage_tenant_id?: string
          sales_adjustment_zero_rating_nominal_code?: string
          sales_exports_nominal_code?: string
          vat_adjustments_nominal_code?: string
          vat_input_nominal_code?: string
          vat_liability_nominal_code?: string
          vat_output_nominal_code?: string
          version_number?: number
        }
        Relationships: [
          {
            foreignKeyName: "sage_config_created_by_staff_id_fkey"
            columns: ["created_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sage_config_installation_id_fkey"
            columns: ["installation_id"]
            isOneToOne: false
            referencedRelation: "installation"
            referencedColumns: ["id"]
          },
        ]
      }
      sage_postings: {
        Row: {
          amount_gbp: number
          event_type: string
          id: string
          idempotency_key: string
          posted_at: string | null
          posting_type: string
          retry_count: number
          sage_config_version_id: string
          sage_response_json: Json | null
          sage_transaction_id: string | null
          source_id: string
          source_table: string
          status: string
        }
        Insert: {
          amount_gbp: number
          event_type: string
          id?: string
          idempotency_key: string
          posted_at?: string | null
          posting_type: string
          retry_count?: number
          sage_config_version_id: string
          sage_response_json?: Json | null
          sage_transaction_id?: string | null
          source_id: string
          source_table: string
          status?: string
        }
        Update: {
          amount_gbp?: number
          event_type?: string
          id?: string
          idempotency_key?: string
          posted_at?: string | null
          posting_type?: string
          retry_count?: number
          sage_config_version_id?: string
          sage_response_json?: Json | null
          sage_transaction_id?: string | null
          source_id?: string
          source_table?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "sage_postings_sage_config_version_id_fkey"
            columns: ["sage_config_version_id"]
            isOneToOne: false
            referencedRelation: "sage_config"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_invoices: {
        Row: {
          amount_gbp: number
          consideration_received_date: string
          created_at: string
          export_evidence_complete_date: string | null
          id: string
          invoice_type: string
          line_items_json: Json
          linked_invoice_id: string | null
          order_id: string
          raised_by_trigger: boolean
          reversal_posted_at: string | null
          sage_invoice_date: string
          sage_invoice_id: string | null
          sage_invoice_period: string
          sage_posted_at: string | null
          sage_status: string
          tax_point_period: string
          vat_adjustment_posted_at: string | null
          vat_box6_reported_period: string | null
          vat_code: string
          zero_rating_deadline_date: string
          zero_rating_status: string
        }
        Insert: {
          amount_gbp: number
          consideration_received_date: string
          created_at?: string
          export_evidence_complete_date?: string | null
          id?: string
          invoice_type: string
          line_items_json: Json
          linked_invoice_id?: string | null
          order_id: string
          raised_by_trigger?: boolean
          reversal_posted_at?: string | null
          sage_invoice_date: string
          sage_invoice_id?: string | null
          sage_invoice_period: string
          sage_posted_at?: string | null
          sage_status?: string
          tax_point_period: string
          vat_adjustment_posted_at?: string | null
          vat_box6_reported_period?: string | null
          vat_code?: string
          zero_rating_deadline_date: string
          zero_rating_status?: string
        }
        Update: {
          amount_gbp?: number
          consideration_received_date?: string
          created_at?: string
          export_evidence_complete_date?: string | null
          id?: string
          invoice_type?: string
          line_items_json?: Json
          linked_invoice_id?: string | null
          order_id?: string
          raised_by_trigger?: boolean
          reversal_posted_at?: string | null
          sage_invoice_date?: string
          sage_invoice_id?: string | null
          sage_invoice_period?: string
          sage_posted_at?: string | null
          sage_status?: string
          tax_point_period?: string
          vat_adjustment_posted_at?: string | null
          vat_box6_reported_period?: string | null
          vat_code?: string
          zero_rating_deadline_date?: string
          zero_rating_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_invoices_linked_invoice_id_fkey"
            columns: ["linked_invoice_id"]
            isOneToOne: false
            referencedRelation: "sales_invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_invoices_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "sales_invoices_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
        ]
      }
      shipper_branding: {
        Row: {
          custom_domain: string | null
          email_sender_address: string | null
          email_sender_name: string | null
          id: string
          logo_url: string | null
          primary_colour: string | null
          secondary_colour: string | null
          shipper_id: string
          updated_at: string
        }
        Insert: {
          custom_domain?: string | null
          email_sender_address?: string | null
          email_sender_name?: string | null
          id?: string
          logo_url?: string | null
          primary_colour?: string | null
          secondary_colour?: string | null
          shipper_id: string
          updated_at?: string
        }
        Update: {
          custom_domain?: string | null
          email_sender_address?: string | null
          email_sender_name?: string | null
          id?: string
          logo_url?: string | null
          primary_colour?: string | null
          secondary_colour?: string | null
          shipper_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipper_branding_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shipper_countries: {
        Row: {
          country_id: string
          created_at: string
          id: string
          shipper_id: string
        }
        Insert: {
          country_id: string
          created_at?: string
          id?: string
          shipper_id: string
        }
        Update: {
          country_id?: string
          created_at?: string
          id?: string
          shipper_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipper_countries_country_id_fkey"
            columns: ["country_id"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipper_countries_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shipper_liabilities: {
        Row: {
          amount_gbp: number
          dispute_id: string
          id: string
          notes: string | null
          offset_against_shipping_quote_id: string | null
          order_id: string
          resolved_at: string | null
          settlement_method: string | null
          shipper_id: string
          shipper_response: string | null
        }
        Insert: {
          amount_gbp: number
          dispute_id: string
          id?: string
          notes?: string | null
          offset_against_shipping_quote_id?: string | null
          order_id: string
          resolved_at?: string | null
          settlement_method?: string | null
          shipper_id: string
          shipper_response?: string | null
        }
        Update: {
          amount_gbp?: number
          dispute_id?: string
          id?: string
          notes?: string | null
          offset_against_shipping_quote_id?: string | null
          order_id?: string
          resolved_at?: string | null
          settlement_method?: string | null
          shipper_id?: string
          shipper_response?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shipper_liabilities_dispute_id_fkey"
            columns: ["dispute_id"]
            isOneToOne: false
            referencedRelation: "disputes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipper_liabilities_offset_against_shipping_quote_id_fkey"
            columns: ["offset_against_shipping_quote_id"]
            isOneToOne: false
            referencedRelation: "shipping_quotes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipper_liabilities_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "shipper_liabilities_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipper_liabilities_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shipper_retailers: {
        Row: {
          created_at: string
          enabled: boolean
          id: string
          retailer_id: string
          shipper_id: string
        }
        Insert: {
          created_at?: string
          enabled?: boolean
          id?: string
          retailer_id: string
          shipper_id: string
        }
        Update: {
          created_at?: string
          enabled?: boolean
          id?: string
          retailer_id?: string
          shipper_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipper_retailers_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipper_retailers_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shipper_sops: {
        Row: {
          active: boolean
          cargo_insurance_ref: string | null
          claim_email: string | null
          claim_procedure_notes: string | null
          deprecated_date: string | null
          effective_date: string
          escalation_path: string | null
          id: string
          shipper_id: string
          version: string
        }
        Insert: {
          active?: boolean
          cargo_insurance_ref?: string | null
          claim_email?: string | null
          claim_procedure_notes?: string | null
          deprecated_date?: string | null
          effective_date: string
          escalation_path?: string | null
          id?: string
          shipper_id: string
          version: string
        }
        Update: {
          active?: boolean
          cargo_insurance_ref?: string | null
          claim_email?: string | null
          claim_procedure_notes?: string | null
          deprecated_date?: string | null
          effective_date?: string
          escalation_path?: string | null
          id?: string
          shipper_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipper_sops_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shipper_users: {
        Row: {
          active: boolean
          auth_user_id: string
          created_at: string
          email: string
          full_name: string
          id: string
          last_login_at: string | null
          permissions_json: Json | null
          phone: string | null
          role_at_shipper: string
          shipper_id: string
        }
        Insert: {
          active?: boolean
          auth_user_id: string
          created_at?: string
          email: string
          full_name: string
          id?: string
          last_login_at?: string | null
          permissions_json?: Json | null
          phone?: string | null
          role_at_shipper: string
          shipper_id: string
        }
        Update: {
          active?: boolean
          auth_user_id?: string
          created_at?: string
          email?: string
          full_name?: string
          id?: string
          last_login_at?: string | null
          permissions_json?: Json | null
          phone?: string | null
          role_at_shipper?: string
          shipper_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipper_users_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shippers: {
        Row: {
          active: boolean
          contact_email: string | null
          contact_phone: string | null
          created_at: string
          id: string
          name: string
          primary_hub_id: string | null
          sage_customer_code_prefix: string | null
          sage_supplier_code: string | null
          sla_breach_escalation_contact: string | null
          sla_dispatch_days: number
          sla_ghana_arrival_days: number
          vat_registration_country: string | null
          vat_treatment: string | null
        }
        Insert: {
          active?: boolean
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          name: string
          primary_hub_id?: string | null
          sage_customer_code_prefix?: string | null
          sage_supplier_code?: string | null
          sla_breach_escalation_contact?: string | null
          sla_dispatch_days?: number
          sla_ghana_arrival_days?: number
          vat_registration_country?: string | null
          vat_treatment?: string | null
        }
        Update: {
          active?: boolean
          contact_email?: string | null
          contact_phone?: string | null
          created_at?: string
          id?: string
          name?: string
          primary_hub_id?: string | null
          sage_customer_code_prefix?: string | null
          sage_supplier_code?: string | null
          sla_breach_escalation_contact?: string | null
          sla_dispatch_days?: number
          sla_ghana_arrival_days?: number
          vat_registration_country?: string | null
          vat_treatment?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_shippers_primary_hub"
            columns: ["primary_hub_id"]
            isOneToOne: false
            referencedRelation: "hubs"
            referencedColumns: ["id"]
          },
        ]
      }
      shipping_estimate_brackets: {
        Row: {
          active: boolean
          applicable_corridor: string | null
          estimated_cost_gbp: number
          id: string
          shipper_id: string
          weight_or_volume_description: string
        }
        Insert: {
          active?: boolean
          applicable_corridor?: string | null
          estimated_cost_gbp: number
          id?: string
          shipper_id: string
          weight_or_volume_description: string
        }
        Update: {
          active?: boolean
          applicable_corridor?: string | null
          estimated_cost_gbp?: number
          id?: string
          shipper_id?: string
          weight_or_volume_description?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipping_estimate_brackets_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      shipping_quote_orders: {
        Row: {
          apportioned_shipping_gbp: number
          apportionment_pct: number
          created_at: string
          id: string
          order_id: string
          order_value_gbp: number
          shipping_quote_id: string
        }
        Insert: {
          apportioned_shipping_gbp: number
          apportionment_pct: number
          created_at?: string
          id?: string
          order_id: string
          order_value_gbp: number
          shipping_quote_id: string
        }
        Update: {
          apportioned_shipping_gbp?: number
          apportionment_pct?: number
          created_at?: string
          id?: string
          order_id?: string
          order_value_gbp?: number
          shipping_quote_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipping_quote_orders_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: true
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "shipping_quote_orders_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: true
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipping_quote_orders_shipping_quote_id_fkey"
            columns: ["shipping_quote_id"]
            isOneToOne: false
            referencedRelation: "shipping_quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      shipping_quotes: {
        Row: {
          bol_url: string | null
          booking_ref: string | null
          cert_of_shipment_url: string | null
          commercial_invoice_url: string | null
          courier_id: string | null
          created_at: string
          dispatched_at: string | null
          estimated_ghana_arrival_at: string | null
          ghana_delivered_at: string | null
          hub_receipt_confirmed_at: string | null
          hub_receipt_confirmed_by_staff_id: string | null
          id: string
          pod_ghana_url: string | null
          quote_gbp_total: number
          shipper_id: string
          sla_breach_flag: boolean
          sla_breach_reason: string | null
          sla_dispatch_target_date: string | null
          status: string
        }
        Insert: {
          bol_url?: string | null
          booking_ref?: string | null
          cert_of_shipment_url?: string | null
          commercial_invoice_url?: string | null
          courier_id?: string | null
          created_at?: string
          dispatched_at?: string | null
          estimated_ghana_arrival_at?: string | null
          ghana_delivered_at?: string | null
          hub_receipt_confirmed_at?: string | null
          hub_receipt_confirmed_by_staff_id?: string | null
          id?: string
          pod_ghana_url?: string | null
          quote_gbp_total: number
          shipper_id: string
          sla_breach_flag?: boolean
          sla_breach_reason?: string | null
          sla_dispatch_target_date?: string | null
          status?: string
        }
        Update: {
          bol_url?: string | null
          booking_ref?: string | null
          cert_of_shipment_url?: string | null
          commercial_invoice_url?: string | null
          courier_id?: string | null
          created_at?: string
          dispatched_at?: string | null
          estimated_ghana_arrival_at?: string | null
          ghana_delivered_at?: string | null
          hub_receipt_confirmed_at?: string | null
          hub_receipt_confirmed_by_staff_id?: string | null
          id?: string
          pod_ghana_url?: string | null
          quote_gbp_total?: number
          shipper_id?: string
          sla_breach_flag?: boolean
          sla_breach_reason?: string | null
          sla_dispatch_target_date?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipping_quotes_courier_id_fkey"
            columns: ["courier_id"]
            isOneToOne: false
            referencedRelation: "couriers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipping_quotes_hub_receipt_confirmed_by_staff_id_fkey"
            columns: ["hub_receipt_confirmed_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipping_quotes_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      signup_tokens: {
        Row: {
          country_id: string
          created_at: string
          created_by_staff_id: string
          expires_at: string
          id: string
          intended_use: string
          shipper_id: string
          token: string
          used_at: string | null
          used_by_operator_id: string | null
        }
        Insert: {
          country_id: string
          created_at?: string
          created_by_staff_id: string
          expires_at: string
          id?: string
          intended_use: string
          shipper_id: string
          token: string
          used_at?: string | null
          used_by_operator_id?: string | null
        }
        Update: {
          country_id?: string
          created_at?: string
          created_by_staff_id?: string
          expires_at?: string
          id?: string
          intended_use?: string
          shipper_id?: string
          token?: string
          used_at?: string | null
          used_by_operator_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_signup_tokens_used_by_operator"
            columns: ["used_by_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "signup_tokens_country_id_fkey"
            columns: ["country_id"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "signup_tokens_created_by_staff_id_fkey"
            columns: ["created_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "signup_tokens_shipper_id_fkey"
            columns: ["shipper_id"]
            isOneToOne: false
            referencedRelation: "shippers"
            referencedColumns: ["id"]
          },
        ]
      }
      sops: {
        Row: {
          content_md: string
          created_at: string
          deprecated_date: string | null
          effective_date: string
          id: string
          published_by_staff_id: string
          version: string
        }
        Insert: {
          content_md: string
          created_at?: string
          deprecated_date?: string | null
          effective_date: string
          id?: string
          published_by_staff_id: string
          version: string
        }
        Update: {
          content_md?: string
          created_at?: string
          deprecated_date?: string | null
          effective_date?: string
          id?: string
          published_by_staff_id?: string
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "sops_published_by_staff_id_fkey"
            columns: ["published_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
      staff: {
        Row: {
          active: boolean
          auth_user_id: string
          created_at: string
          email: string
          full_name: string
          id: string
          permissions_json: Json | null
          role_type: string
        }
        Insert: {
          active?: boolean
          auth_user_id: string
          created_at?: string
          email: string
          full_name: string
          id?: string
          permissions_json?: Json | null
          role_type: string
        }
        Update: {
          active?: boolean
          auth_user_id?: string
          created_at?: string
          email?: string
          full_name?: string
          id?: string
          permissions_json?: Json | null
          role_type?: string
        }
        Relationships: []
      }
      status_transitions: {
        Row: {
          active: boolean
          actor_roles_allowed: string[]
          entity_type: string
          from_status: string
          id: string
          required_conditions_json: Json | null
          to_status: string
        }
        Insert: {
          active?: boolean
          actor_roles_allowed: string[]
          entity_type: string
          from_status: string
          id?: string
          required_conditions_json?: Json | null
          to_status: string
        }
        Update: {
          active?: boolean
          actor_roles_allowed?: string[]
          entity_type?: string
          from_status?: string
          id?: string
          required_conditions_json?: Json | null
          to_status?: string
        }
        Relationships: []
      }
      supplier_invoice_lines: {
        Row: {
          amount_confirmed: number | null
          amount_inc_vat_gbp: number
          created_at: string
          description: string
          eligible_for_invoice_yn: string
          id: string
          line_order: number
          line_source: string
          qty: number
          qty_confirmed: number | null
          retailer_sku: string | null
          size: string | null
          supplier_invoice_id: string
          updated_at: string
        }
        Insert: {
          amount_confirmed?: number | null
          amount_inc_vat_gbp: number
          created_at?: string
          description: string
          eligible_for_invoice_yn?: string
          id?: string
          line_order: number
          line_source: string
          qty: number
          qty_confirmed?: number | null
          retailer_sku?: string | null
          size?: string | null
          supplier_invoice_id: string
          updated_at?: string
        }
        Update: {
          amount_confirmed?: number | null
          amount_inc_vat_gbp?: number
          created_at?: string
          description?: string
          eligible_for_invoice_yn?: string
          id?: string
          line_order?: number
          line_source?: string
          qty?: number
          qty_confirmed?: number | null
          retailer_sku?: string | null
          size?: string | null
          supplier_invoice_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "supplier_invoice_lines_supplier_invoice_id_fkey"
            columns: ["supplier_invoice_id"]
            isOneToOne: false
            referencedRelation: "supplier_invoices"
            referencedColumns: ["id"]
          },
        ]
      }
      supplier_invoices: {
        Row: {
          id: string
          invoice_pdf_url: string
          invoice_ref: string
          ocr_extracted_at: string | null
          ocr_raw_json: Json | null
          ocr_service_used: string | null
          order_id: string
          reconciled_by_operator_id: string | null
          reconciliation_confirmed_at: string | null
          reconciliation_gbp_total: number | null
          retailer_account_id: string
          retailer_id: string
          uploaded_at: string
          uploaded_by_operator_id: string
        }
        Insert: {
          id?: string
          invoice_pdf_url: string
          invoice_ref: string
          ocr_extracted_at?: string | null
          ocr_raw_json?: Json | null
          ocr_service_used?: string | null
          order_id: string
          reconciled_by_operator_id?: string | null
          reconciliation_confirmed_at?: string | null
          reconciliation_gbp_total?: number | null
          retailer_account_id: string
          retailer_id: string
          uploaded_at?: string
          uploaded_by_operator_id: string
        }
        Update: {
          id?: string
          invoice_pdf_url?: string
          invoice_ref?: string
          ocr_extracted_at?: string | null
          ocr_raw_json?: Json | null
          ocr_service_used?: string | null
          order_id?: string
          reconciled_by_operator_id?: string | null
          reconciliation_confirmed_at?: string | null
          reconciliation_gbp_total?: number | null
          retailer_account_id?: string
          retailer_id?: string
          uploaded_at?: string
          uploaded_by_operator_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "supplier_invoices_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "order_reconciliation_vw"
            referencedColumns: ["order_id"]
          },
          {
            foreignKeyName: "supplier_invoices_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_reconciled_by_operator_id_fkey"
            columns: ["reconciled_by_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_retailer_account_id_fkey"
            columns: ["retailer_account_id"]
            isOneToOne: false
            referencedRelation: "retailer_accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_invoices_uploaded_by_operator_id_fkey"
            columns: ["uploaded_by_operator_id"]
            isOneToOne: false
            referencedRelation: "operators"
            referencedColumns: ["id"]
          },
        ]
      }
      vat_return_adjustments: {
        Row: {
          amount_gbp: number
          direction: string
          id: string
          notes: string | null
          posted_at: string
          posted_by_staff_id: string
          report_type: string
          return_period: string
          sage_journal_ref: string | null
          source_sales_invoice_id: string
        }
        Insert: {
          amount_gbp: number
          direction: string
          id?: string
          notes?: string | null
          posted_at?: string
          posted_by_staff_id: string
          report_type: string
          return_period: string
          sage_journal_ref?: string | null
          source_sales_invoice_id: string
        }
        Update: {
          amount_gbp?: number
          direction?: string
          id?: string
          notes?: string | null
          posted_at?: string
          posted_by_staff_id?: string
          report_type?: string
          return_period?: string
          sage_journal_ref?: string | null
          source_sales_invoice_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "vat_return_adjustments_posted_by_staff_id_fkey"
            columns: ["posted_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vat_return_adjustments_source_sales_invoice_id_fkey"
            columns: ["source_sales_invoice_id"]
            isOneToOne: false
            referencedRelation: "sales_invoices"
            referencedColumns: ["id"]
          },
        ]
      }
      vat_return_workings: {
        Row: {
          breach_total: number | null
          filed_at: string | null
          filed_by_staff_id: string | null
          final_box1: number | null
          final_box4: number | null
          final_box6: number | null
          final_box7: number | null
          generated_at: string
          generated_by_staff_id: string
          id: string
          reinstatement_total: number | null
          return_period: string
          section_a_total: number | null
          section_b_total: number | null
          section_c_total: number | null
          section_d_total: number | null
          zip_bundle_url: string | null
        }
        Insert: {
          breach_total?: number | null
          filed_at?: string | null
          filed_by_staff_id?: string | null
          final_box1?: number | null
          final_box4?: number | null
          final_box6?: number | null
          final_box7?: number | null
          generated_at?: string
          generated_by_staff_id: string
          id?: string
          reinstatement_total?: number | null
          return_period: string
          section_a_total?: number | null
          section_b_total?: number | null
          section_c_total?: number | null
          section_d_total?: number | null
          zip_bundle_url?: string | null
        }
        Update: {
          breach_total?: number | null
          filed_at?: string | null
          filed_by_staff_id?: string | null
          final_box1?: number | null
          final_box4?: number | null
          final_box6?: number | null
          final_box7?: number | null
          generated_at?: string
          generated_by_staff_id?: string
          id?: string
          reinstatement_total?: number | null
          return_period?: string
          section_a_total?: number | null
          section_b_total?: number | null
          section_c_total?: number | null
          section_d_total?: number | null
          zip_bundle_url?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "vat_return_workings_filed_by_staff_id_fkey"
            columns: ["filed_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "vat_return_workings_generated_by_staff_id_fkey"
            columns: ["generated_by_staff_id"]
            isOneToOne: false
            referencedRelation: "staff"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      importer_balance_vw: {
        Row: {
          active_order_funding_gbp: number | null
          available_credit_gbp: number | null
          importer_id: string | null
          last_refreshed_at: string | null
          payout_in_progress_gbp: number | null
          pending_refund_gbp: number | null
        }
        Relationships: []
      }
      order_reconciliation_vw: {
        Row: {
          amount_progressed_invoiceable_gbp: number | null
          amount_resolved_noninvoiceable_gbp: number | null
          amount_target_gbp: number | null
          amount_unresolved_gbp: number | null
          invoiceable_subset_released_yn: boolean | null
          last_refreshed_at: string | null
          order_id: string | null
          qty_progressed_invoiceable: number | null
          qty_resolved_noninvoiceable: number | null
          qty_target: number | null
          qty_unresolved: number | null
          whole_order_cleared_yn: boolean | null
        }
        Relationships: []
      }
    }
    Functions: {
      [_ in never]: never
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
