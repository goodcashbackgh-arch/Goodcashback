-- =============================================================================
-- closure_v2_functions_v2.sql
-- Multi Tenant Platform Build — additive Phase 1 closure functions / views pack
-- Corrected to align with:
--   1. Architecture Completion Addendum v2
--   2. Canonical Schema Reference v1
--   3. SAGE_POSTING_MATRIX_v1
--
-- Baseline expected:
--   * goodcashback-complete.v3.sql already applied
--   * closure_v2_migration_v2.sql already applied
--
-- Scope of this pack:
--   * helper views
--   * helper functions
--   * trigger functions
--   * workflow enforcement helpers
--   * no seed/config data here
--   * no multi-shipper-per-order architecture in Phase 1
--
-- Corrective note:
--   This v2 replacement closes the baseline-compatibility gaps by:
--     * preserving importer_balance_vw baseline column shape
--     * adding importer_credit_breakdown_vw for detailed credit diagnostics
--     * surfacing requires_admin_review_yn helpers/views
--     * fixing progressed-subset logic to use order_reconciliation_vw /
--       eligible_for_invoice_yn instead of a non-existent supplier_invoice_lines.status
--     * syncing real funding events from DVA reconciliation / credit application
--     * aligning replacement-child / VAT helpers to the actual baseline + migration
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';


