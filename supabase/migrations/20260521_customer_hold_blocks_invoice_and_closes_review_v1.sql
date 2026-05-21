BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
  IF to_regclass('public.sales_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sales_invoices';
  END IF;
  IF to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_customer_invoice_release_queue_v1()';
  END IF;
  IF to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_order_has_active_pre_shipment_hold_v1(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = p_order_id
      AND h.status IN ('requested','supervisor_approved')
  );
$$;

REVOKE ALL ON FUNCTION public.customer_order_has_active_pre_shipment_hold_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_order_has_active_pre_shipment_hold_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_close_order_review_links_for_invoice_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.invoice_type::text, '') IN ('main','supplementary')
     AND COALESCE(NEW.sage_status::text, '') IN ('draft','posted')
  THEN
    UPDATE public.customer_order_review_links l
    SET is_active = false
    WHERE l.order_id = NEW.order_id
      AND l.is_active = true;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_close_order_review_links_for_invoice_v1
  ON public.sales_invoices;

CREATE TRIGGER trg_customer_close_order_review_links_for_invoice_v1
AFTER INSERT OR UPDATE OF sage_status, invoice_type, order_id
ON public.sales_invoices
FOR EACH ROW
EXECUTE FUNCTION public.customer_close_order_review_links_for_invoice_v1();

