-- Governed by HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md.
-- Read-only post-deploy verification. This file must not be treated as a substitute
-- for the mandatory live preflight or the full database/browser regression pack.
BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '0';
SET LOCAL TRANSACTION READ ONLY;

DO $verify$
DECLARE
  v_indexdef text;
  v_count integer;
  v_amount numeric;
BEGIN
  IF to_regprocedure('public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing operator replacement return adapter.';
  END IF;

  IF to_regprocedure('public.shipper_return_tasks_v2()') IS NULL THEN
    RAISE EXCEPTION 'Missing shipper return task reader v2.';
  END IF;

  IF to_regprocedure('public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing shipper return confirmation v2.';
  END IF;

  IF to_regprocedure('public.shipper_return_tasks_v1()') IS NULL
     OR to_regprocedure('public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Protected refund return authorities are missing.';
  END IF;

  IF has_function_privilege('anon', 'public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.shipper_return_tasks_v2()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'anon has unexpected replacement return adapter execution.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.shipper_return_tasks_v2()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'authenticated is missing required replacement return adapter execution.';
  END IF;

  SELECT indexdef
  INTO v_indexdef
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND indexname = 'uq_shipper_return_task_one_pending_v1';

  IF v_indexdef IS NULL OR v_indexdef NOT LIKE '%return_tracking_submission_id%' OR v_indexdef NOT LIKE '%pending_review%' THEN
    RAISE EXCEPTION 'Pending shipper confirmation uniqueness invariant is absent or malformed.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.shipper_return_task_confirmations confirmation
  WHERE confirmation.review_status = 'pending_review'
  GROUP BY confirmation.return_tracking_submission_id
  HAVING COUNT(*) > 1
  LIMIT 1;

  IF COALESCE(v_count, 0) > 0 THEN
    RAISE EXCEPTION 'Duplicate pending shipper confirmations exist.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_return_tracking_submissions return_row
    JOIN public.disputes dispute_row ON dispute_row.id = return_row.dispute_id
    WHERE dispute_row.desired_outcome = 'replacement'
      AND EXISTS (
        SELECT 1
        FROM public.dispute_lines source_line
        JOIN public.physical_exception_remedy_allocations remedy_row
          ON remedy_row.id = source_line.physical_remedy_allocation_id
        JOIN public.shipper_package_receipt_line_dispositions disposition
          ON disposition.id = remedy_row.receipt_line_disposition_id
        WHERE source_line.dispute_id = dispute_row.id
          AND disposition.disposition_type = 'missing'
      )
  ) THEN
    RAISE EXCEPTION 'A missing-item replacement has a return-tracking submission; governed eligibility is violated.';
  END IF;

  SELECT remedy_row.customer_commercial_value_gbp
  INTO v_amount
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.id = '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid;

  IF v_amount IS DISTINCT FROM 60.00 THEN
    RAISE EXCEPTION 'Exact £60 remedy repair postcondition failed: %', v_amount;
  END IF;

  SELECT line_row.amount_impact_gbp
  INTO v_amount
  FROM public.dispute_lines line_row
  WHERE line_row.id = '126ed01a-09b4-47e4-a2db-c52e7480d814'::uuid;

  IF v_amount IS DISTINCT FROM 60.00 THEN
    RAISE EXCEPTION 'Exact £60 dispute-line repair postcondition failed: %', v_amount;
  END IF;

  SELECT dispute_row.amount_impact_gbp
  INTO v_amount
  FROM public.disputes dispute_row
  WHERE dispute_row.id = 'd7b32314-603e-49bf-83d1-1a01e2e4d29f'::uuid;

  IF v_amount IS DISTINCT FROM 60.00 THEN
    RAISE EXCEPTION 'Exact £60 dispute-header repair postcondition failed: %', v_amount;
  END IF;
END
$verify$;

SELECT
  p.oid::regprocedure::text AS function_signature,
  pg_get_userbyid(p.proowner) AS owner_name,
  p.prosecdef AS security_definer,
  p.proacl AS acl,
  md5(pg_get_functiondef(p.oid)) AS function_md5
FROM pg_proc p
WHERE p.oid IN (
  'public.operator_submit_replacement_return_collection_tracking_v1(uuid,uuid,text,date,text,boolean,text,text,text,text)'::regprocedure,
  'public.shipper_return_tasks_v2()'::regprocedure,
  'public.shipper_submit_return_task_confirmation_v2(uuid,text,text,text,text)'::regprocedure,
  'public.shipper_return_tasks_v1()'::regprocedure,
  'public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)'::regprocedure
)
ORDER BY 1;

ROLLBACK;
