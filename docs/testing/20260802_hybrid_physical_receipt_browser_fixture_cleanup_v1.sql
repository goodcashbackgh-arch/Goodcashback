\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- Required psql variables:
-- RUN_ID EXPECTED_DATABASE ORDER_ID REVIEW_ID RECEIPT_ID TRACKING_SUBMISSION_ID
-- SUPPLIER_INVOICE_ID SUPPLIER_INVOICE_LINE_ID STORAGE_OBJECT_PATH

DO $guard$
BEGIN
  IF current_setting('app.environment', true) IS DISTINCT FROM 'acceptance' THEN
    RAISE EXCEPTION 'Browser fixture cleanup is acceptance-only.';
  END IF;
  IF current_database() IS DISTINCT FROM :'EXPECTED_DATABASE' THEN
    RAISE EXCEPTION 'Acceptance database identity mismatch.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.orders
    WHERE id=:'ORDER_ID'::uuid
      AND order_ref='PW-PHYSICAL-'||:'RUN_ID'
  ) THEN
    RAISE EXCEPTION 'Fixture ownership check failed; cleanup refused.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.physical_receipt_reviews
    WHERE id=:'REVIEW_ID'::uuid AND order_id=:'ORDER_ID'::uuid AND receipt_id=:'RECEIPT_ID'::uuid
  ) THEN
    RAISE EXCEPTION 'Review ownership check failed; cleanup refused.';
  END IF;
END
$guard$;

BEGIN;

CREATE TEMP TABLE fixture_disputes ON COMMIT DROP AS
SELECT link.dispute_id
FROM public.physical_receipt_review_dispute_links link
WHERE link.physical_receipt_review_id=:'REVIEW_ID'::uuid;

DELETE FROM public.dispute_lines
WHERE dispute_id IN (SELECT dispute_id FROM fixture_disputes)
  AND physical_remedy_allocation_id IN (
    SELECT id FROM public.physical_exception_remedy_allocations
    WHERE physical_receipt_review_id=:'REVIEW_ID'::uuid
  );

DELETE FROM public.physical_receipt_review_dispute_links
WHERE physical_receipt_review_id=:'REVIEW_ID'::uuid
  AND dispute_id IN (SELECT dispute_id FROM fixture_disputes);

UPDATE public.physical_receipt_reviews
SET linked_dispute_id=NULL,
    status=CASE WHEN status='approved_to_existing_exception' THEN 'rejected' ELSE status END,
    approved_liable_party=NULL,
    supervisor_decided_by_staff_id=NULL,
    supervisor_decided_at=NULL,
    decision_note=CASE WHEN status='approved_to_existing_exception' THEN 'physical-receipt-browser cleanup' ELSE decision_note END,
    updated_at=now()
WHERE id=:'REVIEW_ID'::uuid;

DELETE FROM public.disputes
WHERE id IN (SELECT dispute_id FROM fixture_disputes)
  AND NOT EXISTS (SELECT 1 FROM public.dispute_lines dl WHERE dl.dispute_id=disputes.id)
  AND NOT EXISTS (SELECT 1 FROM public.physical_receipt_review_dispute_links l WHERE l.dispute_id=disputes.id);

DELETE FROM public.physical_exception_remedy_allocations
WHERE physical_receipt_review_id=:'REVIEW_ID'::uuid;
DELETE FROM public.physical_receipt_reviews WHERE id=:'REVIEW_ID'::uuid;
DELETE FROM public.shipper_package_receipt_evidence
WHERE receipt_id=:'RECEIPT_ID'::uuid AND storage_object_path=:'STORAGE_OBJECT_PATH';
DELETE FROM storage.objects
WHERE bucket_id='invoice-evidence' AND name=:'STORAGE_OBJECT_PATH';
DELETE FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=:'RECEIPT_ID'::uuid;
DELETE FROM public.shipper_package_receipts WHERE id=:'RECEIPT_ID'::uuid;
DELETE FROM public.order_tracking_line_allocations
WHERE order_id=:'ORDER_ID'::uuid AND tracking_submission_id=:'TRACKING_SUBMISSION_ID'::uuid;
DELETE FROM public.order_tracking_submissions WHERE id=:'TRACKING_SUBMISSION_ID'::uuid AND order_id=:'ORDER_ID'::uuid;
DELETE FROM public.supplier_invoice_lines WHERE id=:'SUPPLIER_INVOICE_LINE_ID'::uuid;
DELETE FROM public.supplier_invoices WHERE id=:'SUPPLIER_INVOICE_ID'::uuid AND order_id=:'ORDER_ID'::uuid;
DELETE FROM public.orders WHERE id=:'ORDER_ID'::uuid AND order_ref='PW-PHYSICAL-'||:'RUN_ID';

DO $zero$
DECLARE v_remaining integer;
BEGIN
  SELECT
    (SELECT count(*) FROM public.orders WHERE id=:'ORDER_ID'::uuid OR order_ref='PW-PHYSICAL-'||:'RUN_ID')
    +(SELECT count(*) FROM public.order_tracking_submissions WHERE id=:'TRACKING_SUBMISSION_ID'::uuid)
    +(SELECT count(*) FROM public.shipper_package_receipts WHERE id=:'RECEIPT_ID'::uuid)
    +(SELECT count(*) FROM public.physical_receipt_reviews WHERE id=:'REVIEW_ID'::uuid)
    +(SELECT count(*) FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=:'REVIEW_ID'::uuid)
    +(SELECT count(*) FROM public.physical_receipt_review_dispute_links WHERE physical_receipt_review_id=:'REVIEW_ID'::uuid)
    +(SELECT count(*) FROM public.dispute_lines WHERE dispute_id IN (SELECT dispute_id FROM fixture_disputes))
    +(SELECT count(*) FROM public.disputes WHERE id IN (SELECT dispute_id FROM fixture_disputes))
    +(SELECT count(*) FROM storage.objects WHERE bucket_id='invoice-evidence' AND name=:'STORAGE_OBJECT_PATH')
  INTO v_remaining;
  IF v_remaining<>0 THEN
    RAISE EXCEPTION 'Fixture cleanup left % run-owned rows.', v_remaining;
  END IF;
END
$zero$;

SELECT jsonb_build_object('cleanup','PASS','run_id',:'RUN_ID','remaining_rows',0);
COMMIT;
