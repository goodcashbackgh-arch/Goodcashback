-- Supabase SQL Editor regression v4.
-- Rollback-only. Avoids mutating pending_surplus_gbp because the live table
-- enforces the original receipt-residual arithmetic by check constraint.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $r$
DECLARE
  t uuid; s uuid; c uuid; p uuid;
  pb numeric(12,2); cb numeric(12,2); tf numeric(12,2);
  pos0 jsonb; pos1 jsonb; x record; y record; blocked boolean;
  def text; rows0 bigint; rows1 bigint; ev0 bigint; ev1 bigint;
  full_target uuid; full_amount numeric(12,2); full_result record;
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

  SELECT to_jsonb(q) INTO pos0
  FROM public.order_settlement_resolution_position_v1 q
  WHERE order_id=s;

  IF pos0 IS NULL OR pos0->>'resolution_status'<>'fully_resolved'
     OR coalesce((pos0->>'remaining_unresolved_gbp')::numeric,999999)>0.01
     OR coalesce((pos0->>'over_resolved_gbp')::numeric,999999)>0.01
     OR coalesce((pos0->>'pending_evidence_count')::int,-1)<>0
     OR abs(coalesce((pos0->>'confirmed_customer_credit_gbp')::numeric,-999999)-cb)>0.01
  THEN RAISE EXCEPTION 'REGRESSION: source settlement is not fully resolved'; END IF;

  SELECT pg_get_functiondef(
    'public.internal_supplier_payment_bundle_source_v1(uuid,numeric)'::regprocedure
  ) INTO def;

  IF strpos(def,'ABS(r.pending_surplus_gbp - r.credit_amount_gbp) <= 0.01')=0
     OR strpos(def,'settlement_resolution_status = ''fully_resolved''')=0
     OR strpos(def,'settlement_remaining_unresolved_gbp')=0
     OR strpos(def,'settlement_confirmed_customer_credit_gbp')=0
     OR strpos(def,'source_funding_ambiguous_for_supplier_payment_bank_resolution')=0
  THEN RAISE EXCEPTION 'REGRESSION: scoped resolver contract missing'; END IF;

  SELECT count(*) INTO rows0 FROM public.dva_statement_line_allocations;
  SELECT count(*) INTO ev0 FROM public.order_funding_events;

  -- 1. Real partial, canonically fully-resolved case must now pass.
  SELECT * INTO x FROM public.internal_supplier_payment_bundle_source_v1(t,tf);
  SELECT * INTO y FROM public.internal_supplier_payment_bundle_source_v1(t,tf);

  IF x.source_bank_account_mapping_code<>'DVA_CASH_BANK_ACCOUNT'
     OR x.source_wallet_code IS NOT NULL
     OR x.source_resolution_reason<>'proven_remaining_order_cash_funding'
     OR x.remaining_order_cash_funding_gbp+0.01<tf
     OR to_jsonb(x) IS DISTINCT FROM to_jsonb(y)
  THEN RAISE EXCEPTION 'REGRESSION: valid partial path failed'; END IF;

  -- 2. Existing ordinary/full-overfunding route: use a real existing equality
  -- case if one exists. Never rewrite pending_surplus_gbp to manufacture it.
  WITH full_cases AS (
    SELECT DISTINCT
      applied.order_id AS target_order_id,
      round(abs(applied.amount_gbp)::numeric,2) AS applied_gbp
    FROM public.order_funding_events applied
    JOIN public.importer_credit_ledger db ON db.id=applied.source_entity_id
    JOIN public.importer_credit_ledger cr ON cr.id=CASE
      WHEN db.source_table='importer_credit_ledger' THEN db.source_id
      WHEN db.source_entity_type='importer_credit_ledger' THEN db.source_entity_id
      ELSE NULL::uuid END
    JOIN public.order_pending_funding_surplus ops ON ops.confirmed_credit_ledger_id=cr.id
    JOIN LATERAL public.internal_supplier_payment_readiness_v1(applied.order_id) rr
      ON rr.supplier_payment_ready_yn IS TRUE
    WHERE applied.event_type='credit_applied'
      AND cr.source_type='overfunding'
      AND ops.status='credit_confirmed'
      AND ops.reversed_at IS NULL
      AND abs(round(ops.pending_surplus_gbp::numeric,2)-round(abs(cr.amount_gbp)::numeric,2))<=0.01
      AND round(abs(applied.amount_gbp)::numeric,2)>0
      AND applied.order_id<>t
  )
  SELECT target_order_id,applied_gbp INTO full_target,full_amount
  FROM full_cases ORDER BY target_order_id LIMIT 1;

  IF full_target IS NOT NULL THEN
    SELECT * INTO full_result
    FROM public.internal_supplier_payment_bundle_source_v1(full_target,full_amount);
    IF full_result.source_bank_account_mapping_code IS NULL THEN
      RAISE EXCEPTION 'REGRESSION: existing full-overfunding equality case no longer resolves';
    END IF;
  ELSE
    RAISE NOTICE 'LIMITATION: no existing live full-overfunding equality fixture; equality path is exact-definition verified and left unchanged.';
  END IF;

  -- 3. Same real partial credit must fail closed when its pending-surplus evidence
  -- is reversed. This mutation is valid under the live table constraint and is
  -- rolled back immediately inside the subtransaction.
  BEGIN
    UPDATE public.order_pending_funding_surplus
    SET reversed_at=now()
    WHERE id=p;

    blocked:=false;
    BEGIN
      PERFORM * FROM public.internal_supplier_payment_bundle_source_v1(t,tf);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'source_funding_required_for_supplier_payment_bank_resolution:%'
         OR SQLERRM LIKE 'source_funding_ambiguous_for_supplier_payment_bank_resolution:%'
      THEN blocked:=true;
      ELSE RAISE;
      END IF;
    END;

    IF blocked IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'REGRESSION: reversed/invalid partial provenance did not fail closed';
    END IF;

    RAISE EXCEPTION USING ERRCODE='ZX001',MESSAGE='rollback fixture';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN NULL; END;

  -- 4. Original facts and resolver side effects remain unchanged.
  IF (SELECT round(pending_surplus_gbp::numeric,2)
      FROM public.order_pending_funding_surplus WHERE id=p) IS DISTINCT FROM pb
     OR (SELECT round(abs(amount_gbp)::numeric,2)
      FROM public.importer_credit_ledger WHERE id=c) IS DISTINCT FROM cb
  THEN RAISE EXCEPTION 'REGRESSION: source business facts mutated'; END IF;

  SELECT to_jsonb(q) INTO pos1
  FROM public.order_settlement_resolution_position_v1 q
  WHERE order_id=s;

  IF pos1 IS DISTINCT FROM pos0 THEN
    RAISE EXCEPTION 'REGRESSION: settlement position changed';
  END IF;

  SELECT count(*) INTO rows1 FROM public.dva_statement_line_allocations;
  SELECT count(*) INTO ev1 FROM public.order_funding_events;

  IF rows1<>rows0 OR ev1<>ev0 THEN
    RAISE EXCEPTION 'REGRESSION: persistent allocation/funding rows changed';
  END IF;
END
$r$;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','real partial fully-resolved overfunding resolves as DVA cash; ordinary equality route is preserved and behavior-tested when a live fixture exists; reversed/invalid partial provenance fails closed; pending residual, confirmed credit, settlement position, funding events and supplier allocations remain unchanged'
) AS regression_result;

ROLLBACK;
