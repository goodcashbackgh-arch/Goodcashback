BEGIN;

-- Sage posting batch model v1
-- Contract v4 Phase 9 + Phase 10 only.
-- Scope: create posting batches from already frozen/revalidated snapshots with NO Sage API call.
-- Posting stays disabled until Sage OAuth + dry-run validation are proven.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sage_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_batches';
  END IF;

  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_posting_snapshots';
  END IF;

  IF to_regprocedure('public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)';
  END IF;

  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

ALTER TABLE public.sage_posting_batches
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'draft',
  ADD COLUMN IF NOT EXISTS lane text NOT NULL DEFAULT 'mixed',
  ADD COLUMN IF NOT EXISTS row_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS posting_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS posting_completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS success_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS failed_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS blocked_count integer NOT NULL DEFAULT 0;

UPDATE public.sage_posting_batches
SET status = CASE
    WHEN batch_status = 'posted' THEN 'posted'
    WHEN batch_status = 'partially_posted' THEN 'partial_success'
    WHEN batch_status = 'voided' THEN 'cancelled'
    ELSE COALESCE(NULLIF(status, ''), 'draft')
  END,
  lane = COALESCE(NULLIF(lane, ''), 'mixed')
WHERE status IS NULL OR status = '' OR lane IS NULL OR lane = '';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sage_posting_batches_v4_status_chk'
      AND conrelid = 'public.sage_posting_batches'::regclass
  ) THEN
    ALTER TABLE public.sage_posting_batches
      ADD CONSTRAINT sage_posting_batches_v4_status_chk CHECK (status IN (
        'draft',
        'validated',
        'posting',
        'partial_success',
        'posted',
        'failed',
        'cancelled'
      ));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sage_posting_batches_counts_nonnegative_chk'
      AND conrelid = 'public.sage_posting_batches'::regclass
  ) THEN
    ALTER TABLE public.sage_posting_batches
      ADD CONSTRAINT sage_posting_batches_counts_nonnegative_chk CHECK (
        row_count >= 0
        AND total_amount_gbp >= 0
        AND success_count >= 0
        AND failed_count >= 0
        AND blocked_count >= 0
      );
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.sage_posting_batch_rows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.sage_posting_batches(id) ON DELETE CASCADE,
  snapshot_id uuid REFERENCES public.sage_posting_snapshots(id) ON DELETE RESTRICT,
  idempotency_key text,
  posting_status text NOT NULL DEFAULT 'included' CHECK (posting_status IN (
    'included',
    'excluded',
    'validated',
    'posting',
    'posted',
    'failed_retryable',
    'failed_terminal',
    'cancelled'
  )),
  sage_object_type text,
  sage_object_id text,
  sage_reference text,
  request_payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  response_payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  payload_hash text,
  error_code text,
  error_message text,
  attempt_count integer NOT NULL DEFAULT 0,
  posted_at timestamptz,
  last_attempt_at timestamptz,
  exclusion_reason text,
  payload_validation_status text NOT NULL DEFAULT 'not_dry_run_validated' CHECK (payload_validation_status IN (
    'not_dry_run_validated',
    'local_validated_pending_sage_dry_run',
    'excluded_before_validation',
    'dry_run_validated',
    'dry_run_failed',
    'posting_disabled_until_sage_connection_tested'
  )),
  source_table text,
  source_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  reference_text text,
  counterparty_name text,
  amount_gbp numeric(18,2),
  currency_code text NOT NULL DEFAULT 'GBP',
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_by_auth_user_id uuid,
  CONSTRAINT sage_posting_batch_rows_attempt_count_chk CHECK (attempt_count >= 0),
  CONSTRAINT sage_posting_batch_rows_posted_object_chk CHECK (
    posting_status <> 'posted'
    OR (sage_object_id IS NOT NULL AND posted_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.sage_posting_batch_rows IS
'Rows locked into a v4 Sage posting batch. Phase 10 only creates rows; no Sage API call or posting occurs here.';

CREATE INDEX IF NOT EXISTS idx_sage_posting_batches_v4_status
  ON public.sage_posting_batches(status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sage_posting_batches_lane
  ON public.sage_posting_batches(lane, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sage_posting_batch_rows_batch
  ON public.sage_posting_batch_rows(batch_id, posting_status);

CREATE INDEX IF NOT EXISTS idx_sage_posting_batch_rows_snapshot
  ON public.sage_posting_batch_rows(snapshot_id)
  WHERE snapshot_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sage_posting_batch_rows_idempotency
  ON public.sage_posting_batch_rows(idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_sage_posting_batch_rows_one_active_batch_per_snapshot
  ON public.sage_posting_batch_rows(snapshot_id)
  WHERE snapshot_id IS NOT NULL
    AND posting_status NOT IN ('excluded', 'cancelled');

ALTER TABLE public.sage_posting_batch_rows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sage_posting_batch_rows_staff_select ON public.sage_posting_batch_rows;
CREATE POLICY sage_posting_batch_rows_staff_select
ON public.sage_posting_batch_rows
FOR SELECT
TO authenticated
USING (public.is_active_staff());

CREATE OR REPLACE FUNCTION public.internal_create_sage_posting_batch_from_filter_v1(
  p_queue text DEFAULT 'frozen_ready_to_post',
  p_lane text DEFAULT 'all',
  p_posting_gate text DEFAULT 'ready_to_post',
  p_search text DEFAULT NULL,
  p_include_warnings boolean DEFAULT false,
  p_notes text DEFAULT NULL,
  p_max_rows integer DEFAULT 5000
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  status text,
  lane text,
  included_count integer,
  excluded_count integer,
  total_amount_gbp numeric,
  detail_href text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_batch_id uuid;
  v_batch_ref text;
  v_lane text := COALESCE(NULLIF(p_lane, ''), 'all');
  v_batch_lane text;
  v_included_count integer;
  v_excluded_count integer;
  v_total_amount numeric(18,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: posting batch creation requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for posting batch creation.';
  END IF;

  SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  CREATE TEMP TABLE tmp_sage_posting_batch_candidates ON COMMIT DROP AS
  WITH candidates AS (
    SELECT c.*
    FROM public.internal_accounting_command_centre_bulk_candidates_v1(
      COALESCE(NULLIF(p_queue, ''), 'frozen_ready_to_post'),
      COALESCE(NULLIF(p_lane, ''), 'all'),
      COALESCE(NULLIF(p_posting_gate, ''), 'ready_to_post'),
      NULLIF(trim(COALESCE(p_search, '')), ''),
      'revalidate',
      'all',
      p_include_warnings,
      LEAST(GREATEST(COALESCE(p_max_rows, 5000), 1), 10000)
    ) c
  ), assessed AS (
    SELECT
      c.*,
      s.id AS locked_snapshot_id,
      br.id AS locked_row_id,
      lb.batch_ref AS locked_batch_ref,
      CASE
        WHEN c.snapshot_id IS NULL THEN 'missing_snapshot_id'
        WHEN c.excluded_reason IS NOT NULL THEN c.excluded_reason
        WHEN br.id IS NOT NULL THEN 'already_locked_to_batch:' || COALESCE(lb.batch_ref, br.batch_id::text)
        WHEN c.candidate_status = 'ok_to_post' AND c.posting_gate = 'ready_to_post' THEN NULL::text
        WHEN p_include_warnings = true AND c.candidate_status = 'warning_only' THEN NULL::text
        WHEN c.posting_gate <> 'ready_to_post' THEN 'not_ready_to_post:' || COALESCE(c.posting_gate, 'unknown')
        ELSE 'not_ok_to_post:' || COALESCE(c.candidate_status, 'unknown')
      END AS final_exclusion_reason
    FROM candidates c
    LEFT JOIN public.sage_posting_snapshots s
      ON s.id = c.snapshot_id
    LEFT JOIN public.sage_posting_batch_rows br
      ON br.snapshot_id = c.snapshot_id
     AND br.posting_status NOT IN ('excluded', 'cancelled')
    LEFT JOIN public.sage_posting_batches lb
      ON lb.id = br.batch_id
  )
  SELECT * FROM assessed;

  SELECT COUNT(*)::integer,
         COALESCE(SUM(amount_gbp), 0)::numeric(18,2)
  INTO v_included_count, v_total_amount
  FROM tmp_sage_posting_batch_candidates
  WHERE final_exclusion_reason IS NULL;

  SELECT COUNT(*)::integer
  INTO v_excluded_count
  FROM tmp_sage_posting_batch_candidates
  WHERE final_exclusion_reason IS NOT NULL;

  IF v_included_count = 0 THEN
    RAISE EXCEPTION 'No ready-to-post frozen snapshots matched this filter. Excluded rows: %', COALESCE(v_excluded_count, 0);
  END IF;

  SELECT CASE
    WHEN COUNT(DISTINCT document_lane) FILTER (WHERE final_exclusion_reason IS NULL) = 1 THEN MIN(document_lane) FILTER (WHERE final_exclusion_reason IS NULL)
    WHEN v_lane IN ('customer_sales','shipper_ap') THEN v_lane
    ELSE 'mixed'
  END
  INTO v_batch_lane
  FROM tmp_sage_posting_batch_candidates;

  INSERT INTO public.sage_posting_batches (
    batch_kind,
    batch_status,
    status,
    lane,
    row_count,
    total_amount_gbp,
    success_count,
    failed_count,
    blocked_count,
    created_by_staff_id,
    created_by_auth_user_id,
    notes,
    source
  ) VALUES (
    'posting_batch',
    'frozen_pending_posting',
    'draft',
    COALESCE(v_batch_lane, 'mixed'),
    v_included_count,
    v_total_amount,
    0,
    0,
    v_excluded_count,
    v_staff_id,
    auth.uid(),
    p_notes,
    'internal_create_sage_posting_batch_from_filter_v1'
  )
  RETURNING id, batch_ref INTO v_batch_id, v_batch_ref;

  INSERT INTO public.sage_posting_batch_rows (
    batch_id,
    snapshot_id,
    idempotency_key,
    posting_status,
    sage_object_type,
    request_payload_json,
    response_payload_json,
    payload_hash,
    error_code,
    error_message,
    attempt_count,
    exclusion_reason,
    payload_validation_status,
    source_table,
    source_id,
    document_lane,
    document_type,
    order_ref,
    reference_text,
    counterparty_name,
    amount_gbp,
    currency_code,
    created_by_staff_id,
    created_by_auth_user_id
  )
  SELECT
    v_batch_id,
    c.snapshot_id,
    COALESCE(s.idempotency_key, c.snapshot_id::text),
    CASE WHEN c.final_exclusion_reason IS NULL THEN 'included' ELSE 'excluded' END,
    CASE
      WHEN c.document_lane = 'customer_sales' THEN 'sales_invoice'
      WHEN c.document_lane = 'shipper_ap' THEN 'purchase_invoice'
      ELSE c.document_type
    END,
    CASE WHEN c.final_exclusion_reason IS NULL THEN COALESCE(s.resolved_payload, '{}'::jsonb) ELSE '{}'::jsonb END,
    '{}'::jsonb,
    CASE WHEN c.final_exclusion_reason IS NULL THEN md5(COALESCE(s.resolved_payload::text, '')) ELSE NULL::text END,
    CASE WHEN c.final_exclusion_reason IS NULL THEN NULL::text ELSE 'excluded_before_batch' END,
    c.final_exclusion_reason,
    0,
    c.final_exclusion_reason,
    CASE
      WHEN c.final_exclusion_reason IS NULL THEN 'local_validated_pending_sage_dry_run'
      ELSE 'excluded_before_validation'
    END,
    c.source_table,
    c.source_id,
    c.document_lane,
    c.document_type,
    c.order_ref,
    c.reference_text,
    c.counterparty_name,
    c.amount_gbp,
    'GBP',
    v_staff_id,
    auth.uid()
  FROM tmp_sage_posting_batch_candidates c
  LEFT JOIN public.sage_posting_snapshots s
    ON s.id = c.snapshot_id;

  RETURN QUERY
  SELECT
    v_batch_id,
    v_batch_ref,
    'draft'::text,
    COALESCE(v_batch_lane, 'mixed')::text,
    v_included_count,
    v_excluded_count,
    v_total_amount,
    ('/internal/accounting-command-centre/batches/' || v_batch_id::text)::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_sage_posting_batch_from_filter_v1(text, text, text, text, boolean, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_create_sage_posting_batch_from_filter_v1(text, text, text, text, boolean, text, integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_sage_posting_batch_detail_v1(
  p_batch_id uuid
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_status text,
  status text,
  lane text,
  row_count integer,
  total_amount_gbp numeric,
  success_count integer,
  failed_count integer,
  blocked_count integer,
  notes text,
  created_at timestamptz,
  created_by_staff_id uuid,
  posting_started_at timestamptz,
  posting_completed_at timestamptz,
  batch_summary jsonb,
  row_id uuid,
  snapshot_id uuid,
  idempotency_key text,
  posting_status text,
  sage_object_type text,
  sage_object_id text,
  sage_reference text,
  payload_hash text,
  payload_validation_status text,
  exclusion_reason text,
  error_code text,
  error_message text,
  attempt_count integer,
  posted_at timestamptz,
  last_attempt_at timestamptz,
  source_table text,
  source_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  reference_text text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  request_payload_json jsonb,
  response_payload_json jsonb,
  row_created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: posting batch detail requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for posting batch detail.';
  END IF;

  RETURN QUERY
  WITH batch AS (
    SELECT b.*
    FROM public.sage_posting_batches b
    WHERE b.id = p_batch_id
  ), rows AS (
    SELECT r.*
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
  ), summary AS (
    SELECT jsonb_build_object(
      'included_count', COUNT(*) FILTER (WHERE r.posting_status <> 'excluded'),
      'excluded_count', COUNT(*) FILTER (WHERE r.posting_status = 'excluded'),
      'validated_count', COUNT(*) FILTER (WHERE r.posting_status = 'validated'),
      'posted_count', COUNT(*) FILTER (WHERE r.posting_status = 'posted'),
      'failed_count', COUNT(*) FILTER (WHERE r.posting_status IN ('failed_retryable','failed_terminal')),
      'total_included_value', COALESCE(SUM(r.amount_gbp) FILTER (WHERE r.posting_status <> 'excluded'), 0),
      'customer_sales_count', COUNT(*) FILTER (WHERE r.document_lane = 'customer_sales' AND r.posting_status <> 'excluded'),
      'shipper_ap_count', COUNT(*) FILTER (WHERE r.document_lane = 'shipper_ap' AND r.posting_status <> 'excluded'),
      'posting_disabled_reason', 'Posting disabled until Sage OAuth and dry-run validation are proven.'
    ) AS batch_summary
    FROM rows r
  )
  SELECT
    b.id AS batch_id,
    b.batch_ref,
    b.batch_status,
    b.status,
    b.lane,
    b.row_count,
    b.total_amount_gbp,
    b.success_count,
    b.failed_count,
    b.blocked_count,
    b.notes,
    b.created_at,
    b.created_by_staff_id,
    b.posting_started_at,
    b.posting_completed_at,
    s.batch_summary,
    r.id AS row_id,
    r.snapshot_id,
    r.idempotency_key,
    r.posting_status,
    r.sage_object_type,
    r.sage_object_id,
    r.sage_reference,
    r.payload_hash,
    r.payload_validation_status,
    r.exclusion_reason,
    r.error_code,
    r.error_message,
    r.attempt_count,
    r.posted_at,
    r.last_attempt_at,
    r.source_table,
    r.source_id,
    r.document_lane,
    r.document_type,
    r.order_ref,
    r.reference_text,
    r.counterparty_name,
    r.amount_gbp,
    r.currency_code,
    r.request_payload_json,
    r.response_payload_json,
    r.created_at AS row_created_at
  FROM batch b
  CROSS JOIN summary s
  LEFT JOIN rows r ON true
  ORDER BY
    CASE r.posting_status
      WHEN 'included' THEN 0
      WHEN 'validated' THEN 1
      WHEN 'posting' THEN 2
      WHEN 'failed_retryable' THEN 3
      WHEN 'failed_terminal' THEN 4
      WHEN 'excluded' THEN 5
      WHEN 'posted' THEN 6
      ELSE 9
    END,
    r.document_lane NULLS LAST,
    r.order_ref NULLS LAST,
    r.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
