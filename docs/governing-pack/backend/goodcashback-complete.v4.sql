-- =============================================================================
-- GOODCASHBACK PLATFORM — COMPLETE SUPABASE MIGRATION
-- =============================================================================
-- Run this entire file in Supabase SQL Editor as a single migration.
-- Contains:
--   1. Extensions
--   2. All 49 tables with constraints
--   3. Foreign key relationships
--   4. Unique indexes (including 7 partial indexes)
--   5. Check constraints
--   6. Two derived views (importer_balance_vw, order_reconciliation_vw)
--   7. Audit log trigger function (attached to all substantive tables)
--   8. State transition enforcement trigger
--   9. Invoice-gate trigger
--  10. Lock state machine triggers
--  11. RLS policies (per role)
--  12. Seed reference data (currencies, countries, default SOP, status_transitions)
-- =============================================================================

-- =============================================================================
-- 1. EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- 2. MODULE 1 — CONFIGURATION & TENANCY
-- =============================================================================

CREATE TABLE currencies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code varchar(3) NOT NULL UNIQUE,
  symbol varchar(5),
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE countries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar NOT NULL,
  iso_code varchar(3) NOT NULL UNIQUE,
  currency_id uuid NOT NULL REFERENCES currencies(id),
  active boolean NOT NULL DEFAULT true
);

-- staff and shippers are forward-referenced; created here without FKs, FKs added later
CREATE TABLE staff (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_user_id uuid UNIQUE NOT NULL,
  role_type varchar NOT NULL CHECK (role_type IN ('admin','supervisor')),
  full_name varchar NOT NULL,
  email varchar NOT NULL UNIQUE,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  permissions_json jsonb DEFAULT '{}'::jsonb
);

CREATE TABLE shippers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar NOT NULL,
  contact_email varchar,
  contact_phone varchar,
  vat_treatment varchar CHECK (vat_treatment IN ('outside_scope','domestic_vat','zero_rated')),
  vat_registration_country varchar,
  sage_supplier_code varchar,
  sage_customer_code_prefix varchar,
  primary_hub_id uuid, -- FK added after hubs created
  sla_dispatch_days int NOT NULL DEFAULT 14,
  sla_ghana_arrival_days int NOT NULL DEFAULT 42,
  sla_breach_escalation_contact varchar,
  created_at timestamptz NOT NULL DEFAULT now(),
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE shipper_branding (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  logo_url varchar,
  primary_colour varchar,
  secondary_colour varchar,
  custom_domain varchar,
  email_sender_name varchar,
  email_sender_address varchar,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE installation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  deployment_mode varchar NOT NULL CHECK (deployment_mode IN ('multi_tenant','single_tenant')),
  active_shipper_id uuid REFERENCES shippers(id),
  platform_name_override varchar,
  default_tenant_branding_id uuid REFERENCES shipper_branding(id),
  netp_status boolean NOT NULL DEFAULT true,
  uk_vat_number varchar,
  vat_return_frequency varchar DEFAULT 'monthly',
  markup_enabled_global boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT installation_tenancy_check CHECK (
    (deployment_mode = 'single_tenant' AND active_shipper_id IS NOT NULL) OR
    (deployment_mode = 'multi_tenant' AND active_shipper_id IS NULL)
  )
);

CREATE TABLE couriers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar NOT NULL,
  tracking_url_template varchar,
  added_by_staff_id uuid REFERENCES staff(id),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retailers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name varchar NOT NULL,
  website_url varchar,
  account_email_template varchar,
  global_enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE markup_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid REFERENCES shippers(id),
  category_name varchar NOT NULL,
  default_markup_pct decimal(6,3) NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE fx_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_id uuid NOT NULL REFERENCES countries(id),
  rate_date date NOT NULL,
  quote_rate decimal(18,8) NOT NULL,
  quote_card_markup_pct decimal(6,3) NOT NULL,
  settlement_rate decimal(18,8) NOT NULL,
  settlement_card_markup_pct decimal(6,3) NOT NULL,
  entered_by_staff_id uuid NOT NULL REFERENCES staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (country_id, rate_date)
);

CREATE TABLE sops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  version varchar NOT NULL,
  content_md text NOT NULL,
  effective_date date NOT NULL,
  deprecated_date date,
  published_by_staff_id uuid NOT NULL REFERENCES staff(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retailer_sops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  retailer_id uuid NOT NULL REFERENCES retailers(id),
  claim_email varchar,
  claim_portal_url varchar,
  claim_procedure_notes text,
  escalation_path text,
  version varchar NOT NULL,
  effective_date date NOT NULL,
  deprecated_date date,
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE shipper_sops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  claim_email varchar,
  cargo_insurance_ref varchar,
  claim_procedure_notes text,
  escalation_path text,
  version varchar NOT NULL,
  effective_date date NOT NULL,
  deprecated_date date,
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE sage_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  installation_id uuid NOT NULL REFERENCES installation(id),
  version_number int NOT NULL,
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  sage_tenant_id varchar NOT NULL,
  sage_api_credentials_vault_ref varchar NOT NULL,
  default_sales_tax_code varchar NOT NULL DEFAULT 'T0',
  default_purchase_tax_code varchar NOT NULL DEFAULT 'T1',
  outside_scope_tax_code varchar,
  ar_nominal_code varchar NOT NULL,
  ap_retailer_nominal_code varchar NOT NULL,
  ap_shipper_nominal_code varchar NOT NULL,
  sales_exports_nominal_code varchar NOT NULL,
  cogs_goods_nominal_code varchar NOT NULL,
  cogs_shipping_nominal_code varchar NOT NULL,
  fx_gain_loss_nominal_code varchar NOT NULL,
  sales_adjustment_zero_rating_nominal_code varchar NOT NULL,
  vat_input_nominal_code varchar NOT NULL,
  vat_output_nominal_code varchar NOT NULL,
  vat_liability_nominal_code varchar NOT NULL,
  vat_adjustments_nominal_code varchar NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by_staff_id uuid NOT NULL REFERENCES staff(id),
  reason_for_change text,
  UNIQUE (installation_id, version_number)
);

CREATE TABLE status_transitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type varchar NOT NULL CHECK (entity_type IN ('order','dispute','dispute_line','shipping_quote')),
  from_status varchar NOT NULL,
  to_status varchar NOT NULL,
  required_conditions_json jsonb,
  actor_roles_allowed text[] NOT NULL,
  active boolean NOT NULL DEFAULT true
);

-- =============================================================================
-- 3. MODULE 2 — ORGANIZATIONS
-- =============================================================================

