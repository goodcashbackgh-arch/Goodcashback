-- =============================================================================
-- closure_v2_migration.sql
-- Multi Tenant Platform Build — additive Phase 1 closure migration
-- Governing sources:
--   1. Architecture Completion Addendum v2
--   2. Canonical Schema Reference v1
--   3. SAGE_POSTING_MATRIX_v1
--
-- Baseline expected:
--   goodcashback-complete.v3.sql already applied.
--
-- Scope of this migration:
--   * schema-only / data-normalisation changes
--   * no permanent functions, triggers, views, or seed data here
--   * no multi-shipper-per-order architecture in Phase 1
--
-- Companion files expected after this migration:
--   * closure_v2_functions.sql
--   * closure_v2_seed.sql
-- =============================================================================

BEGIN;

-- =============================================================================
-- 0. Defensive settings
-- =============================================================================
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 1. PHASE 1 GUARDRAILS / COMMENTS
-- =============================================================================
COMMENT ON COLUMN orders.shipper_id IS
'Phase 1 active shipper lane for the order. Do not deprecate in Phase 1. One active shipper lane per original/replacement child order.';

COMMENT ON COLUMN orders.screenshot_url IS
'Legacy / backward-compat only. New screenshot flows must use order_screenshots.';

-- =============================================================================
-- 2. ORDERS — canonical parent-order state model, quote FX lock fields,
--    VAT/accounting release fields, and replacement-child standardisation
-- =============================================================================

-- 2.1 Additive columns
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS quote_fx_rate_locked decimal(18,8),
  ADD COLUMN IF NOT EXISTS quote_card_markup_pct_locked decimal(9,6),
  ADD COLUMN IF NOT EXISTS quote_rate_date_locked date,
  ADD COLUMN IF NOT EXISTS quote_rate_locked_at timestamptz,
  ADD COLUMN IF NOT EXISTS vat_rate_applied varchar,
  ADD COLUMN IF NOT EXISTS vat_tax_point_date date,
  ADD COLUMN IF NOT EXISTS vat_return_period date,
  ADD COLUMN IF NOT EXISTS vat_release_approved_by_staff_id uuid REFERENCES staff(id),
  ADD COLUMN IF NOT EXISTS vat_release_approved_at timestamptz,
  ADD COLUMN IF NOT EXISTS vat_release_evidence_json jsonb,
  ADD COLUMN IF NOT EXISTS accounting_release_ready_at timestamptz,
  ADD COLUMN IF NOT EXISTS accounting_release_ready_by_staff_id uuid REFERENCES staff(id),
  ADD COLUMN IF NOT EXISTS replacement_source_dispute_line_id uuid REFERENCES dispute_lines(id);

-- 2.2 Best-effort backfill for locked quote snapshot fields from existing quote data
UPDATE orders
SET quote_fx_rate_locked = COALESCE(quote_fx_rate_locked, quote_fx_rate),
    quote_card_markup_pct_locked = COALESCE(quote_card_markup_pct_locked, quote_card_markup_pct),
    quote_rate_date_locked = COALESCE(quote_rate_date_locked, created_at::date),
    quote_rate_locked_at = COALESCE(quote_rate_locked_at, created_at)
WHERE quote_fx_rate IS NOT NULL
   OR quote_card_markup_pct IS NOT NULL;

-- 2.3 Standardise order_type literals to Phase 1 canonical values
UPDATE orders
SET order_type = CASE
  WHEN order_type = 'main' THEN 'original'
  WHEN order_type = 'replacement' THEN 'replacement_child'
  ELSE order_type
END
WHERE order_type IN ('main','replacement');

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_order_type_check;
ALTER TABLE orders
  ADD CONSTRAINT orders_order_type_check
  CHECK (order_type IN ('original','replacement_child'));
ALTER TABLE orders ALTER COLUMN order_type SET DEFAULT 'original';

