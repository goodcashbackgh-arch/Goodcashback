BEGIN;

-- Sage posting freeze layer v1
-- This is a control layer only. It does not call Sage and does not mark documents posted.
-- Purpose: convert a live resolved preview into an immutable posting snapshot after supervisor/admin approval.

CREATE TABLE IF NOT EXISTS public.sage_posting_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_ref text NOT NULL UNIQUE DEFAULT ('SPB-' || extract(epoch from clock_timestamp())::bigint::text),
  batch_kind text NOT NULL DEFAULT 'preview_freeze',
  batch_status text NOT NULL DEFAULT 'frozen_pending_posting',
  created_by_staff_id uuid NULL REFERENCES public.staff(id),
  created_by_auth_user_id uuid NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  notes text NULL,
  source text NOT NULL DEFAULT 'internal_freeze_customer_sales_sage_batch_v1',
  CONSTRAINT sage_posting_batches_status_chk CHECK (batch_status IN (
    'frozen_pending_posting',
    'partially_posted',
    'posted',
    'voided',
    'superseded'
  ))
);

CREATE TABLE IF NOT EXISTS public.sage_posting_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.sage_posting_batches(id),
  source_table text NOT NULL,
  source_id uuid NOT NULL,
  document_lane text NOT NULL,
  document_type text NOT NULL,
  order_id uuid NULL,
  order_ref text NULL,
  shipment_batch_id uuid NULL,
  booking_ref text NULL,
  counterparty_name text NULL,
  amount_gbp numeric(18,2) NOT NULL,
  currency_code text NOT NULL DEFAULT 'GBP',
  reference_text text NULL,
  notes_text text NULL,
  sage_status_at_freeze text NULL,
  resolved_payload jsonb NOT NULL,
  commercial_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  mapping_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  mapping_semantic_fingerprint text NOT NULL,
  payload_semantic_fingerprint text NOT NULL,
  idempotency_key text NOT NULL UNIQUE,
  approval_status text NOT NULL DEFAULT 'approved_frozen',
  approved_by_staff_id uuid NULL REFERENCES public.staff(id),
  approved_by_auth_user_id uuid NULL,
  approved_at timestamptz NOT NULL DEFAULT now(),
  revalidation_status text NOT NULL DEFAULT 'not_revalidated',
  revalidated_at timestamptz NULL,
  revalidation_notes text NULL,
  sage_posting_status text NOT NULL DEFAULT 'not_posted',
  sage_invoice_id text NULL,
  sage_posted_at timestamptz NULL,
  posting_attempt_count integer NOT NULL DEFAULT 0,
  last_posting_error text NULL,
  active boolean NOT NULL DEFAULT true,
  superseded_by_snapshot_id uuid NULL REFERENCES public.sage_posting_snapshots(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by_staff_id uuid NULL REFERENCES public.staff(id),
  created_by_auth_user_id uuid NULL,
  CONSTRAINT sage_posting_snapshots_approval_chk CHECK (approval_status IN (
    'approved_frozen',
    'superseded',
    'voided'
  )),
  CONSTRAINT sage_posting_snapshots_revalidation_chk CHECK (revalidation_status IN (
    'not_revalidated',
    'ok_to_post',
    'warning_only',
    'stale_reapproval_required',
    'blocked_source_not_ready'
  )),
  CONSTRAINT sage_posting_snapshots_posting_chk CHECK (sage_posting_status IN (
    'not_posted',
    'posting_in_progress',
    'posted',
    'posting_failed',
    'voided'
  ))
);

CREATE INDEX IF NOT EXISTS sage_posting_batches_created_idx
  ON public.sage_posting_batches(created_at DESC);

CREATE INDEX IF NOT EXISTS sage_posting_snapshots_source_idx
  ON public.sage_posting_snapshots(source_table, source_id, active)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS sage_posting_snapshots_batch_idx
  ON public.sage_posting_snapshots(batch_id);

CREATE INDEX IF NOT EXISTS sage_posting_snapshots_status_idx
  ON public.sage_posting_snapshots(sage_posting_status, revalidation_status, approval_status)
  WHERE active = true;

ALTER TABLE public.sage_posting_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sage_posting_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sage_posting_batches_staff_select ON public.sage_posting_batches;
CREATE POLICY sage_posting_batches_staff_select
ON public.sage_posting_batches
FOR SELECT
TO authenticated
USING (public.is_active_staff());