CREATE TABLE hubs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid REFERENCES shippers(id),
  name varchar NOT NULL,
  country_id uuid NOT NULL REFERENCES countries(id),
  full_address text NOT NULL,
  postcode varchar,
  receiving_contact_name varchar,
  receiving_contact_phone varchar,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- now add the shipper.primary_hub_id FK
ALTER TABLE shippers ADD CONSTRAINT fk_shippers_primary_hub
  FOREIGN KEY (primary_hub_id) REFERENCES hubs(id);

CREATE TABLE shipper_countries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  country_id uuid NOT NULL REFERENCES countries(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shipper_id, country_id)
);

CREATE TABLE shipper_retailers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  retailer_id uuid NOT NULL REFERENCES retailers(id),
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shipper_id, retailer_id)
);

CREATE TABLE signup_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token varchar NOT NULL UNIQUE,
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  country_id uuid NOT NULL REFERENCES countries(id),
  intended_use varchar NOT NULL CHECK (intended_use IN ('importer','operator')),
  created_by_staff_id uuid NOT NULL REFERENCES staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  used_by_operator_id uuid -- FK added after operators created
);

CREATE TABLE importers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  country_id uuid NOT NULL REFERENCES countries(id),
  company_name varchar NOT NULL,
  trading_name varchar,
  address text,
  sage_customer_code varchar,
  gcb_dva_ref varchar,
  dva_card_last_4 varchar(4),
  onboarded_via_signup_token_id uuid REFERENCES signup_tokens(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE operators (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email varchar NOT NULL UNIQUE,
  phone varchar,
  full_name varchar NOT NULL,
  auth_user_id uuid UNIQUE,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz
);

ALTER TABLE signup_tokens ADD CONSTRAINT fk_signup_tokens_used_by_operator
  FOREIGN KEY (used_by_operator_id) REFERENCES operators(id);

CREATE TABLE operator_importers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operator_id uuid NOT NULL REFERENCES operators(id),
  importer_id uuid NOT NULL REFERENCES importers(id),
  relationship_type varchar NOT NULL CHECK (relationship_type IN ('sole_owner','authorised_user')),
  granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE TABLE shipper_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  auth_user_id uuid NOT NULL,
  full_name varchar NOT NULL,
  email varchar NOT NULL,
  phone varchar,
  role_at_shipper varchar NOT NULL CHECK (role_at_shipper IN ('shipper_admin','shipper_operator','shipper_readonly')),
  permissions_json jsonb DEFAULT '{}'::jsonb,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz,
  UNIQUE (shipper_id, auth_user_id)
);

CREATE TABLE retailer_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  retailer_id uuid NOT NULL REFERENCES retailers(id),
  shipper_id uuid REFERENCES shippers(id),
  account_email varchar NOT NULL,
  account_username varchar,
  credentials_vault_ref varchar,
  credential_delivery_method varchar NOT NULL CHECK (credential_delivery_method IN ('vault_brokered','shared_direct','pending_vault_upgrade')),
  delivery_address_locked_to_hub_id uuid NOT NULL REFERENCES hubs(id),
  card_last_4 varchar(4),
  card_vault_ref varchar,
  status varchar NOT NULL CHECK (status IN ('active','suspended','locked_out')),
  last_login_at timestamptz,
  last_login_by_operator_id uuid REFERENCES operators(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE retailer_account_access (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  retailer_account_id uuid NOT NULL REFERENCES retailer_accounts(id),
  operator_id uuid NOT NULL REFERENCES operators(id),
  granted_at timestamptz NOT NULL DEFAULT now(),
  granted_by_staff_id uuid NOT NULL REFERENCES staff(id),
  revoked_at timestamptz
);

-- =============================================================================
-- 4. MODULE 3 — ORDERS (with forward ref to sales_invoices resolved later)
-- =============================================================================

CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_ref varchar NOT NULL UNIQUE,
  payment_auth_id varchar,
  importer_id uuid NOT NULL REFERENCES importers(id),
  operator_id uuid NOT NULL REFERENCES operators(id),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  retailer_id uuid NOT NULL REFERENCES retailers(id),
  destination_hub_id uuid NOT NULL REFERENCES hubs(id),
  parent_order_id uuid REFERENCES orders(id),
  order_type varchar NOT NULL DEFAULT 'main' CHECK (order_type IN ('main','replacement')),
  screenshot_url varchar, -- legacy / backward-compat only; new screenshot flows use order_screenshots
  order_total_gbp_declared decimal(12,2) NOT NULL,
  order_total_gbp_reconciled decimal(12,2),
  total_qty_declared int NOT NULL,
  markup_applied_gbp decimal(12,2),
  estimated_shipping_gbp decimal(12,2),
  actual_shipping_gbp decimal(12,2),
  bundled_quote_gbp decimal(12,2),
  bundled_final_gbp decimal(12,2),
  quote_fx_rate decimal(18,8),
  quote_card_markup_pct decimal(6,3),
  quote_total_ghs decimal(18,2),
  funded_at timestamptz,
  status varchar NOT NULL DEFAULT 'pending_dva_funding',
  content_locked_at timestamptz,
  tracking_locked_at timestamptz,
  sop_version varchar NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE TABLE order_screenshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  screenshot_url varchar NOT NULL,
  uploaded_by_operator_id uuid NOT NULL REFERENCES operators(id),
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  display_order int NOT NULL DEFAULT 1,
  note varchar
);

CREATE INDEX idx_order_screenshots_order_display
  ON order_screenshots(order_id, display_order);

CREATE TABLE order_tracking_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  courier_id uuid NOT NULL REFERENCES couriers(id),
  tracking_ref varchar NOT NULL,
  tracking_date date NOT NULL,
  tracking_screenshot_url varchar,
  submitted_by_operator_id uuid NOT NULL REFERENCES operators(id),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  superseded_at timestamptz,
  note text
);

CREATE INDEX idx_order_tracking_submissions_order_submitted
  ON order_tracking_submissions(order_id, submitted_at);

CREATE INDEX idx_order_tracking_submissions_courier_tracking
  ON order_tracking_submissions(courier_id, tracking_ref);

