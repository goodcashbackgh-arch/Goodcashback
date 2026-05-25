BEGIN;

-- Cash residual/refund control RPCs.
-- Reuses the existing cash workbench read model, Sage Mapping, cash snapshots and cash batch tables.
-- No Sage API call. Control rows are batched as blocked_endpoint_prove_required.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_batches') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_batches'; END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_batch_rows'; END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN RAISE EXCEPTION 'Missing sage_mapping_settings'; END IF;
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)') IS NULL THEN RAISE EXCEPTION 'Missing internal_cash_posting_workbench_rows_v1'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing internal_has_accounting_admin_access_v1'; END IF;
END $$;

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
  ), defaults AS (
    SELECT
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'FX_CARD_GAIN_LEDGER' AND is_active = true) AS fx_gain_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'FX_CARD_LOSS_LEDGER' AND is_active = true) AS fx_loss_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'BANK_FEE_LEDGER' AND is_active = true) AS bank_fee_ledger_id,
      MAX(sage_external_id) FILTER (WHERE mapping_code = 'UNMATCHED_HOLD_LEDGER' AND is_active = true) AS unmatched_hold_ledger_id
    FROM public.sage_mapping_settings
  ), wb AS (
    SELECT w.*
    FROM public.internal_cash_posting_workbench_rows_v1('all','all','all',NULL,5000,0) w
  ), candidate AS (
    SELECT
      wanted.queue_row_id AS selected_queue_row_id,
      wb.queue_row_id AS workbench_queue_row_id,
      wb.source_id,
      wb.source_type,
      wb.statement_line_id,
      wb.statement_id,
      wb.statement_date_text,
      wb.direction,
      CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'unmatched_hold' ELSE wb.category END AS category,
      wb.counterparty_type,
      wb.counterparty_id,
      CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'Unmatched/hold suspense' ELSE wb.counterparty_name END AS counterparty_name,
      wb.order_id,
      wb.order_ref,
      wb.auth_ref,
      wb.reference_raw,
      wb.amount_gbp,
      wb.matched_target_type,
      wb.matched_target_id,
      wb.matched_target_ref,
      wb.sage_contact_id,
      wb.sage_contact_name,
      wb.sage_bank_account_id,
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
      END::text AS short_reference,
      CASE WHEN wb.statement_date_text ~ '^\d{4}-\d{2}-\d{2}' THEN left(wb.statement_date_text, 10)::date ELSE CURRENT_DATE END AS posting_date,
      ('cash:' || CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'unmatched_hold' ELSE wb.category END || ':' || wb.source_type || ':' || wb.source_id::text)::text AS idempotency_key,
      wb.detail_json,
      existing.id AS existing_snapshot_id
    FROM wanted
    LEFT JOIN wb
      ON wb.source_id = wanted.selected_source_id
     AND (wb.category = wanted.selected_category OR (wanted.selected_category = 'unmatched_hold' AND wb.category IN ('exception_hold','not_charged_closure','unmatched_hold')))
    CROSS JOIN defaults
    LEFT JOIN public.cash_posting_snapshots existing
      ON existing.active = true
     AND existing.idempotency_key = ('cash:' || CASE WHEN wb.category IN ('exception_hold','not_charged_closure','unmatched_hold') THEN 'unmatched_hold' ELSE wb.category END || ':' || wb.source_type || ':' || wb.source_id::text)
  ), prepared AS (
    SELECT
      c.*,
      CASE
        WHEN c.source_id IS NULL THEN 'selected cash control row was not found in the workbench read model'
        WHEN c.existing_snapshot_id IS NOT NULL THEN 'already frozen'
        WHEN c.category NOT IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold') THEN 'selected row is not a control cash category'
        WHEN NULLIF(trim(COALESCE(c.sage_bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN c.category = 'retailer_refund_received' AND NULLIF(trim(COALESCE(c.sage_contact_id, '')), '') IS NULL THEN 'retailer/supplier Sage contact mapping missing'
        WHEN c.category IN ('bank_fee','fx_card_difference','unmatched_hold') AND NULLIF(trim(COALESCE(c.ledger_account_id, '')), '') IS NULL THEN 'mapped Sage ledger account missing'
        WHEN COALESCE(c.amount_gbp, 0) <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS final_blocker
    FROM candidate c
  ), inserted AS (
    INSERT INTO public.cash_posting_snapshots (
      posting_category, source_type, source_id, statement_line_id, order_id, order_ref,
      counterparty_type, counterparty_id, counterparty_name, sage_contact_id, sage_contact_name,
      sage_bank_account_id, amount_gbp, posting_date, short_reference, idempotency_key,
      request_payload, internal_reference_json, freeze_status, validation_status, validation_errors,
      notes, validated_at, created_by_staff_id
    )
    SELECT
      p.category, p.source_type, p.source_id, p.statement_line_id, p.order_id, p.order_ref,
      p.counterparty_type, p.counterparty_id, p.counterparty_name, p.sage_contact_id, p.sage_contact_name,
      p.sage_bank_account_id, p.amount_gbp, p.posting_date, p.short_reference, p.idempotency_key,
      CASE WHEN p.category = 'retailer_refund_received' THEN
        jsonb_build_object('endpoint','endpoint_prove_required','method','POST','posting_category',p.category,'live_posting_status','blocked_endpoint_prove_required','supplier_refund_candidate',jsonb_build_object('contact_id',p.sage_contact_id,'bank_account_id',p.sage_bank_account_id,'date',p.posting_date::text,'total_amount',p.amount_gbp,'reference',p.short_reference,'matched_target_ref',p.matched_target_ref))
      ELSE
        jsonb_build_object('endpoint','bank_to_gl_endpoint_prove_required','method','POST','posting_category',p.category,'live_posting_status','blocked_endpoint_prove_required','bank_to_gl',jsonb_build_object('bank_account_id',p.sage_bank_account_id,'ledger_account_id',p.ledger_account_id,'date',p.posting_date::text,'total_amount',p.amount_gbp,'reference',p.short_reference,'direction',p.direction,'matched_target_ref',p.matched_target_ref))
      END,
      jsonb_build_object('queue_row_id',p.workbench_queue_row_id,'source_id',p.source_id,'source_type',p.source_type,'statement_line_id',p.statement_line_id,'statement_id',p.statement_id,'statement_date_text',p.statement_date_text,'direction',p.direction,'posting_category',p.category,'order_id',p.order_id,'order_ref',p.order_ref,'auth_ref',p.auth_ref,'reference_raw',p.reference_raw,'counterparty_type',p.counterparty_type,'counterparty_id',p.counterparty_id,'counterparty_name',p.counterparty_name,'target_sage_contact_id',p.sage_contact_id,'target_sage_bank_account_id',p.sage_bank_account_id,'target_sage_ledger_account_id',p.ledger_account_id,'matched_target_type',p.matched_target_type,'matched_target_id',p.matched_target_id,'matched_target_ref',p.matched_target_ref,'idempotency_key',p.idempotency_key,'live_posting_status','blocked_endpoint_prove_required','workbench_detail',p.detail_json),
      'frozen','validated','[]'::jsonb,p_notes,now(),v_staff_id
    FROM prepared p
    WHERE p.final_blocker IS NULL
    ON CONFLICT (idempotency_key) WHERE active = true DO NOTHING
    RETURNING id, source_id, posting_category, validation_status, short_reference, amount_gbp
  )
  SELECT
    p.selected_queue_row_id,
    p.source_id,
    COALESCE(i.id, p.existing_snapshot_id),
    CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'already_frozen' WHEN i.id IS NOT NULL THEN 'frozen' ELSE 'not_frozen' END,
    COALESCE(i.validation_status, CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'validated' ELSE 'not_validated' END),
    CASE WHEN p.existing_snapshot_id IS NOT NULL THEN 'already frozen' ELSE p.final_blocker END,
    COALESCE(i.short_reference, p.short_reference),
    COALESCE(i.amount_gbp, p.amount_gbp),
    COALESCE(i.posting_category, p.category)
  FROM prepared p
  LEFT JOIN inserted i ON i.source_id = p.source_id AND i.posting_category = p.category
  ORDER BY p.selected_queue_row_id;
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
    SELECT DISTINCT trim(x) AS queue_row_id FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT s.queue_row_id, split_part(s.queue_row_id, ':', 2)::text AS selected_category, NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected s WHERE split_part(s.queue_row_id, ':', 1) = 'cash' AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
  ), snaps AS (
    SELECT w.queue_row_id, snap.*
    FROM wanted w
    JOIN public.cash_posting_snapshots snap ON snap.active = true AND snap.source_id = w.selected_source_id AND snap.posting_category = CASE WHEN w.selected_category IN ('exception_hold','not_charged_closure') THEN 'unmatched_hold' ELSE w.selected_category END
    WHERE snap.posting_category IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold')
      AND snap.validation_status = 'validated'
      AND snap.sage_posting_status <> 'posted'
      AND NOT EXISTS (SELECT 1 FROM public.cash_posting_batch_rows br WHERE br.active = true AND br.snapshot_id = snap.id)
  )
  SELECT CASE WHEN count(DISTINCT posting_category) = 1 THEN min(posting_category) ELSE 'mixed_cash_control' END,
         count(*), COALESCE(sum(amount_gbp),0)::numeric(18,2)
  INTO v_batch_category, v_count, v_total
  FROM snaps;

  IF v_count > 0 AND v_batch_category <> 'mixed_cash_control' THEN
    v_batch_ref := 'CPB-' || floor(extract(epoch from clock_timestamp()))::bigint::text;
    INSERT INTO public.cash_posting_batches (batch_ref, posting_category, batch_status, row_count, total_amount_gbp, notes, created_by_staff_id)
    VALUES (v_batch_ref, v_batch_category, 'validated', v_count, v_total, p_notes, v_staff_id)
    RETURNING id INTO v_batch_id;

    WITH selected AS (
      SELECT DISTINCT trim(x) AS queue_row_id FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x WHERE NULLIF(trim(x), '') IS NOT NULL
    ), wanted AS (
      SELECT split_part(s.queue_row_id, ':', 2)::text AS selected_category, NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
      FROM selected s WHERE split_part(s.queue_row_id, ':', 1) = 'cash' AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
    )
    INSERT INTO public.cash_posting_batch_rows (batch_id, snapshot_id, source_id, posting_category, idempotency_key, amount_gbp, validation_status, posting_status, request_payload)
    SELECT v_batch_id, snap.id, snap.source_id, snap.posting_category, snap.idempotency_key, snap.amount_gbp, 'validated', 'blocked_endpoint_prove_required', snap.request_payload
    FROM wanted w
    JOIN public.cash_posting_snapshots snap ON snap.active = true AND snap.source_id = w.selected_source_id AND snap.posting_category = CASE WHEN w.selected_category IN ('exception_hold','not_charged_closure') THEN 'unmatched_hold' ELSE w.selected_category END
    WHERE snap.posting_category IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold')
      AND snap.validation_status = 'validated'
      AND snap.sage_posting_status <> 'posted'
      AND NOT EXISTS (SELECT 1 FROM public.cash_posting_batch_rows br WHERE br.active = true AND br.snapshot_id = snap.id);
  END IF;

  RETURN QUERY
  WITH selected AS (
    SELECT DISTINCT trim(x) AS queue_row_id FROM unnest(COALESCE(p_queue_row_ids, ARRAY[]::text[])) x WHERE NULLIF(trim(x), '') IS NOT NULL
  ), wanted AS (
    SELECT s.queue_row_id, split_part(s.queue_row_id, ':', 2)::text AS selected_category, NULLIF(split_part(s.queue_row_id, ':', 3), '')::uuid AS selected_source_id
    FROM selected s WHERE split_part(s.queue_row_id, ':', 1) = 'cash' AND NULLIF(split_part(s.queue_row_id, ':', 3), '') IS NOT NULL
  ), rows AS (
    SELECT w.queue_row_id, snap.id AS snapshot_id, snap.source_id, snap.posting_category, snap.amount_gbp, br.batch_id, b.batch_ref, b.batch_status,
      CASE
        WHEN snap.id IS NULL THEN 'freeze and validate this cash control row first'
        WHEN snap.posting_category NOT IN ('retailer_refund_received','bank_fee','fx_card_difference','unmatched_hold') THEN 'selected row is not a cash control category'
        WHEN snap.validation_status <> 'validated' THEN 'cash control snapshot is not validated'
        WHEN snap.sage_posting_status = 'posted' THEN 'cash control snapshot already posted'
        WHEN v_batch_category = 'mixed_cash_control' THEN 'mixed control categories cannot be batched together; filter to one category'
        WHEN br.batch_id IS NULL THEN 'cash control batch was not created'
        ELSE NULL::text
      END AS blocker
    FROM wanted w
    LEFT JOIN public.cash_posting_snapshots snap ON snap.active = true AND snap.source_id = w.selected_source_id AND snap.posting_category = CASE WHEN w.selected_category IN ('exception_hold','not_charged_closure') THEN 'unmatched_hold' ELSE w.selected_category END
    LEFT JOIN public.cash_posting_batch_rows br ON br.active = true AND br.snapshot_id = snap.id
    LEFT JOIN public.cash_posting_batches b ON b.active = true AND b.id = br.batch_id
  )
  SELECT queue_row_id, source_id, snapshot_id, batch_id, batch_ref, batch_status,
    CASE WHEN batch_id IS NOT NULL THEN 'batched_validated' ELSE 'blocked' END,
    blocker, amount_gbp, posting_category
  FROM rows
  ORDER BY queue_row_id;
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
