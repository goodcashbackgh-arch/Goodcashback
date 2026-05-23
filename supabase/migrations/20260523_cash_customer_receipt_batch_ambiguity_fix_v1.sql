BEGIN;

-- Fix: internal_create_customer_receipt_cash_batch_v1 can fail with
-- column reference "amount_gbp" is ambiguous after a row is already frozen.
-- Root cause: RETURNS TABLE output names conflict with unqualified CTE column names in PL/pgSQL.
-- This replaces the batch RPC using internal aliases and qualified columns throughout.
-- No table/data/UI/Sage changes. No Sage API call.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_create_customer_receipt_cash_batch_v1(
  p_source_ids uuid[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  source_id uuid,
  snapshot_id uuid,
  batch_id uuid,
  batch_ref text,
  batch_status text,
  row_status text,
  blocker text,
  amount_gbp numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_batch_id uuid;
  v_batch_ref text;
  v_valid_count integer := 0;
  v_total_amount numeric(18,2) := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  WITH selected AS (
    SELECT DISTINCT unnest(COALESCE(p_source_ids, ARRAY[]::uuid[])) AS selected_source_id
  ), candidates AS (
    SELECT
      sel.selected_source_id,
      snap.id AS cand_snapshot_id,
      snap.source_id AS cand_source_id,
      snap.posting_category AS cand_posting_category,
      snap.validation_status AS cand_validation_status,
      snap.sage_posting_status AS cand_sage_posting_status,
      snap.amount_gbp AS cand_amount_gbp,
      snap.idempotency_key AS cand_idempotency_key,
      snap.request_payload AS cand_request_payload,
      existing.batch_id AS existing_batch_id,
      existing_batch.batch_ref AS existing_batch_ref,
      existing_batch.batch_status AS existing_batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate customer IN row first'
        WHEN snap.posting_category <> 'customer_receipt_on_account' THEN 'only customer/importer IN receipts can enter this batch'
        WHEN snap.validation_status <> 'validated' THEN 'cash snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash snapshot already posted'
        WHEN existing.batch_id IS NOT NULL THEN 'already in active cash posting batch'
        ELSE NULL::text
      END AS cand_blocker
    FROM selected sel
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = sel.selected_source_id
     AND snap.posting_category = 'customer_receipt_on_account'
    LEFT JOIN public.cash_posting_batch_rows existing
      ON existing.active = true
     AND existing.snapshot_id = snap.id
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing.batch_id
     AND existing_batch.active = true
  )
  SELECT count(*), COALESCE(sum(c.cand_amount_gbp), 0)::numeric(18,2)
  INTO v_valid_count, v_total_amount
  FROM candidates c
  WHERE c.cand_blocker IS NULL;

  IF v_valid_count > 0 THEN
    v_batch_ref := 'CPB-' || floor(extract(epoch from clock_timestamp()))::bigint::text;

    INSERT INTO public.cash_posting_batches AS cpb (
      batch_ref,
      posting_category,
      batch_status,
      row_count,
      total_amount_gbp,
      notes,
      created_by_staff_id
    )
    VALUES (
      v_batch_ref,
      'customer_receipt_on_account',
      'validated',
      v_valid_count,
      v_total_amount,
      p_notes,
      v_staff_id
    )
    RETURNING cpb.id INTO v_batch_id;

    WITH selected AS (
      SELECT DISTINCT unnest(COALESCE(p_source_ids, ARRAY[]::uuid[])) AS selected_source_id
    ), valid_snapshots AS (
      SELECT
        snap.id AS vs_snapshot_id,
        snap.source_id AS vs_source_id,
        snap.posting_category AS vs_posting_category,
        snap.idempotency_key AS vs_idempotency_key,
        snap.amount_gbp AS vs_amount_gbp,
        snap.request_payload AS vs_request_payload
      FROM selected sel
      JOIN public.cash_posting_snapshots snap
        ON snap.active = true
       AND snap.source_id = sel.selected_source_id
       AND snap.posting_category = 'customer_receipt_on_account'
       AND snap.validation_status = 'validated'
       AND snap.sage_posting_status <> 'posted'
      LEFT JOIN public.cash_posting_batch_rows existing
        ON existing.active = true
       AND existing.snapshot_id = snap.id
      WHERE existing.id IS NULL
    )
    INSERT INTO public.cash_posting_batch_rows (
      batch_id,
      snapshot_id,
      source_id,
      posting_category,
      idempotency_key,
      amount_gbp,
      validation_status,
      posting_status,
      request_payload
    )
    SELECT
      v_batch_id,
      vs.vs_snapshot_id,
      vs.vs_source_id,
      vs.vs_posting_category,
      vs.vs_idempotency_key,
      vs.vs_amount_gbp,
      'validated',
      'not_posted',
      vs.vs_request_payload
    FROM valid_snapshots vs;
  END IF;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT unnest(COALESCE(p_source_ids, ARRAY[]::uuid[])) AS selected_source_id
  ), candidates AS (
    SELECT
      sel.selected_source_id,
      snap.id AS cand_snapshot_id,
      snap.source_id AS cand_source_id,
      snap.posting_category AS cand_posting_category,
      snap.validation_status AS cand_validation_status,
      snap.sage_posting_status AS cand_sage_posting_status,
      snap.amount_gbp AS cand_amount_gbp,
      existing.batch_id AS existing_batch_id,
      existing_batch.batch_ref AS existing_batch_ref,
      existing_batch.batch_status AS existing_batch_status,
      created_row.batch_id AS created_batch_id,
      created_batch.batch_ref AS created_batch_ref,
      created_batch.batch_status AS created_batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate customer IN row first'
        WHEN snap.posting_category <> 'customer_receipt_on_account' THEN 'only customer/importer IN receipts can enter this batch'
        WHEN snap.validation_status <> 'validated' THEN 'cash snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash snapshot already posted'
        WHEN existing.batch_id IS NOT NULL THEN 'already in active cash posting batch'
        ELSE NULL::text
      END AS cand_blocker
    FROM selected sel
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = sel.selected_source_id
     AND snap.posting_category = 'customer_receipt_on_account'
    LEFT JOIN public.cash_posting_batch_rows existing
      ON existing.active = true
     AND existing.snapshot_id = snap.id
     AND (v_batch_id IS NULL OR existing.batch_id <> v_batch_id)
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing.batch_id
     AND existing_batch.active = true
    LEFT JOIN public.cash_posting_batch_rows created_row
      ON created_row.active = true
     AND created_row.snapshot_id = snap.id
     AND created_row.batch_id = v_batch_id
    LEFT JOIN public.cash_posting_batches created_batch
      ON created_batch.id = created_row.batch_id
     AND created_batch.active = true
  )
  SELECT
    c.selected_source_id AS source_id,
    c.cand_snapshot_id AS snapshot_id,
    COALESCE(c.created_batch_id, c.existing_batch_id) AS batch_id,
    COALESCE(c.created_batch_ref, c.existing_batch_ref) AS batch_ref,
    COALESCE(c.created_batch_status, c.existing_batch_status) AS batch_status,
    CASE
      WHEN c.created_batch_id IS NOT NULL THEN 'batched_validated'
      WHEN c.existing_batch_id IS NOT NULL THEN 'already_batched'
      WHEN c.cand_blocker IS NULL THEN 'not_batched'
      ELSE 'blocked'
    END::text AS row_status,
    c.cand_blocker AS blocker,
    c.cand_amount_gbp AS amount_gbp
  FROM candidates c
  ORDER BY c.selected_source_id::text;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_customer_receipt_cash_batch_v1(uuid[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_create_customer_receipt_cash_batch_v1(uuid[], text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
