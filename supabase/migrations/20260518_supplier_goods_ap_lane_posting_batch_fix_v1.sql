BEGIN;

-- Contract v5 runtime correction:
-- supplier_goods_ap must create a real lane-specific posting batch.
-- This replaces only batch creation. No Sage API call. No posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
  v_distinct_lane_count integer;
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
         COALESCE(SUM(c.amount_gbp), 0)::numeric(18,2)
  INTO v_included_count, v_total_amount
  FROM tmp_sage_posting_batch_candidates c
  WHERE c.final_exclusion_reason IS NULL;

  SELECT COUNT(*)::integer
  INTO v_excluded_count
  FROM tmp_sage_posting_batch_candidates c
  WHERE c.final_exclusion_reason IS NOT NULL;

  IF v_included_count = 0 THEN
    RAISE EXCEPTION 'No ready-to-post frozen snapshots matched this filter. Excluded rows: %', COALESCE(v_excluded_count, 0);
  END IF;

  SELECT COUNT(DISTINCT c.document_lane)::integer,
         MIN(c.document_lane)::text
  INTO v_distinct_lane_count, v_batch_lane
  FROM tmp_sage_posting_batch_candidates c
  WHERE c.final_exclusion_reason IS NULL;

  IF COALESCE(v_distinct_lane_count, 0) <> 1 THEN
    RAISE EXCEPTION 'Posting batches must be lane-specific. Select one lane only: customer_sales, supplier_goods_ap, or shipper_ap.';
  END IF;

  IF v_batch_lane NOT IN ('customer_sales', 'supplier_goods_ap', 'shipper_ap') THEN
    RAISE EXCEPTION 'Unsupported posting batch lane: %', COALESCE(v_batch_lane, 'unknown');
  END IF;

  INSERT INTO public.sage_posting_batches AS b (
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
    v_batch_lane,
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
  RETURNING b.id, b.batch_ref INTO v_batch_id, v_batch_ref;

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
      WHEN c.document_lane IN ('supplier_goods_ap', 'shipper_ap') THEN 'purchase_invoice'
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
    v_batch_lane::text,
    v_included_count,
    v_excluded_count,
    v_total_amount,
    ('/internal/accounting-command-centre/batches/' || v_batch_id::text)::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_sage_posting_batch_from_filter_v1(text, text, text, text, boolean, text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_create_sage_posting_batch_from_filter_v1(text, text, text, text, boolean, text, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
