BEGIN;

-- Contract v5 Sage payload hardening:
-- Future supplier_goods_ap snapshots must carry the original source invoice facts
-- needed for a Sage purchase invoice: original supplier invoice ref, source file,
-- order context, supplier contact target, coded line split and totals.
-- No Sage API call. No posting.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
      si.invoice_pdf_url::text AS invoice_pdf_url,
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
    ('Order ' || COALESCE(b.order_ref, '') || ' · Supplier goods AP · Source invoice ' || COALESCE(b.invoice_ref, b.supplier_invoice_id::text))::text AS notes_text,
    ('/internal/supplier-draft-ready?status=approved')::text AS detail_href,
    jsonb_build_object(
      'document_lane', 'supplier_goods_ap',
      'sage_document_type', 'purchase_invoice',
      'source_table', 'supplier_invoices',
      'source_id', b.supplier_invoice_id,
      'source_evidence', jsonb_build_object(
        'source_table', 'supplier_invoices',
        'source_id', b.supplier_invoice_id,
        'file_url', b.invoice_pdf_url,
        'status', CASE WHEN NULLIF(b.invoice_pdf_url, '') IS NULL THEN 'missing_source_evidence_file' ELSE 'source_evidence_available' END
      ),
      'order_id', b.order_id,
      'order_ref', b.order_ref,
      'retailer_id', b.retailer_id,
      'retailer_name', b.retailer_name,
      'supplier_invoice_ref', b.invoice_ref,
      'supplier_invoice_pdf_url', b.invoice_pdf_url,
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
        'notes', 'Order ' || COALESCE(b.order_ref, '') || ' · Supplier goods AP · Source invoice ' || COALESCE(b.invoice_ref, b.supplier_invoice_id::text)
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

NOTIFY pgrst, 'reload schema';
COMMIT;
