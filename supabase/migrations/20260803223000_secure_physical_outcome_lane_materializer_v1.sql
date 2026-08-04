-- Security correction for physical outcome lane materialization.
-- Keeps the same function name/signature and additive lane model.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $preflight$
BEGIN
  IF to_regprocedure('public.materialize_physical_receipt_outcome_lanes_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing materialize_physical_receipt_outcome_lanes_v1(uuid)';
  END IF;
  IF to_regclass('public.physical_receipt_outcome_lanes') IS NULL
     OR to_regclass('public.physical_receipt_outcome_lane_items') IS NULL THEN
    RAISE EXCEPTION 'Outcome lane foundation is not installed';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(p_review_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_lane_id uuid;
  v_type text;
  v_count integer;
  v_result jsonb := '[]'::jsonb;
  v_auth_uid uuid := auth.uid();
  v_staff_id uuid;
  v_operator_id uuid;
  v_authorized boolean := false;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  SELECT * INTO v_review
  FROM public.physical_receipt_reviews
  WHERE id=p_review_id
  FOR UPDATE;

  IF v_review.id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review not found.';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id=v_auth_uid
    AND COALESCE(s.active,true)
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NOT NULL THEN
    v_authorized := true;
  ELSE
    SELECT op.id INTO v_operator_id
    FROM public.operators op
    JOIN public.operator_importers oi
      ON oi.operator_id=op.id
     AND oi.importer_id=v_review.importer_id
     AND oi.revoked_at IS NULL
    WHERE op.auth_user_id=v_auth_uid
      AND COALESCE(op.active,true)
    LIMIT 1;

    v_authorized := v_operator_id IS NOT NULL;
  END IF;

  IF NOT v_authorized THEN
    RAISE EXCEPTION 'User is not authorized to materialize lanes for this review.';
  END IF;

  FOR v_type IN
    SELECT DISTINCT r.approved_remedy_type
    FROM public.physical_exception_remedy_allocations r
    WHERE r.physical_receipt_review_id=p_review_id
      AND r.approved_remedy_type IN ('refund','replacement')
      AND r.status IN ('approved','linked_to_exception','in_progress','completed')
    ORDER BY 1
  LOOP
    INSERT INTO public.physical_receipt_outcome_lanes(order_id,physical_receipt_review_id,outcome_type)
    VALUES(v_review.order_id,v_review.id,v_type)
    ON CONFLICT(physical_receipt_review_id,outcome_type)
    DO UPDATE SET updated_at=now()
    RETURNING id INTO v_lane_id;

    INSERT INTO public.physical_receipt_outcome_lane_items(
      lane_id,physical_remedy_allocation_id,dispute_id,dispute_line_id
    )
    SELECT v_lane_id,r.id,dl.dispute_id,r.dispute_line_id
    FROM public.physical_exception_remedy_allocations r
    LEFT JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
    WHERE r.physical_receipt_review_id=p_review_id
      AND r.approved_remedy_type=v_type
      AND r.status IN ('approved','linked_to_exception','in_progress','completed')
    ON CONFLICT(physical_remedy_allocation_id)
    DO UPDATE SET lane_id=EXCLUDED.lane_id,dispute_id=EXCLUDED.dispute_id,dispute_line_id=EXCLUDED.dispute_line_id;

    GET DIAGNOSTICS v_count=ROW_COUNT;
    v_result := v_result || jsonb_build_array(jsonb_build_object('lane_id',v_lane_id,'outcome_type',v_type,'items_touched',v_count));
  END LOOP;

  RETURN jsonb_build_object('ok',true,'review_id',p_review_id,'lanes',v_result);
END;
$function$;

REVOKE ALL ON FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(uuid) TO authenticated,service_role;

COMMENT ON FUNCTION public.materialize_physical_receipt_outcome_lanes_v1(uuid) IS
'Materializes refund/replacement lanes for one physical receipt review. Restricted to active admin/supervisor staff or active operators linked to the review importer.';

NOTIFY pgrst,'reload schema';
COMMIT;
