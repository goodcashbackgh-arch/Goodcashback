BEGIN;

-- Require an explicit document date for formal supplier credit notes. Legacy rows are
-- backfilled only while their source evidence remains live and has never been frozen
-- into a Sage posting snapshot. Unsafe legacy rows remain visible but blocked.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_posting_snapshots';
  END IF;
END $$;

UPDATE public.dispute_refund_evidence_submissions s
SET credit_note_date = s.ocr_credit_note_date
WHERE s.document_mode = 'credit_note'
  AND s.credit_note_date IS NULL
  AND s.ocr_credit_note_date IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot
    WHERE snapshot.source_table = 'dispute_refund_evidence_submissions'
      AND snapshot.source_id = s.id
  );

ALTER TABLE public.dispute_refund_evidence_submissions
  ADD CONSTRAINT dispute_refund_evidence_credit_note_date_required_chk
  CHECK (document_mode <> 'credit_note' OR credit_note_date IS NOT NULL)
  NOT VALID;

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
      CASE
        WHEN b.document_mode = 'credit_note' THEN b.credit_note_date
        ELSE COALESCE(
          b.credit_note_date,
          b.refund_statement_date,
          b.supplier_approved_at::date,
          b.submitted_at::date,
          CURRENT_DATE
        )::date
      END AS document_date
    FROM base b
  ), source_lines AS (
    SELECT
      l.refund_evidence_submission_id,
      l.id AS source_line_id,
      COALESCE(NULLIF(c.description_override, ''), NULLIF(l.description, ''), 'Supplier credit line')::text AS description,
      COALESCE(NULLIF(l.qty, 0), 1)::numeric AS quantity,
      COALESCE(c.net_amount_gbp, 0)::numeric(18,2) AS net_amount_gbp,
      COALESCE(c.vat_amount_gbp, 0)::numeric(18,2) AS vat_amount_gbp,
      COALESCE(c.gross_amount_gbp, l.amount_gbp, 0)::numeric(18,2) AS gross_amount_gbp,
      NULLIF(trim(COALESCE(c.sage_ledger_account_id, '')), '') AS line_ledger_id,
      NULLIF(trim(COALESCE(c.tax_rate_id, '')), '') AS line_tax_rate_id,
      c.tax_rate_label,
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
      1::numeric AS quantity,
      COALESCE(a.net_amount_gbp, 0)::numeric(18,2) AS net_amount_gbp,
      COALESCE(a.vat_amount_gbp, 0)::numeric(18,2) AS vat_amount_gbp,
      COALESCE(a.gross_amount_gbp, 0)::numeric(18,2) AS gross_amount_gbp,
      NULLIF(trim(COALESCE(a.sage_ledger_account_id, '')), '') AS line_ledger_id,
      NULLIF(trim(COALESCE(a.tax_rate_id, '')), '') AS line_tax_rate_id,
      a.tax_rate_label,
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
      COUNT(*) FILTER (WHERE NULLIF(COALESCE(li.line_ledger_id, d.default_ledger_id, ''), '') IS NULL)::integer AS missing_ledger_count,
      COUNT(*) FILTER (WHERE NULLIF(COALESCE(li.line_tax_rate_id, d.default_tax_rate_id, ''), '') IS NULL)::integer AS missing_tax_count,
      COALESCE(SUM(li.gross_amount_gbp), 0)::numeric(18,2) AS line_gross_total_gbp,
      jsonb_agg(
        jsonb_build_object(
          'line_kind', li.line_kind,
          'source_line_id', li.source_line_id,
          'description', li.description,
          'quantity', li.quantity,
          'unit_price', CASE WHEN li.quantity = 0 THEN li.gross_amount_gbp ELSE round((li.gross_amount_gbp / li.quantity)::numeric, 2) END,
          'total_line_amount_gbp', li.gross_amount_gbp,
          'net_credit_gbp', li.net_amount_gbp,
          'vat_credit_gbp', li.vat_amount_gbp,
          'gross_credit_gbp', li.gross_amount_gbp,
          'sage_ledger_account_id', COALESCE(li.line_ledger_id, d.default_ledger_id),
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
    ('supplier_credit_note:' || a.refund_evidence_submission_id::text)::text,
    'supplier_credit_note'::text,
    'supplier_credit_note_purchase_credit_note_intent'::text,
    'dispute_refund_evidence_submissions'::text,
    a.refund_evidence_submission_id,
    a.order_id,
    a.order_ref,
    NULL::uuid,
    a.order_ref::text,
    COALESCE(a.retailer_name, 'Retailer/supplier')::text,
    COALESCE(a.accepted_gross_gbp, lp.line_gross_total_gbp, 0)::numeric(18,2),
    'GBP'::text,
    'purchase_credit_note'::text,
    'not_drafted'::text,
    NULL::text,
    NULL::timestamptz,
    CASE
      WHEN a.document_mode = 'credit_note' AND a.credit_note_date IS NULL THEN 'blocked_supplier_credit_note_date_missing'
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
    END::text,
    CASE
      WHEN a.document_mode = 'credit_note' AND a.credit_note_date IS NULL THEN 'formal supplier credit note date missing'
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
    END,
    COALESCE(a.credit_note_ref, 'REFUND-' || COALESCE(a.order_ref, left(a.refund_evidence_submission_id::text, 8)))::text,
    ('Order ' || COALESCE(a.order_ref, '') || ' · Supplier credit note')::text,
    ('/internal/status-control/supplier-credit-payload-preview?submission_id=' || a.refund_evidence_submission_id::text)::text,
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
    )
  FROM accepted a
  CROSS JOIN defaults d
  LEFT JOIN line_payloads lp ON lp.refund_evidence_submission_id = a.refund_evidence_submission_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_supplier_credit_note_ready_rows_v1() TO authenticated;

COMMIT;
