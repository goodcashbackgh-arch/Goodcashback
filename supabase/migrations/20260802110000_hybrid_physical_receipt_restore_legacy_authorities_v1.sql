BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Corrective migration only. It restores the exact pre-Build-4 public
-- reconciliation contract and moves the Build-2 hybrid-only guard extension to
-- a new v2 authority without changing its body or its existing trigger binding.

DO $preflight$
DECLARE
  v_guard_fingerprint text;
  v_columns text[];
BEGIN
  IF to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL THEN
    RAISE EXCEPTION 'Expected physical_remedy_allocation_guard_v1() is missing.';
  END IF;
  IF to_regprocedure('public.physical_remedy_allocation_guard_v2()') IS NOT NULL THEN
    RAISE EXCEPTION 'physical_remedy_allocation_guard_v2() already exists; inspect rather than replace.';
  END IF;

  SELECT md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v1()'::regprocedure))
  INTO v_guard_fingerprint;
  IF v_guard_fingerprint IS DISTINCT FROM '32e1d3eb9161cdc3e09114edb8c0d3c0' THEN
    RAISE EXCEPTION 'Unexpected physical_remedy_allocation_guard_v1() baseline: %', v_guard_fingerprint;
  END IF;

  IF to_regclass('public.order_reconciliation_vw') IS NULL THEN
    RAISE EXCEPTION 'Expected public.order_reconciliation_vw is missing.';
  END IF;
  IF to_regclass('public.order_reconciliation_v2_vw') IS NOT NULL THEN
    RAISE EXCEPTION 'public.order_reconciliation_v2_vw already exists; inspect rather than replace.';
  END IF;

  SELECT array_agg(column_name ORDER BY ordinal_position)
  INTO v_columns
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'order_reconciliation_vw';

  IF v_columns IS DISTINCT FROM ARRAY[
    'order_id','qty_target','qty_progressed_invoiceable','qty_resolved_noninvoiceable',
    'qty_unresolved','amount_target_gbp','amount_progressed_invoiceable_gbp',
    'amount_resolved_noninvoiceable_gbp','amount_unresolved_gbp',
    'invoiceable_subset_released_yn','whole_order_cleared_yn','last_refreshed_at'
  ]::text[] THEN
    RAISE EXCEPTION 'Unexpected reconciliation contract: %', v_columns;
  END IF;
END
$preflight$;

-- PostgreSQL triggers bind to the function object, not its text name. Renaming
-- therefore preserves the currently installed hybrid guard and keeps the
-- existing trigger attached to that exact body under the explicit v2 name.
ALTER FUNCTION public.physical_remedy_allocation_guard_v1()
  RENAME TO physical_remedy_allocation_guard_v2;

COMMENT ON FUNCTION public.physical_remedy_allocation_guard_v2() IS
  'Build-2 outcome-specific physical dispute compatibility guard. Versioned from the foundation v1 without changing the installed body.';

-- Recreate the foundation v1 from the now-versioned v2 definition by changing
-- only the function identity and the single Build-2 outcome-link extension.
DO $restore_guard$
DECLARE
  v_definition text;
  v_extended_block text := $extended$
       OR NOT EXISTS (
         SELECT 1
         FROM public.physical_receipt_review_dispute_links link_row
         WHERE link_row.physical_receipt_review_id = v_review.id
           AND link_row.dispute_id = v_dispute_id
           AND link_row.desired_outcome = NEW.approved_remedy_type
       )
$extended$;
  v_foundation_block text := $foundation$
       OR (
         v_review.linked_dispute_id IS NOT NULL
         AND v_review.linked_dispute_id IS DISTINCT FROM v_dispute_id
       )