COMMENT ON COLUMN orders.order_type IS
'Phase 1 literals: original | replacement_child. Replacement child is a continuation path, not a fresh funded commercial order.';

-- 2.4 Normalise parent-order statuses into the canonical Phase 1 set
UPDATE orders o
SET status = CASE
  WHEN o.status IN (
    'draft',
    'pending_dva_funding',
    'evidence_collecting',
    'reconciling',
    'partially_progressed',
    'ready_for_shipment',
    'shipment_booked',
    'shipment_dispatched',
    'awaiting_importer_receipt',
    'discrepancy_open',
    'awaiting_financial_closure',
    'completed',
    'archived',
    'cancelled'
  ) THEN o.status

  WHEN o.completed_at IS NOT NULL THEN 'completed'
  WHEN o.status IN ('disputed') THEN 'discrepancy_open'
  WHEN o.status IN ('confirmed_receipt','refunded','replaced_closed') THEN 'awaiting_financial_closure'

  WHEN EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = o.id
      AND sq.ghana_delivered_at IS NOT NULL
  ) THEN 'awaiting_importer_receipt'

  WHEN EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = o.id
      AND sq.dispatched_at IS NOT NULL
  ) THEN 'shipment_dispatched'

  WHEN EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = o.id
      AND sq.booking_ref IS NOT NULL
  ) THEN 'shipment_booked'

  WHEN o.status IN ('reconciled','awaiting_shipper_receipt','at_uk_hub','awaiting_shipping_quote','shipping_quoted','ready_for_invoicing','invoiced','in_transit','delivered_ghana') THEN 'ready_for_shipment'
  WHEN o.status IN ('reconciliation_in_progress','ocr_extracted','invoice_uploaded') THEN 'reconciling'
  WHEN o.status IN ('pending_retailer_purchase','retailer_purchase_confirmed') THEN 'evidence_collecting'
  WHEN o.status = 'funded' THEN 'pending_dva_funding'
  ELSE 'pending_dva_funding'
END;

ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_status_check;
ALTER TABLE orders
  ADD CONSTRAINT orders_status_check
  CHECK (status IN (
    'draft',
    'pending_dva_funding',
    'evidence_collecting',
    'reconciling',
    'partially_progressed',
    'ready_for_shipment',
    'shipment_booked',
    'shipment_dispatched',
    'awaiting_importer_receipt',
    'discrepancy_open',
    'awaiting_financial_closure',
    'completed',
    'archived',
    'cancelled'
  ));
ALTER TABLE orders ALTER COLUMN status SET DEFAULT 'pending_dva_funding';

-- 2.5 VAT field checks
ALTER TABLE orders DROP CONSTRAINT IF EXISTS orders_vat_rate_applied_check;
ALTER TABLE orders
  ADD CONSTRAINT orders_vat_rate_applied_check
  CHECK (vat_rate_applied IS NULL OR vat_rate_applied IN ('zero_rated','standard_rated','exempt','out_of_scope'));

CREATE INDEX IF NOT EXISTS idx_orders_status
  ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_parent_order_id
  ON orders(parent_order_id);
CREATE INDEX IF NOT EXISTS idx_orders_vat_release
  ON orders(vat_release_approved_at, vat_return_period);
CREATE INDEX IF NOT EXISTS idx_orders_accounting_release
  ON orders(accounting_release_ready_at);

-- =============================================================================
-- 3. SHIPPING_QUOTES — expand Phase 1 shipment-lane states and VAT evidence checkpoint
-- =============================================================================

ALTER TABLE shipping_quotes
  ADD COLUMN IF NOT EXISTS zero_rating_evidence_complete_at timestamptz,
  ADD COLUMN IF NOT EXISTS zero_rating_evidence_checked_by_staff_id uuid REFERENCES staff(id);