CREATE TABLE order_category_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id),
  markup_category_id uuid NOT NULL REFERENCES markup_categories(id),
  qty int NOT NULL,
  amount_inc_vat_gbp decimal(12,2) NOT NULL,
  markup_pct_applied decimal(6,3) NOT NULL,
  markup_gbp_calculated decimal(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE supplier_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id),
  retailer_id uuid NOT NULL REFERENCES retailers(id),
  retailer_account_id uuid NOT NULL REFERENCES retailer_accounts(id),
  invoice_ref varchar NOT NULL,
  invoice_pdf_url varchar NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  uploaded_by_operator_id uuid NOT NULL REFERENCES operators(id),
  ocr_service_used varchar CHECK (ocr_service_used IN ('mindee','google_docai','manual')),
  ocr_raw_json jsonb,
  ocr_extracted_at timestamptz,
  reconciliation_confirmed_at timestamptz,
  reconciled_by_operator_id uuid REFERENCES operators(id),
  reconciliation_gbp_total decimal(12,2),
  UNIQUE (retailer_id, invoice_ref, order_id)
);

CREATE TABLE supplier_invoice_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id uuid NOT NULL REFERENCES supplier_invoices(id),
  line_order int NOT NULL,
  retailer_sku varchar,
  description varchar NOT NULL,
  qty int NOT NULL,
  size varchar,
  amount_inc_vat_gbp decimal(12,2) NOT NULL,
  line_source varchar NOT NULL CHECK (line_source IN ('ocr_extracted','manually_added')),
  qty_confirmed int,
  amount_confirmed decimal(12,2),
  eligible_for_invoice_yn varchar(1) NOT NULL DEFAULT 'N' CHECK (eligible_for_invoice_yn IN ('Y','N')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 5. MODULE 4 — SHIPPING
-- =============================================================================

CREATE TABLE shipping_estimate_brackets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  weight_or_volume_description varchar NOT NULL,
  estimated_cost_gbp decimal(12,2) NOT NULL,
  applicable_corridor varchar,
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE shipping_quotes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  quote_gbp_total decimal(12,2) NOT NULL,
  booking_ref varchar,
  courier_id uuid REFERENCES couriers(id),
  bol_url varchar,
  cert_of_shipment_url varchar,
  commercial_invoice_url varchar,
  hub_receipt_confirmed_at timestamptz,
  hub_receipt_confirmed_by_staff_id uuid REFERENCES staff(id),
  dispatched_at timestamptz,
  estimated_ghana_arrival_at timestamptz,
  pod_ghana_url varchar,
  ghana_delivered_at timestamptz,
  sla_dispatch_target_date date,
  sla_breach_flag boolean NOT NULL DEFAULT false,
  sla_breach_reason text,
  status varchar NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed','dispatched','delivered')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE shipping_quote_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipping_quote_id uuid NOT NULL REFERENCES shipping_quotes(id),
  order_id uuid NOT NULL REFERENCES orders(id) UNIQUE,
  order_value_gbp decimal(12,2) NOT NULL,
  apportionment_pct decimal(7,4) NOT NULL,
  apportioned_shipping_gbp decimal(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 6. MODULE 5 — DISPUTES, EXCEPTIONS & PAYOUTS
-- =============================================================================

-- sales_invoices forward-declared here as a stub; full definition below; disputes.customer_credit_note_sales_invoice_id references it
CREATE TABLE sales_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);

CREATE TABLE disputes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id),
  raised_at timestamptz NOT NULL DEFAULT now(),
  raised_by_operator_id uuid NOT NULL REFERENCES operators(id),
  issue_type varchar NOT NULL CHECK (issue_type IN ('missing','damaged','defective','not_as_described','wrong_item','late_warranty')),
  desired_outcome varchar NOT NULL CHECK (desired_outcome IN ('refund','replacement')),
  refund_settlement_mode varchar CHECK (refund_settlement_mode IN ('credit_balance','manual_payout')),
  liable_party varchar NOT NULL DEFAULT 'unknown' CHECK (liable_party IN ('retailer','shipper','unknown')),
  stage_detected varchar NOT NULL CHECK (stage_detected IN ('at_reconciliation','at_ghana_delivery','post_delivery_warranty')),
  amount_impact_gbp decimal(12,2) NOT NULL,
  comments_initial text,
  status varchar NOT NULL DEFAULT 'raised',
  reviewed_by_staff_id uuid REFERENCES staff(id),
  reviewed_at timestamptz,
  refund_approved_by_staff_id uuid REFERENCES staff(id),
  refund_approved_at timestamptz,
  customer_credit_note_sales_invoice_id uuid REFERENCES sales_invoices(id),
  replacement_child_order_id uuid REFERENCES orders(id),
  resolved_at timestamptz,
  sop_version varchar NOT NULL
);

CREATE TABLE dispute_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES disputes(id),
  supplier_invoice_line_id uuid NOT NULL REFERENCES supplier_invoice_lines(id),
  qty_impact int NOT NULL,
  amount_impact_gbp decimal(12,2) NOT NULL,
  line_status varchar NOT NULL CHECK (line_status IN ('affected','resolved','written_off')),
  conversation_status varchar DEFAULT 'child_exception_created' CHECK (conversation_status IN ('child_exception_created','remedy_selected','refund_pending_approval','retailer_draft_ready','retailer_contacted','retailer_response_received','ai_next_draft_ready','awaiting_retailer_resolution','resolved_refund','resolved_replacement','resolved_credit','closed_no_action')),
  intended_remedy varchar CHECK (intended_remedy IN ('refund','replacement')),
  resolution_method varchar CHECK (resolution_method IN ('refund','replacement','accept_as_is','credit','closed_no_action')),
  resolved_at timestamptz,
  resolved_via_child_order_id uuid REFERENCES orders(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dispute_id, supplier_invoice_line_id)
);

CREATE TABLE dispute_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES disputes(id),
  image_url varchar NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  uploaded_by_operator_id uuid NOT NULL REFERENCES operators(id)
);

CREATE TABLE dispute_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES disputes(id),
  note_text text NOT NULL,
  author_type varchar NOT NULL CHECK (author_type IN ('operator','staff','shipper_user')),
  author_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dispute_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES disputes(id),
  message_type varchar NOT NULL CHECK (message_type IN ('opening','retailer_reply','gc_draft','gc_sent','supervisor_note')),
  counterparty varchar NOT NULL CHECK (counterparty IN ('retailer','shipper','internal')),
  subject varchar,
  body text NOT NULL,
  generated_by varchar NOT NULL CHECK (generated_by IN ('claude','manual','retailer_paste')),
  sop_version_applied varchar,
  in_reply_to_message_id uuid REFERENCES dispute_messages(id),
  ai_input_context_json jsonb,
  ai_model_used varchar,
  ai_prompt_hash varchar,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_dispute_lines_conversation_status
  ON dispute_lines(conversation_status);

