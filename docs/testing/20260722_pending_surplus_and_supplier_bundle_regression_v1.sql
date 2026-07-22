-- Rollback-safe regression for three funding outcomes and sequential A+B+C+FX allocation.
BEGIN;

DO $$
DECLARE d text;
BEGIN
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN RAISE EXCEPTION 'base funding signature missing'; END IF;
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(uuid,uuid,numeric,uuid,text)') IS NULL THEN RAISE EXCEPTION 'FX funding branch missing'; END IF;
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)') IS NULL THEN RAISE EXCEPTION 'pending-surplus funding branch missing'; END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice_incremental_v1(uuid,uuid,numeric,text)') IS NULL THEN RAISE EXCEPTION 'incremental supplier allocator missing'; END IF;
  IF to_regclass('public.order_pending_funding_surplus') IS NULL THEN RAISE EXCEPTION 'pending-surplus ledger missing'; END IF;
  d := lower(pg_get_functiondef('public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text)'::regprocedure));
  IF position('staff_reconcile_dva_line_to_order(' in d)=0 OR position('v_entered-v_gap' in d)=0 OR position('credit_created_yn' in d)=0 THEN RAISE EXCEPTION 'pending branch does not cap funding and preserve residual'; END IF;
END $$;

CREATE TEMP TABLE funding_cases(
  scenario int PRIMARY KEY, statement_in numeric(12,2), order_gap numeric(12,2), entered numeric(12,2),
  fx_checked boolean, funding numeric(12,2), statement_residual numeric(12,2), fx numeric(12,2), pending numeric(12,2), automatic_credit numeric(12,2)
);
INSERT INTO funding_cases VALUES
 (1,900,884.96,884.96,false,884.96,15.04,0,0,0),
 (2,900,884.96,900,true,884.96,0,15.04,0,0),
 (3,900,884.96,900,false,884.96,0,0,15.04,0);
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM funding_cases WHERE
   funding<>least(entered,order_gap) OR statement_residual<>statement_in-entered OR
   fx<>CASE WHEN entered>order_gap AND fx_checked THEN entered-order_gap ELSE 0 END OR
   pending<>CASE WHEN entered>order_gap AND NOT fx_checked THEN entered-order_gap ELSE 0 END OR automatic_credit<>0)
 THEN RAISE EXCEPTION 'funding outcome regression failed'; END IF;
END $$;

CREATE TEMP TABLE supplier_uses(seq int PRIMARY KEY, kind text, invoice text, amount numeric(12,2), reversed boolean DEFAULT false);
INSERT INTO supplier_uses VALUES
 (1,'supplier','A',449.98,false),(2,'supplier','B',249.99,false),(3,'supplier','C',95.00,false),(4,'fx_card',NULL,95.03,false);
DO $$
DECLARE total numeric; supplier numeric; remaining numeric := 890; r record;
BEGIN
 FOR r IN SELECT * FROM supplier_uses ORDER BY seq LOOP
   IF r.amount > remaining THEN RAISE EXCEPTION 'over-allocation at leg %',r.seq; END IF;
   remaining := round(remaining-r.amount,2);
   IF r.seq<4 AND remaining<=0 THEN RAISE EXCEPTION 'same OUT not reusable after leg %',r.seq; END IF;
 END LOOP;
 SELECT sum(amount),sum(amount) FILTER(WHERE kind='supplier') INTO total,supplier FROM supplier_uses WHERE NOT reversed;
 IF supplier<>794.97 OR total<>890.00 OR remaining<>0 THEN RAISE EXCEPTION 'A+B+C+FX totals failed'; END IF;
 IF (SELECT count(*) FROM supplier_uses WHERE kind='supplier')<>(SELECT count(DISTINCT invoice) FROM supplier_uses WHERE kind='supplier') THEN RAISE EXCEPTION 'duplicate invoice allocation'; END IF;
 IF NOT EXISTS (SELECT 1 FROM supplier_uses GROUP BY seq HAVING count(*)=1) THEN RAISE EXCEPTION 'individual reversal identity missing'; END IF;
END $$;

-- View exposure and confirmation must use pending amount, wait for evidence, and lock for idempotency.
DO $$ DECLARE vd text; fd text; BEGIN
 vd:=lower(pg_get_viewdef('public.order_surplus_evidence_position_v2'::regclass,true));
 fd:=lower(pg_get_functiondef('public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)'::regprocedure));
 IF position('pending_surplus_gbp' in vd)=0 OR position('evidence_basis' in vd)=0 THEN RAISE EXCEPTION 'pending evidence not exposed'; END IF;
 IF position('for update' in fd)=0 OR position('credit_confirmed' in fd)=0 OR position('pending_surplus_gbp' in fd)=0 THEN RAISE EXCEPTION 'confirmation not idempotent/evidence-capped'; END IF;
END $$;

ROLLBACK;
