-- =============================================================================
-- closure_v2_seed.sql
-- Multi Tenant Platform Build — additive Phase 1 closure seed/config pack
-- Governing sources:
--   1. Architecture Completion Addendum v2
--   2. Canonical Schema Reference v1
--   3. SAGE_POSTING_MATRIX_v1
--
-- Baseline expected:
--   * goodcashback-complete.v3.sql already applied
--   * closure_v2_migration.sql already applied
--   * closure_v2_functions.sql already applied
--
-- Scope of this seed pack:
--   * rules-as-data seed rows
--   * canonical status transition seeds
--   * safe default installation seed for Phase 1 multi-tenant mode
--   * no tenant/business-specific secrets or live SOP content
--   * no multi-shipper-per-order architecture in Phase 1
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PHASE 1 INSTALLATION DEFAULT
--    Safe only when no installation row exists yet.
-- =============================================================================
INSERT INTO installation (
  deployment_mode,
  active_shipper_id,
  platform_name_override,
  default_tenant_branding_id,
  netp_status,
  uk_vat_number,
  vat_return_frequency,
  markup_enabled_global
)
SELECT
  'multi_tenant',
  NULL,
  NULL,
  NULL,
  true,
  NULL,
  'monthly',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM installation
);

COMMENT ON TABLE installation IS
'Installation seed defaults to multi_tenant in Phase 1 if no row exists. Country is jurisdiction; shipper is the tenant lane.';

-- =============================================================================
-- 1. ESCALATION RULES — rules-as-data seed
--    Locked to Addendum v2 Phase 1 model. No multi-shipper-per-order rules.
-- =============================================================================
INSERT INTO escalation_rules (
  rule_code,
  event_type,
  description,
  threshold_numeric,
  threshold_interval,
  route_to,
  active
)
SELECT *
FROM (
  VALUES
    (
      'ORDER_AMOUNT_IMPACT_GT_250',
      'financial_impact',
      'Route to admin when amount_impact_gbp exceeds the default Phase 1 governance threshold of GBP 250.00.',
      250.00::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'FUND_AUTH_MISMATCH',
      'funding_reconciliation',
      'Route to admin when same-auth override is requested or auth mismatch is not cleanly explained.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'EVIDENCE_OWNERSHIP_MISMATCH',
      'evidence_integrity',
      'Route to admin when screenshot, tracking, invoice, or operator/importer linkage is attached to the wrong entity.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'FUND_MANUAL_OVERRIDE',
      'funding_reconciliation',
      'Route to admin when a manual funding reconciliation is attempted without a clean importer + auth + amount trail.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'FUND_LATE_MATCH',
      'funding_state',
      'Route to admin when an original order is operationally active for more than 14 days and funding remains unmatched.',
      NULL::numeric,
      interval '14 days',
      'admin',
      true
    ),
    (
      'PAYOUT_REQUEST_PRESENT',
      'payout_request',
      'Any importer payout request requires admin review before release.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'CREDIT_MANUAL_OR_LOCKED_SOURCE',
      'importer_credit',
      'Route to admin when a manual credit adjustment is created or when credit remains tied to an unresolved exception, payout, or hold.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'CREDIT_AMOUNT',
      'importer_credit',
      'Route to admin when a single importer-credit application exceeds GBP 500.00.',
      500.00::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'REFUND_AMOUNT',
      'refund_approval',
      'Route to admin when a refund amount exceeds GBP 500.00.',
      500.00::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'SHIPPER_LIABILITY_DISPUTED_OR_MATERIAL',
      'shipper_liability',
      'Route to admin when shipper liability is disputed, partial, or materially affects value/governance.',
      250.00::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'VAT_OVERRIDE_REQUESTED',
      'vat_release',
      'Any manual VAT period override, Box 6 timing override, or exceptional zero-rating treatment requires admin review.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'POLICY_OVERRIDE_REQUIRED',
      'governance',
      'Supervisor explicitly marked policy_override_required = true.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'SHIPPING_QUOTE_TOTAL_GT_2000',
      'shipping_quote',
      'Route to admin when a shipping quote total exceeds GBP 2,000.00.',
      2000.00::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'SAGE_POST_FAIL_AFTER_3',
      'sage_posting',
      'Route to admin when a Sage posting remains failed after 3 retries.',
      3::numeric,
      NULL::interval,
      'admin',
      true
    ),
    (
      'REPLACEMENT_CHILD',
      'replacement_child',
      'Route to admin when a replacement child order is created so governance can review the non-routine outcome.',
      NULL::numeric,
      NULL::interval,
      'admin',
      true
    )
) AS seed (
  rule_code,
  event_type,
  description,
  threshold_numeric,
  threshold_interval,
  route_to,
  active
)
WHERE NOT EXISTS (
  SELECT 1
  FROM escalation_rules er
  WHERE er.rule_code = seed.rule_code
);