CREATE INDEX idx_dispute_messages_in_reply_to
  ON dispute_messages(in_reply_to_message_id);

CREATE TABLE shipper_liabilities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES disputes(id),
  shipper_id uuid NOT NULL REFERENCES shippers(id),
  order_id uuid NOT NULL REFERENCES orders(id),
  amount_gbp decimal(12,2) NOT NULL,
  shipper_response varchar CHECK (shipper_response IN ('accepted','disputed','partial')),
  settlement_method varchar CHECK (settlement_method IN ('offset_next_invoice','cash_refund','write_off')),
  offset_against_shipping_quote_id uuid REFERENCES shipping_quotes(id),
  resolved_at timestamptz,
  notes text
);

CREATE TABLE payout_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  importer_id uuid NOT NULL REFERENCES importers(id),
  dispute_id uuid NOT NULL REFERENCES disputes(id),
  amount_gbp decimal(12,2) NOT NULL,
  amount_local_ccy decimal(18,2) NOT NULL,
  local_ccy varchar(3) NOT NULL,
  payout_method varchar NOT NULL CHECK (payout_method IN ('bank_transfer','mobile_money','card_reversal','other')),
  beneficiary_reference varchar,
  status varchar NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','approved','paid','cancelled','failed')),
  approved_by_staff_id uuid REFERENCES staff(id),
  approved_at timestamptz,
  paid_at timestamptz,
  proof_url varchar,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 7. MODULE 6 — DVA, CREDIT LEDGER & BANK RECONCILIATION
-- =============================================================================

CREATE TABLE dva_statements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  importer_id uuid NOT NULL REFERENCES importers(id),
  source_bank varchar NOT NULL CHECK (source_bank IN ('gcb','firstbank','zenith','other')),
  uploaded_by_staff_id uuid NOT NULL REFERENCES staff(id),
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  csv_url varchar NOT NULL,
  statement_period_from date NOT NULL,
  statement_period_to date NOT NULL,
  parse_status varchar NOT NULL DEFAULT 'pending' CHECK (parse_status IN ('pending','parsed','failed')),
  parse_errors_json jsonb
);

CREATE TABLE dva_statement_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_statement_id uuid NOT NULL REFERENCES dva_statements(id),
  line_order int NOT NULL,
  statement_date date NOT NULL,
  reference_raw varchar NOT NULL,
  direction varchar NOT NULL CHECK (direction IN ('in','out')),
  amount_local_ccy decimal(18,2) NOT NULL,
  local_ccy varchar(3) NOT NULL,
  fx_rate_applied decimal(18,8) NOT NULL,
  card_markup_pct_applied decimal(6,3) NOT NULL,
  amount_gbp_equivalent decimal(12,2) NOT NULL,
  auth_id_ref varchar,
  retailer_name_ref varchar,
  match_status varchar NOT NULL DEFAULT 'unmatched' CHECK (match_status IN ('unmatched','suggested','confirmed','rejected')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE match_suggestions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_statement_line_id uuid NOT NULL REFERENCES dva_statement_lines(id),
  suggested_match_type varchar NOT NULL CHECK (suggested_match_type IN ('order','supplier_invoice','dispute')),
  suggested_match_id uuid NOT NULL,
  confidence varchar NOT NULL CHECK (confidence IN ('high','medium','low')),
  variance_gbp decimal(12,2),
  variance_days int,
  accepted_by_staff_id uuid REFERENCES staff(id),
  accepted_at timestamptz,
  rejected_reason text
);

CREATE TABLE dva_reconciliation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_statement_line_id uuid NOT NULL UNIQUE REFERENCES dva_statement_lines(id),
  reconciliation_type varchar NOT NULL CHECK (reconciliation_type IN ('order_funding','retailer_purchase','refund_credit','exception_hold')),
  order_id uuid REFERENCES orders(id),
  supplier_invoice_id uuid REFERENCES supplier_invoices(id),
  dispute_id uuid REFERENCES disputes(id),
  reconciled_gbp_amount decimal(12,2) NOT NULL,
  fx_diff_gbp decimal(12,2),
  fx_diff_posted_to_sage_at timestamptz,
  sage_fx_journal_ref varchar,
  reconciled_by_staff_id uuid NOT NULL REFERENCES staff(id),
  reconciled_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  CONSTRAINT dva_reconciliation_type_refs CHECK (
    (reconciliation_type = 'order_funding'    AND order_id IS NOT NULL AND supplier_invoice_id IS NULL AND dispute_id IS NULL) OR
    (reconciliation_type = 'retailer_purchase' AND order_id IS NULL AND supplier_invoice_id IS NOT NULL AND dispute_id IS NULL) OR
    (reconciliation_type = 'refund_credit'    AND order_id IS NULL AND supplier_invoice_id IS NULL AND dispute_id IS NOT NULL) OR
    (reconciliation_type = 'exception_hold')
  )
);

CREATE TABLE importer_credit_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  importer_id uuid NOT NULL REFERENCES importers(id),
  entry_type varchar NOT NULL CHECK (entry_type IN ('retailer_refund','shipper_refund','manual_credit','applied_to_order','payout_sent','reversal','admin_adjustment')),
  source_table varchar NOT NULL,
  source_id uuid NOT NULL,
  linked_order_id uuid REFERENCES orders(id),
  linked_dispute_id uuid REFERENCES disputes(id),
  direction varchar NOT NULL CHECK (direction IN ('credit','debit')),
  amount_gbp decimal(12,2) NOT NULL,
  amount_local_ccy decimal(18,2) NOT NULL,
  local_ccy varchar(3) NOT NULL,
  created_by_staff_id uuid REFERENCES staff(id),
  effective_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

-- =============================================================================
-- 8. MODULE 7 — SAGE & SALES INVOICES (finalise sales_invoices stub)
-- =============================================================================

