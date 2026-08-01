-- =============================================================================
-- Goodcashback VAT integrity, final evidence and atomic Sage posting v1
-- Governing authority:
-- docs/governing-pack/architecture/
-- VAT_RETURN_INTEGRITY_EVIDENCE_AND_ATOMIC_SAGE_POSTING_ADDENDUM_v1.md
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- -----------------------------------------------------------------------------
-- Fail closed if reviewed deployed functions have changed.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_actual text;
BEGIN
  IF to_regprocedure('public.staff_apply_vat_timing_source_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: staff_apply_vat_timing_source_lines_v1(uuid)';
  END IF;
  SELECT md5(pg_get_functiondef(to_regprocedure('public.staff_apply_vat_timing_source_lines_v1(uuid)')))
  INTO v_actual;
  IF v_actual <> '9fa97f7d1a09710e10e40ce8629c87c2' THEN
    RAISE EXCEPTION 'Fingerprint mismatch for staff_apply_vat_timing_source_lines_v1(uuid): %', v_actual;
  END IF;

  IF to_regprocedure('public.staff_refresh_vat_return_source_snapshot_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: staff_refresh_vat_return_source_snapshot_v1(uuid)';
  END IF;
  SELECT md5(pg_get_functiondef(to_regprocedure('public.staff_refresh_vat_return_source_snapshot_v1(uuid)')))
  INTO v_actual;
  IF v_actual <> 'ccfcc4c3787da4b0963e751cc698915b' THEN
    RAISE EXCEPTION 'Fingerprint mismatch for staff_refresh_vat_return_source_snapshot_v1(uuid): %', v_actual;
  END IF;

  IF to_regprocedure(
    'public.staff_record_vat_sage_submission_and_lock_v1(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamp with time zone,text,jsonb,numeric,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: staff_record_vat_sage_submission_and_lock_v1';
  END IF;
  SELECT md5(pg_get_functiondef(to_regprocedure(
    'public.staff_record_vat_sage_submission_and_lock_v1(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamp with time zone,text,jsonb,numeric,text)'
  ))) INTO v_actual;
  IF v_actual <> '8a5f7590500abc1b16a8717e9075da45' THEN
    RAISE EXCEPTION 'Fingerprint mismatch for staff_record_vat_sage_submission_and_lock_v1: %', v_actual;
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Export reversal uniqueness. Abort rather than guess if incompatible links exist.
-- -----------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.vat_return_run_lines l
    WHERE l.line_kind = 'box1_export_evidence_reinstatement'
      AND l.status = 'active'
      AND l.prior_vat_return_line_id IS NOT NULL
    GROUP BY l.prior_vat_return_line_id
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate active export reinstatement links already exist; manual review required.';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_vat_export_reinstatement_active_prior_line_v1
ON public.vat_return_run_lines (prior_vat_return_line_id)
WHERE line_kind = 'box1_export_evidence_reinstatement'
  AND status = 'active'
  AND prior_vat_return_line_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- Private immutable final VAT evidence bucket.
-- -----------------------------------------------------------------------------

INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
VALUES (
  'vat-return-evidence',
  'vat-return-evidence',
  false,
  2000000,
  ARRAY[
    'text/csv',
    'text/plain',
    'text/tab-separated-values',
    'application/csv',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/octet-stream'
  ]::text[]
)
ON CONFLICT (id) DO UPDATE
SET
  name = EXCLUDED.name,
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS vat_return_evidence_admin_read_v1 ON storage.objects;
CREATE POLICY vat_return_evidence_admin_read_v1
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'vat-return-evidence'
  AND public.internal_has_vat_return_admin_access_v1()
);

DROP POLICY IF EXISTS vat_return_evidence_admin_upload_v1 ON storage.objects;
CREATE POLICY vat_return_evidence_admin_upload_v1
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'vat-return-evidence'
  AND public.internal_has_vat_return_admin_access_v1()
);

DROP POLICY IF EXISTS vat_return_evidence_admin_cleanup_v1 ON storage.objects;
CREATE POLICY vat_return_evidence_admin_cleanup_v1
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'vat-return-evidence'
  AND public.internal_has_vat_return_admin_access_v1()
);

