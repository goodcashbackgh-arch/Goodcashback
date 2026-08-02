-- Rollback-only authority-versioning structural and reconciliation regression v1.
BEGIN;

DO $guards$
DECLARE
  v_v1_hash text;
  v_v2_hash text;
  v_v1_owner oid;
  v_v2_owner oid;
  v_public oid := 0;
  v_anon oid;
  v_authenticated oid;
BEGIN
  IF to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL
     OR to_regprocedure('public.physical_remedy_allocation_guard_v2()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: v1 or v2 guard is missing';
  END IF;
  SELECT oid INTO v_anon FROM pg_roles WHERE rolname = 'anon';
  SELECT oid INTO v_authenticated FROM pg_roles WHERE rolname = 'authenticated';
  SELECT md5(concat_ws('|', p.prosrc, l.lanname, p.provolatile, p.prosecdef::text,
    p.proisstrict::text, p.proparallel, p.proleakproof::text,
    p.prorettype::regtype::text, p.proargtypes::text,
    coalesce(array_to_string(p.proconfig, ','), ''))), p.proowner
  INTO v_v1_hash, v_v1_owner FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure;
  SELECT md5(concat_ws('|', p.prosrc, l.lanname, p.provolatile, p.prosecdef::text,
    p.proisstrict::text, p.proparallel, p.proleakproof::text,
    p.prorettype::regtype::text, p.proargtypes::text,
    coalesce(array_to_string(p.proconfig, ','), ''))), p.proowner
  INTO v_v2_hash, v_v2_owner FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
  WHERE p.oid = 'public.physical_remedy_allocation_guard_v2()'::regprocedure;
  IF v_v1_hash <> '404fff52528bbd7d963df8809e6f23a9' THEN
    RAISE EXCEPTION 'FAIL: v1 is not exact foundation behavior (%)', v_v1_hash;
  END IF;
  IF v_v2_hash <> '821eacb226a9d52b2048228f97b480d4' THEN
    RAISE EXCEPTION 'FAIL: v2 is not exact Build 2 behavior (%)', v_v2_hash;
  END IF;
  IF v_v1_owner IS DISTINCT FROM v_v2_owner OR v_v1_owner IS DISTINCT FROM current_user::regrole::oid THEN
    RAISE EXCEPTION 'FAIL: guard owners are not the expected migration owner';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_physical_remedy_allocation_guard_v1'
       AND tgfoid = 'public.physical_remedy_allocation_guard_v2()'::regprocedure AND NOT tgisinternal)
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgfoid = 'public.physical_remedy_allocation_guard_v1()'::regprocedure AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'FAIL: trigger is not bound by OID exclusively to v2';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_proc p
    CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    WHERE p.oid IN ('public.physical_remedy_allocation_guard_v1()'::regprocedure,
                    'public.physical_remedy_allocation_guard_v2()'::regprocedure)
      AND a.grantee IN (v_public, v_anon, v_authenticated) AND a.privilege_type = 'EXECUTE'
  ) THEN RAISE EXCEPTION 'FAIL: unsafe guard execution privilege'; END IF;
END
$guards$;