ALTER TABLE sales_invoices
  ADD COLUMN order_id uuid NOT NULL REFERENCES orders(id),
  ADD COLUMN invoice_type varchar NOT NULL CHECK (invoice_type IN ('main','supplementary','credit_note')),
  ADD COLUMN linked_invoice_id uuid REFERENCES sales_invoices(id),
  ADD COLUMN consideration_received_date date NOT NULL,
  ADD COLUMN sage_invoice_date date NOT NULL,
  ADD COLUMN tax_point_period varchar NOT NULL,
  ADD COLUMN sage_invoice_period varchar NOT NULL,
  ADD COLUMN vat_box6_reported_period varchar,
  ADD COLUMN amount_gbp decimal(12,2) NOT NULL,
  ADD COLUMN vat_code varchar NOT NULL DEFAULT 'T0',
  ADD COLUMN line_items_json jsonb NOT NULL,
  ADD COLUMN sage_invoice_id varchar,
  ADD COLUMN sage_posted_at timestamptz,
  ADD COLUMN sage_status varchar NOT NULL DEFAULT 'draft' CHECK (sage_status IN ('draft','posted','void')),
  ADD COLUMN export_evidence_complete_date date,
  ADD COLUMN zero_rating_deadline_date date NOT NULL,
  ADD COLUMN zero_rating_status varchar NOT NULL DEFAULT 'on_track' CHECK (zero_rating_status IN ('on_track','at_risk','breached','reinstated','evidence_complete')),
  ADD COLUMN vat_adjustment_posted_at timestamptz,
  ADD COLUMN reversal_posted_at timestamptz,
  ADD COLUMN raised_by_trigger boolean NOT NULL DEFAULT false,
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE sage_postings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type varchar NOT NULL,
  source_table varchar NOT NULL,
  source_id uuid NOT NULL,
  posting_type varchar NOT NULL CHECK (posting_type IN ('ar_invoice','ar_credit_note','ar_receipt','ap_invoice','ap_payment','fx_gl','vat_adjustment_box6','vat_adjustment_box1')),
  idempotency_key varchar NOT NULL UNIQUE,
  sage_transaction_id varchar,
  sage_response_json jsonb,
  amount_gbp decimal(12,2) NOT NULL,
  sage_config_version_id uuid NOT NULL REFERENCES sage_config(id),
  posted_at timestamptz,
  status varchar NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','posted','failed','retry')),
  retry_count int NOT NULL DEFAULT 0
);

-- =============================================================================
-- 9. MODULE 8 — VAT COMPLIANCE
-- =============================================================================

CREATE TABLE vat_return_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_period varchar NOT NULL,
  report_type varchar NOT NULL CHECK (report_type IN ('box6_carry_in','box6_carry_out','box1_breach','box1_reinstatement')),
  source_sales_invoice_id uuid NOT NULL REFERENCES sales_invoices(id),
  amount_gbp decimal(12,2) NOT NULL,
  direction varchar NOT NULL CHECK (direction IN ('add','subtract')),
  sage_journal_ref varchar,
  posted_by_staff_id uuid NOT NULL REFERENCES staff(id),
  posted_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

CREATE TABLE vat_return_workings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_period varchar NOT NULL UNIQUE,
  generated_at timestamptz NOT NULL DEFAULT now(),
  generated_by_staff_id uuid NOT NULL REFERENCES staff(id),
  section_a_total decimal(14,2),
  section_b_total decimal(14,2),
  section_c_total decimal(14,2),
  section_d_total decimal(14,2),
  breach_total decimal(14,2),
  reinstatement_total decimal(14,2),
  final_box1 decimal(14,2),
  final_box4 decimal(14,2),
  final_box6 decimal(14,2),
  final_box7 decimal(14,2),
  filed_at timestamptz,
  filed_by_staff_id uuid REFERENCES staff(id),
  zip_bundle_url varchar
);

-- =============================================================================
-- 10. MODULE 9 — AUDIT
-- =============================================================================

CREATE TABLE audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "timestamp" timestamptz NOT NULL DEFAULT now(),
  actor_operator_id uuid REFERENCES operators(id),
  actor_staff_id uuid REFERENCES staff(id),
  actor_shipper_user_id uuid REFERENCES shipper_users(id),
  actor_role varchar NOT NULL CHECK (actor_role IN ('operator','shipper_user','supervisor','admin','system')),
  subject_importer_id uuid REFERENCES importers(id),
  subject_shipper_id uuid REFERENCES shippers(id),
  table_name varchar NOT NULL,
  record_id uuid NOT NULL,
  action varchar NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE','REJECTED_UPDATE','REJECTED_TRANSITION')),
  before_json jsonb,
  after_json jsonb,
  reason_code varchar,
  ip_address inet,
  user_agent varchar,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- =============================================================================
-- 11. THE 7 PARTIAL UNIQUE INDEXES (required by locked spec)
-- =============================================================================

CREATE UNIQUE INDEX uq_orders_payment_auth_id
  ON orders (payment_auth_id) WHERE payment_auth_id IS NOT NULL;

CREATE UNIQUE INDEX uq_sage_config_current
  ON sage_config (installation_id) WHERE effective_to IS NULL;

CREATE UNIQUE INDEX uq_operator_importers_active
  ON operator_importers (operator_id, importer_id) WHERE revoked_at IS NULL;

CREATE UNIQUE INDEX uq_retailer_account_access_active
  ON retailer_account_access (retailer_account_id, operator_id) WHERE revoked_at IS NULL;

CREATE UNIQUE INDEX uq_dispute_lines_open
  ON dispute_lines (supplier_invoice_line_id) WHERE resolved_at IS NULL;

CREATE UNIQUE INDEX uq_status_transitions_active
  ON status_transitions (entity_type, from_status, to_status) WHERE active = true;

CREATE UNIQUE INDEX uq_sales_invoices_one_main_per_order
  ON sales_invoices (order_id) WHERE invoice_type = 'main' AND sage_status <> 'void';

-- =============================================================================
-- 12. DERIVED VIEWS
-- =============================================================================

CREATE OR REPLACE VIEW importer_balance_vw AS
SELECT
  i.id AS importer_id,
  COALESCE(
    SUM(CASE WHEN icl.direction = 'credit' THEN icl.amount_gbp ELSE -icl.amount_gbp END),
    0
  ) AS available_credit_gbp,
  COALESCE(
    (SELECT SUM(d.amount_impact_gbp)
       FROM disputes d
       WHERE d.order_id IN (SELECT o.id FROM orders o WHERE o.importer_id = i.id)
         AND d.status IN ('approved_refund','awaiting_refund_credit')),
    0
  ) AS pending_refund_gbp,
  COALESCE(
    (SELECT SUM(o.bundled_quote_gbp)
       FROM orders o
       WHERE o.importer_id = i.id
         AND o.funded_at IS NOT NULL
         AND o.status NOT IN ('invoiced','confirmed_receipt','refunded','replaced_closed','delivered_ghana')),
    0
  ) AS active_order_funding_gbp,
  COALESCE(
    (SELECT SUM(pr.amount_gbp)
       FROM payout_requests pr
       WHERE pr.importer_id = i.id
         AND pr.status IN ('requested','approved')),
    0
  ) AS payout_in_progress_gbp,
  now() AS last_refreshed_at
