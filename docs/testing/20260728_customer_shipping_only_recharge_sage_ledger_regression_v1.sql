/* Read-only regression for CUSTOMER_SHIPPING_ONLY_RECHARGE_SAGE_LEDGER_ADDENDUM_v1 */

DO $$
DECLARE
  v_def text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.sage_mapping_settings m
    JOIN public.sage_mapping_settings s
      ON s.mapping_code = 'VAT_BOX6_CARRIAGE_ON_SALES_LEDGER'
     AND s.is_active = true
    WHERE m.mapping_code = 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER'
      AND m.is_active = true
      AND NULLIF(BTRIM(COALESCE(m.sage_external_id, '')), '') IS NOT NULL
      AND m.sage_external_id = s.sage_external_id
      AND m.sage_display_name IS NOT DISTINCT FROM s.sage_display_name
  ) THEN
    RAISE EXCEPTION 'FAIL: production shipping recharge mapping is not aligned to active carriage on sales mapping';
  END IF;

  IF to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: canonical/preserved resolver pair missing';
  END IF;

  SELECT pg_get_functiondef(p.oid)
  INTO v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_resolved_customer_sales_sage_payload_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_sales_invoice_id uuid';

  IF v_def NOT ILIKE '%CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER%'
     OR v_def NOT ILIKE '%goods_amount_gbp%'
     OR v_def NOT ILIKE '%shipping_amount_gbp%'
     OR v_def NOT ILIKE '%Shipping charge — %'
     OR v_def NOT ILIKE '%missing_customer_shipping_recharge_income_ledger%'
  THEN
    RAISE EXCEPTION 'FAIL: scoped shipping-only resolver branch missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sage_mapping_settings
    WHERE mapping_code = 'EXPORT_SALE_INCOME_LEDGER'
      AND is_active = true
      AND NULLIF(BTRIM(COALESCE(sage_external_id, '')), '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: existing export sale mapping not preserved';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices si
    JOIN LATERAL (
      SELECT
        ROUND(COALESCE(SUM(l.goods_amount_gbp),0),2) AS goods_gbp,
        ROUND(COALESCE(SUM(l.shipping_amount_gbp),0),2) AS shipping_gbp,
        ROUND(COALESCE(SUM(l.customer_charge_amount_gbp),0),2) AS charge_gbp,
        COUNT(*)::integer AS line_count
      FROM public.customer_sales_release_lines l
      WHERE l.sales_invoice_id = si.id
        AND l.release_status = 'active'
    ) x ON true
    WHERE si.id = '0c583ba5-5fc7-4183-961c-57b6975c4556'::uuid
      AND si.sage_status = 'posted'
      AND x.goods_gbp = 0.00
      AND x.shipping_gbp = 24.00
      AND x.charge_gbp = 24.00
      AND x.line_count = 2
  ) THEN
    RAISE EXCEPTION 'FAIL: historical shipping-only durable release proof changed';
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','production carriage mapping aligned; canonical resolver branches only shipping-only durable lines; export-sale mapping preserved; historical release facts unchanged'
) AS regression_result;
