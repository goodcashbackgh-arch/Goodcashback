BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_order_id uuid := 'd2acf50b-5b8e-476d-b5ad-2578289f4cce'::uuid;
  v_pending_id uuid := '0a97a5ef-c691-4a09-b41b-f1de8d8bb5da'::uuid;
  v_supplier_fx_id uuid := 'e51c5ea9-f15e-4df5-8d43-32afd1d3e929'::uuid;
  v_auth_uid uuid;
  v_evidence record;
  v_before_settlement record;
  v_after_settlement record;
  v_after_pending record;
  v_result jsonb;
  v_repeat jsonb;
  v_credit_id uuid;
  v_provenance_id uuid;
  v_count integer;
  v_amount numeric;
  v_fx_before jsonb;
  v_fx_after jsonb;
  v_source_used_before numeric;
  v_source_used_after numeric;
  v_sage_before text;
  v_sage_after text;
  v_funding_fx_def_before text;
  v_funding_fx_def_after text;
BEGIN
  IF to_regprocedure('public.staff_confirm_pending_receipt_surplus_credit_v1(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: new pending receipt surplus credit wrapper is missing.';
  END IF;
  IF to_regclass('public.order_pending_surplus_credit_resolution_provenance_v1') IS NULL THEN
    RAISE EXCEPTION 'FAIL: new pending-credit provenance table is missing.';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'FAIL: sage_posting_snapshots is missing; protected Sage fingerprint cannot be proved.';
  END IF;
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: established funding-time FX RPC is missing.';
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM public.order_pending_surplus_credit_resolution_provenance_v1;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: provenance table contains % rows before new-path action; no backfill is permitted.', v_count;
  END IF;

  -- P=0 compatibility: current settlement FX must remain the established sum of
  -- active explicit action FX and unambiguous supplier-OUT FX for every order.
  IF EXISTS (
    WITH active_action AS (
      SELECT a.order_id,
             ROUND(COALESCE(SUM(a.fx_card_difference_gbp) FILTER (WHERE a.status = 'active'), 0)::numeric, 2) AS fx_gbp
      FROM public.order_settlement_resolution_actions a
      GROUP BY a.order_id
    ), raw_supplier AS (
      SELECT supplier_order.order_id,
             ROUND(COALESCE(SUM(ABS(COALESCE(NULLIF(fx.fx_or_card_diff_gbp, 0), fx.allocated_gbp_amount, 0))), 0)::numeric, 2) AS fx_gbp
      FROM public.dva_statement_line_allocations fx
      JOIN public.dva_statement_lines dsl ON dsl.id = fx.dva_statement_line_id
      JOIN public.dva_statements ds ON ds.id = dsl.dva_statement_id
      JOIN LATERAL (
        WITH supplier_orders AS (
          SELECT DISTINCT COALESCE(si.order_id, sa.order_id) AS order_id
          FROM public.dva_statement_line_allocations sa
          LEFT JOIN public.supplier_invoices si ON si.id = sa.supplier_invoice_id
          WHERE sa.dva_statement_line_id = fx.dva_statement_line_id
            AND sa.allocation_status = 'confirmed'
            AND sa.allocation_type = 'supplier_invoice'
            AND COALESCE(si.order_id, sa.order_id) IS NOT NULL
        )
        SELECT so.order_id FROM supplier_orders so
        WHERE (SELECT COUNT(*) FROM supplier_orders) = 1
      ) supplier_order ON true
      WHERE fx.allocation_type = 'fx_card_difference'
        AND fx.allocation_status = 'confirmed'
        AND dsl.direction = 'out'
        AND COALESCE(ds.statement_account_context, 'importer_dva_card_account') = 'importer_dva_card_account'
      GROUP BY supplier_order.order_id
    )
    SELECT 1
    FROM public.order_settlement_resolution_position_v1 p
    LEFT JOIN active_action aa ON aa.order_id = p.order_id
    LEFT JOIN raw_supplier rs ON rs.order_id = p.order_id
    WHERE ROUND(COALESCE(p.settlement_fx_card_difference_gbp, 0)::numeric, 2)
          IS DISTINCT FROM ROUND((COALESCE(aa.fx_gbp, 0) + COALESCE(rs.fx_gbp, 0))::numeric, 2)
  ) THEN
    RAISE EXCEPTION 'FAIL: P=0 compatibility changed existing settlement FX output.';
  END IF;

  -- Pending rows with no confirmed final balance retain the old pending formula.
  IF EXISTS (
    WITH fb AS (
      SELECT a.order_id, ROUND(SUM(a.allocated_gbp_amount)::numeric, 2) AS amount_gbp
      FROM public.dva_statement_line_allocations a
      WHERE a.allocation_type = 'final_balance_payment'
        AND a.allocation_status = 'confirmed'
        AND a.order_id IS NOT NULL
      GROUP BY a.order_id
    )
    SELECT 1
    FROM public.order_surplus_evidence_position_v3 v3
    LEFT JOIN fb ON fb.order_id = v3.order_id
    WHERE v3.pending_position_count > 0
      AND COALESCE(fb.amount_gbp, 0) = 0
      AND (
        ROUND(v3.effective_receipt_gbp::numeric, 2)
          IS DISTINCT FROM ROUND((v3.funding_total_gbp + v3.pending_surplus_gbp)::numeric, 2)
        OR ROUND(v3.evidence_surplus_gbp::numeric, 2)
          IS DISTINCT FROM ROUND((v3.funding_total_gbp + v3.pending_surplus_gbp - v3.evidence_value_gbp)::numeric, 2)
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: pending rows without final-balance payments changed.';
  END IF;

  -- Non-pending rows remain v2-compatible.
  IF EXISTS (
    SELECT 1
    FROM public.order_surplus_evidence_position_v3 v3
    JOIN public.order_surplus_evidence_position_v2 v2 ON v2.order_id = v3.order_id
    WHERE v3.pending_position_count = 0
      AND (
        ROUND(v3.evidence_surplus_gbp, 2) IS DISTINCT FROM ROUND(v2.evidence_surplus_gbp, 2)
        OR v3.evidence_status IS DISTINCT FROM v2.evidence_status
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: non-pending v3 behaviour changed from v2.';
  END IF;

  -- Genuine final-sale shortfalls must remain shortfalls. Do not assert a legacy
  -- resolution_status label here: historical classification can independently make
  -- an old row over_resolved. The protected arithmetic invariant is simply that a
  -- receipt below final sale cannot become a positive settlement difference.
  IF EXISTS (
    SELECT 1
    FROM public.order_settlement_resolution_position_v1 p
    WHERE p.final_sale_document_count > 0
      AND p.final_order_value_gbp > p.order_attributed_receipt_gbp + 0.01
      AND ROUND(p.gross_positive_difference_gbp, 2) <> 0.00
  ) THEN
    RAISE EXCEPTION 'FAIL: genuine final-sale shortfall became a positive settlement difference.';
  END IF;

  -- Controlled evidence: 600 + .79 + 20 - 620 = .79.
  SELECT * INTO v_evidence
  FROM public.order_surplus_evidence_position_v3 e
  WHERE e.order_id = v_order_id;

  IF NOT FOUND
     OR ROUND(v_evidence.funding_total_gbp, 2) <> 600.00
     OR ROUND(v_evidence.pending_surplus_gbp, 2) <> 0.79
     OR ROUND(v_evidence.effective_receipt_gbp, 2) <> 620.79
     OR ROUND(v_evidence.evidence_value_gbp, 2) <> 620.00
     OR ROUND(v_evidence.evidence_surplus_gbp, 2) <> 0.79
     OR v_evidence.evidence_status <> 'ready_posted_invoice_surplus' THEN
    RAISE EXCEPTION 'FAIL: controlled pending evidence calculation mismatch: %', to_jsonb(v_evidence);
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2) INTO v_amount
  FROM public.dva_statement_line_allocations a
  WHERE a.order_id = v_order_id
    AND a.allocation_type = 'final_balance_payment'
    AND a.allocation_status = 'confirmed';
  IF v_amount <> 20.00 THEN
    RAISE EXCEPTION 'FAIL: controlled confirmed final-balance payment expected 20.00, got %.', v_amount;
  END IF;

  -- Capture protected physical/Sage/funding-time-FX fingerprints.
  SELECT to_jsonb(a) INTO v_fx_before
  FROM public.dva_statement_line_allocations a
  WHERE a.id = v_supplier_fx_id;
  IF v_fx_before IS NULL THEN RAISE EXCEPTION 'FAIL: controlled supplier FX allocation missing.'; END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
  INTO v_source_used_before
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = (v_fx_before->>'dva_statement_line_id')::uuid
    AND a.allocation_status = 'confirmed';

  SELECT md5(COALESCE(string_agg(to_jsonb(s)::text, '|' ORDER BY to_jsonb(s)::text), ''))
  INTO v_sage_before
  FROM public.sage_posting_snapshots s;

  SELECT md5(pg_get_functiondef('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)'::regprocedure))
  INTO v_funding_fx_def_before;

  SELECT * INTO v_before_settlement
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ROUND(v_before_settlement.gross_positive_difference_gbp, 2) <> 0.79
     OR ROUND(v_before_settlement.confirmed_customer_credit_gbp, 2) <> 0.00
     OR ROUND(v_before_settlement.settlement_fx_card_difference_gbp, 2) <> 0.79
     OR ROUND(v_before_settlement.total_classified_gbp, 2) <> 0.79
     OR ROUND(v_before_settlement.remaining_unresolved_gbp, 2) <> 0.00 THEN
    RAISE EXCEPTION 'FAIL: controlled pre-confirmation settlement fingerprint changed: %', to_jsonb(v_before_settlement);
  END IF;

  SELECT s.auth_user_id INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND s.role_type IN ('admin','supervisor')
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at
  LIMIT 1;
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'FAIL: no active admin/supervisor auth user.'; END IF;
  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  v_result := public.staff_confirm_pending_receipt_surplus_credit_v1(
    v_order_id,
    'Regression pending surplus confirmation',
    'Rollback-only governed regression.'
  );

  v_credit_id := NULLIF(v_result->>'credit_ledger_id', '')::uuid;
  v_provenance_id := NULLIF(v_result->>'provenance_id', '')::uuid;
  IF v_credit_id IS NULL OR v_provenance_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: wrapper did not return credit/provenance ids: %', v_result;
  END IF;

  SELECT * INTO v_after_pending
  FROM public.order_pending_funding_surplus p
  WHERE p.id = v_pending_id;
  IF NOT FOUND
     OR v_after_pending.status <> 'credit_confirmed'
     OR v_after_pending.confirmed_credit_ledger_id IS DISTINCT FROM v_credit_id THEN
    RAISE EXCEPTION 'FAIL: pending row did not become credit_confirmed through established RPC.';
  END IF;

  SELECT ROUND(ABS(c.amount_gbp)::numeric, 2) INTO v_amount
  FROM public.importer_credit_ledger c
  WHERE c.id = v_credit_id
    AND c.direction = 'credit'
    AND c.source_entity_type = 'order'
    AND c.source_entity_id = v_order_id;
  IF v_amount <> 0.79 THEN
    RAISE EXCEPTION 'FAIL: established confirmation RPC created credit %, expected 0.79.', v_amount;
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM public.order_pending_surplus_credit_resolution_provenance_v1 pr
  WHERE pr.id = v_provenance_id
    AND pr.order_id = v_order_id
    AND pr.pending_surplus_id = v_pending_id
    AND pr.confirmed_credit_ledger_id = v_credit_id;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL: exact pending-to-credit provenance missing.'; END IF;

  -- Settlement counts the 79p once; physical/Sage/funding-time FX remain untouched.
  SELECT * INTO v_after_settlement
  FROM public.order_settlement_resolution_position_v1 p
  WHERE p.order_id = v_order_id;

  IF ROUND(v_after_settlement.gross_positive_difference_gbp, 2) <> 0.79
     OR ROUND(v_after_settlement.confirmed_customer_credit_gbp, 2) <> 0.79
     OR ROUND(v_after_settlement.settlement_fx_card_difference_gbp, 2) <> 0.00
     OR ROUND(v_after_settlement.total_classified_gbp, 2) <> 0.79
     OR ROUND(v_after_settlement.remaining_unresolved_gbp, 2) <> 0.00
     OR ROUND(v_after_settlement.over_resolved_gbp, 2) <> 0.00
     OR v_after_settlement.resolution_status <> 'fully_resolved' THEN
    RAISE EXCEPTION 'FAIL: controlled post-confirmation settlement mismatch: %', to_jsonb(v_after_settlement);
  END IF;

  SELECT to_jsonb(a) INTO v_fx_after
  FROM public.dva_statement_line_allocations a
  WHERE a.id = v_supplier_fx_id;
  IF v_fx_after IS DISTINCT FROM v_fx_before THEN
    RAISE EXCEPTION 'FAIL: physical supplier FX allocation mutated.';
  END IF;

  SELECT ROUND(COALESCE(SUM(a.allocated_gbp_amount), 0)::numeric, 2)
  INTO v_source_used_after
  FROM public.dva_statement_line_allocations a
  WHERE a.dva_statement_line_id = (v_fx_before->>'dva_statement_line_id')::uuid
    AND a.allocation_status = 'confirmed';
  IF v_source_used_after IS DISTINCT FROM v_source_used_before THEN
    RAISE EXCEPTION 'FAIL: supplier-payment statement-line consumption changed from % to %.', v_source_used_before, v_source_used_after;
  END IF;

  SELECT md5(COALESCE(string_agg(to_jsonb(s)::text, '|' ORDER BY to_jsonb(s)::text), ''))
  INTO v_sage_after
  FROM public.sage_posting_snapshots s;
  IF v_sage_after IS DISTINCT FROM v_sage_before THEN
    RAISE EXCEPTION 'FAIL: Sage posting snapshot fingerprint changed.';
  END IF;

  SELECT md5(pg_get_functiondef('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)'::regprocedure))
  INTO v_funding_fx_def_after;
  IF v_funding_fx_def_after IS DISTINCT FROM v_funding_fx_def_before THEN
    RAISE EXCEPTION 'FAIL: funding-time FX RPC definition changed.';
  END IF;

  -- Idempotency: second call returns the same ids and creates no duplicate rows.
  v_repeat := public.staff_confirm_pending_receipt_surplus_credit_v1(
    v_order_id,
    'Regression pending surplus confirmation',
    'Rollback-only governed regression repeat.'
  );

  IF COALESCE((v_repeat->>'already_confirmed')::boolean, false) IS DISTINCT FROM true
     OR NULLIF(v_repeat->>'credit_ledger_id', '')::uuid IS DISTINCT FROM v_credit_id
     OR NULLIF(v_repeat->>'provenance_id', '')::uuid IS DISTINCT FROM v_provenance_id THEN
    RAISE EXCEPTION 'FAIL: wrapper idempotent response mismatch: %', v_repeat;
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM public.order_pending_surplus_credit_resolution_provenance_v1 pr
  WHERE pr.order_id = v_order_id;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL: duplicate provenance created.'; END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM public.importer_credit_ledger c
  WHERE c.importer_id = v_after_pending.importer_id
    AND c.source_entity_type = 'order'
    AND c.source_entity_id = v_order_id
    AND c.direction = 'credit'
    AND c.source_type IN ('overfunding','settlement_credit');
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL: duplicate order credit created; count %.', v_count; END IF;

  RAISE NOTICE 'PASS: governed 79p calculation, P=0 compatibility, pending-no-final-balance compatibility, status-neutral genuine shortfalls, provenance/idempotency, physical source consumption, Sage snapshots and funding-time FX are all preserved.';
END;
$regression$;

ROLLBACK;
