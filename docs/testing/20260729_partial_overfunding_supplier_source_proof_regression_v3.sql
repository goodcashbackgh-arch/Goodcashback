-- Supabase SQL Editor regression v3 (compact, rollback-only).
BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $r$
DECLARE
  t uuid; s uuid; c uuid; p uuid;
  pb numeric(12,2); cb numeric(12,2); tf numeric(12,2);
  pos0 jsonb; pos1 jsonb; x record; y record; blocked boolean;
  def text; rows0 bigint; rows1 bigint; ev0 bigint; ev1 bigint;
  d uuid; drem numeric(12,2); dx record;
  l uuid; lrem numeric(12,2); lw text; lx record;
BEGIN
  SELECT id INTO t FROM public.orders WHERE order_ref='ORD-1785274708774';
  IF t IS NULL THEN RAISE EXCEPTION 'REGRESSION: target order missing'; END IF;

  SELECT cr.id,cr.source_entity_id,ops.id,
         round(coalesce(ops.pending_surplus_gbp,0)::numeric,2),
         round(abs(coalesce(cr.amount_gbp,0))::numeric,2)
    INTO c,s,p,pb,cb
  FROM public.order_funding_events e
  JOIN public.importer_credit_ledger db ON db.id=e.source_entity_id
  JOIN public.importer_credit_ledger cr ON cr.id=CASE
    WHEN db.source_table='importer_credit_ledger' THEN db.source_id
    WHEN db.source_entity_type='importer_credit_ledger' THEN db.source_entity_id
    ELSE NULL::uuid END
  JOIN public.order_pending_funding_surplus ops ON ops.confirmed_credit_ledger_id=cr.id
  WHERE e.order_id=t AND e.event_type='credit_applied' AND cr.source_type='overfunding'
  LIMIT 1;

  IF c IS NULL OR s IS NULL OR p IS NULL OR pb<=cb+0.01 THEN
    RAISE EXCEPTION 'REGRESSION: partial-overfunding provenance fixture missing';
  END IF;

  SELECT round(coalesce(sum(CASE
    WHEN event_type IN ('funding_contribution','credit_applied','manual_adjustment') THEN amount_gbp
    WHEN event_type='funding_reversed' THEN -abs(amount_gbp) ELSE 0 END),0)::numeric,2)
    INTO tf FROM public.order_funding_events WHERE order_id=t;

  SELECT to_jsonb(q) INTO pos0 FROM public.order_settlement_resolution_position_v1 q WHERE order_id=s;
  IF pos0 IS NULL OR pos0->>'resolution_status'<>'fully_resolved'
     OR coalesce((pos0->>'remaining_unresolved_gbp')::numeric,999999)>0.01
     OR coalesce((pos0->>'over_resolved_gbp')::numeric,999999)>0.01
     OR coalesce((pos0->>'pending_evidence_count')::int,-1)<>0
     OR abs(coalesce((pos0->>'confirmed_customer_credit_gbp')::numeric,-999999)-cb)>0.01
  THEN RAISE EXCEPTION 'REGRESSION: source settlement is not fully resolved'; END IF;

  SELECT pg_get_functiondef('public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure) INTO def;
  IF strpos(def,'settlement_resolution_status = ''fully_resolved''')=0
     OR strpos(def,'settlement_remaining_unresolved_gbp')=0
     OR strpos(def,'settlement_confirmed_customer_credit_gbp')=0
  THEN RAISE EXCEPTION 'REGRESSION: scoped resolver patch missing'; END IF;

  SELECT count(*) INTO rows0 FROM public.dva_statement_line_allocations;
  SELECT count(*) INTO ev0 FROM public.order_funding_events;

  -- New valid partial path.
  SELECT * INTO x FROM public.internal_supplier_payment_bundle_source_v1(t,tf);
  SELECT * INTO y FROM public.internal_supplier_payment_bundle_source_v1(t,tf);
  IF x.source_bank_account_mapping_code<>'DVA_CASH_BANK_ACCOUNT'
     OR x.source_wallet_code IS NOT NULL
     OR x.source_resolution_reason<>'proven_remaining_order_cash_funding'
     OR x.remaining_order_cash_funding_gbp+0.01<tf
     OR to_jsonb(x) IS DISTINCT FROM to_jsonb(y)
  THEN RAISE EXCEPTION 'REGRESSION: valid partial path failed'; END IF;

  -- Existing full-overfunding equality path.
  BEGIN
    UPDATE public.order_pending_funding_surplus SET pending_surplus_gbp=cb WHERE id=p;
    SELECT * INTO x FROM public.internal_supplier_payment_bundle_source_v1(t,tf);
    IF x.source_bank_account_mapping_code<>'DVA_CASH_BANK_ACCOUNT'
       OR x.source_resolution_reason<>'proven_remaining_order_cash_funding'
    THEN RAISE EXCEPTION 'REGRESSION: full-overfunding path changed'; END IF;
    RAISE EXCEPTION USING ERRCODE='ZX001',MESSAGE='rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN NULL; END;

  -- Partial but no longer canonically resolved must fail closed.
  BEGIN
    UPDATE public.order_pending_funding_surplus SET pending_surplus_gbp=pb-1 WHERE id=p;
    blocked:=false;
    BEGIN
      PERFORM * FROM public.internal_supplier_payment_bundle_source_v1(t,tf);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'source_funding_required_for_supplier_payment_bank_resolution:%'
         OR SQLERRM LIKE 'source_funding_ambiguous_for_supplier_payment_bank_resolution:%' THEN blocked:=true; ELSE RAISE; END IF;
    END;
    IF blocked IS DISTINCT FROM true THEN RAISE EXCEPTION 'REGRESSION: unresolved partial did not block'; END IF;
    RAISE EXCEPTION USING ERRCODE='ZX002',MESSAGE='rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX002' THEN NULL; END;

  -- Existing direct-cash behaviour.
  WITH z AS (
    SELECT o.id,
      round(coalesce(sum(abs(e.amount_gbp)) FILTER(WHERE e.event_type='funding_contribution'),0)::numeric,2) cash,
      round(coalesce((SELECT sum(a.allocated_gbp_amount) FROM public.dva_statement_line_allocations a
        JOIN public.supplier_invoices si ON si.id=a.supplier_invoice_id
        WHERE si.order_id=o.id AND a.allocation_type='supplier_invoice' AND a.allocation_status='confirmed'
          AND a.source_bank_account_mapping_code='DVA_CASH_BANK_ACCOUNT'),0)::numeric,2) used
    FROM public.orders o LEFT JOIN public.order_funding_events e ON e.order_id=o.id
    WHERE o.id<>t AND NOT EXISTS(SELECT 1 FROM public.order_funding_events ce WHERE ce.order_id=o.id AND ce.event_type='credit_applied' AND abs(coalesce(ce.amount_gbp,0))>0.01)
    GROUP BY o.id)
  SELECT z.id,round(greatest(z.cash-z.used,0)::numeric,2) INTO d,drem
  FROM z JOIN LATERAL public.internal_supplier_payment_readiness_v1(z.id) rr ON rr.supplier_payment_ready_yn IS TRUE
  WHERE z.cash-z.used>=1 ORDER BY z.id LIMIT 1;
  IF d IS NULL THEN RAISE EXCEPTION 'REGRESSION: no direct-cash baseline order'; END IF;
  SELECT * INTO dx FROM public.internal_supplier_payment_bundle_source_v1(d,1);
  IF dx.source_bank_account_mapping_code<>'DVA_CASH_BANK_ACCOUNT' OR dx.source_wallet_code IS NOT NULL
     OR dx.source_resolution_reason<>'proven_remaining_order_cash_funding'
     OR abs(coalesce(dx.remaining_order_cash_funding_gbp,0)-drem)>0.01
  THEN RAISE EXCEPTION 'REGRESSION: direct-cash behaviour changed'; END IF;

  -- Existing released-loyalty behaviour, compact live candidate.
  WITH la AS (
    SELECT DISTINCT ON(e.id) e.order_id,e.id,round(abs(coalesce(e.amount_gbp,0))::numeric,2) amt,r.resolved_wallet_code::text wallet
    FROM public.order_funding_events e
    JOIN public.orders o ON o.id=e.order_id
    JOIN public.importer_credit_ledger db ON db.id=e.source_entity_id
    JOIN public.main_bank_completion_loyalty_funding_matches m ON m.credit_ledger_id=CASE WHEN db.source_table='importer_credit_ledger' THEN db.source_id WHEN db.source_entity_type='importer_credit_ledger' THEN db.source_entity_id ELSE NULL::uuid END
      AND m.importer_id=o.importer_id AND m.match_status='released_available_dashboard_credit' AND coalesce(m.transfer_pair_status,'')='paired_released' AND m.destination_in_statement_line_id IS NOT NULL
    JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(m.destination_in_statement_line_id) r ON r.blocker IS NULL
    WHERE e.event_type='credit_applied' AND e.source_entity_type='importer_credit_ledger'
    ORDER BY e.id,m.id), wt AS (
    SELECT order_id,wallet,round(sum(amt)::numeric,2) rem FROM la GROUP BY order_id,wallet), one AS (
    SELECT order_id FROM wt WHERE rem>0 GROUP BY order_id HAVING count(*)=1)
  SELECT wt.order_id,wt.rem,wt.wallet INTO l,lrem,lw FROM wt JOIN one USING(order_id)
  JOIN LATERAL public.internal_supplier_payment_readiness_v1(wt.order_id) rr ON rr.supplier_payment_ready_yn IS TRUE
  WHERE wt.rem>0 ORDER BY wt.order_id LIMIT 1;
  IF l IS NULL THEN RAISE EXCEPTION 'REGRESSION: no released-loyalty baseline order'; END IF;
  SELECT * INTO lx FROM public.internal_supplier_payment_bundle_source_v1(l,lrem);
  IF lx.source_wallet_code IS DISTINCT FROM lw
     OR NOT ((lw='virtual_gbp_wallet' AND lx.source_bank_account_mapping_code='LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT')
          OR (lw='dva_ghs_wallet' AND lx.source_bank_account_mapping_code='LOYALTY_DVA_GHS_BANK_ACCOUNT'))
     OR lx.source_resolution_reason<>'exact_remaining_released_loyalty_source'
  THEN RAISE EXCEPTION 'REGRESSION: released-loyalty behaviour changed'; END IF;

  IF strpos(def,'source_funding_ambiguous_for_supplier_payment_bank_resolution')=0 THEN
    RAISE EXCEPTION 'REGRESSION: ambiguity fail-closed control missing';
  END IF;

  IF (SELECT round(pending_surplus_gbp::numeric,2) FROM public.order_pending_funding_surplus WHERE id=p) IS DISTINCT FROM pb
     OR (SELECT round(abs(amount_gbp)::numeric,2) FROM public.importer_credit_ledger WHERE id=c) IS DISTINCT FROM cb
  THEN RAISE EXCEPTION 'REGRESSION: source business facts mutated'; END IF;
  SELECT to_jsonb(q) INTO pos1 FROM public.order_settlement_resolution_position_v1 q WHERE order_id=s;
  IF pos1 IS DISTINCT FROM pos0 THEN RAISE EXCEPTION 'REGRESSION: settlement position changed'; END IF;
  SELECT count(*) INTO rows1 FROM public.dva_statement_line_allocations;
  SELECT count(*) INTO ev1 FROM public.order_funding_events;
  IF rows1<>rows0 OR ev1<>ev0 THEN RAISE EXCEPTION 'REGRESSION: persistent rows changed'; END IF;
END
$r$;

SELECT jsonb_build_object('regression_result','PASS','proof','partial fully-resolved overfunding passes; full overfunding, direct cash and released loyalty remain working; unresolved partial and ambiguity remain fail-closed; settlement and business rows unchanged') AS regression_result;
ROLLBACK;
