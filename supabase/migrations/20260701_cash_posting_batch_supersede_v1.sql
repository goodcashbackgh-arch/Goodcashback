BEGIN;

-- Cash posting local batch supersede v1.
-- Mirrors the AP/AR local Sage posting batch supersede pattern for cash batches.
-- No deletes. No Sage API call. Blocks if any row has posted or has a Sage object/allocation id.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_batches';
  END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_batch_rows';
  END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_snapshots';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_supersede_cash_posting_batch_v1(
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
#variable_conflict use_column
DECLARE
  v_staff_id uuid;
  v_batch_ref text;
  v_previous_status text;
  v_cancelled_rows integer := 0;
  v_deactivated_snapshots integer := 0;
  v_reason text := COALESCE(NULLIF(trim(p_reason), ''), 'Superseded local cash batch; re-freeze from current resolver.');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: cash batch supersede requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for cash batch supersede.';
  END IF;

  SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  SELECT b.batch_ref, b.batch_status
  INTO v_batch_ref, v_previous_status
  FROM public.cash_posting_batches b
  WHERE b.id = p_batch_id
    AND b.active = true
  FOR UPDATE;

  IF v_batch_ref IS NULL THEN
    RAISE EXCEPTION 'Active cash posting batch not found: %', p_batch_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.cash_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
      AND r.active = true
      AND (
        r.posting_status IN ('posted', 'posted_needs_review')
        OR NULLIF(trim(COALESCE(r.sage_object_id, '')), '') IS NOT NULL
        OR NULLIF(trim(COALESCE(r.sage_payment_on_account_id, '')), '') IS NOT NULL
        OR r.posted_at IS NOT NULL
        OR NULLIF(trim(COALESCE(r.sage_allocation_id, '')), '') IS NOT NULL
        OR r.sage_allocation_posted_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'Cannot supersede cash batch %. At least one row has already posted or has a Sage object/allocation id.', v_batch_ref;
  END IF;

  UPDATE public.cash_posting_batch_rows r
  SET active = false,
      posting_status = CASE WHEN r.posting_status = 'excluded' THEN 'excluded' ELSE 'cancelled' END,
      blocker = COALESCE(r.blocker, v_reason),
      error_code = CASE WHEN r.posting_status = 'excluded' THEN r.error_code ELSE COALESCE(r.error_code, 'superseded_local_cash_batch') END,
      error_message = CASE WHEN r.posting_status = 'excluded' THEN r.error_message ELSE COALESCE(r.error_message, v_reason) END,
      response_payload = COALESCE(r.response_payload, '{}'::jsonb) || jsonb_build_object(
        'superseded_local_cash_batch', true,
        'superseded_at', now(),
        'superseded_by_auth_user_id', auth.uid(),
        'superseded_by_staff_id', v_staff_id,
        'supersede_reason', v_reason
      ),
      updated_at = now(),
      last_attempt_at = COALESCE(r.last_attempt_at, now())
  WHERE r.batch_id = p_batch_id
    AND r.active = true
    AND r.posting_status NOT IN ('posted', 'posted_needs_review');

  GET DIAGNOSTICS v_cancelled_rows = ROW_COUNT;

  UPDATE public.cash_posting_snapshots s
  SET active = false,
      freeze_status = 'superseded',
      validation_status = 'superseded',
      validation_errors = COALESCE(s.validation_errors, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'code', 'superseded_local_cash_batch',
        'message', v_reason,
        'superseded_at', now(),
        'superseded_by_staff_id', v_staff_id
      )),
      notes = concat_ws(E'\n', NULLIF(s.notes, ''), 'SUPERSEDED LOCAL CASH BATCH: ' || v_reason),
      updated_at = now()
  WHERE s.id IN (
    SELECT DISTINCT r.snapshot_id
    FROM public.cash_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
      AND r.snapshot_id IS NOT NULL
      AND r.posting_status <> 'posted'
  )
    AND s.active = true
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
    AND NULLIF(trim(COALESCE(s.sage_object_id, '')), '') IS NULL
    AND NULLIF(trim(COALESCE(s.sage_payment_on_account_id, '')), '') IS NULL
    AND NULLIF(trim(COALESCE(s.sage_allocation_id, '')), '') IS NULL;

  GET DIAGNOSTICS v_deactivated_snapshots = ROW_COUNT;

  UPDATE public.cash_posting_batches b
  SET active = false,
      batch_status = 'superseded',
      failed_count = GREATEST(COALESCE(b.failed_count, 0), v_cancelled_rows),
      posting_completed_at = now(),
      notes = concat_ws(E'\n', NULLIF(b.notes, ''), 'SUPERSEDED LOCAL CASH BATCH: ' || v_reason),
      updated_at = now()
  WHERE b.id = p_batch_id;

  RETURN QUERY
  SELECT
    p_batch_id,
    v_batch_ref,
    v_previous_status,
    'superseded'::text,
    v_cancelled_rows,
    v_deactivated_snapshots,
    '/internal/accounting-command-centre/cash-posting?status=ready'::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supersede_cash_posting_batch_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supersede_cash_posting_batch_v1(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.internal_supersede_cash_posting_batch_v1(uuid, text) IS
'Safely supersedes an unposted local cash posting batch. Blocks if any row has posted or has Sage object/allocation ids. Deactivates batch rows and snapshots so cash workbench can re-freeze from current resolver. No Sage API call.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks after execution:
-- select to_regprocedure('public.internal_supersede_cash_posting_batch_v1(uuid,text)') as supersede_rpc;
