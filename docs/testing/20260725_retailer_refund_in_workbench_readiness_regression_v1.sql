BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $structure$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)') IS NULL
     OR to_regprocedure('public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(text,text,text,text,integer,integer)') IS NULL
     OR to_regprocedure('public.internal_retailer_refund_has_posted_settlement_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical workbench, preserved workbench or canonical settlement gate missing';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)'::regprocedure))
  INTO v_definition;

  IF position('internal_cash_posting_workbench_rows_pre_refund_readiness_v1' IN v_definition) = 0
     OR position('internal_retailer_refund_has_posted_settlement_v1' IN v_definition) = 0
     OR position('ready_to_freeze' IN v_definition) = 0
     OR position('blocked_endpoint_prove_required' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'FAIL: canonical workbench is not the preserved resolver plus canonical retailer-refund settlement gate';
  END IF;
END
$structure$;

DO $behaviour$
DECLARE
  v_auth_uid uuid;
  v_target_source_id uuid;
  v_gate_passed boolean;
  v_before_status text;
  v_after_status text;
  v_after_blocker text;
  v_after_selectable boolean;
  v_non_refund_difference_count integer;
BEGIN
  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 WHEN s.role_type = 'supervisor' THEN 1 ELSE 2 END,
           s.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active staff auth identity available';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  SELECT p.source_id
  INTO v_target_source_id
  FROM public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(
    'in',
    'retailer_refund_received',
    'all',
    NULL,
    300,
    0
  ) p
  WHERE p.category = 'retailer_refund_received'
    AND p.direction = 'in'
    AND public.internal_retailer_refund_has_posted_settlement_v1(p.source_id)
  ORDER BY CASE WHEN round(COALESCE(p.amount_gbp, 0), 2) = 184.99 THEN 0 ELSE 1 END,
           p.statement_date_text DESC NULLS LAST,
           p.queue_row_id
  LIMIT 1;

  IF v_target_source_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: no retailer refund IN row with a posted canonical supplier-credit settlement was found';
  END IF;

  SELECT public.internal_retailer_refund_has_posted_settlement_v1(v_target_source_id)
  INTO v_gate_passed;

  IF v_gate_passed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: target retailer refund IN source did not pass the canonical settlement gate';
  END IF;

  SELECT p.posting_status
  INTO v_before_status
  FROM public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(
    'in',
    'retailer_refund_received',
    'all',
    NULL,
    300,
    0
  ) p
  WHERE p.source_id = v_target_source_id
  LIMIT 1;

  SELECT c.posting_status, c.blocker, c.selectable
  INTO v_after_status, v_after_blocker, v_after_selectable
  FROM public.internal_cash_posting_workbench_rows_v1(
    'in',
    'retailer_refund_received',
    'all',
    NULL,
    300,
    0
  ) c
  WHERE c.source_id = v_target_source_id
  LIMIT 1;

  IF v_before_status IS DISTINCT FROM 'blocked_endpoint_prove_required' THEN
    RAISE EXCEPTION 'FAIL: preserved resolver status is %, expected blocked_endpoint_prove_required for the proven defect', v_before_status;
  END IF;

  IF v_after_status IS DISTINCT FROM 'ready_to_freeze'
     OR v_after_blocker IS NOT NULL
     OR v_after_selectable IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: canonical workbench returned status %, blocker %, selectable %; expected ready_to_freeze, NULL, true',
      v_after_status, v_after_blocker, v_after_selectable;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_non_refund_difference_count
  FROM (
    SELECT to_jsonb(c) - 'total_count' AS row_json
    FROM public.internal_cash_posting_workbench_rows_v1('all', 'all', 'all', NULL, 300, 0) c
    WHERE c.category IS DISTINCT FROM 'retailer_refund_received'
    EXCEPT ALL
    SELECT to_jsonb(p) - 'total_count' AS row_json
    FROM public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1('all', 'all', 'all', NULL, 300, 0) p
    WHERE p.category IS DISTINCT FROM 'retailer_refund_received'

    UNION ALL

    SELECT to_jsonb(p) - 'total_count' AS row_json
    FROM public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1('all', 'all', 'all', NULL, 300, 0) p
    WHERE p.category IS DISTINCT FROM 'retailer_refund_received'
    EXCEPT ALL
    SELECT to_jsonb(c) - 'total_count' AS row_json
    FROM public.internal_cash_posting_workbench_rows_v1('all', 'all', 'all', NULL, 300, 0) c
    WHERE c.category IS DISTINCT FROM 'retailer_refund_received'
  ) differences;

  IF v_non_refund_difference_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: wrapper changed % non-retailer-refund workbench row(s)', v_non_refund_difference_count;
  END IF;
END
$behaviour$;

SELECT
  'PASS'::text AS regression_result,
  'Retailer refund IN readiness now follows the existing canonical posted-settlement gate; all non-retailer-refund workbench rows remain unchanged.'::text AS details;

ROLLBACK;