DROP POLICY IF EXISTS sage_posting_snapshots_staff_select ON public.sage_posting_snapshots;
CREATE POLICY sage_posting_snapshots_staff_select
ON public.sage_posting_snapshots
FOR SELECT
TO authenticated
USING (public.is_active_staff());

CREATE OR REPLACE FUNCTION public.internal_current_staff_id_v1()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT s.id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1
$$;

REVOKE ALL ON FUNCTION public.internal_current_staff_id_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_current_staff_id_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_customer_sales_payload_fingerprint_v1(
  p_resolved_payload jsonb,
  p_mapping_semantic_fingerprint text,
  p_amount_gbp numeric,
  p_reference_text text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT md5(concat_ws('|',
    COALESCE(p_mapping_semantic_fingerprint, ''),
    COALESCE(p_amount_gbp::text, ''),
    COALESCE(p_reference_text, ''),
    COALESCE(p_resolved_payload #>> '{sage_header,reference}', ''),
    COALESCE(p_resolved_payload #>> '{sage_header,notes}', ''),
    COALESCE(p_resolved_payload #>> '{tax_resolution,sage_tax_rate_id}', ''),
    COALESCE(p_resolved_payload #>> '{ledger_resolution,sage_ledger_account_id}', ''),
    COALESCE((p_resolved_payload->'resolved_lines')::text, '')
  ))
$$;

CREATE OR REPLACE FUNCTION public.internal_freeze_customer_sales_sage_batch_v1(
  p_sales_invoice_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  snapshot_id uuid,
  sales_invoice_id uuid,
  order_ref text,
  amount_gbp numeric,
  freeze_status text,
  blocker text,
  idempotency_key text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_batch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage freeze requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for Sage freeze.';
  END IF;

  IF p_sales_invoice_ids IS NULL OR array_length(p_sales_invoice_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one sales invoice id is required.';
  END IF;

  SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  INSERT INTO public.sage_posting_batches (
    batch_kind,
    batch_status,
    created_by_staff_id,
    created_by_auth_user_id,
    notes,
    source
  ) VALUES (
    'customer_sales_preview_freeze',
    'frozen_pending_posting',
    v_staff_id,
    auth.uid(),
    p_notes,
    'internal_freeze_customer_sales_sage_batch_v1'
  )
  RETURNING id INTO v_batch_id;

  RETURN QUERY
  WITH requested AS (
    SELECT DISTINCT unnest(p_sales_invoice_ids)::uuid AS sales_invoice_id
  ), resolved AS (
    SELECT r.*
    FROM requested req
    JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(req.sales_invoice_id) r ON true
  ), prepared AS (
    SELECT
      r.*,
      public.internal_customer_sales_payload_fingerprint_v1(r.resolved_payload, r.mapping_semantic_fingerprint, r.amount_gbp, r.reference_text) AS payload_fingerprint,
      md5(concat_ws('|',
        'sage_posting_snapshot',
        r.document_lane,
        r.document_type,
        r.sales_invoice_id::text,
        r.mapping_semantic_fingerprint,
        public.internal_customer_sales_payload_fingerprint_v1(r.resolved_payload, r.mapping_semantic_fingerprint, r.amount_gbp, r.reference_text)
      )) AS prepared_idempotency_key
    FROM resolved r
  ), inserted AS (
    INSERT INTO public.sage_posting_snapshots (
      batch_id,
      source_table,
      source_id,
      document_lane,
      document_type,
      order_id,
      order_ref,
      shipment_batch_id,
      booking_ref,
      counterparty_name,
      amount_gbp,
      currency_code,
      reference_text,
      notes_text,
      sage_status_at_freeze,
      resolved_payload,
      commercial_payload,
      mapping_snapshot,
      mapping_semantic_fingerprint,
      payload_semantic_fingerprint,
      idempotency_key,
      approval_status,
      approved_by_staff_id,
      approved_by_auth_user_id,
      approved_at,
      created_by_staff_id,
      created_by_auth_user_id
    )
    SELECT
      v_batch_id,
      'sales_invoices',
      p.sales_invoice_id,
      p.document_lane,
      p.document_type,
      p.order_id,
      p.order_ref,
      NULLIF(p.resolved_payload #>> '{commercial_payload,draft_control,shipment_batch_id}', '')::uuid,
      p.notes_text,
      p.counterparty_name,
      p.amount_gbp,
      p.currency_code,
      p.reference_text,
      p.notes_text,
      p.sage_status,
      p.resolved_payload,
      p.commercial_payload,
      p.mapping_snapshot,
      p.mapping_semantic_fingerprint,
      p.payload_fingerprint,
      p.prepared_idempotency_key,
      'approved_frozen',
      v_staff_id,
      auth.uid(),
      now(),
      v_staff_id,
      auth.uid()
    FROM prepared p
    WHERE p.payload_status = 'ready_for_sage_posting_preview'
    ON CONFLICT (idempotency_key) DO UPDATE
      SET batch_id = EXCLUDED.batch_id,
          active = true,
          approval_status = 'approved_frozen',
          revalidation_status = 'not_revalidated',
          revalidated_at = NULL,
          revalidation_notes = NULL
      WHERE public.sage_posting_snapshots.sage_posting_status = 'not_posted'
    RETURNING id, source_id, order_ref, amount_gbp, idempotency_key
  )
  SELECT
    v_batch_id AS batch_id,
    i.id AS snapshot_id,
    i.source_id AS sales_invoice_id,
    i.order_ref,
    i.amount_gbp,
    'frozen'::text AS freeze_status,
    NULL::text AS blocker,
    i.idempotency_key
  FROM inserted i
  UNION ALL
  SELECT
    v_batch_id AS batch_id,
    NULL::uuid AS snapshot_id,
    p.sales_invoice_id,
    p.order_ref,
    p.amount_gbp,
    'not_frozen'::text AS freeze_status,
    COALESCE(p.blocker, p.payload_status, 'not_ready') AS blocker,
    p.prepared_idempotency_key AS idempotency_key
  FROM prepared p
  WHERE p.payload_status <> 'ready_for_sage_posting_preview';
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_customer_sales_sage_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_customer_sales_sage_batch_v1(uuid[], text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_revalidate_sage_posting_snapshots_v1(
  p_snapshot_ids uuid[] DEFAULT NULL
)
RETURNS TABLE (
  snapshot_id uuid,
  source_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  amount_gbp numeric,
  previous_revalidation_status text,
  revalidation_status text,
  revalidation_notes text,
  current_payload_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage snapshot revalidation requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for Sage snapshot revalidation.';
  END IF;

  RETURN QUERY
  WITH target AS (
    SELECT s.*
    FROM public.sage_posting_snapshots s
    WHERE s.active = true
      AND s.sage_posting_status = 'not_posted'
      AND (p_snapshot_ids IS NULL OR s.id = ANY(p_snapshot_ids))
  ), resolved AS (
    SELECT
      t.id AS snapshot_id,
      t.source_id,
      t.document_lane,
      t.document_type,
      t.order_ref,
      t.amount_gbp,
      t.revalidation_status AS previous_revalidation_status,
      r.payload_status AS current_payload_status,
      r.mapping_semantic_fingerprint AS current_mapping_fingerprint,
      public.internal_customer_sales_payload_fingerprint_v1(r.resolved_payload, r.mapping_semantic_fingerprint, r.amount_gbp, r.reference_text) AS current_payload_fingerprint,
      t.mapping_semantic_fingerprint AS frozen_mapping_fingerprint,
      t.payload_semantic_fingerprint AS frozen_payload_fingerprint,
      t.id AS target_snapshot_id
    FROM target t
    LEFT JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(t.source_id) r
      ON t.document_lane = 'customer_sales'
     AND t.source_table = 'sales_invoices'
  ), assessed AS (
    SELECT
      r.*,
      CASE
        WHEN r.current_payload_status IS NULL THEN 'blocked_source_not_ready'
        WHEN r.current_payload_status <> 'ready_for_sage_posting_preview' THEN 'blocked_source_not_ready'
        WHEN r.current_mapping_fingerprint <> r.frozen_mapping_fingerprint THEN 'stale_reapproval_required'
        WHEN r.current_payload_fingerprint <> r.frozen_payload_fingerprint THEN 'stale_reapproval_required'
        ELSE 'ok_to_post'
      END::text AS new_revalidation_status,
      CASE
        WHEN r.current_payload_status IS NULL THEN 'resolver_returned_no_current_payload'
        WHEN r.current_payload_status <> 'ready_for_sage_posting_preview' THEN 'current_source_payload_not_ready: ' || r.current_payload_status
        WHEN r.current_mapping_fingerprint <> r.frozen_mapping_fingerprint THEN 'mapping_changed_since_approval'
        WHEN r.current_payload_fingerprint <> r.frozen_payload_fingerprint THEN 'posting_critical_payload_changed_since_approval'
        ELSE NULL::text
      END AS new_revalidation_notes
    FROM resolved r
  ), updated AS (
    UPDATE public.sage_posting_snapshots s
    SET revalidation_status = a.new_revalidation_status,
        revalidated_at = now(),
        revalidation_notes = a.new_revalidation_notes
    FROM assessed a
    WHERE s.id = a.target_snapshot_id
    RETURNING
      s.id,
      s.source_id,
      s.document_lane,
      s.document_type,
      s.order_ref,
      s.amount_gbp,
      a.previous_revalidation_status,
      s.revalidation_status,
      s.revalidation_notes,
      a.current_payload_status
  )
  SELECT
    u.id AS snapshot_id,
    u.source_id,
    u.document_lane,
    u.document_type,
    u.order_ref,
    u.amount_gbp,
    u.previous_revalidation_status,
    u.revalidation_status,
    u.revalidation_notes,
    u.current_payload_status
  FROM updated u;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_revalidate_sage_posting_snapshots_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_revalidate_sage_posting_snapshots_v1(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_sage_posting_snapshot_queue_v1()
RETURNS TABLE (
  snapshot_id uuid,
  batch_id uuid,
  batch_ref text,
  source_table text,
  source_id uuid,
  document_lane text,
  document_type text,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  reference_text text,
  notes_text text,
  approval_status text,
  approved_at timestamptz,
  approved_by_staff_id uuid,
  revalidation_status text,
  revalidated_at timestamptz,
  revalidation_notes text,
  sage_posting_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  idempotency_key text,
  mapping_snapshot jsonb,
  resolved_payload jsonb,
  posting_gate_status text,
  posting_gate_blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage posting snapshot queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for Sage posting snapshot queue.';
  END IF;

  RETURN QUERY
  SELECT
    s.id AS snapshot_id,
    s.batch_id,
    b.batch_ref,
    s.source_table,
    s.source_id,
    s.document_lane,
    s.document_type,
    s.order_id,
    s.order_ref,
    s.shipment_batch_id,
    s.booking_ref,
    s.counterparty_name,
    s.amount_gbp,
    s.currency_code,
    s.reference_text,
    s.notes_text,
    s.approval_status,
    s.approved_at,
    s.approved_by_staff_id,
    s.revalidation_status,
    s.revalidated_at,
    s.revalidation_notes,
    s.sage_posting_status,
    s.sage_invoice_id,
    s.sage_posted_at,
    s.idempotency_key,
    s.mapping_snapshot,
    s.resolved_payload,
    CASE
      WHEN s.approval_status <> 'approved_frozen' THEN 'not_approved'
      WHEN s.sage_posting_status = 'posted' THEN 'posted'
      WHEN s.sage_posting_status <> 'not_posted' THEN s.sage_posting_status
      WHEN s.revalidation_status = 'ok_to_post' THEN 'ready_to_post'
      WHEN s.revalidation_status = 'not_revalidated' THEN 'requires_revalidation'
      ELSE 'blocked_before_posting'
    END::text AS posting_gate_status,
    CASE
      WHEN s.approval_status <> 'approved_frozen' THEN 'snapshot_not_approved'
      WHEN s.sage_posting_status = 'posted' THEN NULL::text
      WHEN s.sage_posting_status <> 'not_posted' THEN s.last_posting_error
      WHEN s.revalidation_status = 'ok_to_post' THEN NULL::text
      WHEN s.revalidation_status = 'not_revalidated' THEN 'snapshot_must_be_revalidated_before_posting'
      ELSE COALESCE(s.revalidation_notes, s.revalidation_status)
    END::text AS posting_gate_blocker
  FROM public.sage_posting_snapshots s
  JOIN public.sage_posting_batches b ON b.id = s.batch_id
  WHERE s.active = true
  ORDER BY
    CASE
      WHEN s.sage_posting_status = 'not_posted' AND s.revalidation_status = 'ok_to_post' THEN 0
      WHEN s.sage_posting_status = 'not_posted' AND s.revalidation_status = 'not_revalidated' THEN 1
      WHEN s.sage_posting_status = 'not_posted' THEN 2
      WHEN s.sage_posting_status = 'posting_failed' THEN 3
      WHEN s.sage_posting_status = 'posted' THEN 4
      ELSE 5
    END,
    s.approved_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_snapshot_queue_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_snapshot_queue_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
