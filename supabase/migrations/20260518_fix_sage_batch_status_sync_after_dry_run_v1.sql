BEGIN;

-- Fix Phase 11 dry-run status promotion.
-- Problem found live: row payload dry-run validation can complete successfully while
-- the parent sage_posting_batches.status remains 'draft'. This happens because the
-- original validation RPC updates rows and then reads the base table inside the same
-- data-modifying CTE snapshot, so the parent update can miss the just-updated row state.
--
-- This patch adds a small parent-batch status recompute helper + trigger and backfills
-- existing batches. No Sage API call. No posting. No schema widening.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_batches';
  END IF;

  IF to_regclass('public.sage_posting_batch_rows') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_batch_rows';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_recompute_sage_posting_batch_status_v1(
  p_batch_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_status text;
BEGIN
  IF p_batch_id IS NULL THEN
    RETURN NULL;
  END IF;

  WITH stats AS (
    SELECT
      COUNT(*) FILTER (WHERE r.posting_status <> 'excluded')::integer AS included_count,
      COUNT(*) FILTER (WHERE r.posting_status = 'excluded')::integer AS excluded_count,
      COUNT(*) FILTER (WHERE r.posting_status = 'posted')::integer AS posted_count,
      COUNT(*) FILTER (WHERE r.posting_status = 'posting')::integer AS posting_count,
      COUNT(*) FILTER (WHERE r.posting_status IN ('failed_retryable', 'failed_terminal'))::integer AS failed_count,
      COUNT(*) FILTER (WHERE r.posting_status <> 'excluded' AND r.payload_validation_status = 'dry_run_validated')::integer AS dry_run_ok_count,
      COUNT(*) FILTER (WHERE r.posting_status <> 'excluded' AND r.payload_validation_status = 'dry_run_failed')::integer AS dry_run_failed_count,
      COALESCE(SUM(r.amount_gbp) FILTER (WHERE r.posting_status <> 'excluded'), 0)::numeric(18,2) AS included_value
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
  ), decision AS (
    SELECT
      CASE
        WHEN s.included_count = 0 THEN NULL::text
        WHEN s.posted_count = s.included_count THEN 'posted'
        WHEN s.posting_count > 0 THEN 'posting'
        WHEN s.posted_count > 0 AND s.failed_count > 0 THEN 'partial_success'
        WHEN s.failed_count > 0 THEN 'failed'
        WHEN s.dry_run_ok_count = s.included_count AND s.dry_run_failed_count = 0 THEN 'validated'
        ELSE 'draft'
      END AS next_status,
      s.*
    FROM stats s
  )
  UPDATE public.sage_posting_batches b
  SET
    status = CASE
      WHEN b.status = 'cancelled' THEN b.status
      WHEN d.next_status IS NULL THEN b.status
      ELSE d.next_status
    END,
    row_count = COALESCE(d.included_count, b.row_count),
    total_amount_gbp = COALESCE(d.included_value, b.total_amount_gbp),
    success_count = COALESCE(d.posted_count, b.success_count),
    failed_count = COALESCE(d.failed_count, b.failed_count),
    blocked_count = COALESCE(d.excluded_count, b.blocked_count),
    posting_started_at = CASE
      WHEN d.next_status = 'posting' AND b.posting_started_at IS NULL THEN now()
      ELSE b.posting_started_at
    END,
    posting_completed_at = CASE
      WHEN d.next_status IN ('posted', 'partial_success', 'failed') AND b.posting_completed_at IS NULL THEN now()
      ELSE b.posting_completed_at
    END
  FROM decision d
  WHERE b.id = p_batch_id
  RETURNING b.status INTO v_status;

  RETURN v_status;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_recompute_sage_posting_batch_status_v1(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.internal_sync_sage_posting_batch_status_trigger_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch_id uuid;
BEGIN
  v_batch_id := COALESCE(NEW.batch_id, OLD.batch_id);
  PERFORM public.internal_recompute_sage_posting_batch_status_v1(v_batch_id);
  RETURN COALESCE(NEW, OLD);
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sync_sage_posting_batch_status_trigger_v1() FROM PUBLIC;

DROP TRIGGER IF EXISTS sage_posting_batch_rows_sync_batch_status_trg
ON public.sage_posting_batch_rows;

CREATE TRIGGER sage_posting_batch_rows_sync_batch_status_trg
AFTER INSERT OR UPDATE OR DELETE ON public.sage_posting_batch_rows
FOR EACH ROW
EXECUTE FUNCTION public.internal_sync_sage_posting_batch_status_trigger_v1();

-- Backfill existing local batches, including the batch already dry-run validated before this patch.
DO $$
DECLARE
  v_batch record;
BEGIN
  FOR v_batch IN
    SELECT b.id
    FROM public.sage_posting_batches b
    WHERE b.status <> 'cancelled'
  LOOP
    PERFORM public.internal_recompute_sage_posting_batch_status_v1(v_batch.id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