UPDATE shipping_quotes sq
SET status = CASE
  WHEN sq.status IN (
    'draft_quote',
    'confirmed_ready_for_booking',
    'booked',
    'hub_received',
    'dispatched',
    'in_transit',
    'delivered_ghana',
    'closed',
    'cancelled'
  ) THEN sq.status
  WHEN sq.ghana_delivered_at IS NOT NULL OR sq.status = 'delivered' THEN 'delivered_ghana'
  WHEN sq.dispatched_at IS NOT NULL OR sq.status = 'dispatched' THEN 'dispatched'
  WHEN sq.hub_receipt_confirmed_at IS NOT NULL THEN 'hub_received'
  WHEN sq.booking_ref IS NOT NULL THEN 'booked'
  WHEN sq.status = 'confirmed' THEN 'confirmed_ready_for_booking'
  ELSE 'draft_quote'
END;

ALTER TABLE shipping_quotes DROP CONSTRAINT IF EXISTS shipping_quotes_status_check;
ALTER TABLE shipping_quotes
  ADD CONSTRAINT shipping_quotes_status_check
  CHECK (status IN (
    'draft_quote',
    'confirmed_ready_for_booking',
    'booked',
    'hub_received',
    'dispatched',
    'in_transit',
    'delivered_ghana',
    'closed',
    'cancelled'
  ));
ALTER TABLE shipping_quotes ALTER COLUMN status SET DEFAULT 'draft_quote';

CREATE INDEX IF NOT EXISTS idx_shipping_quotes_shipper_status
  ON shipping_quotes(shipper_id, status);
CREATE INDEX IF NOT EXISTS idx_shipping_quotes_zero_rating_complete
  ON shipping_quotes(zero_rating_evidence_complete_at);

-- =============================================================================
-- 4. RETAILER_SOPS — versioning / replay support for AI drafting governance
-- =============================================================================

ALTER TABLE retailer_sops
  ADD COLUMN IF NOT EXISTS content_md text,
  ADD COLUMN IF NOT EXISTS content_hash text,
  ADD COLUMN IF NOT EXISTS active_from timestamptz,
  ADD COLUMN IF NOT EXISTS active_to timestamptz,
  ADD COLUMN IF NOT EXISTS created_by_staff_id uuid REFERENCES staff(id),
  ADD COLUMN IF NOT EXISTS supersedes_id uuid REFERENCES retailer_sops(id);

UPDATE retailer_sops
SET active_from = COALESCE(active_from, effective_date::timestamptz)
WHERE active_from IS NULL;

-- Backfill active_to for deprecated rows where possible
UPDATE retailer_sops
SET active_to = COALESCE(active_to, deprecated_date::timestamptz)
WHERE deprecated_date IS NOT NULL
  AND active_to IS NULL;

-- Keep only the newest active row per retailer before adding the one-active index
WITH ranked AS (
  SELECT id,
         retailer_id,
         ROW_NUMBER() OVER (
           PARTITION BY retailer_id
           ORDER BY COALESCE(effective_date, CURRENT_DATE) DESC, id DESC
         ) AS rn
  FROM retailer_sops
  WHERE active = true
    AND active_to IS NULL
)
UPDATE retailer_sops rs
SET active = false,
    active_to = COALESCE(rs.active_to, now())
FROM ranked r
WHERE rs.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_retailer_sops_one_active
  ON retailer_sops(retailer_id)
  WHERE active = true AND active_to IS NULL;

CREATE INDEX IF NOT EXISTS idx_retailer_sops_active_lookup
  ON retailer_sops(retailer_id, active, active_to);

-- =============================================================================
-- 5. DISPUTE_MESSAGES — AI replay/audit additions
-- =============================================================================

