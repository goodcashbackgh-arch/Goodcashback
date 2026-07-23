BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_shipping_apportionment_preview_v1(
  p_shipping_document_id uuid
)
RETURNS TABLE (
  shipping_document_id uuid,
  shipment_batch_id uuid,
  booking_ref text,
  importer_name text,
  shipper_name text,
  review_status text,
  source_currency_code text,
  source_total_amount numeric,
  existing_allocation_id uuid,
  existing_allocation_status text,
  existing_approved_at timestamptz,
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  tracking_ref text,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  adjusted_net_value_gbp numeric,
  suggested_category_code text,
  suggested_category_label text,
  suggested_category_factor numeric,
  weighted_basis numeric,
  preview_allocated_amount numeric,
  blocker text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipping apportionment preview requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for shipping apportionment preview.';
  END IF;

  RETURN QUERY
  WITH doc AS (
    SELECT
      sd.*,
      b.booking_ref,
      i.company_name,
      i.trading_name,
      s.name AS shipper_name
    FROM public.shipping_documents sd
    JOIN public.shipper_shipment_batches b
      ON b.id = sd.shipment_batch_id
    LEFT JOIN public.importers i
      ON i.id = sd.importer_id
    JOIN public.shippers s
      ON s.id = sd.shipper_id
    WHERE sd.id = p_shipping_document_id
      AND sd.active = true
  ), current_alloc AS (
    SELECT sca.*
    FROM public.shipping_cost_allocations sca
    WHERE sca.shipping_document_id = p_shipping_document_id
      AND sca.active = true
    ORDER BY sca.created_at DESC
    LIMIT 1
  ), raw_lines AS (
    SELECT
      d.id AS shipping_document_id,
      d.shipment_batch_id,
      d.booking_ref::text,
      COALESCE(NULLIF(d.trading_name, ''), d.company_name)::text AS importer_name,
      d.shipper_name::text,
      d.review_status::text,
      COALESCE(d.extracted_currency_code, d.currency_code, 'GBP')::text AS source_currency_code,
      COALESCE(d.extracted_total_amount, d.total_amount, 0)::numeric AS source_total_amount,
      ca.id AS existing_allocation_id,
      ca.allocation_status::text AS existing_allocation_status,
      ca.approved_at AS existing_approved_at,
      e.tracking_submission_id,
      e.order_id,
      o.order_ref::text,
      ots.tracking_ref::text,
      e.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
      e.qty_in_shipment AS qty_allocated,
      e.adjusted_net_value_gbp,
      CASE
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(blender|processor|microwave|fridge|freezer|washer|washing|dryer|dishwasher|cooker|oven|appliance)' THEN 'appliances'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(shoe|shoes|trainer|trainers|sneaker|sneakers|bag|handbag|boot|boots)' THEN 'shoes_bags'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(phone|laptop|tablet|camera|headphone|headphones|earbud|earbuds|console|speaker)' THEN 'small_electronics'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(dress|shirt|top|jean|jeans|coat|jacket|trouser|trousers|skirt|clothing|fashion)' THEN 'fashion_clothing'
        ELSE 'unclassified'
      END::text AS suggested_category_code,
      CASE
        WHEN d.review_status <> 'accepted_current' THEN 'shipper_document_not_accepted'
        WHEN COALESCE(d.extracted_total_amount, d.total_amount, 0) <= 0 THEN 'missing_charge_amount'
        WHEN e.tracking_line_allocation_id IS NULL THEN 'no_allocated_items_for_batch'
        WHEN COALESCE(e.adjusted_net_value_gbp, 0) <= 0 THEN 'missing_adjusted_value'
        ELSE NULL
      END::text AS blocker
    FROM doc d
    LEFT JOIN current_alloc ca ON true
    LEFT JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(d.shipment_batch_id) e ON true
    LEFT JOIN public.supplier_invoice_lines sil
      ON sil.id = e.supplier_invoice_line_id
    LEFT JOIN public.orders o
      ON o.id = e.order_id
    LEFT JOIN public.order_tracking_submissions ots
      ON ots.id = e.tracking_submission_id
  ), weighted_rows AS (
    SELECT
      rl.*,
      COALESCE(r.label::text, 'Unclassified / default') AS suggested_category_label,
      COALESCE(r.default_factor, 1::numeric) AS suggested_category_factor,
      ROUND(
        COALESCE(rl.adjusted_net_value_gbp, 0) * COALESCE(r.default_factor, 1::numeric),
        4
      ) AS line_weighted_basis
    FROM raw_lines rl
    LEFT JOIN public.shipping_category_weight_rules r
      ON r.rule_code = rl.suggested_category_code
  ), totals AS (
    SELECT COALESCE(SUM(wr.line_weighted_basis), 0::numeric) AS total_weighted_basis
    FROM weighted_rows wr
    WHERE wr.blocker IS NULL
  )
  SELECT
    w.shipping_document_id,
    w.shipment_batch_id,
    w.booking_ref,
    w.importer_name,
    w.shipper_name,
    w.review_status,
    w.source_currency_code,
    w.source_total_amount,
    w.existing_allocation_id,
    w.existing_allocation_status,
    w.existing_approved_at,
    w.tracking_submission_id,
    w.order_id,
    w.order_ref,
    w.tracking_ref,
    w.supplier_invoice_line_id,
    w.item_description,
    COALESCE(w.qty_allocated, 0::numeric),
    COALESCE(w.adjusted_net_value_gbp, 0::numeric),
    w.suggested_category_code,
    w.suggested_category_label,
    w.suggested_category_factor,
    COALESCE(w.line_weighted_basis, 0::numeric) AS weighted_basis,
    CASE
      WHEN w.blocker IS NULL AND t.total_weighted_basis > 0
        THEN ROUND(w.source_total_amount * w.line_weighted_basis / t.total_weighted_basis, 2)
      ELSE 0::numeric
    END AS preview_allocated_amount,
    w.blocker
  FROM weighted_rows w
  CROSS JOIN totals t
  ORDER BY w.order_ref NULLS LAST, w.tracking_ref NULLS LAST, w.item_description;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_apportionment_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_apportionment_preview_v1(uuid) TO authenticated;

COMMENT ON FUNCTION public.internal_shipping_apportionment_preview_v1(uuid) IS
'Authenticated staff shipping apportionment preview using effective shipment lines. Internal weighted-basis aliases are qualified to avoid PL/pgSQL output-column ambiguity.';

NOTIFY pgrst, 'reload schema';

COMMIT;
