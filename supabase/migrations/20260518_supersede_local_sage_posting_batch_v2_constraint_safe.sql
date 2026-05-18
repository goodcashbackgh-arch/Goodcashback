BEGIN;

-- Constraint-safe replacement for local batch supersede / void control.
-- Does not delete data and does not call Sage.
-- Uses allowed snapshot statuses:
--   approval_status = 'superseded'
--   revalidation_status = 'not_revalidated'
--   batch_status = 'superseded'
--   status = 'cancelled'

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_supersede_sage_posting_batch_v1(
  p_batch_id uuid,
  p_reason text DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  previous_status text,
  new_status text,
  cancelled_row_count integer,
  deactivated_snapshot_count integer,
  detail_href text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_batch_ref text;
  v_previous_status text;
  v_cancelled_rows integer := 0;
  v_deactivated_snapshots integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: batch supersede requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for batch supersede.';
  END IF;

  SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  SELECT b.batch_ref, b.status
  INTO v_batch_ref, v_previous_status
  FROM public.sage_posting_batches b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF v_batch_ref IS NULL THEN
    RAISE EXCEPTION 'Posting batch not found: %', p_batch_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
      AND (
        r.posting_status = 'posted'
        OR NULLIF(r.sage_object_id, '') IS NOT NULL
        OR r.posted_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'Cannot supersede batch %. At least one row has already posted to Sage.', v_batch_ref;
  END IF;

  UPDATE public.sage_posting_batch_rows r
  SET posting_status = CASE WHEN r.posting_status = 'excluded' THEN 'excluded' ELSE 'cancelled' END,
      payload_validation_status = CASE WHEN r.posting_status = 'excluded' THEN r.payload_validation_status ELSE 'excluded_before_validation' END,
      error_code = CASE WHEN r.posting_status = 'excluded' THEN r.error_code ELSE 'superseded_local_batch' END,
      error_message = CASE WHEN r.posting_status = 'excluded' THEN r.error_message ELSE COALESCE(NULLIF(p_reason, ''), 'Superseded locally before Sage posting. Re-freeze from current source resolver.') END,
      response_payload_json = COALESCE(r.response_payload_json, '{}'::jsonb) || jsonb_build_object(
        'superseded_local_batch', true,
        'superseded_at', now(),
        'superseded_by_auth_user_id', auth.uid(),
        'superseded_by_staff_id', v_staff_id,
        'supersede_reason', COALESCE(NULLIF(p_reason, ''), 'Re-freeze from current resolver')
      ),
      last_attempt_at = now()
  WHERE r.batch_id = p_batch_id
    AND r.posting_status NOT IN ('posted', 'cancelled');

  GET DIAGNOSTICS v_cancelled_rows = ROW_COUNT;

  -- Keep old snapshots for audit but remove them from active queues.
  UPDATE public.sage_posting_snapshots s
  SET active = false,
      approval_status = 'superseded',
      revalidation_status = 'not_revalidated',
      revalidation_notes = COALESCE(NULLIF(p_reason, ''), 'Superseded local batch; re-freeze from current resolver'),
      revalidated_at = now()
  WHERE s.id IN (
    SELECT DISTINCT r.snapshot_id
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
      AND r.snapshot_id IS NOT NULL
      AND r.posting_status <> 'posted'
  )
    AND s.sage_posting_status <> 'posted';

  GET DIAGNOSTICS v_deactivated_snapshots = ROW_COUNT;

  UPDATE public.sage_posting_batches b
  SET status = 'cancelled',
      batch_status = 'superseded',
      blocked_count = GREATEST(COALESCE(b.blocked_count, 0), v_cancelled_rows),
      posting_completed_at = now(),
      notes = concat_ws(E'\n', NULLIF(b.notes, ''), 'SUPERSEDED LOCAL BATCH: ' || COALESCE(NULLIF(p_reason, ''), 'Re-freeze from current resolver'))
  WHERE b.id = p_batch_id;

  RETURN QUERY
  SELECT
    p_batch_id,
    v_batch_ref,
    v_previous_status,
    'cancelled'::text,
    v_cancelled_rows,
    v_deactivated_snapshots,
    ('/internal/accounting-command-centre?queue=live_ready_not_frozen')::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supersede_sage_posting_batch_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supersede_sage_posting_batch_v1(uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
