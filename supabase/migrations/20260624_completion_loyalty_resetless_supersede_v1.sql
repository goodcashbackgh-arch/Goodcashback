BEGIN;

-- Completion loyalty resetless supersede v1.
-- Allows staff to retire a failed/unposted loyalty Sage batch and its frozen group(s)
-- without deleting audit history, so the source credit_applied event can be materialised again.
-- Blocks if any linked Sage step may already have posted.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.completion_loyalty_sage_posting_batches') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_batches'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_batch_items') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_batch_items'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_groups') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_groups'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_steps') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_steps'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_step_logs') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_step_logs'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_staff_id_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_staff_id_v1()'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_supersede_completion_loyalty_sage_batch_resetless_v1(
  p_batch_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch record;
  v_staff_id uuid;
  v_reason text := COALESCE(NULLIF(trim(p_reason), ''), 'Resetless supersede before any Sage object posted; re-materialise from current resolver.');
  v_group_count integer := 0;
  v_item_count integer := 0;
  v_step_count integer := 0;
  v_blocking_step record;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: resetless loyalty Sage batch supersede requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for resetless loyalty Sage batch supersede.';
  END IF;

  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;
  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff record required for resetless loyalty Sage batch supersede.';
  END IF;

  SELECT * INTO v_batch
  FROM public.completion_loyalty_sage_posting_batches b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Completion-loyalty Sage batch not found: %', p_batch_id;
  END IF;

  IF COALESCE(v_batch.batch_type, '') <> 'completion_loyalty_applied_settlement' THEN
    RAISE EXCEPTION 'Resetless supersede currently supports applied-loyalty settlement batches only. Found %.', v_batch.batch_type;
  END IF;

  IF v_batch.active IS NOT TRUE OR v_batch.status IN ('cancelled', 'superseded') THEN
    RAISE EXCEPTION 'Batch % is already inactive/cancelled/superseded.', v_batch.batch_ref;
  END IF;

  IF v_batch.status IN ('posting_to_sage', 'posted_to_sage', 'partially_posted_needs_review') THEN
    RAISE EXCEPTION 'Batch % cannot be resetlessly superseded from status %. Review/retry/correction is required.', v_batch.batch_ref, v_batch.status;
  END IF;

  PERFORM 1
  FROM public.completion_loyalty_sage_posting_batch_items bi
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true
  FOR UPDATE;

  PERFORM 1
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id IN (
    SELECT bi.posting_group_id
    FROM public.completion_loyalty_sage_posting_batch_items bi
    WHERE bi.batch_id = p_batch_id
      AND bi.active = true
  )
  FOR UPDATE;

  SELECT s.* INTO v_blocking_step
  FROM public.completion_loyalty_sage_posting_steps s
  JOIN public.completion_loyalty_sage_posting_batch_items bi
    ON bi.posting_group_id = s.posting_group_id
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true
    AND s.active = true
    AND (
      s.status = 'posted_to_sage'
      OR s.sage_object_id IS NOT NULL
      OR s.posted_at IS NOT NULL
    )
  ORDER BY s.posted_at DESC NULLS LAST, s.created_at DESC
  LIMIT 1;

  IF v_blocking_step.id IS NOT NULL THEN
    RAISE EXCEPTION 'Batch % cannot be resetlessly superseded because step % may already have posted to Sage. Use retry/review/correction instead.', v_batch.batch_ref, v_blocking_step.step_type;
  END IF;

  UPDATE public.completion_loyalty_sage_posting_steps s
  SET status = 'superseded',
      active = false,
      last_error = v_reason,
      updated_at = now()
  WHERE s.active = true
    AND s.posting_group_id IN (
      SELECT bi.posting_group_id
      FROM public.completion_loyalty_sage_posting_batch_items bi
      WHERE bi.batch_id = p_batch_id
        AND bi.active = true
    );
  GET DIAGNOSTICS v_step_count = ROW_COUNT;

  UPDATE public.completion_loyalty_sage_posting_groups g
  SET status = 'superseded',
      active = false,
      approval_status = 'invalidated',
      superseded_at = now(),
      superseded_by_staff_id = v_staff_id,
      supersede_reason = v_reason,
      updated_at = now()
  WHERE g.id IN (
    SELECT bi.posting_group_id
    FROM public.completion_loyalty_sage_posting_batch_items bi
    WHERE bi.batch_id = p_batch_id
      AND bi.active = true
  );
  GET DIAGNOSTICS v_group_count = ROW_COUNT;

  UPDATE public.completion_loyalty_sage_posting_batch_items bi
  SET item_status = 'superseded',
      posting_status = 'superseded',
      active = false,
      updated_at = now()
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true;
  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE public.completion_loyalty_sage_posting_batches b
  SET status = 'superseded',
      approval_status = 'invalidated',
      active = false,
      last_posting_error = v_reason,
      updated_at = now()
  WHERE b.id = p_batch_id;

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (
    posting_group_id,
    log_type,
    message,
    payload,
    created_by_staff_id
  )
  SELECT
    g.id,
    'batch_resetless_supersede',
    'Completion-loyalty Sage batch resetlessly superseded before any Sage object posted.',
    jsonb_build_object(
      'batch_id', p_batch_id,
      'batch_ref', v_batch.batch_ref,
      'reason', v_reason,
      'superseded_item_count', v_item_count,
      'superseded_step_count', v_step_count
    ),
    v_staff_id
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id IN (
    SELECT bi.posting_group_id
    FROM public.completion_loyalty_sage_posting_batch_items bi
    WHERE bi.batch_id = p_batch_id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'batch_id', p_batch_id,
    'batch_ref', v_batch.batch_ref,
    'status', 'superseded',
    'superseded_group_count', v_group_count,
    'superseded_item_count', v_item_count,
    'superseded_step_count', v_step_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_supersede_completion_loyalty_sage_batch_resetless_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_supersede_completion_loyalty_sage_batch_resetless_v1(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.staff_supersede_completion_loyalty_sage_batch_resetless_v1(uuid, text) IS
'Resetless supersede for failed/unposted completion-loyalty Sage batches. Blocks if any linked Sage step has posted/object id/posted_at; keeps audit history and frees source for fresh materialisation.';

NOTIFY pgrst, 'reload schema';

COMMIT;
