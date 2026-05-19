BEGIN;

-- Sage source posting status resolver v1.
--
-- Purpose:
--   Do not add duplicate sage_status columns to operational source tables
--   such as supplier_invoices. The Sage posting ledger is the source of truth.
--
-- Contract alignment:
--   For each source_table + source_id + document_lane:
--     1. Posted snapshot wins.
--     2. If none posted, latest active non-posted snapshot wins.
--     3. Historical inactive/superseded snapshots are retained as audit only.
--
-- No source rows are mutated by this migration.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_snapshots';
  END IF;

  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

-- Add optional AP evidence attachment control fields to the posting ledger.
-- These are intentionally on the posting ledger, not on supplier_invoices.
ALTER TABLE public.sage_posting_snapshots
  ADD COLUMN IF NOT EXISTS sage_attachment_status text NOT NULL DEFAULT 'not_attempted',
  ADD COLUMN IF NOT EXISTS sage_attachment_attempt_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS sage_attachment_object_id text,
  ADD COLUMN IF NOT EXISTS sage_attachment_file_name text,
  ADD COLUMN IF NOT EXISTS sage_attachment_source_url text,
  ADD COLUMN IF NOT EXISTS sage_attachment_error_code text,
  ADD COLUMN IF NOT EXISTS sage_attachment_error_message text,
  ADD COLUMN IF NOT EXISTS sage_attachment_attempted_at timestamptz,
  ADD COLUMN IF NOT EXISTS sage_attachment_attached_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sage_posting_snapshots_attachment_status_chk'
      AND conrelid = 'public.sage_posting_snapshots'::regclass
  ) THEN
    ALTER TABLE public.sage_posting_snapshots
      ADD CONSTRAINT sage_posting_snapshots_attachment_status_chk CHECK (
        sage_attachment_status IN (
          'not_required',
          'not_attempted',
          'pending',
          'attached',
          'failed_retryable',
          'failed_terminal',
          'unsupported'
        )
      );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sage_posting_snapshots_attachment_attempt_count_chk'
      AND conrelid = 'public.sage_posting_snapshots'::regclass
  ) THEN
    ALTER TABLE public.sage_posting_snapshots
      ADD CONSTRAINT sage_posting_snapshots_attachment_attempt_count_chk CHECK (
        sage_attachment_attempt_count >= 0
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_sage_posting_snapshots_source_current_lookup
  ON public.sage_posting_snapshots(source_table, source_id, document_lane, sage_posting_status, active, created_at DESC)
  WHERE source_table IS NOT NULL
    AND source_id IS NOT NULL
    AND document_lane IS NOT NULL;

CREATE OR REPLACE FUNCTION public.internal_sage_source_posting_status_v1(
  p_source_table text DEFAULT NULL,
  p_source_id uuid DEFAULT NULL,
  p_document_lane text DEFAULT NULL
)
RETURNS TABLE (
  source_table text,
  source_id uuid,
  document_lane text,
  current_snapshot_id uuid,
  current_batch_id uuid,
  source_posting_status text,
  sage_posting_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  sage_attachment_status text,
  sage_attachment_object_id text,
  sage_attachment_source_url text,
  sage_attachment_attached_at timestamptz,
  sage_attachment_error_code text,
  sage_attachment_error_message text,
  last_posting_error text,
  current_active boolean,
  superseded_by_snapshot_id uuid,
  current_created_at timestamptz,
  current_reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage source posting status requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for Sage source posting status.';
  END IF;

  RETURN QUERY
  WITH filtered AS (
    SELECT s.*
    FROM public.sage_posting_snapshots s
    WHERE s.source_table IS NOT NULL
      AND s.source_id IS NOT NULL
      AND s.document_lane IS NOT NULL
      AND (p_source_table IS NULL OR s.source_table = p_source_table)
      AND (p_source_id IS NULL OR s.source_id = p_source_id)
      AND (p_document_lane IS NULL OR s.document_lane = p_document_lane)
  ), ranked AS (
    SELECT
      f.*,
      row_number() OVER (
        PARTITION BY f.source_table, f.source_id, f.document_lane
        ORDER BY
          CASE
            WHEN f.sage_posting_status = 'posted' AND f.sage_invoice_id IS NOT NULL THEN 0
            WHEN COALESCE(f.active, false) = true AND f.superseded_by_snapshot_id IS NULL THEN 1
            ELSE 2
          END,
          COALESCE(f.sage_posted_at, f.created_at) DESC,
          f.created_at DESC,
          f.id DESC
      ) AS rn
    FROM filtered f
  )
  SELECT
    r.source_table,
    r.source_id,
    r.document_lane,
    r.id AS current_snapshot_id,
    r.batch_id AS current_batch_id,
    CASE
      WHEN r.sage_posting_status = 'posted' AND r.sage_invoice_id IS NOT NULL THEN 'posted'
      WHEN COALESCE(r.active, false) = false OR r.superseded_by_snapshot_id IS NOT NULL THEN 'history_only'
      WHEN r.sage_posting_status IN ('posting_failed', 'failed', 'failed_retryable', 'failed_terminal') THEN 'failed'
      WHEN r.approval_status = 'approved_frozen' THEN 'frozen_not_posted'
      ELSE COALESCE(NULLIF(r.sage_posting_status, ''), 'not_posted')
    END::text AS source_posting_status,
    r.sage_posting_status,
    r.sage_invoice_id,
    r.sage_posted_at,
    r.sage_attachment_status,
    r.sage_attachment_object_id,
    COALESCE(
      NULLIF(r.sage_attachment_source_url, ''),
      NULLIF(r.resolved_payload #>> '{source_evidence,file_url}', ''),
      NULLIF(r.resolved_payload #>> '{source_payload,supplier_invoice_pdf_url}', ''),
      NULLIF(r.resolved_payload #>> '{source_payload,invoice_pdf_url}', ''),
      NULLIF(r.commercial_payload #>> '{source_evidence,file_url}', ''),
      NULLIF(r.commercial_payload #>> '{supplier_invoice_pdf_url}', ''),
      NULLIF(r.commercial_payload #>> '{invoice_pdf_url}', '')
    )::text AS sage_attachment_source_url,
    r.sage_attachment_attached_at,
    r.sage_attachment_error_code,
    r.sage_attachment_error_message,
    r.last_posting_error,
    r.active AS current_active,
    r.superseded_by_snapshot_id,
    r.created_at AS current_created_at,
    CASE
      WHEN r.sage_posting_status = 'posted' AND r.sage_invoice_id IS NOT NULL THEN 'posted_snapshot_wins'
      WHEN COALESCE(r.active, false) = true AND r.superseded_by_snapshot_id IS NULL THEN 'latest_active_non_posted_snapshot'
      ELSE 'historical_snapshot_only'
    END::text AS current_reason
  FROM ranked r
  WHERE r.rn = 1
  ORDER BY r.document_lane, r.source_table, r.created_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_source_posting_status_v1(text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_source_posting_status_v1(text, uuid, text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
