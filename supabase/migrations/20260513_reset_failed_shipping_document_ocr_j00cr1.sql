BEGIN;

-- Safe reset for the technical Mindee enqueue validation failure on booking J00CR1 / document J0227666.
-- This does not delete the document and does not touch accepted/apportioned documents.
UPDATE public.shipping_documents sd
SET
  ocr_status = 'not_started',
  review_status = 'needs_supervisor_review',
  mindee_job_id = NULL,
  mindee_inference_id = NULL,
  mindee_error_message = NULL,
  ocr_raw_json = NULL,
  updated_at = now()
FROM public.shipper_shipment_batches b
WHERE b.id = sd.shipment_batch_id
  AND b.booking_ref = 'J00CR1'
  AND sd.document_ref = 'J0227666'
  AND sd.ocr_status = 'failed'
  AND sd.review_status <> 'accepted_current'
  AND sd.active = true;

NOTIFY pgrst, 'reload schema';

COMMIT;
