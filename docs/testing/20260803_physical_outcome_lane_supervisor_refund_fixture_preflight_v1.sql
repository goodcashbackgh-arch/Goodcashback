-- Read-only preflight for the rollback-only grouped supervisor refund regression.
-- Exposes the exact funding source contract and one structurally valid physical refund anchor.

WITH funding_function AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    md5(pg_get_functiondef(p.oid)) AS md5,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid='public.order_funding_total_gbp(uuid)'::regprocedure
), anchor AS (
  SELECT
    r.id AS physical_remedy_allocation_id,
    r.physical_receipt_review_id,
    r.receipt_line_disposition_id,
    r.tracking_line_allocation_id,
    r.supplier_invoice_line_id,
    r.dispute_line_id,
    dl.dispute_id,
    pr.order_id,
    pr.importer_id,
    r.proposed_by_operator_id,
    st.id AS staff_id,
    st.auth_user_id AS staff_auth_user_id,
    COALESCE(r.customer_commercial_value_gbp,dl.amount_impact_gbp,1)::numeric AS seed_amount_gbp
  FROM public.physical_exception_remedy_allocations r
  JOIN public.physical_receipt_reviews pr ON pr.id=r.physical_receipt_review_id
  JOIN public.dispute_lines dl ON dl.id=r.dispute_line_id
  JOIN public.disputes d ON d.id=dl.dispute_id AND d.order_id=pr.order_id
  JOIN public.physical_receipt_review_dispute_links l
    ON l.physical_receipt_review_id=pr.id
   AND l.dispute_id=d.id
  CROSS JOIN LATERAL (
    SELECT s.id,s.auth_user_id
    FROM public.staff s
    WHERE COALESCE(s.active,true)
      AND s.role_type IN ('admin','supervisor')
      AND s.auth_user_id IS NOT NULL
    ORDER BY s.id LIMIT 1
  ) st
  WHERE r.dispute_line_id IS NOT NULL
    AND r.receipt_line_disposition_id IS NOT NULL
    AND r.tracking_line_allocation_id IS NOT NULL
    AND r.supplier_invoice_line_id IS NOT NULL
  ORDER BY r.created_at,r.id
  LIMIT 1
), table_columns AS (
  SELECT table_name,jsonb_agg(jsonb_build_object(
    'column',column_name,
    'type',data_type,
    'nullable',is_nullable,
    'default',column_default
  ) ORDER BY ordinal_position) AS columns
  FROM information_schema.columns
  WHERE table_schema='public'
    AND table_name IN ('sales_invoices','importer_credit_ledger','orders')
  GROUP BY table_name
)
SELECT jsonb_build_object(
  'preflight','physical_outcome_lane_supervisor_refund_fixture_v1',
  'result',CASE
    WHEN NOT EXISTS(SELECT 1 FROM funding_function) THEN 'BLOCKED'
    WHEN NOT EXISTS(SELECT 1 FROM anchor) THEN 'BLOCKED'
    ELSE 'READY'
  END,
  'blockers',jsonb_strip_nulls(jsonb_build_object(
    'funding_function',CASE WHEN NOT EXISTS(SELECT 1 FROM funding_function) THEN 'order_funding_total_gbp(uuid) missing' END,
    'structural_anchor',CASE WHEN NOT EXISTS(SELECT 1 FROM anchor) THEN 'no exact physical remedy/review/dispute-link anchor exists' END
  )),
  'funding_function',(SELECT jsonb_build_object(
    'signature',signature,'md5',md5,'definition',definition
  ) FROM funding_function),
  'anchor',(SELECT to_jsonb(anchor) FROM anchor),
  'settlement_position_for_anchor',(
    SELECT to_jsonb(p)
    FROM anchor a
    LEFT JOIN public.order_settlement_credit_position_v1 p ON p.order_id=a.order_id
  ),
  'table_columns',(
    SELECT jsonb_object_agg(table_name,columns) FROM table_columns
  ),
  'required_function_md5s',jsonb_build_object(
    'staff_close_refund_exception_as_settlement_credit_v1',md5(pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure)),
    'staff_confirm_order_settlement_credit_v1',md5(pg_get_functiondef('public.staff_confirm_order_settlement_credit_v1(uuid,text,text)'::regprocedure)),
    'grouped_supervisor_decision',md5(pg_get_functiondef('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)'::regprocedure))
  )
) AS result;
