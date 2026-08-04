-- Read-only evidence check before changing customer-review timing or membership shape.
-- Shows real allocation lines that entered review and those excluded, with the reason visible from live state.

WITH orders_in_scope AS (
  SELECT DISTINCT a.order_id
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id IS NOT NULL
), current_candidates AS (
  SELECT c.*
  FROM orders_in_scope o
  CROSS JOIN LATERAL public.customer_review_cycle_candidates_v1(o.order_id) c
), latest_receipt AS (
  SELECT DISTINCT ON (r.tracking_submission_id)
    r.id AS receipt_id,
    r.order_id,
    r.tracking_submission_id,
    r.receipt_model_version,
    r.receipt_state,
    r.receipt_status,
    r.recorded_at,
    r.finalised_at,
    r.created_at
  FROM public.shipper_package_receipts r
  ORDER BY r.tracking_submission_id, r.created_at DESC, r.id DESC
), disposition_totals AS (
  SELECT
    d.receipt_id,
    d.tracking_line_allocation_id,
    SUM(d.quantity) FILTER (WHERE d.disposition_type = 'clean')::numeric AS clean_qty,
    SUM(d.quantity) FILTER (WHERE d.disposition_type <> 'clean')::numeric AS affected_qty,
    jsonb_object_agg(d.disposition_type, d.quantity) AS disposition_breakdown
  FROM public.shipper_package_receipt_line_dispositions d
  GROUP BY d.receipt_id, d.tracking_line_allocation_id
), membership_totals AS (
  SELECT
    m.tracking_line_allocation_id,
    SUM(m.review_qty)::numeric AS included_review_qty,
    MIN(m.receipt_recorded_at) AS first_review_receipt_at,
    MAX(m.receipt_recorded_at) AS last_review_receipt_at,
    jsonb_agg(
      jsonb_build_object(
        'membership_id', m.id,
        'review_link_id', m.review_link_id,
        'review_qty', m.review_qty,
        'membership_status', m.membership_status,
        'receipt_recorded_at', m.receipt_recorded_at,
        'created_at', m.created_at
      ) ORDER BY m.created_at
    ) AS memberships
  FROM public.customer_review_cycle_memberships m
  GROUP BY m.tracking_line_allocation_id
), active_holds AS (
  SELECT DISTINCT rm.tracking_line_allocation_id
  FROM public.customer_hold_review_memberships hm
  JOIN public.customer_review_cycle_memberships rm
    ON rm.id = hm.review_membership_id
  JOIN public.customer_pre_shipment_hold_requests h
    ON h.id = hm.hold_request_id
  WHERE hm.membership_status = 'active'
    AND h.status IN ('requested','supervisor_approved')
), open_disputes AS (
  SELECT DISTINCT a.id AS tracking_line_allocation_id
  FROM public.order_tracking_line_allocations a
  JOIN public.dispute_lines dl
    ON dl.supplier_invoice_line_id = a.supplier_invoice_line_id
  JOIN public.disputes d
    ON d.id = dl.dispute_id
  WHERE dl.resolved_at IS NULL
    AND d.resolved_at IS NULL
), active_remedies AS (
  SELECT
    r.tracking_line_allocation_id,
    SUM(
      CASE
        WHEN r.status = 'proposed' THEN COALESCE(r.proposed_remedy_qty,0)
        WHEN r.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action')
          THEN COALESCE(r.approved_remedy_qty,0)
        ELSE 0
      END
    )::numeric AS remedy_qty
  FROM public.physical_exception_remedy_allocations r
  GROUP BY r.tracking_line_allocation_id
), line_evidence AS (
  SELECT
    a.order_id,
    a.id AS tracking_line_allocation_id,
    a.tracking_submission_id,
    a.supplier_invoice_line_id,
    a.qty_allocated,
    lr.receipt_id,
    lr.receipt_model_version,
    lr.receipt_state,
    lr.receipt_status,
    lr.recorded_at AS latest_receipt_recorded_at,
    lr.finalised_at AS latest_receipt_finalised_at,
    COALESCE(dt.clean_qty,0)::numeric AS clean_qty,
    COALESCE(dt.affected_qty,0)::numeric AS affected_qty,
    dt.disposition_breakdown,
    COALESCE(mt.included_review_qty,0)::numeric AS included_review_qty,
    mt.first_review_receipt_at,
    mt.last_review_receipt_at,
    mt.memberships,
    (cc.tracking_line_allocation_id IS NOT NULL) AS currently_returned_by_candidate_function,
    (ah.tracking_line_allocation_id IS NOT NULL) AS has_active_exact_hold,
    (od.tracking_line_allocation_id IS NOT NULL) AS has_open_line_dispute,
    COALESCE(ar.remedy_qty,0)::numeric AS active_or_progressed_remedy_qty
  FROM public.order_tracking_line_allocations a
  LEFT JOIN latest_receipt lr
    ON lr.tracking_submission_id = a.tracking_submission_id
  LEFT JOIN disposition_totals dt
    ON dt.receipt_id = lr.receipt_id
   AND dt.tracking_line_allocation_id = a.id
  LEFT JOIN membership_totals mt
    ON mt.tracking_line_allocation_id = a.id
  LEFT JOIN current_candidates cc
    ON cc.tracking_line_allocation_id = a.id
  LEFT JOIN active_holds ah
    ON ah.tracking_line_allocation_id = a.id
  LEFT JOIN open_disputes od
    ON od.tracking_line_allocation_id = a.id
  LEFT JOIN active_remedies ar
    ON ar.tracking_line_allocation_id = a.id
  WHERE COALESCE(a.qty_allocated,0) > 0
), classified AS (
  SELECT
    le.*,
    CASE
      WHEN included_review_qty > 0 THEN 'included_existing_membership'
      WHEN currently_returned_by_candidate_function THEN 'included_current_candidate'
      WHEN receipt_id IS NULL THEN 'excluded_no_receipt'
      WHEN receipt_model_version = 2 AND receipt_state <> 'finalised' THEN 'excluded_v2_not_finalised'
      WHEN receipt_status IS DISTINCT FROM 'received_clean' THEN 'excluded_current_function_requires_whole_receipt_clean'
      WHEN has_active_exact_hold THEN 'excluded_active_hold'
      WHEN has_open_line_dispute THEN 'excluded_open_dispute'
      WHEN active_or_progressed_remedy_qty > 0 THEN 'excluded_active_or_progressed_remedy'
      ELSE 'excluded_other_current_rule'
    END AS observed_classification
  FROM line_evidence le
)
SELECT jsonb_build_object(
  'summary', (
    SELECT jsonb_object_agg(observed_classification, row_count)
    FROM (
      SELECT observed_classification, COUNT(*) AS row_count
      FROM classified
      GROUP BY observed_classification
      ORDER BY observed_classification
    ) s
  ),
  'included_examples', COALESCE((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.latest_receipt_recorded_at DESC NULLS LAST, x.tracking_line_allocation_id)
    FROM (
      SELECT *
      FROM classified
      WHERE observed_classification IN ('included_existing_membership','included_current_candidate')
      ORDER BY latest_receipt_recorded_at DESC NULLS LAST
      LIMIT 20
    ) x
  ), '[]'::jsonb),
  'excluded_examples', COALESCE((
    SELECT jsonb_agg(to_jsonb(x) ORDER BY x.latest_receipt_recorded_at DESC NULLS LAST, x.tracking_line_allocation_id)
    FROM (
      SELECT *
      FROM classified
      WHERE observed_classification LIKE 'excluded_%'
      ORDER BY latest_receipt_recorded_at DESC NULLS LAST
      LIMIT 30
    ) x
  ), '[]'::jsonb)
) AS customer_review_included_excluded_examples;