$foundation$;
BEGIN
  v_definition := pg_get_functiondef(
    'public.physical_remedy_allocation_guard_v2()'::regprocedure
  );

  v_definition := replace(
    v_definition,
    'physical_remedy_allocation_guard_v2',
    'physical_remedy_allocation_guard_v1'
  );

  IF position(v_extended_block IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Could not locate the exact Build-2 guard extension; no restoration performed.';
  END IF;

  v_definition := replace(v_definition, v_extended_block, v_foundation_block);
  EXECUTE v_definition;
END
$restore_guard$;

REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v2()
  FROM PUBLIC, anon, authenticated;

-- Preserve the Build-4 calculation under a new additive name.
CREATE VIEW public.order_reconciliation_v2_vw AS
WITH authoritative_supplier_lines AS (
  SELECT si.order_id,
         sil.id AS supplier_invoice_line_id,
         COALESCE(sil.qty_confirmed, 0)::bigint AS qty_confirmed,
         COALESCE(sil.amount_confirmed, 0)::numeric AS amount_confirmed
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  WHERE si.is_current_for_order = true
    AND si.review_status IN ('approved_current','ref_corrected_approved')
    AND si.blocked_from_sage_yn = false
    AND si.superseded_by_supplier_invoice_id IS NULL
    AND sil.eligible_for_invoice_yn = 'Y'
),
supplier_line_totals AS (
  SELECT order_id,
         COALESCE(SUM(qty_confirmed), 0::numeric)::bigint AS qty_progressed_invoiceable,
         COALESCE(SUM(amount_confirmed), 0::numeric) AS amount_progressed_invoiceable_gbp
  FROM authoritative_supplier_lines
  GROUP BY order_id
),
dispute_line_totals AS (
  SELECT d.order_id,
         COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' AND asl.supplier_invoice_line_id IS NULL THEN dl.qty_impact ELSE 0 END), 0::bigint) AS qty_resolved_noninvoiceable,
         COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' AND asl.supplier_invoice_line_id IS NULL THEN dl.amount_impact_gbp ELSE 0::numeric END), 0::numeric) AS amount_resolved_dispute_gbp
  FROM public.disputes d
  JOIN public.dispute_lines dl ON dl.dispute_id = d.id
  LEFT JOIN authoritative_supplier_lines asl
    ON asl.order_id = d.order_id
   AND asl.supplier_invoice_line_id = dl.supplier_invoice_line_id
  GROUP BY d.order_id
),
resolved_nonphysical AS (
  SELECT r.order_id,
         COALESCE(SUM(
           CASE r.financial_type
             WHEN 'delivery' THEN ABS(COALESCE(r.amount_gbp, 0::numeric))
             WHEN 'fee' THEN ABS(COALESCE(r.amount_gbp, 0::numeric))
             WHEN 'discount' THEN -ABS(COALESCE(r.amount_gbp, 0::numeric))
             WHEN 'zero_value_delivery' THEN 0::numeric
             ELSE 0::numeric
           END
         ), 0::numeric) AS signed_nonphysical_amount_gbp
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.active = true AND r.resolution_type = 'non_physical_financial'
  GROUP BY r.order_id
),
reconciled AS (
  SELECT o.id AS order_id,
         o.total_qty_declared AS qty_target,
         COALESCE(slt.qty_progressed_invoiceable, 0::bigint) AS qty_progressed_invoiceable,
         COALESCE(dlt.qty_resolved_noninvoiceable, 0::bigint) AS qty_resolved_noninvoiceable,
         o.total_qty_declared - COALESCE(slt.qty_progressed_invoiceable, 0::bigint) - COALESCE(dlt.qty_resolved_noninvoiceable, 0::bigint) AS qty_unresolved,
         o.order_total_gbp_declared AS amount_target_gbp,
         COALESCE(slt.amount_progressed_invoiceable_gbp, 0::numeric) AS amount_progressed_invoiceable_gbp,
         COALESCE(dlt.amount_resolved_dispute_gbp, 0::numeric) + COALESCE(rn.signed_nonphysical_amount_gbp, 0::numeric) AS amount_resolved_noninvoiceable_gbp,
         o.order_total_gbp_declared - COALESCE(slt.amount_progressed_invoiceable_gbp, 0::numeric) - COALESCE(dlt.amount_resolved_dispute_gbp, 0::numeric) - COALESCE(rn.signed_nonphysical_amount_gbp, 0::numeric) AS amount_unresolved_gbp,
         EXISTS (SELECT 1 FROM authoritative_supplier_lines released WHERE released.order_id = o.id) AS invoiceable_subset_released_yn
  FROM public.orders o
  LEFT JOIN supplier_line_totals slt ON slt.order_id = o.id
  LEFT JOIN dispute_line_totals dlt ON dlt.order_id = o.id
  LEFT JOIN resolved_nonphysical rn ON rn.order_id = o.id
)
SELECT r.order_id,
       r.qty_target,
       r.qty_progressed_invoiceable,
       r.qty_resolved_noninvoiceable,
       r.qty_unresolved,
       r.amount_target_gbp,
       r.amount_progressed_invoiceable_gbp,
       r.amount_resolved_noninvoiceable_gbp,
       r.amount_unresolved_gbp,
       r.invoiceable_subset_released_yn,
       (
         r.qty_unresolved = 0
         AND r.amount_unresolved_gbp = 0::numeric
         AND r.qty_progressed_invoiceable + r.qty_resolved_noninvoiceable <= r.qty_target
         AND r.amount_progressed_invoiceable_gbp + r.amount_resolved_noninvoiceable_gbp <= r.amount_target_gbp
       ) AS whole_order_cleared_yn,
       now() AS last_refreshed_at
FROM reconciled r;

COMMENT ON VIEW public.order_reconciliation_v2_vw IS
  'Versioned Build-4 authoritative-supplier reconciliation. Existing public.order_reconciliation_vw remains the legacy authority.';

REVOKE ALL ON public.order_reconciliation_v2_vw FROM PUBLIC, anon;
GRANT SELECT ON public.order_reconciliation_v2_vw TO authenticated, service_role;

-- Restore the exact pre-Build-4 public view definition. CREATE OR REPLACE is
-- required here solely to reverse the already-applied view replacement while
-- preserving dependent-object identity and grants.
CREATE OR REPLACE VIEW public.order_reconciliation_vw AS
WITH resolved_nonphysical AS (
  SELECT r.order_id,
    COALESCE(SUM(
      CASE r.financial_type
        WHEN 'delivery' THEN ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'fee' THEN ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'discount' THEN -ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'zero_value_delivery' THEN 0::numeric
        ELSE 0::numeric
      END
    ), 0)::numeric AS signed_nonphysical_amount_gbp
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.active = true
    AND r.resolution_type = 'non_physical_financial'
  GROUP BY r.order_id
)
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
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    + COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0)
    AS amount_resolved_noninvoiceable_gbp,
  o.order_total_gbp_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    - COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0)
    AS amount_unresolved_gbp,
  CASE WHEN EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil2
    JOIN public.supplier_invoices si2 ON si2.id = sil2.supplier_invoice_id
    WHERE si2.order_id = o.id
      AND sil2.eligible_for_invoice_yn = 'Y'
  ) THEN true ELSE false END AS invoiceable_subset_released_yn,
  CASE WHEN (
    o.total_qty_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) = 0
    AND o.order_total_gbp_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
      - COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0) = 0
  ) THEN true ELSE false END AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM public.orders o
