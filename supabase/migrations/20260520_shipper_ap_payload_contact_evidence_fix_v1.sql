BEGIN;

-- Shipper AP purchase-invoice payload fix v1.
-- Adds missing shipper Sage supplier contact and shipping document source evidence to shipper AP payloads.
-- No Sage API call. No posted Sage rows/snapshots are touched.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.shipping_documents') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipping_documents';
  END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_party_mappings';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_freeze_shipper_ap_sage_batch_v1(
  p_shipping_document_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  snapshot_id uuid,
  shipping_document_id uuid,
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
    RAISE EXCEPTION 'Unauthenticated user: shipper AP freeze requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for shipper AP freeze.';
  END IF;

  IF p_shipping_document_ids IS NULL OR array_length(p_shipping_document_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one shipping document id is required.';
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
    'shipper_ap_preview_freeze',
    'frozen_pending_posting',
    v_staff_id,
    auth.uid(),
    p_notes,
    'internal_freeze_shipper_ap_sage_batch_v1'
  )
  RETURNING public.sage_posting_batches.id INTO v_batch_id;

  RETURN QUERY
  WITH requested AS (
    SELECT DISTINCT unnest(p_shipping_document_ids)::uuid AS shipping_document_id
  ), live_rows AS (
    SELECT
      req.shipping_document_id,
      q.*,
      sd.file_url::text AS shipping_document_file_url,
      sd.shipper_id AS shipping_document_shipper_id,
      sd.document_ref::text AS shipping_document_ref,
      sd.document_date AS shipping_document_date
    FROM requested req
    LEFT JOIN LATERAL (
      SELECT live_q.*
      FROM public.internal_ready_for_sage_queue_v2() live_q
      WHERE live_q.source_table = 'shipping_documents'
        AND live_q.document_lane = 'shipper_ap'
        AND live_q.source_id = req.shipping_document_id
      ORDER BY live_q.queue_row_id
      LIMIT 1
    ) q ON true
    LEFT JOIN public.shipping_documents sd ON sd.id = req.shipping_document_id
  ), party AS (
    SELECT
      lr.shipping_document_id,
      pm.id AS party_mapping_id,
      pm.sage_contact_id,
      pm.sage_contact_display_name,
      pm.sage_contact_reference,
      pm.sage_contact_type,
      pm.verified_at AS party_verified_at
    FROM live_rows lr
    LEFT JOIN LATERAL (
      SELECT m.*
      FROM public.sage_party_mappings m
      WHERE m.platform_party_type = 'shipper'
        AND m.platform_party_id = lr.shipping_document_shipper_id
        AND m.active = true
      ORDER BY m.verified_at DESC NULLS LAST, m.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
  ), mapping AS (
    SELECT
      COALESCE(
        jsonb_object_agg(
          sm.mapping_code,
          jsonb_build_object(
            'mapping_code', sm.mapping_code,
            'mapping_group', sm.mapping_group,
            'value_kind', sm.value_kind,
            'sage_external_id', sm.sage_external_id,
            'sage_display_name', sm.sage_display_name,
            'configured_at', sm.configured_at,
            'is_active', sm.is_active
          ) ORDER BY sm.mapping_code
        ),
        '{}'::jsonb
      ) AS mapping_snapshot,
      md5(COALESCE(string_agg(concat_ws(':',
        sm.mapping_code,
        COALESCE(sm.sage_external_id, ''),
        COALESCE(sm.sage_display_name, ''),
        COALESCE(sm.configured_at::text, ''),
        COALESCE(sm.is_active::text, '')
      ), '|' ORDER BY sm.mapping_code), '')) AS mapping_fingerprint
    FROM public.sage_mapping_settings sm
    WHERE sm.is_active = true
      AND (
        'shipper_ap_purchase_invoice' = ANY(sm.required_for)
        OR sm.mapping_group = 'shipper_ap'
      )
  ), prepared AS (
    SELECT
      lr.*,
      p.party_mapping_id,
      p.sage_contact_id,
      p.sage_contact_display_name,
      p.sage_contact_reference,
      p.sage_contact_type,
      p.party_verified_at,
      m.mapping_snapshot,
      m.mapping_fingerprint,
      jsonb_build_object(
        'source', 'ready_for_sage_queue',
        'document_lane', lr.document_lane,
        'document_type', lr.document_type,
        'source_table', lr.source_table,
        'source_id', lr.source_id,
        'sage_document_type', 'purchase_invoice',
        'counterparty_name', lr.counterparty_name,
        'amount_gbp', lr.amount_gbp,
        'currency_code', COALESCE(lr.currency_code, 'GBP'),
        'source_evidence', jsonb_build_object(
          'source_table', 'shipping_documents',
          'source_id', lr.source_id,
          'file_url', lr.shipping_document_file_url,
          'status', CASE WHEN NULLIF(lr.shipping_document_file_url, '') IS NULL THEN 'missing_source_evidence_file' ELSE 'source_evidence_available' END
        ),
        'shipper_target', jsonb_build_object(
          'platform_party_type', 'shipper',
          'platform_party_id', lr.shipping_document_shipper_id,
          'display_name', lr.counterparty_name,
          'sage_party_mapping_id', p.party_mapping_id,
          'sage_contact_id', p.sage_contact_id,
          'sage_contact_display_name', p.sage_contact_display_name,
          'sage_contact_reference', p.sage_contact_reference,
          'sage_contact_type', p.sage_contact_type,
          'verified_at', p.party_verified_at
        ),
        'sage_header', jsonb_build_object(
          'contact_id', p.sage_contact_id,
          'sage_contact_id', p.sage_contact_id,
          'date', COALESCE(lr.shipping_document_date::text, lr.source_payload #>> '{shipping_document_date}', lr.source_payload #>> '{document_date}'),
          'invoice_date', COALESCE(lr.shipping_document_date::text, lr.source_payload #>> '{shipping_document_date}', lr.source_payload #>> '{document_date}'),
          'reference', COALESCE(NULLIF(lr.reference_text, ''), NULLIF(lr.shipping_document_ref, ''), lr.source_id::text),
          'notes', lr.notes_text,
          'booking_ref', lr.booking_ref,
          'order_ref', lr.order_ref
        ),
        'resolved_lines', jsonb_build_array(jsonb_build_object(
          'description', concat_ws(' - ', 'Shipper freight/AP charge', NULLIF(lr.booking_ref, ''), NULLIF(lr.reference_text, '')),
          'quantity', 1,
          'unit_price_gbp', lr.amount_gbp,
          'total_line_amount_gbp', lr.amount_gbp,
          'gross_amount_gbp', lr.amount_gbp,
          'ledger_account_role', 'shipper_freight_cost',
          'sage_ledger_account_id', m.mapping_snapshot #>> '{SHIPPER_FREIGHT_COST_LEDGER,sage_external_id}',
          'sage_ledger_account_display', m.mapping_snapshot #>> '{SHIPPER_FREIGHT_COST_LEDGER,sage_display_name}',
          'sage_tax_rate_id', m.mapping_snapshot #>> '{SHIPPER_AP_TAX_RATE_REVIEW,sage_external_id}',
          'sage_tax_rate_display', m.mapping_snapshot #>> '{SHIPPER_AP_TAX_RATE_REVIEW,sage_display_name}'
        )),
        'mapping_snapshot', m.mapping_snapshot,
        'source_payload', COALESCE(lr.source_payload, '{}'::jsonb),
        'freeze_control', jsonb_build_object('status', 'approved_frozen_not_posted_to_sage')
      ) AS resolved_payload,
      CASE
        WHEN lr.source_id IS NULL THEN 'ready_queue_row_not_found'
        WHEN COALESCE(lr.readiness_status, '') NOT LIKE 'ready%' THEN COALESCE(lr.blocker, lr.readiness_status, 'not_ready')
        WHEN NULLIF(p.sage_contact_id, '') IS NULL THEN 'missing_shipper_sage_supplier_contact'
        WHEN NULLIF(lr.shipping_document_file_url, '') IS NULL THEN 'missing_shipping_document_source_file'
        WHEN NULLIF(m.mapping_snapshot #>> '{SHIPPER_FREIGHT_COST_LEDGER,sage_external_id}', '') IS NULL THEN 'missing_shipper_freight_cost_ledger'
        WHEN NULLIF(m.mapping_snapshot #>> '{SHIPPER_AP_TAX_RATE_REVIEW,sage_external_id}', '') IS NULL THEN 'missing_shipper_ap_tax_rate'
        ELSE NULL::text
      END AS freeze_blocker
    FROM live_rows lr
    LEFT JOIN party p ON p.shipping_document_id = lr.shipping_document_id
    CROSS JOIN mapping m
  ), keyed AS (
    SELECT
      p.*,
      md5(concat_ws('|',
        COALESCE(p.mapping_fingerprint, ''),
        COALESCE(p.sage_contact_id, ''),
        COALESCE(p.amount_gbp::text, ''),
        COALESCE(p.reference_text, ''),
        COALESCE((p.resolved_payload->'resolved_lines')::text, ''),
        COALESCE((p.resolved_payload->'source_payload')::text, '')
      )) AS payload_fingerprint,
      md5(concat_ws('|',
        'sage_posting_snapshot',
        COALESCE(p.document_lane, ''),
        COALESCE(p.document_type, ''),
        COALESCE(p.source_id::text, ''),
        COALESCE(p.mapping_fingerprint, ''),
        COALESCE(p.sage_contact_id, ''),
        COALESCE((p.resolved_payload->'resolved_lines')::text, '')
      )) AS prepared_idempotency_key
    FROM prepared p
  ), inserted AS (
    INSERT INTO public.sage_posting_snapshots (
      batch_id, source_table, source_id, document_lane, document_type, order_id, order_ref,
      shipment_batch_id, booking_ref, counterparty_name, amount_gbp, currency_code,
      reference_text, notes_text, sage_status_at_freeze, resolved_payload, commercial_payload,
      mapping_snapshot, mapping_semantic_fingerprint, payload_semantic_fingerprint, idempotency_key,
      approval_status, approved_by_staff_id, approved_by_auth_user_id, approved_at,
      revalidation_status, revalidated_at, revalidation_notes, created_by_staff_id, created_by_auth_user_id
    )
    SELECT
      v_batch_id, k.source_table, k.source_id, k.document_lane, k.document_type, k.order_id, k.order_ref,
      k.shipment_batch_id, k.booking_ref, k.counterparty_name, k.amount_gbp, COALESCE(k.currency_code, 'GBP'),
      k.reference_text, k.notes_text, k.sage_status, k.resolved_payload, COALESCE(k.source_payload, '{}'::jsonb),
      k.mapping_snapshot, k.mapping_fingerprint, k.payload_fingerprint, k.prepared_idempotency_key,
      'approved_frozen', v_staff_id, auth.uid(), now(), 'ok_to_post', now(), NULL::text, v_staff_id, auth.uid()
    FROM keyed k
    WHERE k.freeze_blocker IS NULL
    ON CONFLICT (idempotency_key) DO UPDATE
      SET batch_id = EXCLUDED.batch_id,
          active = true,
          approval_status = 'approved_frozen',
          revalidation_status = 'ok_to_post',
          revalidated_at = now(),
          revalidation_notes = NULL,
          resolved_payload = EXCLUDED.resolved_payload,
          commercial_payload = EXCLUDED.commercial_payload,
          mapping_snapshot = EXCLUDED.mapping_snapshot,
          mapping_semantic_fingerprint = EXCLUDED.mapping_semantic_fingerprint,
          payload_semantic_fingerprint = EXCLUDED.payload_semantic_fingerprint
      WHERE public.sage_posting_snapshots.sage_posting_status = 'not_posted'
    RETURNING id, source_id, order_ref, amount_gbp, idempotency_key
  )
  SELECT v_batch_id, i.id, i.source_id, i.order_ref, i.amount_gbp, 'frozen'::text, NULL::text, i.idempotency_key
  FROM inserted i
  UNION ALL
  SELECT v_batch_id, NULL::uuid, k.shipping_document_id, k.order_ref, k.amount_gbp, 'not_frozen'::text, COALESCE(k.freeze_blocker, 'not_ready'), k.prepared_idempotency_key
  FROM keyed k
  WHERE k.freeze_blocker IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_shipper_ap_sage_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_shipper_ap_sage_batch_v1(uuid[], text) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_sage_posting_batch_detail_v1(
  p_batch_id uuid
)
RETURNS TABLE (
  batch_id uuid, batch_ref text, batch_status text, status text, lane text,
  row_count integer, total_amount_gbp numeric, success_count integer, failed_count integer, blocked_count integer,
  notes text, created_at timestamptz, created_by_staff_id uuid, posting_started_at timestamptz, posting_completed_at timestamptz,
  batch_summary jsonb, row_id uuid, snapshot_id uuid, idempotency_key text, posting_status text, sage_object_type text,
  sage_object_id text, sage_reference text, payload_hash text, payload_validation_status text, exclusion_reason text,
  error_code text, error_message text, attempt_count integer, posted_at timestamptz, last_attempt_at timestamptz,
  source_table text, source_id uuid, document_lane text, document_type text, order_ref text, reference_text text,
  counterparty_name text, amount_gbp numeric, currency_code text, request_payload_json jsonb, response_payload_json jsonb,
  ap_net_amount_gbp numeric, ap_vat_amount_gbp numeric, ap_gross_amount_gbp numeric, ap_vat_rate_summary text,
  ap_vat_control_status text, source_invoice_file_url text, source_evidence_status text, row_created_at timestamptz
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
    SELECT b.* FROM public.sage_posting_batches b WHERE b.id = p_batch_id
  ), rows AS (
    SELECT r.* FROM public.sage_posting_batch_rows r WHERE r.batch_id = p_batch_id
  ), line_calc AS (
    SELECT
      r.id AS row_id,
      COALESCE(SUM(public.internal_sage_jsonb_num_v1(line.value->'net_amount_gbp')), 0)::numeric(18,2) AS ap_net_amount_gbp,
      COALESCE(SUM(public.internal_sage_jsonb_num_v1(line.value->'vat_amount_gbp')), 0)::numeric(18,2) AS ap_vat_amount_gbp,
      COALESCE(SUM(public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp')), 0)::numeric(18,2) AS ap_gross_amount_gbp,
      string_agg(DISTINCT COALESCE(line.value->>'vat_rate_percent', ''), ', ' ORDER BY COALESCE(line.value->>'vat_rate_percent', '')) FILTER (WHERE NULLIF(line.value->>'vat_rate_percent', '') IS NOT NULL) AS ap_vat_rate_summary,
      COUNT(*) FILTER (WHERE line.value ? 'net_amount_gbp' AND line.value ? 'vat_amount_gbp' AND line.value ? 'gross_amount_gbp') AS lines_with_net_vat_gross,
      COUNT(*) AS line_count,
      COUNT(*) FILTER (
        WHERE line.value ? 'net_amount_gbp' AND line.value ? 'vat_amount_gbp' AND line.value ? 'gross_amount_gbp'
          AND abs(round((COALESCE(public.internal_sage_jsonb_num_v1(line.value->'net_amount_gbp'), 0) + COALESCE(public.internal_sage_jsonb_num_v1(line.value->'vat_amount_gbp'), 0))::numeric, 2)
          - round(COALESCE(public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp'), 0)::numeric, 2)) <= 0.01
      ) AS lines_balanced
    FROM rows r
    LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(r.request_payload_json->'resolved_lines') = 'array' THEN r.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) AS line(value) ON true
    GROUP BY r.id
  ), source_evidence AS (
    SELECT r.id AS row_id, COALESCE(si.invoice_pdf_url::text, sd.file_url::text) AS source_file_url
    FROM rows r
    LEFT JOIN public.supplier_invoices si ON r.source_table = 'supplier_invoices' AND si.id = r.source_id
    LEFT JOIN public.shipping_documents sd ON r.source_table = 'shipping_documents' AND sd.id = r.source_id
  ), summary AS (
    SELECT jsonb_build_object(
      'included_count', COUNT(*) FILTER (WHERE r.posting_status <> 'excluded'),
      'excluded_count', COUNT(*) FILTER (WHERE r.posting_status = 'excluded'),
      'validated_count', COUNT(*) FILTER (WHERE r.posting_status = 'validated'),
      'posted_count', COUNT(*) FILTER (WHERE r.posting_status = 'posted'),
      'failed_count', COUNT(*) FILTER (WHERE r.posting_status IN ('failed_retryable','failed_terminal')),
      'total_included_value', COALESCE(SUM(r.amount_gbp) FILTER (WHERE r.posting_status <> 'excluded'), 0),
      'customer_sales_count', COUNT(*) FILTER (WHERE r.document_lane = 'customer_sales' AND r.posting_status <> 'excluded'),
      'supplier_goods_ap_count', COUNT(*) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'),
      'shipper_ap_count', COUNT(*) FILTER (WHERE r.document_lane = 'shipper_ap' AND r.posting_status <> 'excluded'),
      'supplier_goods_ap_net_total_gbp', COALESCE(SUM(lc.ap_net_amount_gbp) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'), 0),
      'supplier_goods_ap_vat_total_gbp', COALESCE(SUM(lc.ap_vat_amount_gbp) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'), 0),
      'supplier_goods_ap_gross_total_gbp', COALESCE(SUM(lc.ap_gross_amount_gbp) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'), 0),
      'posting_disabled_reason', 'Posting disabled until Sage OAuth and dry-run validation are proven.'
    ) AS batch_summary
    FROM rows r LEFT JOIN line_calc lc ON lc.row_id = r.id
  )
  SELECT
    b.id, b.batch_ref, b.batch_status, b.status, b.lane, b.row_count, b.total_amount_gbp, b.success_count, b.failed_count, b.blocked_count,
    b.notes, b.created_at, b.created_by_staff_id, b.posting_started_at, b.posting_completed_at, s.batch_summary,
    r.id, r.snapshot_id, r.idempotency_key, r.posting_status, r.sage_object_type, r.sage_object_id, r.sage_reference, r.payload_hash,
    r.payload_validation_status, r.exclusion_reason, r.error_code, r.error_message, r.attempt_count, r.posted_at, r.last_attempt_at,
    r.source_table, r.source_id, r.document_lane, r.document_type, r.order_ref, r.reference_text, r.counterparty_name, r.amount_gbp,
    r.currency_code, r.request_payload_json, r.response_payload_json,
    lc.ap_net_amount_gbp, lc.ap_vat_amount_gbp, lc.ap_gross_amount_gbp, COALESCE(NULLIF(lc.ap_vat_rate_summary, ''), '—')::text,
    CASE
      WHEN r.document_lane <> 'supplier_goods_ap' THEN 'not_applicable'
      WHEN COALESCE(lc.line_count, 0) = 0 THEN 'missing_resolved_lines'
      WHEN COALESCE(lc.lines_with_net_vat_gross, 0) <> COALESCE(lc.line_count, 0) THEN 'missing_net_vat_gross_fields'
      WHEN COALESCE(lc.lines_balanced, 0) <> COALESCE(lc.line_count, 0) THEN 'net_plus_vat_not_equal_gross'
      WHEN abs(COALESCE(lc.ap_gross_amount_gbp, 0) - COALESCE(r.amount_gbp, 0)) > 0.01 THEN 'gross_total_mismatch'
      ELSE 'ok'
    END::text,
    COALESCE(
      NULLIF(r.request_payload_json #>> '{source_evidence,file_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,supplier_invoice_pdf_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,invoice_pdf_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,document_file_url}', ''),
      NULLIF(se.source_file_url, '')
    )::text,
    CASE
      WHEN r.document_lane NOT IN ('supplier_goods_ap', 'shipper_ap') THEN 'not_applicable'
      WHEN COALESCE(
        NULLIF(r.request_payload_json #>> '{source_evidence,file_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,supplier_invoice_pdf_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,invoice_pdf_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,document_file_url}', ''),
        NULLIF(se.source_file_url, '')
      ) IS NULL THEN 'missing_source_evidence_file'
      ELSE 'source_evidence_available'
    END::text,
    r.created_at
  FROM batch b
  CROSS JOIN summary s
  LEFT JOIN rows r ON true
  LEFT JOIN line_calc lc ON lc.row_id = r.id
  LEFT JOIN source_evidence se ON se.row_id = r.id
  ORDER BY
    CASE r.posting_status WHEN 'included' THEN 0 WHEN 'validated' THEN 1 WHEN 'posting' THEN 2 WHEN 'failed_retryable' THEN 3 WHEN 'failed_terminal' THEN 4 WHEN 'excluded' THEN 5 WHEN 'posted' THEN 6 ELSE 9 END,
    r.document_lane NULLS LAST, r.order_ref NULLS LAST, r.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) TO authenticated;

WITH enrich AS (
  SELECT
    s.id AS snapshot_id,
    s.source_id,
    sd.file_url::text AS file_url,
    sd.shipper_id,
    sd.document_ref::text AS document_ref,
    sd.document_date,
    pm.id AS party_mapping_id,
    pm.sage_contact_id,
    pm.sage_contact_display_name,
    pm.sage_contact_reference,
    pm.sage_contact_type,
    pm.verified_at
  FROM public.sage_posting_snapshots s
  JOIN public.shipping_documents sd ON s.source_table = 'shipping_documents' AND s.source_id = sd.id
  LEFT JOIN LATERAL (
    SELECT m.*
    FROM public.sage_party_mappings m
    WHERE m.platform_party_type = 'shipper'
      AND m.platform_party_id = sd.shipper_id
      AND m.active = true
    ORDER BY m.verified_at DESC NULLS LAST, m.updated_at DESC NULLS LAST
    LIMIT 1
  ) pm ON true
  WHERE s.document_lane = 'shipper_ap'
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
), repaired_snapshots AS (
  UPDATE public.sage_posting_snapshots s
  SET resolved_payload = COALESCE(s.resolved_payload, '{}'::jsonb)
      || jsonb_build_object(
        'source_evidence', jsonb_build_object('source_table', 'shipping_documents', 'source_id', e.source_id, 'file_url', e.file_url, 'status', CASE WHEN NULLIF(e.file_url, '') IS NULL THEN 'missing_source_evidence_file' ELSE 'source_evidence_available' END),
        'shipper_target', jsonb_build_object('platform_party_type', 'shipper', 'platform_party_id', e.shipper_id, 'sage_party_mapping_id', e.party_mapping_id, 'sage_contact_id', e.sage_contact_id, 'sage_contact_display_name', e.sage_contact_display_name, 'sage_contact_reference', e.sage_contact_reference, 'sage_contact_type', e.sage_contact_type, 'verified_at', e.verified_at),
        'sage_header', COALESCE(s.resolved_payload->'sage_header', '{}'::jsonb) || jsonb_build_object('contact_id', e.sage_contact_id, 'sage_contact_id', e.sage_contact_id, 'date', e.document_date::text, 'invoice_date', e.document_date::text, 'reference', COALESCE(NULLIF(s.reference_text, ''), NULLIF(e.document_ref, ''), e.source_id::text))
      ),
      commercial_payload = COALESCE(s.commercial_payload, '{}'::jsonb) || jsonb_build_object('shipper_target_repaired_from_party_mapping', true, 'source_file_repaired_from_shipping_documents', true),
      revalidation_status = CASE WHEN NULLIF(e.sage_contact_id, '') IS NULL THEN s.revalidation_status ELSE 'ok_to_post' END,
      revalidation_notes = CASE WHEN NULLIF(e.sage_contact_id, '') IS NULL THEN COALESCE(NULLIF(s.revalidation_notes, ''), 'Shipper Sage supplier contact mapping still missing') ELSE NULL END,
      revalidated_at = now()
  FROM enrich e
  WHERE s.id = e.snapshot_id
  RETURNING s.id, s.resolved_payload
)
UPDATE public.sage_posting_batch_rows r
SET request_payload_json = rs.resolved_payload,
    payload_validation_status = CASE WHEN r.payload_validation_status = 'dry_run_validated' THEN 'local_validated_pending_sage_dry_run' ELSE r.payload_validation_status END,
    error_code = NULL,
    error_message = NULL
FROM repaired_snapshots rs
WHERE r.snapshot_id = rs.id
  AND r.document_lane = 'shipper_ap'
  AND r.posting_status NOT IN ('posted', 'cancelled');

NOTIFY pgrst, 'reload schema';
COMMIT;
