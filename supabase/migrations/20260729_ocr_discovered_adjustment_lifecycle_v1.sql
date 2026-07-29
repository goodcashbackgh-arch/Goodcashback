BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_line_resolutions';
  END IF;
  IF to_regclass('public.supplier_invoice_review_flags') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_review_flags';
  END IF;
  IF to_regclass('public.order_value_adjustments') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_value_adjustments';
  END IF;
  IF to_regclass('public.order_adjustment_policy') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_adjustment_policy';
  END IF;
END $$;

-- Materialise only the missing commercial adjustment fact for an invoice that
-- already has an explicit active delivery/discount non-physical resolution and
-- an open delivery_discount_query. Existing adjustment policy remains authority.
CREATE OR REPLACE FUNCTION public.internal_materialize_ocr_financial_adjustment_v1(
  p_supplier_invoice_id uuid,
  p_financial_type text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_order_id uuid;
  v_shipper_id uuid;
  v_invoice_status text;
  v_adjustment_type text;
  v_total numeric(12,2);
  v_operator_id uuid;
  v_delivery_limit numeric(12,2) := 10.00;
  v_requires_supervisor boolean;
  v_approval_status text;
BEGIN
  IF p_financial_type NOT IN ('delivery', 'discount') THEN
    RETURN;
  END IF;

  -- Serialise same-invoice/type materialisation so retries/concurrent resolver
  -- calls cannot create duplicate commercial facts without changing schema.
  PERFORM pg_advisory_xact_lock(
    hashtext('ocr_financial_adjustment:' || p_supplier_invoice_id::text || ':' || p_financial_type)
  );

  SELECT si.order_id, o.shipper_id, si.review_status::text
    INTO v_order_id, v_shipper_id, v_invoice_status
  FROM public.supplier_invoices si
  JOIN public.orders o ON o.id = si.order_id
  WHERE si.id = p_supplier_invoice_id;

  IF v_order_id IS NULL OR COALESCE(v_invoice_status, '') <> 'pending_review' THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = p_supplier_invoice_id
      AND f.flag_type = 'delivery_discount_query'
      AND f.status IN ('open', 'under_review')
  ) THEN
    RETURN;
  END IF;

  -- Do not materialise a partial type total while another obvious OCR line of
  -- the same financial type is still unclassified. Description is only a
  -- fail-closed completeness gate; it never creates the adjustment by itself.
  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = p_supplier_invoice_id
      AND sil.line_source = 'ocr_extracted'
      AND abs(COALESCE(sil.amount_inc_vat_gbp, 0)) > 0.01
      AND (
        (
          p_financial_type = 'delivery'
          AND lower(COALESCE(sil.description, '')) ~ '(delivery|shipping|postage|freight|carriage)'
        )
        OR (
          p_financial_type = 'discount'
          AND lower(COALESCE(sil.description, '')) ~ '(discount|promotion|promotional|promo|voucher|coupon|saving|savings)'
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = sil.id
          AND r.supplier_invoice_id = p_supplier_invoice_id
          AND r.active = true
          AND r.resolution_type = 'non_physical_financial'
          AND r.financial_type = p_financial_type
      )
  ) THEN
    RETURN;
  END IF;

  SELECT round(COALESCE(sum(abs(r.amount_gbp)), 0)::numeric, 2)
    INTO v_total
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.supplier_invoice_id = p_supplier_invoice_id
    AND r.active = true
    AND r.resolution_type = 'non_physical_financial'
    AND r.financial_type = p_financial_type;

  IF COALESCE(v_total, 0) <= 0.01 THEN
    RETURN;
  END IF;

  v_adjustment_type := CASE p_financial_type
    WHEN 'delivery' THEN 'retailer_delivery'
    WHEN 'discount' THEN 'retailer_discount'
  END;

  -- Reuse any already-live same-type fact. If its amount conflicts with the
  -- classified total, the review flag deliberately remains open for the
  -- existing correction route rather than creating a competing adjustment.
  IF EXISTS (
    SELECT 1
    FROM public.order_value_adjustments a
    WHERE a.supplier_invoice_id = p_supplier_invoice_id
      AND a.adjustment_type = v_adjustment_type
      AND a.approval_status <> 'rejected'
  ) THEN
    RETURN;
  END IF;

  SELECT COALESCE(
    (
      SELECT r.resolved_by_operator_id
      FROM public.supplier_invoice_line_resolutions r
      WHERE r.supplier_invoice_id = p_supplier_invoice_id
        AND r.active = true
        AND r.resolution_type = 'non_physical_financial'
        AND r.financial_type = p_financial_type
        AND r.resolved_by_operator_id IS NOT NULL
      ORDER BY r.resolved_at DESC, r.id DESC
      LIMIT 1
    ),
    (
      SELECT si.uploaded_by_operator_id
      FROM public.supplier_invoices si
      WHERE si.id = p_supplier_invoice_id
    )
  ) INTO v_operator_id;

  IF v_operator_id IS NULL THEN
    RETURN;
  END IF;

  IF p_financial_type = 'delivery' THEN
    SELECT COALESCE(
      (
        SELECT p.delivery_auto_approve_limit_gbp
        FROM public.order_adjustment_policy p
        WHERE p.active = true
          AND p.shipper_id = v_shipper_id
        ORDER BY p.updated_at DESC, p.id DESC
        LIMIT 1
      ),
      (
        SELECT p.delivery_auto_approve_limit_gbp
        FROM public.order_adjustment_policy p
        WHERE p.active = true
          AND p.shipper_id IS NULL
        ORDER BY p.updated_at DESC, p.id DESC
        LIMIT 1
      ),
      10.00
    ) INTO v_delivery_limit;

    v_requires_supervisor := v_total > v_delivery_limit;
    v_approval_status := CASE
      WHEN v_requires_supervisor THEN 'pending_supervisor'
      ELSE 'auto_approved'
    END;
  ELSE
    v_requires_supervisor := true;
    v_approval_status := 'pending_supervisor';
  END IF;

  INSERT INTO public.order_value_adjustments (
    order_id,
    supplier_invoice_id,
    adjustment_type,
    amount_gbp,
    approval_status,
    requires_supervisor_approval,
    submitted_by_operator_id,
    apportionment_method,
    customer_treatment,
    notes
  ) VALUES (
    v_order_id,
    p_supplier_invoice_id,
    v_adjustment_type,
    v_total,
    v_approval_status,
    v_requires_supervisor,
    v_operator_id,
    'pro_rata_by_line_value',
    'pass_to_importer',
    CASE
      WHEN p_financial_type = 'delivery' AND v_requires_supervisor = false
        THEN format('Auto-approved retailer delivery charge within GBP %s limit.', trim(to_char(v_delivery_limit, 'FM999999990.00')))
      WHEN p_financial_type = 'delivery'
        THEN format('Retailer delivery charge exceeds GBP %s auto-approval limit.', trim(to_char(v_delivery_limit, 'FM999999990.00')))
      ELSE 'Retailer discount requires supervisor approval before final invoice drafting.'
    END
  );