LEFT JOIN public.supplier_invoices si ON si.order_id = o.id
LEFT JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
LEFT JOIN public.disputes d ON d.order_id = o.id
LEFT JOIN public.dispute_lines dl ON dl.dispute_id = d.id
LEFT JOIN resolved_nonphysical rn ON rn.order_id = o.id
GROUP BY o.id, o.total_qty_declared, o.order_total_gbp_declared;

COMMENT ON VIEW public.order_reconciliation_vw IS
  'Baseline order reconciliation preserved, with active non-physical financial resolutions added once per order using explicit commercial sign: delivery/fee positive, discount negative and zero-value delivery zero. Ambiguous types remain unresolved.';

DO $postflight$
DECLARE
  v_trigger_function text;
  v_legacy_view_fingerprint text;
BEGIN
  SELECT p.proname
  INTO v_trigger_function
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = 'public.physical_exception_remedy_allocations'::regclass
    AND t.tgname = 'trg_physical_remedy_allocation_guard_v1'
    AND NOT t.tgisinternal;

  IF v_trigger_function IS DISTINCT FROM 'physical_remedy_allocation_guard_v2' THEN
    RAISE EXCEPTION 'Hybrid remedy trigger did not remain bound to v2: %', v_trigger_function;
  END IF;

  SELECT md5(definition)
  INTO v_legacy_view_fingerprint
  FROM pg_views
  WHERE schemaname = 'public' AND viewname = 'order_reconciliation_vw';

  IF v_legacy_view_fingerprint IS DISTINCT FROM '89cc95922a2b8ec1fa040ba79f12907a' THEN
    RAISE EXCEPTION 'Legacy reconciliation was not restored exactly: %', v_legacy_view_fingerprint;
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