-- Keep existing rows but align descriptions/thresholds for locked Phase 1 rules.
UPDATE escalation_rules er
SET event_type = seed.event_type,
    description = seed.description,
    threshold_numeric = seed.threshold_numeric,
    threshold_interval = seed.threshold_interval,
    route_to = seed.route_to,
    active = seed.active
FROM (
  VALUES
    ('ORDER_AMOUNT_IMPACT_GT_250','financial_impact','Route to admin when amount_impact_gbp exceeds the default Phase 1 governance threshold of GBP 250.00.',250.00::numeric,NULL::interval,'admin',true),
    ('FUND_AUTH_MISMATCH','funding_reconciliation','Route to admin when same-auth override is requested or auth mismatch is not cleanly explained.',NULL::numeric,NULL::interval,'admin',true),
    ('EVIDENCE_OWNERSHIP_MISMATCH','evidence_integrity','Route to admin when screenshot, tracking, invoice, or operator/importer linkage is attached to the wrong entity.',NULL::numeric,NULL::interval,'admin',true),
    ('FUND_MANUAL_OVERRIDE','funding_reconciliation','Route to admin when a manual funding reconciliation is attempted without a clean importer + auth + amount trail.',NULL::numeric,NULL::interval,'admin',true),
    ('FUND_LATE_MATCH','funding_state','Route to admin when an original order is operationally active for more than 14 days and funding remains unmatched.',NULL::numeric,interval '14 days','admin',true),
    ('PAYOUT_REQUEST_PRESENT','payout_request','Any importer payout request requires admin review before release.',NULL::numeric,NULL::interval,'admin',true),
    ('CREDIT_MANUAL_OR_LOCKED_SOURCE','importer_credit','Route to admin when a manual credit adjustment is created or when credit remains tied to an unresolved exception, payout, or hold.',NULL::numeric,NULL::interval,'admin',true),
    ('CREDIT_AMOUNT','importer_credit','Route to admin when a single importer-credit application exceeds GBP 500.00.',500.00::numeric,NULL::interval,'admin',true),
    ('REFUND_AMOUNT','refund_approval','Route to admin when a refund amount exceeds GBP 500.00.',500.00::numeric,NULL::interval,'admin',true),
    ('SHIPPER_LIABILITY_DISPUTED_OR_MATERIAL','shipper_liability','Route to admin when shipper liability is disputed, partial, or materially affects value/governance.',250.00::numeric,NULL::interval,'admin',true),
    ('VAT_OVERRIDE_REQUESTED','vat_release','Any manual VAT period override, Box 6 timing override, or exceptional zero-rating treatment requires admin review.',NULL::numeric,NULL::interval,'admin',true),
    ('POLICY_OVERRIDE_REQUIRED','governance','Supervisor explicitly marked policy_override_required = true.',NULL::numeric,NULL::interval,'admin',true),
    ('SHIPPING_QUOTE_TOTAL_GT_2000','shipping_quote','Route to admin when a shipping quote total exceeds GBP 2,000.00.',2000.00::numeric,NULL::interval,'admin',true),
    ('SAGE_POST_FAIL_AFTER_3','sage_posting','Route to admin when a Sage posting remains failed after 3 retries.',3::numeric,NULL::interval,'admin',true),
    ('REPLACEMENT_CHILD','replacement_child','Route to admin when a replacement child order is created so governance can review the non-routine outcome.',NULL::numeric,NULL::interval,'admin',true)
) AS seed (
  rule_code,
  event_type,
  description,
  threshold_numeric,
  threshold_interval,
  route_to,
  active
)
WHERE er.rule_code = seed.rule_code;

-- =============================================================================
-- 2. STATUS_TRANSITIONS — deactivate legacy active rows for Phase 1 entities
--    and insert canonical active transitions.
-- =============================================================================
UPDATE status_transitions
SET active = false
WHERE entity_type IN ('order','shipping_quote','dispute_line')
  AND active = true;

