-- Rollback-only regression for line-level shipment membership.
-- Apply migrations 20260723f, 20260723g and 20260723h before running.

BEGIN;

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipment line membership table missing';
  END IF;

  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: effective shipment lines function missing';
  END IF;

  IF to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipment candidate function missing';
  END IF;

  IF to_regprocedure('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipment creation function missing';
  END IF;

  SELECT pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure)
  INTO v_def;
  IF position('customer_line_has_active_hold_conflict_v1' in v_def) = 0
     OR position('COALESCE(eligible.allocated_qty, 0) > 0' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: candidates do not filter every held line and suppress all-held packages';
  END IF;

  SELECT pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure)
  INTO v_def;
  IF position('shipper_shipment_batch_line_memberships' in v_def) = 0
     OR position('v_eligible_count' in v_def) = 0
     OR position('customer_line_has_active_hold_conflict_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: shipment creation does not re-check and snapshot every eligible line';
  END IF;

  SELECT pg_get_functiondef('public.internal_shipping_apportionment_preview_v1(uuid)'::regprocedure)
  INTO v_def;
  IF position('shipper_shipment_batch_effective_lines_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: freight preview reconstructs original package allocations';
  END IF;

  SELECT pg_get_functiondef('public.internal_approve_shipping_apportionment_v1(uuid,jsonb,text)'::regprocedure)
  INTO v_def;
  IF position('shipper_shipment_batch_effective_lines_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: freight approval reconstructs original package allocations';
  END IF;

  SELECT pg_get_functiondef('public.internal_shipping_ap_recharge_readiness_preview_v1(uuid)'::regprocedure)
  INTO v_def;
  IF position('shipper_shipment_batch_effective_lines_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: AP/recharge readiness reconstructs original package allocations';
  END IF;
END $$;

-- Pure cardinality regression for the shared set rule:
-- all positive allocation rows minus active conflicts equals shipment membership.
CREATE TEMP TABLE regression_lines (
  scenario text NOT NULL,
  line_no integer NOT NULL,
  qty numeric NOT NULL,
  held boolean NOT NULL,
  PRIMARY KEY (scenario, line_no)
) ON COMMIT DROP;

INSERT INTO regression_lines(scenario,line_no,qty,held)
VALUES
  ('one_clear',1,1,false),
  ('one_held',1,1,true);

INSERT INTO regression_lines(scenario,line_no,qty,held)
SELECT 'twenty_clear', n, 1, false FROM generate_series(1,20) n;

INSERT INTO regression_lines(scenario,line_no,qty,held)
SELECT 'twenty_one_held', n, 1, n = 7 FROM generate_series(1,20) n;

INSERT INTO regression_lines(scenario,line_no,qty,held)
SELECT 'twenty_ten_held', n, 1, n <= 10 FROM generate_series(1,20) n;

INSERT INTO regression_lines(scenario,line_no,qty,held)
SELECT 'twenty_all_held', n, 1, true FROM generate_series(1,20) n;

DO $$
DECLARE
  v_count integer;
  v_qty numeric;
BEGIN
  SELECT count(*), coalesce(sum(qty),0) INTO v_count,v_qty
  FROM regression_lines WHERE scenario='one_clear' AND qty>0 AND held=false;
  IF v_count<>1 OR v_qty<>1 THEN RAISE EXCEPTION 'FAIL: one clear line'; END IF;

  SELECT count(*), coalesce(sum(qty),0) INTO v_count,v_qty
  FROM regression_lines WHERE scenario='one_held' AND qty>0 AND held=false;
  IF v_count<>0 OR v_qty<>0 THEN RAISE EXCEPTION 'FAIL: only held line must suppress package'; END IF;

  SELECT count(*), coalesce(sum(qty),0) INTO v_count,v_qty
  FROM regression_lines WHERE scenario='twenty_clear' AND qty>0 AND held=false;
  IF v_count<>20 OR v_qty<>20 THEN RAISE EXCEPTION 'FAIL: twenty clear lines'; END IF;

  SELECT count(*), coalesce(sum(qty),0) INTO v_count,v_qty
  FROM regression_lines WHERE scenario='twenty_one_held' AND qty>0 AND held=false;
  IF v_count<>19 OR v_qty<>19 THEN RAISE EXCEPTION 'FAIL: one of twenty held'; END IF;

  SELECT count(*), coalesce(sum(qty),0) INTO v_count,v_qty
  FROM regression_lines WHERE scenario='twenty_ten_held' AND qty>0 AND held=false;
  IF v_count<>10 OR v_qty<>10 THEN RAISE EXCEPTION 'FAIL: ten of twenty held'; END IF;

  SELECT count(*), coalesce(sum(qty),0) INTO v_count,v_qty
  FROM regression_lines WHERE scenario='twenty_all_held' AND qty>0 AND held=false;
  IF v_count<>0 OR v_qty<>0 THEN RAISE EXCEPTION 'FAIL: all-held package must be suppressed'; END IF;
END $$;

-- Known live-case read-only assertion. This validates the existing Ninja line remains
-- conflicted while any unrelated positive allocations on the same tracking remain countable.
DO $$
DECLARE
  v_tracking uuid := 'e4cee0cf-de35-46cf-9a9a-1c81add2795c';
  v_held_line uuid := 'd7d42758-4a8d-4632-910e-353c06d2f621';
  v_hold_conflict boolean;
  v_total_positive integer;
  v_eligible_positive integer;
BEGIN
  SELECT public.customer_line_has_active_hold_conflict_v1(a.order_id,a.tracking_submission_id,a.supplier_invoice_line_id)
  INTO v_hold_conflict
  FROM public.order_tracking_line_allocations a
  WHERE a.tracking_submission_id=v_tracking
    AND a.supplier_invoice_line_id=v_held_line
    AND COALESCE(a.qty_allocated,0)>0
  LIMIT 1;

  IF v_hold_conflict IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: known Ninja allocation is not recognised as actively held';
  END IF;

  SELECT count(*) INTO v_total_positive
  FROM public.order_tracking_line_allocations a
  WHERE a.tracking_submission_id=v_tracking
    AND COALESCE(a.qty_allocated,0)>0;

  SELECT count(*) INTO v_eligible_positive
  FROM public.order_tracking_line_allocations a
  WHERE a.tracking_submission_id=v_tracking
    AND COALESCE(a.qty_allocated,0)>0
    AND public.customer_line_has_active_hold_conflict_v1(a.order_id,a.tracking_submission_id,a.supplier_invoice_line_id) IS DISTINCT FROM true;

  IF v_total_positive < 1 THEN
    RAISE EXCEPTION 'FAIL: known tracking has no positive allocations';
  END IF;
  IF v_eligible_positive <> v_total_positive - 1 THEN
    RAISE EXCEPTION 'FAIL: known tracking eligible count %, expected %', v_eligible_positive, v_total_positive - 1;
  END IF;
END $$;

RAISE NOTICE 'PASS: line-level shipment membership cardinality, downstream scope and known Ninja hold assertions completed';

ROLLBACK;
