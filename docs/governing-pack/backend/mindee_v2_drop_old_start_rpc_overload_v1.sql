-- =============================================================================
-- mindee_v2_drop_old_start_rpc_overload_v1.sql
-- Multi Tenant Platform Build — remove ambiguous old Mindee start RPC overload
--
-- Purpose:
--   Keep only the newer staff_start_mindee_invoice_ocr(uuid, varchar, boolean)
--   function. The old two-argument function conflicts with the newer function
--   because the third argument has a default value, causing RPC ambiguity.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DROP FUNCTION IF EXISTS public.staff_start_mindee_invoice_ocr(uuid, varchar);

COMMIT;

NOTIFY pgrst, 'reload schema';
