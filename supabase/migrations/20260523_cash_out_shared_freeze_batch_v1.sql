BEGIN;

-- Shared cash freeze/batch layer for the single Cash Posting Workbench.
-- Supports customer IN and supplier/shipper OUT rows through one set of RPCs.
-- No Sage API call here.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_snapshots. Run cash customer receipt freeze migration first.';
  END IF;
  IF to_regclass('public.cash_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Missing public.cash_posting_batches. Run cash customer receipt batch migration first.';
  END IF;
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_cash_posting_workbench_rows_v1';
  END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_freeze_cash_posting_rows_v2(
  p_queue_row_ids text[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  queue_row_id text,
  source_id uuid,
  snapshot_id uuid,
  freeze_status text,
  validation_status text,
  blocker text,
  short_reference text,
  amount_gbp numeric,
  posting_category text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
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

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT trim(x) AS queue_row_id
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x
    WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT
      s.queue_row_id,
      split_part(s.queue_row_id, ':', 2)::text AS selected_category,
      NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected s
    WHERE split_part(s.queue_row_id, ':', 1) = 'cash'
      AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
  ), workbench AS (
    SELECT w.*
    FROM public.internal_cash_posting_workbench_rows_v1('all','all','all',NULL,500,0) w
    JOIN wanted x
      ON x.selected_source_id = w.source_id
     AND x.selected_category = w.category
  ), candidate AS (
    SELECT
      x.queue_row_id AS selected_queue_row_id,
      w.queue_row_id AS resolved_queue_row_id,
      w.source_id,
      w.source_type,
      w.statement_line_id,
      w.statement_id,
      w.statement_date_text,
      w.direction,
      w.category,
      w.counterparty_type,
      w.counterparty_id,
      w.counterparty_name,
      w.order_id,
      w.order_ref,
      w.auth_ref,
      w.reference_raw,
      w.amount_gbp,
      w.matched_target_type,
      w.matched_target_id,
      w.matched_target_ref,
      w.sage_contact_id,
      w.sage_contact_name,
      w.sage_bank_account_id,
      w.target_sage_object_id,
      w.posting_status,
      w.blocker AS workbench_blocker,
      w.selectable,
      w.detail_json,
      COALESCE(w.detail_json->>'short_reference',
        CASE
          WHEN w.direction = 'out' THEN 'GCB-OUT-' || left(COALESCE(w.matched_target_ref, w.order_ref, w.source_id::text), 24)
          ELSE 'GCB-IN-' || left(COALESCE(w.order_ref, w.source_id::text), 24)
        END
      )::text AS short_reference,
      ('cash:' || w.category || ':' || w.source_type || ':' || w.source_id::text)::text AS idempotency_key,
      existing.id AS existing_snapshot_id
    FROM wanted x
    LEFT JOIN workbench w
      ON w.source_id = x.selected_source_id
     AND w.category = x.selected_category
    LEFT JOIN public.cash_posting_snapshots existing
      ON existing.active = true
     AND existing.idempotency_key = ('cash:' || w.category || ':' || w.source_type || ':' || w.source_id::text)
  ), prepared AS (
    SELECT
      c.*,
      CASE
        WHEN c.source_id IS NULL THEN 'selected cash row was not found in the workbench read model'
        WHEN c.existing_snapshot_id IS NOT NULL THEN 'already frozen'
        WHEN c.category NOT IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') THEN 'cash category is not enabled for freeze/batch yet'
        WHEN c.posting_status <> 'ready_to_freeze' THEN COALESCE(c.workbench_blocker, 'cash row is not ready to freeze')
        WHEN c.selectable IS DISTINCT FROM true THEN COALESCE(c.workbench_blocker, 'cash row is not selectable')
        WHEN NULLIF(trim(COALESCE(c.sage_bank_account_id, '')), '') IS NULL THEN 'Sage bank account mapping missing'
        WHEN c.category IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') AND NULLIF(trim(COALESCE(c.sage_contact_id, '')), '') IS NULL THEN 'Sage contact mapping missing'
        WHEN c.category IN ('supplier_invoice_payment','shipper_invoice_payment') AND NULLIF(trim(COALESCE(c.target_sage_object_id, '')), '') IS NULL THEN 'matched Sage purchase invoice id missing'
        WHEN c.amount_gbp <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS final_blocker,
      COALESCE(NULLIF(c.statement_date_text, '')::date, CURRENT_DATE) AS posting_date
    FROM candidate c
  ), inserted AS (
    INSERT INTO public.cash_posting_snapshots (
      posting_category,
      source_type,
      source_id,
      statement_line_id,
      order_id,
      order_ref,
      counterparty_type,
      counterparty_id,
      counterparty_name,
      sage_contact_id,
      sage_contact_name,
      sage_bank_account_id,
      amount_gbp,
      posting_date,
      short_reference,
      idempotency_key,
      request_payload,
      internal_reference_json,
      freeze_status,
      validation_status,
      validation_errors,
      notes,
      validated_at,
      created_by_staff_id
    )
    SELECT
      p.category,
      p.source_type,
      p.source_id,
      p.statement_line_id,
      p.order_id,
      p.order_ref,
      p.counterparty_type,
      p.counterparty_id,
      p.counterparty_name,
      p.sage_contact_id,
      p.sage_contact_name,
      p.sage_bank_account_id,
      p.amount_gbp,
      p.posting_date,
      p.short_reference,
      p.idempotency_key,
      CASE
        WHEN p.category = 'customer_receipt_on_account' THEN jsonb_build_object(
          'endpoint', '/contact_payments',
          'method', 'POST',
          'posting_category', p.category,
          'contact_payment', jsonb_build_object(
            'transaction_type_id', 'CUSTOMER_RECEIPT',
            'contact_id', p.sage_contact_id,
            'bank_account_id', p.sage_bank_account_id,
            'date', p.posting_date::text,
            'total_amount', p.amount_gbp,
            'reference', p.short_reference
          )
        )
        ELSE jsonb_build_object(
          'endpoint', '/purchase_payments',
          'method', 'POST',
          'posting_category', p.category,
          'purchase_payment', jsonb_build_object(
            'contact_id', p.sage_contact_id,
            'bank_account_id', p.sage_bank_account_id,
            'date', p.posting_date::text,
            'total_amount', p.amount_gbp,
            'reference', p.short_reference
          ),
          'allocation_target', jsonb_build_object(
            'endpoint', '/allocations',
            'purchase_invoice_id', p.target_sage_object_id,
            'amount', p.amount_gbp,
            'matched_target_ref', p.matched_target_ref
          )
        )
      END,
      jsonb_build_object(
        'queue_row_id', p.resolved_queue_row_id,
        'source_id', p.source_id,
        'source_type', p.source_type,
        'statement_line_id', p.statement_line_id,
        'statement_id', p.statement_id,
        'statement_date_text', p.statement_date_text,
        'direction', p.direction,
        'posting_category', p.category,
        'order_id', p.order_id,
        'order_ref', p.order_ref,
        'auth_ref', p.auth_ref,
        'reference_raw', p.reference_raw,
        'counterparty_type', p.counterparty_type,
        'counterparty_id', p.counterparty_id,
        'counterparty_name', p.counterparty_name,
        'target_sage_contact_id', p.sage_contact_id,
        'target_sage_bank_account_id', p.sage_bank_account_id,
        'matched_target_type', p.matched_target_type,
        'matched_target_id', p.matched_target_id,
        'matched_target_ref', p.matched_target_ref,
        'target_sage_object_id', p.target_sage_object_id,
        'idempotency_key', p.idempotency_key,
        'workbench_detail', p.detail_json
      ),
      'frozen',
      'validated',
      '[]'::jsonb,
      p_notes,
      now(),
      v_staff_id
    FROM prepared p
    WHERE p.final_blocker IS NULL
    ON CONFLICT (idempotency_key) WHERE active = true DO NOTHING
    RETURNING id, source_id, posting_category, validation_status, short_reference, amount_gbp
  )
  SELECT
    p.selected_queue_row_id AS queue_row_id,
    p.source_id,
    COALESCE(i.id, p.existing_snapshot_id) AS snapshot_id,
    CASE
      WHEN p.existing_snapshot_id IS NOT NULL THEN 'already_frozen'
      WHEN i.id IS NOT NULL THEN 'frozen'
      ELSE 'not_frozen'
    END::text AS freeze_status,
    COALESCE(i.validation_status, CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'validated' ELSE 'not_validated' END)::text AS validation_status,
    CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'already frozen' ELSE p.final_blocker END AS blocker,
    COALESCE(i.short_reference, p.short_reference) AS short_reference,
    COALESCE(i.amount_gbp, p.amount_gbp) AS amount_gbp,
    COALESCE(i.posting_category, p.category) AS posting_category
  FROM prepared p
  LEFT JOIN inserted i
    ON i.source_id = p.source_id
   AND i.posting_category = p.category
  ORDER BY p.selected_queue_row_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_create_cash_batch_v2(
  p_queue_row_ids text[],
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  queue_row_id text,
  source_id uuid,
  snapshot_id uuid,
  batch_id uuid,
  batch_ref text,
  batch_status text,
  row_status text,
  blocker text,
  amount_gbp numeric,
  posting_category text
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
  v_batch_category text := NULL;
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
    SELECT DISTINCT trim(x) AS queue_row_id
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x
    WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT
      s.queue_row_id,
      split_part(s.queue_row_id, ':', 2)::text AS selected_category,
      NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected s
    WHERE split_part(s.queue_row_id, ':', 1) = 'cash'
      AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
  ), candidates AS (
    SELECT
      w.queue_row_id,
      w.selected_category,
      snap.id AS snapshot_id,
      snap.source_id,
      snap.posting_category,
      snap.validation_status,
      snap.sage_posting_status,
      snap.amount_gbp,
      snap.idempotency_key,
      snap.request_payload,
      snap.internal_reference_json,
      existing.batch_id AS existing_batch_id,
      existing_batch.batch_ref AS existing_batch_ref,
      existing_batch.batch_status AS existing_batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate this cash row first'
        WHEN snap.posting_category <> w.selected_category THEN 'frozen snapshot category does not match selected row'
        WHEN snap.posting_category NOT IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') THEN 'cash category is not enabled for batching yet'
        WHEN snap.validation_status <> 'validated' THEN 'cash snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash snapshot already posted'
        WHEN existing.batch_id IS NOT NULL THEN 'already in active cash posting batch'
        ELSE NULL::text
      END AS blocker
    FROM wanted w
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = w.selected_source_id
     AND snap.posting_category = w.selected_category
    LEFT JOIN public.cash_posting_batch_rows existing
      ON existing.active = true
     AND existing.snapshot_id = snap.id
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing.batch_id
     AND existing_batch.active = true
  ), valid AS (
    SELECT * FROM candidates WHERE blocker IS NULL
  )
  SELECT
    count(*),
    COALESCE(sum(amount_gbp), 0)::numeric(18,2),
    CASE
      WHEN count(*) = 0 THEN NULL
      WHEN count(DISTINCT posting_category) = 1 THEN min(posting_category)
      WHEN bool_and(posting_category IN ('supplier_invoice_payment','shipper_invoice_payment')) THEN 'out_purchase_payment'
      ELSE 'mixed_cash_posting'
    END
  INTO v_valid_count, v_total_amount, v_batch_category
  FROM valid;

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
      COALESCE(v_batch_category, 'cash_posting'),
      'validated',
      v_valid_count,
      v_total_amount,
      p_notes,
      v_staff_id
    )
    RETURNING id INTO v_batch_id;

    WITH selected AS (
      SELECT DISTINCT trim(x) AS queue_row_id
      FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x
      WHERE NULLIF(trim(x), '') IS NOT NULL
    ), wanted AS (
      SELECT
        split_part(s.queue_row_id, ':', 2)::text AS selected_category,
        NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
      FROM selected s
      WHERE split_part(s.queue_row_id, ':', 1) = 'cash'
        AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
    ), valid_snapshots AS (
      SELECT snap.*
      FROM wanted w
      JOIN public.cash_posting_snapshots snap
        ON snap.active = true
       AND snap.source_id = w.selected_source_id
       AND snap.posting_category = w.selected_category
       AND snap.validation_status = 'validated'
       AND snap.sage_posting_status <> 'posted'
       AND snap.posting_category IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment')
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
    SELECT DISTINCT trim(x) AS queue_row_id
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x
    WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT
      s.queue_row_id,
      split_part(s.queue_row_id, ':', 2)::text AS selected_category,
      NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected s
    WHERE split_part(s.queue_row_id, ':', 1) = 'cash'
      AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
  ), candidates AS (
    SELECT
      w.queue_row_id,
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
        WHEN snap.id IS NULL THEN 'freeze and validate this cash row first'
        WHEN snap.posting_category <> w.selected_category THEN 'frozen snapshot category does not match selected row'
        WHEN snap.posting_category NOT IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') THEN 'cash category is not enabled for batching yet'
        WHEN snap.validation_status <> 'validated' THEN 'cash snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash snapshot already posted'
        WHEN existing.batch_id IS NOT NULL THEN 'already in active cash posting batch'
        ELSE NULL::text
      END AS blocker
    FROM wanted w
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = w.selected_source_id
     AND snap.posting_category = w.selected_category
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
    c.queue_row_id,
    c.source_id,
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
    c.amount_gbp,
    c.posting_category
  FROM candidates c
  ORDER BY c.queue_row_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_cash_posting_rows_v2(text[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_create_cash_batch_v2(text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_cash_posting_rows_v2(text[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_create_cash_batch_v2(text[], text) TO authenticated;

COMMENT ON FUNCTION public.internal_freeze_cash_posting_rows_v2(text[], text) IS 'Shared cash freeze/validation RPC for one Cash Posting Workbench. Supports customer IN and supplier/shipper OUT. No Sage API call.';
COMMENT ON FUNCTION public.internal_create_cash_batch_v2(text[], text) IS 'Shared cash batch RPC for one Cash Posting Workbench. Supports customer IN and supplier/shipper OUT. No Sage API call.';

NOTIFY pgrst, 'reload schema';

COMMIT;
