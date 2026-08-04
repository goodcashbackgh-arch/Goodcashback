BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regprocedure('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v2 authority is missing.';
  END IF;

  IF to_regprocedure('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Supervisor decision v1 authority is missing.';
  END IF;

  IF to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Grouped outcome lane materialization authority is missing.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.staff_decide_physical_receipt_review_v2(
  p_review_id uuid,
  p_decision text,
  p_allocations jsonb DEFAULT '[]'::jsonb,
  p_liable_party text DEFAULT 'unknown',
  p_decision_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_result jsonb;
  v_lane_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: supervisor physical receipt decision requires auth.uid().';
  END IF;

  IF p_review_id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review identity is required.';
  END IF;

  IF jsonb_typeof(COALESCE(p_allocations, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Supervisor allocation payload must be a JSON array.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(p_allocations, '[]'::jsonb)) allocation_row
    WHERE jsonb_typeof(allocation_row) <> 'object'
       OR EXISTS (
         SELECT 1
         FROM jsonb_object_keys(allocation_row) key_name
         WHERE key_name NOT IN (
           'remedy_allocation_id',
           'approved_remedy_type',
           'approved_remedy_qty',
           'supplier_cost_mode'
         )
       )
  ) THEN
    RAISE EXCEPTION 'Supervisor allocation rows contain unknown fields.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(COALESCE(p_allocations, '[]'::jsonb)) AS allocation_row(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
    WHERE allocation_row.remedy_allocation_id IS NULL
       OR allocation_row.approved_remedy_qty IS NULL
       OR allocation_row.approved_remedy_qty <= 0
       OR allocation_row.approved_remedy_qty <> TRUNC(allocation_row.approved_remedy_qty)
  ) THEN
    RAISE EXCEPTION 'Every supervisor physical remedy quantity must be a positive whole unit.';
  END IF;

  SELECT public.staff_decide_physical_receipt_review_v1(
    p_review_id,
    p_decision,
    p_allocations,
    p_liable_party,
    p_decision_note
  ) INTO v_result;

  IF lower(BTRIM(COALESCE(p_decision, ''))) = 'approve_existing_exception' THEN
    SELECT public.materialize_physical_receipt_outcome_lanes_v1(p_review_id)
    INTO v_lane_result;

    v_result := COALESCE(v_result, '{}'::jsonb)
      || jsonb_build_object('outcome_lane_materialization', v_lane_result);
  END IF;

  RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text) IS
'Authenticated exact whole-unit supervisor decision gateway. Approve-existing-exception atomically materializes grouped refund/replacement lanes before returning.';

REVOKE ALL ON FUNCTION public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