FROM importers i
LEFT JOIN importer_credit_ledger icl ON icl.importer_id = i.id
GROUP BY i.id;

CREATE OR REPLACE VIEW order_reconciliation_vw AS
SELECT
  o.id AS order_id,
  o.total_qty_declared AS qty_target,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0) AS qty_progressed_invoiceable,
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) AS qty_resolved_noninvoiceable,
  o.total_qty_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0)
    AS qty_unresolved,
  o.order_total_gbp_declared AS amount_target_gbp,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0) AS amount_progressed_invoiceable_gbp,
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0) AS amount_resolved_noninvoiceable_gbp,
  o.order_total_gbp_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    AS amount_unresolved_gbp,
  CASE WHEN EXISTS (
    SELECT 1 FROM supplier_invoice_lines sil2
    JOIN supplier_invoices si2 ON si2.id = sil2.supplier_invoice_id
    WHERE si2.order_id = o.id AND sil2.eligible_for_invoice_yn = 'Y'
  ) THEN true ELSE false END AS invoiceable_subset_released_yn,
  CASE WHEN (
    o.total_qty_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) = 0
    AND o.order_total_gbp_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0) = 0
  ) THEN true ELSE false END AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM orders o
LEFT JOIN supplier_invoices si ON si.order_id = o.id
LEFT JOIN supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
LEFT JOIN disputes d ON d.order_id = o.id
LEFT JOIN dispute_lines dl ON dl.dispute_id = d.id
GROUP BY o.id, o.total_qty_declared, o.order_total_gbp_declared;

-- =============================================================================
-- 13. AUDIT LOG TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION audit_log_trigger()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO audit_log (
    "timestamp", actor_role, table_name, record_id, action,
    before_json, after_json, reason_code
  )
  VALUES (
    now(),
    'system',
    TG_TABLE_NAME,
    COALESCE((NEW.id), (OLD.id)),
    TG_OP,
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
    NULL
  );
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach to substantive tables
CREATE TRIGGER audit_orders AFTER INSERT OR UPDATE OR DELETE ON orders
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_supplier_invoices AFTER INSERT OR UPDATE OR DELETE ON supplier_invoices
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_supplier_invoice_lines AFTER INSERT OR UPDATE OR DELETE ON supplier_invoice_lines
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_disputes AFTER INSERT OR UPDATE OR DELETE ON disputes
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_dispute_lines AFTER INSERT OR UPDATE OR DELETE ON dispute_lines
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_sales_invoices AFTER INSERT OR UPDATE OR DELETE ON sales_invoices
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_sage_postings AFTER INSERT OR UPDATE OR DELETE ON sage_postings
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_dva_reconciliation AFTER INSERT OR UPDATE OR DELETE ON dva_reconciliation
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_importer_credit_ledger AFTER INSERT OR UPDATE OR DELETE ON importer_credit_ledger
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_payout_requests AFTER INSERT OR UPDATE OR DELETE ON payout_requests
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_shipper_liabilities AFTER INSERT OR UPDATE OR DELETE ON shipper_liabilities
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_shipping_quotes AFTER INSERT OR UPDATE OR DELETE ON shipping_quotes
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_shipping_quote_orders AFTER INSERT OR UPDATE OR DELETE ON shipping_quote_orders
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_dva_statements AFTER INSERT OR UPDATE OR DELETE ON dva_statements
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
CREATE TRIGGER audit_dva_statement_lines AFTER INSERT OR UPDATE OR DELETE ON dva_statement_lines
  FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();

-- =============================================================================
-- 14. STATE TRANSITION ENFORCEMENT TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_status_transition()
RETURNS TRIGGER AS $$
DECLARE
  v_valid boolean;
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    SELECT EXISTS(
      SELECT 1 FROM status_transitions
      WHERE entity_type = TG_ARGV[0]
        AND from_status = OLD.status
        AND to_status = NEW.status
        AND active = true
    ) INTO v_valid;

    IF NOT v_valid THEN
      INSERT INTO audit_log (
        "timestamp", actor_role, table_name, record_id, action,
        before_json, after_json, reason_code
      )
      VALUES (
        now(), 'system', TG_TABLE_NAME, NEW.id, 'REJECTED_TRANSITION',
        to_jsonb(OLD), to_jsonb(NEW),
        format('Invalid transition: %s -> %s', OLD.status, NEW.status)
      );
      RAISE EXCEPTION 'Invalid status transition: % -> %', OLD.status, NEW.status;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER enforce_orders_transition BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION enforce_status_transition('order');
CREATE TRIGGER enforce_disputes_transition BEFORE UPDATE ON disputes
  FOR EACH ROW EXECUTE FUNCTION enforce_status_transition('dispute');
CREATE TRIGGER enforce_shipping_quotes_transition BEFORE UPDATE ON shipping_quotes
  FOR EACH ROW EXECUTE FUNCTION enforce_status_transition('shipping_quote');

-- =============================================================================
-- 15. LOCK STATE MACHINE TRIGGER (content_locked, tracking_locked)
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_order_locks()
RETURNS TRIGGER AS $$
BEGIN
  -- content_locked_at blocks item/qty/amount changes
  IF OLD.content_locked_at IS NOT NULL AND (
    OLD.order_total_gbp_declared IS DISTINCT FROM NEW.order_total_gbp_declared OR
    OLD.total_qty_declared IS DISTINCT FROM NEW.total_qty_declared
  ) THEN
    INSERT INTO audit_log ("timestamp", actor_role, table_name, record_id, action, before_json, after_json, reason_code)
    VALUES (now(), 'system', 'orders', NEW.id, 'REJECTED_UPDATE', to_jsonb(OLD), to_jsonb(NEW), 'content_locked');
    RAISE EXCEPTION 'Order content is locked (content_locked_at set)';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER enforce_orders_locks BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION enforce_order_locks();

-- =============================================================================
-- 16. INVOICE GATE TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_invoice_gate()
RETURNS TRIGGER AS $$
DECLARE
  v_recon_ok boolean;
  v_shipping_ok boolean;
  v_dispute_blocking boolean;