-- =============================================================================
-- 0A. PREREQUISITE ASSERTIONS
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.order_reconciliation_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_reconciliation_vw must exist before closure_v2_functions_v2.sql is applied';
  END IF;

  IF to_regclass('public.importer_balance_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.importer_balance_vw must exist before closure_v2_functions_v2.sql is applied';
  END IF;

  IF (
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'importer_balance_vw'
  ) IS DISTINCT FROM 'importer_id,available_credit_gbp,pending_refund_gbp,active_order_funding_gbp,payout_in_progress_gbp,last_refreshed_at' THEN
    RAISE EXCEPTION 'Baseline compatibility failure: importer_balance_vw must keep the baseline column shape: importer_id, available_credit_gbp, pending_refund_gbp, active_order_funding_gbp, payout_in_progress_gbp, last_refreshed_at. Use a fresh baseline or restore the baseline-compatible view before applying closure_v2_functions_v2.sql';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='importer_credit_ledger'
      AND column_name IN ('source_type','source_entity_type','source_entity_id','applied_to_order_id','lock_reason','lock_source_entity_id')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 6
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: importer_credit_ledger closure-v2 source/lock columns. Run closure_v2_migration_v2.sql before this functions file';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema='public'
      AND table_name='orders'
      AND column_name IN ('quote_fx_rate_locked','quote_card_markup_pct_locked','quote_rate_date_locked','quote_rate_locked_at','vat_rate_applied','vat_tax_point_date','vat_return_period','vat_release_approved_by_staff_id','vat_release_approved_at','vat_release_evidence_json','accounting_release_ready_at','accounting_release_ready_by_staff_id','replacement_source_dispute_line_id')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 13
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: orders closure-v2 fields. Run closure_v2_migration_v2.sql before this functions file';
  END IF;

  IF to_regclass('public.order_funding_events') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_funding_events must exist before closure_v2_functions_v2.sql is applied';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='staff' AND column_name='role_type'
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: staff.role_type';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='dispute_messages' AND column_name='ai_input_context_json'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='dispute_messages' AND column_name='ai_model_used'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='dispute_messages' AND column_name='ai_prompt_hash'
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_messages AI replay core fields (ai_input_context_json, ai_model_used, ai_prompt_hash)';
  END IF;
END $$;


-- =============================================================================
-- 0. HELPER FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION current_staff_role()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT s.role_type
  FROM staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1
$$;

COMMENT ON FUNCTION current_staff_role() IS
'Returns the active staff role (supervisor/admin) for the authenticated user using the baseline staff.role_type field.';

CREATE OR REPLACE FUNCTION entity_requires_admin_review(
  p_entity_type text,
  p_entity_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM escalation_events ee
    WHERE ee.entity_type = p_entity_type
      AND ee.entity_id = p_entity_id
      AND ee.route = 'admin'
      AND ee.resolved_at IS NULL
  )
$$;

COMMENT ON FUNCTION entity_requires_admin_review(text, uuid) IS
'Generic helper that surfaces whether the entity currently has an unresolved admin-routed escalation.';

CREATE OR REPLACE FUNCTION order_has_open_child_exceptions(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM disputes d
    JOIN dispute_lines dl
      ON dl.dispute_id = d.id
    WHERE d.order_id = p_order_id
      AND dl.conversation_status IN (
        'child_exception_created',
        'remedy_selected',
        'refund_pending_approval',
        'retailer_draft_ready',
        'retailer_contacted',
        'retailer_response_received',
        'ai_next_draft_ready',
        'awaiting_retailer_resolution'
      )
  )
$$;

COMMENT ON FUNCTION order_has_open_child_exceptions(uuid) IS
'True when an order still has child exceptions that affect value and therefore block final closure.';

CREATE OR REPLACE FUNCTION order_has_progressed_subset(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM order_reconciliation_vw orv
    WHERE orv.order_id = p_order_id
      AND COALESCE(orv.invoiceable_subset_released_yn, false) = true
  )
$$;

COMMENT ON FUNCTION order_has_progressed_subset(uuid) IS
'Uses the real reconciliation model to determine whether a progressed invoiceable subset exists. Avoids inventing supplier_invoice_lines.status = progressed.';

CREATE OR REPLACE FUNCTION order_funding_total_gbp(p_order_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(SUM(
           CASE
             WHEN ofe.event_type IN ('funding_contribution','credit_applied','manual_adjustment')
               THEN ofe.amount_gbp
             WHEN ofe.event_type = 'funding_reversed'
               THEN -ABS(ofe.amount_gbp)
             ELSE 0
           END
         ), 0)
  FROM order_funding_events ofe
  WHERE ofe.order_id = p_order_id
$$;

COMMENT ON FUNCTION order_funding_total_gbp(uuid) IS
'Total effective funding against the order from the immutable order_funding_events log.';

CREATE OR REPLACE FUNCTION order_funding_gap_gbp(p_order_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT GREATEST(
           COALESCE(o.order_total_gbp_declared, 0) - COALESCE(order_funding_total_gbp(o.id), 0),
           0
         )
  FROM orders o
  WHERE o.id = p_order_id
$$;

COMMENT ON FUNCTION order_funding_gap_gbp(uuid) IS
'Remaining funding gap for original orders using the immutable funding-event overlay.';

-- =============================================================================
-- 1. HELPER VIEWS
-- =============================================================================

CREATE OR REPLACE VIEW importer_balance_vw AS
SELECT
  i.id AS importer_id,
  COALESCE(
    SUM(
      CASE
        WHEN icl.direction = 'credit' AND icl.lock_reason IS NULL THEN ABS(icl.amount_gbp)
        WHEN icl.direction = 'debit' THEN -ABS(icl.amount_gbp)
        ELSE 0
      END
    ),
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
         AND o.status NOT IN ('completed','archived','cancelled')),
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
LEFT JOIN importer_credit_ledger icl
  ON icl.importer_id = i.id
GROUP BY i.id;

COMMENT ON VIEW importer_balance_vw IS
'Baseline-compatible importer balance view. Column shape is preserved while available_credit_gbp excludes locked credit and debits are interpreted using importer_credit_ledger.direction.';

CREATE OR REPLACE VIEW importer_credit_breakdown_vw AS
SELECT
  i.id AS importer_id,
  COALESCE(SUM(CASE WHEN icl.direction = 'credit' AND icl.lock_reason IS NULL THEN ABS(icl.amount_gbp) ELSE 0 END), 0) AS gross_available_credits_gbp,
  COALESCE(SUM(CASE WHEN icl.direction = 'credit' AND icl.lock_reason IS NOT NULL THEN ABS(icl.amount_gbp) ELSE 0 END), 0) AS gross_locked_credits_gbp,
  COALESCE(SUM(CASE WHEN icl.direction = 'debit' THEN ABS(icl.amount_gbp) ELSE 0 END), 0) AS gross_debits_gbp,
  COALESCE(
    SUM(
      CASE
        WHEN icl.direction = 'credit' AND icl.lock_reason IS NULL THEN ABS(icl.amount_gbp)
        WHEN icl.direction = 'debit' THEN -ABS(icl.amount_gbp)
        ELSE 0
      END
    ),
    0
  ) AS available_credit_gbp,
  now() AS last_refreshed_at
FROM importers i
LEFT JOIN importer_credit_ledger icl
  ON icl.importer_id = i.id
GROUP BY i.id;

COMMENT ON VIEW importer_credit_breakdown_vw IS
'Detailed importer credit diagnostic view. Keeps importer_balance_vw baseline-compatible while exposing available, locked, and debit breakdowns for staff/admin UI.';

CREATE OR REPLACE VIEW admin_escalation_queue_vw AS
SELECT
  ee.id,
  er.rule_code,
  er.event_type,
  er.description AS rule_description,
  ee.entity_type,
  ee.entity_id,
  ee.raised_at,
  ee.raised_context_json,
  ee.assigned_to_staff_id,
  ee.route,
  EXTRACT(EPOCH FROM (now() - ee.raised_at)) / 3600.0 AS hours_open
FROM escalation_events ee
JOIN escalation_rules er
  ON er.id = ee.rule_id
WHERE ee.resolved_at IS NULL
  AND ee.route = 'admin'
ORDER BY ee.raised_at;

COMMENT ON VIEW admin_escalation_queue_vw IS
'Open admin-routed escalation events, ordered oldest first.';

CREATE OR REPLACE VIEW entity_admin_review_vw AS
SELECT
  ee.entity_type,
  ee.entity_id,
  true AS requires_admin_review_yn,
  MIN(ee.raised_at) AS oldest_open_escalated_at,
  array_agg(er.rule_code ORDER BY er.rule_code) AS open_rule_codes
FROM escalation_events ee
JOIN escalation_rules er
  ON er.id = ee.rule_id
WHERE ee.resolved_at IS NULL
  AND ee.route = 'admin'
GROUP BY ee.entity_type, ee.entity_id;

COMMENT ON VIEW entity_admin_review_vw IS
'Generic surfaced admin-review helper built from rules-as-data. Used by entity-specific views and UI gating.';

CREATE OR REPLACE VIEW order_admin_review_vw AS
SELECT
  o.id AS order_id,
  COALESCE(e.requires_admin_review_yn, false) AS requires_admin_review_yn,
  e.oldest_open_escalated_at,
  e.open_rule_codes
FROM orders o
LEFT JOIN entity_admin_review_vw e
  ON e.entity_type = 'order'
 AND e.entity_id = o.id;

CREATE OR REPLACE VIEW dispute_admin_review_vw AS
SELECT
  d.id AS dispute_id,
  COALESCE(e.requires_admin_review_yn, false) AS requires_admin_review_yn,
  e.oldest_open_escalated_at,
  e.open_rule_codes
FROM disputes d
LEFT JOIN entity_admin_review_vw e
  ON e.entity_type = 'dispute'
 AND e.entity_id = d.id;

CREATE OR REPLACE VIEW payout_request_admin_review_vw AS
SELECT
  p.id AS payout_request_id,
  COALESCE(e.requires_admin_review_yn, false) AS requires_admin_review_yn,
  e.oldest_open_escalated_at,
  e.open_rule_codes
FROM payout_requests p
LEFT JOIN entity_admin_review_vw e
  ON e.entity_type = 'payout_request'
 AND e.entity_id = p.id;

CREATE OR REPLACE VIEW shipping_quote_admin_review_vw AS
SELECT
  sq.id AS shipping_quote_id,
  COALESCE(e.requires_admin_review_yn, false) AS requires_admin_review_yn,
  e.oldest_open_escalated_at,
  e.open_rule_codes
FROM shipping_quotes sq
LEFT JOIN entity_admin_review_vw e
  ON e.entity_type = 'shipping_quote'
 AND e.entity_id = sq.id;

CREATE OR REPLACE VIEW importer_credit_admin_review_vw AS
SELECT
  icl.id AS importer_credit_ledger_id,
  COALESCE(e.requires_admin_review_yn, false) AS requires_admin_review_yn,
  e.oldest_open_escalated_at,
  e.open_rule_codes
FROM importer_credit_ledger icl
LEFT JOIN entity_admin_review_vw e
  ON e.entity_type = 'importer_credit'
 AND e.entity_id = icl.id;

COMMENT ON VIEW order_admin_review_vw IS 'Order-level surfaced admin review helper.';
COMMENT ON VIEW dispute_admin_review_vw IS 'Dispute-level surfaced admin review helper.';
COMMENT ON VIEW payout_request_admin_review_vw IS 'Payout-level surfaced admin review helper.';
COMMENT ON VIEW shipping_quote_admin_review_vw IS 'Shipping-quote-level surfaced admin review helper.';
COMMENT ON VIEW importer_credit_admin_review_vw IS 'Importer-credit-level surfaced admin review helper.';

CREATE OR REPLACE VIEW order_state_vw AS
SELECT
  o.id,
  o.order_ref,
  o.importer_id,
  o.shipper_id,
  o.parent_order_id,
  o.order_type,
  o.status AS lifecycle_status,
  CASE
    WHEN o.order_type = 'replacement_child' THEN 'not_required'
    WHEN o.funded_at IS NOT NULL THEN 'platform_funded'
    WHEN entity_requires_admin_review('order', o.id) THEN 'anomaly_queue'
    ELSE 'pending'
  END AS funding_overlay,
  CASE
    WHEN EXISTS (
      SELECT 1
      FROM shipping_quote_orders sqo
      JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
      WHERE sqo.order_id = o.id
        AND sq.status IN ('delivered_ghana','closed')
    ) THEN 'delivered'
    WHEN EXISTS (
      SELECT 1
      FROM shipping_quote_orders sqo
      JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
      WHERE sqo.order_id = o.id
        AND sq.status IN ('dispatched','in_transit','hub_received','booked')
    ) THEN 'in_transit'
    WHEN o.status IN ('ready_for_shipment','shipment_booked','shipment_dispatched','awaiting_importer_receipt') THEN 'ready_for_shipment'
    ELSE 'not_yet'
  END AS shipment_readiness_overlay,
  COALESCE(oar.requires_admin_review_yn, false) AS requires_admin_review_yn,
  o.funded_at,
  o.quote_rate_locked_at,
  o.accounting_release_ready_at,
  o.vat_release_approved_at,
  CASE
    WHEN o.status IN ('completed','archived','cancelled') THEN 'closed'
    WHEN o.status = 'awaiting_financial_closure' THEN 'awaiting_release'
    WHEN o.status IN ('evidence_collecting','reconciling','partially_progressed','ready_for_shipment','shipment_booked','shipment_dispatched','awaiting_importer_receipt','discrepancy_open')
      AND o.funded_at IS NULL
      AND o.order_type <> 'replacement_child'
      THEN 'parallel_lane_active'
    ELSE 'normal'
  END AS operational_bucket
FROM orders o
LEFT JOIN order_admin_review_vw oar
  ON oar.order_id = o.id;

COMMENT ON VIEW order_state_vw IS
'Dashboard/helper view combining parent lifecycle status with funding and shipment overlays and surfaced requires_admin_review_yn without redesigning orders.status in Phase 1.';

-- =============================================================================
-- 2. ESCALATION FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION raise_escalation(
  p_rule_code text,
  p_entity_type text,
  p_entity_id uuid,
  p_context jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rule_id uuid;
  v_route text;
  v_event_id uuid;
BEGIN
  SELECT er.id, er.route_to
    INTO v_rule_id, v_route
  FROM escalation_rules er
  WHERE er.rule_code = p_rule_code
    AND er.active = true;

  IF v_rule_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM escalation_events ee
    WHERE ee.rule_id = v_rule_id
      AND ee.entity_type = p_entity_type
      AND ee.entity_id = p_entity_id
      AND ee.resolved_at IS NULL
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO escalation_events (
    rule_id,
    entity_type,
    entity_id,
    raised_context_json,
    route
  )
  VALUES (
    v_rule_id,
    p_entity_type,
    p_entity_id,
    COALESCE(p_context, '{}'::jsonb),
    v_route
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

COMMENT ON FUNCTION raise_escalation(text, text, uuid, jsonb) IS
'Creates one unresolved escalation per (rule, entity) and returns the event id. The UI and queue helpers derive requires_admin_review_yn from these events.';

-- =============================================================================
-- 3. SOP VERSIONING / HASHING
-- =============================================================================

CREATE OR REPLACE FUNCTION update_retailer_sop(
  p_retailer_id uuid,
  p_claim_email varchar,
  p_claim_portal_url varchar,
  p_claim_procedure_notes text,
  p_escalation_path text,
  p_staff_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_id uuid;
  v_old_version_text text;
  v_new_version_text text;
  v_new_id uuid;
  v_hash_input text;
BEGIN
  SELECT rs.id, rs.version
    INTO v_old_id, v_old_version_text
  FROM retailer_sops rs
  WHERE rs.retailer_id = p_retailer_id
    AND rs.active = true
    AND rs.active_to IS NULL
  ORDER BY COALESCE(rs.active_from, rs.effective_date::timestamptz) DESC, rs.id DESC
  LIMIT 1
  FOR UPDATE;

  IF v_old_id IS NOT NULL THEN
    UPDATE retailer_sops
    SET active = false,
        active_to = now(),
        deprecated_date = COALESCE(deprecated_date, CURRENT_DATE)
    WHERE id = v_old_id;
  END IF;

  v_new_version_text := (
    COALESCE((
      SELECT COUNT(*)::text
      FROM retailer_sops r2
      WHERE r2.retailer_id = p_retailer_id
    ), '0')::int + 1
  )::text;

  v_hash_input := concat_ws(E'\n',
    COALESCE(p_claim_email, ''),
    COALESCE(p_claim_portal_url, ''),
    COALESCE(p_claim_procedure_notes, ''),
    COALESCE(p_escalation_path, '')
  );

  INSERT INTO retailer_sops (
    retailer_id,
    claim_email,
    claim_portal_url,
    claim_procedure_notes,
    escalation_path,
    version,
    effective_date,
    deprecated_date,
    active,
    content_hash,
    active_from,
    active_to,
    created_by_staff_id,
    supersedes_id
  )
  VALUES (
    p_retailer_id,
    p_claim_email,
    p_claim_portal_url,
    p_claim_procedure_notes,
    p_escalation_path,
    v_new_version_text,
    CURRENT_DATE,
    NULL,
    true,
    encode(digest(v_hash_input, 'sha256'), 'hex'),
    now(),
    NULL,
    p_staff_id,
    v_old_id
  )
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

COMMENT ON FUNCTION update_retailer_sop(uuid, varchar, varchar, text, text, uuid) IS
'Closes the current active retailer SOP row and inserts a new versioned row using the real baseline fields plus a deterministic content hash.';

-- =============================================================================
-- 4. QUOTE FX SNAPSHOT LOCK ON ORDER SUBMISSION
-- =============================================================================

CREATE OR REPLACE FUNCTION trg_lock_quote_snapshot_on_order_submit()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status = 'pending_dva_funding'
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'pending_dva_funding') THEN
    NEW.quote_fx_rate_locked := COALESCE(NEW.quote_fx_rate_locked, NEW.quote_fx_rate);
    NEW.quote_card_markup_pct_locked := COALESCE(NEW.quote_card_markup_pct_locked, NEW.quote_card_markup_pct);
    NEW.quote_rate_date_locked := COALESCE(NEW.quote_rate_date_locked, COALESCE(NEW.created_at, now())::date);
    NEW.quote_rate_locked_at := COALESCE(NEW.quote_rate_locked_at, now());
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lock_quote_snapshot_on_order_submit ON orders;
CREATE TRIGGER trg_lock_quote_snapshot_on_order_submit
BEFORE INSERT OR UPDATE OF status
ON orders
FOR EACH ROW
EXECUTE FUNCTION trg_lock_quote_snapshot_on_order_submit();

COMMENT ON FUNCTION trg_lock_quote_snapshot_on_order_submit() IS
'Locks the quote-side FX snapshot when the importer submits the order into pending_dva_funding. Historical quote FX must never restamp later.';

-- =============================================================================
-- 5. FUNDING EVENT SYNC + PLATFORM-FUNDED STAMPING
-- =============================================================================

CREATE OR REPLACE FUNCTION recompute_order_platform_funded(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_total numeric := 0;
  v_threshold_at timestamptz;
BEGIN
  SELECT COALESCE(o.order_total_gbp_declared, 0)
    INTO v_order_total
  FROM orders o
  WHERE o.id = p_order_id;

  IF v_order_total = 0 THEN
    RETURN;
  END IF;

  WITH running AS (
    SELECT
      ofe.created_at,
      ofe.id,
      SUM(
        CASE
          WHEN ofe.event_type IN ('funding_contribution','credit_applied','manual_adjustment')
            THEN ofe.amount_gbp
          WHEN ofe.event_type = 'funding_reversed'
            THEN -ABS(ofe.amount_gbp)
          ELSE 0
        END
      ) OVER (ORDER BY ofe.created_at, ofe.id) AS running_total
    FROM order_funding_events ofe
    WHERE ofe.order_id = p_order_id
  )
  SELECT MIN(r.created_at)
    INTO v_threshold_at
  FROM running r
  WHERE r.running_total >= v_order_total;

  UPDATE orders
  SET funded_at = v_threshold_at
  WHERE id = p_order_id;
END;
$$;

COMMENT ON FUNCTION recompute_order_platform_funded(uuid) IS
'Recomputes funded_at from immutable order_funding_events. Sets funded_at to the first timestamp at which cumulative funding met the order total, or NULL if not yet met.';

CREATE OR REPLACE FUNCTION sync_order_overfunding_credit(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_total_funding numeric := 0;
  v_excess_gbp numeric := 0;
  v_existing_credit_id uuid;
  v_staff_id uuid;
BEGIN
  IF p_order_id IS NULL THEN
    RETURN;
  END IF;

  SELECT
    o.id,
    o.importer_id,
    COALESCE(o.order_type, 'original') AS order_type,
    COALESCE(o.order_total_gbp_declared, 0) AS order_total_gbp_declared
  INTO v_order
  FROM orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Replacement children are not fresh payer-funding events in Phase 1.
  -- Therefore they must not carry generated overfunding credit.
  IF v_order.order_type <> 'original' THEN
    DELETE FROM importer_credit_ledger icl
    WHERE icl.importer_id = v_order.importer_id
      AND icl.source_type = 'overfunding'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id = p_order_id
      AND icl.linked_order_id = p_order_id;
    RETURN;
  END IF;

  SELECT COALESCE(SUM(
           CASE
             WHEN ofe.event_type IN ('funding_contribution','credit_applied','manual_adjustment','funding_reversed')
               THEN ofe.amount_gbp
             ELSE 0
           END
         ), 0)
    INTO v_total_funding
  FROM order_funding_events ofe
  WHERE ofe.order_id = p_order_id;

  v_excess_gbp := GREATEST(v_total_funding - v_order.order_total_gbp_declared, 0);

  SELECT ofe.created_by_staff_id
    INTO v_staff_id
  FROM order_funding_events ofe
  WHERE ofe.order_id = p_order_id
    AND ofe.event_type IN ('funding_contribution','manual_adjustment')
  ORDER BY ofe.created_at DESC, ofe.id DESC
  LIMIT 1;

  IF v_excess_gbp <= 0 THEN
    DELETE FROM importer_credit_ledger icl
    WHERE icl.importer_id = v_order.importer_id
      AND icl.source_type = 'overfunding'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id = p_order_id
      AND icl.linked_order_id = p_order_id;
    RETURN;
  END IF;

  SELECT icl.id
    INTO v_existing_credit_id
  FROM importer_credit_ledger icl
  WHERE icl.importer_id = v_order.importer_id
    AND icl.source_type = 'overfunding'
    AND icl.source_entity_type = 'order'
    AND icl.source_entity_id = p_order_id
    AND icl.linked_order_id = p_order_id
  ORDER BY icl.created_at, icl.id
  LIMIT 1
  FOR UPDATE;

  IF v_existing_credit_id IS NULL THEN
    INSERT INTO importer_credit_ledger (
      importer_id,
      entry_type,
      source_table,
      source_id,
      linked_order_id,
      linked_dispute_id,
      direction,
      amount_gbp,
      amount_local_ccy,
      local_ccy,
      effective_at,
      source_type,
      source_entity_type,
      source_entity_id,
      applied_to_order_id,
      lock_reason,
      created_by_staff_id,
      notes
    )
    VALUES (
      v_order.importer_id,
      'manual_credit',
      'orders',
      p_order_id,
      p_order_id,
      NULL,
      'credit',
      v_excess_gbp,
      v_excess_gbp,
      'GBP',
      now(),
      'overfunding',
      'order',
      p_order_id,
      NULL,
      NULL,
      v_staff_id,
      'Auto-created excess DVA funding credit for original order'
    )
    RETURNING id INTO v_existing_credit_id;
  ELSE
    UPDATE importer_credit_ledger
    SET amount_gbp = v_excess_gbp,
        amount_local_ccy = v_excess_gbp,
        local_ccy = 'GBP',
        direction = 'credit',
        source_type = 'overfunding',
        source_entity_type = 'order',
        source_entity_id = p_order_id,
        linked_order_id = p_order_id,
        applied_to_order_id = NULL,
        lock_reason = NULL,
        created_by_staff_id = COALESCE(created_by_staff_id, v_staff_id),
        effective_at = now(),
        notes = 'Auto-updated excess DVA funding credit for original order'
    WHERE id = v_existing_credit_id;

    -- Collapse any duplicate generated overfunding rows for the same order.
    DELETE FROM importer_credit_ledger icl
    WHERE icl.id <> v_existing_credit_id
      AND icl.importer_id = v_order.importer_id
      AND icl.source_type = 'overfunding'
      AND icl.source_entity_type = 'order'
      AND icl.source_entity_id = p_order_id
      AND icl.linked_order_id = p_order_id;
  END IF;
END;
$$;

COMMENT ON FUNCTION sync_order_overfunding_credit(uuid) IS
'Mirrors funding above the original order total into importer_credit_ledger as available overfunding credit, and removes the generated credit again if the excess disappears.';


CREATE OR REPLACE FUNCTION trg_sync_order_funding_event_from_dva_reconciliation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM order_funding_events
    WHERE event_type = 'funding_contribution'
      AND source_entity_type = 'dva_reconciliation'
      AND source_entity_id = OLD.id;

    IF OLD.order_id IS NOT NULL THEN
      PERFORM recompute_order_platform_funded(OLD.order_id);
      PERFORM sync_order_overfunding_credit(OLD.order_id);
    END IF;

    RETURN OLD;
  END IF;

  -- If an existing reconciliation moves away from the old order or stops being
  -- order funding, remove the old funding event and recompute the old order.
  IF TG_OP = 'UPDATE'
     AND OLD.reconciliation_type = 'order_funding'
     AND OLD.order_id IS NOT NULL
     AND (
       NEW.reconciliation_type IS DISTINCT FROM 'order_funding'
       OR NEW.order_id IS DISTINCT FROM OLD.order_id
     ) THEN
    DELETE FROM order_funding_events
    WHERE event_type = 'funding_contribution'
      AND source_entity_type = 'dva_reconciliation'
      AND source_entity_id = OLD.id;

    PERFORM recompute_order_platform_funded(OLD.order_id);
    PERFORM sync_order_overfunding_credit(OLD.order_id);
  END IF;

  IF NEW.reconciliation_type = 'order_funding' AND NEW.order_id IS NOT NULL THEN
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
    VALUES (
      NEW.order_id,
      'funding_contribution',
      NEW.reconciled_gbp_amount,
      CONCAT('dva_reconciliation:', NEW.id::text),
      'dva_reconciliation',
      NEW.id,
      NEW.reconciled_by_staff_id,
      NEW.reconciled_at,
      NEW.notes
    )
    ON CONFLICT (event_type, source_entity_type, source_entity_id)
    WHERE source_entity_id IS NOT NULL
    DO UPDATE SET
      order_id = EXCLUDED.order_id,
      amount_gbp = EXCLUDED.amount_gbp,
      source_ref = EXCLUDED.source_ref,
      created_by_staff_id = EXCLUDED.created_by_staff_id,
      created_at = EXCLUDED.created_at,
      notes = EXCLUDED.notes;

    PERFORM recompute_order_platform_funded(NEW.order_id);
    PERFORM sync_order_overfunding_credit(NEW.order_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_order_funding_event_from_dva_reconciliation ON dva_reconciliation;
CREATE TRIGGER trg_sync_order_funding_event_from_dva_reconciliation
AFTER INSERT OR UPDATE OR DELETE
ON dva_reconciliation
FOR EACH ROW
EXECUTE FUNCTION trg_sync_order_funding_event_from_dva_reconciliation();

COMMENT ON FUNCTION trg_sync_order_funding_event_from_dva_reconciliation() IS
'Keeps order_funding_events in sync with DVA reconciliation rows, recomputes funded_at, and mirrors DVA overfunding into importer_credit_ledger.';

CREATE OR REPLACE FUNCTION trg_sync_order_funding_event_from_importer_credit_ledger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_old_order_id uuid;
  v_new_order_id uuid;
  v_old_event_type text;
  v_new_event_type text;
  v_amount numeric;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    v_old_order_id := COALESCE(OLD.applied_to_order_id, OLD.linked_order_id);
    v_old_event_type := CASE
      WHEN OLD.source_type = 'credit_application' AND v_old_order_id IS NOT NULL THEN 'credit_applied'
      WHEN OLD.source_type = 'overfunding' AND v_old_order_id IS NOT NULL THEN 'overfunding_credit_created'
      ELSE NULL
    END;
  END IF;

  IF TG_OP IN ('INSERT','UPDATE') THEN
    v_new_order_id := COALESCE(NEW.applied_to_order_id, NEW.linked_order_id);
    v_new_event_type := CASE
      WHEN NEW.source_type = 'credit_application' AND v_new_order_id IS NOT NULL THEN 'credit_applied'
      WHEN NEW.source_type = 'overfunding' AND v_new_order_id IS NOT NULL THEN 'overfunding_credit_created'
      ELSE NULL
    END;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF v_old_event_type IS NOT NULL THEN
      DELETE FROM order_funding_events
      WHERE event_type = v_old_event_type
        AND source_entity_type = 'importer_credit_ledger'
        AND source_entity_id = OLD.id;

      IF v_old_order_id IS NOT NULL THEN
        PERFORM recompute_order_platform_funded(v_old_order_id);
      END IF;
    END IF;

    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE'
     AND v_old_event_type IS NOT NULL
     AND (
       v_new_event_type IS DISTINCT FROM v_old_event_type
       OR v_new_order_id IS DISTINCT FROM v_old_order_id
     ) THEN
    DELETE FROM order_funding_events
    WHERE event_type = v_old_event_type
      AND source_entity_type = 'importer_credit_ledger'
      AND source_entity_id = OLD.id;

    IF v_old_order_id IS NOT NULL THEN
      PERFORM recompute_order_platform_funded(v_old_order_id);
    END IF;
  END IF;

  IF v_new_event_type IS NOT NULL THEN
    v_amount := ABS(NEW.amount_gbp);

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
    VALUES (
      v_new_order_id,
      v_new_event_type,
      v_amount,
      CONCAT('importer_credit_ledger:', NEW.id::text),
      'importer_credit_ledger',
      NEW.id,
      NEW.created_by_staff_id,
      COALESCE(NEW.effective_at, NEW.created_at, now()),
      NEW.notes
    )
    ON CONFLICT (event_type, source_entity_type, source_entity_id)
    WHERE source_entity_id IS NOT NULL
    DO UPDATE SET
      order_id = EXCLUDED.order_id,
      amount_gbp = EXCLUDED.amount_gbp,
      source_ref = EXCLUDED.source_ref,
      created_by_staff_id = EXCLUDED.created_by_staff_id,
      created_at = EXCLUDED.created_at,
      notes = EXCLUDED.notes;

    PERFORM recompute_order_platform_funded(v_new_order_id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_order_funding_event_from_importer_credit_ledger ON importer_credit_ledger;
CREATE TRIGGER trg_sync_order_funding_event_from_importer_credit_ledger
AFTER INSERT OR UPDATE OR DELETE
ON importer_credit_ledger
FOR EACH ROW
EXECUTE FUNCTION trg_sync_order_funding_event_from_importer_credit_ledger();

COMMENT ON FUNCTION trg_sync_order_funding_event_from_importer_credit_ledger() IS
'Keeps order_funding_events in sync with importer credit rows relevant to funding and deletes stale source events when ledger rows change type/order.';

CREATE OR REPLACE FUNCTION trg_recompute_order_platform_funded_from_event()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    PERFORM recompute_order_platform_funded(OLD.order_id);
  END IF;

  IF TG_OP IN ('INSERT','UPDATE') THEN
    PERFORM recompute_order_platform_funded(NEW.order_id);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_order_platform_funded_from_event ON order_funding_events;
CREATE TRIGGER trg_recompute_order_platform_funded_from_event
AFTER INSERT OR UPDATE OR DELETE
ON order_funding_events
FOR EACH ROW
EXECUTE FUNCTION trg_recompute_order_platform_funded_from_event();

-- =============================================================================
-- 6. PARENT ORDER STATUS RECOMPUTE
-- =============================================================================

-- =============================================================================
-- Day 3 hotfix: status recompute must not auto-promote to ready_for_shipment,
-- and OCR-source supplier invoice lines must be editable but not deletable.
-- =============================================================================

CREATE OR REPLACE FUNCTION recompute_order_status(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_has_tracking boolean := false;
  v_has_invoice boolean := false;
  v_has_progressed boolean := false;
  v_has_open_children boolean := false;
  v_whole_order_cleared boolean := false;
  v_has_booking boolean := false;
  v_has_dispatch boolean := false;
  v_has_delivery boolean := false;
  v_new_status text;
BEGIN
  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Do not let evidence/OCR triggers drag closed or financial-control states backwards.
  IF v_order.status IN ('archived', 'cancelled', 'completed', 'awaiting_financial_closure') THEN
    RETURN;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM order_tracking_submissions ots
    WHERE ots.order_id = p_order_id
      AND ots.superseded_at IS NULL
  )
    INTO v_has_tracking;

  SELECT EXISTS (
    SELECT 1
    FROM supplier_invoices si
    WHERE si.order_id = p_order_id
  )
    INTO v_has_invoice;

  SELECT COALESCE(order_has_progressed_subset(p_order_id), false)
    INTO v_has_progressed;

  SELECT order_has_open_child_exceptions(p_order_id)
    INTO v_has_open_children;

  SELECT COALESCE(orv.whole_order_cleared_yn, false)
    INTO v_whole_order_cleared
  FROM order_reconciliation_vw orv
  WHERE orv.order_id = p_order_id;

  SELECT EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq
      ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = p_order_id
      AND sq.status IN ('booked','hub_received','dispatched','in_transit','delivered_ghana','closed')
  )
    INTO v_has_booking;

  SELECT EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq
      ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = p_order_id
      AND sq.status IN ('dispatched','in_transit','delivered_ghana','closed')
  )
    INTO v_has_dispatch;

  SELECT EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq
      ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = p_order_id
      AND sq.status IN ('delivered_ghana','closed')
  )
    INTO v_has_delivery;

  v_new_status := CASE
    WHEN v_order.status = 'discrepancy_open' THEN 'discrepancy_open'
    WHEN v_has_delivery THEN 'awaiting_importer_receipt'
    WHEN v_has_dispatch THEN 'shipment_dispatched'
    WHEN v_has_booking THEN 'shipment_booked'

    -- ready_for_shipment is an explicit supervisor/admin handoff state.
    -- Reconciliation triggers may preserve it, but must not create it or drag it backwards.
    WHEN v_order.status = 'ready_for_shipment' THEN 'ready_for_shipment'

    -- Progressed subset exists but the parent is not fully cleared, or open children remain.
    WHEN v_has_progressed AND (v_has_open_children OR NOT v_whole_order_cleared) THEN 'partially_progressed'

    -- Fully cleared OCR/reconciliation remains reconciling until explicit ready-for-shipment handoff.
    WHEN v_has_progressed AND v_whole_order_cleared THEN 'reconciling'
    WHEN v_has_invoice THEN 'reconciling'
    WHEN v_has_tracking OR v_has_invoice THEN 'evidence_collecting'
    ELSE v_order.status
  END;

  IF v_new_status IS DISTINCT FROM v_order.status THEN
    UPDATE orders
    SET status = v_new_status
    WHERE id = p_order_id;
  END IF;
END;
$$;

COMMENT ON FUNCTION recompute_order_status(uuid) IS
'Best-effort parent-order status recompute aligned to Phase 1. Uses order_reconciliation_vw / eligible_for_invoice_yn, marks partial progress when unresolved value remains, and preserves ready_for_shipment as an explicit handoff rather than auto-promoting to it.';


CREATE OR REPLACE FUNCTION trg_recompute_order_status_from_tracking()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM recompute_order_status(CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END);

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_order_status_from_tracking ON order_tracking_submissions;
CREATE TRIGGER trg_recompute_order_status_from_tracking
AFTER INSERT OR UPDATE OR DELETE
ON order_tracking_submissions
FOR EACH ROW
EXECUTE FUNCTION trg_recompute_order_status_from_tracking();

CREATE OR REPLACE FUNCTION trg_recompute_order_status_from_invoice()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM recompute_order_status(CASE WHEN TG_OP = 'DELETE' THEN OLD.order_id ELSE NEW.order_id END);

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_order_status_from_invoice ON supplier_invoices;
CREATE TRIGGER trg_recompute_order_status_from_invoice
AFTER INSERT OR UPDATE OR DELETE
ON supplier_invoices
FOR EACH ROW
EXECUTE FUNCTION trg_recompute_order_status_from_invoice();

CREATE OR REPLACE FUNCTION trg_recompute_order_status_from_invoice_line()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  SELECT si.order_id
    INTO v_order_id
  FROM supplier_invoices si
  WHERE si.id = CASE WHEN TG_OP = 'DELETE' THEN OLD.supplier_invoice_id ELSE NEW.supplier_invoice_id END;

  IF v_order_id IS NOT NULL THEN
    PERFORM recompute_order_status(v_order_id);
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_order_status_from_invoice_line ON supplier_invoice_lines;
CREATE TRIGGER trg_recompute_order_status_from_invoice_line
AFTER INSERT OR UPDATE OR DELETE
ON supplier_invoice_lines
FOR EACH ROW
EXECUTE FUNCTION trg_recompute_order_status_from_invoice_line();

CREATE OR REPLACE FUNCTION prevent_ocr_supplier_invoice_line_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.line_source = 'ocr_extracted' THEN
    RAISE EXCEPTION 'OCR-extracted supplier invoice lines are editable but not deletable';
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_ocr_supplier_invoice_line_delete ON supplier_invoice_lines;
CREATE TRIGGER trg_prevent_ocr_supplier_invoice_line_delete
BEFORE DELETE ON supplier_invoice_lines
FOR EACH ROW
EXECUTE FUNCTION prevent_ocr_supplier_invoice_line_delete();

COMMENT ON FUNCTION prevent_ocr_supplier_invoice_line_delete() IS
'Enforces Day 3 control: OCR-extracted invoice lines preserve source provenance and may be edited, but only manually-added lines may be deleted.';

CREATE OR REPLACE FUNCTION trg_recompute_order_status_from_shipping_quote()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  FOR v_order_id IN
    SELECT DISTINCT sqo.order_id
    FROM shipping_quote_orders sqo
    WHERE sqo.shipping_quote_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END
  LOOP
    PERFORM recompute_order_status(v_order_id);
  END LOOP;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_order_status_from_shipping_quote ON shipping_quotes;
CREATE TRIGGER trg_recompute_order_status_from_shipping_quote
AFTER INSERT OR UPDATE OR DELETE
ON shipping_quotes
FOR EACH ROW
EXECUTE FUNCTION trg_recompute_order_status_from_shipping_quote();

-- =============================================================================
-- 7. IMPORTER CREDIT UNLOCK ON CHILD RESOLUTION
-- =============================================================================

CREATE OR REPLACE FUNCTION trg_unlock_credits_on_dispute_line_resolve()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.conversation_status IN (
       'resolved_refund',
       'resolved_replacement',
       'resolved_credit',
       'closed_no_action'
     )
     AND OLD.conversation_status IS DISTINCT FROM NEW.conversation_status THEN
    UPDATE importer_credit_ledger
    SET lock_reason = NULL,
        lock_source_entity_id = NULL
    WHERE lock_source_entity_id = NEW.id
      AND lock_reason = 'tied_to_open_dispute';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_unlock_credits_on_dispute_line_resolve ON dispute_lines;
CREATE TRIGGER trg_unlock_credits_on_dispute_line_resolve
AFTER UPDATE OF conversation_status
ON dispute_lines
FOR EACH ROW
EXECUTE FUNCTION trg_unlock_credits_on_dispute_line_resolve();

COMMENT ON FUNCTION trg_unlock_credits_on_dispute_line_resolve() IS
'Unlocks credit rows once the originating child exception reaches a resolved state.';
-- =============================================================================
-- Day 4 hotfix: refund communication gate must be backend-enforced.
-- =============================================================================

CREATE OR REPLACE FUNCTION enforce_refund_dispute_line_gate()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_approved boolean := false;
BEGIN
  IF OLD.conversation_status IS DISTINCT FROM NEW.conversation_status
     AND NEW.conversation_status = 'retailer_draft_ready'
     AND COALESCE(NEW.intended_remedy, '') = 'refund' THEN

    SELECT EXISTS (
      SELECT 1
      FROM disputes d
      WHERE d.id = NEW.dispute_id
        AND d.refund_approved_by_staff_id IS NOT NULL
        AND d.refund_approved_at IS NOT NULL
    ) INTO v_approved;

    IF v_approved IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'Refund child cannot move to retailer_draft_ready before supervisor/admin refund approval';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_refund_dispute_line_gate ON dispute_lines;
CREATE TRIGGER trg_enforce_refund_dispute_line_gate
BEFORE UPDATE OF conversation_status, intended_remedy
ON dispute_lines
FOR EACH ROW
EXECUTE FUNCTION enforce_refund_dispute_line_gate();

COMMENT ON FUNCTION enforce_refund_dispute_line_gate() IS
'Backend refund gate: refund-intent dispute lines cannot move to retailer_draft_ready until the parent dispute has supervisor/admin refund approval stamped.';

-- =============================================================================
-- 8. IMPORTER CREDIT APPLICATION
-- =============================================================================

CREATE OR REPLACE FUNCTION apply_importer_credit_to_order(
  p_importer_id uuid,
  p_order_id uuid,
  p_amount_gbp numeric,
  p_staff_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_available numeric := 0;
  v_gap numeric := 0;
  v_applied numeric := 0;
  v_debit_id uuid;
  v_order orders%ROWTYPE;
BEGIN
  IF p_amount_gbp IS NULL OR p_amount_gbp <= 0 THEN
    RAISE EXCEPTION 'Credit application amount must be > 0';
  END IF;

  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Target order % not found', p_order_id;
  END IF;

  IF v_order.importer_id <> p_importer_id THEN
    RAISE EXCEPTION 'Importer % cannot apply credit to order % owned by importer %', p_importer_id, p_order_id, v_order.importer_id;
  END IF;

  IF v_order.order_type = 'replacement_child' THEN
    RAISE EXCEPTION 'Credit cannot be applied to replacement child order % in Phase 1', p_order_id;
  END IF;

  IF v_order.funded_at IS NOT NULL THEN
    RAISE EXCEPTION 'Order % is already platform-funded', p_order_id;
  END IF;

  PERFORM 1
  FROM importer_credit_ledger
  WHERE importer_id = p_importer_id
  FOR UPDATE;

  SELECT COALESCE(ib.available_credit_gbp, 0)
    INTO v_available
  FROM importer_balance_vw ib
  WHERE ib.importer_id = p_importer_id;

  IF v_available <= 0 THEN
    RAISE EXCEPTION 'No available importer credit for importer %', p_importer_id;
  END IF;

  v_gap := order_funding_gap_gbp(p_order_id);

  IF v_gap <= 0 THEN
    RAISE EXCEPTION 'Order % has no remaining funding gap', p_order_id;
  END IF;

  v_applied := LEAST(p_amount_gbp, v_available, v_gap);

  INSERT INTO importer_credit_ledger (
    importer_id,
    entry_type,
    source_table,
    source_id,
    linked_order_id,
    linked_dispute_id,
    direction,
    amount_gbp,
    amount_local_ccy,
    local_ccy,
    effective_at,
    source_type,
    source_entity_type,
    source_entity_id,
    applied_to_order_id,
    lock_reason,
    created_by_staff_id,
    notes
  )
  VALUES (
    p_importer_id,
    'applied_to_order',
    'orders',
    p_order_id,
    p_order_id,
    NULL,
    'debit',
    v_applied,
    0,
    'GBP',
    now(),
    'credit_application',
    'order',
    p_order_id,
    p_order_id,
    NULL,
    p_staff_id,
    'Phase 1 credit application'
  )
  RETURNING id INTO v_debit_id;

  -- Also write the funding event explicitly so the runtime overlay is complete even
  -- before the ledger-sync trigger runs.
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
  VALUES (
    p_order_id,
    'credit_applied',
    v_applied,
    CONCAT('importer_credit_ledger:', v_debit_id::text),
    'importer_credit_ledger',
    v_debit_id,
    p_staff_id,
    now(),
    'Credit applied to original order in Phase 1'
  )
  ON CONFLICT (event_type, source_entity_type, source_entity_id)
  WHERE source_entity_id IS NOT NULL
  DO NOTHING;

  PERFORM recompute_order_platform_funded(p_order_id);

  IF v_applied > 500 THEN
    PERFORM raise_escalation(
      'CREDIT_AMOUNT',
      'importer_credit',
      v_debit_id,
      jsonb_build_object(
        'amount_gbp', v_applied,
        'order_id', p_order_id,
        'staff_id', p_staff_id
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'credit_debit_id', v_debit_id,
    'applied_gbp', v_applied,
    'remaining_available_gbp', v_available - v_applied,
    'remaining_order_gap_gbp', GREATEST(order_funding_gap_gbp(p_order_id), 0),
    'order_platform_funded', (SELECT funded_at IS NOT NULL FROM orders WHERE id = p_order_id),
    'requires_admin_review_yn', entity_requires_admin_review('importer_credit', v_debit_id)
  );
END;
$$;

COMMENT ON FUNCTION apply_importer_credit_to_order(uuid, uuid, numeric, uuid) IS
'Applies available importer credit to an original order only. Partial and repeated applications are allowed until the gap reaches zero. Uses the immutable funding-event overlay and surfaces admin review where thresholds fire.';

-- =============================================================================
-- 9. REPLACEMENT CHILD ORDER CREATION
-- =============================================================================

CREATE OR REPLACE FUNCTION create_replacement_child_order(
  p_parent_order_id uuid,
  p_dispute_line_id uuid,
  p_staff_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_parent orders%ROWTYPE;
  v_dispute_id uuid;
  v_child_id uuid;
  v_sequence int;
  v_qty int;
  v_amount numeric;
  v_parent_has_funding_anomaly boolean := false;
BEGIN
  SELECT *
    INTO v_parent
  FROM orders
  WHERE id = p_parent_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parent order % not found', p_parent_order_id;
  END IF;

  IF v_parent.order_type = 'replacement_child' THEN
    RAISE EXCEPTION 'Cannot create replacement of a replacement in Phase 1';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM escalation_events ee
    JOIN escalation_rules er ON er.id = ee.rule_id
    WHERE ee.entity_type = 'order'
      AND ee.entity_id = p_parent_order_id
      AND ee.resolved_at IS NULL
      AND er.rule_code = 'FUND_LATE_MATCH'
  ) INTO v_parent_has_funding_anomaly;

  IF v_parent.funded_at IS NULL AND NOT v_parent_has_funding_anomaly THEN
    RAISE EXCEPTION 'Parent order % must be platform-funded or explicitly in the funding anomaly queue before replacement can be created', p_parent_order_id;
  END IF;

  SELECT dl.dispute_id,
         GREATEST(COALESCE(dl.qty_impact, 1), 1),
         COALESCE(dl.amount_impact_gbp, 0)
    INTO v_dispute_id, v_qty, v_amount
  FROM dispute_lines dl
  JOIN disputes d
    ON d.id = dl.dispute_id
   AND d.order_id = p_parent_order_id
  WHERE dl.id = p_dispute_line_id
  FOR UPDATE OF dl;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'Dispute line % not found or not linked to parent order %', p_dispute_line_id, p_parent_order_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.replacement_source_dispute_line_id = p_dispute_line_id
  ) THEN
    RAISE EXCEPTION 'Replacement child order already exists for dispute line %', p_dispute_line_id;
  END IF;

  SELECT COUNT(*) + 1
    INTO v_sequence
  FROM orders o
  WHERE o.parent_order_id = p_parent_order_id;

  INSERT INTO orders (
    order_ref,
    payment_auth_id,
    importer_id,
    operator_id,
    shipper_id,
    retailer_id,
    destination_hub_id,
    parent_order_id,
    order_type,
    order_total_gbp_declared,
    total_qty_declared,
    quote_fx_rate,
    quote_card_markup_pct,
    quote_fx_rate_locked,
    quote_card_markup_pct_locked,
    quote_rate_date_locked,
    quote_rate_locked_at,
    status,
    sop_version,
    replacement_source_dispute_line_id,
    funded_at,
    created_at,
    updated_at
  )
  VALUES (
    v_parent.order_ref || '-R' || v_sequence,
    NULL,
    v_parent.importer_id,
    v_parent.operator_id,
    v_parent.shipper_id,
    v_parent.retailer_id,
    v_parent.destination_hub_id,
    p_parent_order_id,
    'replacement_child',
    v_amount,
    v_qty,
    v_parent.quote_fx_rate,
    v_parent.quote_card_markup_pct,
    v_parent.quote_fx_rate_locked,
    v_parent.quote_card_markup_pct_locked,
    v_parent.quote_rate_date_locked,
    v_parent.quote_rate_locked_at,
    'evidence_collecting',
    v_parent.sop_version,
    p_dispute_line_id,
    NULL,
    now(),
    now()
  )
  RETURNING id INTO v_child_id;

  INSERT INTO order_category_lines (
    order_id,
    markup_category_id,
    qty,
    amount_inc_vat_gbp,
    markup_pct_applied,
    markup_gbp_calculated,
    created_at
  )
  SELECT
    v_child_id,
    ocl.markup_category_id,
    v_qty,
    v_amount,
    ocl.markup_pct_applied,
    COALESCE(ocl.markup_gbp_calculated, 0),
    now()
  FROM order_category_lines ocl
  WHERE ocl.order_id = p_parent_order_id
  ORDER BY ocl.id
  LIMIT 1;

  UPDATE disputes
  SET replacement_child_order_id = v_child_id,
      resolved_at = COALESCE(resolved_at, now())
  WHERE id = v_dispute_id;

  UPDATE dispute_lines
  SET resolved_via_child_order_id = v_child_id,
      conversation_status = 'resolved_replacement',
      resolution_method = 'replacement',
      resolved_at = COALESCE(resolved_at, now())
  WHERE id = p_dispute_line_id;

  PERFORM raise_escalation(
    'REPLACEMENT_CHILD',
    'order',
    v_child_id,
    jsonb_build_object(
      'parent_order_id', p_parent_order_id,
      'dispute_line_id', p_dispute_line_id,
      'notes', p_notes,
      'staff_id', p_staff_id
    )
  );

  RETURN v_child_id;
END;
$$;

COMMENT ON FUNCTION create_replacement_child_order(uuid, uuid, uuid, text) IS
'Creates a replacement child order using the actual baseline orders shape. New replacement evidence attaches to the child order; no fresh DVA funding match is required in Phase 1.';

-- =============================================================================
-- 10. SHIPPING QUOTE / ORDER STATUS SYNC HELPERS
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_shipping_quote_confirmed_ready_for_booking(
  p_shipping_quote_id uuid,
  p_staff_id uuid
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_linked_order_count int := 0;
  v_bad_order_count int := 0;
  v_overscope_count int := 0;
  v_closed_order_count int := 0;
  v_staff_role text;
  v_order_id uuid;
BEGIN
  -- Day 5 guardrail: this function represents the explicit supervisor/admin
  -- handoff into the shipper lane. It must not be a generic quote-status setter.
  SELECT s.role_type
    INTO v_staff_role
  FROM staff s
  WHERE s.id = p_staff_id
    AND COALESCE(s.active, true) = true;

  IF COALESCE(v_staff_role, '') NOT IN ('supervisor','admin') THEN
    RAISE EXCEPTION 'Only active supervisor/admin staff may confirm a shipping quote ready for booking. Staff id: %', p_staff_id;
  END IF;

  SELECT COUNT(*)
    INTO v_linked_order_count
  FROM shipping_quote_orders sqo
  WHERE sqo.shipping_quote_id = p_shipping_quote_id;

  IF v_linked_order_count = 0 THEN
    RAISE EXCEPTION 'Cannot confirm shipping quote % because it has no linked orders', p_shipping_quote_id;
  END IF;

  -- Bring linked orders to their current evidence/OCR-derived state before
  -- checking shipment readiness. This avoids relying on stale order.status.
  FOR v_order_id IN
    SELECT DISTINCT sqo.order_id
    FROM shipping_quote_orders sqo
    WHERE sqo.shipping_quote_id = p_shipping_quote_id
  LOOP
    PERFORM recompute_order_status(v_order_id);
  END LOOP;

  -- Every linked order must have a real progressed invoiceable subset.
  SELECT COUNT(*)
    INTO v_bad_order_count
  FROM shipping_quote_orders sqo
  LEFT JOIN order_reconciliation_vw orv
    ON orv.order_id = sqo.order_id
  WHERE sqo.shipping_quote_id = p_shipping_quote_id
    AND COALESCE(orv.invoiceable_subset_released_yn, false) IS DISTINCT FROM true;

  IF v_bad_order_count > 0 THEN
    RAISE EXCEPTION 'Cannot confirm shipping quote % because % linked order(s) have no progressed subset', p_shipping_quote_id, v_bad_order_count;
  END IF;

  -- The quote scope must not include unresolved child-exception value.
  -- shipping_quote_orders.order_value_gbp is the value being handed to shipper;
  -- it cannot exceed the progressed invoiceable value for that order.
  SELECT COUNT(*)
    INTO v_overscope_count
  FROM shipping_quote_orders sqo
  JOIN order_reconciliation_vw orv
    ON orv.order_id = sqo.order_id
  WHERE sqo.shipping_quote_id = p_shipping_quote_id
    AND COALESCE(sqo.order_value_gbp, 0) > COALESCE(orv.amount_progressed_invoiceable_gbp, 0) + 0.01;

  IF v_overscope_count > 0 THEN
    RAISE EXCEPTION 'Cannot confirm shipping quote % because % linked order(s) include value above the progressed subset', p_shipping_quote_id, v_overscope_count;
  END IF;

  SELECT COUNT(*)
    INTO v_closed_order_count
  FROM shipping_quote_orders sqo
  JOIN orders o
    ON o.id = sqo.order_id
  WHERE sqo.shipping_quote_id = p_shipping_quote_id
    AND o.status IN ('completed','archived','cancelled');

  IF v_closed_order_count > 0 THEN
    RAISE EXCEPTION 'Cannot confirm shipping quote % because % linked order(s) are closed/cancelled', p_shipping_quote_id, v_closed_order_count;
  END IF;

  UPDATE shipping_quotes
  SET status = 'confirmed_ready_for_booking'
  WHERE id = p_shipping_quote_id
    AND status = 'draft_quote';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shipping quote % was not in draft_quote status', p_shipping_quote_id;
  END IF;

  -- Multi-order quotes are allowed as batching of orders inside one shipper lane.
  -- Every linked order must receive the explicit ready-for-shipment handoff.
  UPDATE orders o
  SET status = 'ready_for_shipment',
      updated_at = now()
  FROM shipping_quote_orders sqo
  WHERE sqo.order_id = o.id
    AND sqo.shipping_quote_id = p_shipping_quote_id
    AND o.status NOT IN ('ready_for_shipment','completed','archived','cancelled');
END;
$$;

COMMENT ON FUNCTION mark_shipping_quote_confirmed_ready_for_booking(uuid, uuid) IS
'Confirms a draft shipping quote only when every linked order has a progressed subset and the quoted order value does not exceed progressed invoiceable value. This is the explicit supervisor/admin handoff into the shipper lane.';

-- =============================================================================
-- 11. VAT TAX POINT / RELEASE FUNCTIONS
-- =============================================================================

CREATE OR REPLACE FUNCTION derive_order_vat_tax_point(p_order_id uuid)
RETURNS date
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tax_point date;
BEGIN
  SELECT MIN(sq.dispatched_at::date)
    INTO v_tax_point
  FROM shipping_quote_orders sqo
  JOIN shipping_quotes sq
    ON sq.id = sqo.shipping_quote_id
  WHERE sqo.order_id = p_order_id
    AND sq.dispatched_at IS NOT NULL;

  IF v_tax_point IS NOT NULL THEN
    UPDATE orders
    SET vat_tax_point_date = v_tax_point,
        vat_return_period = date_trunc('quarter', v_tax_point::timestamp)::date,
        updated_at = now()
    WHERE id = p_order_id;
  END IF;

  RETURN v_tax_point;
END;
$$;

COMMENT ON FUNCTION derive_order_vat_tax_point(uuid) IS
'Derives the tax point from the earliest shipping quote dispatched_at for the order and stamps vat_tax_point_date / vat_return_period.';

CREATE OR REPLACE FUNCTION approve_vat_release(
  p_order_id uuid,
  p_staff_id uuid,
  p_evidence_json jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_tax_point date;
  v_missing_quote_count int;
  v_open_payout_count int;
  v_open_shipper_liability_count int;
BEGIN
  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  IF v_order.order_type = 'replacement_child' THEN
    RAISE EXCEPTION 'Replacement child order % does not create a fresh VAT release / Box 6 event by default in Phase 1; release the original parent order instead', p_order_id;
  END IF;

  IF v_order.order_type = 'original' AND v_order.funded_at IS NULL THEN
    RAISE EXCEPTION 'Cannot approve VAT release for original order % before platform funding is matched', p_order_id;
  END IF;

  IF order_has_open_child_exceptions(p_order_id) THEN
    RAISE EXCEPTION 'Cannot approve VAT release for order % while child exceptions remain unresolved', p_order_id;
  END IF;

  IF v_order.status = 'discrepancy_open' THEN
    RAISE EXCEPTION 'Cannot approve VAT release for order % while a discrepancy remains open', p_order_id;
  END IF;

  SELECT COUNT(*)
    INTO v_open_payout_count
  FROM payout_requests pr
  JOIN disputes d ON d.id = pr.dispute_id
  WHERE d.order_id = p_order_id
    AND pr.status IN ('requested','approved');

  IF v_open_payout_count > 0 THEN
    RAISE EXCEPTION 'Cannot approve VAT release for order % while payout requests remain open', p_order_id;
  END IF;

  SELECT COUNT(*)
    INTO v_open_shipper_liability_count
  FROM shipper_liabilities sl
  WHERE sl.order_id = p_order_id
    AND sl.resolved_at IS NULL;

  IF v_open_shipper_liability_count > 0 THEN
    RAISE EXCEPTION 'Cannot approve VAT release for order % while shipper liability remains unresolved', p_order_id;
  END IF;

  SELECT COUNT(*)
    INTO v_missing_quote_count
  FROM shipping_quote_orders sqo
  JOIN shipping_quotes sq
    ON sq.id = sqo.shipping_quote_id
  WHERE sqo.order_id = p_order_id
    AND (
      sq.dispatched_at IS NULL
      OR sq.ghana_delivered_at IS NULL
      OR sq.pod_ghana_url IS NULL
      OR (sq.bol_url IS NULL AND sq.commercial_invoice_url IS NULL)
    );

  IF v_missing_quote_count > 0 THEN
    RAISE EXCEPTION 'Cannot approve VAT release for order % because export evidence is incomplete on % shipment lane(s)', p_order_id, v_missing_quote_count;
  END IF;

  v_tax_point := derive_order_vat_tax_point(p_order_id);

  IF v_tax_point IS NULL THEN
    RAISE EXCEPTION 'Cannot approve VAT release for order % before dispatched_at exists on a linked shipping quote', p_order_id;
  END IF;

  UPDATE shipping_quotes sq
  SET zero_rating_evidence_complete_at = COALESCE(sq.zero_rating_evidence_complete_at, now()),
      zero_rating_evidence_checked_by_staff_id = COALESCE(sq.zero_rating_evidence_checked_by_staff_id, p_staff_id)
  FROM shipping_quote_orders sqo
  WHERE sqo.shipping_quote_id = sq.id
    AND sqo.order_id = p_order_id;

  UPDATE orders
  SET vat_rate_applied = COALESCE(vat_rate_applied, 'zero_rated'),
      vat_release_approved_by_staff_id = p_staff_id,
      vat_release_approved_at = now(),
      vat_release_evidence_json = COALESCE(p_evidence_json, '{}'::jsonb),
      status = CASE
                 WHEN status IN ('awaiting_importer_receipt','discrepancy_open') THEN 'awaiting_financial_closure'
                 ELSE status
               END,
      updated_at = now()
  WHERE id = p_order_id;

  RETURN p_order_id;
END;
$$;

COMMENT ON FUNCTION approve_vat_release(uuid, uuid, jsonb) IS
'Admin-facing VAT release checkpoint. Uses the earliest dispatch date as tax point, requires complete export evidence, stable value, and no open child/payout/liability blockers.';

CREATE OR REPLACE FUNCTION post_to_vat_return_workings(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_working_id uuid;
  v_period_label varchar;
  v_generated_by uuid;
  v_box6_total numeric := 0;
BEGIN
  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  IF v_order.order_type = 'replacement_child' THEN
    RAISE EXCEPTION 'Replacement child order % does not create a fresh VAT return working / Box 6 event by default in Phase 1', p_order_id;
  END IF;

  IF v_order.vat_release_approved_at IS NULL THEN
    RAISE EXCEPTION 'Order % has not been VAT-released', p_order_id;
  END IF;

  IF v_order.vat_return_period IS NULL THEN
    RAISE EXCEPTION 'Order % has no derived VAT return period', p_order_id;
  END IF;

  v_period_label := to_char(v_order.vat_return_period, 'YYYY') || '-Q' || extract(quarter from v_order.vat_return_period)::int;
  v_generated_by := COALESCE(v_order.vat_release_approved_by_staff_id, (SELECT s.id FROM staff s WHERE COALESCE(s.active, true) = true ORDER BY s.created_at LIMIT 1));

  SELECT COALESCE(SUM(o.order_total_gbp_declared), 0)
    INTO v_box6_total
  FROM orders o
  WHERE o.vat_release_approved_at IS NOT NULL
    AND o.vat_return_period = v_order.vat_return_period
    AND o.order_type = 'original'
    AND COALESCE(o.vat_rate_applied, 'zero_rated') IN ('zero_rated','standard_rated');

  INSERT INTO vat_return_workings (
    return_period,
    generated_at,
    generated_by_staff_id,
    section_c_total,
    final_box1,
    final_box4,
    final_box6,
    final_box7
  )
  VALUES (
    v_period_label,
    now(),
    v_generated_by,
    v_box6_total,
    0,
    COALESCE((SELECT final_box4 FROM vat_return_workings WHERE return_period = v_period_label), 0),
    v_box6_total,
    COALESCE((SELECT final_box7 FROM vat_return_workings WHERE return_period = v_period_label), 0)
  )
  ON CONFLICT (return_period)
  DO UPDATE SET
    generated_at = EXCLUDED.generated_at,
    generated_by_staff_id = EXCLUDED.generated_by_staff_id,
    section_c_total = EXCLUDED.section_c_total,
    final_box1 = EXCLUDED.final_box1,
    final_box6 = EXCLUDED.final_box6
  RETURNING id INTO v_working_id;

  RETURN v_working_id;
END;
$$;

COMMENT ON FUNCTION post_to_vat_return_workings(uuid) IS
'Updates the period-level vat_return_workings summary using the actual baseline table shape. It is idempotent per return period and only runs after VAT release approval.';

-- =============================================================================
-- 12. ACCOUNTING RELEASE HELPER
-- =============================================================================

CREATE OR REPLACE FUNCTION mark_order_accounting_release_ready(
  p_order_id uuid,
  p_staff_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_open_payout_count int;
BEGIN
  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  IF v_order.order_type = 'original' AND v_order.funded_at IS NULL THEN
    RAISE EXCEPTION 'Cannot mark accounting release ready for original order % before platform funding is matched', p_order_id;
  END IF;

  IF order_has_open_child_exceptions(p_order_id) THEN
    RAISE EXCEPTION 'Cannot mark accounting release ready for order % while child exceptions remain unresolved', p_order_id;
  END IF;

  SELECT COUNT(*)
    INTO v_open_payout_count
  FROM payout_requests pr
  JOIN disputes d ON d.id = pr.dispute_id
  WHERE d.order_id = p_order_id
    AND pr.status IN ('requested','approved');

  IF v_open_payout_count > 0 THEN
    RAISE EXCEPTION 'Cannot mark accounting release ready for order % while payout requests remain open', p_order_id;
  END IF;

  UPDATE orders
  SET accounting_release_ready_at = now(),
      accounting_release_ready_by_staff_id = p_staff_id,
      status = 'awaiting_financial_closure',
      updated_at = now()
  WHERE id = p_order_id;

  RETURN p_order_id;
END;
$$;

COMMENT ON FUNCTION mark_order_accounting_release_ready(uuid, uuid) IS
'Stamps the order as ready for Sage/accounting release once operational truth, funding-control, and financial outcomes are stable enough to release.';

-- =============================================================================
-- 13. OPTIONAL SCHEDULED / ASYNC HELPERS
-- =============================================================================

CREATE OR REPLACE FUNCTION run_fund_late_match_rule()
RETURNS integer
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count integer := 0;
  r record;
BEGIN
  FOR r IN
    SELECT o.id
    FROM orders o
    WHERE o.status IN (
      'evidence_collecting',
      'reconciling',
      'partially_progressed',
      'ready_for_shipment',
      'shipment_booked',
      'shipment_dispatched',
      'awaiting_importer_receipt',
      'discrepancy_open',
      'awaiting_financial_closure'
    )
      AND o.order_type = 'original'
      AND o.funded_at IS NULL
      AND o.created_at < now() - interval '14 days'
  LOOP
    IF raise_escalation(
         'FUND_LATE_MATCH',
         'order',
         r.id,
         jsonb_build_object('created_at_overdue', true)
       ) IS NOT NULL THEN
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION run_fund_late_match_rule() IS
'Scheduled helper that raises FUND_LATE_MATCH for operationally active original orders that still lack platform funding after 14 days.';



-- =============================================================================
-- DAY 7 PORTAL RLS POLICY COVERAGE
-- =============================================================================

-- =============================================================================
-- day7_portal_rls_policy_hotfix.sql
-- Multi Tenant Platform Build — Day 7 portal RLS policy coverage hotfix
--
-- Purpose:
--   Adds the missing thin-portal RLS policy coverage identified by
--   day7_portal_role_boundary_smoke_test.sql.
--
-- Authority stack interpretation:
--   * importer/operator can work on own importer-lane evidence, invoices,
--     OCR lines, disputes, and read shipment allocations tied to own orders.
--   * staff can supervise/administer routine and escalated portal objects.
--   * shipper can see/act only on its own shipping lane and shipper-side disputes.
--   * shipper does not operate importer OCR; no shipper policy is added for
--     supplier_invoices/supplier_invoice_lines.
-- =============================================================================



SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Keep RLS explicitly enabled on the Day 7 portal tables.
ALTER TABLE supplier_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplier_invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE disputes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dispute_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipping_quotes ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipping_quote_orders ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- Importer evidence / OCR portal: supplier_invoices
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS staff_all_supplier_invoices ON supplier_invoices;
CREATE POLICY staff_all_supplier_invoices
ON supplier_invoices
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

DROP POLICY IF EXISTS operator_own_supplier_invoices ON supplier_invoices;
CREATE POLICY operator_own_supplier_invoices
ON supplier_invoices
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.id = supplier_invoices.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.id = supplier_invoices.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

-- -----------------------------------------------------------------------------
-- Importer evidence / OCR portal: supplier_invoice_lines
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS staff_all_supplier_invoice_lines ON supplier_invoice_lines;
CREATE POLICY staff_all_supplier_invoice_lines
ON supplier_invoice_lines
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

DROP POLICY IF EXISTS operator_own_supplier_invoice_lines ON supplier_invoice_lines;
CREATE POLICY operator_own_supplier_invoice_lines
ON supplier_invoice_lines
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM supplier_invoices si
    JOIN orders o ON o.id = si.order_id
    WHERE si.id = supplier_invoice_lines.supplier_invoice_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM supplier_invoices si
    JOIN orders o ON o.id = si.order_id
    WHERE si.id = supplier_invoice_lines.supplier_invoice_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

-- -----------------------------------------------------------------------------
-- Child exception / dispute portal: disputes
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS staff_all_disputes ON disputes;
CREATE POLICY staff_all_disputes
ON disputes
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

DROP POLICY IF EXISTS operator_own_disputes ON disputes;
CREATE POLICY operator_own_disputes
ON disputes
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.id = disputes.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.id = disputes.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

DROP POLICY IF EXISTS shipper_read_own_disputes ON disputes;
CREATE POLICY shipper_read_own_disputes
ON disputes
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.id = disputes.order_id
      AND o.shipper_id = current_shipper_id()
  )
);

-- -----------------------------------------------------------------------------
-- Child exception / dispute portal: dispute_lines
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS staff_all_dispute_lines ON dispute_lines;
CREATE POLICY staff_all_dispute_lines
ON dispute_lines
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

DROP POLICY IF EXISTS operator_own_dispute_lines ON dispute_lines;
CREATE POLICY operator_own_dispute_lines
ON dispute_lines
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM disputes d
    JOIN orders o ON o.id = d.order_id
    WHERE d.id = dispute_lines.dispute_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM disputes d
    JOIN orders o ON o.id = d.order_id
    WHERE d.id = dispute_lines.dispute_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

DROP POLICY IF EXISTS shipper_read_own_dispute_lines ON dispute_lines;
CREATE POLICY shipper_read_own_dispute_lines
ON dispute_lines
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM disputes d
    JOIN orders o ON o.id = d.order_id
    WHERE d.id = dispute_lines.dispute_id
      AND o.shipper_id = current_shipper_id()
  )
);

-- -----------------------------------------------------------------------------
-- Shipping portal / handoff: shipping_quotes
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS staff_all_shipping_quotes ON shipping_quotes;
CREATE POLICY staff_all_shipping_quotes
ON shipping_quotes
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

DROP POLICY IF EXISTS shipper_own_shipping_quotes ON shipping_quotes;
CREATE POLICY shipper_own_shipping_quotes
ON shipping_quotes
FOR ALL
TO public
USING (shipper_id = current_shipper_id())
WITH CHECK (shipper_id = current_shipper_id());

DROP POLICY IF EXISTS operator_read_own_shipping_quotes ON shipping_quotes;
CREATE POLICY operator_read_own_shipping_quotes
ON shipping_quotes
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN orders o ON o.id = sqo.order_id
    WHERE sqo.shipping_quote_id = shipping_quotes.id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

-- -----------------------------------------------------------------------------
-- Shipping portal / handoff: shipping_quote_orders
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS staff_all_shipping_quote_orders ON shipping_quote_orders;
CREATE POLICY staff_all_shipping_quote_orders
ON shipping_quote_orders
FOR ALL
TO public
USING (is_active_staff())
WITH CHECK (is_active_staff());

DROP POLICY IF EXISTS shipper_own_shipping_quote_orders ON shipping_quote_orders;
CREATE POLICY shipper_own_shipping_quote_orders
ON shipping_quote_orders
FOR ALL
TO public
USING (
  EXISTS (
    SELECT 1
    FROM shipping_quotes sq
    WHERE sq.id = shipping_quote_orders.shipping_quote_id
      AND sq.shipper_id = current_shipper_id()
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM shipping_quotes sq
    WHERE sq.id = shipping_quote_orders.shipping_quote_id
      AND sq.shipper_id = current_shipper_id()
  )
);

DROP POLICY IF EXISTS operator_read_own_shipping_quote_orders ON shipping_quote_orders;
CREATE POLICY operator_read_own_shipping_quote_orders
ON shipping_quote_orders
FOR SELECT
TO public
USING (
  EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.id = shipping_quote_orders.order_id
      AND o.importer_id IN (SELECT current_operator_importer_ids())
  )
);

-- =============================================================================
-- VAT TIMING & EXPORT EVIDENCE ADDENDUM V1 OVERRIDES
-- =============================================================================

-- day8_vat_timing_prepayment_hotfix.sql
-- Multi Tenant Platform Build — VAT Timing Addendum v1 hotfix.
-- Applies prepayment/deposit timing over the old dispatch-date-only VAT timing rule.



CREATE OR REPLACE FUNCTION derive_order_vat_tax_point(p_order_id uuid)
RETURNS date
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_prepayment_tax_point date;
  v_dispatch_tax_point date;
  v_tax_point date;
BEGIN
  -- VAT Timing Addendum v1:
  -- For known quoted goods paid in advance, the qualifying prepayment/deposit
  -- date is the VAT timing event to the extent covered by the payment.
  -- Shipment dispatch/export evidence remains the zero-rating checkpoint and
  -- fallback timing event where no qualifying prepayment exists.
  SELECT MIN(COALESCE(dsl.statement_date, dr.reconciled_at::date, ofe.created_at::date))
    INTO v_prepayment_tax_point
  FROM order_funding_events ofe
  LEFT JOIN dva_reconciliation dr
    ON ofe.source_entity_type = 'dva_reconciliation'
   AND ofe.source_entity_id = dr.id
  LEFT JOIN dva_statement_lines dsl
    ON dsl.id = dr.dva_statement_line_id
  WHERE ofe.order_id = p_order_id
    AND ofe.event_type IN ('funding_contribution','credit_applied')
    AND ofe.amount_gbp > 0;

  SELECT MIN(sq.dispatched_at::date)
    INTO v_dispatch_tax_point
  FROM shipping_quote_orders sqo
  JOIN shipping_quotes sq
    ON sq.id = sqo.shipping_quote_id
  WHERE sqo.order_id = p_order_id
    AND sq.dispatched_at IS NOT NULL;

  v_tax_point := COALESCE(v_prepayment_tax_point, v_dispatch_tax_point);

  IF v_tax_point IS NOT NULL THEN
    UPDATE orders
    SET vat_tax_point_date = v_tax_point,
        vat_return_period = date_trunc('quarter', v_tax_point::timestamp)::date,
        updated_at = now()
    WHERE id = p_order_id;
  END IF;

  RETURN v_tax_point;
END;
$$;

COMMENT ON FUNCTION derive_order_vat_tax_point(uuid) IS
'VAT Timing Addendum v1: derives VAT timing from the earliest qualifying prepayment/deposit date where available; falls back to earliest linked shipment dispatched_at only where no qualifying prepayment exists. Export evidence remains the zero-rating release checkpoint.';

COMMENT ON FUNCTION approve_vat_release(uuid, uuid, jsonb) IS
'Admin-facing VAT release checkpoint. VAT Timing Addendum v1: tax point is earliest qualifying prepayment/deposit date where available, otherwise earliest linked dispatch date. Export evidence, stable value, no open child/payout/liability blockers, and funding control remain required before zero-rating release.';


-- VAT Timing Addendum v1 reporting helpers.
-- These support review schedules; they do not post VAT automatically.

CREATE OR REPLACE VIEW vat_prepayment_timing_vw AS
SELECT
  o.id AS order_id,
  o.order_ref,
  o.importer_id,
  o.order_total_gbp_declared,
  MIN(COALESCE(dsl.statement_date, dr.reconciled_at::date, ofe.created_at::date)) AS first_prepayment_tax_point_date,
  date_trunc('quarter', MIN(COALESCE(dsl.statement_date, dr.reconciled_at::date, ofe.created_at::date))::timestamp)::date AS prepayment_return_period,
  SUM(CASE WHEN ofe.event_type IN ('funding_contribution','credit_applied') THEN ofe.amount_gbp ELSE 0 END) AS funding_events_gbp,
  o.vat_tax_point_date,
  o.vat_return_period,
  o.vat_release_approved_at
FROM orders o
JOIN order_funding_events ofe
  ON ofe.order_id = o.id
LEFT JOIN dva_reconciliation dr
  ON ofe.source_entity_type = 'dva_reconciliation'
 AND ofe.source_entity_id = dr.id
LEFT JOIN dva_statement_lines dsl
  ON dsl.id = dr.dva_statement_line_id
WHERE COALESCE(o.order_type, 'original') = 'original'
  AND ofe.event_type IN ('funding_contribution','credit_applied')
  AND ofe.amount_gbp > 0
GROUP BY
  o.id,
  o.order_ref,
  o.importer_id,
  o.order_total_gbp_declared,
  o.vat_tax_point_date,
  o.vat_return_period,
  o.vat_release_approved_at;

COMMENT ON VIEW vat_prepayment_timing_vw IS
'VAT Timing Addendum v1 helper. Shows first qualifying prepayment/deposit timing event and stamped VAT return period for known quoted goods.';

DROP VIEW IF EXISTS vat_export_deadline_breach_candidates_vw;
CREATE VIEW vat_export_deadline_breach_candidates_vw AS
SELECT
  si.id AS source_sales_invoice_id,
  si.order_id,
  o.order_ref,
  o.importer_id,
  si.consideration_received_date AS tax_point_date,
  si.zero_rating_deadline_date,
  si.amount_gbp AS consideration_gbp,
  round((si.amount_gbp / 6.0)::numeric, 2) AS estimated_box1_vat_due_gbp,
  si.zero_rating_status,
  si.vat_adjustment_posted_at,
  to_char(si.zero_rating_deadline_date, 'YYYY') || '-Q' || extract(quarter from si.zero_rating_deadline_date)::int AS deadline_return_period,
  CASE
    WHEN si.zero_rating_status = 'breached' AND si.vat_adjustment_posted_at IS NULL THEN true
    ELSE false
  END AS requires_box1_adjustment_yn
FROM sales_invoices si
JOIN orders o
  ON o.id = si.order_id
WHERE si.invoice_type = 'main'
  AND si.vat_code = 'T0'
  AND si.zero_rating_status IN ('at_risk','breached','reinstated','evidence_complete');

COMMENT ON VIEW vat_export_deadline_breach_candidates_vw IS
'VAT Timing Addendum v1 helper. Surfaces zero-rating deadline breach candidates so staff can post Box 1 breach adjustments when the export/evidence time limit expires, and later reversals if evidence is obtained.';

-- =============================================================================
-- DAY 8 VAT WORKINGS ADJUSTMENT OVERRIDE
-- =============================================================================

CREATE OR REPLACE FUNCTION post_to_vat_return_workings(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_working_id uuid;
  v_period_label varchar;
  v_generated_by uuid;
  v_base_box6_total numeric := 0;
  v_box6_adjustment_total numeric := 0;
  v_final_box6 numeric := 0;
  v_box1_adjustment_total numeric := 0;
  v_breach_total numeric := 0;
  v_reinstatement_total numeric := 0;
BEGIN
  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  IF v_order.order_type = 'replacement_child' THEN
    RAISE EXCEPTION 'Replacement child order % does not create a fresh VAT return working / Box 6 event by default in Phase 1', p_order_id;
  END IF;

  IF v_order.vat_release_approved_at IS NULL THEN
    RAISE EXCEPTION 'Order % has not been VAT-released', p_order_id;
  END IF;

  IF v_order.vat_return_period IS NULL THEN
    RAISE EXCEPTION 'Order % has no derived VAT return period', p_order_id;
  END IF;

  v_period_label := to_char(v_order.vat_return_period, 'YYYY') || '-Q' || extract(quarter from v_order.vat_return_period)::int;

  v_generated_by := COALESCE(
    v_order.vat_release_approved_by_staff_id,
    (SELECT s.id FROM staff s WHERE COALESCE(s.active, true) = true ORDER BY s.created_at LIMIT 1)
  );

  IF v_generated_by IS NULL THEN
    RAISE EXCEPTION 'Cannot post VAT return workings because no active staff user is available for generated_by_staff_id';
  END IF;

  -- Base Box 6: original VAT-released orders whose tax-point period belongs to this return.
  SELECT COALESCE(SUM(o.order_total_gbp_declared), 0)
    INTO v_base_box6_total
  FROM orders o
  WHERE o.vat_release_approved_at IS NOT NULL
    AND o.vat_return_period = v_order.vat_return_period
    AND COALESCE(o.order_type, 'original') = 'original'
    AND COALESCE(o.vat_rate_applied, 'zero_rated') IN ('zero_rated','standard_rated');

  -- Timing adjustments: carry-in adds to the period; carry-out subtracts from the period.
  SELECT COALESCE(SUM(
           CASE vra.direction
             WHEN 'add' THEN vra.amount_gbp
             WHEN 'subtract' THEN -vra.amount_gbp
             ELSE 0
           END
         ), 0)
    INTO v_box6_adjustment_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = v_period_label
    AND vra.report_type IN ('box6_carry_in','box6_carry_out');

  v_final_box6 := v_base_box6_total + v_box6_adjustment_total;

  -- Box 1 adjustment support is retained for the baseline adjustment table shape.
  SELECT COALESCE(SUM(
           CASE vra.direction
             WHEN 'add' THEN vra.amount_gbp
             WHEN 'subtract' THEN -vra.amount_gbp
             ELSE 0
           END
         ), 0)
    INTO v_box1_adjustment_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = v_period_label
    AND vra.report_type IN ('box1_breach','box1_reinstatement');

  SELECT COALESCE(SUM(vra.amount_gbp), 0)
    INTO v_breach_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = v_period_label
    AND vra.report_type = 'box1_breach';

  SELECT COALESCE(SUM(vra.amount_gbp), 0)
    INTO v_reinstatement_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = v_period_label
    AND vra.report_type = 'box1_reinstatement';

  INSERT INTO vat_return_workings (
    return_period,
    generated_at,
    generated_by_staff_id,
    section_c_total,
    breach_total,
    reinstatement_total,
    final_box1,
    final_box4,
    final_box6,
    final_box7
  )
  VALUES (
    v_period_label,
    now(),
    v_generated_by,
    v_base_box6_total,
    v_breach_total,
    v_reinstatement_total,
    v_box1_adjustment_total,
    COALESCE((SELECT final_box4 FROM vat_return_workings WHERE return_period = v_period_label), 0),
    v_final_box6,
    COALESCE((SELECT final_box7 FROM vat_return_workings WHERE return_period = v_period_label), 0)
  )
  ON CONFLICT (return_period)
  DO UPDATE SET
    generated_at = EXCLUDED.generated_at,
    generated_by_staff_id = EXCLUDED.generated_by_staff_id,
    section_c_total = EXCLUDED.section_c_total,
    breach_total = EXCLUDED.breach_total,
    reinstatement_total = EXCLUDED.reinstatement_total,
    final_box1 = EXCLUDED.final_box1,
    final_box6 = EXCLUDED.final_box6
  RETURNING id INTO v_working_id;

  RETURN v_working_id;
END;
$$;

COMMENT ON FUNCTION post_to_vat_return_workings(uuid) IS
'Updates period-level VAT workings after VAT release approval. section_c_total is base Box 6; final_box6 includes vat_return_adjustments carry-in/carry-out timing adjustments and remains idempotent per return period.';



-- =============================================================================
-- PROGRESSIVE COMMERCIAL RELEASE & REPLACEMENT INVOICING ADDENDUM V1
-- =============================================================================

-- Existing schema keeps one MAIN customer sales invoice per commercial parent order.
-- Later stable releases for the same commercial order use SUPPLEMENTARY invoices.
-- Replacement child orders remain operational fulfilment paths; their customer-facing
-- invoice release is still tied to the original commercial parent order.

CREATE OR REPLACE VIEW sales_invoice_released_line_ids_vw AS
SELECT
  si.id AS sales_invoice_id,
  si.order_id AS commercial_order_id,
  (li.elem->>'supplier_invoice_line_id')::uuid AS supplier_invoice_line_id,
  si.invoice_type,
  si.amount_gbp,
  si.sage_status,
  si.created_at
FROM sales_invoices si
CROSS JOIN LATERAL jsonb_array_elements(si.line_items_json) AS li(elem)
WHERE si.sage_status <> 'void'
  AND si.invoice_type IN ('main','supplementary')
  AND li.elem ? 'supplier_invoice_line_id'
  AND (li.elem->>'supplier_invoice_line_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

COMMENT ON VIEW sales_invoice_released_line_ids_vw IS
'Progressive Commercial Release Addendum v1 helper. Extracts supplier invoice line IDs already released to customer sales invoices so later releases cannot duplicate the same line.';

CREATE OR REPLACE VIEW progressive_invoiceable_lines_vw AS
SELECT
  CASE
    WHEN COALESCE(source_order.order_type, 'original') = 'replacement_child' THEN source_order.parent_order_id
    ELSE source_order.id
  END AS commercial_order_id,
  source_order.id AS source_order_id,
  source_order.order_type AS source_order_type,
  sil.id AS supplier_invoice_line_id,
  sil.description,
  sil.qty_confirmed,
  sil.amount_confirmed AS amount_gbp,
  sil.eligible_for_invoice_yn,
  EXISTS (
    SELECT 1
    FROM shipping_quote_orders sqo
    JOIN shipping_quotes sq ON sq.id = sqo.shipping_quote_id
    WHERE sqo.order_id = source_order.id
      AND sq.status IN ('hub_received','dispatched','in_transit','delivered_ghana','closed')
  ) AS source_order_shipper_received_yn,
  EXISTS (
    SELECT 1
    FROM sales_invoice_released_line_ids_vw released
    WHERE released.commercial_order_id = CASE
        WHEN COALESCE(source_order.order_type, 'original') = 'replacement_child' THEN source_order.parent_order_id
        ELSE source_order.id
      END
      AND released.supplier_invoice_line_id = sil.id
  ) AS already_released_to_customer_invoice_yn
FROM supplier_invoice_lines sil
JOIN supplier_invoices si
  ON si.id = sil.supplier_invoice_id
JOIN orders source_order
  ON source_order.id = si.order_id
WHERE sil.eligible_for_invoice_yn = 'Y'
  AND COALESCE(sil.qty_confirmed, 0) > 0
  AND COALESCE(sil.amount_confirmed, 0) > 0
  AND (
    COALESCE(source_order.order_type, 'original') <> 'replacement_child'
    OR source_order.parent_order_id IS NOT NULL
  );

COMMENT ON VIEW progressive_invoiceable_lines_vw IS
'Progressive Commercial Release Addendum v1 helper. Shows stable supplier invoice lines that can be customer-invoiced against the original commercial parent order once the source order has reached UK shipper receipt or later.';

CREATE OR REPLACE FUNCTION create_progressive_customer_invoice_release(
  p_order_id uuid,
  p_staff_id uuid,
  p_sage_invoice_date date DEFAULT CURRENT_DATE,
  p_export_evidence_complete_date date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_input_order orders%ROWTYPE;
  v_commercial_order orders%ROWTYPE;
  v_commercial_order_id uuid;
  v_existing_main_invoice_id uuid;
  v_invoice_type varchar;
  v_invoice_id uuid;
  v_amount_gbp numeric;
  v_line_items_json jsonb;
  v_tax_point_date date;
  v_tax_point_period varchar;
  v_sage_invoice_period varchar;
  v_zero_rating_deadline date;
  v_sage_config_id uuid;
BEGIN
  IF p_staff_id IS NULL THEN
    RAISE EXCEPTION 'Staff id is required for progressive customer invoice release';
  END IF;

  SELECT *
    INTO v_input_order
  FROM orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  v_commercial_order_id := CASE
    WHEN COALESCE(v_input_order.order_type, 'original') = 'replacement_child' THEN v_input_order.parent_order_id
    ELSE v_input_order.id
  END;

  IF v_commercial_order_id IS NULL THEN
    RAISE EXCEPTION 'Replacement child order % has no parent commercial order', p_order_id;
  END IF;

  SELECT *
    INTO v_commercial_order
  FROM orders
  WHERE id = v_commercial_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Commercial parent order % not found', v_commercial_order_id;
  END IF;

  IF COALESCE(v_commercial_order.order_type, 'original') = 'replacement_child' THEN
    RAISE EXCEPTION 'Commercial customer invoice release must attach to the original parent order, not replacement child %', v_commercial_order_id;
  END IF;

  IF v_commercial_order.funded_at IS NULL THEN
    RAISE EXCEPTION 'Cannot customer-invoice order % before original order funding is matched', v_commercial_order_id;
  END IF;

  SELECT id
    INTO v_sage_config_id
  FROM sage_config
  WHERE effective_to IS NULL
  ORDER BY effective_from DESC, version_number DESC
  LIMIT 1;

  IF v_sage_config_id IS NULL THEN
    RAISE EXCEPTION 'Cannot queue progressive customer invoice because no current Sage config exists';
  END IF;

  -- Select all stable, shipper-received or later, not-yet-invoiced lines across
  -- the commercial parent and its replacement child orders.
  SELECT
    COALESCE(SUM(pil.amount_gbp), 0),
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'supplier_invoice_line_id', pil.supplier_invoice_line_id,
          'source_order_id', pil.source_order_id,
          'source_order_type', pil.source_order_type,
          'description', pil.description,
          'qty', pil.qty_confirmed,
          'amount_gbp', pil.amount_gbp
        )
        ORDER BY pil.source_order_id, pil.supplier_invoice_line_id
      ),
      '[]'::jsonb
    )
    INTO v_amount_gbp, v_line_items_json
  FROM progressive_invoiceable_lines_vw pil
  WHERE pil.commercial_order_id = v_commercial_order_id
    AND pil.source_order_shipper_received_yn = true
    AND pil.already_released_to_customer_invoice_yn = false;

  IF COALESCE(v_amount_gbp, 0) <= 0 OR jsonb_array_length(v_line_items_json) = 0 THEN
    RAISE EXCEPTION 'No new stable progressed subset is available for customer invoice release on order %', v_commercial_order_id;
  END IF;

  SELECT id
    INTO v_existing_main_invoice_id
  FROM sales_invoices
  WHERE order_id = v_commercial_order_id
    AND invoice_type = 'main'
    AND sage_status <> 'void'
  ORDER BY created_at
  LIMIT 1;

  v_invoice_type := CASE WHEN v_existing_main_invoice_id IS NULL THEN 'main' ELSE 'supplementary' END;

  v_tax_point_date := derive_order_vat_tax_point(v_commercial_order_id);

  IF v_tax_point_date IS NULL THEN
    RAISE EXCEPTION 'Cannot customer-invoice order % because no VAT timing event exists yet', v_commercial_order_id;
  END IF;

  v_tax_point_period := to_char(v_tax_point_date, 'YYYY') || '-Q' || extract(quarter from v_tax_point_date)::int;
  v_sage_invoice_period := to_char(p_sage_invoice_date, 'YYYY') || '-Q' || extract(quarter from p_sage_invoice_date)::int;
  v_zero_rating_deadline := (v_tax_point_date + INTERVAL '90 days')::date;

  INSERT INTO sales_invoices (
    order_id,
    invoice_type,
    linked_invoice_id,
    consideration_received_date,
    sage_invoice_date,
    tax_point_period,
    sage_invoice_period,
    vat_box6_reported_period,
    amount_gbp,
    vat_code,
    line_items_json,
    export_evidence_complete_date,
    zero_rating_deadline_date,
    zero_rating_status,
    sage_status,
    raised_by_trigger
  )
  VALUES (
    v_commercial_order_id,
    v_invoice_type,
    CASE WHEN v_invoice_type = 'supplementary' THEN v_existing_main_invoice_id ELSE NULL END,
    v_tax_point_date,
    p_sage_invoice_date,
    v_tax_point_period,
    v_sage_invoice_period,
    v_tax_point_period,
    v_amount_gbp,
    'T0',
    v_line_items_json,
    p_export_evidence_complete_date,
    v_zero_rating_deadline,
    CASE WHEN p_export_evidence_complete_date IS NULL THEN 'on_track' ELSE 'evidence_complete' END,
    'draft',
    true
  )
  RETURNING id INTO v_invoice_id;

  INSERT INTO sage_postings (
    event_type,
    source_table,
    source_id,
    posting_type,
    idempotency_key,
    amount_gbp,
    sage_config_version_id,
    status
  )
  VALUES (
    'progressive_customer_invoice_release',
    'sales_invoices',
    v_invoice_id,
    'ar_invoice',
    'sales-invoice:' || v_invoice_id::text,
    v_amount_gbp,
    v_sage_config_id,
    'pending'
  )
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_invoice_id;
END;
$$;

COMMENT ON FUNCTION create_progressive_customer_invoice_release(uuid, uuid, date, date) IS
'Progressive Commercial Release Addendum v1. Creates the first MAIN customer invoice for the first stable progressed subset of an original commercial order, then SUPPLEMENTARY invoices for later stable releases such as late replacement items. Replacement child source lines invoice against the original parent order and do not create fresh funding events or a fresh commercial order.';

DROP VIEW IF EXISTS vat_export_deadline_breach_candidates_vw;
CREATE VIEW vat_export_deadline_breach_candidates_vw AS
SELECT
  si.id AS source_sales_invoice_id,
  si.order_id,
  o.order_ref,
  o.importer_id,
  si.invoice_type,
  si.consideration_received_date AS tax_point_date,
  si.zero_rating_deadline_date,
  si.amount_gbp AS consideration_gbp,
  round((si.amount_gbp / 6.0)::numeric, 2) AS estimated_box1_vat_due_gbp,
  si.zero_rating_status,
  si.vat_adjustment_posted_at,
  to_char(si.zero_rating_deadline_date, 'YYYY') || '-Q' || extract(quarter from si.zero_rating_deadline_date)::int AS deadline_return_period,
  CASE
    WHEN si.zero_rating_status = 'breached' AND si.vat_adjustment_posted_at IS NULL THEN true
    ELSE false
  END AS requires_box1_adjustment_yn
FROM sales_invoices si
JOIN orders o
  ON o.id = si.order_id
WHERE si.invoice_type IN ('main','supplementary')
  AND si.vat_code = 'T0'
  AND si.zero_rating_status IN ('at_risk','breached','reinstated','evidence_complete');

COMMENT ON VIEW vat_export_deadline_breach_candidates_vw IS
'VAT Timing and Progressive Commercial Release addenda helper. Surfaces zero-rating deadline breach candidates for both main and supplementary customer invoice releases.';

COMMIT;



-- day6_8_vat_reporting_clarification_hotfix.sql
-- Multi Tenant Platform Build — Day 6/8 clarification hotfix
-- Splits stable subset invoice release / VAT reporting from final zero-rating evidence clearance.

BEGIN;

-- Sales-invoice-based VAT reporting view.
-- This is the reporting source for Box 6 after progressive commercial release.
-- It includes main and supplementary customer invoice releases and keeps export evidence status visible.
CREATE OR REPLACE VIEW vat_sales_invoice_reporting_vw AS
SELECT
  si.id AS sales_invoice_id,
  si.order_id,
  o.order_ref,
  o.importer_id,
  si.invoice_type,
  si.consideration_received_date,
  si.sage_invoice_date,
  si.tax_point_period,
  si.sage_invoice_period,
  si.vat_box6_reported_period,
  si.amount_gbp,
  si.vat_code,
  si.zero_rating_deadline_date,
  si.zero_rating_status,
  si.export_evidence_complete_date,
  si.vat_adjustment_posted_at,
  si.reversal_posted_at,
  CASE
    WHEN si.zero_rating_status IN ('on_track','at_risk')
     AND si.zero_rating_deadline_date >= CURRENT_DATE THEN true
    ELSE false
  END AS evidence_pending_within_deadline_yn,
  CASE
    WHEN si.zero_rating_status = 'breached'
      OR (si.export_evidence_complete_date IS NULL AND si.zero_rating_deadline_date < CURRENT_DATE)
    THEN true
    ELSE false
  END AS export_evidence_deadline_breached_yn
FROM sales_invoices si
JOIN orders o
  ON o.id = si.order_id
WHERE si.invoice_type IN ('main','supplementary')
  AND si.sage_status <> 'void'
  AND si.vat_code = 'T0'
  AND si.vat_box6_reported_period IS NOT NULL;

COMMENT ON VIEW vat_sales_invoice_reporting_vw IS
'Day 6/8 clarification: sales-invoice-based VAT reporting source. Includes main and supplementary released customer invoice values by vat_box6_reported_period, even where export evidence is still pending but within deadline. Evidence status remains visible for review and breach handling.';

-- Period-based VAT workings helper.
-- This avoids forcing an order-level VAT release/evidence clearance before the period report can be prepared.
CREATE OR REPLACE FUNCTION post_to_vat_return_workings_for_period(
  p_return_period varchar,
  p_staff_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_working_id uuid;
  v_generated_by uuid;
  v_base_box6_total numeric := 0;
  v_box6_adjustment_total numeric := 0;
  v_final_box6 numeric := 0;
  v_box1_adjustment_total numeric := 0;
  v_breach_total numeric := 0;
  v_reinstatement_total numeric := 0;
BEGIN
  IF p_return_period IS NULL OR btrim(p_return_period) = '' THEN
    RAISE EXCEPTION 'Return period is required';
  END IF;

  v_generated_by := COALESCE(
    p_staff_id,
    (SELECT s.id FROM staff s WHERE COALESCE(s.active, true) = true ORDER BY s.created_at LIMIT 1)
  );

  IF v_generated_by IS NULL THEN
    RAISE EXCEPTION 'Cannot post VAT return workings because no staff user is available for generated_by_staff_id';
  END IF;

  -- Base Box 6 is now driven from released customer sales invoice records, not full order totals.
  -- This supports progressive release: main + supplementary invoices without duplicate order values.
  SELECT COALESCE(SUM(vsir.amount_gbp), 0)
    INTO v_base_box6_total
  FROM vat_sales_invoice_reporting_vw vsir
  WHERE vsir.vat_box6_reported_period = p_return_period
    AND vsir.zero_rating_status IN ('on_track','at_risk','evidence_complete','breached','reinstated');

  SELECT COALESCE(SUM(
           CASE vra.direction
             WHEN 'add' THEN vra.amount_gbp
             WHEN 'subtract' THEN -vra.amount_gbp
             ELSE 0
           END
         ), 0)
    INTO v_box6_adjustment_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = p_return_period
    AND vra.report_type IN ('box6_carry_in','box6_carry_out');

  v_final_box6 := v_base_box6_total + v_box6_adjustment_total;

  SELECT COALESCE(SUM(
           CASE vra.direction
             WHEN 'add' THEN vra.amount_gbp
             WHEN 'subtract' THEN -vra.amount_gbp
             ELSE 0
           END
         ), 0)
    INTO v_box1_adjustment_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = p_return_period
    AND vra.report_type IN ('box1_breach','box1_reinstatement');

  SELECT COALESCE(SUM(vra.amount_gbp), 0)
    INTO v_breach_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = p_return_period
    AND vra.report_type = 'box1_breach';

  SELECT COALESCE(SUM(vra.amount_gbp), 0)
    INTO v_reinstatement_total
  FROM vat_return_adjustments vra
  WHERE vra.return_period = p_return_period
    AND vra.report_type = 'box1_reinstatement';

  INSERT INTO vat_return_workings (
    return_period,
    generated_at,
    generated_by_staff_id,
    section_c_total,
    breach_total,
    reinstatement_total,
    final_box1,
    final_box4,
    final_box6,
    final_box7
  )
  VALUES (
    p_return_period,
    now(),
    v_generated_by,
    v_base_box6_total,
    v_breach_total,
    v_reinstatement_total,
    v_box1_adjustment_total,
    COALESCE((SELECT final_box4 FROM vat_return_workings WHERE return_period = p_return_period), 0),
    v_final_box6,
    COALESCE((SELECT final_box7 FROM vat_return_workings WHERE return_period = p_return_period), 0)
  )
  ON CONFLICT (return_period)
  DO UPDATE SET
    generated_at = EXCLUDED.generated_at,
    generated_by_staff_id = EXCLUDED.generated_by_staff_id,
    section_c_total = EXCLUDED.section_c_total,
    breach_total = EXCLUDED.breach_total,
    reinstatement_total = EXCLUDED.reinstatement_total,
    final_box1 = EXCLUDED.final_box1,
    final_box6 = EXCLUDED.final_box6
  RETURNING id INTO v_working_id;

  RETURN v_working_id;
END;
$$;

COMMENT ON FUNCTION post_to_vat_return_workings_for_period(varchar, uuid) IS
'Day 6/8 clarification: posts period VAT workings from released customer sales invoice records. This allows prepayment-timed/on-track zero-rated sales to appear in the VAT return report before final export evidence clearance, while breach/reinstatement adjustments remain separate.';

-- Backward-compatible order-level wrapper.
-- It derives the relevant VAT period from the order's released sales invoices first, then falls back to the order-level VAT period.
CREATE OR REPLACE FUNCTION post_to_vat_return_workings(p_order_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_period_label varchar;
BEGIN
  SELECT *
    INTO v_order
  FROM orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order % not found', p_order_id;
  END IF;

  IF COALESCE(v_order.order_type, 'original') = 'replacement_child' THEN
    RAISE EXCEPTION 'Replacement child order % does not own customer VAT return workings; use the original commercial parent order instead', p_order_id;
  END IF;

  SELECT si.vat_box6_reported_period
    INTO v_period_label
  FROM sales_invoices si
  WHERE si.order_id = p_order_id
    AND si.invoice_type IN ('main','supplementary')
    AND si.sage_status <> 'void'
    AND si.vat_box6_reported_period IS NOT NULL
  ORDER BY si.created_at DESC
  LIMIT 1;

  IF v_period_label IS NULL AND v_order.vat_return_period IS NOT NULL THEN
    v_period_label := to_char(v_order.vat_return_period, 'YYYY') || '-Q' || extract(quarter from v_order.vat_return_period)::int;
  END IF;

  IF v_period_label IS NULL THEN
    RAISE EXCEPTION 'Order % has no sales-invoice VAT reporting period and no order VAT return period', p_order_id;
  END IF;

  RETURN post_to_vat_return_workings_for_period(v_period_label, v_order.vat_release_approved_by_staff_id);
END;
$$;

COMMENT ON FUNCTION post_to_vat_return_workings(uuid) IS
'Day 6/8 clarification wrapper. Posts VAT workings for the relevant sales-invoice VAT period without requiring final zero-rating evidence clearance first. Replacement children do not own the VAT workings; their supplementary customer invoice releases remain attached to the original parent order.';

COMMENT ON FUNCTION approve_vat_release(uuid, uuid, jsonb) IS
'Day 6/8 clarification: this is the final zero-rating evidence clearance checkpoint, not the gate for including an on-track prepayment-timed sale in VAT return reporting. It may still require complete export evidence before final clearance.';

COMMIT;
