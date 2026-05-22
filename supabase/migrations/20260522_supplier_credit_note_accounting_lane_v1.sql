BEGIN;

-- Supplier credit note lane for Accounting Command Centre.
-- Adds supplier_credit_note as a first-class freeze/revalidate/batch/dry-run lane.
-- No Sage API call. No customer credit note. No new accounting upload shortcut.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_lines';
  END IF;
  IF to_regclass('public.dispute_refund_document_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_line_accounting_codes';
  END IF;
  IF to_regclass('public.dispute_refund_document_accounting_totals_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_document_accounting_totals_vw';
  END IF;
  IF to_regclass('public.dva_statement_line_allocation_detail_vw') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dva_statement_line_allocation_detail_vw';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_posting_snapshots';
  END IF;
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_ready_for_sage_queue_v2()';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_supplier_credit_note_ready_rows_v1()
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
    RAISE EXCEPTION 'Unauthenticated user: supplier credit note readiness requires auth.uid()';
  END IF;
  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for supplier credit note readiness.';
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
        ) FILTER (WHERE sm.mapping_group IN ('supplier_goods_ap','supplier_credit_note') OR 'supplier_goods_ap_purchase_invoice' = ANY(sm.required_for)),
        '{}'::jsonb
      ) AS mapping_snapshot
    FROM public.sage_mapping_settings sm
  ), refund_allocations AS (
    SELECT
      a.dispute_id,
      COALESCE(SUM(a.allocated_gbp_amount) FILTER (WHERE a.allocation_type = 'retailer_refund' AND a.allocation_status = 'confirmed'), 0)::numeric(18,2) AS refund_in_allocated_gbp,
      MIN(a.statement_date) FILTER (WHERE a.allocation_type = 'retailer_refund' AND a.allocation_status = 'confirmed') AS refund_statement_date
    FROM public.dva_statement_line_allocation_detail_vw a
    GROUP BY a.dispute_id
  ), base AS (
    SELECT
      s.id AS refund_evidence_submission_id,
      s.dispute_id,
      s.original_order_id,
      s.original_supplier_invoice_id,
      s.submitted_at,
      s.document_mode,
      s.credit_note_ref,
      s.credit_note_date,
      s.credit_note_file_url,
      s.refund_proof_file_url,
      s.captured_refund_amount_abs_gbp,
      s.expected_exception_amount_abs_gbp,
      s.amount_balance_status,
      s.supplier_approval_status,
      s.supplier_control_status,
      s.supplier_approved_at,
      s.match_status,
      d.order_id AS dispute_order_id,
      d.amount_impact_gbp,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      o.retailer_id,
      r.name::text AS retailer_name,
      si.invoice_ref::text AS original_supplier_invoice_ref,
      si.invoice_pdf_url::text AS original_supplier_invoice_file_url,
      t.accepted_document_gross_gbp::numeric(18,2) AS accepted_document_gross_gbp,
      t.total_coded_net_gbp::numeric(18,2) AS total_coded_net_gbp,
      t.total_coded_vat_gbp::numeric(18,2) AS total_coded_vat_gbp,
      t.total_coded_gross_gbp::numeric(18,2) AS total_coded_gross_gbp,
      t.adjustment_gross_gbp::numeric(18,2) AS adjustment_gross_gbp,
      t.progressed_line_count,
      t.coded_line_count,
      t.all_progressed_lines_coded_yn,
      t.gross_reconciled_to_document_yn,
      t.gross_variance_gbp,
      COALESCE(ra.refund_in_allocated_gbp, 0)::numeric(18,2) AS refund_in_allocated_gbp,
      ra.refund_statement_date,
      pm.id AS party_mapping_id,
      pm.sage_contact_id,
      pm.sage_contact_display_name,
      pm.sage_contact_reference,
      pm.sage_contact_type,
      pm.verified_at AS party_verified_at
    FROM public.dispute_refund_evidence_submissions s
    JOIN public.disputes d ON d.id = s.dispute_id
    LEFT JOIN public.orders o ON o.id = COALESCE(s.original_order_id, d.order_id)
    LEFT JOIN public.supplier_invoices si ON si.id = s.original_supplier_invoice_id
    LEFT JOIN public.retailers r ON r.id = COALESCE(o.retailer_id, si.retailer_id)
    LEFT JOIN public.dispute_refund_document_accounting_totals_vw t ON t.refund_evidence_submission_id = s.id
    LEFT JOIN refund_allocations ra ON ra.dispute_id = s.dispute_id
    LEFT JOIN LATERAL (
      SELECT m.*
      FROM public.sage_party_mappings m
      WHERE m.platform_party_type = 'retailer_supplier'
        AND m.platform_party_id = COALESCE(o.retailer_id, si.retailer_id)
        AND m.active = true
      ORDER BY m.verified_at DESC NULLS LAST, m.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    WHERE s.document_mode IN ('credit_note', 'refund_proof_no_credit_note', 'no_document')
      AND s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
  ), accepted AS (
    SELECT
      b.*,
      GREATEST(
        COALESCE(b.accepted_document_gross_gbp, 0),
        COALESCE(b.captured_refund_amount_abs_gbp, 0),
        COALESCE(b.expected_exception_amount_abs_gbp, 0),
        COALESCE(b.amount_impact_gbp, 0)
      )::numeric(18,2) AS accepted_gross_gbp,
      COALESCE(
        b.credit_note_date,
        b.refund_statement_date,
        b.supplier_approved_at::date,
        b.submitted_at::date,
        CURRENT_DATE
      )::date AS document_date
    FROM base b
  ), source_lines AS (
    SELECT
      l.refund_evidence_submission_id,
      l.id AS source_line_id,
      COALESCE(NULLIF(c.description_override, ''), NULLIF(l.description, ''), 'Supplier credit line')::text AS description,
      COALESCE(NULLIF(c.sku_override, ''), NULLIF(l.retailer_sku, ''), NULL)::text AS sku,
      COALESCE(NULLIF(c.size_override, ''), NULLIF(l.size, ''), NULL)::text AS size,
      COALESCE(NULLIF(l.qty, 0), 1)::numeric AS quantity,
      COALESCE(c.net_amount_gbp, 0)::numeric(18,2) AS net_amount_gbp,
      COALESCE(c.vat_amount_gbp, 0)::numeric(18,2) AS vat_amount_gbp,
      COALESCE(c.gross_amount_gbp, l.amount_gbp, 0)::numeric(18,2) AS gross_amount_gbp,
      NULLIF(trim(COALESCE(c.sage_ledger_account_id, '')), '') AS line_ledger_id,
      NULLIF(trim(COALESCE(c.nominal_code, '')), '') AS nominal_code,
      NULLIF(trim(COALESCE(c.tax_rate_id, '')), '') AS line_tax_rate_id,
      c.tax_rate_label,
      COALESCE(c.vat_rate_percent, 0)::numeric(7,4) AS vat_rate_percent,
      l.line_order::integer AS sort_order,
      'refund_document_line'::text AS line_kind
    FROM public.dispute_refund_document_lines l
    LEFT JOIN public.dispute_refund_document_line_accounting_codes c ON c.refund_document_line_id = l.id
    WHERE COALESCE(l.progressed_to_supplier_control_yn, false) = true
  ), adjustment_lines AS (
    SELECT
      a.refund_evidence_submission_id,
      a.id AS source_line_id,
      COALESCE(NULLIF(a.description, ''), 'Supplier credit adjustment')::text AS description,
      NULLIF(a.sku, '')::text AS sku,
      NULLIF(a.size, '')::text AS size,
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
      'refund_adjustment_line'::text AS line_kind
    FROM public.dispute_refund_document_accounting_adjustment_lines a
  ), line_items AS (
    SELECT * FROM source_lines
    UNION ALL
    SELECT * FROM adjustment_lines
  ), line_payloads AS (
    SELECT
      li.refund_evidence_submission_id,
      COUNT(*)::integer AS line_count,
      COUNT(*) FILTER (WHERE li.line_kind = 'refund_document_line')::integer AS refund_line_count,
      COUNT(*) FILTER (WHERE NULLIF(COALESCE(li.line_ledger_id, d.default_ledger_id, ''), '') IS NULL)::integer AS missing_ledger_count,
      COUNT(*) FILTER (WHERE NULLIF(COALESCE(li.line_tax_rate_id, d.default_tax_rate_id, ''), '') IS NULL)::integer AS missing_tax_count,
      COALESCE(SUM(li.gross_amount_gbp), 0)::numeric(18,2) AS line_gross_total_gbp,
      jsonb_agg(
        jsonb_build_object(
          'line_kind', li.line_kind,
          'source_line_id', li.source_line_id,
          'description', li.description,
          'sku', li.sku,
          'size', li.size,
          'quantity', li.quantity,
          'unit_price_gbp', CASE WHEN li.quantity = 0 THEN li.gross_amount_gbp ELSE round((li.gross_amount_gbp / li.quantity)::numeric, 2) END,
          'unit_price', CASE WHEN li.quantity = 0 THEN li.gross_amount_gbp ELSE round((li.gross_amount_gbp / li.quantity)::numeric, 2) END,
          'total_line_amount_gbp', li.gross_amount_gbp,
          'net_credit_gbp', li.net_amount_gbp,
          'vat_credit_gbp', li.vat_amount_gbp,
          'gross_credit_gbp', li.gross_amount_gbp,
          'nominal_code', li.nominal_code,
          'vat_rate_percent', li.vat_rate_percent,
          'sage_ledger_account_id', COALESCE(li.line_ledger_id, d.default_ledger_id),
          'sage_ledger_account_display', CASE WHEN li.line_ledger_id IS NOT NULL THEN li.nominal_code ELSE d.default_ledger_display END,
          'sage_tax_rate_id', COALESCE(li.line_tax_rate_id, d.default_tax_rate_id),
          'tax_rate_id', COALESCE(li.line_tax_rate_id, d.default_tax_rate_id),
          'sage_tax_rate_display', COALESCE(li.tax_rate_label, d.default_tax_rate_display),
          'posting_sign', 'credit'
        ) ORDER BY li.sort_order, li.description, li.source_line_id
      ) AS resolved_lines
    FROM line_items li
    CROSS JOIN defaults d
    GROUP BY li.refund_evidence_submission_id
  )
  SELECT
    ('supplier_credit_note:' || a.refund_evidence_submission_id::text)::text AS queue_row_id,
    'supplier_credit_note'::text AS document_lane,
    'supplier_credit_note_purchase_credit_note_intent'::text AS document_type,
    'dispute_refund_evidence_submissions'::text AS source_table,
    a.refund_evidence_submission_id AS source_id,
    a.order_id,
    a.order_ref,
    NULL::uuid AS shipment_batch_id,
    a.order_ref::text AS booking_ref,
    COALESCE(a.retailer_name, 'Retailer/supplier')::text AS counterparty_name,
    COALESCE(a.accepted_gross_gbp, lp.line_gross_total_gbp, 0)::numeric(18,2) AS amount_gbp,
    'GBP'::text AS currency_code,
    'purchase_credit_note'::text AS invoice_type,
    'not_drafted'::text AS sage_status,
    NULL::text AS sage_invoice_id,
    NULL::timestamptz AS sage_posted_at,
    CASE
      WHEN a.original_supplier_invoice_id IS NULL THEN 'blocked_supplier_credit_original_supplier_invoice_missing'
      WHEN COALESCE(a.accepted_gross_gbp, 0) <= 0 THEN 'blocked_supplier_credit_amount_missing'
      WHEN COALESCE(a.progressed_line_count, 0) < 1 THEN 'blocked_supplier_credit_no_progressed_lines'
      WHEN COALESCE(a.coded_line_count, 0) < 1 THEN 'blocked_supplier_credit_no_coded_lines'
      WHEN COALESCE(a.all_progressed_lines_coded_yn, false) IS DISTINCT FROM true THEN 'blocked_supplier_credit_not_all_lines_coded'
      WHEN COALESCE(a.gross_reconciled_to_document_yn, false) IS DISTINCT FROM true THEN 'blocked_supplier_credit_gross_not_reconciled'
      WHEN COALESCE(a.refund_in_allocated_gbp, 0) + 0.01 < COALESCE(a.accepted_gross_gbp, 0) THEN 'blocked_supplier_credit_refund_in_allocation_short'
      WHEN NULLIF(trim(COALESCE(a.sage_contact_id, '')), '') IS NULL THEN 'blocked_supplier_credit_sage_supplier_contact_missing'
      WHEN COALESCE(lp.line_count, 0) = 0 THEN 'blocked_supplier_credit_resolved_lines_missing'
      WHEN COALESCE(lp.missing_ledger_count, 0) > 0 THEN 'blocked_supplier_credit_ledger_mapping_missing'
      WHEN COALESCE(lp.missing_tax_count, 0) > 0 THEN 'blocked_supplier_credit_tax_mapping_missing'
      ELSE 'ready_for_supplier_credit_note_purchase_credit_note_draft'
    END::text AS readiness_status,
    CASE
      WHEN a.original_supplier_invoice_id IS NULL THEN 'original supplier invoice id missing'
      WHEN COALESCE(a.accepted_gross_gbp, 0) <= 0 THEN 'accepted supplier credit gross missing'
      WHEN COALESCE(a.progressed_line_count, 0) < 1 THEN 'no progressed refund document lines'
      WHEN COALESCE(a.coded_line_count, 0) < 1 THEN 'no supplier credit line accounting codes saved'
      WHEN COALESCE(a.all_progressed_lines_coded_yn, false) IS DISTINCT FROM true THEN 'all progressed supplier credit lines must be coded'
      WHEN COALESCE(a.gross_reconciled_to_document_yn, false) IS DISTINCT FROM true THEN 'gross variance ' || COALESCE(a.gross_variance_gbp::text, 'unknown')
      WHEN COALESCE(a.refund_in_allocated_gbp, 0) + 0.01 < COALESCE(a.accepted_gross_gbp, 0) THEN 'confirmed refund-IN allocation ' || COALESCE(a.refund_in_allocated_gbp::text, '0') || ' is below accepted credit ' || COALESCE(a.accepted_gross_gbp::text, '0')
      WHEN NULLIF(trim(COALESCE(a.sage_contact_id, '')), '') IS NULL THEN 'retailer/supplier Sage contact mapping missing'
      WHEN COALESCE(lp.line_count, 0) = 0 THEN 'resolved supplier credit lines missing'
      WHEN COALESCE(lp.missing_ledger_count, 0) > 0 THEN lp.missing_ledger_count::text || ' supplier credit line(s) missing ledger mapping'
      WHEN COALESCE(lp.missing_tax_count, 0) > 0 THEN lp.missing_tax_count::text || ' supplier credit line(s) missing tax mapping'
      ELSE NULL::text
    END AS blocker,
    COALESCE(a.credit_note_ref, 'REFUND-' || COALESCE(a.order_ref, left(a.refund_evidence_submission_id::text, 8)))::text AS reference_text,
    ('Order ' || COALESCE(a.order_ref, '') || ' · Supplier credit note')::text AS notes_text,
    ('/internal/status-control/supplier-credit-payload-preview?submission_id=' || a.refund_evidence_submission_id::text)::text AS detail_href,
    jsonb_build_object(
      'document_lane', 'supplier_credit_note',
      'sage_document_type', 'purchase_credit_note',
      'posting_intent', 'supplier_credit_note',
      'source_table', 'dispute_refund_evidence_submissions',
      'source_id', a.refund_evidence_submission_id,
      'refund_evidence_submission_id', a.refund_evidence_submission_id,
      'dispute_id', a.dispute_id,
      'order_id', a.order_id,
      'order_ref', a.order_ref,
      'retailer_id', a.retailer_id,
      'retailer_name', a.retailer_name,
      'original_supplier_invoice_id', a.original_supplier_invoice_id,
      'original_supplier_invoice_ref', a.original_supplier_invoice_ref,
      'supplier_target', jsonb_build_object(
        'platform_party_type', 'retailer_supplier',
        'platform_party_id', a.retailer_id,
        'display_name', a.retailer_name,
        'sage_party_mapping_id', a.party_mapping_id,
        'sage_contact_id', a.sage_contact_id,
        'sage_contact_display_name', a.sage_contact_display_name,
        'sage_contact_reference', a.sage_contact_reference,
        'sage_contact_type', a.sage_contact_type,
        'verified_at', a.party_verified_at
      ),
      'sage_header', jsonb_build_object(
        'reference', COALESCE(a.credit_note_ref, 'REFUND-' || COALESCE(a.order_ref, left(a.refund_evidence_submission_id::text, 8))),
        'date', a.document_date,
        'notes', 'Order ' || COALESCE(a.order_ref, '') || ' · Supplier credit note'
      ),
      'totals', jsonb_build_object(
        'accepted_credit_gross_gbp', a.accepted_gross_gbp,
        'total_coded_net_gbp', a.total_coded_net_gbp,
        'total_coded_vat_gbp', a.total_coded_vat_gbp,
        'total_coded_gross_gbp', a.total_coded_gross_gbp,
        'line_gross_total_gbp', lp.line_gross_total_gbp,
        'refund_in_allocated_gbp', a.refund_in_allocated_gbp,
        'progressed_line_count', a.progressed_line_count,
        'coded_line_count', a.coded_line_count,
        'gross_variance_gbp', a.gross_variance_gbp
      ),
      'controls', jsonb_build_object(
        'supplier_approval_status', a.supplier_approval_status,
        'supplier_control_status', a.supplier_control_status,
        'gross_reconciled_to_document_yn', a.gross_reconciled_to_document_yn,
        'all_progressed_lines_coded_yn', a.all_progressed_lines_coded_yn,
        'refund_in_allocation_covers_approved_amount', COALESCE(a.refund_in_allocated_gbp, 0) + 0.01 >= COALESCE(a.accepted_gross_gbp, 0)
      ),
      'evidence', jsonb_build_object(
        'credit_note_file_url', a.credit_note_file_url,
        'refund_proof_file_url', a.refund_proof_file_url,
        'original_supplier_invoice_file_url', a.original_supplier_invoice_file_url
      ),
      'mapping_snapshot', d.mapping_snapshot,
      'resolved_lines', COALESCE(lp.resolved_lines, '[]'::jsonb),
      'status', 'source_ready_not_posted_to_sage'
    ) AS source_payload
  FROM accepted a
  CROSS JOIN defaults d
  LEFT JOIN line_payloads lp ON lp.refund_evidence_submission_id = a.refund_evidence_submission_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_freeze_supplier_credit_note_sage_batch_v1(
  p_refund_evidence_submission_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  snapshot_id uuid,
  refund_evidence_submission_id uuid,
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
    RAISE EXCEPTION 'Unauthenticated user: supplier credit note freeze requires auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for supplier credit note freeze.';
  END IF;
  IF p_refund_evidence_submission_ids IS NULL OR array_length(p_refund_evidence_submission_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one supplier credit/refund evidence submission id is required.';
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
    'supplier_credit_note_preview_freeze',
    'frozen_pending_posting',
    v_staff_id,
    auth.uid(),
    p_notes,
    'internal_freeze_supplier_credit_note_sage_batch_v1'
  )
  RETURNING public.sage_posting_batches.id INTO v_batch_id;

  RETURN QUERY
  WITH requested AS (
    SELECT DISTINCT unnest(p_refund_evidence_submission_ids)::uuid AS refund_evidence_submission_id
  ), live_rows AS (
    SELECT req.refund_evidence_submission_id, q.*
    FROM requested req
    LEFT JOIN LATERAL (
      SELECT live_q.*
      FROM public.internal_ready_for_sage_queue_v2() live_q
      WHERE live_q.source_table = 'dispute_refund_evidence_submissions'
        AND live_q.document_lane = 'supplier_credit_note'
        AND live_q.source_id = req.refund_evidence_submission_id
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
        'sage_document_type', 'purchase_credit_note',
        'posting_intent', 'supplier_credit_note',
        'supplier_target', COALESCE(lr.source_payload->'supplier_target', '{}'::jsonb),
        'counterparty_name', lr.counterparty_name,
        'amount_gbp', lr.amount_gbp,
        'currency_code', COALESCE(lr.currency_code, 'GBP'),
        'sage_header', COALESCE(lr.source_payload->'sage_header', jsonb_build_object('reference', lr.reference_text, 'notes', lr.notes_text)),
        'resolved_lines', COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb),
        'mapping_snapshot', COALESCE(lr.source_payload->'mapping_snapshot', '{}'::jsonb),
        'evidence', COALESCE(lr.source_payload->'evidence', '{}'::jsonb),
        'source_payload', COALESCE(lr.source_payload, '{}'::jsonb),
        'freeze_control', jsonb_build_object('status', 'approved_frozen_not_posted_to_sage')
      ) AS resolved_payload,
      CASE
        WHEN lr.source_id IS NULL THEN 'ready_queue_row_not_found'
        WHEN COALESCE(lr.readiness_status, '') NOT LIKE 'ready%' THEN COALESCE(lr.blocker, lr.readiness_status, 'not_ready')
        WHEN NULLIF(lr.source_payload #>> '{supplier_target,sage_contact_id}', '') IS NULL THEN 'missing_supplier_credit_sage_supplier_contact'
        WHEN NULLIF(lr.source_payload #>> '{source_payload,original_supplier_invoice_id}', '') IS NULL AND NULLIF(lr.source_payload #>> '{original_supplier_invoice_id}', '') IS NULL THEN 'missing_original_supplier_invoice_id'
        WHEN jsonb_array_length(COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb)) = 0 THEN 'missing_supplier_credit_resolved_lines'
        WHEN EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb)) line(value)
          WHERE NULLIF(line.value #>> '{sage_ledger_account_id}', '') IS NULL
        ) THEN 'missing_supplier_credit_ledger_mapping'
        WHEN EXISTS (
          SELECT 1
          FROM jsonb_array_elements(COALESCE(lr.source_payload->'resolved_lines', '[]'::jsonb)) line(value)
          WHERE NULLIF(COALESCE(line.value #>> '{sage_tax_rate_id}', line.value #>> '{tax_rate_id}', ''), '') IS NULL
        ) THEN 'missing_supplier_credit_tax_mapping'
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
        COALESCE((p.resolved_payload->'resolved_lines')::text, ''),
        COALESCE((p.resolved_payload->'source_payload')::text, '')
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
    i.source_id AS refund_evidence_submission_id,
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
    k.refund_evidence_submission_id,
    k.order_ref,
    k.amount_gbp,
    'not_frozen'::text AS freeze_status,
    COALESCE(k.freeze_blocker, 'not_ready') AS blocker,
    k.prepared_idempotency_key AS idempotency_key
  FROM keyed k
  WHERE k.freeze_blocker IS NOT NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text) TO authenticated;

DO $patch$
DECLARE
  v_oid oid;
  v_sql text;
BEGIN
  v_oid := to_regprocedure('public.internal_ready_for_sage_queue_v2()');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'internal_ready_for_sage_queue_v2() missing'; END IF;
  v_sql := pg_get_functiondef(v_oid);
  IF position('internal_supplier_credit_note_ready_rows_v1' in v_sql) = 0 THEN
    IF position('SELECT * FROM public.internal_supplier_goods_ap_ready_rows_v1()' in v_sql) > 0 THEN
      v_sql := replace(v_sql,
        'SELECT * FROM public.internal_supplier_goods_ap_ready_rows_v1()',
        'SELECT * FROM public.internal_supplier_goods_ap_ready_rows_v1()
    UNION ALL
    SELECT * FROM public.internal_supplier_credit_note_ready_rows_v1()'
      );
    ELSE
      RAISE EXCEPTION 'Could not find supplier goods AP union point in internal_ready_for_sage_queue_v2';
    END IF;
    EXECUTE v_sql;
  END IF;

  v_oid := to_regprocedure('public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'internal_accounting_command_centre_bulk_candidates_v1 missing'; END IF;
  v_sql := pg_get_functiondef(v_oid);
  IF position('supplier_credit_note' in v_sql) = 0 THEN
    v_sql := replace(v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$
    );
    v_sql := replace(v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN NULL::text$$
    );
    EXECUTE v_sql;
  END IF;

  v_oid := to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'internal_accounting_command_centre_grid_v1 missing'; END IF;
  v_sql := pg_get_functiondef(v_oid);
  IF position('supplier_credit_note' in v_sql) = 0 THEN
    v_sql := replace(v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'Freeze supplier credit note'$$
    );
    v_sql := replace(v_sql,
      $$(rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices')
        OR (rq.document_lane = 'supplier_goods_ap' AND rq.source_table = 'supplier_invoices')
        OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents') AS out_selectable$$,
      $$(rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices')
        OR (rq.document_lane = 'supplier_goods_ap' AND rq.source_table = 'supplier_invoices')
        OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents')
        OR (rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions') AS out_selectable$$
    );
    v_sql := replace(v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$
    );
    EXECUTE v_sql;
  END IF;

  v_oid := to_regprocedure('public.internal_revalidate_sage_posting_snapshots_v1(uuid[])');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'internal_revalidate_sage_posting_snapshots_v1 missing'; END IF;
  v_sql := pg_get_functiondef(v_oid);
  IF position('supplier_credit_note' in v_sql) = 0 THEN
    v_sql := replace(v_sql, $$t.document_lane IN ('supplier_goods_ap','shipper_ap')$$, $$t.document_lane IN ('supplier_goods_ap','shipper_ap','supplier_credit_note')$$);
    v_sql := replace(v_sql, $$t.document_lane IN ('supplier_goods_ap','shipper_ap') THEN$$, $$t.document_lane IN ('supplier_goods_ap','shipper_ap','supplier_credit_note') THEN$$);
    v_sql := replace(v_sql, $$t.document_lane NOT IN ('customer_sales','supplier_goods_ap','shipper_ap') THEN 'unsupported_snapshot_lane'$$, $$t.document_lane NOT IN ('customer_sales','supplier_goods_ap','shipper_ap','supplier_credit_note') THEN 'unsupported_snapshot_lane'$$);
    v_sql := replace(v_sql, $$WHEN t.document_lane = 'supplier_goods_ap' AND nc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'supplier_goods_ap_payload_or_mapping_changed_since_approval'$$, $$WHEN t.document_lane = 'supplier_goods_ap' AND nc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'supplier_goods_ap_payload_or_mapping_changed_since_approval'
        WHEN t.document_lane = 'supplier_credit_note' AND nc.payload_fingerprint <> t.payload_semantic_fingerprint THEN 'supplier_credit_note_payload_or_mapping_changed_since_approval'$$);
    EXECUTE v_sql;
  END IF;

  v_oid := to_regprocedure('public.internal_create_sage_posting_batch_from_filter_v1(text,text,text,text,boolean,text,integer)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'internal_create_sage_posting_batch_from_filter_v1 missing'; END IF;
  v_sql := pg_get_functiondef(v_oid);
  IF position('supplier_credit_note' in v_sql) = 0 THEN
    v_sql := replace(v_sql,
      $$IF v_batch_lane NOT IN ('customer_sales', 'supplier_goods_ap', 'shipper_ap') THEN$$,
      $$IF v_batch_lane NOT IN ('customer_sales', 'supplier_goods_ap', 'shipper_ap', 'supplier_credit_note') THEN$$
    );
    v_sql := replace(v_sql,
      $$Select one lane only: customer_sales, supplier_goods_ap, or shipper_ap.$$,
      $$Select one lane only: customer_sales, supplier_goods_ap, supplier_credit_note, or shipper_ap.$$
    );
    v_sql := replace(v_sql,
      $$WHEN c.document_lane IN ('supplier_goods_ap', 'shipper_ap') THEN 'purchase_invoice'$$,
      $$WHEN c.document_lane IN ('supplier_goods_ap', 'shipper_ap') THEN 'purchase_invoice'
      WHEN c.document_lane = 'supplier_credit_note' THEN 'purchase_credit_note'$$
    );
    EXECUTE v_sql;
  END IF;

  v_oid := to_regprocedure('public.internal_validate_sage_posting_batch_payloads_v1(uuid)');
  IF v_oid IS NULL THEN RAISE EXCEPTION 'internal_validate_sage_posting_batch_payloads_v1 missing'; END IF;
  v_sql := pg_get_functiondef(v_oid);
  IF position('missing_supplier_credit_note_supplier_contact_mapping' in v_sql) = 0 THEN
    v_sql := replace(v_sql,
      $$CASE WHEN t.document_lane = 'supplier_goods_ap' AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) line(value) WHERE NULLIF(trim(COALESCE(line.value #>> '{sage_tax_rate_id}', '')), '') IS NULL) THEN 'missing_supplier_goods_ap_tax_mapping' END,$$,
      $$CASE WHEN t.document_lane = 'supplier_goods_ap' AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) line(value) WHERE NULLIF(trim(COALESCE(line.value #>> '{sage_tax_rate_id}', '')), '') IS NULL) THEN 'missing_supplier_goods_ap_tax_mapping' END,
        CASE WHEN t.document_lane = 'supplier_credit_note' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{supplier_target,sage_contact_id}', '')), '') IS NULL THEN 'missing_supplier_credit_note_supplier_contact_mapping' END,
        CASE WHEN t.document_lane = 'supplier_credit_note' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{source_payload,original_supplier_invoice_id}', t.request_payload_json #>> '{original_supplier_invoice_id}', '')), '') IS NULL THEN 'missing_supplier_credit_note_original_supplier_invoice' END,
        CASE WHEN t.document_lane = 'supplier_credit_note' AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) line(value) WHERE NULLIF(trim(COALESCE(line.value #>> '{sage_ledger_account_id}', '')), '') IS NULL) THEN 'missing_supplier_credit_note_ledger_mapping' END,
        CASE WHEN t.document_lane = 'supplier_credit_note' AND EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) line(value) WHERE NULLIF(trim(COALESCE(line.value #>> '{sage_tax_rate_id}', line.value #>> '{tax_rate_id}', '')), '') IS NULL) THEN 'missing_supplier_credit_note_tax_mapping' END,$$
    );
    EXECUTE v_sql;
  END IF;
END
$patch$;

NOTIFY pgrst, 'reload schema';
COMMIT;
