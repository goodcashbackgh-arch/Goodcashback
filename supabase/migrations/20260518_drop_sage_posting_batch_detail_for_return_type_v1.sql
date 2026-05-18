BEGIN;

-- Required because PostgreSQL cannot CREATE OR REPLACE a function when the
-- RETURNS TABLE shape changes. This drops only the RPC wrapper, not any data.
-- Run before 20260518_supplier_goods_ap_batch_detail_vat_evidence_v1.sql.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DROP FUNCTION IF EXISTS public.internal_sage_posting_batch_detail_v1(uuid);

NOTIFY pgrst, 'reload schema';
COMMIT;
