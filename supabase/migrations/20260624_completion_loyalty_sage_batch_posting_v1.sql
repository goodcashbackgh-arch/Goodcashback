BEGIN;

-- Completion Loyalty Sage Batch Posting v1
-- Adds the batch wrapper around already-materialised completion-loyalty Sage posting groups.
-- No Sage API call is made by this migration.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.completion_loyalty_sage_posting_groups') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_groups'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_steps') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_steps'; END IF;
  IF to_regclass('public.completion_loyalty_sage_posting_step_logs') IS NULL THEN RAISE EXCEPTION 'Missing public.completion_loyalty_sage_posting_step_logs'; END IF;
  IF to_regclass('public.staff') IS NULL THEN RAISE EXCEPTION 'Missing public.staff'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.internal_completion_loyalty_staff_id_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_completion_loyalty_staff_id_v1()'; END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.completion_loyalty_sage_posting_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_ref text NOT NULL UNIQUE,
  batch_type text NOT NULL DEFAULT 'completion_loyalty_applied_settlement',
  status text NOT NULL DEFAULT 'validated',
  validation_status text NOT NULL DEFAULT 'ok_to_post',
  approval_status text NOT NULL DEFAULT 'not_approved',
  approved_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  approved_at timestamptz,
  approved_payload_hash text,
  posting_attempt_count integer NOT NULL DEFAULT 0,
  last_posting_error text,
  row_count integer NOT NULL DEFAULT 0,
  total_amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  notes text,
  created_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  active boolean NOT NULL DEFAULT true,
  CONSTRAINT completion_loyalty_sage_batch_type_chk CHECK (batch_type IN ('completion_loyalty_applied_settlement')),
  CONSTRAINT completion_loyalty_sage_batch_status_chk CHECK (status IN ('draft','validated','blocked','approved','posting_to_sage','partially_posted_needs_review','posted_to_sage','failed_retryable','failed_terminal','cancelled','superseded')),
  CONSTRAINT completion_loyalty_sage_batch_validation_chk CHECK (validation_status IN ('not_validated','ok_to_post','warning_only','stale_reapproval_required','blocked_source_not_ready','blocked_mapping_missing','blocked_target_not_ready')),
  CONSTRAINT completion_loyalty_sage_batch_approval_chk CHECK (approval_status IN ('not_approved','approved','invalidated')),
  CONSTRAINT completion_loyalty_sage_batch_amount_chk CHECK (total_amount_gbp >= 0),
  CONSTRAINT completion_loyalty_sage_batch_row_count_chk CHECK (row_count >= 0)
);

