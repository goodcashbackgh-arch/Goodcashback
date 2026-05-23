BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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

  SELECT staff_row.id INTO v_staff_id
  FROM public.staff staff_row
  WHERE staff_row.auth_user_id = auth.uid()
    AND staff_row.active = true
  LIMIT 1;

  RETURN QUERY
  WITH selected_rows AS (
    SELECT DISTINCT trim(raw_queue_id) AS selected_queue_row_id
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) raw_queue_id
    WHERE NULLIF(trim(raw_queue_id), '') IS NOT NULL
  ), wanted_rows AS (
    SELECT
      selected_rows.selected_queue_row_id,
      split_part(selected_rows.selected_queue_row_id, ':', 2)::text AS selected_category,
      NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected_rows
    WHERE split_part(selected_rows.selected_queue_row_id, ':', 1) = 'cash'
      AND NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '') IS NOT NULL
  ), workbench_rows AS (
    SELECT wb.*
    FROM public.internal_cash_posting_workbench_rows_v1('all','all','all',NULL,500,0) wb
    JOIN wanted_rows wanted
      ON wanted.selected_source_id = wb.source_id
     AND wanted.selected_category = wb.category
  ), candidate_rows AS (
    SELECT
      wanted.selected_queue_row_id,
      wb.queue_row_id AS resolved_queue_row_id,
      wb.source_id AS candidate_source_id,
      wb.source_type AS candidate_source_type,
      wb.statement_line_id AS candidate_statement_line_id,
      wb.statement_id AS candidate_statement_id,
      wb.statement_date_text AS candidate_statement_date_text,
      wb.direction AS candidate_direction,
      wb.category AS candidate_category,
      wb.counterparty_type AS candidate_counterparty_type,
      wb.counterparty_id AS candidate_counterparty_id,
      wb.counterparty_name AS candidate_counterparty_name,
      wb.order_id AS candidate_order_id,
      wb.order_ref AS candidate_order_ref,
      wb.auth_ref AS candidate_auth_ref,
      wb.reference_raw AS candidate_reference_raw,
      wb.amount_gbp AS candidate_amount_gbp,
      wb.matched_target_type AS candidate_matched_target_type,
      wb.matched_target_id AS candidate_matched_target_id,
      wb.matched_target_ref AS candidate_matched_target_ref,
      wb.sage_contact_id AS candidate_sage_contact_id,
      wb.sage_contact_name AS candidate_sage_contact_name,
      wb.sage_bank_account_id AS candidate_sage_bank_account_id,
      wb.target_sage_object_id AS candidate_target_sage_object_id,
      wb.posting_status AS candidate_posting_status,
      wb.blocker AS workbench_blocker,
      wb.selectable AS candidate_selectable,
      wb.detail_json AS candidate_detail_json,
      COALESCE(wb.detail_json->>'short_reference',
        CASE
          WHEN wb.direction = 'out' THEN 'GCB-OUT-' || left(COALESCE(wb.matched_target_ref, wb.order_ref, wb.source_id::text), 24)
          ELSE 'GCB-IN-' || left(COALESCE(wb.order_ref, wb.source_id::text), 24)
        END
      )::text AS candidate_short_reference,
      ('cash:' || wb.category || ':' || wb.source_type || ':' || wb.source_id::text)::text AS candidate_idempotency_key,
      existing_snapshot.id AS existing_snapshot_id
    FROM wanted_rows wanted
    LEFT JOIN workbench_rows wb
      ON wb.source_id = wanted.selected_source_id
     AND wb.category = wanted.selected_category
    LEFT JOIN public.cash_posting_snapshots existing_snapshot
      ON existing_snapshot.active = true
     AND existing_snapshot.idempotency_key = ('cash:' || wb.category || ':' || wb.source_type || ':' || wb.source_id::text)
  ), prepared_rows AS (
    SELECT
      candidate_rows.*,
      CASE
        WHEN candidate_rows.candidate_source_id IS NULL THEN 'selected cash row was not found in the workbench read model'
        WHEN candidate_rows.existing_snapshot_id IS NOT NULL THEN 'already frozen'
        WHEN candidate_rows.candidate_category NOT IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') THEN 'cash category is not enabled for freeze/batch yet'
        WHEN candidate_rows.candidate_posting_status <> 'ready_to_freeze' THEN COALESCE(candidate_rows.workbench_blocker, 'cash row is not ready to freeze')
        WHEN candidate_rows.candidate_selectable IS DISTINCT FROM true THEN COALESCE(candidate_rows.workbench_blocker, 'cash row is not selectable')
        WHEN NULLIF(trim(COALESCE(candidate_rows.candidate_sage_bank_account_id, '')), '') IS NULL THEN 'Sage bank account mapping missing'
        WHEN candidate_rows.candidate_category IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') AND NULLIF(trim(COALESCE(candidate_rows.candidate_sage_contact_id, '')), '') IS NULL THEN 'Sage contact mapping missing'
        WHEN candidate_rows.candidate_category IN ('supplier_invoice_payment','shipper_invoice_payment') AND NULLIF(trim(COALESCE(candidate_rows.candidate_target_sage_object_id, '')), '') IS NULL THEN 'matched Sage purchase invoice id missing'
        WHEN candidate_rows.candidate_amount_gbp <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS final_blocker,
      COALESCE(NULLIF(candidate_rows.candidate_statement_date_text, '')::date, CURRENT_DATE) AS candidate_posting_date
    FROM candidate_rows
  ), inserted_snapshots AS (
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
      prepared.candidate_category,
      prepared.candidate_source_type,
      prepared.candidate_source_id,
      prepared.candidate_statement_line_id,
      prepared.candidate_order_id,
      prepared.candidate_order_ref,
      prepared.candidate_counterparty_type,
      prepared.candidate_counterparty_id,
      prepared.candidate_counterparty_name,
      prepared.candidate_sage_contact_id,
      prepared.candidate_sage_contact_name,
      prepared.candidate_sage_bank_account_id,
      prepared.candidate_amount_gbp,
      prepared.candidate_posting_date,
      prepared.candidate_short_reference,
      prepared.candidate_idempotency_key,
      CASE
        WHEN prepared.candidate_category = 'customer_receipt_on_account' THEN jsonb_build_object(
          'endpoint', '/contact_payments',
          'method', 'POST',
          'posting_category', prepared.candidate_category,
          'contact_payment', jsonb_build_object(
            'transaction_type_id', 'CUSTOMER_RECEIPT',
            'contact_id', prepared.candidate_sage_contact_id,
            'bank_account_id', prepared.candidate_sage_bank_account_id,
            'date', prepared.candidate_posting_date::text,
            'total_amount', prepared.candidate_amount_gbp,
            'reference', prepared.candidate_short_reference
          )
        )
        ELSE jsonb_build_object(
          'endpoint', '/purchase_payments',
          'method', 'POST',
          'posting_category', prepared.candidate_category,
          'purchase_payment', jsonb_build_object(
            'contact_id', prepared.candidate_sage_contact_id,
            'bank_account_id', prepared.candidate_sage_bank_account_id,
            'date', prepared.candidate_posting_date::text,
            'total_amount', prepared.candidate_amount_gbp,
            'reference', prepared.candidate_short_reference
          ),
          'allocation_target', jsonb_build_object(
            'endpoint', '/allocations',
            'purchase_invoice_id', prepared.candidate_target_sage_object_id,
            'amount', prepared.candidate_amount_gbp,
            'matched_target_ref', prepared.candidate_matched_target_ref
          )
        )
      END,
      jsonb_build_object(
        'queue_row_id', prepared.resolved_queue_row_id,
        'source_id', prepared.candidate_source_id,
        'source_type', prepared.candidate_source_type,
        'statement_line_id', prepared.candidate_statement_line_id,
        'statement_id', prepared.candidate_statement_id,
        'statement_date_text', prepared.candidate_statement_date_text,
        'direction', prepared.candidate_direction,
        'posting_category', prepared.candidate_category,
        'order_id', prepared.candidate_order_id,
        'order_ref', prepared.candidate_order_ref,
        'auth_ref', prepared.candidate_auth_ref,
        'reference_raw', prepared.candidate_reference_raw,
        'counterparty_type', prepared.candidate_counterparty_type,
        'counterparty_id', prepared.candidate_counterparty_id,
        'counterparty_name', prepared.candidate_counterparty_name,
        'target_sage_contact_id', prepared.candidate_sage_contact_id,
        'target_sage_bank_account_id', prepared.candidate_sage_bank_account_id,
        'matched_target_type', prepared.candidate_matched_target_type,
        'matched_target_id', prepared.candidate_matched_target_id,
        'matched_target_ref', prepared.candidate_matched_target_ref,
        'target_sage_object_id', prepared.candidate_target_sage_object_id,
        'idempotency_key', prepared.candidate_idempotency_key,
        'workbench_detail', prepared.candidate_detail_json
      ),
      'frozen',
      'validated',
      '[]'::jsonb,
      p_notes,
      now(),
      v_staff_id
    FROM prepared_rows prepared
    WHERE prepared.final_blocker IS NULL
    ON CONFLICT (idempotency_key) WHERE active = true DO NOTHING
    RETURNING
      cash_posting_snapshots.id AS inserted_snapshot_id,
      cash_posting_snapshots.source_id AS inserted_source_id,
      cash_posting_snapshots.posting_category AS inserted_posting_category,
      cash_posting_snapshots.validation_status AS inserted_validation_status,
      cash_posting_snapshots.short_reference AS inserted_short_reference,
      cash_posting_snapshots.amount_gbp AS inserted_amount_gbp
  )
  SELECT
    prepared.selected_queue_row_id AS queue_row_id,
    prepared.candidate_source_id AS source_id,
    COALESCE(inserted.inserted_snapshot_id, prepared.existing_snapshot_id) AS snapshot_id,
    CASE
      WHEN prepared.existing_snapshot_id IS NOT NULL THEN 'already_frozen'
      WHEN inserted.inserted_snapshot_id IS NOT NULL THEN 'frozen'
      ELSE 'not_frozen'
    END::text AS freeze_status,
    COALESCE(inserted.inserted_validation_status, CASE WHEN prepared.existing_snapshot_id IS NOT NULL THEN 'validated' ELSE 'not_validated' END)::text AS validation_status,
    CASE WHEN prepared.existing_snapshot_id IS NOT NULL THEN 'already frozen' ELSE prepared.final_blocker END AS blocker,
    COALESCE(inserted.inserted_short_reference, prepared.candidate_short_reference) AS short_reference,
    COALESCE(inserted.inserted_amount_gbp, prepared.candidate_amount_gbp) AS amount_gbp,
    COALESCE(inserted.inserted_posting_category, prepared.candidate_category) AS posting_category
  FROM prepared_rows prepared
  LEFT JOIN inserted_snapshots inserted
    ON inserted.inserted_source_id = prepared.candidate_source_id
   AND inserted.inserted_posting_category = prepared.candidate_category
  ORDER BY prepared.selected_queue_row_id;
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

  SELECT staff_row.id INTO v_staff_id
  FROM public.staff staff_row
  WHERE staff_row.auth_user_id = auth.uid()
    AND staff_row.active = true
  LIMIT 1;

  WITH selected_rows AS (
    SELECT DISTINCT trim(raw_queue_id) AS selected_queue_row_id
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) raw_queue_id
    WHERE NULLIF(trim(raw_queue_id), '') IS NOT NULL
  ), wanted_rows AS (
    SELECT
      selected_rows.selected_queue_row_id,
      split_part(selected_rows.selected_queue_row_id, ':', 2)::text AS selected_category,
      NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected_rows
    WHERE split_part(selected_rows.selected_queue_row_id, ':', 1) = 'cash'
      AND NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '') IS NOT NULL
  ), candidate_rows AS (
    SELECT
      wanted.selected_queue_row_id,
      wanted.selected_category,
      snap.id AS candidate_snapshot_id,
      snap.source_id AS candidate_source_id,
      snap.posting_category AS candidate_posting_category,
      snap.validation_status AS candidate_validation_status,
      snap.sage_posting_status AS candidate_sage_posting_status,
      snap.amount_gbp AS candidate_amount_gbp,
      snap.idempotency_key AS candidate_idempotency_key,
      snap.request_payload AS candidate_request_payload,
      snap.internal_reference_json AS candidate_internal_reference_json,
      existing_row.batch_id AS existing_batch_id,
      existing_batch.batch_ref AS existing_batch_ref,
      existing_batch.batch_status AS existing_batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate this cash row first'
        WHEN snap.posting_category <> wanted.selected_category THEN 'frozen snapshot category does not match selected row'
        WHEN snap.posting_category NOT IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') THEN 'cash category is not enabled for batching yet'
        WHEN snap.validation_status <> 'validated' THEN 'cash snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash snapshot already posted'
        WHEN existing_row.batch_id IS NOT NULL THEN 'already in active cash posting batch'
        ELSE NULL::text
      END AS candidate_blocker
    FROM wanted_rows wanted
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = wanted.selected_source_id
     AND snap.posting_category = wanted.selected_category
    LEFT JOIN public.cash_posting_batch_rows existing_row
      ON existing_row.active = true
     AND existing_row.snapshot_id = snap.id
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing_row.batch_id
     AND existing_batch.active = true
  ), valid_rows AS (
    SELECT * FROM candidate_rows WHERE candidate_blocker IS NULL
  )
  SELECT
    count(*),
    COALESCE(sum(valid_rows.candidate_amount_gbp), 0)::numeric(18,2),
    CASE
      WHEN count(*) = 0 THEN NULL
      WHEN count(DISTINCT valid_rows.candidate_posting_category) = 1 THEN min(valid_rows.candidate_posting_category)
      WHEN bool_and(valid_rows.candidate_posting_category IN ('supplier_invoice_payment','shipper_invoice_payment')) THEN 'out_purchase_payment'
      ELSE 'mixed_cash_posting'
    END
  INTO v_valid_count, v_total_amount, v_batch_category
  FROM valid_rows;

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

    WITH selected_rows AS (
      SELECT DISTINCT trim(raw_queue_id) AS selected_queue_row_id
      FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) raw_queue_id
      WHERE NULLIF(trim(raw_queue_id), '') IS NOT NULL
    ), wanted_rows AS (
      SELECT
        split_part(selected_rows.selected_queue_row_id, ':', 2)::text AS selected_category,
        NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '')::uuid AS selected_source_id
      FROM selected_rows
      WHERE split_part(selected_rows.selected_queue_row_id, ':', 1) = 'cash'
        AND NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '') IS NOT NULL
    ), valid_snapshots AS (
      SELECT snap.*
      FROM wanted_rows wanted
      JOIN public.cash_posting_snapshots snap
        ON snap.active = true
       AND snap.source_id = wanted.selected_source_id
       AND snap.posting_category = wanted.selected_category
       AND snap.validation_status = 'validated'
       AND snap.sage_posting_status <> 'posted'
       AND snap.posting_category IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment')
      LEFT JOIN public.cash_posting_batch_rows existing_row
        ON existing_row.active = true
       AND existing_row.snapshot_id = snap.id
      WHERE existing_row.id IS NULL
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
      valid_snapshots.id,
      valid_snapshots.source_id,
      valid_snapshots.posting_category,
      valid_snapshots.idempotency_key,
      valid_snapshots.amount_gbp,
      'validated',
      'not_posted',
      valid_snapshots.request_payload
    FROM valid_snapshots;
  END IF;

  RETURN QUERY
  WITH selected_rows AS (
    SELECT DISTINCT trim(raw_queue_id) AS selected_queue_row_id
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) raw_queue_id
    WHERE NULLIF(trim(raw_queue_id), '') IS NOT NULL
  ), wanted_rows AS (
    SELECT
      selected_rows.selected_queue_row_id,
      split_part(selected_rows.selected_queue_row_id, ':', 2)::text AS selected_category,
      NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected_rows
    WHERE split_part(selected_rows.selected_queue_row_id, ':', 1) = 'cash'
      AND NULLIF(split_part(selected_rows.selected_queue_row_id, ':', 3), '') IS NOT NULL
  ), candidate_rows AS (
    SELECT
      wanted.selected_queue_row_id,
      snap.id AS candidate_snapshot_id,
      snap.source_id AS candidate_source_id,
      snap.posting_category AS candidate_posting_category,
      snap.validation_status AS candidate_validation_status,
      snap.sage_posting_status AS candidate_sage_posting_status,
      snap.amount_gbp AS candidate_amount_gbp,
      existing_row.batch_id AS existing_batch_id,
      existing_batch.batch_ref AS existing_batch_ref,
      existing_batch.batch_status AS existing_batch_status,
      created_row.batch_id AS created_batch_id,
      created_batch.batch_ref AS created_batch_ref,
      created_batch.batch_status AS created_batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate this cash row first'
        WHEN snap.posting_category <> wanted.selected_category THEN 'frozen snapshot category does not match selected row'
        WHEN snap.posting_category NOT IN ('customer_receipt_on_account','supplier_invoice_payment','shipper_invoice_payment') THEN 'cash category is not enabled for batching yet'
        WHEN snap.validation_status <> 'validated' THEN 'cash snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash snapshot already posted'
        WHEN existing_row.batch_id IS NOT NULL THEN 'already in active cash posting batch'
        ELSE NULL::text
      END AS candidate_blocker
    FROM wanted_rows wanted
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = wanted.selected_source_id
     AND snap.posting_category = wanted.selected_category
    LEFT JOIN public.cash_posting_batch_rows existing_row
      ON existing_row.active = true
     AND existing_row.snapshot_id = snap.id
     AND (v_batch_id IS NULL OR existing_row.batch_id <> v_batch_id)
    LEFT JOIN public.cash_posting_batches existing_batch
      ON existing_batch.id = existing_row.batch_id
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
    candidate_rows.selected_queue_row_id AS queue_row_id,
    candidate_rows.candidate_source_id AS source_id,
    candidate_rows.candidate_snapshot_id AS snapshot_id,
    COALESCE(candidate_rows.created_batch_id, candidate_rows.existing_batch_id) AS batch_id,
    COALESCE(candidate_rows.created_batch_ref, candidate_rows.existing_batch_ref) AS batch_ref,
    COALESCE(candidate_rows.created_batch_status, candidate_rows.existing_batch_status) AS batch_status,
    CASE
      WHEN candidate_rows.created_batch_id IS NOT NULL THEN 'batched_validated'
      WHEN candidate_rows.existing_batch_id IS NOT NULL THEN 'already_batched'
      WHEN candidate_rows.candidate_blocker IS NULL THEN 'not_batched'
      ELSE 'blocked'
    END::text AS row_status,
    candidate_rows.candidate_blocker AS blocker,
    candidate_rows.candidate_amount_gbp AS amount_gbp,
    candidate_rows.candidate_posting_category AS posting_category
  FROM candidate_rows
  ORDER BY candidate_rows.selected_queue_row_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_cash_posting_rows_v2(text[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_create_cash_batch_v2(text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_cash_posting_rows_v2(text[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_create_cash_batch_v2(text[], text) TO authenticated;

COMMENT ON FUNCTION public.internal_freeze_cash_posting_rows_v2(text[], text) IS 'Shared cash freeze/validation RPC for one Cash Posting Workbench. Supports customer IN and supplier/shipper OUT. Column names are fully qualified to avoid PL/pgSQL output-parameter ambiguity. No Sage API call.';
COMMENT ON FUNCTION public.internal_create_cash_batch_v2(text[], text) IS 'Shared cash batch RPC for one Cash Posting Workbench. Supports customer IN and supplier/shipper OUT. Column names are fully qualified to avoid PL/pgSQL output-parameter ambiguity. No Sage API call.';

NOTIFY pgrst, 'reload schema';

COMMIT;