END;
$$;

-- Close only the specific delivery_discount_query, and only when the invoice's
-- accepted adjustment totals agree with its active classified OCR financial
-- totals and no obvious OCR delivery/discount row remains unclassified.
CREATE OR REPLACE FUNCTION public.internal_resolve_delivery_discount_query_if_satisfied_v1(
  p_supplier_invoice_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_resolved_delivery numeric(12,2) := 0;
  v_resolved_discount numeric(12,2) := 0;
  v_accepted_delivery numeric(12,2) := 0;
  v_accepted_discount numeric(12,2) := 0;
  v_resolved_by_staff_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = p_supplier_invoice_id
      AND f.flag_type = 'delivery_discount_query'
      AND f.status IN ('open', 'under_review')
  ) THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_value_adjustments a
    WHERE a.supplier_invoice_id = p_supplier_invoice_id
      AND a.adjustment_type IN ('retailer_delivery', 'retailer_discount')
      AND a.approval_status NOT IN ('approved', 'auto_approved', 'rejected')
  ) THEN
    RETURN;
  END IF;

  -- A rejected adjustment is not accepted evidence. If it is the only fact for
  -- a classified type, the totals below fail to agree and the flag stays open.
  SELECT
    round(COALESCE(sum(CASE WHEN r.financial_type = 'delivery' THEN abs(r.amount_gbp) ELSE 0 END), 0)::numeric, 2),
    round(COALESCE(sum(CASE WHEN r.financial_type = 'discount' THEN abs(r.amount_gbp) ELSE 0 END), 0)::numeric, 2)
  INTO v_resolved_delivery, v_resolved_discount
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.supplier_invoice_id = p_supplier_invoice_id
    AND r.active = true
    AND r.resolution_type = 'non_physical_financial'
    AND r.financial_type IN ('delivery', 'discount');

  IF (v_resolved_delivery + v_resolved_discount) <= 0.01 THEN
    RETURN;
  END IF;

  SELECT
    round(COALESCE(sum(CASE WHEN a.adjustment_type = 'retailer_delivery' THEN a.amount_gbp ELSE 0 END), 0)::numeric, 2),
    round(COALESCE(sum(CASE WHEN a.adjustment_type = 'retailer_discount' THEN a.amount_gbp ELSE 0 END), 0)::numeric, 2)
  INTO v_accepted_delivery, v_accepted_discount
  FROM public.order_value_adjustments a
  WHERE a.supplier_invoice_id = p_supplier_invoice_id
    AND a.adjustment_type IN ('retailer_delivery', 'retailer_discount')
    AND a.approval_status IN ('approved', 'auto_approved');

  SELECT a.approved_by_staff_id
    INTO v_resolved_by_staff_id
  FROM public.order_value_adjustments a
  WHERE a.supplier_invoice_id = p_supplier_invoice_id
    AND a.adjustment_type IN ('retailer_delivery', 'retailer_discount')
    AND a.approval_status = 'approved'
    AND a.approved_by_staff_id IS NOT NULL
  ORDER BY a.approved_at DESC NULLS LAST, a.updated_at DESC, a.id DESC
  LIMIT 1;

  IF abs(v_resolved_delivery - v_accepted_delivery) > 0.01
     OR abs(v_resolved_discount - v_accepted_discount) > 0.01 THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.supplier_invoice_id = p_supplier_invoice_id
      AND sil.line_source = 'ocr_extracted'
      AND abs(COALESCE(sil.amount_inc_vat_gbp, 0)) > 0.01
      AND (
        lower(COALESCE(sil.description, '')) ~ '(delivery|shipping|postage|freight|carriage)'
        OR lower(COALESCE(sil.description, '')) ~ '(discount|promotion|promotional|promo|voucher|coupon|saving|savings)'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.supplier_invoice_line_resolutions r
        WHERE r.supplier_invoice_line_id = sil.id
          AND r.supplier_invoice_id = p_supplier_invoice_id
          AND r.active = true
          AND r.resolution_type = 'non_physical_financial'
          AND (
            (
              lower(COALESCE(sil.description, '')) ~ '(delivery|shipping|postage|freight|carriage)'
              AND r.financial_type = 'delivery'
            )
            OR (
              lower(COALESCE(sil.description, '')) ~ '(discount|promotion|promotional|promo|voucher|coupon|saving|savings)'
              AND r.financial_type = 'discount'
            )
          )
      )
  ) THEN
    RETURN;
  END IF;

  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_resolved_by_staff_id,
    resolved_at = now(),
    resolution_notes = 'Delivery/discount query satisfied by accepted adjustment facts and matching active non-physical financial resolution(s).',
    updated_at = now()
  WHERE f.supplier_invoice_id = p_supplier_invoice_id
    AND f.flag_type = 'delivery_discount_query'
    AND f.status IN ('open', 'under_review');
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_ocr_financial_resolution_adjustment_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NEW.active = true
     AND NEW.resolution_type = 'non_physical_financial'
     AND NEW.financial_type IN ('delivery', 'discount') THEN
    PERFORM public.internal_materialize_ocr_financial_adjustment_v1(
      NEW.supplier_invoice_id,
      NEW.financial_type::text
    );
    PERFORM public.internal_resolve_delivery_discount_query_if_satisfied_v1(
      NEW.supplier_invoice_id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_ocr_financial_resolution_adjustment_v1
  ON public.supplier_invoice_line_resolutions;

CREATE TRIGGER trg_sync_ocr_financial_resolution_adjustment_v1
AFTER INSERT OR UPDATE OF active, resolution_type, financial_type, amount_gbp, supplier_invoice_line_id
ON public.supplier_invoice_line_resolutions
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_ocr_financial_resolution_adjustment_v1();

CREATE OR REPLACE FUNCTION public.trg_recheck_delivery_discount_query_after_adjustment_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NEW.supplier_invoice_id IS NOT NULL
     AND NEW.adjustment_type IN ('retailer_delivery', 'retailer_discount') THEN
    PERFORM public.internal_resolve_delivery_discount_query_if_satisfied_v1(
      NEW.supplier_invoice_id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recheck_delivery_discount_query_after_adjustment_v1
  ON public.order_value_adjustments;

CREATE TRIGGER trg_recheck_delivery_discount_query_after_adjustment_v1
AFTER INSERT OR UPDATE OF approval_status, amount_gbp, adjustment_type, supplier_invoice_id
ON public.order_value_adjustments
FOR EACH ROW
EXECUTE FUNCTION public.trg_recheck_delivery_discount_query_after_adjustment_v1();

-- Guarded historical repair: only pending-review invoices with an open query,
-- an active delivery/discount non-physical resolution, and no live adjustment of
-- that mapped type are considered. The helper applies all remaining gates.
DO $$
DECLARE
  v_row record;
BEGIN
  FOR v_row IN
    SELECT DISTINCT
      r.supplier_invoice_id,
      r.financial_type::text AS financial_type
    FROM public.supplier_invoice_line_resolutions r
    JOIN public.supplier_invoices si ON si.id = r.supplier_invoice_id
    WHERE r.active = true
      AND r.resolution_type = 'non_physical_financial'
      AND r.financial_type IN ('delivery', 'discount')
      AND si.review_status = 'pending_review'
      AND EXISTS (
        SELECT 1
        FROM public.supplier_invoice_review_flags f
        WHERE f.supplier_invoice_id = r.supplier_invoice_id
          AND f.flag_type = 'delivery_discount_query'
          AND f.status IN ('open', 'under_review')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.order_value_adjustments a
        WHERE a.supplier_invoice_id = r.supplier_invoice_id
          AND a.adjustment_type = CASE r.financial_type
            WHEN 'delivery' THEN 'retailer_delivery'
            WHEN 'discount' THEN 'retailer_discount'
          END
          AND a.approval_status <> 'rejected'
      )
  LOOP
    PERFORM public.internal_materialize_ocr_financial_adjustment_v1(
      v_row.supplier_invoice_id,
      v_row.financial_type
    );
    PERFORM public.internal_resolve_delivery_discount_query_if_satisfied_v1(
      v_row.supplier_invoice_id
    );
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION public.internal_materialize_ocr_financial_adjustment_v1(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_resolve_delivery_discount_query_if_satisfied_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_sync_ocr_financial_resolution_adjustment_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.trg_recheck_delivery_discount_query_after_adjustment_v1() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;
