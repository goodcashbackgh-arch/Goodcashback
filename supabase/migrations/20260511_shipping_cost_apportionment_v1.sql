BEGIN;

CREATE TABLE IF NOT EXISTS public.shipping_category_weight_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_code varchar NOT NULL UNIQUE,
  label text NOT NULL,
  default_factor numeric(8,3) NOT NULL CHECK (default_factor > 0),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.shipping_category_weight_rules (rule_code, label, default_factor)
VALUES
  ('fashion_clothing', 'Fashion / clothing', 1.000),
  ('shoes_bags', 'Shoes / bags', 1.400),
  ('small_electronics', 'Small electronics', 1.800),
  ('appliances', 'Appliances', 3.000),
  ('bulky_manual', 'Bulky / manual review', 5.000),
  ('unclassified', 'Unclassified / default', 1.000)
ON CONFLICT (rule_code) DO UPDATE
SET label = EXCLUDED.label,
    default_factor = EXCLUDED.default_factor,
    active = true;

CREATE TABLE IF NOT EXISTS public.shipping_cost_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipping_document_id uuid NOT NULL REFERENCES public.shipping_documents(id),
  shipment_batch_id uuid NOT NULL REFERENCES public.shipper_shipment_batches(id),
  importer_id uuid REFERENCES public.importers(id),
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  allocation_method varchar NOT NULL DEFAULT 'category_weighted_shipped_value',
  source_currency_code varchar NOT NULL DEFAULT 'GBP',
  source_total_amount numeric(14,2) NOT NULL CHECK (source_total_amount >= 0),
  total_weighted_basis numeric(14,4) NOT NULL DEFAULT 0,
  total_allocated_amount numeric(14,2) NOT NULL DEFAULT 0,
  allocation_status varchar NOT NULL DEFAULT 'approved' CHECK (allocation_status IN ('approved','superseded','voided')),
  approval_note text,
  approved_by_staff_id uuid REFERENCES public.staff(id),
  approved_at timestamptz,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_shipping_cost_allocations_one_active_doc
  ON public.shipping_cost_allocations(shipping_document_id)
  WHERE active = true;

