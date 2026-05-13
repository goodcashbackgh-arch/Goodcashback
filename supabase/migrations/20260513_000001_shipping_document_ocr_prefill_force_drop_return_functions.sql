BEGIN;

-- Corrective migration for Postgres return-type replacement.
-- The OCR prefill migration extends the RETURNS TABLE shape for these two functions.
-- PostgreSQL cannot replace an existing function with a different OUT-parameter row type,
-- so these must be dropped immediately before rerunning the OCR prefill migration.
DROP FUNCTION IF EXISTS public.internal_shipping_document_worklist_v1();
DROP FUNCTION IF EXISTS public.internal_shipping_document_detail_v1(uuid);

NOTIFY pgrst, 'reload schema';

COMMIT;
