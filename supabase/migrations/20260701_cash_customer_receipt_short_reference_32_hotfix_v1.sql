BEGIN;

-- Hotfix: Sage contact_payment.reference has a 32 character limit.
-- The final-balance cash bridge generated refs like
-- GCB-IN-FB-ORD-1777736251155-d4454138, which is too long.
-- Patch the live generators and repair unposted/failed frozen customer-receipt rows.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_cash_short_reference_v1(
  p_direction text,
  p_statement_line_id uuid,
  p_source_id uuid,
  p_order_ref text DEFAULT NULL,
  p_auth_ref text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT upper(left(
    regexp_replace(
      'GCB-' ||
      CASE WHEN lower(COALESCE(p_direction, '')) = 'in' THEN 'IN' ELSE 'OUT' END || '-' ||
      COALESCE(
        NULLIF(regexp_replace(COALESCE(p_auth_ref, ''), '[^A-Za-z0-9]+', '', 'g'), ''),
        NULLIF(regexp_replace(COALESCE(p_order_ref, ''), '[^A-Za-z0-9]+', '', 'g'), ''),
        replace(p_statement_line_id::text, '-', ''),
        replace(p_source_id::text, '-', '')
      ),
      '[^A-Za-z0-9-]+', '', 'g'
    ),
    32
  ));
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)'::regprocedure)
    INTO v_def;

  IF position($old_customer$'short_reference', ('GCB-IN-' || COALESCE(o.order_ref::text, left(o.id::text, 8)) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10))$old_customer$ in v_def) = 0 THEN
    RAISE EXCEPTION 'Expected customer receipt short_reference expression not found in internal_cash_posting_workbench_rows_v1';
  END IF;

  v_def := replace(
    v_def,
    $old_customer$'short_reference', ('GCB-IN-' || COALESCE(o.order_ref::text, left(o.id::text, 8)) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10))$old_customer$,
    $new_customer$'short_reference', public.internal_cash_short_reference_v1('in', dsl.id, dr.id, o.order_ref::text, COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text))$new_customer$
  );

  IF position($old_final_balance$'short_reference', ('GCB-IN-FB-' || left(COALESCE(o.order_ref::text, o.id::text), 16) || '-' || left(adv.allocation_id::text, 8))$old_final_balance$ in v_def) = 0 THEN
    RAISE EXCEPTION 'Expected final-balance short_reference expression not found in internal_cash_posting_workbench_rows_v1';
  END IF;

  v_def := replace(
    v_def,
    $old_final_balance$'short_reference', ('GCB-IN-FB-' || left(COALESCE(o.order_ref::text, o.id::text), 16) || '-' || left(adv.allocation_id::text, 8))$old_final_balance$,
    $new_final_balance$'short_reference', left(('GCB-IN-FB-' || left(COALESCE(o.order_ref::text, o.id::text), 13) || '-' || left(adv.allocation_id::text, 8)), 32)$new_final_balance$
  );

  EXECUTE v_def;
END $$;

DO $$
DECLARE
  v_def text;
BEGIN
  IF to_regprocedure('public.internal_freeze_customer_receipt_cash_posting_v1(uuid[],text)') IS NULL THEN
    RETURN;
  END IF;

  SELECT pg_get_functiondef('public.internal_freeze_customer_receipt_cash_posting_v1(uuid[],text)'::regprocedure)
    INTO v_def;

  IF position($old_legacy$      ('GCB-IN-' || left(COALESCE(o.order_ref::text, o.id::text), 18) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10))::text AS short_reference,$old_legacy$ in v_def) > 0 THEN
    v_def := replace(
      v_def,
      $old_legacy$      ('GCB-IN-' || left(COALESCE(o.order_ref::text, o.id::text), 18) || '-' || left(COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text), 10))::text AS short_reference,$old_legacy$,
      $new_legacy$      public.internal_cash_short_reference_v1('in', dsl.id, dr.id, o.order_ref::text, COALESCE(to_jsonb(dsl)->>'auth_id_ref', to_jsonb(dsl)->>'payment_auth_id', dsl.id::text))::text AS short_reference,$new_legacy$
    );
    EXECUTE v_def;
  END IF;
