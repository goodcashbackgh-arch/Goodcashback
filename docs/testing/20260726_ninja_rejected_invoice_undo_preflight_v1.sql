-- Read-only preflight for the currently mis-rejected invoice on
-- ORD-1784976429191. This makes no changes.

WITH target_order AS (
  SELECT o.id, o.order_ref
  FROM public.orders o
  WHERE o.order_ref = 'ORD-1784976429191'
), invoice_state AS (
  SELECT
    si.id AS supplier_invoice_id,
    si.order_id,
    si.retailer_id,
    si.invoice_ref,
    si.review_status,
    si.reviewed_at,
    si.review_notes,
    si.uploaded_at,
    si.blocked_from_sage_yn,
    si.is_current_for_order,
    si.superseded_by_supplier_invoice_id
  FROM public.supplier_invoices si
  JOIN target_order o ON o.id = si.order_id
)
SELECT
  i.supplier_invoice_id,
  i.invoice_ref,
  i.review_status,
  i.reviewed_at,
  i.review_notes,
  i.blocked_from_sage_yn,
  i.is_current_for_order,
  i.superseded_by_supplier_invoice_id,
  (
    SELECT count(*)
    FROM public.supplier_invoices sibling
    WHERE sibling.id <> i.supplier_invoice_id
      AND sibling.order_id = i.order_id
      AND sibling.retailer_id = i.retailer_id
      AND lower(regexp_replace(btrim(sibling.invoice_ref), '[^a-zA-Z0-9]+', '', 'g')) =
          lower(regexp_replace(btrim(i.invoice_ref), '[^a-zA-Z0-9]+', '', 'g'))
      AND i.reviewed_at IS NOT NULL
      AND sibling.uploaded_at > i.reviewed_at
  ) AS later_same_reference_family_count,
  (
    SELECT count(*)
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = i.supplier_invoice_id
  ) AS line_count,
  (
    SELECT count(*)
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = i.supplier_invoice_id
      AND (
        sil.eligible_for_invoice_yn = 'Y'
        OR sil.qty_confirmed IS NOT NULL
        OR sil.amount_confirmed IS NOT NULL
      )
  ) AS progressed_line_count,
  (
    SELECT count(*)
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = i.supplier_invoice_id
      AND COALESCE(a.qty_allocated, 0) > 0
  ) AS tracking_allocation_count,
  (
    SELECT count(*)
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.supplier_invoice_lines sil ON sil.id = m.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = i.supplier_invoice_id
  ) AS shipment_membership_count,
  (
    SELECT count(*)
    FROM public.customer_sales_release_lines r
    WHERE r.supplier_invoice_id = i.supplier_invoice_id
  ) AS customer_sales_release_count,
  (
    SELECT count(*)
    FROM public.order_value_adjustments a
    WHERE a.supplier_invoice_id = i.supplier_invoice_id
  ) AS adjustment_count,
  (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'type', a.adjustment_type,
        'status', a.approval_status,
        'amount_gbp', a.amount_gbp
      ) ORDER BY a.id
    )
    FROM public.order_value_adjustments a
    WHERE a.supplier_invoice_id = i.supplier_invoice_id
  ) AS adjustments,
  (
    SELECT count(*)
    FROM public.supplier_invoice_line_resolutions r
    WHERE r.supplier_invoice_id = i.supplier_invoice_id
      AND r.active = true
  ) AS active_resolution_count,
  (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', f.id,
        'type', f.flag_type,
        'status', f.status,
        'resolved_at', f.resolved_at,
        'resolution_notes', f.resolution_notes
      ) ORDER BY f.created_at
    )
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = i.supplier_invoice_id
  ) AS review_flags,
  (
    SELECT count(*)
    FROM public.dva_statement_line_allocations a
    WHERE a.supplier_invoice_id = i.supplier_invoice_id
      AND a.allocation_type::text = 'supplier_invoice'
      AND a.allocation_status::text IN ('confirmed', 'held')
  ) AS supplier_payment_allocation_count,
  (
    SELECT count(*)
    FROM public.dispute_refund_evidence_submissions e
    WHERE e.original_supplier_invoice_id = i.supplier_invoice_id
  ) AS refund_evidence_count,
  (
    SELECT count(*)
    FROM public.sage_posting_snapshots s
    WHERE s.source_table = 'supplier_invoices'
      AND s.source_id = i.supplier_invoice_id
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ) + (
    SELECT count(*)
    FROM public.sage_postings p
    WHERE p.source_table = 'supplier_invoices'
      AND p.source_id = i.supplier_invoice_id
  ) AS sage_artifact_count
FROM invoice_state i
ORDER BY i.uploaded_at NULLS LAST, i.invoice_ref;