ALTER TABLE dispute_messages
  ADD COLUMN IF NOT EXISTS ai_input_context_json jsonb,
  ADD COLUMN IF NOT EXISTS ai_model_used varchar,
  ADD COLUMN IF NOT EXISTS ai_prompt_hash varchar,
  ADD COLUMN IF NOT EXISTS retailer_sop_version_used uuid REFERENCES retailer_sops(id),
  ADD COLUMN IF NOT EXISTS ai_response_raw text,
  ADD COLUMN IF NOT EXISTS ai_generated_at timestamptz,
  ADD COLUMN IF NOT EXISTS ai_model_parameters_json jsonb,
  ADD COLUMN IF NOT EXISTS human_edited_at timestamptz,
  ADD COLUMN IF NOT EXISTS human_editor_staff_id uuid REFERENCES staff(id);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_retailer_sop_version_used
  ON dispute_messages(retailer_sop_version_used);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_ai_prompt_hash
  ON dispute_messages(ai_prompt_hash);

CREATE INDEX IF NOT EXISTS idx_dispute_messages_ai_model_used
  ON dispute_messages(ai_model_used);

-- =============================================================================
-- 6. ESCALATION RULES / EVENTS — rules-as-data schema for supervisor/admin routing
-- =============================================================================

CREATE TABLE IF NOT EXISTS escalation_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_code text NOT NULL UNIQUE,
  event_type text NOT NULL,
  description text NOT NULL,
  threshold_numeric numeric,
  threshold_interval interval,
  route_to text NOT NULL CHECK (route_to IN ('supervisor','admin')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS escalation_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id uuid NOT NULL REFERENCES escalation_rules(id),
  entity_type text NOT NULL,
  entity_id uuid NOT NULL,
  raised_at timestamptz NOT NULL DEFAULT now(),
  raised_context_json jsonb,
  assigned_to_staff_id uuid REFERENCES staff(id),
  resolved_at timestamptz,
  resolved_by_staff_id uuid REFERENCES staff(id),
  resolution_notes text,
  route text NOT NULL CHECK (route IN ('supervisor','admin'))
);

CREATE INDEX IF NOT EXISTS idx_escalation_events_open
  ON escalation_events(route, raised_at)
  WHERE resolved_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_escalation_events_entity
  ON escalation_events(entity_type, entity_id, resolved_at);

-- =============================================================================
-- 7. IMPORTER_CREDIT_LEDGER — typed source lineage and lock fields
-- =============================================================================

ALTER TABLE importer_credit_ledger
  ADD COLUMN IF NOT EXISTS source_type varchar,
  ADD COLUMN IF NOT EXISTS source_entity_type varchar,
  ADD COLUMN IF NOT EXISTS source_entity_id uuid,
  ADD COLUMN IF NOT EXISTS applied_to_order_id uuid REFERENCES orders(id),
  ADD COLUMN IF NOT EXISTS lock_reason text,
  ADD COLUMN IF NOT EXISTS lock_source_entity_id uuid;

-- Best-effort backfill from legacy entry_type / linked fields
UPDATE importer_credit_ledger
SET source_type = CASE
      WHEN entry_type = 'retailer_refund' THEN 'refund_resolution'
      WHEN entry_type = 'shipper_refund' THEN 'liability_settlement'
      WHEN entry_type IN ('manual_credit','admin_adjustment') THEN 'manual'
      WHEN entry_type = 'applied_to_order' THEN 'credit_application'
      WHEN entry_type = 'payout_sent' THEN 'payout_settlement'
      WHEN entry_type = 'reversal' THEN 'payout_reversal'
      ELSE source_type
    END,
    source_entity_type = COALESCE(source_entity_type, source_table),
    source_entity_id = COALESCE(source_entity_id, source_id),
    applied_to_order_id = COALESCE(applied_to_order_id, linked_order_id)
WHERE source_type IS NULL
   OR source_entity_type IS NULL
   OR source_entity_id IS NULL
   OR (applied_to_order_id IS NULL AND linked_order_id IS NOT NULL);

