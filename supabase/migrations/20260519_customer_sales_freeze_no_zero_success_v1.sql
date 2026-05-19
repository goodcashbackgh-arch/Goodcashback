BEGIN;

-- Customer sales freeze hardening.
--
-- Problem:
--   The freeze RPC could create an empty local preview batch and return zero rows
--   if the requested sales invoice id did not resolve through the current customer
--   sales payload resolver. The UI then showed a false success such as:
--     "frozen and revalidated 0 row(s)".
--
-- Fix:
--   1. Do not create a local freeze batch unless at least one requested customer
--      sales invoice resolves as ready_for_sage_posting_preview.
--   2. Return one not_frozen diagnostic row for every requested id that is not
--      ready, including resolver_returned_no_row_for_sales_invoice_id.
--   3. Preserve the existing idempotent upsert behaviour for ready rows.
--
-- No Sage API call. No source invoice deletion. No posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
  v_ready_count integer := 0;
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

  WITH requested AS (
    SELECT DISTINCT unnest(p_sales_invoice_ids)::uuid AS requested_sales_invoice_id
  ), resolved AS (
    SELECT req.requested_sales_invoice_id, r.sales_invoice_id, r.payload_status
    FROM requested req
    LEFT JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(req.requested_sales_invoice_id) r ON true
  )
  SELECT COUNT(*)::integer
  INTO v_ready_count
  FROM resolved r
  WHERE r.sales_invoice_id IS NOT NULL
    AND r.payload_status = 'ready_for_sage_posting_preview';

  IF v_ready_count > 0 THEN
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
    RETURNING public.sage_posting_batches.id INTO v_batch_id;
  END IF;

  RETURN QUERY
  WITH requested AS (
    SELECT DISTINCT unnest(p_sales_invoice_ids)::uuid AS requested_sales_invoice_id
  ), resolved AS (
    SELECT req.requested_sales_invoice_id, r.*
    FROM requested req
    LEFT JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(req.requested_sales_invoice_id) r ON true
  ), prepared AS (
    SELECT
      r.*,
      CASE
        WHEN r.sales_invoice_id IS NULL THEN NULL::text
        ELSE public.internal_customer_sales_payload_fingerprint_v1(r.resolved_payload, r.mapping_semantic_fingerprint, r.amount_gbp, r.reference_text)
      END AS payload_fingerprint,
      CASE
        WHEN r.sales_invoice_id IS NULL THEN NULL::text
        ELSE md5(concat_ws('|',
          'sage_posting_snapshot',
          r.document_lane,
          r.document_type,
          r.sales_invoice_id::text,
          r.mapping_semantic_fingerprint,
          public.internal_customer_sales_payload_fingerprint_v1(r.resolved_payload, r.mapping_semantic_fingerprint, r.amount_gbp, r.reference_text)
        ))
      END AS prepared_idempotency_key
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
    WHERE v_batch_id IS NOT NULL
      AND p.sales_invoice_id IS NOT NULL
      AND p.payload_status = 'ready_for_sage_posting_preview'
    ON CONFLICT ON CONSTRAINT sage_posting_snapshots_idempotency_key_key DO UPDATE
      SET batch_id = EXCLUDED.batch_id,
          active = true,
          approval_status = 'approved_frozen',
          revalidation_status = 'not_revalidated',
          revalidated_at = NULL,
          revalidation_notes = NULL
      WHERE public.sage_posting_snapshots.sage_posting_status = 'not_posted'
    RETURNING
      public.sage_posting_snapshots.id AS inserted_snapshot_id,
      public.sage_posting_snapshots.source_id AS inserted_sales_invoice_id,
      public.sage_posting_snapshots.order_ref AS inserted_order_ref,
      public.sage_posting_snapshots.amount_gbp AS inserted_amount_gbp,
      public.sage_posting_snapshots.idempotency_key AS inserted_idempotency_key
  )
  SELECT
    v_batch_id AS batch_id,
    i.inserted_snapshot_id AS snapshot_id,
    i.inserted_sales_invoice_id AS sales_invoice_id,
    i.inserted_order_ref AS order_ref,
    i.inserted_amount_gbp AS amount_gbp,
    'frozen'::text AS freeze_status,
    NULL::text AS blocker,
    i.inserted_idempotency_key AS idempotency_key
  FROM inserted i
  UNION ALL
  SELECT
    v_batch_id AS batch_id,
    NULL::uuid AS snapshot_id,
    COALESCE(p.sales_invoice_id, p.requested_sales_invoice_id) AS sales_invoice_id,
    p.order_ref,
    p.amount_gbp,
    'not_frozen'::text AS freeze_status,
    CASE
      WHEN p.sales_invoice_id IS NULL THEN 'resolver_returned_no_row_for_sales_invoice_id'
      ELSE COALESCE(p.blocker, p.payload_status, 'not_ready')
    END AS blocker,
    p.prepared_idempotency_key AS idempotency_key
  FROM prepared p
  WHERE p.sales_invoice_id IS NULL
     OR COALESCE(p.payload_status, '') <> 'ready_for_sage_posting_preview';
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_customer_sales_sage_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_customer_sales_sage_batch_v1(uuid[], text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
