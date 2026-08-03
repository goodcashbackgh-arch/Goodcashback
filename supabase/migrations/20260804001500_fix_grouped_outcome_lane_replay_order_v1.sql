-- Ensure identical grouped outcome-lane replays return their stored result
-- before mutable post-decision coverage checks run.
-- No decision, refund, replacement, settlement, or audit semantics are changed.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $migration$
DECLARE
  v_oid regprocedure:='public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)'::regprocedure;
  v_def text;
  v_marker text:='  -- The refund authority resolves every unresolved line in a dispute. Require exact selected coverage.';
  v_early_replay text:=E'  -- Identical completed requests must replay before mutable-state guards.\n'
    || E'  SELECT md5(\n'
    || E'    p_lane_id::text||''|''||p_staff_id::text||''|''||v_decision_type||''|''||\n'
    || E'    COALESCE((\n'
    || E'      SELECT string_agg((x->>''physical_remedy_allocation_id''),'','' ORDER BY (x->>''physical_remedy_allocation_id''))\n'
    || E'      FROM jsonb_array_elements(p_item_decisions) x\n'
    || E'    ),'''')||''|''||COALESCE(BTRIM(p_note),'''')\n'
    || E'  ) INTO v_request_hash;\n\n'
    || E'  SELECT result_json INTO v_existing_result\n'
    || E'  FROM public.physical_receipt_outcome_lane_decisions\n'
    || E'  WHERE lane_id=p_lane_id AND request_hash=v_request_hash;\n'
    || E'  IF v_existing_result IS NOT NULL THEN RETURN v_existing_result; END IF;\n\n';
BEGIN
  IF md5(pg_get_functiondef(v_oid))<>'1fb2c815df1fc0de5dc22da3e924db07' THEN
    RAISE EXCEPTION 'Unexpected grouped outcome-lane authority definition; inspect before replacing.';
  END IF;

  v_def:=pg_get_functiondef(v_oid);

  IF position(v_marker IN v_def)=0 THEN
    RAISE EXCEPTION 'Expected refund exact-coverage marker not found.';
  END IF;

  IF v_def LIKE '%Identical completed requests must replay before mutable-state guards.%' THEN
    RAISE EXCEPTION 'Early replay correction already appears installed.';
  END IF;

  v_def:=replace(v_def,v_marker,v_early_replay||v_marker);
  EXECUTE v_def;
END
$migration$;

REVOKE ALL ON FUNCTION public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text) TO authenticated;

DO $postflight$
DECLARE
  v_def text:=pg_get_functiondef('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)'::regprocedure);
  v_early integer;
  v_guard integer;
BEGIN
  v_early:=position('Identical completed requests must replay before mutable-state guards.' IN v_def);
  v_guard:=position('The refund authority resolves every unresolved line in a dispute. Require exact selected coverage.' IN v_def);

  IF v_early=0 OR v_guard=0 OR v_early>=v_guard THEN
    RAISE EXCEPTION 'Grouped outcome-lane early replay correction did not install before the mutable-state guard.';
  END IF;

  IF v_def NOT ILIKE '%WHERE lane_id=p_lane_id AND request_hash=v_request_hash%'
     OR v_def NOT ILIKE '%IF v_existing_result IS NOT NULL THEN RETURN v_existing_result; END IF;%'
     OR v_def NOT ILIKE '%Refund decision must select every unresolved physical item in each affected dispute.%'
  THEN
    RAISE EXCEPTION 'Grouped outcome-lane replay or exact-coverage contract is incomplete after replacement.';
  END IF;
END
$postflight$;

NOTIFY pgrst,'reload schema';
COMMIT;
