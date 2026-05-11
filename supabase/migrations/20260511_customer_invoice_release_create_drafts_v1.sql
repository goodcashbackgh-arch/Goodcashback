BEGIN;

CREATE OR REPLACE FUNCTION public.internal_customer_invoice_release_create_drafts_v1(p_shipment_batch_ids uuid[])
RETURNS TABLE (
  shipment_batch_id uuid,
  order_id uuid,
  order_ref text,
  booking_ref text,
  invoice_type text,
  result_status text,
  sales_invoice_id uuid,
  amount_gbp numeric,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer invoice draft creation requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for customer invoice draft creation.';
  END IF;

  IF p_shipment_batch_ids IS NULL OR array_length(p_shipment_batch_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'At least one shipment batch id is required.';
  END IF;

  RETURN QUERY
  WITH selected_batches AS (
    SELECT DISTINCT unnest(p_shipment_batch_ids) AS shipment_batch_id
  ), selected_queue AS (
    SELECT q.*
    FROM public.internal_customer_invoice_release_queue_v1() q
    JOIN selected_batches sb
      ON sb.shipment_batch_id = q.shipment_batch_id
  ), ready_queue AS (
    SELECT *
    FROM selected_queue q
    WHERE q.readiness_status = 'ready_to_create_draft'
  ), locked_orders AS (
    SELECT o.id
    FROM public.orders o
    WHERE o.id IN (
      SELECT DISTINCT p.order_id
      FROM ready_queue rq
      CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(rq.shipment_batch_id) p
      WHERE p.blocker IS NULL
        AND p.order_id IS NOT NULL
    )
    FOR UPDATE
  ), preview_rows AS (
    SELECT p.*
    FROM ready_queue rq
    CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(rq.shipment_batch_id) p
    WHERE p.blocker IS NULL
      AND p.order_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM locked_orders lo WHERE lo.id = p.order_id)
  ), order_payload AS (
    SELECT
      pr.shipment_batch_id,
      pr.order_id,
      MIN(pr.order_ref)::text AS order_ref,
      MAX(pr.booking_ref)::text AS booking_ref,
      MAX(pr.proposed_invoice_type)::text AS invoice_type,
      SUM(COALESCE(pr.total_line_amount_gbp, 0))::numeric AS amount_gbp,
      jsonb_build_object(
        'sage_header', jsonb_build_object(
          'reference', MIN(pr.order_ref)::text,
          'notes', CONCAT('Booking ', MAX(pr.booking_ref)::text),
          'reference_source', 'order_ref',
          'notes_source', 'booking_ref'
        ),
        'tax_resolution', jsonb_build_object(
          'tax_treatment', 'zero_rated_export',
          'sage_tax_rate_id', NULL,
          'sage_tax_rate_resolution_required', true,
          'display_vat_code', 'zero-rated export'
        ),
        'lines', jsonb_agg(
          jsonb_build_object(
            'description', COALESCE(NULLIF(pr.item_description, ''), 'Goods'),
            'quantity', COALESCE(pr.qty_allocated, 1),
            'unit_price_gbp', CASE
              WHEN COALESCE(pr.qty_allocated, 0) = 0 THEN COALESCE(pr.total_line_amount_gbp, 0)
              ELSE ROUND(COALESCE(pr.total_line_amount_gbp, 0) / pr.qty_allocated, 2)
            END,
            'total_line_amount_gbp', COALESCE(pr.total_line_amount_gbp, 0),
            'ledger_account_role', 'export_sale_income'
          ) ORDER BY pr.order_ref NULLS LAST, pr.item_description NULLS LAST
        ),
        'draft_control', jsonb_build_object(
          'created_from', 'customer_invoice_release_queue',
          'shipment_batch_id', pr.shipment_batch_id,
          'status', 'internal_draft_only_not_posted_to_sage'
        )
      ) AS line_items_payload,
      CASE
        WHEN MAX(pr.proposed_invoice_type)::text = 'supplementary' THEN (
          SELECT si.id
          FROM public.sales_invoices si
          WHERE si.order_id = pr.order_id
            AND si.invoice_type = 'main'
            AND si.sage_status = 'posted'
          ORDER BY si.created_at DESC, si.id DESC
          LIMIT 1
        )
        ELSE NULL
      END AS linked_invoice_id,
      (
        SELECT si.id
        FROM public.sales_invoices si
        WHERE si.order_id = pr.order_id
          AND si.invoice_type = MAX(pr.proposed_invoice_type)::text
          AND si.sage_status = 'draft'
        ORDER BY si.created_at DESC, si.id DESC
        LIMIT 1
      ) AS existing_draft_id,
      (
        SELECT si.id
        FROM public.sales_invoices si
        WHERE si.order_id = pr.order_id
          AND si.invoice_type = MAX(pr.proposed_invoice_type)::text
          AND si.sage_status = 'posted'
        ORDER BY si.created_at DESC, si.id DESC
        LIMIT 1
      ) AS existing_posted_id
    FROM preview_rows pr
    GROUP BY pr.shipment_batch_id, pr.order_id
  ), inserted AS (
    INSERT INTO public.sales_invoices (
      order_id,
      invoice_type,
      linked_invoice_id,
      consideration_received_date,
      sage_invoice_date,
      tax_point_period,
      sage_invoice_period,
      vat_box6_reported_period,
      amount_gbp,
      vat_code,
      line_items_json,
      sage_invoice_id,
      sage_posted_at,
      sage_status,
      export_evidence_complete_date,
      zero_rating_deadline_date,
      zero_rating_status,
      vat_adjustment_posted_at,
      reversal_posted_at,
      raised_by_trigger
    )
    SELECT
      op.order_id,
      op.invoice_type,
      op.linked_invoice_id,
      CURRENT_DATE,
      CURRENT_DATE,
      to_char(CURRENT_DATE, 'YYYY-MM'),
      to_char(CURRENT_DATE, 'YYYY-MM'),
      NULL,
      op.amount_gbp,
      'ZERO_RATED_EXPORT_INTENT',
      op.line_items_payload,
      NULL,
      NULL,
      'draft',
      NULL,
      (CURRENT_DATE + INTERVAL '90 days')::date,
      'on_track',
      NULL,
      NULL,
      false
    FROM order_payload op
    WHERE op.existing_draft_id IS NULL
      AND op.existing_posted_id IS NULL
      AND op.amount_gbp > 0
    RETURNING id, order_id, invoice_type, amount_gbp
  ), ready_results AS (
    SELECT
      op.shipment_batch_id,
      op.order_id,
      op.order_ref,
      op.booking_ref,
      op.invoice_type,
      CASE
        WHEN i.id IS NOT NULL THEN 'draft_created'
        WHEN op.existing_draft_id IS NOT NULL THEN 'skipped_draft_already_exists'
        WHEN op.existing_posted_id IS NOT NULL THEN 'skipped_posted_invoice_exists'
        WHEN op.amount_gbp <= 0 THEN 'skipped_zero_amount'
        ELSE 'skipped_not_inserted'
      END::text AS result_status,
      COALESCE(i.id, op.existing_draft_id, op.existing_posted_id) AS sales_invoice_id,
      op.amount_gbp,
      CASE
        WHEN i.id IS NOT NULL THEN 'Draft sales invoice created. Not posted to Sage.'
        WHEN op.existing_draft_id IS NOT NULL THEN 'Draft already exists.'
        WHEN op.existing_posted_id IS NOT NULL THEN 'Posted invoice already exists.'
        WHEN op.amount_gbp <= 0 THEN 'Zero amount skipped.'
        ELSE 'No insert performed.'
      END::text AS message
    FROM order_payload op
    LEFT JOIN inserted i
      ON i.order_id = op.order_id
     AND i.invoice_type = op.invoice_type
  ), non_ready_results AS (
    SELECT
      q.shipment_batch_id,
      NULL::uuid AS order_id,
      q.first_order_ref AS order_ref,
      q.booking_ref,
      q.proposed_invoice_type AS invoice_type,
      ('skipped_' || COALESCE(q.readiness_status, 'not_ready'))::text AS result_status,
      NULL::uuid AS sales_invoice_id,
      COALESCE(q.proposed_amount_gbp, 0) AS amount_gbp,
      ('Not created: ' || COALESCE(q.readiness_status, 'not ready'))::text AS message
    FROM selected_queue q
    WHERE q.readiness_status IS DISTINCT FROM 'ready_to_create_draft'
  )
  SELECT * FROM ready_results
  UNION ALL
  SELECT * FROM non_ready_results
  ORDER BY booking_ref NULLS LAST, order_ref NULLS LAST, result_status;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
