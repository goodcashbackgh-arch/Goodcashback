BEGIN;

-- Fix supplier_credit_note freeze RPC PL/pgSQL ambiguity.
-- The RPC RETURNS TABLE includes an output column named idempotency_key.
-- In PL/pgSQL, unqualified ON CONFLICT/RETURNING references to idempotency_key can collide with that output variable.
-- This mirrors the earlier customer_sales and shipper_ap ambiguity fixes: use the explicit unique constraint and qualified RETURNING columns.
-- No Sage API call. No posting. No schema widening.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid;
  v_sql text;
  v_original_sql text;
BEGIN
  v_oid := to_regprocedure('public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text) missing';
  END IF;

  v_sql := pg_get_functiondef(v_oid);
  v_original_sql := v_sql;

  IF position('ON CONFLICT (idempotency_key) DO UPDATE' in v_sql) > 0 THEN
    v_sql := replace(
      v_sql,
      'ON CONFLICT (idempotency_key) DO UPDATE',
      'ON CONFLICT ON CONSTRAINT sage_posting_snapshots_idempotency_key_key DO UPDATE'
    );
  END IF;

  IF position('RETURNING id, source_id, order_ref, amount_gbp, idempotency_key' in v_sql) > 0 THEN
    v_sql := replace(
      v_sql,
      'RETURNING id, source_id, order_ref, amount_gbp, idempotency_key',
      'RETURNING public.sage_posting_snapshots.id, public.sage_posting_snapshots.source_id, public.sage_posting_snapshots.order_ref, public.sage_posting_snapshots.amount_gbp, public.sage_posting_snapshots.idempotency_key'
    );
  END IF;

  IF v_sql = v_original_sql THEN
    RAISE NOTICE 'supplier credit note freeze RPC already appears patched; no replacement applied';
  ELSE
    EXECUTE v_sql;
  END IF;
END
$patch$;

NOTIFY pgrst, 'reload schema';
COMMIT;