-- -----------------------------------------------------------------------------
-- Integrity finaliser. Owns only its new Box 6 line kind and blocker codes.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staff_finalize_vat_return_integrity_v1(
  p_vat_return_run_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run public.vat_return_runs%rowtype;
  v_inserted_box6 integer := 0;
  v_linked_exports integer := 0;
  v_blocked_exports integer := 0;
  v_funding_blockers integer := 0;
BEGIN
  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found: %', p_vat_return_run_id;
  END IF;

  IF v_run.locked_at IS NOT NULL
     OR v_run.status IN (
       'admin_approved',
       'sage_adjustment_journals_pending',
       'sage_adjustment_journals_posted',
       'sage_return_review_required',
       'sage_return_submitted',
       'matched_to_sage_locked',
       'mismatch_needs_admin_review',
       'superseded'
     ) THEN
    RAISE EXCEPTION 'VAT return run is not editable for integrity finalisation: %', v_run.status;
  END IF;

  UPDATE public.vat_return_run_lines
  SET
    status = 'superseded',
    adjustment_reason = concat_ws(
      E'\n',
      NULLIF(adjustment_reason, ''),
      'superseded_by_staff_finalize_vat_return_integrity_v1'
    )
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND line_kind = 'box6_uninvoiced_order_funding';

  UPDATE public.vat_return_blockers
  SET
    status = 'resolved',
    resolved_at = now(),
    resolution_notes = 'Rebuilt by staff_finalize_vat_return_integrity_v1.'
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'open'
    AND blocker_code IN (
      'vat_box6_negative_uninvoiced_funding_balance_v1',
      'vat_export_reinstatement_missing_prior_breach_v1',
      'vat_export_reinstatement_ambiguous_prior_breach_v1',
      'vat_export_reinstatement_prior_breach_already_reversed_v1'
    );

  WITH signed_events AS (
    SELECT
      fe.id,
      fe.order_id,
      fe.created_at,
      CASE
        WHEN fe.event_type IN ('funding_contribution', 'credit_applied')
          THEN COALESCE(fe.amount_gbp, 0)
        WHEN fe.event_type = 'funding_reversed'
          THEN -abs(COALESCE(fe.amount_gbp, 0))
        ELSE 0
      END AS signed_amount_gbp
    FROM public.order_funding_events fe
    WHERE fe.event_type IN (
      'funding_contribution',
      'credit_applied',
      'funding_reversed'
    )
      AND fe.created_at::date <= v_run.period_end_date
  ), running AS (
    SELECT
      e.*,
      sum(e.signed_amount_gbp) OVER (
        PARTITION BY e.order_id
        ORDER BY e.created_at, e.id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS running_balance_gbp
    FROM signed_events e
  ), invalid_orders AS (
    SELECT
      order_id,
      min(running_balance_gbp) AS minimum_balance_gbp,
      jsonb_agg(
        jsonb_build_object(
          'funding_event_id', id,
          'created_at', created_at,
          'signed_amount_gbp', signed_amount_gbp,
          'running_balance_gbp', running_balance_gbp
        )
        ORDER BY created_at, id
      ) AS events
    FROM running
    GROUP BY order_id
    HAVING min(running_balance_gbp) < -0.01
  )
  INSERT INTO public.vat_return_blockers (
    vat_return_run_id,
    blocker_code,
    severity,
    owner_role,
    source_table,
    source_id,
    source_ref,
    message,
    required_action,
    status
  )
  SELECT
    p_vat_return_run_id,
    'vat_box6_negative_uninvoiced_funding_balance_v1',
    'blocker',
    'admin',
    'orders',
    i.order_id,
    i.order_id::text,
    format(
      'Qualifying order funding reaches an impossible negative cumulative balance of %s before VAT period end.',
      round(i.minimum_balance_gbp::numeric, 2)
    ),
    'Correct or reclassify the source funding events; no Box 6 repair amount was guessed. Event audit: ' || i.events::text,
    'open'
  FROM invalid_orders i;

  GET DIAGNOSTICS v_funding_blockers = ROW_COUNT;

  WITH invalid_orders AS (
    SELECT DISTINCT b.source_id AS order_id
    FROM public.vat_return_blockers b
    WHERE b.vat_return_run_id = p_vat_return_run_id
      AND b.status = 'open'
      AND b.blocker_code = 'vat_box6_negative_uninvoiced_funding_balance_v1'
  ), qualifying AS (
    SELECT
      fe.*,
      CASE
        WHEN fe.event_type = 'funding_reversed' THEN 'decrease'
        ELSE 'increase'
      END AS line_direction,
      abs(COALESCE(fe.amount_gbp, 0)) AS line_amount_gbp
    FROM public.order_funding_events fe
    WHERE fe.created_at::date BETWEEN v_run.period_start_date AND v_run.period_end_date
      AND fe.event_type IN (
        'funding_contribution',
        'credit_applied',
        'funding_reversed'
      )
      AND abs(COALESCE(fe.amount_gbp, 0)) > 0.01
      AND NOT EXISTS (
        SELECT 1
        FROM invalid_orders i
        WHERE i.order_id = fe.order_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.sales_invoices si
        WHERE si.order_id = fe.order_id
          AND COALESCE(si.sage_status, '') <> 'void'
          AND lower(COALESCE(si.invoice_type, '')) IN ('main', 'supplementary')
          AND COALESCE(si.amount_gbp, 0) > 0
      )
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id,
    line_kind,
    source_table,
    source_id,
    source_ref,
    source_json,
    source_lineage_json,
    box_number,
    direction,
    amount_gbp,
    vat_amount_gbp,
    vat_basis,
    tax_point_date,
    return_period_label,
    natural_sage_covered,
    adjustment_required,
    adjustment_reason,
    status
  )
  SELECT
    p_vat_return_run_id,
    'box6_uninvoiced_order_funding',
    'order_funding_events',
    q.id,
    COALESCE(NULLIF(q.source_ref, ''), 'order_funding_event:' || q.id::text),
    jsonb_build_object(
      'integrity_rule', 'box6_uninvoiced_order_funding_v1',
      'funding_event_id', q.id,
      'order_id', q.order_id,
      'event_type', q.event_type,
      'raw_amount_gbp', q.amount_gbp,
      'direction', q.line_direction,
      'box6_amount_gbp', round(q.line_amount_gbp::numeric, 2),
      'created_at', q.created_at,
      'source_table', q.source_table,
      'source_id', q.source_id,
      'source_entity_type', q.source_entity_type,
      'source_entity_id', q.source_entity_id
    ),
    jsonb_build_object(
      'lineage', 'order_funding_events -> order -> vat_return_run_lines',
      'order_id', q.order_id,
      'funding_event_id', q.id
    ),
    6,
    q.line_direction,
    round(q.line_amount_gbp::numeric, 2),
    0,
    'order_funding_event_without_nonvoid_sales_invoice',
    q.created_at::date,
    v_run.return_period_label,
    false,
    true,
    'Box 6 consideration event has no non-void positive main or supplementary sales invoice.',
    'active'
  FROM qualifying q;

  GET DIAGNOSTICS v_inserted_box6 = ROW_COUNT;

  -- Classify unsupported reinstatements before assigning any prior-line links.
  -- This prevents two current rows from racing the partial unique index.
  WITH reinstatements AS (
    SELECT r.*
    FROM public.vat_return_run_lines r
    WHERE r.vat_return_run_id = p_vat_return_run_id
      AND r.status = 'active'
      AND r.line_kind = 'box1_export_evidence_reinstatement'
  ), candidate_arrays AS (
    SELECT
      r.id,
      r.source_id,
      r.source_ref,
      count(b.id) FILTER (WHERE br.id IS NOT NULL) AS candidate_count,
      array_agg(b.id ORDER BY b.id) FILTER (WHERE br.id IS NOT NULL) AS candidate_ids
    FROM reinstatements r
    LEFT JOIN public.vat_return_run_lines b
      ON b.line_kind = 'box1_export_evidence_breach'
     AND b.status = 'active'
     AND b.source_table = r.source_table
     AND b.source_id IS NOT DISTINCT FROM r.source_id
     AND abs(COALESCE(b.amount_gbp, 0) - COALESCE(r.amount_gbp, 0)) <= 0.01
    LEFT JOIN public.vat_return_runs br
      ON br.id = b.vat_return_run_id
     AND br.status = 'matched_to_sage_locked'
     AND br.locked_at IS NOT NULL
     AND br.period_end_date < r.tax_point_date
    GROUP BY r.id, r.source_id, r.source_ref
  ), assessed AS (
    SELECT
      c.*,
      c.candidate_ids[1] AS candidate_id
    FROM candidate_arrays c
  ), claimed AS (
    SELECT
      a.*,
      count(*) FILTER (WHERE a.candidate_count = 1)
        OVER (PARTITION BY a.candidate_id) AS current_candidate_claim_count
    FROM assessed a
  ), invalid AS (
    SELECT
      c.*,
      CASE
        WHEN c.candidate_count = 0 THEN 'vat_export_reinstatement_missing_prior_breach_v1'
        WHEN c.candidate_count > 1 THEN 'vat_export_reinstatement_ambiguous_prior_breach_v1'
        ELSE 'vat_export_reinstatement_prior_breach_already_reversed_v1'
      END AS blocker_code
    FROM claimed c
    WHERE c.candidate_count <> 1
       OR c.current_candidate_claim_count <> 1
       OR EXISTS (
         SELECT 1
         FROM public.vat_return_run_lines other
         WHERE other.line_kind = 'box1_export_evidence_reinstatement'
           AND other.status = 'active'
           AND other.id <> c.id
           AND other.prior_vat_return_line_id = c.candidate_id
       )
  ), superseded AS (
    UPDATE public.vat_return_run_lines r
    SET
      status = 'superseded',
      prior_vat_return_line_id = NULL,
      adjustment_reason = concat_ws(
        E'\n',
        NULLIF(r.adjustment_reason, ''),
        'superseded_by_export_reinstatement_integrity_v1'
      )
    FROM invalid i
    WHERE r.id = i.id
    RETURNING i.*
  )
  INSERT INTO public.vat_return_blockers (
    vat_return_run_id,
    blocker_code,
    severity,
    owner_role,
    source_table,
    source_id,
    source_ref,
    message,
    required_action,
    status
  )
  SELECT
    p_vat_return_run_id,
    s.blocker_code,
    'blocker',
    'admin',
    'sales_invoices',
    s.source_id,
    COALESCE(s.source_ref, s.source_id::text),
    CASE s.blocker_code
      WHEN 'vat_export_reinstatement_missing_prior_breach_v1'
        THEN 'Late export evidence has no exact earlier active breach in a locked VAT return.'
      WHEN 'vat_export_reinstatement_ambiguous_prior_breach_v1'
        THEN format('Late export evidence matches %s earlier locked breach lines.', s.candidate_count)
      ELSE 'The exact earlier export breach is already claimed, or multiple current reinstatements claim the same breach.'
    END,
    'Use the existing VAT correction/review route. No Box 1 decrease was retained.',
    'open'
  FROM superseded s;

  GET DIAGNOSTICS v_blocked_exports = ROW_COUNT;

  -- Only uniquely supported active rows remain. Link them after all conflicts
  -- have been superseded so the unique index cannot be raced by this statement.
  WITH candidates AS (
    SELECT
      r.id AS reinstatement_id,
      count(b.id) FILTER (WHERE br.id IS NOT NULL) AS candidate_count,
      (array_agg(b.id ORDER BY b.id) FILTER (WHERE br.id IS NOT NULL))[1] AS candidate_id
    FROM public.vat_return_run_lines r
    LEFT JOIN public.vat_return_run_lines b
      ON b.line_kind = 'box1_export_evidence_breach'
     AND b.status = 'active'
     AND b.source_table = r.source_table
     AND b.source_id IS NOT DISTINCT FROM r.source_id
     AND abs(COALESCE(b.amount_gbp, 0) - COALESCE(r.amount_gbp, 0)) <= 0.01
    LEFT JOIN public.vat_return_runs br
      ON br.id = b.vat_return_run_id
     AND br.status = 'matched_to_sage_locked'
     AND br.locked_at IS NOT NULL
     AND br.period_end_date < r.tax_point_date
    WHERE r.vat_return_run_id = p_vat_return_run_id
      AND r.status = 'active'
      AND r.line_kind = 'box1_export_evidence_reinstatement'
    GROUP BY r.id
  ), eligible AS (
    SELECT c.*
    FROM candidates c
    WHERE c.candidate_count = 1
      AND NOT EXISTS (
        SELECT 1
        FROM public.vat_return_run_lines other
        WHERE other.line_kind = 'box1_export_evidence_reinstatement'
          AND other.status = 'active'
          AND other.id <> c.reinstatement_id
          AND other.prior_vat_return_line_id = c.candidate_id
      )
  )
  UPDATE public.vat_return_run_lines r
  SET prior_vat_return_line_id = e.candidate_id
  FROM eligible e
  WHERE r.id = e.reinstatement_id
    AND r.prior_vat_return_line_id IS DISTINCT FROM e.candidate_id;

  GET DIAGNOSTICS v_linked_exports = ROW_COUNT;

  WITH sums AS (
    SELECT
      COALESCE(sum(CASE WHEN box_number = 1 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 1 THEN amount_gbp ELSE 0 END), 0) AS box1,
      COALESCE(sum(CASE WHEN box_number = 2 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 2 THEN amount_gbp ELSE 0 END), 0) AS box2,
      COALESCE(sum(CASE WHEN box_number = 4 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 4 THEN amount_gbp ELSE 0 END), 0) AS box4,
      COALESCE(sum(CASE WHEN box_number = 6 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 6 THEN amount_gbp ELSE 0 END), 0) AS box6,
      COALESCE(sum(CASE WHEN box_number = 7 AND direction = 'decrease' THEN -amount_gbp WHEN box_number = 7 THEN amount_gbp ELSE 0 END), 0) AS box7
    FROM public.vat_return_run_lines
    WHERE vat_return_run_id = p_vat_return_run_id
      AND status = 'active'
  )
  UPDATE public.vat_return_runs r
  SET
    expected_box1_gbp = round(s.box1::numeric, 2),
    expected_box2_gbp = round(s.box2::numeric, 2),
    expected_box3_gbp = round((s.box1 + s.box2)::numeric, 2),
    expected_box4_gbp = round(s.box4::numeric, 2),
    expected_box5_gbp = round(((s.box1 + s.box2) - s.box4)::numeric, 2),
    expected_box6_gbp = round(s.box6::numeric, 2),
    expected_box7_gbp = round(s.box7::numeric, 2),
    expected_box8_gbp = COALESCE(r.expected_box8_gbp, 0),
    expected_box9_gbp = COALESCE(r.expected_box9_gbp, 0),
    source_counts_json = COALESCE(r.source_counts_json, '{}'::jsonb) || jsonb_build_object(
      'vat_integrity_finaliser_v1',
      jsonb_build_object(
        'applied_at', now(),
        'box6_uninvoiced_lines', v_inserted_box6,
        'export_links_updated', v_linked_exports,
        'export_reinstatements_blocked', v_blocked_exports,
        'funding_integrity_blockers', v_funding_blockers
      )
    ),
    updated_at = now()
  FROM sums s
  WHERE r.id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'box6_uninvoiced_lines', v_inserted_box6,
    'export_links_updated', v_linked_exports,
    'export_reinstatements_blocked', v_blocked_exports,
    'funding_integrity_blockers', v_funding_blockers
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_refresh_vat_return_source_snapshot_v2(
  p_vat_return_run_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_base jsonb;
  v_integrity jsonb;
BEGIN
  IF NOT public.internal_has_vat_return_admin_access_v1() THEN
    RAISE EXCEPTION 'Admin-only VAT source refresh action.';
  END IF;

  v_base := public.staff_refresh_vat_return_source_snapshot_v1(p_vat_return_run_id);
  v_integrity := public.staff_finalize_vat_return_integrity_v1(p_vat_return_run_id);

  RETURN COALESCE(v_base, '{}'::jsonb)
    || jsonb_build_object('vat_integrity_finaliser_v1', v_integrity);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_record_vat_sage_submission_and_lock_v2(
  p_vat_return_run_id uuid,
  p_sage_return_reference text,
  p_sage_submitted_box1_gbp numeric,
  p_sage_submitted_box2_gbp numeric,
  p_sage_submitted_box3_gbp numeric,
  p_sage_submitted_box4_gbp numeric,
  p_sage_submitted_box5_gbp numeric,
  p_sage_submitted_box6_gbp numeric,
  p_sage_submitted_box7_gbp numeric,
  p_sage_submitted_box8_gbp numeric DEFAULT 0,
  p_sage_submitted_box9_gbp numeric DEFAULT 0,
  p_sage_submission_timestamp timestamptz DEFAULT now(),
  p_evidence_url text DEFAULT NULL,
  p_evidence_json jsonb DEFAULT '{}'::jsonb,
  p_tolerance_gbp numeric DEFAULT 0.01,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage, pg_temp
AS $$
DECLARE
  v_bucket text := NULLIF(p_evidence_json->>'storage_bucket', '');
  v_path text := NULLIF(p_evidence_json->>'storage_object_path', '');
  v_sha256 text := lower(NULLIF(p_evidence_json->>'sha256', ''));
  v_filename text := NULLIF(p_evidence_json->>'original_filename', '');
  v_size bigint;
BEGIN
  IF NOT public.internal_has_vat_return_admin_access_v1() THEN
    RAISE EXCEPTION 'Admin-only VAT submission match/lock action.';
  END IF;

  IF COALESCE(p_evidence_json->>'upload_purpose', '') <> 'final_submission_evidence' THEN
    RAISE EXCEPTION 'Final Sage VAT lock requires final_submission_evidence purpose.';
  END IF;

  IF v_bucket IS DISTINCT FROM 'vat-return-evidence' THEN
    RAISE EXCEPTION 'Final Sage VAT evidence must use the private vat-return-evidence bucket.';
  END IF;

  IF v_path IS NULL OR v_sha256 IS NULL OR v_filename IS NULL THEN
    RAISE EXCEPTION 'Final Sage VAT evidence requires object path, original filename and SHA-256.';
  END IF;

  BEGIN
    v_size := (p_evidence_json->>'size_bytes')::bigint;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Final Sage VAT evidence requires a valid positive size_bytes value.';
  END;

  IF v_size <= 0 THEN
    RAISE EXCEPTION 'Final Sage VAT evidence requires a positive size_bytes value.';
  END IF;

  IF v_path !~ ('^' || p_vat_return_run_id::text || '/final-submission/[0-9a-f]{64}\.[a-z0-9]+$')
     OR position(v_sha256 in lower(v_path)) = 0 THEN
    RAISE EXCEPTION 'Final Sage VAT evidence path does not match the VAT run and SHA-256.';
  END IF;

  IF p_evidence_url IS DISTINCT FROM ('storage://vat-return-evidence/' || v_path) THEN
    RAISE EXCEPTION 'Final Sage VAT evidence_url does not match the stored object identity.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.objects o
    WHERE o.bucket_id = 'vat-return-evidence'
      AND o.name = v_path
  ) THEN
    RAISE EXCEPTION 'Final Sage VAT evidence object does not exist in private storage.';
  END IF;

  RETURN public.staff_record_vat_sage_submission_and_lock_v1(
    p_vat_return_run_id,
    p_sage_return_reference,
    p_sage_submitted_box1_gbp,
    p_sage_submitted_box2_gbp,
    p_sage_submitted_box3_gbp,
    p_sage_submitted_box4_gbp,
    p_sage_submitted_box5_gbp,
    p_sage_submitted_box6_gbp,
    p_sage_submitted_box7_gbp,
    p_sage_submitted_box8_gbp,
    p_sage_submitted_box9_gbp,
    p_sage_submission_timestamp,
    p_evidence_url,
    p_evidence_json,
    p_tolerance_gbp,
    p_notes
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_claim_vat_adjustment_journal_post_v1(
  p_vat_return_adjustment_journal_id uuid,
  p_staff_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claimed public.vat_return_adjustment_journals%rowtype;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.id = p_staff_id
      AND s.active = true
      AND s.role_type = 'admin'
  ) THEN
    RAISE EXCEPTION 'Active admin staff identity required for VAT journal posting claim.';
  END IF;

  UPDATE public.vat_return_adjustment_journals j
  SET
    status = 'posting_to_sage',
    retry_count = COALESCE(j.retry_count, 0) + 1,
    last_error = NULL,
    updated_at = now()
  FROM public.vat_return_runs r
  WHERE j.id = p_vat_return_adjustment_journal_id
    AND j.vat_return_run_id = r.id
    AND j.status = 'admin_approved'
    AND NULLIF(btrim(COALESCE(j.sage_journal_id, '')), '') IS NULL
    AND r.locked_at IS NULL
    AND r.status = 'admin_approved'
    AND NOT EXISTS (
      SELECT 1
      FROM public.vat_return_blockers b
      WHERE b.vat_return_run_id = r.id
        AND b.status = 'open'
        AND b.severity = 'blocker'
    )
  RETURNING j.* INTO v_claimed;

  IF v_claimed.id IS NULL THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'journal_id', p_vat_return_adjustment_journal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'claimed', true,
    'journal_id', v_claimed.id,
    'vat_return_run_id', v_claimed.vat_return_run_id,
    'status', v_claimed.status,
    'retry_count', v_claimed.retry_count,
    'idempotency_key', v_claimed.idempotency_key,
    'payload_hash', v_claimed.payload_hash
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_finalize_vat_return_integrity_v1(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_finalize_vat_return_integrity_v1(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v2(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v2(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v2(
  uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamptz,text,jsonb,numeric,text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v2(
  uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamptz,text,jsonb,numeric,text
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.staff_claim_vat_adjustment_journal_post_v1(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_claim_vat_adjustment_journal_post_v1(uuid,uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.staff_apply_vat_timing_source_lines_v1(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_apply_vat_timing_source_lines_v1(uuid) TO service_role;

REVOKE EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v1(
  uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamptz,text,jsonb,numeric,text
) FROM anon;

COMMENT ON FUNCTION public.staff_finalize_vat_return_integrity_v1(uuid) IS
'Addendum-governed VAT integrity finaliser: owns only uninvoiced funding Box 6 lines, exact export-reinstatement linkage, owned blockers and expected-box recalculation for an editable run.';

COMMENT ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v2(uuid) IS
'Additive VAT refresh entrypoint: existing v1 refresh followed by staff_finalize_vat_return_integrity_v1.';

COMMENT ON FUNCTION public.staff_record_vat_sage_submission_and_lock_v2(
  uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,timestamptz,text,jsonb,numeric,text
) IS
'Final Sage VAT evidence lock v2: verifies immutable private storage evidence, then delegates reviewed box comparison and lock semantics to v1.';

COMMENT ON FUNCTION public.staff_claim_vat_adjustment_journal_post_v1(uuid,uuid) IS
'Atomic service-role claim for one approved VAT adjustment journal immediately before Sage request logging and network posting.';

NOTIFY pgrst, 'reload schema';

COMMIT;
