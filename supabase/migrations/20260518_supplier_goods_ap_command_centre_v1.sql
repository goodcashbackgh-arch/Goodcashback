BEGIN;

-- Contract v5 Phase 5-8: bring retailer/supplier goods AP into the same
-- Supervisor/Accounting Command Centre handoff as customer_sales and shipper_ap.
-- No Sage API call. No posting. This only exposes, freezes and dry-run-validates
-- supplier_goods_ap purchase invoice payloads from already-approved supplier invoices.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_line_accounting_coding_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_line_accounting_coding_vw';
  END IF;
  IF to_regclass('public.supplier_invoice_accounting_coding_totals_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_accounting_coding_totals_vw';
  END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sage_party_mappings';
  END IF;
  IF to_regprocedure('public.internal_ready_for_sage_queue_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v1()';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_supplier_goods_ap_ready_rows_v1()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: supplier goods AP readiness requires auth.uid()';
  END IF;
  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for supplier goods AP readiness.';
  END IF;

  RETURN QUERY
  WITH defaults AS (
    SELECT
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'SUPPLIER_GOODS_AP_LEDGER' AND sm.is_active = true) AS default_ledger_id,
      MAX(sm.sage_display_name) FILTER (WHERE sm.mapping_code = 'SUPPLIER_GOODS_AP_LEDGER' AND sm.is_active = true) AS default_ledger_display,
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'SUPPLIER_GOODS_AP_TAX_RATE' AND sm.is_active = true) AS default_tax_rate_id,
      MAX(sm.sage_display_name) FILTER (WHERE sm.mapping_code = 'SUPPLIER_GOODS_AP_TAX_RATE' AND sm.is_active = true) AS default_tax_rate_display,
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
        ) FILTER (WHERE sm.mapping_group = 'supplier_goods_ap' OR 'supplier_goods_ap_purchase_invoice' = ANY(sm.required_for)),
        '{}'::jsonb
      ) AS mapping_snapshot
    FROM public.sage_mapping_settings sm
  ), base AS (
    SELECT
      si.id AS supplier_invoice_id,
      si.order_id,
      o.order_ref::text AS order_ref,
      o.retailer_id,
      r.name::text AS retailer_name,
      COALESCE(si.ocr_invoice_ref, si.invoice_ref, si.id::text)::text AS invoice_ref,
      si.review_status::text AS review_status,
      COALESCE(si.is_current_for_order, false) AS is_current_for_order,
      COALESCE(si.blocked_from_sage_yn, false) AS blocked_from_sage_yn,
      si.ocr_invoice_total_gbp::numeric(18,2) AS ocr_invoice_total_gbp,
      t.accepted_invoice_gross_gbp::numeric(18,2) AS accepted_invoice_gross_gbp,
      t.total_coded_net_gbp::numeric(18,2) AS total_coded_net_gbp,
      t.total_coded_vat_gbp::numeric(18,2) AS total_coded_vat_gbp,
      t.total_coded_gross_gbp::numeric(18,2) AS total_coded_gross_gbp,
      t.progressed_line_count,
      t.coded_line_count,
      t.all_progressed_lines_coded_yn,
      COALESCE(t.net_reconciled_to_invoice_yn, true) AS net_reconciled_to_invoice_yn,
      COALESCE(t.vat_reconciled_to_invoice_yn, true) AS vat_reconciled_to_invoice_yn,
      t.gross_reconciled_to_invoice_yn,
      t.net_variance_gbp,
      t.vat_variance_gbp,
      t.gross_variance_gbp,
      pm.id AS party_mapping_id,
      pm.sage_contact_id,
      pm.sage_contact_display_name,
      pm.sage_contact_reference,
      pm.sage_contact_type,
      pm.verified_at AS party_verified_at
    FROM public.supplier_invoices si
    JOIN public.orders o ON o.id = si.order_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    LEFT JOIN public.supplier_invoice_accounting_coding_totals_vw t ON t.supplier_invoice_id = si.id
    LEFT JOIN LATERAL (
      SELECT m.*
      FROM public.sage_party_mappings m
      WHERE m.platform_party_type = 'retailer_supplier'
        AND m.platform_party_id = o.retailer_id
        AND m.active = true
      ORDER BY m.verified_at DESC NULLS LAST, m.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    WHERE si.review_status IN ('approved_current', 'ref_corrected_approved')
       OR si.is_current_for_order = true
  ), source_lines AS (
    SELECT
      v.supplier_invoice_id,
      v.supplier_invoice_line_id AS source_line_id,
      COALESCE(NULLIF(v.posting_description, ''), NULLIF(v.source_description, ''), 'Supplier goods line')::text AS description,
      COALESCE(v.qty, 1)::numeric AS quantity,
      COALESCE(v.net_amount_gbp, 0)::numeric(18,2) AS net_amount_gbp,
      COALESCE(v.vat_amount_gbp, 0)::numeric(18,2) AS vat_amount_gbp,
      COALESCE(v.gross_amount_gbp, v.approved_gross_amount_gbp, 0)::numeric(18,2) AS gross_amount_gbp,
      NULLIF(trim(COALESCE(v.sage_ledger_account_id, '')), '') AS line_ledger_id,
      NULLIF(trim(COALESCE(v.nominal_code, '')), '') AS nominal_code,
      NULLIF(trim(COALESCE(v.tax_rate_id, '')), '') AS line_tax_rate_id,
      v.tax_rate_label,
      COALESCE(v.vat_rate_percent, 0)::numeric(7,4) AS vat_rate_percent,
      v.line_order::integer AS sort_order,
      'supplier_invoice_line'::text AS line_kind
    FROM public.supplier_invoice_line_accounting_coding_vw v
    WHERE lower(trim(COALESCE(v.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
      AND COALESCE(v.coded_yn, false) = true
  ), adjustment_lines AS (
    SELECT
      a.supplier_invoice_id,
      a.id AS source_line_id,
      a.description::text AS description,
      1::numeric AS quantity,
      COALESCE(a.net_amount_gbp, 0)::numeric(18,2) AS net_amount_gbp,
      COALESCE(a.vat_amount_gbp, 0)::numeric(18,2) AS vat_amount_gbp,
      COALESCE(a.gross_amount_gbp, 0)::numeric(18,2) AS gross_amount_gbp,
      NULLIF(trim(COALESCE(a.sage_ledger_account_id, '')), '') AS line_ledger_id,
      NULLIF(trim(COALESCE(a.nominal_code, '')), '') AS nominal_code,
      NULLIF(trim(COALESCE(a.tax_rate_id, '')), '') AS line_tax_rate_id,
      a.tax_rate_label,
      COALESCE(a.vat_rate_percent, 0)::numeric(7,4) AS vat_rate_percent,
      100000::integer AS sort_order,
      'supplier_adjustment_line'::text AS line_kind
    FROM public.supplier_invoice_accounting_adjustment_lines a
  ), line_items AS (
    SELECT * FROM source_lines
    UNION ALL
    SELECT * FROM adjustment_lines
  ), line_payloads AS (
    SELECT
      li.supplier_invoice_id,
      COUNT(*)::integer AS line_count,
      COUNT(*) FILTER (WHERE NULLIF(COALESCE(li.line_ledger_id, d.default_ledger_id, ''), '') IS NULL)::integer AS missing_ledger_count,
      COUNT(*) FILTER (WHERE NULLIF(COALESCE(li.line_tax_rate_id, d.default_tax_rate_id, ''), '') IS NULL)::integer AS missing_tax_count,
      COALESCE(SUM(li.gross_amount_gbp), 0)::numeric(18,2) AS line_gross_total_gbp,
      jsonb_agg(
        jsonb_build_object(
          'line_kind', li.line_kind,
          'source_line_id', li.source_line_id,
          'description', li.description,
          'quantity', li.quantity,
          'unit_price_gbp', li.gross_amount_gbp,
          'net_amount_gbp', li.net_amount_gbp,
          'vat_amount_gbp', li.vat_amount_gbp,
          'gross_amount_gbp', li.gross_amount_gbp,
          'total_line_amount_gbp', li.gross_amount_gbp,
          'nominal_code', li.nominal_code,
          'vat_rate_percent', li.vat_rate_percent,
          'sage_ledger_account_id', COALESCE(li.line_ledger_id, d.default_ledger_id),
          'sage_ledger_account_display', CASE WHEN li.line_ledger_id IS NOT NULL THEN li.nominal_code ELSE d.default_ledger_display END,
          'sage_tax_rate_id', COALESCE(li.line_tax_rate_id, d.default_tax_rate_id),
          'sage_tax_rate_display', COALESCE(li.tax_rate_label, d.default_tax_rate_display)
        ) ORDER BY li.sort_order, li.description, li.source_line_id
      ) AS resolved_lines
    FROM line_items li
    CROSS JOIN defaults d
    GROUP BY li.supplier_invoice_id
  )
  SELECT
    ('supplier_goods_ap:' || b.supplier_invoice_id::text)::text AS queue_row_id,
    'supplier_goods_ap'::text AS document_lane,
    'supplier_goods_ap_purchase_invoice_intent'::text AS document_type,
    'supplier_invoices'::text AS source_table,
    b.supplier_invoice_id AS source_id,
    b.order_id,
    b.order_ref,
    NULL::uuid AS shipment_batch_id,
    b.order_ref::text AS booking_ref,
    COALESCE(b.retailer_name, 'Retailer/supplier')::text AS counterparty_name,
    COALESCE(b.total_coded_gross_gbp, b.accepted_invoice_gross_gbp, b.ocr_invoice_total_gbp, lp.line_gross_total_gbp, 0)::numeric(18,2) AS amount_gbp,
    'GBP'::text AS currency_code,
    'purchase_invoice'::text AS invoice_type,
    'not_drafted'::text AS sage_status,
    NULL::text AS sage_invoice_id,
    NULL::timestamptz AS sage_posted_at,
    CASE
      WHEN b.blocked_from_sage_yn THEN 'blocked_supplier_invoice_marked_blocked_from_sage'
      WHEN b.review_status NOT IN ('approved_current', 'ref_corrected_approved') AND b.is_current_for_order IS DISTINCT FROM true THEN 'blocked_supplier_invoice_not_approved_current'
      WHEN COALESCE(b.total_coded_gross_gbp, 0) <= 0 THEN 'blocked_supplier_goods_ap_amount_missing'
      WHEN COALESCE(b.progressed_line_count, 0) < 1 THEN 'blocked_supplier_goods_ap_no_progressed_lines'
      WHEN COALESCE(b.coded_line_count, 0) < 1 THEN 'blocked_supplier_goods_ap_no_coded_lines'
      WHEN COALESCE(b.all_progressed_lines_coded_yn, false) IS DISTINCT FROM true THEN 'blocked_supplier_goods_ap_not_all_lines_coded'
      WHEN COALESCE(b.gross_reconciled_to_invoice_yn, false) IS DISTINCT FROM true THEN 'blocked_supplier_goods_ap_gross_not_reconciled'
      WHEN COALESCE(b.net_reconciled_to_invoice_yn, true) IS DISTINCT FROM true THEN 'blocked_supplier_goods_ap_net_not_reconciled'
      WHEN COALESCE(b.vat_reconciled_to_invoice_yn, true) IS DISTINCT FROM true THEN 'blocked_supplier_goods_ap_vat_not_reconciled'
      WHEN NULLIF(trim(COALESCE(b.sage_contact_id, '')), '') IS NULL THEN 'blocked_supplier_goods_ap_sage_supplier_contact_missing'
      WHEN COALESCE(lp.line_count, 0) = 0 THEN 'blocked_supplier_goods_ap_resolved_lines_missing'
      WHEN COALESCE(lp.missing_ledger_count, 0) > 0 THEN 'blocked_supplier_goods_ap_ledger_mapping_missing'
      WHEN COALESCE(lp.missing_tax_count, 0) > 0 THEN 'blocked_supplier_goods_ap_tax_mapping_missing'
      ELSE 'ready_for_supplier_goods_ap_purchase_invoice_draft'
    END::text AS readiness_status,
    CASE
      WHEN b.blocked_from_sage_yn THEN 'supplier_invoice_blocked_from_sage_yn'
      WHEN b.review_status NOT IN ('approved_current', 'ref_corrected_approved') AND b.is_current_for_order IS DISTINCT FROM true THEN 'supplier_invoice_must_be_approved_current_first'
      WHEN COALESCE(b.total_coded_gross_gbp, 0) <= 0 THEN 'accepted/coded supplier invoice gross total missing'
      WHEN COALESCE(b.progressed_line_count, 0) < 1 THEN 'no progressed supplier invoice lines'
      WHEN COALESCE(b.coded_line_count, 0) < 1 THEN 'no supplier invoice accounting codes saved'
      WHEN COALESCE(b.all_progressed_lines_coded_yn, false) IS DISTINCT FROM true THEN 'all progressed supplier invoice lines must be coded'
      WHEN COALESCE(b.gross_reconciled_to_invoice_yn, false) IS DISTINCT FROM true THEN 'gross variance ' || COALESCE(b.gross_variance_gbp::text, 'unknown')
      WHEN COALESCE(b.net_reconciled_to_invoice_yn, true) IS DISTINCT FROM true THEN 'net variance ' || COALESCE(b.net_variance_gbp::text, 'unknown')
      WHEN COALESCE(b.vat_reconciled_to_invoice_yn, true) IS DISTINCT FROM true THEN 'vat variance ' || COALESCE(b.vat_variance_gbp::text, 'unknown')
      WHEN NULLIF(trim(COALESCE(b.sage_contact_id, '')), '') IS NULL THEN 'retailer/supplier Sage contact mapping missing'
      WHEN COALESCE(lp.line_count, 0) = 0 THEN 'resolved purchase invoice lines missing'
      WHEN COALESCE(lp.missing_ledger_count, 0) > 0 THEN lp.missing_ledger_count::text || ' supplier goods AP line(s) missing ledger mapping'
      WHEN COALESCE(lp.missing_tax_count, 0) > 0 THEN lp.missing_tax_count::text || ' supplier goods AP line(s) missing tax mapping'
      ELSE NULL::text
    END AS blocker,
    b.invoice_ref AS reference_text,
    ('Order ' || COALESCE(b.order_ref, '') || ' · Supplier goods AP')::text AS notes_text,
    ('/internal/supplier-draft-ready?status=approved')::text AS detail_href,
    jsonb_build_object(
      'document_lane', 'supplier_goods_ap',
      'sage_document_type', 'purchase_invoice',
      'source_table', 'supplier_invoices',
      'source_id', b.supplier_invoice_id,
      'order_id', b.order_id,
      'order_ref', b.order_ref,
      'retailer_id', b.retailer_id,
      'retailer_name', b.retailer_name,
      'supplier_invoice_ref', b.invoice_ref,
      'supplier_target', jsonb_build_object(
        'platform_party_type', 'retailer_supplier',
        'platform_party_id', b.retailer_id,
        'display_name', b.retailer_name,
        'sage_party_mapping_id', b.party_mapping_id,
        'sage_contact_id', b.sage_contact_id,
        'sage_contact_display_name', b.sage_contact_display_name,
        'sage_contact_reference', b.sage_contact_reference,
        'sage_contact_type', b.sage_contact_type,
        'verified_at', b.party_verified_at
      ),
      'sage_header', jsonb_build_object(
        'reference', b.invoice_ref,
        'notes', 'Order ' || COALESCE(b.order_ref, '') || ' · Supplier goods AP'
      ),
      'totals', jsonb_build_object(
        'accepted_invoice_gross_gbp', b.accepted_invoice_gross_gbp,
        'total_coded_net_gbp', b.total_coded_net_gbp,
        'total_coded_vat_gbp', b.total_coded_vat_gbp,
        'total_coded_gross_gbp', b.total_coded_gross_gbp,
        'line_gross_total_gbp', lp.line_gross_total_gbp,
        'progressed_line_count', b.progressed_line_count,
        'coded_line_count', b.coded_line_count,
        'gross_variance_gbp', b.gross_variance_gbp,
        'net_variance_gbp', b.net_variance_gbp,
        'vat_variance_gbp', b.vat_variance_gbp
      ),
      'mapping_snapshot', d.mapping_snapshot,
      'resolved_lines', COALESCE(lp.resolved_lines, '[]'::jsonb),
      'status', 'source_ready_not_posted_to_sage'
    ) AS source_payload
  FROM base b
  CROSS JOIN defaults d
  LEFT JOIN line_payloads lp ON lp.supplier_invoice_id = b.supplier_invoice_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_goods_ap_ready_rows_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: ready for Sage queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for ready for Sage queue.';
  END IF;

  RETURN QUERY
  WITH q AS (
    SELECT * FROM public.internal_ready_for_sage_queue_v1()
    UNION ALL
    SELECT * FROM public.internal_supplier_goods_ap_ready_rows_v1()
  )
  SELECT
    q.queue_row_id,
    q.document_lane,
    q.document_type,
    q.source_table,
    q.source_id,
    q.order_id,
    q.order_ref,
    q.shipment_batch_id,
    q.booking_ref,
    q.counterparty_name,
    q.amount_gbp,
    q.currency_code,
    q.invoice_type,
    q.sage_status,
    q.sage_invoice_id,
    q.sage_posted_at,
    CASE
      WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'internally_marked_posted_no_sage_confirmation'
      WHEN q.sage_status = 'posted'
        THEN 'sage_confirmation_recorded'
      ELSE q.readiness_status
    END AS readiness_status,
    CASE
      WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'legacy_internal_posted_status_without_sage_confirmation'
      ELSE q.blocker
    END AS blocker,
    q.reference_text,
    q.notes_text,
    q.detail_href,
    q.source_payload
  FROM q;
END;
$$;

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
      FROM public.internal_ready_for_sage_queue_v2() live_q
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
          revalidation_notes = NULL
      WHERE public.sage_posting_snapshots.sage_posting_status = 'not_posted'
    RETURNING id, source_id, order_ref, amount_gbp, idempotency_key
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
  ), customer_current AS (
    SELECT
      t.id AS snapshot_id,
      r.payload_status,
      r.mapping_semantic_fingerprint,
      public.internal_customer_sales_payload_fingerprint_v1(r.resolved_payload, r.mapping_semantic_fingerprint, r.amount_gbp, r.reference_text) AS payload_fingerprint
    FROM target t
    JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(t.source_id) r
      ON t.document_lane = 'customer_sales'
     AND t.source_table = 'sales_invoices'
  ), non_customer_current AS (
    SELECT
      t.id AS snapshot_id,
      rq.readiness_status AS payload_status,
      md5(COALESCE((rq.source_payload->'mapping_snapshot')::text, COALESCE(t.mapping_snapshot::text, ''))) AS mapping_semantic_fingerprint,
      md5(concat_ws('|',
        md5(COALESCE((rq.source_payload->'mapping_snapshot')::text, COALESCE(t.mapping_snapshot::text, ''))),
        COALESCE(rq.amount_gbp::text, ''),
        COALESCE(rq.reference_text, ''),
        COALESCE((rq.source_payload->'supplier_target')::text, ''),
        COALESCE((rq.source_payload->'resolved_lines')::text, ''),
        COALESCE(rq.source_payload::text, '')
      )) AS payload_fingerprint
    FROM target t
    LEFT JOIN LATERAL (
      SELECT q.*
      FROM public.internal_ready_for_sage_queue_v2() q
      WHERE q.source_table = t.source_table
        AND q.source_id = t.source_id
        AND q.document_lane = t.document_lane
      LIMIT 1
    ) rq ON t.document_lane IN ('supplier_goods_ap','shipper_ap')
  ), assessed AS (
    SELECT
      t.id AS snapshot_id,
      t.source_id,
      t.document_lane,
      t.document_type,
      t.order_ref,
      t.amount_gbp,
      t.revalidation_status AS previous_revalidation_status,
      COALESCE(cc.payload_status, nc.payload_status) AS current_payload_status,
      CASE
        WHEN t.document_lane = 'customer_sales' THEN
          CASE
            WHEN cc.payload_status IS NULL THEN 'blocked_source_not_ready'
            WHEN cc.payload_status <> 'ready_for_sage_posting_preview' THEN 'blocked_source_not_ready'
            WHEN cc.mapping_semantic_fingerprint <> t.mapping_semantic_fingerprint THEN 'stale_reapproval_required'
            WHEN cc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'stale_reapproval_required'
            ELSE 'ok_to_post'
          END
        WHEN t.document_lane IN ('supplier_goods_ap','shipper_ap') THEN
          CASE
            WHEN nc.payload_status IS NULL THEN 'blocked_source_not_ready'
            WHEN nc.payload_status NOT LIKE 'ready%' THEN 'blocked_source_not_ready'
            WHEN t.document_lane = 'supplier_goods_ap' AND nc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'stale_reapproval_required'
            ELSE 'ok_to_post'
          END
        ELSE 'blocked_source_not_ready'
      END::text AS new_revalidation_status,
      CASE
        WHEN t.document_lane = 'customer_sales' AND cc.payload_status IS NULL THEN 'resolver_returned_no_current_payload'
        WHEN t.document_lane = 'customer_sales' AND cc.payload_status <> 'ready_for_sage_posting_preview' THEN 'current_source_payload_not_ready: ' || COALESCE(cc.payload_status, 'missing')
        WHEN t.document_lane = 'customer_sales' AND cc.mapping_semantic_fingerprint <> t.mapping_semantic_fingerprint THEN 'mapping_changed_since_approval'
        WHEN t.document_lane = 'customer_sales' AND cc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'posting_critical_payload_changed_since_approval'
        WHEN t.document_lane IN ('supplier_goods_ap','shipper_ap') AND nc.payload_status IS NULL THEN 'current_source_row_not_found'
        WHEN t.document_lane IN ('supplier_goods_ap','shipper_ap') AND nc.payload_status NOT LIKE 'ready%' THEN 'current_source_payload_not_ready: ' || COALESCE(nc.payload_status, 'missing')
        WHEN t.document_lane = 'supplier_goods_ap' AND nc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'supplier_goods_ap_payload_or_mapping_changed_since_approval'
        WHEN t.document_lane NOT IN ('customer_sales','supplier_goods_ap','shipper_ap') THEN 'unsupported_snapshot_lane'
        ELSE NULL::text
      END AS new_revalidation_notes
    FROM target t
    LEFT JOIN customer_current cc ON cc.snapshot_id = t.id
    LEFT JOIN non_customer_current nc ON nc.snapshot_id = t.id
  ), updated AS (
    UPDATE public.sage_posting_snapshots s
    SET revalidation_status = a.new_revalidation_status,
        revalidated_at = now(),
        revalidation_notes = a.new_revalidation_notes
    FROM assessed a
    WHERE s.id = a.snapshot_id
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

CREATE OR REPLACE FUNCTION public.internal_validate_sage_posting_batch_payloads_v1(p_batch_id uuid)
RETURNS TABLE (
  row_id uuid,
  batch_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  idempotency_key text,
  posting_status text,
  payload_validation_status text,
  error_code text,
  error_message text,
  validation_summary jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_connection_count integer;
  v_business_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage payload validation requires auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for Sage payload validation.';
  END IF;

  SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  SELECT COUNT(DISTINCT c.id)::integer, COUNT(DISTINCT b.id)::integer
  INTO v_connection_count, v_business_count
  FROM public.sage_connections c
  JOIN public.sage_oauth_tokens t ON t.connection_id = c.id AND t.status = 'active'
  LEFT JOIN public.sage_businesses b ON b.connection_id = c.id AND b.status = 'active'
  WHERE c.status = 'connected';

  IF NOT EXISTS (SELECT 1 FROM public.sage_posting_batches b WHERE b.id = p_batch_id) THEN
    RAISE EXCEPTION 'Posting batch not found: %', p_batch_id;
  END IF;

  RETURN QUERY
  WITH target AS (
    SELECT r.*
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
  ), line_amounts AS (
    SELECT
      t.id AS row_id,
      COUNT(line.value)::integer AS line_count,
      COUNT(line.value) FILTER (WHERE COALESCE(
        public.internal_sage_jsonb_num_v1(line.value->'total_line_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'line_total_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price_gbp') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1)
      ) IS NOT NULL)::integer AS numeric_line_count,
      COALESCE(SUM(COALESCE(
        public.internal_sage_jsonb_num_v1(line.value->'total_line_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'line_total_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price_gbp') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1)
      )), 0)::numeric(18,2) AS line_total_gbp
    FROM target t
    LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) AS line(value) ON true
    GROUP BY t.id
  ), assessed AS (
    SELECT
      t.*,
      COALESCE(l.line_count, 0) AS line_count,
      COALESCE(l.numeric_line_count, 0) AS numeric_line_count,
      COALESCE(l.line_total_gbp, 0)::numeric(18,2) AS line_total_gbp,
      array_remove(ARRAY[
        CASE WHEN t.posting_status = 'excluded' THEN 'excluded_before_validation' END,
        CASE WHEN v_connection_count = 0 THEN 'missing_active_sage_connection' END,
        CASE WHEN v_business_count = 0 THEN 'missing_selected_sage_business' END,
        CASE WHEN NULLIF(trim(COALESCE(t.idempotency_key, '')), '') IS NULL THEN 'missing_idempotency_key' END,
        CASE WHEN COALESCE(t.request_payload_json, '{}'::jsonb) = '{}'::jsonb THEN 'missing_request_payload' END,
        CASE WHEN NULLIF(trim(COALESCE(t.request_payload_json #>> '{sage_header,reference}', t.reference_text, '')), '') IS NULL THEN 'missing_sage_reference' END,
        CASE WHEN COALESCE(t.amount_gbp, 0) <= 0 THEN 'amount_must_be_positive' END,
        CASE WHEN COALESCE(NULLIF(t.currency_code, ''), 'GBP') <> 'GBP' THEN 'unsupported_currency' END,
        CASE WHEN COALESCE(l.line_count, 0) = 0 THEN 'missing_resolved_lines' END,
        CASE WHEN COALESCE(l.line_count, 0) > 0 AND COALESCE(l.numeric_line_count, 0) = 0 THEN 'line_amounts_missing' END,
        CASE WHEN COALESCE(l.numeric_line_count, 0) > 0 AND abs(COALESCE(l.line_total_gbp, 0) - COALESCE(t.amount_gbp, 0)) > 0.01 THEN 'line_total_does_not_match_header_amount' END,
        CASE WHEN t.document_lane = 'customer_sales' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{customer_target,display_name}', t.counterparty_name, '')), '') IS NULL THEN 'missing_customer_contact_target' END,
        CASE WHEN t.document_lane = 'customer_sales' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{tax_resolution,sage_tax_rate_id}', '')), '') IS NULL THEN 'missing_customer_sales_tax_mapping' END,
        CASE WHEN t.document_lane = 'customer_sales' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{ledger_resolution,sage_ledger_account_id}', '')), '') IS NULL THEN 'missing_customer_sales_ledger_mapping' END,
        CASE WHEN t.document_lane = 'supplier_goods_ap' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{supplier_target,sage_contact_id}', '')), '') IS NULL THEN 'missing_supplier_goods_ap_supplier_contact_mapping' END,
        CASE WHEN t.document_lane = 'supplier_goods_ap' AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) line(value) WHERE NULLIF(trim(COALESCE(line.value #>> '{sage_ledger_account_id}', '')), '') IS NULL) THEN 'missing_supplier_goods_ap_ledger_mapping' END,
        CASE WHEN t.document_lane = 'supplier_goods_ap' AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) line(value) WHERE NULLIF(trim(COALESCE(line.value #>> '{sage_tax_rate_id}', '')), '') IS NULL) THEN 'missing_supplier_goods_ap_tax_mapping' END,
        CASE WHEN t.document_lane = 'shipper_ap' AND NULLIF(trim(COALESCE(t.counterparty_name, t.request_payload_json #>> '{counterparty_name}', '')), '') IS NULL THEN 'missing_shipper_ap_supplier_target' END,
        CASE WHEN t.document_lane = 'shipper_ap' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{resolved_lines,0,sage_ledger_account_id}', '')), '') IS NULL THEN 'missing_shipper_ap_ledger_mapping' END,
        CASE WHEN t.document_lane = 'shipper_ap' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{resolved_lines,0,sage_tax_rate_id}', '')), '') IS NULL THEN 'missing_shipper_ap_tax_mapping' END
      ]::text[], NULL) AS validation_errors
    FROM target t
    LEFT JOIN line_amounts l ON l.row_id = t.id
  ), updated AS (
    UPDATE public.sage_posting_batch_rows r
    SET payload_validation_status = CASE WHEN a.posting_status = 'excluded' THEN 'excluded_before_validation' WHEN array_length(a.validation_errors, 1) IS NULL THEN 'dry_run_validated' ELSE 'dry_run_failed' END,
        posting_status = CASE WHEN a.posting_status = 'included' AND array_length(a.validation_errors, 1) IS NULL THEN 'validated' ELSE a.posting_status END,
        error_code = CASE WHEN array_length(a.validation_errors, 1) IS NULL THEN NULL::text ELSE a.validation_errors[1] END,
        error_message = CASE WHEN array_length(a.validation_errors, 1) IS NULL THEN NULL::text ELSE array_to_string(a.validation_errors, '; ') END,
        response_payload_json = jsonb_build_object(
          'phase', 'phase_11_dry_run_payload_validation',
          'validated_at', now(),
          'sage_api_call_made', false,
          'sage_object_created', false,
          'active_sage_connection_count', v_connection_count,
          'active_sage_business_count', v_business_count,
          'line_count', a.line_count,
          'numeric_line_count', a.numeric_line_count,
          'line_total_gbp', a.line_total_gbp,
          'header_amount_gbp', a.amount_gbp,
          'validation_errors', COALESCE(to_jsonb(a.validation_errors), '[]'::jsonb)
        )
    FROM assessed a
    WHERE r.id = a.id
    RETURNING r.id, r.batch_id, r.document_lane, r.document_type, r.order_ref, r.idempotency_key, r.posting_status, r.payload_validation_status, r.error_code, r.error_message, r.response_payload_json
  ), batch_update AS (
    UPDATE public.sage_posting_batches b
    SET status = CASE
      WHEN NOT EXISTS (SELECT 1 FROM public.sage_posting_batch_rows r WHERE r.batch_id = p_batch_id AND r.posting_status <> 'excluded') THEN b.status
      WHEN NOT EXISTS (SELECT 1 FROM public.sage_posting_batch_rows r WHERE r.batch_id = p_batch_id AND r.posting_status <> 'excluded' AND r.payload_validation_status <> 'dry_run_validated') THEN 'validated'
      ELSE 'draft'
    END
    WHERE b.id = p_batch_id
    RETURNING b.id
  )
  SELECT u.id, u.batch_id, u.document_lane, u.document_type, u.order_ref, u.idempotency_key, u.posting_status, u.payload_validation_status, u.error_code, u.error_message, u.response_payload_json
  FROM updated u
  ORDER BY CASE u.payload_validation_status WHEN 'dry_run_failed' THEN 0 WHEN 'dry_run_validated' THEN 1 ELSE 2 END, u.document_lane, u.order_ref;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
