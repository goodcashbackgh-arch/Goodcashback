BEGIN;

-- Test seed only: creates/updates one supplier credit note evidence submission with an actual credit note PDF URL attached.
-- Anchored to order DAY3-EXC-MVP-004 and the latest refund dispute for that order.
-- This does not freeze a posting batch and does not call Sage.
-- It creates the refund evidence header, one progressed refund document line, and one accounting code line.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $seed$
DECLARE
  v_order_id uuid;
  v_dispute_id uuid;
  v_supplier_invoice_id uuid;
  v_staff_id uuid;
  v_ledger_id text;
  v_tax_rate_id text;
  v_submission_id uuid := '11111111-2222-4333-8444-555555555501'::uuid;
  v_line_id uuid := '11111111-2222-4333-8444-555555555502'::uuid;
  v_file_url text := 'https://goodcashback-v2.vercel.app/test-assets/supplier-credit-note-cn-test-2026-attached-001.pdf';
BEGIN
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Missing dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dispute_refund_document_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing dispute_refund_document_lines';
  END IF;
  IF to_regclass('public.dispute_refund_document_line_accounting_codes') IS NULL THEN
    RAISE EXCEPTION 'Missing dispute_refund_document_line_accounting_codes';
  END IF;

  SELECT o.id
  INTO v_order_id
  FROM public.orders o
  WHERE o.order_ref::text = 'DAY3-EXC-MVP-004'
  LIMIT 1;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Seed order DAY3-EXC-MVP-004 not found';
  END IF;

  SELECT d.id
  INTO v_dispute_id
  FROM public.disputes d
  WHERE d.order_id = v_order_id
    AND d.desired_outcome = 'refund'
  ORDER BY d.raised_at DESC NULLS LAST, d.id DESC
  LIMIT 1;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'No refund dispute found for order DAY3-EXC-MVP-004';
  END IF;

  SELECT si.id
  INTO v_supplier_invoice_id
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order_id
  ORDER BY si.id DESC
  LIMIT 1;

  IF v_supplier_invoice_id IS NULL THEN
    RAISE EXCEPTION 'No supplier invoice found for order DAY3-EXC-MVP-004';
  END IF;

  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.active = true
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.id
  LIMIT 1;

  SELECT sm.sage_external_id
  INTO v_ledger_id
  FROM public.sage_mapping_settings sm
  WHERE sm.mapping_code = 'SUPPLIER_GOODS_AP_LEDGER'
    AND sm.is_active = true
  ORDER BY sm.configured_at DESC NULLS LAST, sm.id DESC
  LIMIT 1;

  SELECT sm.sage_external_id
  INTO v_tax_rate_id
  FROM public.sage_mapping_settings sm
  WHERE sm.mapping_code = 'SUPPLIER_GOODS_AP_TAX_RATE'
    AND sm.is_active = true
  ORDER BY sm.configured_at DESC NULLS LAST, sm.id DESC
  LIMIT 1;

  IF NULLIF(v_ledger_id, '') IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_GOODS_AP_LEDGER mapping is missing';
  END IF;
  IF NULLIF(v_tax_rate_id, '') IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_GOODS_AP_TAX_RATE mapping is missing';
  END IF;

  INSERT INTO public.dispute_refund_evidence_submissions (
    id,
    dispute_id,
    original_order_id,
    original_supplier_invoice_id,
    submitted_at,
    document_mode,
    message_type,
    credit_note_ref,
    credit_note_date,
    expected_credit_note_total_gbp,
    credit_note_file_url,
    refund_lines_json,
    delivery_adjustment_gbp,
    discount_adjustment_gbp,
    expected_exception_amount_abs_gbp,
    captured_refund_amount_abs_gbp,
    variance_abs_gbp,
    amount_balance_status,
    evidence_control_status,
    supplier_readiness_route,
    supplier_approval_status,
    supplier_approved_by_staff_id,
    supplier_approved_at,
    supervisor_review_status,
    supervisor_reviewed_by_staff_id,
    supervisor_reviewed_at,
    supervisor_review_notes,
    raw_body,
    notes,
    ocr_status,
    ocr_credit_note_ref,
    ocr_retailer_name,
    ocr_credit_note_date,
    ocr_credit_note_total_gbp,
    ocr_raw_json,
    ocr_extracted_at,
    match_status,
    supplier_control_status,
    supplier_control_released_by_staff_id,
    supplier_control_released_at,
    supplier_control_release_notes
  ) VALUES (
    v_submission_id,
    v_dispute_id,
    v_order_id,
    v_supplier_invoice_id,
    now(),
    'credit_note',
    'credit_note_evidence',
    'CN-TEST-2026-ATTACHED-001',
    DATE '2026-05-08',
    30.00,
    v_file_url,
    jsonb_build_array(jsonb_build_object('description','Returned shoes','qty',1,'gross_gbp',30.00,'net_gbp',25.00,'vat_gbp',5.00)),
    0,
    0,
    30.00,
    30.00,
    0,
    'balanced',
    'source_evidence_available',
    'supplier_credit_note_purchase_credit_note',
    'approved_current',
    v_staff_id,
    now(),
    'accepted',
    v_staff_id,
    now(),
    'Seeded attached credit note test evidence.',
    'Seeded attached supplier credit note PDF: ' || v_file_url,
    'Seeded attached supplier credit note PDF for Sage purchase credit note test.',
    'completed',
    'CN-TEST-2026-ATTACHED-001',
    'Ninja',
    DATE '2026-05-08',
    30.00,
    jsonb_build_object('seeded', true, 'credit_note_file_url', v_file_url, 'net', 25.00, 'vat', 5.00, 'gross', 30.00),
    now(),
    'matched_ready_to_release',
    'approved_current',
    v_staff_id,
    now(),
    'Seeded as approved current for attached credit note posting test.'
  )
  ON CONFLICT (id) DO UPDATE SET
    original_supplier_invoice_id = EXCLUDED.original_supplier_invoice_id,
    credit_note_ref = EXCLUDED.credit_note_ref,
    credit_note_date = EXCLUDED.credit_note_date,
    expected_credit_note_total_gbp = EXCLUDED.expected_credit_note_total_gbp,
    credit_note_file_url = EXCLUDED.credit_note_file_url,
    refund_lines_json = EXCLUDED.refund_lines_json,
    expected_exception_amount_abs_gbp = EXCLUDED.expected_exception_amount_abs_gbp,
    captured_refund_amount_abs_gbp = EXCLUDED.captured_refund_amount_abs_gbp,
    variance_abs_gbp = EXCLUDED.variance_abs_gbp,
    amount_balance_status = EXCLUDED.amount_balance_status,
    evidence_control_status = EXCLUDED.evidence_control_status,
    supplier_readiness_route = EXCLUDED.supplier_readiness_route,
    supplier_approval_status = EXCLUDED.supplier_approval_status,
    supplier_approved_by_staff_id = EXCLUDED.supplier_approved_by_staff_id,
    supplier_approved_at = EXCLUDED.supplier_approved_at,
    supervisor_review_status = EXCLUDED.supervisor_review_status,
    supervisor_reviewed_by_staff_id = EXCLUDED.supervisor_reviewed_by_staff_id,
    supervisor_reviewed_at = EXCLUDED.supervisor_reviewed_at,
    supervisor_review_notes = EXCLUDED.supervisor_review_notes,
    raw_body = EXCLUDED.raw_body,
    notes = EXCLUDED.notes,
    ocr_status = EXCLUDED.ocr_status,
    ocr_credit_note_ref = EXCLUDED.ocr_credit_note_ref,
    ocr_retailer_name = EXCLUDED.ocr_retailer_name,
    ocr_credit_note_date = EXCLUDED.ocr_credit_note_date,
    ocr_credit_note_total_gbp = EXCLUDED.ocr_credit_note_total_gbp,
    ocr_raw_json = EXCLUDED.ocr_raw_json,
    ocr_extracted_at = EXCLUDED.ocr_extracted_at,
    match_status = EXCLUDED.match_status,
    supplier_control_status = EXCLUDED.supplier_control_status,
    supplier_control_released_by_staff_id = EXCLUDED.supplier_control_released_by_staff_id,
    supplier_control_released_at = EXCLUDED.supplier_control_released_at,
    supplier_control_release_notes = EXCLUDED.supplier_control_release_notes;

  INSERT INTO public.dispute_refund_document_lines (
    id,
    refund_evidence_submission_id,
    dispute_line_id,
    line_order,
    line_source,
    description,
    qty,
    amount_gbp,
    progressed_to_supplier_control_yn
  ) VALUES (
    v_line_id,
    v_submission_id,
    NULL,
    1,
    'ocr_extracted',
    'Returned shoes',
    1,
    30.00,
    true
  )
  ON CONFLICT (id) DO UPDATE SET
    description = EXCLUDED.description,
    qty = EXCLUDED.qty,
    amount_gbp = EXCLUDED.amount_gbp,
    progressed_to_supplier_control_yn = EXCLUDED.progressed_to_supplier_control_yn;

  INSERT INTO public.dispute_refund_document_line_accounting_codes (
    refund_document_line_id,
    description_override,
    sage_ledger_account_id,
    tax_rate_id,
    tax_rate_label,
    vat_rate_percent,
    net_amount_gbp,
    vat_amount_gbp,
    gross_amount_gbp,
    coded_by_staff_id,
    coded_at,
    admin_review_required_yn,
    review_reason
  ) VALUES (
    v_line_id,
    'Returned shoes',
    v_ledger_id,
    v_tax_rate_id,
    '20% standard',
    20.0000,
    25.00,
    5.00,
    30.00,
    v_staff_id,
    now(),
    false,
    NULL
  )
  ON CONFLICT (refund_document_line_id) DO UPDATE SET
    description_override = EXCLUDED.description_override,
    sage_ledger_account_id = EXCLUDED.sage_ledger_account_id,
    tax_rate_id = EXCLUDED.tax_rate_id,
    tax_rate_label = EXCLUDED.tax_rate_label,
    vat_rate_percent = EXCLUDED.vat_rate_percent,
    net_amount_gbp = EXCLUDED.net_amount_gbp,
    vat_amount_gbp = EXCLUDED.vat_amount_gbp,
    gross_amount_gbp = EXCLUDED.gross_amount_gbp,
    coded_by_staff_id = EXCLUDED.coded_by_staff_id,
    coded_at = EXCLUDED.coded_at,
    admin_review_required_yn = EXCLUDED.admin_review_required_yn,
    review_reason = EXCLUDED.review_reason;

  RAISE NOTICE 'Seeded attached supplier credit note evidence submission %, order %, dispute %, original supplier invoice %, PDF %',
    v_submission_id, v_order_id, v_dispute_id, v_supplier_invoice_id, v_file_url;
END
$seed$;

COMMIT;

-- Check after commit:
-- SELECT * FROM public.internal_supplier_credit_note_ready_rows_v1()
-- WHERE source_id = '11111111-2222-4333-8444-555555555501'::uuid;
