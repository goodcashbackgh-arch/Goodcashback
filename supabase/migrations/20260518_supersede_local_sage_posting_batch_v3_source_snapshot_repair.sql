BEGIN;

-- Supersede v3: source-level snapshot deactivation.
-- Problem fixed: cancelling a no-Sage-call posting batch could leave older active
-- snapshots for the same source_table/source_id/document_lane visible as
-- frozen_ready_to_post, causing empty £0 preview-freeze batches.
--
-- This patch:
-- 1) Updates the supersede RPC to deactivate all active non-posted snapshots for
--    the same source rows in the superseded/cancelled batch.
-- 2) Repairs already-cancelled/superseded local batches by deactivating stale
--    source-matched snapshots created before that batch was cancelled.
--
-- No Sage API call. No deletion. Posted Sage rows/snapshots are not touched.

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

  WITH batch_sources AS (
    SELECT DISTINCT
      COALESCE(r.source_table, s0.source_table) AS source_table,
      COALESCE(r.source_id, s0.source_id) AS source_id,
      COALESCE(r.document_lane, s0.document_lane) AS document_lane
    FROM public.sage_posting_batch_rows r
    LEFT JOIN public.sage_posting_snapshots s0 ON s0.id = r.snapshot_id
    WHERE r.batch_id = p_batch_id
      AND r.posting_status <> 'posted'
      AND COALESCE(r.source_id, s0.source_id) IS NOT NULL
      AND COALESCE(r.source_table, s0.source_table) IS NOT NULL
      AND COALESCE(r.document_lane, s0.document_lane) IS NOT NULL
  ), deactivated AS (
    UPDATE public.sage_posting_snapshots s
    SET active = false,
        approval_status = 'superseded',
        revalidation_status = 'not_revalidated',
        revalidation_notes = COALESCE(NULLIF(p_reason, ''), 'Superseded local batch; re-freeze from current resolver'),
        revalidated_at = now()
    FROM batch_sources bs
    WHERE s.source_table = bs.source_table
      AND s.source_id = bs.source_id
      AND s.document_lane = bs.document_lane
      AND s.active = true
      AND s.sage_posting_status <> 'posted'
    RETURNING s.id
  )
  SELECT COUNT(*)::integer INTO v_deactivated_snapshots FROM deactivated;

  UPDATE public.sage_posting_batches b
  SET status = 'cancelled',
      batch_status = 'superseded',
      blocked_count = GREATEST(COALESCE(b.blocked_count, 0), v_cancelled_rows),
      posting_completed_at = COALESCE(b.posting_completed_at, now()),
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

WITH cancelled_sources AS (
  SELECT DISTINCT
    COALESCE(r.source_table, s0.source_table) AS source_table,
    COALESCE(r.source_id, s0.source_id) AS source_id,
    COALESCE(r.document_lane, s0.document_lane) AS document_lane,
    COALESCE(b.posting_completed_at, b.created_at, now()) AS cutoff_at
  FROM public.sage_posting_batches b
  JOIN public.sage_posting_batch_rows r ON r.batch_id = b.id
  LEFT JOIN public.sage_posting_snapshots s0 ON s0.id = r.snapshot_id
  WHERE (b.status = 'cancelled' OR b.batch_status = 'superseded')
    AND r.posting_status <> 'posted'
    AND COALESCE(r.source_id, s0.source_id) IS NOT NULL
    AND COALESCE(r.source_table, s0.source_table) IS NOT NULL
    AND COALESCE(r.document_lane, s0.document_lane) IS NOT NULL
), repaired AS (
  UPDATE public.sage_posting_snapshots s
  SET active = false,
      approval_status = 'superseded',
      revalidation_status = 'not_revalidated',
      revalidation_notes = 'Auto-repaired stale active snapshot after local batch supersede/cancel',
      revalidated_at = now()
  FROM cancelled_sources cs
  WHERE s.source_table = cs.source_table
    AND s.source_id = cs.source_id
    AND s.document_lane = cs.document_lane
    AND s.active = true
    AND s.sage_posting_status <> 'posted'
    AND s.created_at <= cs.cutoff_at
  RETURNING s.id
)
SELECT COUNT(*) AS repaired_stale_snapshot_count FROM repaired;

NOTIFY pgrst, 'reload schema';
COMMIT;