ALTER TABLE importer_credit_ledger DROP CONSTRAINT IF EXISTS importer_credit_ledger_source_type_check;
ALTER TABLE importer_credit_ledger
  ADD CONSTRAINT importer_credit_ledger_source_type_check
  CHECK (
    source_type IS NULL OR source_type IN (
      'overfunding',
      'refund_resolution',
      'liability_settlement',
      'manual',
      'payout_reversal',
      'credit_application',
      'payout_settlement'
    )
  );

CREATE INDEX IF NOT EXISTS idx_importer_credit_ledger_available_lookup
  ON importer_credit_ledger(importer_id, lock_reason, effective_at);
CREATE INDEX IF NOT EXISTS idx_importer_credit_ledger_applied_to_order
  ON importer_credit_ledger(applied_to_order_id);


-- =============================================================================
-- 8. ORDER_FUNDING_EVENTS — immutable funding overlay log for Phase 1
-- =============================================================================

CREATE TABLE IF NOT EXISTS order_funding_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  event_type varchar NOT NULL CHECK (
    event_type IN (
      'funding_contribution',
      'credit_applied',
      'manual_adjustment',
      'funding_reversed',
      'overfunding_credit_created'
    )
  ),
  amount_gbp decimal(12,2) NOT NULL,
  source_ref varchar,
  source_entity_type varchar,
  source_entity_id uuid,
  created_by_staff_id uuid REFERENCES staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_order_funding_events_source
  ON order_funding_events(event_type, source_entity_type, source_entity_id)
  WHERE source_entity_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_order_funding_events_order_created
  ON order_funding_events(order_id, created_at, id);

CREATE INDEX IF NOT EXISTS idx_order_funding_events_type
  ON order_funding_events(event_type, created_at);

-- Backfill immutable funding events from existing reconciliations where possible
INSERT INTO order_funding_events (
  order_id,
  event_type,
  amount_gbp,
  source_ref,
  source_entity_type,
  source_entity_id,
  created_by_staff_id,
  created_at,
  notes
)
SELECT
  dr.order_id,
  'funding_contribution',
  dr.reconciled_gbp_amount,
  CONCAT('dva_reconciliation:', dr.id::text),
  'dva_reconciliation',
  dr.id,
  dr.reconciled_by_staff_id,
  COALESCE(dr.reconciled_at, now()),
  dr.notes
FROM dva_reconciliation dr
WHERE dr.reconciliation_type = 'order_funding'
  AND dr.order_id IS NOT NULL
ON CONFLICT (event_type, source_entity_type, source_entity_id)
WHERE source_entity_id IS NOT NULL
DO NOTHING;

-- Backfill credit-related funding events from the ledger where possible
INSERT INTO order_funding_events (
  order_id,
  event_type,
  amount_gbp,
  source_ref,
  source_entity_type,
  source_entity_id,
  created_by_staff_id,
  created_at,
  notes
)
SELECT
  COALESCE(icl.applied_to_order_id, icl.linked_order_id) AS order_id,
  CASE
    WHEN COALESCE(icl.source_type, '') = 'credit_application' THEN 'credit_applied'
    WHEN COALESCE(icl.source_type, '') = 'overfunding' THEN 'overfunding_credit_created'
    ELSE 'manual_adjustment'
  END AS event_type,
  ABS(icl.amount_gbp),
  CONCAT('importer_credit_ledger:', icl.id::text),
  'importer_credit_ledger',
  icl.id,
  icl.created_by_staff_id,
  COALESCE(icl.effective_at, icl.created_at, now()),
  icl.notes
FROM importer_credit_ledger icl
WHERE COALESCE(icl.applied_to_order_id, icl.linked_order_id) IS NOT NULL
  AND COALESCE(icl.source_type, '') IN ('credit_application','overfunding')
ON CONFLICT (event_type, source_entity_type, source_entity_id)
WHERE source_entity_id IS NOT NULL
DO NOTHING;

-- =============================================================================
-- 8. SAGE_POSTINGS — queue/adapter contract additions for Phase 1
-- =============================================================================

