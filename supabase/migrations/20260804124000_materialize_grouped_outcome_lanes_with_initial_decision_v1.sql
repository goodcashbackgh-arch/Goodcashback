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

-- One-time repair for unresolved reviews approved before materialization was integrated.
-- Deliberately exclude in_progress/completed remedies: those may be historical child-order routes
-- and must not be converted into the new grouped same-order route.
WITH eligible AS (
  SELECT DISTINCT
    review_row.id AS review_id,
    review_row.order_id,
    remedy_row.approved_remedy_type AS outcome_type
  FROM public.physical_receipt_reviews review_row
  JOIN public.physical_exception_remedy_allocations remedy_row
    ON remedy_row.physical_receipt_review_id = review_row.id
  WHERE review_row.status = 'approved_to_existing_exception'
    AND remedy_row.approved_remedy_type IN ('refund', 'replacement')
    AND remedy_row.status IN ('approved', 'linked_to_exception')
), inserted_lanes AS (
  INSERT INTO public.physical_receipt_outcome_lanes(
    order_id,
    physical_receipt_review_id,
    outcome_type
  )
  SELECT order_id, review_id, outcome_type
  FROM eligible
  ON CONFLICT (physical_receipt_review_id, outcome_type)
  DO UPDATE SET updated_at = now()
  RETURNING id
)
INSERT INTO public.physical_receipt_outcome_lane_items(
  lane_id,
  physical_remedy_allocation_id,
  dispute_id,
  dispute_line_id
)
SELECT
  lane.id,
  remedy_row.id,
  dispute_line.dispute_id,
  remedy_row.dispute_line_id
FROM public.physical_receipt_outcome_lanes lane
JOIN public.physical_exception_remedy_allocations remedy_row
  ON remedy_row.physical_receipt_review_id = lane.physical_receipt_review_id
 AND remedy_row.approved_remedy_type = lane.outcome_type
JOIN public.dispute_lines dispute_line
  ON dispute_line.id = remedy_row.dispute_line_id
WHERE lane.physical_receipt_review_id IN (SELECT review_id FROM eligible)
  AND remedy_row.status IN ('approved', 'linked_to_exception')
ON CONFLICT (physical_remedy_allocation_id)
DO UPDATE SET
  lane_id = EXCLUDED.lane_id,
  dispute_id = EXCLUDED.dispute_id,
  dispute_line_id = EXCLUDED.dispute_line_id;

DO $postflight$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.physical_receipt_reviews review_row
    JOIN public.physical_exception_remedy_allocations remedy_row
      ON remedy_row.physical_receipt_review_id = review_row.id
    WHERE review_row.status = 'approved_to_existing_exception'
      AND remedy_row.approved_remedy_type IN ('refund', 'replacement')
      AND remedy_row.status IN ('approved', 'linked_to_exception')
      AND NOT EXISTS (
        SELECT 1
        FROM public.physical_receipt_outcome_lane_items lane_item
        JOIN public.physical_receipt_outcome_lanes lane
          ON lane.id = lane_item.lane_id
        WHERE lane.physical_receipt_review_id = review_row.id
          AND lane.outcome_type = remedy_row.approved_remedy_type
          AND lane_item.physical_remedy_allocation_id = remedy_row.id
      )
  ) THEN
    RAISE EXCEPTION 'Postflight failed: an unresolved eligible physical remedy is missing its grouped outcome lane item.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.physical_receipt_outcome_lane_items lane_item
    WHERE lane_item.physical_remedy_allocation_id = '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid
  ) THEN
    RAISE EXCEPTION 'Postflight failed: historical legacy child-order remedy was incorrectly added to a grouped lane.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