CREATE TABLE IF NOT EXISTS public.shipping_cost_allocation_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipping_cost_allocation_id uuid NOT NULL REFERENCES public.shipping_cost_allocations(id) ON DELETE CASCADE,
  tracking_submission_id uuid,
  order_id uuid,
  order_ref text,
  supplier_invoice_line_id uuid,
  item_description text NOT NULL,
  qty_allocated numeric(12,3) NOT NULL DEFAULT 0,
  adjusted_net_value_gbp numeric(14,2) NOT NULL DEFAULT 0,
  category_code varchar NOT NULL,
  category_label text NOT NULL,
  category_factor numeric(8,3) NOT NULL CHECK (category_factor > 0),
  weighted_basis numeric(14,4) NOT NULL DEFAULT 0,
  allocated_amount numeric(14,2) NOT NULL DEFAULT 0,
  override_applied boolean NOT NULL DEFAULT false,
  override_reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.shipping_category_weight_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipping_cost_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipping_cost_allocation_lines ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_category_weight_rules' AND policyname='shipping_category_weight_rules_staff_select') THEN
    CREATE POLICY shipping_category_weight_rules_staff_select ON public.shipping_category_weight_rules FOR SELECT TO authenticated USING (public.is_active_staff());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_cost_allocations' AND policyname='shipping_cost_allocations_staff_all') THEN
    CREATE POLICY shipping_cost_allocations_staff_all ON public.shipping_cost_allocations FOR ALL TO authenticated USING (public.is_active_staff()) WITH CHECK (public.is_active_staff());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='shipping_cost_allocation_lines' AND policyname='shipping_cost_allocation_lines_staff_all') THEN
    CREATE POLICY shipping_cost_allocation_lines_staff_all ON public.shipping_cost_allocation_lines FOR ALL TO authenticated USING (public.is_active_staff()) WITH CHECK (public.is_active_staff());
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_shipping_apportionment_preview_v1(p_shipping_document_id uuid)
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
    SELECT sd.*, b.booking_ref, i.company_name, i.trading_name, s.name AS shipper_name
    FROM public.shipping_documents sd
    JOIN public.shipper_shipment_batches b ON b.id = sd.shipment_batch_id
    LEFT JOIN public.importers i ON i.id = sd.importer_id
    JOIN public.shippers s ON s.id = sd.shipper_id
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
      p.tracking_submission_id,
      otla.order_id,
      o.order_ref::text,
      ots.tracking_ref::text,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
      otla.qty_allocated,
      otla.adjusted_net_value_gbp,
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
        WHEN otla.id IS NULL THEN 'no_allocated_items_for_batch'
        WHEN COALESCE(otla.adjusted_net_value_gbp, 0) <= 0 THEN 'missing_adjusted_value'
        ELSE NULL
      END::text AS blocker
    FROM doc d
    LEFT JOIN current_alloc ca ON true
    LEFT JOIN public.shipper_shipment_batch_packages p ON p.shipment_batch_id = d.shipment_batch_id AND p.active = true
    LEFT JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = otla.supplier_invoice_line_id
    LEFT JOIN public.orders o ON o.id = otla.order_id
    LEFT JOIN public.order_tracking_submissions ots ON ots.id = p.tracking_submission_id
  ), weighted AS (
    SELECT rl.*, r.label::text AS suggested_category_label, r.default_factor AS suggested_category_factor,
           ROUND(COALESCE(rl.adjusted_net_value_gbp, 0) * COALESCE(r.default_factor, 1), 4) AS weighted_basis
    FROM raw_lines rl
    LEFT JOIN public.shipping_category_weight_rules r ON r.rule_code = rl.suggested_category_code
  ), totals AS (
    SELECT SUM(weighted_basis) AS total_weighted_basis FROM weighted WHERE blocker IS NULL
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
    COALESCE(w.qty_allocated, 0),
    COALESCE(w.adjusted_net_value_gbp, 0),
    w.suggested_category_code,
    COALESCE(w.suggested_category_label, 'Unclassified / default'),
    COALESCE(w.suggested_category_factor, 1),
    COALESCE(w.weighted_basis, 0),
    CASE WHEN w.blocker IS NULL AND COALESCE(t.total_weighted_basis, 0) > 0
      THEN ROUND((w.source_total_amount * w.weighted_basis / t.total_weighted_basis), 2)
      ELSE 0 END AS preview_allocated_amount,
    w.blocker
  FROM weighted w
  CROSS JOIN totals t
  ORDER BY w.order_ref NULLS LAST, w.tracking_ref NULLS LAST, w.item_description;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_shipping_apportionment_preview_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_shipping_apportionment_preview_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_approve_shipping_apportionment_v1(
  p_shipping_document_id uuid,
  p_category_overrides jsonb DEFAULT '[]'::jsonb,
  p_approval_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_doc public.shipping_documents%ROWTYPE;
  v_allocation_id uuid;
  v_total numeric := 0;
  v_currency text := 'GBP';
  v_total_weighted numeric := 0;
  v_remainder numeric := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: approve shipping apportionment requires auth.uid()';
  END IF;

  SELECT id INTO v_staff_id FROM public.staff WHERE auth_user_id = auth.uid() AND active = true ORDER BY created_at DESC LIMIT 1;
  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required for shipping apportionment approval.';
  END IF;

  SELECT * INTO v_doc FROM public.shipping_documents WHERE id = p_shipping_document_id AND active = true;
  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'Active shipping document not found.';
  END IF;
  IF v_doc.review_status <> 'accepted_current' THEN
    RAISE EXCEPTION 'Shipping document must be accepted current before apportionment.';
  END IF;

  v_total := COALESCE(v_doc.extracted_total_amount, v_doc.total_amount, 0);
  v_currency := COALESCE(v_doc.extracted_currency_code, v_doc.currency_code, 'GBP');
  IF v_total <= 0 THEN
    RAISE EXCEPTION 'Accepted shipping document has no charge amount to apportion.';
  END IF;

  UPDATE public.shipping_cost_allocations
     SET active = false, allocation_status = 'superseded', updated_at = now()
   WHERE shipping_document_id = p_shipping_document_id AND active = true;

  WITH raw AS (
    SELECT
      p.tracking_submission_id,
      otla.order_id,
      o.order_ref::text,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
      otla.qty_allocated,
      otla.adjusted_net_value_gbp,
      COALESCE(ov.category_code, CASE
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(blender|processor|microwave|fridge|freezer|washer|washing|dryer|dishwasher|cooker|oven|appliance)' THEN 'appliances'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(shoe|shoes|trainer|trainers|sneaker|sneakers|bag|handbag|boot|boots)' THEN 'shoes_bags'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(phone|laptop|tablet|camera|headphone|headphones|earbud|earbuds|console|speaker)' THEN 'small_electronics'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(dress|shirt|top|jean|jeans|coat|jacket|trouser|trousers|skirt|clothing|fashion)' THEN 'fashion_clothing'
        ELSE 'unclassified' END)::text AS category_code,
      ov.override_reason::text AS override_reason
    FROM public.shipper_shipment_batch_packages p
    JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = otla.supplier_invoice_line_id
    LEFT JOIN public.orders o ON o.id = otla.order_id
    LEFT JOIN LATERAL (
      SELECT x->>'supplier_invoice_line_id' AS supplier_invoice_line_id_text,
             x->>'tracking_submission_id' AS tracking_submission_id_text,
             x->>'category_code' AS category_code,
             x->>'override_reason' AS override_reason
      FROM jsonb_array_elements(COALESCE(p_category_overrides, '[]'::jsonb)) x
      WHERE x->>'supplier_invoice_line_id' = otla.supplier_invoice_line_id::text
        AND x->>'tracking_submission_id' = p.tracking_submission_id::text
      LIMIT 1
    ) ov ON true
    WHERE p.shipment_batch_id = v_doc.shipment_batch_id AND p.active = true
  ), weighted AS (
    SELECT raw.*, r.label::text AS category_label, COALESCE(r.default_factor, 1)::numeric AS category_factor,
           ROUND(raw.adjusted_net_value_gbp * COALESCE(r.default_factor, 1), 4) AS weighted_basis
    FROM raw
    LEFT JOIN public.shipping_category_weight_rules r ON r.rule_code = raw.category_code
    WHERE raw.adjusted_net_value_gbp > 0
  )
  SELECT COALESCE(SUM(weighted_basis), 0) INTO v_total_weighted FROM weighted;

  IF v_total_weighted <= 0 THEN
    RAISE EXCEPTION 'No positive adjusted item value exists for shipping cost apportionment.';
  END IF;

  INSERT INTO public.shipping_cost_allocations (
    shipping_document_id, shipment_batch_id, importer_id, shipper_id,
    source_currency_code, source_total_amount, total_weighted_basis,
    total_allocated_amount, allocation_status, approval_note,
    approved_by_staff_id, approved_at, active
  ) VALUES (
    v_doc.id, v_doc.shipment_batch_id, v_doc.importer_id, v_doc.shipper_id,
    v_currency, v_total, v_total_weighted, v_total, 'approved',
    NULLIF(BTRIM(COALESCE(p_approval_note, '')), ''), v_staff_id, now(), true
  ) RETURNING id INTO v_allocation_id;

  WITH raw AS (
    SELECT
      p.tracking_submission_id,
      otla.order_id,
      o.order_ref::text,
      otla.supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Unlabelled item')::text AS item_description,
      otla.qty_allocated,
      otla.adjusted_net_value_gbp,
      COALESCE(ov.category_code, CASE
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(blender|processor|microwave|fridge|freezer|washer|washing|dryer|dishwasher|cooker|oven|appliance)' THEN 'appliances'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(shoe|shoes|trainer|trainers|sneaker|sneakers|bag|handbag|boot|boots)' THEN 'shoes_bags'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(phone|laptop|tablet|camera|headphone|headphones|earbud|earbuds|console|speaker)' THEN 'small_electronics'
        WHEN LOWER(COALESCE(sil.description, '')) ~ '(dress|shirt|top|jean|jeans|coat|jacket|trouser|trousers|skirt|clothing|fashion)' THEN 'fashion_clothing'
        ELSE 'unclassified' END)::text AS category_code,
      ov.override_reason::text AS override_reason
    FROM public.shipper_shipment_batch_packages p
    JOIN public.order_tracking_line_allocations otla ON otla.tracking_submission_id = p.tracking_submission_id
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = otla.supplier_invoice_line_id
    LEFT JOIN public.orders o ON o.id = otla.order_id
    LEFT JOIN LATERAL (
      SELECT x->>'category_code' AS category_code, x->>'override_reason' AS override_reason
      FROM jsonb_array_elements(COALESCE(p_category_overrides, '[]'::jsonb)) x
      WHERE x->>'supplier_invoice_line_id' = otla.supplier_invoice_line_id::text
        AND x->>'tracking_submission_id' = p.tracking_submission_id::text
      LIMIT 1
    ) ov ON true
    WHERE p.shipment_batch_id = v_doc.shipment_batch_id AND p.active = true
  ), weighted AS (
    SELECT raw.*, r.label::text AS category_label, COALESCE(r.default_factor, 1)::numeric AS category_factor,
           ROUND(raw.adjusted_net_value_gbp * COALESCE(r.default_factor, 1), 4) AS weighted_basis
    FROM raw
    LEFT JOIN public.shipping_category_weight_rules r ON r.rule_code = raw.category_code
    WHERE raw.adjusted_net_value_gbp > 0
  ), amounts AS (
    SELECT weighted.*,
           ROW_NUMBER() OVER (ORDER BY weighted.weighted_basis DESC, weighted.item_description) AS rn,
           ROUND(v_total * weighted.weighted_basis / v_total_weighted, 2) AS rough_amount
    FROM weighted
  ), final_amounts AS (
    SELECT a.*,
           CASE WHEN rn = 1 THEN v_total - COALESCE((SELECT SUM(rough_amount) FROM amounts WHERE rn > 1), 0)
                ELSE rough_amount END AS allocated_amount
    FROM amounts a
  )
  INSERT INTO public.shipping_cost_allocation_lines (
    shipping_cost_allocation_id, tracking_submission_id, order_id, order_ref,
    supplier_invoice_line_id, item_description, qty_allocated, adjusted_net_value_gbp,
    category_code, category_label, category_factor, weighted_basis, allocated_amount,
    override_applied, override_reason
  )
  SELECT
    v_allocation_id, tracking_submission_id, order_id, order_ref,
    supplier_invoice_line_id, item_description, qty_allocated, adjusted_net_value_gbp,
    category_code, COALESCE(category_label, 'Unclassified / default'), category_factor,
    weighted_basis, allocated_amount,
    override_reason IS NOT NULL, override_reason
  FROM final_amounts;

  RETURN v_allocation_id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_approve_shipping_apportionment_v1(uuid,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_approve_shipping_apportionment_v1(uuid,jsonb,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