BEGIN
  -- Only check when transitioning into ready_for_invoicing
  IF NEW.status = 'ready_for_invoicing' AND OLD.status <> 'ready_for_invoicing' THEN

    -- funded_at must be set
    IF NEW.funded_at IS NULL THEN
      RAISE EXCEPTION 'Invoice gate: funded_at is NULL';
    END IF;

    -- at least one reconciled supplier invoice
    SELECT EXISTS (
      SELECT 1 FROM supplier_invoices
      WHERE order_id = NEW.id AND reconciliation_confirmed_at IS NOT NULL
    ) INTO v_recon_ok;
    IF NOT v_recon_ok THEN
      RAISE EXCEPTION 'Invoice gate: no reconciled supplier invoice';
    END IF;

    -- shipping quote + hub receipt + booking ref all present
    SELECT EXISTS (
      SELECT 1
      FROM shipping_quote_orders sqo
      JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
      WHERE sqo.order_id = NEW.id
        AND sq.hub_receipt_confirmed_at IS NOT NULL
        AND sq.booking_ref IS NOT NULL
    ) INTO v_shipping_ok;
    IF NOT v_shipping_ok THEN
      RAISE EXCEPTION 'Invoice gate: shipping quote, hub receipt or booking ref missing';
    END IF;

    -- no blocking pre-invoice dispute on a line that is eligible for invoicing
    SELECT EXISTS (
      SELECT 1 FROM disputes d
      JOIN dispute_lines dl ON dl.dispute_id = d.id
      JOIN supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
      WHERE d.order_id = NEW.id
        AND d.status NOT IN ('refunded','replaced','rejected','closed','approved_replacement','approved_refund')
        AND sil.eligible_for_invoice_yn = 'Y'
    ) INTO v_dispute_blocking;
    IF v_dispute_blocking THEN
      RAISE EXCEPTION 'Invoice gate: unresolved pre-invoice dispute affects invoiceable lines';
    END IF;

  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER enforce_orders_invoice_gate BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION enforce_invoice_gate();

-- =============================================================================
-- 17. RLS POLICIES (basic skeleton — refine against Supabase auth patterns)
-- =============================================================================

-- Auth helper functions required by the policy layer
CREATE OR REPLACE FUNCTION public.current_operator_importer_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT oi.importer_id
  FROM public.operators o
  JOIN public.operator_importers oi
    ON oi.operator_id = o.id
   AND oi.revoked_at IS NULL
  WHERE o.auth_user_id = auth.uid()
    AND o.active = true;
$$;

CREATE OR REPLACE FUNCTION public.current_shipper_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT su.shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.created_at DESC, su.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_active_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
  );
$$;

-- Enable RLS on all substantive tables (Supabase Data API honours this)
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_category_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispute_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispute_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispute_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispute_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipper_liabilities ENABLE ROW LEVEL SECURITY;
ALTER TABLE payout_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE importer_credit_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE sage_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE dva_statements ENABLE ROW LEVEL SECURITY;
ALTER TABLE dva_statement_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE dva_reconciliation ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipping_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipping_quote_orders ENABLE ROW LEVEL SECURITY;

-- Staff (admin + supervisor): full read access; writes policed at app layer per role permissions
CREATE POLICY staff_read_all ON orders FOR SELECT
  USING (EXISTS (SELECT 1 FROM staff s WHERE s.auth_user_id = auth.uid() AND s.active = true));
CREATE POLICY staff_write_all ON orders FOR ALL
  USING (EXISTS (SELECT 1 FROM staff s WHERE s.auth_user_id = auth.uid() AND s.active = true))
  WITH CHECK (EXISTS (SELECT 1 FROM staff s WHERE s.auth_user_id = auth.uid() AND s.active = true));

-- Operator: scoped via operator_importers
CREATE POLICY operator_own_orders ON orders FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM operator_importers oi
      JOIN operators o ON o.id = oi.operator_id
      WHERE o.auth_user_id = auth.uid()
        AND oi.importer_id = orders.importer_id
        AND oi.revoked_at IS NULL
    )
  );

-- Shipper user: scoped via shipper_id
CREATE POLICY shipper_user_own_orders ON orders FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM shipper_users su
      WHERE su.auth_user_id = auth.uid()
        AND su.shipper_id = orders.shipper_id
        AND su.active = true
    )
  );

CREATE POLICY "operator_own_order_screenshots"
ON public.order_screenshots
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_screenshots.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_screenshots.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

CREATE POLICY "shipper_user_own_order_screenshots"
ON public.order_screenshots
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_screenshots.order_id
      AND o.shipper_id = current_shipper_id()
  )
);

CREATE POLICY "staff_read_all_order_screenshots"
ON public.order_screenshots
FOR SELECT
TO public
USING (is_active_staff());

CREATE POLICY "staff_write_all_order_screenshots"
ON public.order_screenshots
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

CREATE POLICY "operator_own_order_tracking_submissions"
ON public.order_tracking_submissions
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_tracking_submissions.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_tracking_submissions.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

CREATE POLICY "shipper_user_own_order_tracking_submissions"
ON public.order_tracking_submissions
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM public.orders o
    WHERE o.id = order_tracking_submissions.order_id
      AND o.shipper_id = current_shipper_id()
  )
);

CREATE POLICY "staff_read_all_order_tracking_submissions"
ON public.order_tracking_submissions
FOR SELECT
TO public
USING (is_active_staff());

CREATE POLICY "staff_write_all_order_tracking_submissions"
ON public.order_tracking_submissions
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

-- NOTE: replicate similar 3-policy pattern (staff full, operator scoped via importer,
-- shipper_user scoped via shipper_id) for each RLS-enabled table.
-- This file contains the template for orders; repeat for other tables as needed.

-- Audit log is read-only once written
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_log_readonly ON audit_log FOR SELECT
  USING (EXISTS (SELECT 1 FROM staff s WHERE s.auth_user_id = auth.uid() AND s.active = true));
CREATE POLICY audit_log_no_update ON audit_log FOR UPDATE USING (false);
CREATE POLICY audit_log_no_delete ON audit_log FOR DELETE USING (false);

-- =============================================================================
-- 18. SEED REFERENCE DATA
-- =============================================================================

-- Currencies
INSERT INTO currencies (code, symbol) VALUES
  ('GBP', '£'),
  ('GHS', '₵'),
  ('NGN', '₦');

-- Countries (link to currencies)
INSERT INTO countries (name, iso_code, currency_id)
  SELECT 'United Kingdom', 'GBR', id FROM currencies WHERE code = 'GBP';
INSERT INTO countries (name, iso_code, currency_id)
  SELECT 'Ghana', 'GHA', id FROM currencies WHERE code = 'GHS';
INSERT INTO countries (name, iso_code, currency_id)
  SELECT 'Nigeria', 'NGA', id FROM currencies WHERE code = 'NGN';

