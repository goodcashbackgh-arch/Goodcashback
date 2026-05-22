BEGIN;

-- Fix supplier credit note freeze crash:
-- PL/pgSQL RETURNS TABLE has an output column named idempotency_key, and the
-- INSERT ... RETURNING list used an unqualified idempotency_key column.
-- That makes Postgres treat idempotency_key as ambiguous between the output
-- variable and sage_posting_snapshots.idempotency_key.
--
-- This mirrors the existing customer/supplier AP ambiguity fix pattern.
-- No schema change. No data change. No Sage API call.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid := to_regprocedure('public.internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text)');
  v_sql text;
  v_before text;
  v_after text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'internal_freeze_supplier_credit_note_sage_batch_v1(uuid[], text) missing';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  v_before := $needle$RETURNING id, source_id, order_ref, amount_gbp, idempotency_key
  )
  SELECT
    v_batch_id,
    i.id,
    i.source_id,
    i.order_ref,
    i.amount_gbp,
    'frozen'::text,
    NULL::text,
    i.idempotency_key
  FROM inserted i$needle$;

  v_after := $replacement$RETURNING
      public.sage_posting_snapshots.id AS inserted_snapshot_id,
      public.sage_posting_snapshots.source_id AS inserted_refund_evidence_submission_id,
      public.sage_posting_snapshots.order_ref AS inserted_order_ref,
      public.sage_posting_snapshots.amount_gbp AS inserted_amount_gbp,
      public.sage_posting_snapshots.idempotency_key AS inserted_idempotency_key
  )
  SELECT
    v_batch_id,
    i.inserted_snapshot_id,
    i.inserted_refund_evidence_submission_id,
    i.inserted_order_ref,
    i.inserted_amount_gbp,
    'frozen'::text,
    NULL::text,
    i.inserted_idempotency_key
  FROM inserted i$replacement$;

  IF position(v_after in v_sql) > 0 THEN
    -- Already patched.
    RETURN;
  END IF;

  IF position(v_before in v_sql) = 0 THEN
    RAISE EXCEPTION 'Could not find ambiguous RETURNING block in internal_freeze_supplier_credit_note_sage_batch_v1';
  END IF;

  v_sql := replace(v_sql, v_before, v_after);
  EXECUTE v_sql;
END
$patch$;

NOTIFY pgrst, 'reload schema';
COMMIT;