DO $views$
DECLARE v_md5 text; v_bad bigint;
BEGIN
  SELECT md5(definition) INTO v_md5 FROM pg_views
  WHERE schemaname = 'public' AND viewname = 'order_reconciliation_vw';
  IF v_md5 <> '89cc95922a2b8ec1fa040ba79f12907a' THEN
    RAISE EXCEPTION 'FAIL: legacy reconciliation is not legacy (%)', v_md5;
  END IF;
  IF to_regclass('public.order_reconciliation_v2_vw') IS NULL THEN RAISE EXCEPTION 'FAIL: v2 view missing'; END IF;

  -- Every v2 progressed supplier line must be current, approved, unblocked and non-superseded;
  -- the comparison also proves each approved authoritative line is included exactly once.
  WITH expected AS (
    SELECT si.order_id, coalesce(sum(coalesce(sil.qty_confirmed,0)),0)::bigint qty,
           coalesce(sum(coalesce(sil.amount_confirmed,0)),0)::numeric amount
    FROM public.supplier_invoices si JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id=si.id
    WHERE si.is_current_for_order=true
      AND si.review_status IN ('approved_current','ref_corrected_approved')
      AND si.blocked_from_sage_yn=false AND si.superseded_by_supplier_invoice_id IS NULL
      AND sil.eligible_for_invoice_yn='Y' GROUP BY si.order_id
  )
  SELECT count(*) INTO v_bad FROM public.order_reconciliation_v2_vw r LEFT JOIN expected e ON e.order_id=r.order_id
  WHERE r.qty_progressed_invoiceable IS DISTINCT FROM coalesce(e.qty,0)
     OR r.amount_progressed_invoiceable_gbp IS DISTINCT FROM coalesce(e.amount,0);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'FAIL: v2 supplier authority inclusion/exclusion mismatch for % orders', v_bad; END IF;

  -- Resolved dispute evidence represented by an authoritative line must not be counted twice.
  WITH authoritative AS (
    SELECT si.order_id,sil.id FROM public.supplier_invoices si JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id=si.id
    WHERE si.is_current_for_order=true AND si.review_status IN ('approved_current','ref_corrected_approved')
      AND si.blocked_from_sage_yn=false AND si.superseded_by_supplier_invoice_id IS NULL AND sil.eligible_for_invoice_yn='Y'
  ), expected AS (
    SELECT d.order_id, coalesce(sum(CASE WHEN dl.line_status='resolved' AND a.id IS NULL THEN dl.qty_impact ELSE 0 END),0)::bigint qty
    FROM public.disputes d JOIN public.dispute_lines dl ON dl.dispute_id=d.id
    LEFT JOIN authoritative a ON a.order_id=d.order_id AND a.id=dl.supplier_invoice_line_id GROUP BY d.order_id
  ) SELECT count(*) INTO v_bad FROM public.order_reconciliation_v2_vw r LEFT JOIN expected e ON e.order_id=r.order_id
    WHERE r.qty_resolved_noninvoiceable IS DISTINCT FROM coalesce(e.qty,0);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'FAIL: authoritative invoice/dispute evidence double-counted'; END IF;

  -- Delivery and fee are positive, discount negative; over-progress can never clear.
  IF EXISTS (SELECT 1 FROM public.order_reconciliation_v2_vw
    WHERE whole_order_cleared_yn AND (qty_progressed_invoiceable+qty_resolved_noninvoiceable>qty_target
      OR amount_progressed_invoiceable_gbp+amount_resolved_noninvoiceable_gbp>amount_target_gbp)) THEN
    RAISE EXCEPTION 'FAIL: over-progress cleared an order';
  END IF;
  WITH authoritative AS (
    SELECT si.order_id,sil.id FROM public.supplier_invoices si JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id=si.id
    WHERE si.is_current_for_order=true AND si.review_status IN ('approved_current','ref_corrected_approved')
      AND si.blocked_from_sage_yn=false AND si.superseded_by_supplier_invoice_id IS NULL AND sil.eligible_for_invoice_yn='Y'
  ), disputes AS (
    SELECT d.order_id, coalesce(sum(CASE WHEN dl.line_status='resolved' AND a.id IS NULL THEN dl.amount_impact_gbp ELSE 0 END),0)::numeric amount
    FROM public.disputes d JOIN public.dispute_lines dl ON dl.dispute_id=d.id
    LEFT JOIN authoritative a ON a.order_id=d.order_id AND a.id=dl.supplier_invoice_line_id GROUP BY d.order_id
  ), nonphysical AS (
    SELECT order_id, coalesce(sum(CASE financial_type WHEN 'delivery' THEN abs(coalesce(amount_gbp,0))
      WHEN 'fee' THEN abs(coalesce(amount_gbp,0)) WHEN 'discount' THEN -abs(coalesce(amount_gbp,0))
      WHEN 'zero_value_delivery' THEN 0 ELSE 0 END),0)::numeric amount
    FROM public.supplier_invoice_line_resolutions WHERE active=true AND resolution_type='non_physical_financial' GROUP BY order_id
  ) SELECT count(*) INTO v_bad FROM public.order_reconciliation_v2_vw r
    LEFT JOIN disputes d ON d.order_id=r.order_id LEFT JOIN nonphysical n ON n.order_id=r.order_id
    WHERE r.amount_resolved_noninvoiceable_gbp IS DISTINCT FROM coalesce(d.amount,0)+coalesce(n.amount,0);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'FAIL: signed delivery, fee or discount behavior mismatch'; END IF;

  IF EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite rw ON d.classid='pg_rewrite'::regclass AND rw.oid=d.objid
      WHERE rw.ev_class='public.order_reconciliation_anomalies_v1'::regclass AND d.refobjid='public.order_reconciliation_vw'::regclass)
     OR NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite rw ON d.classid='pg_rewrite'::regclass AND rw.oid=d.objid
      WHERE rw.ev_class='public.order_reconciliation_anomalies_v1'::regclass AND d.refobjid='public.order_reconciliation_v2_vw'::regclass) THEN
    RAISE EXCEPTION 'FAIL: anomaly output is not based on v2';
  END IF;
END
$views$;

SELECT jsonb_build_object('regression_result','PASS','proof','versioned guards, legacy/v2 reconciliation, authoritative evidence, signed non-physical handling, over-progress prevention and anomaly dependency verified') AS regression_result;

ROLLBACK;