-- 2.1 Canonical order transitions (Phase 1 parent-order lifecycle)
INSERT INTO status_transitions (
  entity_type,
  from_status,
  to_status,
  required_conditions_json,
  actor_roles_allowed,
  active
)
SELECT *
FROM (
  VALUES
    ('order','draft','pending_dva_funding', '{"requires_quote_acceptance": true, "requires_payment_auth_id": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('order','pending_dva_funding','evidence_collecting', '{"requires_any_evidence": true}'::jsonb, ARRAY['operator','supervisor','admin','system']::text[], true),
    ('order','pending_dva_funding','reconciling', '{"requires_invoice_present": true}'::jsonb, ARRAY['operator','supervisor','admin','system']::text[], true),
    ('order','evidence_collecting','reconciling', '{"requires_invoice_present": true}'::jsonb, ARRAY['operator','supervisor','admin','system']::text[], true),
    ('order','reconciling','partially_progressed', '{"requires_progressed_subset": true, "requires_open_child_exception": true}'::jsonb, ARRAY['operator','supervisor','admin','system']::text[], true),
    ('order','reconciling','ready_for_shipment', '{"requires_progressed_subset": true, "requires_no_open_child_exception_affecting_shipment_scope": true}'::jsonb, ARRAY['operator','supervisor','admin','system']::text[], true),
    ('order','partially_progressed','ready_for_shipment', '{"requires_supervisor_handoff": true}'::jsonb, ARRAY['supervisor','admin','system']::text[], true),
    ('order','ready_for_shipment','shipment_booked', '{"requires_confirmed_shipping_quote_and_booking_ref": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('order','shipment_booked','shipment_dispatched', '{"requires_dispatched_at": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('order','shipment_dispatched','awaiting_importer_receipt', '{"requires_ghana_delivery_evidence": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('order','awaiting_importer_receipt','discrepancy_open', '{"requires_importer_discrepancy": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('order','awaiting_importer_receipt','awaiting_financial_closure', '{"requires_importer_receipt_confirmation": true}'::jsonb, ARRAY['operator','supervisor','admin','system']::text[], true),
    ('order','discrepancy_open','awaiting_financial_closure', '{"requires_discrepancy_resolution": true}'::jsonb, ARRAY['supervisor','admin','system']::text[], true),
    ('order','awaiting_financial_closure','completed', '{"requires_all_closure_gates": true}'::jsonb, ARRAY['supervisor','admin','system']::text[], true),
    ('order','completed','archived', '{"requires_archive_action_or_aged_completion": true}'::jsonb, ARRAY['admin','system']::text[], true),
    ('order','draft','cancelled', '{"requires_void_before_live_execution": true}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('order','pending_dva_funding','cancelled', '{"requires_void_before_live_execution": true}'::jsonb, ARRAY['supervisor','admin']::text[], true)
) AS seed (
  entity_type,
  from_status,
  to_status,
  required_conditions_json,
  actor_roles_allowed,
  active
)
WHERE NOT EXISTS (
  SELECT 1
  FROM status_transitions st
  WHERE st.entity_type = seed.entity_type
    AND st.from_status = seed.from_status
    AND st.to_status = seed.to_status
    AND st.active = true
);

-- 2.2 Canonical shipping quote transitions (Phase 1 shipment lane)
INSERT INTO status_transitions (
  entity_type,
  from_status,
  to_status,
  required_conditions_json,
  actor_roles_allowed,
  active
)
SELECT *
FROM (
  VALUES
    ('shipping_quote','draft_quote','confirmed_ready_for_booking', '{"requires_scope_confirmed": true, "requires_progressed_subset_only": true}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('shipping_quote','confirmed_ready_for_booking','booked', '{"requires_booking_ref": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('shipping_quote','booked','hub_received', '{"requires_hub_receipt": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('shipping_quote','booked','dispatched', '{"requires_dispatched_at": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('shipping_quote','hub_received','dispatched', '{"requires_dispatched_at": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('shipping_quote','dispatched','in_transit', '{"requires_export_lane_started": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('shipping_quote','in_transit','delivered_ghana', '{"requires_pod_and_ghana_delivery": true}'::jsonb, ARRAY['shipper_user','supervisor','admin','system']::text[], true),
    ('shipping_quote','delivered_ghana','closed', '{"requires_no_active_shipment_work": true}'::jsonb, ARRAY['supervisor','admin','system']::text[], true),
    ('shipping_quote','draft_quote','cancelled', '{"requires_no_live_execution": true}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('shipping_quote','confirmed_ready_for_booking','cancelled', '{"requires_no_live_execution": true}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('shipping_quote','booked','cancelled', '{"requires_admin_or_supervisor_void_before_dispatch": true}'::jsonb, ARRAY['supervisor','admin']::text[], true)
) AS seed (
  entity_type,
  from_status,
  to_status,
  required_conditions_json,
  actor_roles_allowed,
  active
)
WHERE NOT EXISTS (
  SELECT 1
  FROM status_transitions st
  WHERE st.entity_type = seed.entity_type
    AND st.from_status = seed.from_status
    AND st.to_status = seed.to_status
    AND st.active = true
);

-- 2.3 Canonical dispute-line transitions (reassert current locked child-exception machine)
INSERT INTO status_transitions (
  entity_type,
  from_status,
  to_status,
  required_conditions_json,
  actor_roles_allowed,
  active
)
SELECT *
FROM (
  VALUES
    ('dispute_line','child_exception_created','remedy_selected', '{"requires_intended_remedy": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','remedy_selected','refund_pending_approval', '{"intended_remedy": "refund"}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','remedy_selected','retailer_draft_ready', '{"intended_remedy": "replacement", "requires_ai_draft": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','refund_pending_approval','retailer_draft_ready', '{"intended_remedy": "refund", "requires_dispute_refund_approval": true, "requires_ai_draft": true}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('dispute_line','refund_pending_approval','remedy_selected', '{"approval_denied_or_changed": true}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('dispute_line','retailer_draft_ready','retailer_contacted', '{"requires_outbound_message": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','retailer_contacted','retailer_response_received', '{"requires_retailer_reply_paste": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','retailer_response_received','ai_next_draft_ready', '{"requires_ai_generation": true, "requires_sop_and_status_context": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','ai_next_draft_ready','retailer_contacted', '{"requires_outbound_message": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','retailer_response_received','awaiting_retailer_resolution', '{"awaiting_final_retailer_outcome": true}'::jsonb, ARRAY['operator','supervisor','admin']::text[], true),
    ('dispute_line','awaiting_retailer_resolution','resolved_refund', '{"resolution_method": "refund"}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('dispute_line','awaiting_retailer_resolution','resolved_replacement', '{"resolution_method": "replacement"}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('dispute_line','awaiting_retailer_resolution','resolved_credit', '{"resolution_method": "credit"}'::jsonb, ARRAY['supervisor','admin']::text[], true),
    ('dispute_line','awaiting_retailer_resolution','closed_no_action', '{"resolution_method": "closed_no_action"}'::jsonb, ARRAY['supervisor','admin']::text[], true)
) AS seed (
  entity_type,
  from_status,
  to_status,
  required_conditions_json,
  actor_roles_allowed,
  active
)
WHERE NOT EXISTS (
  SELECT 1
  FROM status_transitions st
  WHERE st.entity_type = seed.entity_type
    AND st.from_status = seed.from_status
    AND st.to_status = seed.to_status
    AND st.active = true
);

-- =============================================================================
-- 3. OPTIONAL LIVE-BUSINESS CONTENT TEMPLATES (NOT AUTO-SEEDED)
--    These remain business/environment specific and should be inserted after
--    the first admin/staff users, retailers, and shippers exist.
-- =============================================================================
-- Global SOP (requires live staff id and final content)
-- INSERT INTO sops (version, content_md, effective_date, published_by_staff_id)
-- VALUES ('v1.0', '<your live SOP markdown>', CURRENT_DATE, '<staff_uuid>');

-- Retailer SOP initial version rows (requires live retailer ids and content)
-- Use update_retailer_sop(retailer_id, content_md, staff_id) from closure_v2_functions.sql
-- rather than inserting future versions manually.

-- Courier / FX / Sage config / branding rows remain environment-specific and are
-- intentionally excluded from this generic seed pack.

-- =============================================================================
-- 4. PHASE 1 GUARDRAIL COMMENTS
-- =============================================================================
COMMENT ON TABLE escalation_rules IS
'Phase 1 rules-as-data seed. Multi-shipper-per-order routing rules are intentionally excluded because they are out of scope.';

COMMENT ON TABLE status_transitions IS
'Canonical active transitions for Phase 1 orders, shipping quotes, and child-exception flow. Legacy rows are preserved inactive for audit/history.';

COMMIT;
