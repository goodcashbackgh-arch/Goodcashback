BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_snapshots'; END IF;
  IF to_regclass('public.cash_posting_batches') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_batches'; END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN RAISE EXCEPTION 'Missing cash_posting_batch_rows'; END IF;
  IF to_regclass('public.dva_statement_line_allocation_detail_vw') IS NULL THEN RAISE EXCEPTION 'Missing dva_statement_line_allocation_detail_vw'; END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN RAISE EXCEPTION 'Missing dispute_refund_evidence_submissions'; END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_retailer_refund_has_posted_settlement_v1(p_allocation_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocation_detail_vw a
    JOIN public.dispute_refund_evidence_submissions s
      ON s.dispute_id = a.dispute_id
    JOIN public.sage_posting_snapshots sp
      ON sp.source_id = s.id
     AND sp.document_lane = 'supplier_credit_note'
     AND sp.sage_posting_status = 'posted'
     AND sp.sage_invoice_id IS NOT NULL
     AND sp.active = true
    WHERE a.allocation_id = p_allocation_id
      AND s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
    LIMIT 1
  );
$$;

-- Repair any active refund-IN batch rows that were batched before the settlement gate existed.
WITH unready AS (
  SELECT br.id AS batch_row_id, br.snapshot_id, br.batch_id
  FROM public.cash_posting_batch_rows br
  JOIN public.cash_posting_batches b ON b.id = br.batch_id AND b.active = true
  WHERE br.active = true
    AND br.posting_category = 'retailer_refund_received'
    AND br.sage_object_id IS NULL
    AND COALESCE(br.posting_status, '') <> 'posted'
    AND NOT public.internal_retailer_refund_has_posted_settlement_v1(br.source_id)
), deactivated_rows AS (
  UPDATE public.cash_posting_batch_rows br
  SET
    active = false,
    blocker = 'Removed from refund-IN batch: supplier credit/equivalent is not posted to Sage yet',
    updated_at = now()
  FROM unready u
  WHERE br.id = u.batch_row_id
  RETURNING br.snapshot_id, br.batch_id
), deactivated_snapshots AS (
  UPDATE public.cash_posting_snapshots s
  SET
    active = false,
    validation_status = 'not_validated',
    validation_errors = jsonb_build_array('supplier credit/equivalent is not posted to Sage yet'),
    notes = concat_ws(E'\n', NULLIF(s.notes, ''), 'System reset: refund-IN snapshot deactivated because supplier credit/equivalent was not posted to Sage before batching.'),
    updated_at = now()
  FROM deactivated_rows u
  WHERE s.id = u.snapshot_id
    AND s.sage_object_id IS NULL
  RETURNING s.id, u.batch_id
), affected_batches AS (
  SELECT DISTINCT batch_id FROM deactivated_rows
), active_totals AS (
  SELECT
    b.id AS batch_id,
    count(br.id)::integer AS active_count,
    COALESCE(sum(br.amount_gbp), 0)::numeric(18,2) AS active_total
  FROM affected_batches ab
  JOIN public.cash_posting_batches b ON b.id = ab.batch_id
  LEFT JOIN public.cash_posting_batch_rows br ON br.batch_id = b.id AND br.active = true
  GROUP BY b.id
)
UPDATE public.cash_posting_batches b
SET
  row_count = at.active_count,
  total_amount_gbp = at.active_total,
  batch_status = CASE WHEN at.active_count = 0 THEN 'cancelled' ELSE b.batch_status END,
  notes = concat_ws(E'\n', NULLIF(b.notes, ''), 'System reset: removed refund-IN rows without posted supplier-credit settlement.'),
  updated_at = now()
FROM active_totals at
WHERE b.id = at.batch_id;

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
      AND (snap.posting_category <> 'retailer_refund_received' OR public.internal_retailer_refund_has_posted_settlement_v1(snap.source_id))
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
      AND (snap.posting_category <> 'retailer_refund_received' OR public.internal_retailer_refund_has_posted_settlement_v1(snap.source_id))
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
        WHEN snap.posting_category = 'retailer_refund_received' AND NOT public.internal_retailer_refund_has_posted_settlement_v1(snap.source_id) THEN 'supplier credit/equivalent is not posted to Sage yet'
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

REVOKE ALL ON FUNCTION public.internal_retailer_refund_has_posted_settlement_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_retailer_refund_has_posted_settlement_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_create_cash_control_batch_v1(text[], text) TO authenticated;

COMMENT ON FUNCTION public.internal_retailer_refund_has_posted_settlement_v1(uuid) IS 'Returns true only when a retailer refund allocation has approved current refund evidence posted to Sage as a supplier-credit settlement artefact.';
COMMENT ON FUNCTION public.internal_create_cash_control_batch_v1(text[], text) IS 'Creates control batches. Retailer refund rows are batched only after supplier credit/equivalent is posted to Sage.';

NOTIFY pgrst, 'reload schema';

COMMIT;
