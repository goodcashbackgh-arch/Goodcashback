BEGIN;

-- Required because PostgreSQL cannot CREATE OR REPLACE a function when the RETURNS TABLE shape changes.
-- This pre-drop must run before 20260513_shipping_document_ocr_prefill_v1.sql.
DROP FUNCTION IF EXISTS public.internal_shipping_document_worklist_v1();
DROP FUNCTION IF EXISTS public.internal_shipping_document_detail_v1(uuid);

COMMIT;
