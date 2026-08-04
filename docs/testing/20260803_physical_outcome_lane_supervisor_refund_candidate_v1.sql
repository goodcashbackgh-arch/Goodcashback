-- Read-only candidate finder for the grouped supervisor refund rollback regression.
-- Returns only disputes that satisfy the delegated settlement-credit authority's
-- live financial preconditions and have an exact physical refund remedy identity.

WITH active_staff AS (
  SELECT id,auth_user_id
  FROM public.staff
  WHERE COALESCE(active,true)
    AND role_type IN ('admin','supervisor')
    AND auth_user_id IS NOT NULL
), candidates AS (
  SELECT
    d.id AS dispute_id,
    d.order_id,
    d.amount_impact_gbp,
    d.status AS dispute_status,
    d.resolved_at,
    dl.id AS dispute_line_id,
    dl.physical_remedy_allocation_id,
    r.physical_receipt_review_id,
    r.approved_remedy_type,
    r.approved_remedy_qty,
    r.status AS remedy_status,
    p.settlement_status,
    p.funding_less_posted_invoice_gbp AS credit_due_gbp,
    abs(coalesce(p.funding_less_posted_invoice_gbp,0)-coalesce(d.amount_impact_gbp,0)) AS amount_delta_gbp,
    EXISTS (
      SELECT 1
      FROM public.physical_receipt_review_dispute_links l
      WHERE l.physical_receipt_review_id=r.physical_receipt_review_id
        AND l.dispute_id=d.id
        AND l.desired_outcome='refund'
    ) AS exact_review_dispute_link,
    (
      SELECT count(*)
      FROM public.dispute_lines dl2
      WHERE dl2.dispute_id=d.id
        AND dl2.resolved_at IS NULL
        AND dl2.physical_remedy_allocation_id IS NOT NULL
    ) AS unresolved_physical_lines,
    s.id AS staff_id,
    s.auth_user_id AS staff_auth_user_id
  FROM public.disputes d
  JOIN public.dispute_lines dl ON dl.dispute_id=d.id
  JOIN public.physical_exception_remedy_allocations r
    ON r.id=dl.physical_remedy_allocation_id
  JOIN public.order_settlement_credit_position_v1 p ON p.order_id=d.order_id
  CROSS JOIN LATERAL (
    SELECT * FROM active_staff ORDER BY id LIMIT 1
  ) s
  WHERE d.desired_outcome='refund'
    AND d.resolved_at IS NULL
    AND r.approved_remedy_type='refund'
    AND r.status IN ('approved','linked_to_exception')
    AND p.settlement_status='credit_due'
    AND abs(coalesce(p.funding_less_posted_invoice_gbp,0)-coalesce(d.amount_impact_gbp,0))<=0.01
)
SELECT jsonb_build_object(
  'finder','physical_outcome_lane_supervisor_refund_candidate_v1',
  'result',CASE WHEN EXISTS(SELECT 1 FROM candidates WHERE exact_review_dispute_link) THEN 'CANDIDATE_FOUND' ELSE 'NO_CANDIDATE' END,
  'candidates',coalesce((
    SELECT jsonb_agg(to_jsonb(c) ORDER BY c.dispute_id)
    FROM candidates c
    WHERE c.exact_review_dispute_link
  ),'[]'::jsonb),
  'requirements',jsonb_build_array(
    'open refund dispute',
    'exact linked physical refund remedy',
    'review/dispute refund identity link',
    'order settlement status credit_due',
    'credit due amount matches dispute amount within GBP 0.01',
    'active supervisor/admin with auth user'
  )
) AS result;