CREATE TABLE IF NOT EXISTS public.completion_loyalty_sage_posting_batch_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.completion_loyalty_sage_posting_batches(id) ON DELETE CASCADE,
  posting_group_id uuid NOT NULL REFERENCES public.completion_loyalty_sage_posting_groups(id) ON DELETE RESTRICT,
  order_funding_event_id uuid,
  amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  item_status text NOT NULL DEFAULT 'batched_validated',
  validation_status text NOT NULL DEFAULT 'ok_to_post',
  posting_status text NOT NULL DEFAULT 'not_posted',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  active boolean NOT NULL DEFAULT true,
  CONSTRAINT completion_loyalty_sage_batch_item_status_chk CHECK (item_status IN ('batched_validated','approved','posting_to_sage','posted_to_sage','partially_posted_needs_review','failed_retryable','failed_terminal','cancelled','superseded')),
  CONSTRAINT completion_loyalty_sage_batch_item_validation_chk CHECK (validation_status IN ('not_validated','ok_to_post','warning_only','stale_reapproval_required','blocked_source_not_ready','blocked_mapping_missing','blocked_target_not_ready')),
  CONSTRAINT completion_loyalty_sage_batch_item_posting_chk CHECK (posting_status IN ('not_posted','posting_to_sage','posted_to_sage','partially_posted_needs_review','failed_retryable','failed_terminal','cancelled','superseded')),
  CONSTRAINT completion_loyalty_sage_batch_item_amount_chk CHECK (amount_gbp >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS completion_loyalty_sage_batch_items_one_active_group_uidx
  ON public.completion_loyalty_sage_posting_batch_items(posting_group_id)
  WHERE active = true AND item_status NOT IN ('cancelled','superseded');

CREATE INDEX IF NOT EXISTS idx_completion_loyalty_sage_batches_status
  ON public.completion_loyalty_sage_posting_batches(batch_type, status, validation_status, approval_status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_completion_loyalty_sage_batch_items_batch
  ON public.completion_loyalty_sage_posting_batch_items(batch_id, item_status, posting_status);

ALTER TABLE public.completion_loyalty_sage_posting_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.completion_loyalty_sage_posting_batch_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS completion_loyalty_sage_batches_staff_select ON public.completion_loyalty_sage_posting_batches;
CREATE POLICY completion_loyalty_sage_batches_staff_select
  ON public.completion_loyalty_sage_posting_batches
  FOR SELECT TO authenticated
  USING (public.is_active_staff());

DROP POLICY IF EXISTS completion_loyalty_sage_batch_items_staff_select ON public.completion_loyalty_sage_posting_batch_items;
CREATE POLICY completion_loyalty_sage_batch_items_staff_select
  ON public.completion_loyalty_sage_posting_batch_items
  FOR SELECT TO authenticated
  USING (public.is_active_staff());

CREATE OR REPLACE FUNCTION public.staff_create_completion_loyalty_sage_batch_v1(
  p_posting_group_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_group_ids uuid[];
  v_group_count integer := 0;
  v_found_count integer := 0;
  v_bad_ref text;
  v_existing_batch_ref text;
  v_staff_id uuid;
  v_batch_id uuid;
  v_batch_ref text;
  v_total_amount numeric(18,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: create loyalty Sage batch requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required to create loyalty Sage batch.'; END IF;

  SELECT array_agg(DISTINCT item) INTO v_group_ids
  FROM unnest(COALESCE(p_posting_group_ids, ARRAY[]::uuid[])) AS item
  WHERE item IS NOT NULL;

  v_group_count := COALESCE(array_length(v_group_ids, 1), 0);
  IF v_group_count = 0 THEN
    RAISE EXCEPTION 'Select at least one locally validated loyalty Sage posting group to batch.';
  END IF;

  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'Active staff record required to create loyalty Sage batch.'; END IF;

  SELECT count(*)::integer INTO v_found_count
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  IF v_found_count <> v_group_count THEN
    RAISE EXCEPTION 'One or more selected loyalty Sage posting groups could not be found.';
  END IF;

  PERFORM 1
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids)
  FOR UPDATE;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids)
    AND NOT (
      g.active = true
      AND g.posting_group_type = 'completion_loyalty_applied_settlement'
      AND g.status IN ('locally_validated','admin_approved')
      AND g.validation_status IN ('ok_to_post','warning_only')
      AND g.blocker IS NULL
      AND g.posted_at IS NULL
    )
  ORDER BY g.created_at DESC
  LIMIT 1;

  IF v_bad_ref IS NOT NULL THEN
    RAISE EXCEPTION 'Selected loyalty Sage group % is not eligible for batching. It must be active, locally validated, unposted and blocker-free.', v_bad_ref;
  END IF;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids)
    AND EXISTS (
      SELECT 1
      FROM public.completion_loyalty_sage_posting_steps s
      WHERE s.posting_group_id = g.id
        AND s.active = true
        AND (s.status = 'posted_to_sage' OR s.sage_object_id IS NOT NULL OR s.posted_at IS NOT NULL)
    )
  LIMIT 1;

  IF v_bad_ref IS NOT NULL THEN
    RAISE EXCEPTION 'Selected loyalty Sage group % already has a posted Sage step and cannot be batched as unposted.', v_bad_ref;
  END IF;

  SELECT b.batch_ref INTO v_existing_batch_ref
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_batches b ON b.id = bi.batch_id
  WHERE bi.posting_group_id = ANY(v_group_ids)
    AND bi.active = true
    AND bi.item_status NOT IN ('cancelled','superseded')
    AND b.active = true
    AND b.status NOT IN ('cancelled','superseded')
  ORDER BY b.created_at DESC
  LIMIT 1;

  IF v_existing_batch_ref IS NOT NULL THEN
    RAISE EXCEPTION 'One or more selected loyalty Sage groups already sit in active batch %.', v_existing_batch_ref;
  END IF;

  SELECT round(COALESCE(sum(g.amount_gbp), 0)::numeric, 2) INTO v_total_amount
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  v_batch_ref := 'CLASB-' || to_char(now(), 'YYYYMMDD-HH24MISS') || '-' || substr(md5(gen_random_uuid()::text), 1, 6);

  INSERT INTO public.completion_loyalty_sage_posting_batches (
    batch_ref,
    batch_type,
    status,
    validation_status,
    approval_status,
    row_count,
    total_amount_gbp,
    notes,
    created_by_staff_id
  ) VALUES (
    v_batch_ref,
    'completion_loyalty_applied_settlement',
    'validated',
    'ok_to_post',
    'not_approved',
    v_group_count,
    v_total_amount,
    NULLIF(p_notes, ''),
    v_staff_id
  ) RETURNING id, batch_ref INTO v_batch_id, v_batch_ref;

  INSERT INTO public.completion_loyalty_sage_posting_batch_items (
    batch_id,
    posting_group_id,
    order_funding_event_id,
    amount_gbp,
    item_status,
    validation_status,
    posting_status
  )
  SELECT
    v_batch_id,
    g.id,
    g.order_funding_event_id,
    g.amount_gbp,
    'batched_validated',
    g.validation_status,
    'not_posted'
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
  SELECT
    g.id,
    'batch_create',
    'Completion-loyalty Sage posting group added to batch.',
    jsonb_build_object('batch_id', v_batch_id, 'batch_ref', v_batch_ref, 'notes', p_notes),
    v_staff_id
  FROM public.completion_loyalty_sage_posting_groups g
  WHERE g.id = ANY(v_group_ids);

  RETURN jsonb_build_object('ok', true, 'batch_id', v_batch_id, 'batch_ref', v_batch_ref, 'row_count', v_group_count, 'total_amount_gbp', v_total_amount);
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_approve_completion_loyalty_sage_batch_v1(
  p_batch_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_batch record;
  v_staff_id uuid;
  v_bad_ref text;
  v_payload_hash text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: approve loyalty Sage batch requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required to approve loyalty Sage batch.'; END IF;

  SELECT public.internal_completion_loyalty_staff_id_v1() INTO v_staff_id;
  IF v_staff_id IS NULL THEN RAISE EXCEPTION 'Active staff record required to approve loyalty Sage batch.'; END IF;

  SELECT * INTO v_batch
  FROM public.completion_loyalty_sage_posting_batches b
  WHERE b.id = p_batch_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Loyalty Sage batch not found: %', p_batch_id; END IF;
  IF v_batch.active IS NOT TRUE OR v_batch.status IN ('cancelled','superseded','posted_to_sage','posting_to_sage') THEN
    RAISE EXCEPTION 'Loyalty Sage batch % cannot be approved from status %.', v_batch.batch_ref, v_batch.status;
  END IF;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true
    AND NOT (
      g.active = true
      AND g.posting_group_type = 'completion_loyalty_applied_settlement'
      AND g.status IN ('locally_validated','admin_approved')
      AND g.validation_status IN ('ok_to_post','warning_only')
      AND g.blocker IS NULL
      AND g.posted_at IS NULL
    )
  ORDER BY g.created_at DESC
  LIMIT 1;

  IF v_bad_ref IS NOT NULL THEN
    RAISE EXCEPTION 'Loyalty Sage batch % cannot be approved because group % is no longer eligible.', v_batch.batch_ref, v_bad_ref;
  END IF;

  SELECT g.posting_group_ref INTO v_bad_ref
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true
    AND EXISTS (
      SELECT 1
      FROM public.completion_loyalty_sage_posting_steps s
      WHERE s.posting_group_id = g.id
        AND s.active = true
        AND (s.status = 'posted_to_sage' OR s.sage_object_id IS NOT NULL OR s.posted_at IS NOT NULL)
    )
  LIMIT 1;

  IF v_bad_ref IS NOT NULL THEN
    RAISE EXCEPTION 'Loyalty Sage batch % cannot be approved because group % already has a posted Sage step.', v_batch.batch_ref, v_bad_ref;
  END IF;

  SELECT md5(COALESCE(string_agg(concat_ws(':', g.id::text, g.payload_fingerprint, g.mapping_fingerprint, g.source_payload_fingerprint), ',' ORDER BY g.id::text), 'empty'))
  INTO v_payload_hash
  FROM public.completion_loyalty_sage_posting_batch_items bi
  JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
  WHERE bi.batch_id = p_batch_id
    AND bi.active = true;

  UPDATE public.completion_loyalty_sage_posting_batches
  SET status = 'approved',
      approval_status = 'approved',
      approved_by_staff_id = v_staff_id,
      approved_at = now(),
      approved_payload_hash = v_payload_hash,
      notes = COALESCE(NULLIF(p_notes, ''), notes),
      updated_at = now()
  WHERE id = p_batch_id;

  UPDATE public.completion_loyalty_sage_posting_batch_items
  SET item_status = 'approved',
      updated_at = now()
  WHERE batch_id = p_batch_id
    AND active = true
    AND item_status = 'batched_validated';

  UPDATE public.completion_loyalty_sage_posting_groups g
  SET status = 'admin_approved',
      approval_status = 'approved',
      approved_by_staff_id = v_staff_id,
      approved_at = now(),
      approved_payload_hash = COALESCE(g.payload_fingerprint, v_payload_hash),
      updated_at = now()
  WHERE g.id IN (
    SELECT bi.posting_group_id
    FROM public.completion_loyalty_sage_posting_batch_items bi
    WHERE bi.batch_id = p_batch_id AND bi.active = true
  )
    AND g.status = 'locally_validated';

  UPDATE public.completion_loyalty_sage_posting_steps s
  SET status = CASE WHEN s.status = 'locally_validated' THEN 'admin_approved' ELSE s.status END,
      updated_at = now()
  WHERE s.posting_group_id IN (
    SELECT bi.posting_group_id
    FROM public.completion_loyalty_sage_posting_batch_items bi
    WHERE bi.batch_id = p_batch_id AND bi.active = true
  )
    AND s.active = true;

  INSERT INTO public.completion_loyalty_sage_posting_step_logs (posting_group_id, log_type, message, payload, created_by_staff_id)
  SELECT
    bi.posting_group_id,
    'batch_approval',
    'Completion-loyalty Sage batch approved.',
    jsonb_build_object('batch_id', p_batch_id, 'batch_ref', v_batch.batch_ref, 'notes', p_notes, 'approved_payload_hash', v_payload_hash),
    v_staff_id
  FROM public.completion_loyalty_sage_posting_batch_items bi
  WHERE bi.batch_id = p_batch_id AND bi.active = true;

  RETURN jsonb_build_object('ok', true, 'batch_id', p_batch_id, 'batch_ref', v_batch.batch_ref, 'status', 'approved');
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_sage_batches_v1(
  p_search text DEFAULT NULL,
  p_status text DEFAULT 'all',
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_type text,
  status text,
  validation_status text,
  approval_status text,
  row_count integer,
  total_amount_gbp numeric,
  postable_count bigint,
  blocked_count bigint,
  posted_count bigint,
  failed_count bigint,
  posting_group_ids jsonb,
  created_at timestamptz,
  approved_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'all'));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty Sage batches require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for loyalty Sage batches.'; END IF;

  RETURN QUERY
  WITH item_rollup AS (
    SELECT
      bi.batch_id,
      count(*) FILTER (WHERE bi.active = true)::bigint AS item_count,
      count(*) FILTER (WHERE bi.active = true AND bi.posting_status IN ('not_posted','failed_retryable'))::bigint AS postable_count,
      count(*) FILTER (WHERE bi.active = true AND bi.validation_status LIKE 'blocked%')::bigint AS blocked_count,
      count(*) FILTER (WHERE bi.active = true AND bi.posting_status = 'posted_to_sage')::bigint AS posted_count,
      count(*) FILTER (WHERE bi.active = true AND bi.posting_status IN ('failed_retryable','failed_terminal'))::bigint AS failed_count,
      COALESCE(jsonb_agg(bi.posting_group_id ORDER BY bi.created_at) FILTER (WHERE bi.active = true), '[]'::jsonb) AS posting_group_ids
    FROM public.completion_loyalty_sage_posting_batch_items bi
    GROUP BY bi.batch_id
  ), base AS (
    SELECT
      b.id,
      b.batch_ref,
      b.batch_type,
      b.status,
      b.validation_status,
      b.approval_status,
      b.row_count,
      b.total_amount_gbp,
      COALESCE(ir.postable_count, 0)::bigint AS postable_count,
      COALESCE(ir.blocked_count, 0)::bigint AS blocked_count,
      COALESCE(ir.posted_count, 0)::bigint AS posted_count,
      COALESCE(ir.failed_count, 0)::bigint AS failed_count,
      COALESCE(ir.posting_group_ids, '[]'::jsonb) AS posting_group_ids,
      b.created_at,
      b.approved_at
    FROM public.completion_loyalty_sage_posting_batches b
    LEFT JOIN item_rollup ir ON ir.batch_id = b.id
    WHERE b.active = true
  ), filtered AS (
    SELECT base.*
    FROM base
    WHERE (v_status = 'all' OR lower(base.status) = v_status OR lower(base.validation_status) = v_status OR lower(base.approval_status) = v_status)
      AND (v_search IS NULL OR lower(concat_ws(' ', base.batch_ref, base.batch_type, base.status, base.validation_status, base.approval_status)) LIKE '%' || v_search || '%')
  )
  SELECT
    f.id,
    f.batch_ref,
    f.batch_type,
    f.status,
    f.validation_status,
    f.approval_status,
    f.row_count,
    f.total_amount_gbp,
    f.postable_count,
    f.blocked_count,
    f.posted_count,
    f.failed_count,
    f.posting_group_ids,
    f.created_at,
    f.approved_at,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.created_at DESC, f.id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_completion_loyalty_sage_batch_detail_v1(p_batch_id uuid)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_type text,
  batch_status text,
  batch_validation_status text,
  batch_approval_status text,
  batch_row_count integer,
  batch_total_amount_gbp numeric,
  batch_created_at timestamptz,
  batch_approved_at timestamptz,
  batch_approved_by_staff_id uuid,
  item_id uuid,
  item_status text,
  item_posting_status text,
  posting_group_id uuid,
  posting_group_ref text,
  order_ref text,
  importer_name text,
  amount_gbp numeric,
  group_status text,
  group_validation_status text,
  group_approval_status text,
  blocker text,
  target_allocation_json jsonb,
  steps_json jsonb,
  created_at timestamptz,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: loyalty Sage batch detail requires auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for loyalty Sage batch detail.'; END IF;

  RETURN QUERY
  WITH step_rollup AS (
    SELECT
      s.posting_group_id,
      COALESCE(jsonb_agg(jsonb_build_object(
        'step_id', s.id,
        'step_type', s.step_type,
        'endpoint_path', s.endpoint_path,
        'method', s.method,
        'status', s.status,
        'sage_reference', s.sage_reference,
        'sage_object_type', s.sage_object_type,
        'sage_object_id', s.sage_object_id,
        'last_error', s.last_error,
        'posted_at', s.posted_at,
        'request_payload_hash', s.request_payload_hash,
        'request_payload', s.request_payload,
        'response_payload', s.response_payload
      ) ORDER BY s.created_at, s.step_type), '[]'::jsonb) AS steps_json
    FROM public.completion_loyalty_sage_posting_steps s
    WHERE s.active = true
    GROUP BY s.posting_group_id
  ), rows AS (
    SELECT
      b.id AS batch_id,
      b.batch_ref,
      b.batch_type,
      b.status AS batch_status,
      b.validation_status AS batch_validation_status,
      b.approval_status AS batch_approval_status,
      b.row_count AS batch_row_count,
      b.total_amount_gbp AS batch_total_amount_gbp,
      b.created_at AS batch_created_at,
      b.approved_at AS batch_approved_at,
      b.approved_by_staff_id AS batch_approved_by_staff_id,
      bi.id AS item_id,
      bi.item_status,
      bi.posting_status AS item_posting_status,
      g.id AS posting_group_id,
      g.posting_group_ref,
      g.order_ref,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), g.request_context_json->>'importer_name', 'Importer/customer')::text AS importer_name,
      g.amount_gbp,
      g.status AS group_status,
      g.validation_status AS group_validation_status,
      g.approval_status AS group_approval_status,
      g.blocker,
      g.target_allocation_json,
      COALESCE(sr.steps_json, '[]'::jsonb) AS steps_json,
      bi.created_at
    FROM public.completion_loyalty_sage_posting_batches b
    JOIN public.completion_loyalty_sage_posting_batch_items bi ON bi.batch_id = b.id AND bi.active = true
    JOIN public.completion_loyalty_sage_posting_groups g ON g.id = bi.posting_group_id
    LEFT JOIN public.importers i ON i.id = g.importer_id
    LEFT JOIN step_rollup sr ON sr.posting_group_id = g.id
    WHERE b.id = p_batch_id
      AND b.active = true
  )
  SELECT
    r.batch_id,
    r.batch_ref,
    r.batch_type,
    r.batch_status,
    r.batch_validation_status,
    r.batch_approval_status,
    r.batch_row_count,
    r.batch_total_amount_gbp,
    r.batch_created_at,
    r.batch_approved_at,
    r.batch_approved_by_staff_id,
    r.item_id,
    r.item_status,
    r.item_posting_status,
    r.posting_group_id,
    r.posting_group_ref,
    r.order_ref,
    r.importer_name,
    r.amount_gbp,
    r.group_status,
    r.group_validation_status,
    r.group_approval_status,
    r.blocker,
    r.target_allocation_json,
    r.steps_json,
    r.created_at,
    count(*) over() AS total_count
  FROM rows r
  ORDER BY r.created_at ASC, r.posting_group_ref ASC;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_create_completion_loyalty_sage_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_create_completion_loyalty_sage_batch_v1(uuid[], text) TO authenticated;
REVOKE ALL ON FUNCTION public.staff_approve_completion_loyalty_sage_batch_v1(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_approve_completion_loyalty_sage_batch_v1(uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.internal_completion_loyalty_sage_batches_v1(text, text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_sage_batches_v1(text, text, integer, integer) TO authenticated;
REVOKE ALL ON FUNCTION public.internal_completion_loyalty_sage_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_completion_loyalty_sage_batch_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