ALTER TABLE sage_postings
  ADD COLUMN IF NOT EXISTS posting_code varchar,
  ADD COLUMN IF NOT EXISTS source_version int,
  ADD COLUMN IF NOT EXISTS idempotency_key varchar,
  ADD COLUMN IF NOT EXISTS payload_json jsonb,
  ADD COLUMN IF NOT EXISTS payload_hash varchar,
  ADD COLUMN IF NOT EXISTS queue_status varchar,
  ADD COLUMN IF NOT EXISTS posted_sage_id varchar,
  ADD COLUMN IF NOT EXISTS last_error text,
  ADD COLUMN IF NOT EXISTS last_attempted_at timestamptz,
  ADD COLUMN IF NOT EXISTS held_reason text,
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;

UPDATE sage_postings
SET queue_status = CASE
  WHEN status = 'pending' THEN 'queued'
  WHEN status = 'retry' THEN 'failed_retryable'
  WHEN status = 'failed' THEN 'failed_terminal'
  WHEN status = 'posted' THEN 'posted'
  ELSE COALESCE(queue_status, 'queued')
END,
    posted_sage_id = COALESCE(posted_sage_id, sage_transaction_id),
    idempotency_key = COALESCE(
      idempotency_key,
      CASE
        WHEN posting_code IS NOT NULL AND source_table IS NOT NULL AND source_id IS NOT NULL
          THEN posting_code || ':' || source_table || ':' || source_id::text
        WHEN source_table IS NOT NULL AND source_id IS NOT NULL
          THEN source_table || ':' || source_id::text
        ELSE NULL
      END
    )
WHERE queue_status IS NULL
   OR posted_sage_id IS NULL
   OR idempotency_key IS NULL;

ALTER TABLE sage_postings DROP CONSTRAINT IF EXISTS sage_postings_queue_status_check;
ALTER TABLE sage_postings
  ADD CONSTRAINT sage_postings_queue_status_check
  CHECK (
    queue_status IS NULL OR queue_status IN (
      'queued',
      'held',
      'posting',
      'posted',
      'failed_retryable',
      'failed_terminal',
      'cancelled'
    )
  );

CREATE INDEX IF NOT EXISTS idx_sage_postings_queue_status
  ON sage_postings(queue_status, retry_count, posted_at);
CREATE INDEX IF NOT EXISTS idx_sage_postings_posting_code
  ON sage_postings(posting_code, source_table, source_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sage_postings_idempotency_key
  ON sage_postings(idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- =============================================================================
-- 9. DATA QUALITY / COMPATIBILITY TIDY-UPS
-- =============================================================================

-- Ensure retailer_sops rows with active_to set are not simultaneously marked active
UPDATE retailer_sops
SET active = false
WHERE active_to IS NOT NULL
  AND active = true;

-- Ensure shipping quote status is at least draft_quote after constraint change
UPDATE shipping_quotes
SET status = 'draft_quote'
WHERE status IS NULL;

-- Ensure order status is at least pending_dva_funding after constraint change
UPDATE orders
SET status = 'pending_dva_funding'
WHERE status IS NULL;

-- =============================================================================
-- 10. FINAL COMMENTS FOR PHASE 1
-- =============================================================================
COMMENT ON COLUMN shipping_quotes.status IS
'Phase 1 shipment-lane state. confirmed_ready_for_booking is the point that unlocks shipper booking visibility.';

COMMENT ON COLUMN orders.status IS
'Phase 1 parent-order lifecycle. Funding match is an overlay and must not be coded as a global operational blocker.';

COMMENT ON COLUMN dispute_messages.retailer_sop_version_used IS
'Reference to the exact retailer SOP row used when assembling the AI draft, for replay and audit.';

COMMENT ON COLUMN importer_credit_ledger.lock_reason IS
'Non-null means the credit is not yet available for application (for example tied_to_open_dispute, pending_payout, awaiting_admin_review).';

COMMIT;
