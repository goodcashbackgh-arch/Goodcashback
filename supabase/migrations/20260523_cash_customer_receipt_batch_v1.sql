BEGIN;

-- Cash Posting Workbench: customer/importer IN batch layer.
-- Additive only. Creates controlled batches from frozen validated customer receipt snapshots.
-- No Sage API call.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_snapshots. Run 20260523_cash_customer_receipt_freeze_v1.sql first.';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.cash_posting_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  active boolean NOT NULL DEFAULT true,
  batch_ref text NOT NULL,
  posting_category text NOT NULL,
  batch_status text NOT NULL DEFAULT 'validated',
  row_count integer NOT NULL DEFAULT 0,
  total_amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  notes text,
  created_by_staff_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.cash_posting_batch_rows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  active boolean NOT NULL DEFAULT true,
  batch_id uuid NOT NULL REFERENCES public.cash_posting_batches(id) ON DELETE CASCADE,
  snapshot_id uuid NOT NULL REFERENCES public.cash_posting_snapshots(id) ON DELETE RESTRICT,
  source_id uuid NOT NULL,
  posting_category text NOT NULL,
  idempotency_key text NOT NULL,
  amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  validation_status text NOT NULL DEFAULT 'validated',
  posting_status text NOT NULL DEFAULT 'not_posted',
  blocker text,
  request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  response_payload jsonb,
  sage_object_id text,
  sage_payment_on_account_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_posting_batches_batch_ref
  ON public.cash_posting_batches(batch_ref)
  WHERE active = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_posting_batch_rows_active_snapshot
  ON public.cash_posting_batch_rows(snapshot_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS ix_cash_posting_batch_rows_batch
  ON public.cash_posting_batch_rows(batch_id)
  WHERE active = true;

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
    SELECT DISTINCT unnest(COALESCE(p_source_ids, ARRAY[]::uuid[])) AS source_id
  ), candidates AS (
    SELECT
      sel.source_id AS selected_source_id,
      snap.id AS snapshot_id,
      snap.source_id,
      snap.posting_category,
      snap.validation_status,
      snap.sage_posting_status,
      snap.amount_gbp,
      snap.idempotency_key,
      snap.request_payload,
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
      END AS blocker
    FROM selected sel
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = sel.source_id
     AND snap.posting_category = 'customer_receipt_on_account'
    LEFT JOIN public.cash_posting_batch_rows existing
      ON existing.active = true
     AND existing.snapshot_id = snap.id
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing.batch_id
     AND existing_batch.active = true
  )
  SELECT count(*), COALESCE(sum(amount_gbp), 0)::numeric(18,2)
  INTO v_valid_count, v_total_amount
  FROM candidates
  WHERE blocker IS NULL;

  IF v_valid_count > 0 THEN
    v_batch_ref := 'CPB-' || floor(extract(epoch from clock_timestamp()))::bigint::text;

    INSERT INTO public.cash_posting_batches (
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
    RETURNING id INTO v_batch_id;

    WITH selected AS (
      SELECT DISTINCT unnest(COALESCE(p_source_ids, ARRAY[]::uuid[])) AS source_id
    ), valid_snapshots AS (
      SELECT snap.*
      FROM selected sel
      JOIN public.cash_posting_snapshots snap
        ON snap.active = true
       AND snap.source_id = sel.source_id
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
      vs.id,
      vs.source_id,
      vs.posting_category,
      vs.idempotency_key,
      vs.amount_gbp,
      'validated',
      'not_posted',
      vs.request_payload
    FROM valid_snapshots vs;
  END IF;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT unnest(COALESCE(p_source_ids, ARRAY[]::uuid[])) AS source_id
  ), candidates AS (
    SELECT
      sel.source_id AS selected_source_id,
      snap.id AS snapshot_id,
      snap.source_id,
      snap.posting_category,
      snap.validation_status,
      snap.sage_posting_status,
      snap.amount_gbp,
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
      END AS blocker
    FROM selected sel
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = sel.source_id
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
    c.snapshot_id,
    COALESCE(c.created_batch_id, c.existing_batch_id) AS batch_id,
    COALESCE(c.created_batch_ref, c.existing_batch_ref) AS batch_ref,
    COALESCE(c.created_batch_status, c.existing_batch_status) AS batch_status,
    CASE
      WHEN c.created_batch_id IS NOT NULL THEN 'batched_validated'
      WHEN c.existing_batch_id IS NOT NULL THEN 'already_batched'
      WHEN c.blocker IS NULL THEN 'not_batched'
      ELSE 'blocked'
    END::text AS row_status,
    c.blocker,
    c.amount_gbp
  FROM candidates c
  ORDER BY c.selected_source_id::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_cash_posting_batch_status_by_source_v1(
  p_source_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
RETURNS TABLE (
  source_id uuid,
  snapshot_id uuid,
  batch_id uuid,
  batch_ref text,
  batch_status text,
  batch_row_status text,
  amount_gbp numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required.';
  END IF;

  RETURN QUERY
  SELECT
    s.source_id,
    s.id AS snapshot_id,
    b.id AS batch_id,
    b.batch_ref,
    b.batch_status,
    r.posting_status AS batch_row_status,
    r.amount_gbp
  FROM public.cash_posting_snapshots s
  JOIN public.cash_posting_batch_rows r
    ON r.snapshot_id = s.id
   AND r.active = true
  JOIN public.cash_posting_batches b
    ON b.id = r.batch_id
   AND b.active = true
  WHERE s.active = true
    AND (COALESCE(array_length(p_source_ids, 1), 0) = 0 OR s.source_id = ANY(p_source_ids));
END;
$$;

REVOKE ALL ON FUNCTION public.internal_create_customer_receipt_cash_batch_v1(uuid[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_cash_posting_batch_status_by_source_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_create_customer_receipt_cash_batch_v1(uuid[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_batch_status_by_source_v1(uuid[]) TO authenticated;

COMMENT ON TABLE public.cash_posting_batches IS 'Controlled cash posting batches. Batch creation validates frozen snapshots but does not call Sage.';
COMMENT ON TABLE public.cash_posting_batch_rows IS 'Rows inside controlled cash posting batches, one row per frozen cash snapshot.';
COMMENT ON FUNCTION public.internal_create_customer_receipt_cash_batch_v1(uuid[], text) IS 'Create a validated customer/importer IN cash posting batch from frozen validated cash snapshots. No Sage API call.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- Smoke checks:
-- select * from public.internal_create_customer_receipt_cash_batch_v1(ARRAY['00000000-0000-0000-0000-000000000000']::uuid[], 'smoke');
-- select * from public.internal_cash_posting_batch_status_by_source_v1(ARRAY[]::uuid[]);