END $$;

WITH candidate_snapshots AS (
  SELECT
    s.id AS snapshot_id,
    CASE
      WHEN s.source_type = 'dva_final_balance_allocation' THEN
        left(('GCB-IN-FB-' || left(COALESCE(s.order_ref, s.order_id::text, s.source_id::text), 13) || '-' || left(s.source_id::text, 8)), 32)
      ELSE
        public.internal_cash_short_reference_v1(
          'in',
          s.statement_line_id,
          s.source_id,
          s.order_ref,
          COALESCE(s.internal_reference_json->>'auth_ref', s.internal_reference_json->>'reference_raw')
        )
    END AS safe_ref
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.posting_category = 'customer_receipt_on_account'
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
    AND NULLIF(trim(COALESCE(s.sage_object_id, '')), '') IS NULL
    AND (
      length(COALESCE(s.short_reference, '')) > 32
      OR length(COALESCE(s.request_payload #>> '{contact_payment,reference}', '')) > 32
    )
), updated_snapshots AS (
  UPDATE public.cash_posting_snapshots s
  SET
    short_reference = c.safe_ref,
    request_payload = jsonb_set(
      COALESCE(s.request_payload, '{}'::jsonb),
      '{contact_payment,reference}',
      to_jsonb(c.safe_ref),
      true
    ),
    sage_posting_status = 'not_posted',
    sage_response_payload = NULL,
    updated_at = now()
  FROM candidate_snapshots c
  WHERE c.snapshot_id = s.id
  RETURNING s.id AS snapshot_id
), updated_rows AS (
  UPDATE public.cash_posting_batch_rows r
  SET
    request_payload = s.request_payload,
    posting_status = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
      THEN 'not_posted'
      ELSE r.posting_status
    END,
    response_payload = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
      THEN NULL
      ELSE r.response_payload
    END,
    error_code = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
      THEN NULL
      ELSE r.error_code
    END,
    error_message = CASE
      WHEN r.posting_status LIKE 'failed%'
       AND COALESCE(r.error_message, '') ILIKE '%maximum is 32%'
      THEN NULL
      ELSE r.error_message
    END,
    updated_at = now()
  FROM public.cash_posting_snapshots s
  JOIN updated_snapshots u ON u.snapshot_id = s.id
  WHERE r.active = true
    AND r.snapshot_id = s.id
    AND NULLIF(trim(COALESCE(r.sage_object_id, '')), '') IS NULL
  RETURNING r.batch_id
), affected_batches AS (
  SELECT DISTINCT batch_id FROM updated_rows WHERE batch_id IS NOT NULL
), batch_counts AS (
  SELECT
    b.id AS batch_id,
    count(r.id)::integer AS row_count,
    COALESCE(sum(r.amount_gbp), 0)::numeric(18,2) AS total_amount_gbp,
    count(*) FILTER (WHERE r.posting_status IN ('posted','posted_needs_review'))::integer AS success_count,
    count(*) FILTER (WHERE r.posting_status LIKE 'failed%')::integer AS failed_count
  FROM affected_batches ab
  JOIN public.cash_posting_batches b ON b.id = ab.batch_id
  JOIN public.cash_posting_batch_rows r ON r.batch_id = b.id AND r.active = true
  GROUP BY b.id
)
UPDATE public.cash_posting_batches b
SET
  batch_status = CASE
    WHEN bc.failed_count > 0 AND bc.success_count > 0 THEN 'partially_posted'
    WHEN bc.failed_count > 0 THEN 'failed'
    WHEN bc.success_count = bc.row_count AND bc.row_count > 0 THEN 'posted'
    ELSE 'validated'
  END,
  row_count = bc.row_count,
  total_amount_gbp = bc.total_amount_gbp,
  success_count = bc.success_count,
  failed_count = bc.failed_count,
  posting_completed_at = CASE
    WHEN bc.failed_count > 0 OR (bc.success_count = bc.row_count AND bc.row_count > 0) THEN b.posting_completed_at
    ELSE NULL
  END,
  updated_at = now()
FROM batch_counts bc
WHERE bc.batch_id = b.id;

NOTIFY pgrst, 'reload schema';

COMMIT;
