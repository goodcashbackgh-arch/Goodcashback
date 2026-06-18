BEGIN;

-- Allow safe supplier_goods_ap AP re-freeze after local posting failure with no Sage invoice.
-- Scope: replace only the supplier goods AP freeze RPC. No posting. No schema change. No data cleanup.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[], text)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[], text)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_freeze_supplier_goods_ap_sage_batch_v1(
  p_supplier_invoice_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  snapshot_id uuid,
  supplier_invoice_id uuid,
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
    RAISE EXCEPTION 'Unauthenticated user: supplier goods AP freeze requires auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for supplier goods AP freeze.';
  END IF;
  IF p_supplier_invoice_ids IS NULL OR array_length(p_supplier_invoice_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one supplier invoice id is required.';
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
    'supplier_goods_ap_preview_freeze',
    'frozen_pending_posting',
    v_staff_id,
    auth.uid(),
    p_notes,
    'internal_freeze_supplier_goods_ap_sage_batch_v1'
  )
  RETURNING public.sage_posting_batches.id INTO v_batch_id;

  RETURN QUERY
  WITH requested AS (
    SELECT DISTINCT unnest(p_supplier_invoice_ids)::uuid AS supplier_invoice_id
  ), live_rows AS (
    SELECT req.supplier_invoice_id, q.*
    FROM requested req
    LEFT JOIN LATERAL (
      SELECT live_q.*
      FROM public.internal_supplier_goods_ap_ready_rows_v1() live_q
      WHERE live_q.source_table = 'supplier_invoices'
        AND live_q.document_lane = 'supplier_goods_ap'
        AND live_q.source_id = req.supplier_invoice_id
      ORDER BY live_q.queue_row_id
      LIMIT 1
    ) q ON true
  ), prepared AS (
    SELECT
      lr.*,
      COALESCE(lr.source_payload->'mapping_snapshot', '{}'::jsonb) AS mapping_snapshot,
      md5(COALESCE((lr.source_payload->'mapping_snapshot')::text, '')) AS mapping_fingerprint,
      jsonb_build_object(
        'source', 'ready_for_sage_queue',
        'document_lane', lr.document_lane,
        'document_type', lr.document_type,
        'source_table', lr.source_table,
        'source_id', lr.source_id,
        'sage_document_type', 'purchase_invoice',
        'supplier_target', COALESCE(lr.source_payload->'supplier_target', '{}'::jsonb),
        'counterparty_name', lr.counterparty_name,
        'amount_gbp', lr.amount_gbp,
        'currency_code', COALESCE(lr.currency_code, 'GBP'),
        'sage_header', COALESCE(lr.source_payload->'sage_header', jsonb_build_object('reference', lr.reference_text, 'notes', lr.notes_text)),
        'resolved_lines', COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb),
        'mapping_snapshot', COALESCE(lr.source_payload->'mapping_snapshot', '{}'::jsonb),
        'source_payload', COALESCE(lr.source_payload, '{}'::jsonb),
        'freeze_control', jsonb_build_object('status', 'approved_frozen_not_posted_to_sage')
      ) AS resolved_payload,
      CASE
        WHEN lr.source_id IS NULL THEN 'ready_queue_row_not_found'
        WHEN COALESCE(lr.readiness_status, '') NOT LIKE 'ready%' THEN COALESCE(lr.blocker, lr.readiness_status, 'not_ready')
        WHEN NULLIF(lr.source_payload #>> '{supplier_target,sage_contact_id}', '') IS NULL THEN 'missing_supplier_goods_ap_sage_supplier_contact'
        WHEN jsonb_array_length(COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb)) = 0 THEN 'missing_supplier_goods_ap_resolved_lines'
        WHEN EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb)) line(value)
          WHERE NULLIF(line.value #>> '{sage_ledger_account_id}', '') IS NULL
        ) THEN 'missing_supplier_goods_ap_ledger_mapping'
        WHEN EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb)) line(value)
          WHERE NULLIF(line.value #>> '{sage_tax_rate_id}', '') IS NULL
        ) THEN 'missing_supplier_goods_ap_tax_mapping'
        ELSE NULL::text
      END AS freeze_blocker
    FROM live_rows lr
  ), keyed AS (
    SELECT
      p.*,
      md5(concat_ws('|',
        COALESCE(p.mapping_fingerprint, ''),
        COALESCE(p.amount_gbp::text, ''),
        COALESCE(p.reference_text, ''),
        COALESCE((p.resolved_payload->'supplier_target')::text, ''),
        COALESCE((p.resolved_payload->'resolved_lines')::text, ''),
        COALESCE((p.resolved_payload->'source_payload')::text, '')
      )) AS payload_fingerprint,
      md5(concat_ws('|',
        'sage_posting_snapshot',
        COALESCE(p.document_lane, ''),
        COALESCE(p.document_type, ''),
        COALESCE(p.source_id::text, ''),
        COALESCE(p.mapping_fingerprint, ''),
        COALESCE((p.resolved_payload->'supplier_target')::text, ''),
        COALESCE((p.resolved_payload->'resolved_lines')::text, '')
      )) AS prepared_idempotency_key
    FROM prepared p
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
      revalidation_status,
      revalidated_at,
      revalidation_notes,
      created_by_staff_id,
      created_by_auth_user_id
    )
    SELECT
      v_batch_id,
      k.source_table,
      k.source_id,
      k.document_lane,
      k.document_type,
      k.order_id,
      k.order_ref,
      k.shipment_batch_id,
      k.booking_ref,
      k.counterparty_name,
      k.amount_gbp,
      COALESCE(k.currency_code, 'GBP'),
      k.reference_text,
      k.notes_text,
      k.sage_status,
      k.resolved_payload,
      COALESCE(k.source_payload, '{}'::jsonb),
      k.mapping_snapshot,
      k.mapping_fingerprint,
      k.payload_fingerprint,
      k.prepared_idempotency_key,
      'approved_frozen',
      v_staff_id,
      auth.uid(),
      now(),
      'ok_to_post',
      now(),
      NULL::text,
      v_staff_id,
      auth.uid()
    FROM keyed k
    WHERE k.freeze_blocker IS NULL
    ON CONFLICT (idempotency_key) DO UPDATE
      SET batch_id = EXCLUDED.batch_id,
          active = true,
          approval_status = 'approved_frozen',
          revalidation_status = 'ok_to_post',
          revalidated_at = now(),
          revalidation_notes = NULL,
          sage_posting_status = 'not_posted',
          sage_invoice_id = NULL,
          sage_posted_at = NULL,
          last_posting_error = NULL
      WHERE (
        public.sage_posting_snapshots.sage_posting_status = 'not_posted'
        OR (
          public.sage_posting_snapshots.sage_posting_status = 'posting_failed'
          AND public.sage_posting_snapshots.sage_invoice_id IS NULL
        )
      )
    RETURNING
      public.sage_posting_snapshots.id,
      public.sage_posting_snapshots.source_id,
      public.sage_posting_snapshots.order_ref,
      public.sage_posting_snapshots.amount_gbp,
      public.sage_posting_snapshots.idempotency_key
  )
  SELECT
    v_batch_id AS batch_id,
    i.id AS snapshot_id,
    i.source_id AS supplier_invoice_id,
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
    k.supplier_invoice_id,
    k.order_ref,
    k.amount_gbp,
    'not_frozen'::text AS freeze_status,
    COALESCE(k.freeze_blocker, 'not_ready') AS blocker,
    k.prepared_idempotency_key AS idempotency_key
  FROM keyed k
  WHERE k.freeze_blocker IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_supplier_goods_ap_sage_batch_v1(uuid[], text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
