BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_trigger_definition text;
  v_md5 text;
  v_flag_id uuid;
  v_order_id uuid;
  v_invoice_id uuid;
  v_flag_status text;
  v_expected_status text;
  v_invoice_status text;
  v_expected_invoice_status text;
  v_blocked boolean;
  v_expected_blocked boolean;
  v_active_total numeric;
  v_order_total numeric;
  v_expected_error_seen boolean := false;
BEGIN
  -- Frozen existing authorities.
  SELECT md5(pg_get_functiondef('public.staff_save_supplier_invoice_header_review(uuid,text,text,text,date,numeric,numeric,numeric,text)'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM '44719b0f9a435f01ea138e1cca6a034e' THEN
    RAISE EXCEPTION 'FAIL: supplier header-review RPC changed: %.', v_md5;
  END IF;

  SELECT md5(pg_get_functiondef('public.flag_order_bundle_limit_after_summary_v1()'::regprocedure))
  INTO v_md5;
  IF v_md5 IS DISTINCT FROM '9227a2afe69a79b745f7934534325125' THEN
    RAISE EXCEPTION 'FAIL: established operator bundle INSERT function changed: %.', v_md5;
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

  IF to_regprocedure('public.protect_order_bundle_limit_breach_resolution_v1()') IS NULL
     OR to_regprocedure('public.flag_order_bundle_limit_after_supervisor_summary_change_v1()') IS NULL
     OR to_regprocedure('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: corrected same-order price-increase objects are missing.';
  END IF;

  IF to_regclass('public.order_supplier_price_position_v1') IS NOT NULL
     OR to_regprocedure('public.enforce_supplier_invoice_order_price_limit_v1()') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: discarded broad price authority exists.';
  END IF;

  -- Gap 1: protector is original-order only.
  SELECT lower(pg_get_functiondef('public.protect_order_bundle_limit_breach_resolution_v1()'::regprocedure))
  INTO v_definition;
  IF position('select o.order_type::text' in v_definition) = 0
     OR position('v_order_type is distinct from ''original''' in v_definition) = 0
     OR position('return new' in v_definition) = 0
     OR position('new.status := old.status' in v_definition) = 0
     OR position('cannot approve supplier invoice while active supplier invoices exceed the accepted order value' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: original-only breach protector boundary is incomplete.';
  END IF;

  -- Gap 2: exact supervisor-entered INSERT + total UPDATE seam.
  SELECT lower(pg_get_functiondef('public.flag_order_bundle_limit_after_supervisor_summary_change_v1()'::regprocedure))
  INTO v_definition;
  IF position('tg_op = ''insert''' in v_definition) = 0
     OR position('tg_op = ''update''' in v_definition) = 0
     OR position('new.source is distinct from ''supervisor_entered''' in v_definition) = 0
     OR position('new.invoice_total_gbp is not distinct from old.invoice_total_gbp' in v_definition) = 0
     OR position('v_order_type is distinct from ''original''' in v_definition) = 0
     OR position('genuine operator provenance is missing' in v_definition) = 0
     OR position('sum(fs.invoice_total_gbp)' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: supervisor summary companion lost governed boundary.';
  END IF;

  SELECT lower(pg_get_triggerdef(t.oid, true))
  INTO v_trigger_definition
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.supplier_invoice_financial_summary'::regclass
    AND t.tgname = 'trg_flag_order_bundle_limit_after_supervisor_summary_change_v1'
    AND NOT t.tgisinternal;

  IF v_trigger_definition IS NULL
     OR position('after insert or update of invoice_total_gbp' in v_trigger_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: supervisor summary trigger is not limited to INSERT + invoice_total_gbp UPDATE.';
  END IF;

  -- Gap 3: accepted gross is validation-only; summary remains monetary authority.
  SELECT lower(pg_get_functiondef('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)'::regprocedure))
  INTO v_definition;
  IF position('supplier_invoice_accounting_coding_totals_vw' in v_definition) = 0
     OR position('accepted_invoice_gross_gbp' in v_definition) = 0
     OR position('abs(fs.invoice_total_gbp - t.accepted_invoice_gross_gbp) > 0.01' in v_definition) = 0
     OR position('reconcile the supplier invoice total first' in v_definition) = 0
     OR position('sum(fs.invoice_total_gbp)' in v_definition) = 0
     OR position('v_order.order_type is distinct from ''original''' in v_definition) = 0
     OR position('quote_total_ghs / v_old_total' in v_definition) = 0
     OR position('recompute_order_platform_funded' in v_definition) = 0
     OR position('sync_order_overfunding_credit' in v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: dedicated price RPC lost governed stale-summary/funding boundary.';
  END IF;

  IF position('v_new_total := ' in v_definition) > 0
     AND position('accepted_invoice_gross_gbp' in substring(v_definition from position('v_new_total := ' in v_definition) for 300)) > 0 THEN
    RAISE EXCEPTION 'FAIL: accepted gross appears to have become monetary authority.';
  END IF;

  IF position('for update of ofe' in v_definition) > 0
     OR position('for update of icl' in v_definition) > 0
     OR position('for update of ps' in v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: price RPC reintroduced funding-row locks.';
  END IF;

  -- Behavioural proof when a genuine current original-order breach fixture exists.
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
      RAISE EXCEPTION 'FAIL: Save cleared a live original-order bundle breach.';
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
      RAISE EXCEPTION 'FAIL: approval-style transaction was not blocked by live original-order breach.';
    END IF;

    SELECT review_status::text, COALESCE(blocked_from_sage_yn, true)
    INTO v_invoice_status, v_blocked
    FROM public.supplier_invoices
    WHERE id = v_invoice_id;

    IF v_invoice_status IS DISTINCT FROM v_expected_invoice_status
       OR v_blocked IS DISTINCT FROM v_expected_blocked THEN
      RAISE EXCEPTION 'FAIL: blocked approval did not roll back invoice state.';
    END IF;
  ELSE
    RAISE NOTICE 'No current original-order live-breach fixture; structural controls still enforced.';
  END IF;

  -- Non-original regression: if a historical non-original bundle flag exists,
  -- the new protector must not preserve it. Outer transaction rolls everything back.
  v_flag_id := NULL;
  SELECT f.id, f.status
  INTO v_flag_id, v_expected_status
  FROM public.supplier_invoice_review_flags f
  JOIN public.orders o ON o.id = f.order_id
  WHERE f.flag_type = 'order_bundle_limit_breach'
    AND f.status IN ('open','under_review')
    AND o.order_type IS DISTINCT FROM 'original'
  ORDER BY f.created_at DESC
  LIMIT 1;

  IF v_flag_id IS NOT NULL THEN
    UPDATE public.supplier_invoice_review_flags
    SET status = 'resolved', resolved_at = now(), resolution_notes = 'rollback regression non-original unaffected'
    WHERE id = v_flag_id;

    SELECT status INTO v_flag_status
    FROM public.supplier_invoice_review_flags
    WHERE id = v_flag_id;

    IF v_flag_status IS DISTINCT FROM 'resolved' THEN
      RAISE EXCEPTION 'FAIL: new protector changed non-original bundle-flag resolution behaviour.';
    END IF;
  END IF;
END
$regression$;

SELECT
  'PASS'::text AS regression_result,
  'Protected authorities unchanged; original-only breach protection, supervisor INSERT/UPDATE seam, and per-invoice stale-summary validator are structurally enforced. Available live fixtures are exercised inside this rollback-only transaction.'::text AS details;

ROLLBACK;
