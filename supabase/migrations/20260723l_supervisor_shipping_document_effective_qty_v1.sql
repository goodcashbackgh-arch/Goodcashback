BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.shipper_shipment_batch_summary_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: shipper_shipment_batch_summary_v1(uuid)';
  END IF;

  IF to_regprocedure('public.internal_shipping_document_worklist_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_shipping_document_worklist_v1()';
  END IF;

  IF to_regprocedure('public.internal_shipping_document_detail_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_shipping_document_detail_v1(uuid)';
  END IF;
END $$;

-- Preserve the complete authenticated supervisor worklist implementation.
-- Only item_qty is replaced by canonical shipment membership quantity.
DO $$
BEGIN
  IF to_regprocedure('public.internal_shipping_document_worklist_v1_base_20260723l()') IS NULL THEN
    ALTER FUNCTION public.internal_shipping_document_worklist_v1()
      RENAME TO internal_shipping_document_worklist_v1_base_20260723l;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_shipping_document_worklist_v1()
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_id uuid,
  shipper_name text,
  importer_id uuid,
  importer_name text,
  document_kind text,
  document_ref text,
  document_date date,
  currency_code text,
  total_amount numeric,
  file_url text,
  ocr_status text,
  review_status text,
  version_no integer,
  created_at timestamptz,
  accepted_at timestamptz,
  reviewed_at timestamptz,
  package_count bigint,
  item_qty numeric,
  open_message_count bigint,
  next_action text,
  ocr_match_status text,
  ocr_match_summary_json jsonb,
  ocr_shipper_name text,
  ocr_reference_text text,
  ocr_document_ref text,
  ocr_document_date date,
  ocr_total_amount numeric,
  mindee_job_id text,
  mindee_inference_id text,
  mindee_error_message text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    w.shipping_document_id,
    w.shipment_batch_id,
    w.booking_ref,
    w.shipper_id,
    w.shipper_name,
    w.importer_id,
    w.importer_name,
    w.document_kind,
    w.document_ref,
    w.document_date,
    w.currency_code,
    w.total_amount,
    w.file_url,
    w.ocr_status,
    w.review_status,
    w.version_no,
    w.created_at,
    w.accepted_at,
    w.reviewed_at,
    w.package_count,
    COALESCE(s.shipment_qty, 0::numeric) AS item_qty,
    w.open_message_count,
    w.next_action,
    w.ocr_match_status,
    w.ocr_match_summary_json,
    w.ocr_shipper_name,
    w.ocr_reference_text,
    w.ocr_document_ref,
    w.ocr_document_date,
    w.ocr_total_amount,
    w.mindee_job_id,
    w.mindee_inference_id,
    w.mindee_error_message
  FROM public.internal_shipping_document_worklist_v1_base_20260723l() w
  LEFT JOIN LATERAL public.shipper_shipment_batch_summary_v1(w.shipment_batch_id) s ON true;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_document_worklist_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_worklist_v1() TO authenticated;

-- Preserve the complete authenticated supervisor document-detail implementation.
-- Only item_qty is replaced by canonical shipment membership quantity.
DO $$
BEGIN
  IF to_regprocedure('public.internal_shipping_document_detail_v1_base_20260723l(uuid)') IS NULL THEN
    ALTER FUNCTION public.internal_shipping_document_detail_v1(uuid)
      RENAME TO internal_shipping_document_detail_v1_base_20260723l;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_shipping_document_detail_v1(
  p_shipping_document_id uuid
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  shipper_name text,
  importer_name text,
  document_kind text,
  document_ref text,
  document_date date,
  currency_code text,
  total_amount numeric,
  file_url text,
  ocr_status text,
  review_status text,
  notes text,
  version_no integer,
  created_at timestamptz,
  accepted_at timestamptz,
  reviewed_at timestamptz,
  review_note text,
  extracted_document_ref text,
  extracted_document_date date,
  extracted_currency_code text,
  extracted_total_amount numeric,
  package_count bigint,
  item_qty numeric,
  ocr_match_status text,
  ocr_match_summary_json jsonb,
  ocr_shipper_name text,
  ocr_reference_text text,
  ocr_document_ref text,
  ocr_document_date date,
  ocr_total_amount numeric,
  mindee_job_id text,
  mindee_inference_id text,
  mindee_error_message text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    d.shipping_document_id,
    d.shipment_batch_id,
    d.booking_ref,
    d.shipper_name,
    d.importer_name,
    d.document_kind,
    d.document_ref,
    d.document_date,
    d.currency_code,
    d.total_amount,
    d.file_url,
    d.ocr_status,
    d.review_status,
    d.notes,
    d.version_no,
    d.created_at,
    d.accepted_at,
    d.reviewed_at,
    d.review_note,
    d.extracted_document_ref,
    d.extracted_document_date,
    d.extracted_currency_code,
    d.extracted_total_amount,
    d.package_count,
    COALESCE(s.shipment_qty, 0::numeric) AS item_qty,
    d.ocr_match_status,
    d.ocr_match_summary_json,
    d.ocr_shipper_name,
    d.ocr_reference_text,
    d.ocr_document_ref,
    d.ocr_document_date,
    d.ocr_total_amount,
    d.mindee_job_id,
    d.mindee_inference_id,
    d.mindee_error_message
  FROM public.internal_shipping_document_detail_v1_base_20260723l(p_shipping_document_id) d
  LEFT JOIN LATERAL public.shipper_shipment_batch_summary_v1(d.shipment_batch_id) s ON true;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_document_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_document_detail_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.internal_shipping_document_worklist_v1() IS
'Supervisor shipping-document worklist. Existing status/OCR/next-action fields are preserved; item_qty uses canonical shipment membership.';

COMMENT ON FUNCTION public.internal_shipping_document_detail_v1(uuid) IS
'Supervisor shipping-document detail. Existing status/OCR/review fields are preserved; item_qty uses canonical shipment membership.';

NOTIFY pgrst, 'reload schema';

COMMIT;