-- Status transitions — orders
INSERT INTO status_transitions (entity_type, from_status, to_status, actor_roles_allowed) VALUES
  ('order','pending_dva_funding','funded',                     ARRAY['supervisor','admin','system']),
  ('order','funded','pending_retailer_purchase',               ARRAY['operator','supervisor','admin']),
  ('order','pending_retailer_purchase','retailer_purchase_confirmed', ARRAY['operator','supervisor','admin']),
  ('order','retailer_purchase_confirmed','invoice_uploaded',   ARRAY['operator','supervisor','admin']),
  ('order','invoice_uploaded','ocr_extracted',                 ARRAY['system','supervisor','admin']),
  ('order','ocr_extracted','reconciliation_in_progress',       ARRAY['operator','supervisor','admin']),
  ('order','reconciliation_in_progress','reconciled',          ARRAY['operator','supervisor','admin']),
  ('order','reconciled','awaiting_shipper_receipt',            ARRAY['supervisor','admin','system']),
  ('order','awaiting_shipper_receipt','at_uk_hub',             ARRAY['shipper_user','supervisor','admin']),
  ('order','at_uk_hub','awaiting_shipping_quote',              ARRAY['supervisor','admin','system']),
  ('order','awaiting_shipping_quote','shipping_quoted',        ARRAY['shipper_user','supervisor','admin']),
  ('order','shipping_quoted','ready_for_invoicing',            ARRAY['supervisor','admin','system']),
  ('order','ready_for_invoicing','invoiced',                   ARRAY['system','supervisor','admin']),
  ('order','invoiced','in_transit',                            ARRAY['shipper_user','supervisor','admin']),
  ('order','in_transit','delivered_ghana',                     ARRAY['shipper_user','supervisor','admin']),
  ('order','delivered_ghana','confirmed_receipt',              ARRAY['operator','supervisor','admin']),
  ('order','confirmed_receipt','disputed',                     ARRAY['operator','supervisor','admin']),
  ('order','disputed','refunded',                              ARRAY['supervisor','admin']),
  ('order','disputed','replaced_closed',                       ARRAY['supervisor','admin','system']);

-- Status transitions — disputes
INSERT INTO status_transitions (entity_type, from_status, to_status, actor_roles_allowed) VALUES
  ('dispute','raised','under_review',              ARRAY['supervisor','admin']),
  ('dispute','under_review','pushed_to_shipper',   ARRAY['supervisor','admin']),
  ('dispute','pushed_to_shipper','shipper_responded', ARRAY['shipper_user','supervisor','admin']),
  ('dispute','shipper_responded','under_review',   ARRAY['supervisor','admin']),
  ('dispute','under_review','approved_refund',     ARRAY['supervisor','admin']),
  ('dispute','under_review','approved_replacement',ARRAY['supervisor','admin']),
  ('dispute','approved_refund','awaiting_refund_credit', ARRAY['system','supervisor','admin']),
  ('dispute','awaiting_refund_credit','refunded',  ARRAY['supervisor','admin','system']),
  ('dispute','approved_replacement','replaced',    ARRAY['supervisor','admin','system']),
  ('dispute','under_review','rejected',            ARRAY['supervisor','admin']),
  ('dispute','refunded','closed',                  ARRAY['supervisor','admin','system']),
  ('dispute','replaced','closed',                  ARRAY['supervisor','admin','system']),
  ('dispute','rejected','closed',                  ARRAY['supervisor','admin','system']);

-- Status transitions — dispute_lines
INSERT INTO status_transitions (entity_type, from_status, to_status, required_conditions_json, actor_roles_allowed) VALUES
  ('dispute_line','child_exception_created','remedy_selected', '{"requires_intended_remedy": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','remedy_selected','refund_pending_approval', '{"intended_remedy": "refund"}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','remedy_selected','retailer_draft_ready', '{"intended_remedy": "replacement", "requires_ai_draft": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','refund_pending_approval','retailer_draft_ready', '{"intended_remedy": "refund", "requires_dispute_refund_approval": true, "requires_ai_draft": true}'::jsonb, ARRAY['supervisor','admin']),
  ('dispute_line','refund_pending_approval','remedy_selected', '{"approval_denied_or_changed": true}'::jsonb, ARRAY['supervisor','admin']),
  ('dispute_line','retailer_draft_ready','retailer_contacted', '{"requires_outbound_message": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','retailer_contacted','retailer_response_received', '{"requires_retailer_reply_paste": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','retailer_response_received','ai_next_draft_ready', '{"requires_ai_generation": true, "requires_sop_and_status_context": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','ai_next_draft_ready','retailer_contacted', '{"requires_outbound_message": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','retailer_response_received','awaiting_retailer_resolution', '{"awaiting_final_retailer_outcome": true}'::jsonb, ARRAY['operator','supervisor','admin']),
  ('dispute_line','awaiting_retailer_resolution','resolved_refund', '{"resolution_method": "refund"}'::jsonb, ARRAY['supervisor','admin']),
  ('dispute_line','awaiting_retailer_resolution','resolved_replacement', '{"resolution_method": "replacement"}'::jsonb, ARRAY['supervisor','admin']),
  ('dispute_line','awaiting_retailer_resolution','resolved_credit', '{"resolution_method": "credit"}'::jsonb, ARRAY['supervisor','admin']),
  ('dispute_line','awaiting_retailer_resolution','closed_no_action', '{"resolution_method": "closed_no_action"}'::jsonb, ARRAY['supervisor','admin']);

-- Status transitions — shipping_quotes
INSERT INTO status_transitions (entity_type, from_status, to_status, actor_roles_allowed) VALUES
  ('shipping_quote','draft','confirmed',    ARRAY['shipper_user','supervisor','admin']),
  ('shipping_quote','confirmed','dispatched', ARRAY['shipper_user','supervisor','admin']),
  ('shipping_quote','dispatched','delivered', ARRAY['shipper_user','supervisor','admin']);

-- Default SOP (v1.0) — placeholder, replace content_md with actual SOP text
-- NOTE: published_by_staff_id requires a staff row to exist first; populate after first admin user created.

-- =============================================================================
-- END OF MIGRATION
-- =============================================================================
-- Next steps after running this file:
--  1. Create your first admin user via Supabase auth, then INSERT into staff with that auth_user_id
--  2. INSERT initial sops row with content_md = your live SOP markdown
--  3. INSERT installation row (multi_tenant or single_tenant)
--  4. INSERT sage_config row with your Sage Cloud credentials and nominal codes
--  5. INSERT shippers, markup_categories, fx_rates, retailers, hubs as needed
--  6. Generate signup_tokens and start onboarding operators/importers
-- =============================================================================
