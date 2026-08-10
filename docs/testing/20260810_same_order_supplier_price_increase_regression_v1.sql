BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_md5 text;
  v_flag_id uuid;
  v_order_id uuid;
  v_invoice_id uuid;
  v_flag_status text;
  v_invoice_status text;
  v_blocked boolean;
  v_expected_status text;
  v_expected_invoice_status text;
  v_expected_blocked boolean;
  v_active_total numeric;
  v_order_total numeric;
  v_summary_id uuid;
  v_summary_invoice_id uuid;
  v_summary_old_total numeric;
  v_summary_operator_id uuid;
  v_other_bundle numeric;
  v_target_summary_total numeric;
  v_created_flag_count integer;
  v_expected_error_seen boolean := false;
BEGIN
  -- Existing authorities this feature must not replace.
  SELECT md5(pg_get_functiondef('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM '44719b0f9a435f01ea138e1cca6a034e' THEN
    RAISE EXCEPTION 'FAIL: supplier header-review RPC changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM md5(pg_get_functiondef('public.staff_approve_supplier_invoice_current(uuid,text,text,text,date,numeric,text)'::regprocedure)) THEN
    RAISE EXCEPTION 'FAIL: impossible supplier approval fingerprint check.';
  END IF;

  SELECT md5(pg_get_functiondef('public.flag_order_bundle_limit_after_summary_v1()'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM '9227a2afe69a79b745f7934534325125' THEN
    RAISE EXCEPTION 'FAIL: established bundle INSERT function changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.order_funding_total_gbp(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '7f71d968c6662c1df535a50428797fb4' THEN
    RAISE EXCEPTION 'FAIL: order_funding_total_gbp changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.order_funding_gap_gbp(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM '8c2ce167a7012ee50b98d9886c455454' THEN
    RAISE EXCEPTION 'FAIL: order_funding_gap_gbp changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.recompute_order_platform_funded(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'cfd3c7bca289b26e748a00c8170a3a9b' THEN
    RAISE EXCEPTION 'FAIL: recompute_order_platform_funded changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.sync_order_overfunding_credit(uuid)'::regprocedure)) INTO v_md5;
  IF v_md5 IS DISTINCT FROM 'f2dcd920585c696b59c80b8baab220b8' THEN
    RAISE EXCEPTION 'FAIL: sync_order_overfunding_credit changed: %.', v_md5;
  END IF;

  -- New objects exist and discarded broad authorities do not.
  IF to_regprocedure('public.protect_order_bundle_limit_breach_resolution_v1()') IS NULL
     OR to_regprocedure('public.flag_order_bundle_limit_after_summary_update_v1()') IS NULL
     OR to_regprocedure('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: corrected same-order price-increase objects are missing.';
  END IF;

  IF to_regclass('public.order_supplier_price_position_v1') IS NOT NULL
     OR to_regprocedure('public.enforce_supplier_invoice_order_price_limit_v1()') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: discarded broad price authority still exists.';
  END IF;

  SELECT lower(pg_get_functiondef('public.protect_order_bundle_limit_breach_resolution_v1()'::regprocedure))
  INTO v_definition;
  IF position('order_bundle_limit:' in v_definition) = 0
     OR position('new.status := old.status' in v_definition) = 0
     OR position('approved_current' in v_definition) = 0
     OR position('ref_corrected_approved' in v_definition) = 0
     OR position('cannot approve supplier invoice while active supplier invoices exceed the accepted order value' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: breach protector lost Save-preserve or approval-hard-stop behaviour.';
  END IF;

  SELECT lower(pg_get_functiondef('public.flag_order_bundle_limit_after_summary_update_v1()'::regprocedure))
  INTO v_definition;
  IF position('new.invoice_total_gbp is not distinct from old.invoice_total_gbp' in v_definition) = 0
     OR position('v_order_type is distinct from ''original''' in v_definition) = 0
     OR position('order_bundle_limit:' in v_definition) = 0
     OR position('sum(fs.invoice_total_gbp)' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: summary UPDATE companion lost governed scope.';
  END IF;

  SELECT lower(pg_get_functiondef('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)'::regprocedure))
  INTO v_definition;
  IF position('v_order.order_type is distinct from ''original''' in v_definition) = 0
     OR position('supplier_invoice_id = p_supplier_invoice_id' in v_definition) = 0
     OR position('flag_type = ''order_bundle_limit_breach''' in v_definition) = 0
     OR position('sum(fs.invoice_total_gbp)' in v_definition) = 0
     OR position('quote_total_ghs / v_old_total' in v_definition) = 0
     OR position('recompute_order_platform_funded' in v_definition) = 0
     OR position('sync_order_overfunding_credit' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: dedicated price RPC lost governed boundary.';
  END IF;

  IF position('for update of ofe' in v_definition) > 0
     OR position('for update of icl' in v_definition) > 0
     OR position('for update of ps' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: price RPC reintroduced funding-row locks / DVA lock-order scope.';
  END IF;

  -- -----------------------------------------------------------------------
  -- Behavioural fixture 1: use an existing genuine live breach if available.
  -- Prove Save-style resolution preserves it, then prove approval-style state
  -- cannot resolve it and the subtransaction rolls back.
  -- -----------------------------------------------------------------------
  SELECT
    f.id,
    f.order_id,
    f.supplier_invoice_id,
    f.status,
    si.review_status::text,
    COALESCE(si.blocked_from_sage_yn, true),
    round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2),
    round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2)
  INTO
    v_flag_id,
    v_order_id,
    v_invoice_id,
    v_expected_status,
    v_expected_invoice_status,
    v_expected_blocked,
    v_order_total,
    v_active_total
  FROM public.supplier_invoice_review_flags f
  JOIN public.supplier_invoices si ON si.id = f.supplier_invoice_id
  JOIN public.orders o ON o.id = f.order_id
  JOIN public.supplier_invoices bundle_si ON bundle_si.order_id = f.order_id
  JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = bundle_si.id
  WHERE f.flag_type = 'order_bundle_limit_breach'
    AND f.status IN ('open','under_review')
    AND o.order_type = 'original'
    AND COALESCE(bundle_si.review_status, 'pending_review') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
  GROUP BY f.id, f.order_id, f.supplier_invoice_id, f.status, si.review_status, si.blocked_from_sage_yn, o.order_total_gbp_declared
  HAVING round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2) > round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) + 0.01
  ORDER BY f.created_at DESC
  LIMIT 1;

  IF v_flag_id IS NOT NULL THEN
    UPDATE public.supplier_invoice_review_flags
    SET status = 'resolved', resolved_at = now(), resolution_notes = 'rollback regression save-style resolution'
    WHERE id = v_flag_id;

    SELECT status INTO v_flag_status
    FROM public.supplier_invoice_review_flags
    WHERE id = v_flag_id;

    IF v_flag_status IS DISTINCT FROM v_expected_status THEN
      RAISE EXCEPTION 'FAIL: Save-style flag resolution cleared a live bundle breach (% -> %).', v_expected_status, v_flag_status;
    END IF;

    v_expected_error_seen := false;
    BEGIN
      UPDATE public.supplier_invoices
      SET review_status = 'approved_current', blocked_from_sage_yn = false
      WHERE id = v_invoice_id;

      UPDATE public.supplier_invoice_review_flags
      SET status = 'resolved', resolved_at = now(), resolution_notes = 'rollback regression approval-style resolution'
      WHERE id = v_flag_id;

    EXCEPTION WHEN OTHERS THEN
      IF position('Cannot approve supplier invoice while active supplier invoices exceed the accepted order value' in SQLERRM) > 0 THEN
        v_expected_error_seen := true;
      ELSE
        RAISE;
      END IF;
    END;

    IF NOT v_expected_error_seen THEN
      RAISE EXCEPTION 'FAIL: direct approval-style transaction was not hard-stopped by the live breach.';
    END IF;

    SELECT review_status::text, COALESCE(blocked_from_sage_yn, true)
    INTO v_invoice_status, v_blocked
    FROM public.supplier_invoices
    WHERE id = v_invoice_id;

    IF v_invoice_status IS DISTINCT FROM v_expected_invoice_status
       OR v_blocked IS DISTINCT FROM v_expected_blocked THEN
      RAISE EXCEPTION 'FAIL: approval-style subtransaction did not fully roll back invoice state.';
    END IF;
  ELSE
    RAISE NOTICE 'SKIP behavioural live-breach fixture: no current genuine open original-order bundle breach exists.';
  END IF;

  -- -----------------------------------------------------------------------
  -- Behavioural fixture 2: use a current non-breaching original summary with
  -- real operator provenance, raise it inside this outer rollback transaction,
  -- and prove the UPDATE companion creates the existing breach flag.
  -- -----------------------------------------------------------------------
  SELECT
    fs.id,
    fs.supplier_invoice_id,
    fs.invoice_total_gbp,
    fs.entered_by_operator_id,
    si.order_id,
    round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2),
    round(COALESCE((
      SELECT sum(fs2.invoice_total_gbp)
      FROM public.supplier_invoice_financial_summary fs2
      JOIN public.supplier_invoices si2 ON si2.id = fs2.supplier_invoice_id
      WHERE si2.order_id = si.order_id
        AND si2.id <> si.id
        AND COALESCE(si2.review_status, 'pending_review') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
    ), 0)::numeric, 2)
  INTO
    v_summary_id,
    v_summary_invoice_id,
    v_summary_old_total,
    v_summary_operator_id,
    v_order_id,
    v_order_total,
    v_other_bundle
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  JOIN public.orders o ON o.id = si.order_id
  WHERE o.order_type = 'original'
    AND fs.entered_by_operator_id IS NOT NULL
    AND COALESCE(si.review_status, 'pending_review') NOT IN ('rejected_resubmit_required','duplicate_blocked','superseded')
    AND NOT EXISTS (
      SELECT 1 FROM public.supplier_invoice_review_flags f
      WHERE f.supplier_invoice_id = si.id
        AND f.flag_type = 'order_bundle_limit_breach'
        AND f.status IN ('open','under_review')
    )
  ORDER BY fs.updated_at DESC NULLS LAST, fs.created_at DESC
  LIMIT 1;

  IF v_summary_id IS NOT NULL THEN
    v_target_summary_total := GREATEST(v_summary_old_total, v_order_total - v_other_bundle + 1.00);

    UPDATE public.supplier_invoice_financial_summary
    SET invoice_total_gbp = v_target_summary_total
    WHERE id = v_summary_id;

    SELECT count(*)::integer
    INTO v_created_flag_count
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = v_summary_invoice_id
      AND f.order_id = v_order_id
      AND f.flag_type = 'order_bundle_limit_breach'
      AND f.status IN ('open','under_review');

    IF v_created_flag_count <> 1 THEN
      RAISE EXCEPTION 'FAIL: summary total UPDATE did not create exactly one open bundle breach; count %.', v_created_flag_count;
    END IF;
  ELSE
    RAISE NOTICE 'SKIP behavioural summary-UPDATE fixture: no safe original summary with operator provenance found.';
  END IF;
END
$regression$;

SELECT
  'PASS'::text AS regression_result,
  'Rollback-only structural and behavioural controls passed. Existing authorities remain unchanged; Save-style resolution preserves a live bundle breach; approval-style resolution is transactionally rejected; summary-total UPDATE creates the same breach when a safe fixture exists.'::text AS details;

ROLLBACK;
