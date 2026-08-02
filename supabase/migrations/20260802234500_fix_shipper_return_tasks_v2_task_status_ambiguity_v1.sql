-- Governed by HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md.
-- Additive correction only: preserve v1, preserve the v2 return shape, and
-- qualify output-column references that collide with PL/pgSQL OUT parameters.
BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
DECLARE
  v_oid oid := to_regprocedure('public.shipper_return_tasks_v2()');
  v_md5 text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'shipper_return_tasks_v2() is missing.';
  END IF;

  SELECT md5(pg_get_functiondef(v_oid)) INTO v_md5;

  IF v_md5 <> 'd9e8336165e996dc7cbc4381d5eaa3d5' THEN
    RAISE EXCEPTION
      'shipper_return_tasks_v2() fingerprint drifted; expected %, found %. Stop and inspect.',
      'd9e8336165e996dc7cbc4381d5eaa3d5',
      v_md5;
  END IF;

  IF to_regprocedure('public.shipper_return_tasks_v1()') IS NULL THEN
    RAISE EXCEPTION 'Protected shipper_return_tasks_v1() is missing.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.shipper_return_tasks_v2()
RETURNS TABLE (
  return_tracking_submission_id uuid,
  dispute_id uuid,
  order_id uuid,
  order_ref text,
  importer_name text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  tracking_evidence_url text,
  retailer_return_instructions_file_url text,
  return_label_file_url text,
  operator_return_proof_file_url text,
  operator_note text,
  is_final_return_yn boolean,
  operator_review_status text,
  submitted_at timestamptz,
  affected_lines jsonb,
  latest_confirmation_id uuid,
  latest_shipper_outcome text,
  latest_shipper_proof_url text,
  latest_shipper_note text,
  latest_shipper_submitted_at timestamptz,
  latest_shipper_review_status text,
  latest_shipper_review_notes text,
  task_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper return tasks require auth.uid().';
  END IF;

  SELECT su.shipper_id
  INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.id DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH refund_rows AS (
    SELECT * FROM public.shipper_return_tasks_v1()
  ), latest_confirmation AS (
    SELECT DISTINCT ON (c.return_tracking_submission_id) c.*
    FROM public.shipper_return_task_confirmations c
    ORDER BY c.return_tracking_submission_id, c.submitted_at DESC, c.id DESC
  ), lines AS (
    SELECT dl.dispute_id,
      jsonb_agg(jsonb_build_object(
        'supplier_invoice_line_id', dl.supplier_invoice_line_id,
        'description', sil.description,
        'qty', COALESCE(dl.qty_impact, sil.qty),
        'amount_gbp', COALESCE(dl.amount_impact_gbp, sil.amount_inc_vat_gbp),
        'intended_remedy', dl.intended_remedy,
        'line_status', dl.line_status
      ) ORDER BY sil.line_order NULLS LAST, sil.description)
      FILTER (WHERE dl.supplier_invoice_line_id IS NOT NULL) AS affected_lines
    FROM public.dispute_lines dl
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    GROUP BY dl.dispute_id
  ), replacement_rows AS (
    SELECT
      rt.id AS return_tracking_submission_id,
      d.id AS dispute_id,
      o.id AS order_id,
      o.order_ref::text AS order_ref,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Importer')::text AS importer_name,
      r.name::text AS retailer_name,
      c.name::text AS courier_name,
      rt.tracking_ref::text AS tracking_ref,
      rt.tracking_date,
      rt.tracking_evidence_url::text AS tracking_evidence_url,
      rt.retailer_return_instructions_file_url::text AS retailer_return_instructions_file_url,
      rt.return_label_file_url::text AS return_label_file_url,
      rt.return_proof_file_url::text AS operator_return_proof_file_url,
      rt.note::text AS operator_note,
      rt.is_final_return_yn,
      rt.review_status::text AS operator_review_status,
      rt.submitted_at,
      COALESCE(lines.affected_lines, '[]'::jsonb) AS affected_lines,
      lc.id AS latest_confirmation_id,
      lc.outcome::text AS latest_shipper_outcome,
      COALESCE(lc.proof_file_url, lc.proof_url)::text AS latest_shipper_proof_url,
      lc.note::text AS latest_shipper_note,
      lc.submitted_at AS latest_shipper_submitted_at,
      lc.review_status::text AS latest_shipper_review_status,
      lc.review_notes::text AS latest_shipper_review_notes,
      CASE
        WHEN lc.id IS NULL THEN 'ready_to_action'
        WHEN lc.review_status = 'pending_review' THEN 'submitted_for_review'
        WHEN lc.review_status = 'accepted' THEN 'accepted'
        WHEN lc.review_status = 'hold' THEN 'held_query'
        WHEN lc.review_status = 'rejected' THEN 'ready_to_action'
        ELSE 'ready_to_action'
      END::text AS task_status
    FROM public.dispute_return_tracking_submissions rt
    JOIN public.disputes d ON d.id = rt.dispute_id
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.retailers r ON r.id = o.retailer_id
    LEFT JOIN public.couriers c ON c.id = rt.courier_id
    LEFT JOIN latest_confirmation lc ON lc.return_tracking_submission_id = rt.id
    LEFT JOIN lines ON lines.dispute_id = d.id
    WHERE o.shipper_id = v_shipper_id
      AND d.desired_outcome = 'replacement'
      AND (
        NULLIF(rt.retailer_return_instructions_file_url, '') IS NOT NULL
        OR NULLIF(rt.return_label_file_url, '') IS NOT NULL
        OR NULLIF(rt.tracking_ref, '') IS NOT NULL
        OR NULLIF(rt.tracking_evidence_url, '') IS NOT NULL
        OR NULLIF(rt.note, '') IS NOT NULL
      )
      AND EXISTS (
        SELECT 1
        FROM public.dispute_lines dl
        JOIN public.physical_exception_remedy_allocations pra
          ON pra.id = dl.physical_remedy_allocation_id
         AND pra.dispute_line_id = dl.id
         AND pra.approved_remedy_type = 'replacement'
        JOIN public.shipper_package_receipt_line_dispositions disp
          ON disp.id = pra.receipt_line_disposition_id
         AND disp.disposition_type IN ('damaged','wrong')
        WHERE dl.dispute_id = d.id
          AND dl.intended_remedy = 'replacement'
          AND (
            (d.replacement_child_order_id IS NULL AND d.resolved_at IS NULL AND dl.resolved_at IS NULL)
            OR
            (d.replacement_child_order_id IS NOT NULL
             AND pra.replacement_child_order_id = d.replacement_child_order_id
             AND dl.resolved_via_child_order_id = d.replacement_child_order_id)
          )
      )
  ), combined AS (
    SELECT * FROM refund_rows
    UNION ALL
    SELECT * FROM replacement_rows
  )
  SELECT combined.*
  FROM combined
  ORDER BY
    CASE combined.task_status
      WHEN 'ready_to_action' THEN 1
      WHEN 'held_query' THEN 2
      WHEN 'submitted_for_review' THEN 3
      WHEN 'accepted' THEN 4
      ELSE 5
    END,
    combined.submitted_at DESC,
    combined.return_tracking_submission_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.shipper_return_tasks_v2() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shipper_return_tasks_v2() TO authenticated;

DO $postflight$
DECLARE
  v_def text := pg_get_functiondef('public.shipper_return_tasks_v2()'::regprocedure);
BEGIN
  IF position('CASE combined.task_status' IN v_def) = 0
     OR position('combined.submitted_at DESC' IN v_def) = 0
     OR position('combined.return_tracking_submission_id' IN v_def) = 0
  THEN
    RAISE EXCEPTION 'Qualified v2 task ordering was not installed.';
  END IF;

  IF has_function_privilege('anon', 'public.shipper_return_tasks_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon unexpectedly has shipper_return_tasks_v2 execute.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.shipper_return_tasks_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated lacks shipper_return_tasks_v2 execute.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';
COMMIT;