UPDATE public.customer_order_review_links l
SET is_active = false
WHERE l.is_active = true
  AND EXISTS (
    SELECT 1
    FROM public.sales_invoices si
    WHERE si.order_id = l.order_id
      AND COALESCE(si.invoice_type::text, '') IN ('main','supplementary')
      AND COALESCE(si.sage_status::text, '') IN ('draft','posted')
  );

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
    SELECT DISTINCT unnest(p_shipment_batch_ids) AS selected_shipment_batch_id
  ), selected_queue AS (
    SELECT q.*,
      EXISTS (
        SELECT 1
        FROM public.internal_shipping_customer_invoice_readiness_preview_v1(q.shipment_batch_id) p
        JOIN public.customer_pre_shipment_hold_requests h
          ON h.order_id = p.order_id
        WHERE h.status IN ('requested','supervisor_approved')
      ) AS has_active_customer_hold
    FROM public.internal_customer_invoice_release_queue_v1() q
    JOIN selected_batches sb
      ON sb.selected_shipment_batch_id = q.shipment_batch_id
  ), ready_queue AS (
    SELECT q.*
    FROM selected_queue q
    WHERE q.readiness_status = 'ready_to_create_draft'
      AND q.has_active_customer_hold IS DISTINCT FROM true
  ), locked_orders AS (
    SELECT o.id AS locked_order_id
    FROM public.orders o
    WHERE o.id IN (
      SELECT DISTINCT p.order_id
      FROM ready_queue rq
      CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(rq.shipment_batch_id) p
      WHERE p.blocker IS NULL
        AND p.order_id IS NOT NULL
        AND public.customer_order_has_active_pre_shipment_hold_v1(p.order_id) IS DISTINCT FROM true
    )
    FOR UPDATE
  ), preview_rows AS (
    SELECT p.*
    FROM ready_queue rq
    CROSS JOIN LATERAL public.internal_shipping_customer_invoice_readiness_preview_v1(rq.shipment_batch_id) p
    WHERE p.blocker IS NULL
      AND p.order_id IS NOT NULL
      AND public.customer_order_has_active_pre_shipment_hold_v1(p.order_id) IS DISTINCT FROM true
      AND EXISTS (SELECT 1 FROM locked_orders lo WHERE lo.locked_order_id = p.order_id)
  ), order_payload AS (
    SELECT
      pr.shipment_batch_id AS payload_shipment_batch_id,
      pr.order_id AS payload_order_id,
      MIN(pr.order_ref)::text AS payload_order_ref,
      MAX(pr.booking_ref)::text AS payload_booking_ref,
      MAX(pr.proposed_invoice_type)::text AS payload_invoice_type,
      SUM(COALESCE(pr.total_line_amount_gbp, 0))::numeric AS payload_amount_gbp,
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
      ) AS payload_line_items_json,
      CASE
        WHEN MAX(pr.proposed_invoice_type)::text = 'supplementary' THEN (
          SELECT si_main.id
          FROM public.sales_invoices si_main
          WHERE si_main.order_id = pr.order_id
            AND si_main.invoice_type = 'main'
            AND si_main.sage_status = 'posted'
          ORDER BY si_main.created_at DESC, si_main.id DESC
          LIMIT 1
        )
        ELSE NULL
      END AS payload_linked_invoice_id,
      (
        SELECT si_draft.id
        FROM public.sales_invoices si_draft
        WHERE si_draft.order_id = pr.order_id
          AND si_draft.invoice_type = MAX(pr.proposed_invoice_type)::text
          AND si_draft.sage_status = 'draft'
        ORDER BY si_draft.created_at DESC, si_draft.id DESC
        LIMIT 1
      ) AS payload_existing_draft_id,
      (
        SELECT si_posted.id
        FROM public.sales_invoices si_posted
        WHERE si_posted.order_id = pr.order_id
          AND si_posted.invoice_type = MAX(pr.proposed_invoice_type)::text
          AND si_posted.sage_status = 'posted'
        ORDER BY si_posted.created_at DESC, si_posted.id DESC
        LIMIT 1
      ) AS payload_existing_posted_id
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
      op.payload_order_id,
      op.payload_invoice_type,
      op.payload_linked_invoice_id,
      CURRENT_DATE,
      CURRENT_DATE,
      to_char(CURRENT_DATE, 'YYYY-MM'),
      to_char(CURRENT_DATE, 'YYYY-MM'),
      NULL,
      op.payload_amount_gbp,
      'ZERO_RATED_EXPORT_INTENT',
      op.payload_line_items_json,
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
    WHERE op.payload_existing_draft_id IS NULL
      AND op.payload_existing_posted_id IS NULL
      AND op.payload_amount_gbp > 0
      AND public.customer_order_has_active_pre_shipment_hold_v1(op.payload_order_id) IS DISTINCT FROM true
    RETURNING
      public.sales_invoices.id AS created_sales_invoice_id,
      public.sales_invoices.order_id AS created_order_id,
      public.sales_invoices.invoice_type AS created_invoice_type,
      public.sales_invoices.amount_gbp AS created_amount_gbp
  ), ready_results AS (
    SELECT
      op.payload_shipment_batch_id AS out_shipment_batch_id,
      op.payload_order_id AS out_order_id,
      op.payload_order_ref AS out_order_ref,
      op.payload_booking_ref AS out_booking_ref,
      op.payload_invoice_type AS out_invoice_type,
      CASE
        WHEN ins.created_sales_invoice_id IS NOT NULL THEN 'draft_created'
        WHEN public.customer_order_has_active_pre_shipment_hold_v1(op.payload_order_id) THEN 'skipped_customer_pre_shipment_hold_unresolved'
        WHEN op.payload_existing_draft_id IS NOT NULL THEN 'skipped_draft_already_exists'
        WHEN op.payload_existing_posted_id IS NOT NULL THEN 'skipped_posted_invoice_exists'
        WHEN op.payload_amount_gbp <= 0 THEN 'skipped_zero_amount'
        ELSE 'skipped_not_inserted'
      END::text AS out_result_status,
      COALESCE(ins.created_sales_invoice_id, op.payload_existing_draft_id, op.payload_existing_posted_id) AS out_sales_invoice_id,
      op.payload_amount_gbp AS out_amount_gbp,
      CASE
        WHEN ins.created_sales_invoice_id IS NOT NULL THEN 'Draft sales invoice created. Not posted to Sage.'
        WHEN public.customer_order_has_active_pre_shipment_hold_v1(op.payload_order_id) THEN 'Not created: unresolved customer pre-shipment hold.'
        WHEN op.payload_existing_draft_id IS NOT NULL THEN 'Draft already exists.'
        WHEN op.payload_existing_posted_id IS NOT NULL THEN 'Posted invoice already exists.'
        WHEN op.payload_amount_gbp <= 0 THEN 'Zero amount skipped.'
        ELSE 'No insert performed.'
      END::text AS out_message
    FROM order_payload op
    LEFT JOIN inserted ins
      ON ins.created_order_id = op.payload_order_id
     AND ins.created_invoice_type = op.payload_invoice_type
  ), blocked_hold_results AS (
    SELECT
      q.shipment_batch_id AS out_shipment_batch_id,
      NULL::uuid AS out_order_id,
      q.first_order_ref AS out_order_ref,
      q.booking_ref AS out_booking_ref,
      q.proposed_invoice_type AS out_invoice_type,
      'skipped_customer_pre_shipment_hold_unresolved'::text AS out_result_status,
      NULL::uuid AS out_sales_invoice_id,
      COALESCE(q.proposed_amount_gbp, 0) AS out_amount_gbp,
      'Not created: unresolved customer pre-shipment hold.'::text AS out_message
    FROM selected_queue q
    WHERE q.has_active_customer_hold = true
  ), non_ready_results AS (
    SELECT
      q.shipment_batch_id AS out_shipment_batch_id,
      NULL::uuid AS out_order_id,
      q.first_order_ref AS out_order_ref,
      q.booking_ref AS out_booking_ref,
      q.proposed_invoice_type AS out_invoice_type,
      ('skipped_' || COALESCE(q.readiness_status, 'not_ready'))::text AS out_result_status,
      NULL::uuid AS out_sales_invoice_id,
      COALESCE(q.proposed_amount_gbp, 0) AS out_amount_gbp,
      ('Not created: ' || COALESCE(q.readiness_status, 'not ready'))::text AS out_message
    FROM selected_queue q
    WHERE q.readiness_status IS DISTINCT FROM 'ready_to_create_draft'
      AND q.has_active_customer_hold IS DISTINCT FROM true
  ), all_results AS (
    SELECT * FROM ready_results
    UNION ALL
    SELECT * FROM blocked_hold_results
    UNION ALL
    SELECT * FROM non_ready_results
  )
  SELECT
    ar.out_shipment_batch_id AS shipment_batch_id,
    ar.out_order_id AS order_id,
    ar.out_order_ref AS order_ref,
    ar.out_booking_ref AS booking_ref,
    ar.out_invoice_type AS invoice_type,
    ar.out_result_status AS result_status,
    ar.out_sales_invoice_id AS sales_invoice_id,
    ar.out_amount_gbp AS amount_gbp,
    ar.out_message AS message
  FROM all_results ar
  ORDER BY ar.out_booking_ref NULLS LAST, ar.out_order_ref NULLS LAST, ar.out_result_status;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_customer_invoice_release_create_drafts_v1(uuid[]) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
