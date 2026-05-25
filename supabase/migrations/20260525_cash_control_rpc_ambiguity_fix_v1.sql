BEGIN;

-- Fix cash control RPCs where PL/pgSQL output column names such as source_id
-- conflicted with unqualified query column names.
-- No schema change. No Sage API call.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_freeze_cash_control_rows_v1(
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
#variable_conflict use_column
DECLARE
  v_staff_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required.'; END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT trim(x) AS qid
    FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x
    WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT
      selected.qid,
      split_part(selected.qid, ':', 2)::text AS wanted_category,
      NULLIF(split_part(selected.qid, ':', 3), '')::uuid AS wanted_source_id
    FROM selected
    WHERE split_part(selected.qid, ':', 1) = 'cash'
      AND NULLIF(split_part(selected.qid, ':', 3), '') IS NOT NULL
  ), defaults AS (
    SELECT
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'FX_CARD_GAIN_LEDGER' AND sm.is_active = true) AS fx_gain_ledger_id,
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'FX_CARD_LOSS_LEDGER' AND sm.is_active = true) AS fx_loss_ledger_id,
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'BANK_FEE_LEDGER' AND sm.is_active = true) AS bank_fee_ledger_id,
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'UNMATCHED_HOLD_LEDGER' AND sm.is_active = true) AS unmatched_hold_ledger_id
    FROM public.sage_mapping_settings sm
  ), wb AS (
    SELECT w.*
    FROM public.internal_cash_posting_workbench_rows_v1('all','all','all',NULL,5000,0) w
  ), candidate AS (
    SELECT
      wanted.qid AS selected_queue_row_id,
      wb.queue_row_id AS workbench_queue_row_id,
      wb.source_id AS wb_source_id,
      wb.source_type AS wb_source_type,
      wb.statement_line_id AS wb_statement_line_id,
      wb.order_id AS wb_order_id,
      wb.order_ref AS wb_order_ref,
      wb.direction AS wb_direction,
      CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'unmatched_hold' ELSE wb.category END AS normal_category,
      wb.counterparty_type AS wb_counterparty_type,
      wb.counterparty_id AS wb_counterparty_id,
      CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'Unmatched/hold suspense' ELSE wb.counterparty_name END AS wb_counterparty_name,
      wb.amount_gbp AS wb_amount_gbp,
      wb.matched_target_type AS wb_matched_target_type,
      wb.matched_target_id AS wb_matched_target_id,
      wb.matched_target_ref AS wb_matched_target_ref,
      wb.sage_contact_id AS wb_sage_contact_id,
      wb.sage_contact_name AS wb_sage_contact_name,
      wb.sage_bank_account_id AS wb_sage_bank_account_id,
      CASE
        WHEN wb.category = 'bank_fee' THEN defaults.bank_fee_ledger_id
        WHEN wb.category = 'fx_card_difference' AND wb.direction = 'in' THEN defaults.fx_gain_ledger_id
        WHEN wb.category = 'fx_card_difference' THEN defaults.fx_loss_ledger_id
        WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN defaults.unmatched_hold_ledger_id
        ELSE NULL::text
      END AS ledger_account_id,
      CASE
        WHEN wb.category = 'retailer_refund_received' THEN 'GCB-REF-' || left(COALESCE(wb.matched_target_ref, wb.order_ref, wb.source_id::text), 20)
        WHEN wb.category = 'bank_fee' THEN 'GCB-FEE-' || left(COALESCE(wb.reference_raw, wb.source_id::text), 20)
        WHEN wb.category = 'fx_card_difference' THEN 'GCB-FX-' || left(COALESCE(wb.reference_raw, wb.source_id::text), 20)
        ELSE 'GCB-HOLD-' || left(COALESCE(wb.reference_raw, wb.source_id::text), 18)
      END::text AS short_ref,
      CASE WHEN wb.statement_date_text ~ '^\d{4}-\d{2}-\d{2}' THEN left(wb.statement_date_text, 10)::date ELSE CURRENT_DATE END AS post_date,
      ('cash:' || CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'unmatched_hold' ELSE wb.category END || ':' || wb.source_type || ':' || wb.source_id::text)::text AS idem_key,
      wb.detail_json AS wb_detail_json,
      existing.id AS existing_snapshot_id
    FROM wanted
    LEFT JOIN wb
      ON wb.source_id = wanted.wanted_source_id
     AND (wb.category = wanted.wanted_category OR (wanted.wanted_category = 'unmatched_hold' AND wb.category IN ('exception_hold','not_charged_closure','unmatched_hold')))
    CROSS JOIN defaults
    LEFT JOIN public.cash_posting_snapshots existing
      ON existing.active = true
     AND existing.idempotency_key = ('cash:' || CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'unmatched_hold' ELSE wb.category END || ':' || wb.source_type || ':' || wb.source_id::text)
  ), prepared AS (
    SELECT
      candidate.*,
      CASE
        WHEN candidate.wb_source_id IS NULL THEN 'selected cash control row was not found in the workbench read model'
        WHEN candidate.existing_snapshot_id IS NOT NULL THEN 'already frozen'
        WHEN candidate.normal_category NOT IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold') THEN 'selected row is not a control cash category'
        WHEN NULLIF(trim(COALESCE(candidate.wb_sage_bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN candidate.normal_category = 'retailer_refund_received' AND NULLIF(trim(COALESCE(candidate.wb_sage_contact_id, '')), '') IS NULL THEN 'retailer/supplier Sage contact mapping missing'
        WHEN candidate.normal_category IN ('bank_fee','fx_card_difference','unmatched_hold') AND NULLIF(trim(COALESCE(candidate.ledger_account_id, '')), '') IS NULL THEN 'mapped Sage ledger account missing'
        WHEN COALESCE(candidate.wb_amount_gbp, 0) <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS final_blocker
    FROM candidate
  ), inserted AS (
    INSERT INTO public.cash_posting_snapshots (
      posting_category, source_type, source_id, statement_line_id, order_id, order_ref,
      counterparty_type, counterparty_id, counterparty_name, sage_contact_id, sage_contact_name,
      sage_bank_account_id, amount_gbp, posting_date, short_reference, idempotency_key,
      request_payload, internal_reference_json, freeze_status, validation_status, validation_errors,
      notes, validated_at, created_by_staff_id
    )
    SELECT
      prepared.normal_category, prepared.wb_source_type, prepared.wb_source_id, prepared.wb_statement_line_id, prepared.wb_order_id, prepared.wb_order_ref,
      prepared.wb_counterparty_type, prepared.wb_counterparty_id, prepared.wb_counterparty_name, prepared.wb_sage_contact_id, prepared.wb_sage_contact_name,
      prepared.wb_sage_bank_account_id, prepared.wb_amount_gbp, prepared.post_date, prepared.short_ref, prepared.idem_key,
      jsonb_build_object('endpoint','endpoint_prove_required','method','POST','posting_category',prepared.normal_category,'live_posting_status','blocked_endpoint_prove_required'),
      jsonb_build_object('queue_row_id',prepared.workbench_queue_row_id,'source_id',prepared.wb_source_id,'posting_category',prepared.normal_category,'matched_target_type',prepared.wb_matched_target_type,'matched_target_id',prepared.wb_matched_target_id,'matched_target_ref',prepared.wb_matched_target_ref,'target_sage_contact_id',prepared.wb_sage_contact_id,'target_sage_bank_account_id',prepared.wb_sage_bank_account_id,'target_sage_ledger_account_id',prepared.ledger_account_id,'live_posting_status','blocked_endpoint_prove_required','workbench_detail',prepared.wb_detail_json),
      'frozen','validated','[]'::jsonb,p_notes,now(),v_staff_id
    FROM prepared
    WHERE prepared.final_blocker IS NULL
    ON CONFLICT (idempotency_key) WHERE active = true DO NOTHING
    RETURNING cash_posting_snapshots.id AS ins_snapshot_id,
              cash_posting_snapshots.source_id AS ins_source_id,
              cash_posting_snapshots.posting_category AS ins_category,
              cash_posting_snapshots.validation_status AS ins_validation_status,
              cash_posting_snapshots.short_reference AS ins_short_reference,
              cash_posting_snapshots.amount_gbp AS ins_amount_gbp
  )
  SELECT
    prepared.selected_queue_row_id::text,
    prepared.wb_source_id::uuid,
    COALESCE(inserted.ins_snapshot_id, prepared.existing_snapshot_id)::uuid,
    CASE WHEN prepared.existing_snapshot_id IS NOT NULL THEN 'already_frozen' WHEN inserted.ins_snapshot_id IS NOT NULL THEN 'frozen' ELSE 'not_frozen' END::text,
    COALESCE(inserted.ins_validation_status, CASE WHEN prepared.existing_snapshot_id IS NOT NULL THEN 'validated' ELSE 'not_validated' END)::text,
    CASE WHEN prepared.existing_snapshot_id IS NOT NULL THEN 'already frozen' ELSE prepared.final_blocker END::text,
    COALESCE(inserted.ins_short_reference, prepared.short_ref)::text,
    COALESCE(inserted.ins_amount_gbp, prepared.wb_amount_gbp)::numeric,
    COALESCE(inserted.ins_category, prepared.normal_category)::text
  FROM prepared
  LEFT JOIN inserted
    ON inserted.ins_source_id = prepared.wb_source_id
   AND inserted.ins_category = prepared.normal_category
  ORDER BY prepared.selected_queue_row_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_create_cash_control_batch_v1(
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
#variable_conflict use_column
DECLARE
  v_staff_id uuid;
  v_batch_id uuid;
  v_batch_ref text;
  v_batch_category text;
  v_count integer;
  v_total numeric(18,2);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required.'; END IF;
  SELECT s.id INTO v_staff_id FROM public.staff s WHERE s.auth_user_id = auth.uid() AND s.active = true LIMIT 1;

  WITH selected AS (
    SELECT DISTINCT trim(x) AS qid FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT selected.qid, split_part(selected.qid, ':', 2)::text AS wanted_category, NULLIF(split_part(selected.qid, ':', 3), '')::uuid AS wanted_source_id
    FROM selected WHERE split_part(selected.qid, ':', 1) = 'cash' AND NULLIF(split_part(selected.qid, ':', 3), '') IS NOT NULL
  ), snaps AS (
    SELECT wanted.qid, snap.*
    FROM wanted
    JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = wanted.wanted_source_id
     AND snap.posting_category = CASE WHEN wanted.wanted_category IN ('exception_hold','not_charged_closure') THEN 'unmatched_hold' ELSE wanted.wanted_category END
    WHERE snap.posting_category IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold')
      AND snap.validation_status = 'validated'
      AND COALESCE(snap.sage_posting_status, 'not_posted') <> 'posted'
      AND NOT EXISTS (SELECT 1 FROM public.cash_posting_batch_rows br WHERE br.active = true AND br.snapshot_id = snap.id)
  )
  SELECT CASE WHEN count(DISTINCT snaps.posting_category) = 1 THEN min(snaps.posting_category) ELSE 'mixed_cash_control' END,
         count(*), COALESCE(sum(snaps.amount_gbp),0)::numeric(18,2)
  INTO v_batch_category, v_count, v_total
  FROM snaps;

  IF v_count > 0 AND v_batch_category <> 'mixed_cash_control' THEN
    v_batch_ref := 'CPB-' || floor(extract(epoch from clock_timestamp()))::bigint::text;
    INSERT INTO public.cash_posting_batches (batch_ref, posting_category, batch_status, row_count, total_amount_gbp, notes, created_by_staff_id)
    VALUES (v_batch_ref, v_batch_category, 'validated', v_count, v_total, p_notes, v_staff_id)
    RETURNING cash_posting_batches.id INTO v_batch_id;

    WITH selected AS (
      SELECT DISTINCT trim(x) AS qid FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x WHERE NULLIF(trim(x), '') IS NOT NULL
    ), wanted AS (
      SELECT split_part(selected.qid, ':', 2)::text AS wanted_category, NULLIF(split_part(selected.qid, ':', 3), '')::uuid AS wanted_source_id
      FROM selected WHERE split_part(selected.qid, ':', 1) = 'cash' AND NULLIF(split_part(selected.qid, ':', 3), '') IS NOT NULL
    )
    INSERT INTO public.cash_posting_batch_rows (batch_id, snapshot_id, source_id, posting_category, idempotency_key, amount_gbp, validation_status, posting_status, request_payload)
    SELECT v_batch_id, snap.id, snap.source_id, snap.posting_category, snap.idempotency_key, snap.amount_gbp, 'validated', 'blocked_endpoint_prove_required', snap.request_payload
    FROM wanted
    JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = wanted.wanted_source_id
     AND snap.posting_category = CASE WHEN wanted.wanted_category IN ('exception_hold','not_charged_closure') THEN 'unmatched_hold' ELSE wanted.wanted_category END
    WHERE snap.posting_category IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold')
      AND snap.validation_status = 'validated'
      AND COALESCE(snap.sage_posting_status, 'not_posted') <> 'posted'
      AND NOT EXISTS (SELECT 1 FROM public.cash_posting_batch_rows br WHERE br.active = true AND br.snapshot_id = snap.id);
  END IF;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT trim(x) AS qid FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT selected.qid, split_part(selected.qid, ':', 2)::text AS wanted_category, NULLIF(split_part(selected.qid, ':', 3), '')::uuid AS wanted_source_id
    FROM selected WHERE split_part(selected.qid, ':', 1) = 'cash' AND NULLIF(split_part(selected.qid, ':', 3), '') IS NOT NULL
  ), result_rows AS (
    SELECT wanted.qid, snap.id AS snap_id, snap.source_id AS snap_source_id, snap.posting_category AS snap_category, snap.amount_gbp AS snap_amount_gbp, br.batch_id AS row_batch_id, b.batch_ref AS row_batch_ref, b.batch_status AS row_batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate this cash control row first'
        WHEN snap.posting_category NOT IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold') THEN 'selected row is not a cash control category'
        WHEN snap.validation_status <> 'validated' THEN 'cash control snapshot is not validated'
        WHEN COALESCE(snap.sage_posting_status, 'not_posted') = 'posted' THEN 'cash control snapshot already posted'
        WHEN v_batch_category = 'mixed_cash_control' THEN 'mixed control categories cannot be batched together; filter to one category'
        WHEN br.batch_id IS NULL THEN 'cash control batch was not created'
        ELSE NULL::text
      END AS result_blocker
    FROM wanted
    LEFT JOIN public.cash_posting_snapshots snap
      ON snap.active = true
     AND snap.source_id = wanted.wanted_source_id
     AND snap.posting_category = CASE WHEN wanted.wanted_category IN ('exception_hold','not_charged_closure') THEN 'unmatched_hold' ELSE wanted.wanted_category END
    LEFT JOIN public.cash_posting_batch_rows br ON br.active = true AND br.snapshot_id = snap.id
    LEFT JOIN public.cash_posting_batches b ON b.active = true AND b.id = br.batch_id
  )
  SELECT result_rows.qid::text,
         result_rows.snap_source_id::uuid,
         result_rows.snap_id::uuid,
         result_rows.row_batch_id::uuid,
         result_rows.row_batch_ref::text,
         result_rows.row_batch_status::text,
         CASE WHEN result_rows.row_batch_id IS NOT NULL THEN 'batched_validated' ELSE 'blocked' END::text,
         result_rows.result_blocker::text,
         result_rows.snap_amount_gbp::numeric,
         result_rows.snap_category::text
  FROM result_rows
  ORDER BY result_rows.qid;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_freeze_cash_control_rows_v1(text[], text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_create_cash_control_batch_v1(text[], text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_freeze_cash_control_rows_v1(text[], text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_create_cash_control_batch_v1(text[], text) TO authenticated;

COMMENT ON FUNCTION public.internal_freeze_cash_control_rows_v1(text[], text) IS 'Freezes retailer refund, bank fee, FX/card and hold control rows. No Sage API call.';
COMMENT ON FUNCTION public.internal_create_cash_control_batch_v1(text[], text) IS 'Creates control batches for retailer refund, bank fee, FX/card and hold rows. Live posting remains blocked.';

NOTIFY pgrst, 'reload schema';

COMMIT;
