BEGIN;

CREATE OR REPLACE FUNCTION public.shipper_saved_physical_receipt_split_v1(
  p_tracking_submission_id uuid
)
RETURNS TABLE(
  receipt_id uuid,
  tracking_line_allocation_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  clean_qty numeric,
  diverted_qty numeric,
  diverted_segments jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH caller AS (
    SELECT su.shipper_id
    FROM public.shipper_users su
    WHERE su.auth_user_id = auth.uid()
      AND su.active = true
    ORDER BY su.created_at DESC, su.id DESC
    LIMIT 1
  ),
  package AS (
    SELECT ots.id, ots.order_id
    FROM public.order_tracking_submissions ots
    JOIN public.orders o ON o.id = ots.order_id
    JOIN caller c ON c.shipper_id = o.shipper_id
    WHERE ots.id = p_tracking_submission_id
      AND ots.superseded_at IS NULL
  ),
  latest_receipt AS (
    SELECT r.id
    FROM public.shipper_package_receipts r
    JOIN package p ON p.id = r.tracking_submission_id
    WHERE r.receipt_model_version = 2
      AND r.receipt_state = 'finalised'
      AND r.finalised_at IS NOT NULL
    ORDER BY
      COALESCE(r.finalised_at, r.created_at) DESC,
      r.created_at DESC,
      r.id DESC
    LIMIT 1
  ),
  saved AS (
    SELECT
      lr.id AS receipt_id,
      d.tracking_line_allocation_id,
      d.supplier_invoice_line_id,
      sil.description AS item_description,
      a.qty_allocated::numeric,
      d.disposition_type,
      d.quantity::numeric,
      d.condition_note,
      d.id AS line_disposition_id
    FROM latest_receipt lr
    JOIN public.shipper_package_receipt_line_dispositions d
      ON d.receipt_id = lr.id
    JOIN public.order_tracking_line_allocations a
      ON a.id = d.tracking_line_allocation_id
    JOIN public.supplier_invoice_lines sil
      ON sil.id = d.supplier_invoice_line_id
  )
  SELECT
    s.receipt_id,
    s.tracking_line_allocation_id,
    s.supplier_invoice_line_id,
    s.item_description,
    MAX(s.qty_allocated)::numeric AS qty_allocated,
    COALESCE(SUM(s.quantity) FILTER (WHERE s.disposition_type = 'clean'), 0)::numeric AS clean_qty,
    COALESCE(SUM(s.quantity) FILTER (WHERE s.disposition_type <> 'clean'), 0)::numeric AS diverted_qty,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'disposition_type', s.disposition_type,
          'quantity', s.quantity,
          'condition_note', s.condition_note,
          'line_disposition_id', s.line_disposition_id
        ) ORDER BY s.disposition_type, s.line_disposition_id
      ) FILTER (WHERE s.disposition_type <> 'clean'),
      '[]'::jsonb
    ) AS diverted_segments
  FROM saved s
  GROUP BY
    s.receipt_id,
    s.tracking_line_allocation_id,
    s.supplier_invoice_line_id,
    s.item_description
  ORDER BY s.item_description, s.tracking_line_allocation_id;
$function$;

REVOKE ALL ON FUNCTION public.shipper_saved_physical_receipt_split_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.shipper_saved_physical_receipt_split_v1(uuid) TO authenticated;

COMMIT;
