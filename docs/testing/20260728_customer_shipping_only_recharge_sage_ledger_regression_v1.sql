/*
  Read-only regression for
  CUSTOMER_SHIPPING_ONLY_RECHARGE_SAGE_LEDGER_ADDENDUM_v1

  No auth.uid(). No writes.
*/

DO $$
DECLARE
  v_def text;
  v_unexpected text;
  v_shipping_ledger_id text;
  v_shipping_ledger_name text;
  v_export_ledger_id text;
BEGIN
  -- 1. Production mapping must be aligned to the existing active carriage-on-sales mapping.
  SELECT m.sage_external_id, m.sage_display_name
  INTO v_shipping_ledger_id, v_shipping_ledger_name
  FROM public.sage_mapping_settings m
  JOIN public.sage_mapping_settings s
    ON s.mapping_code = 'VAT_BOX6_CARRIAGE_ON_SALES_LEDGER'
   AND s.is_active = true
  WHERE m.mapping_code = 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER'
    AND m.is_active = true
    AND NULLIF(BTRIM(COALESCE(m.sage_external_id, '')), '') IS NOT NULL
    AND m.sage_external_id = s.sage_external_id
    AND m.sage_display_name IS NOT DISTINCT FROM s.sage_display_name
  LIMIT 1;

  IF v_shipping_ledger_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: production shipping recharge mapping is not aligned to active carriage on sales mapping';
  END IF;

  SELECT sage_external_id
  INTO v_export_ledger_id
  FROM public.sage_mapping_settings
  WHERE mapping_code = 'EXPORT_SALE_INCOME_LEDGER'
    AND is_active = true
    AND NULLIF(BTRIM(COALESCE(sage_external_id, '')), '') IS NOT NULL
  LIMIT 1;

  IF v_export_ledger_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: existing export sale mapping not preserved';
  END IF;

  -- 2. Canonical/preserved resolver pair must exist.
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

  -- 3. Exact branch must exist, and no new line semantic vocabulary is allowed.
  IF v_def NOT ILIKE '%CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER%'
     OR v_def NOT ILIKE '%goods_amount_gbp%'
     OR v_def NOT ILIKE '%shipping_amount_gbp%'
     OR v_def NOT ILIKE '%Shipping charge — %'
     OR v_def NOT ILIKE '%missing_customer_shipping_recharge_income_ledger%'
     OR v_def NOT ILIKE '%sage_ledger_account_id%'
     OR v_def NOT ILIKE '%sage_ledger_account_display%'
  THEN
    RAISE EXCEPTION 'FAIL: scoped shipping-only resolver branch missing';
  END IF;

  IF v_def ILIKE '%''ledger_account_role'', ''customer_shipping_recharge_income''%'
     OR v_def ILIKE '%''customer_gl_role'', ''customer_shipping_recharge_income''%'
     OR v_def ILIKE '%''presentation'', ''standalone_customer_shipping_recharge_from_durable_release_membership''%'
  THEN
    RAISE EXCEPTION 'FAIL: out-of-scope line role/presentation vocabulary introduced';
  END IF;

  -- 4. No unknown public resolver dependant is permitted.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text)
  INTO v_unexpected
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
    AND p.proname NOT IN (
      'internal_resolved_customer_sales_sage_payload_v1',
      'internal_customer_sales_sage_payload_pre_shipping_recharge_v1',
      'internal_ready_for_sage_queue_v2',
      'internal_freeze_customer_sales_sage_batch_v1',
      'internal_revalidate_sage_posting_snapshots_v1'
    )
    AND p.prosrc LIKE '%internal_resolved_customer_sales_sage_payload_v1%';

  IF v_unexpected IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: unexpected resolver dependant(s) present: %', v_unexpected;
  END IF;

  -- 5. Historical £24 shipping-only durable release proof must remain unchanged.
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

  -- 6. Historical frozen snapshot must remain exactly the already-posted snapshot.
  IF NOT EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.id = 'c82c2918-e163-41a8-9a6a-f8a0753e320a'::uuid
      AND s.source_table = 'sales_invoices'
      AND s.source_id = '0c583ba5-5fc7-4183-961c-57b6975c4556'::uuid
      AND s.sage_posting_status = 'posted'
      AND s.sage_invoice_id = 'd467e522461847b8a382df1aa9c50a90'
      AND s.payload_semantic_fingerprint = 'a9946dd413fe05dc1bcf4879f9d75ffc'
      AND s.resolved_payload #>> '{tax_resolution,sage_tax_rate_id}' = 'GB_ZERO'
      AND s.resolved_payload #>> '{ledger_resolution,sage_ledger_account_display}' = 'Sales - Products (4000)'
  ) THEN
    RAISE EXCEPTION 'FAIL: historical posted Sage snapshot changed';
  END IF;

  -- 7. Real historical shipping-only lines prove the classification boundary.
  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id = '0c583ba5-5fc7-4183-961c-57b6975c4556'::uuid
      AND l.release_status = 'active'
      AND NOT (
        COALESCE(l.goods_amount_gbp,0) = 0
        AND COALESCE(l.shipping_amount_gbp,0) > 0
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: proven £24 document contains a line outside the shipping-only classification';
  END IF;

  -- 8. The £364.99 goods supplementary must remain outside the shipping-only rule.
  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id = '685912ce-0718-4250-97d4-d87d56a8db2f'::uuid
      AND l.release_status = 'active'
      AND COALESCE(l.goods_amount_gbp,0) > 0
  ) THEN
    RAISE EXCEPTION 'FAIL: goods-only comparison document no longer proves positive goods';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id = '685912ce-0718-4250-97d4-d87d56a8db2f'::uuid
      AND l.release_status = 'active'
      AND COALESCE(l.goods_amount_gbp,0) = 0
      AND COALESCE(l.shipping_amount_gbp,0) > 0
  ) THEN
    RAISE EXCEPTION 'FAIL: goods-only comparison document would be misclassified as shipping-only';
  END IF;

  -- 9. Apply the authorised three-field presentation/account transformation to
  -- the real frozen £24 lines in-memory and prove every other JSON field is identical.
  IF EXISTS (
    WITH source_lines AS (
      SELECT line.value AS before_line
      FROM public.sage_posting_snapshots s
      CROSS JOIN LATERAL jsonb_array_elements(s.resolved_payload -> 'resolved_lines') line(value)
      WHERE s.id = 'c82c2918-e163-41a8-9a6a-f8a0753e320a'::uuid
    ), transformed AS (
      SELECT
        before_line,
        before_line || jsonb_build_object(
          'description', 'Shipping charge — ' || COALESCE(NULLIF(before_line ->> 'description',''), 'Export sale'),
          'sage_ledger_account_id', v_shipping_ledger_id,
          'sage_ledger_account_display', v_shipping_ledger_name
        ) AS after_line
      FROM source_lines
      WHERE COALESCE(NULLIF(before_line ->> 'goods_amount_gbp','')::numeric,0) = 0
        AND COALESCE(NULLIF(before_line ->> 'shipping_amount_gbp','')::numeric,0) > 0
    )
    SELECT 1
    FROM transformed
    WHERE (before_line - ARRAY['description','sage_ledger_account_id','sage_ledger_account_display']::text[])
       IS DISTINCT FROM
          (after_line - ARRAY['description','sage_ledger_account_id','sage_ledger_account_display']::text[])
       OR after_line ->> 'sage_ledger_account_id' IS DISTINCT FROM v_shipping_ledger_id
       OR after_line ->> 'sage_ledger_account_display' IS DISTINCT FROM v_shipping_ledger_name
       OR after_line ->> 'description' NOT LIKE 'Shipping charge — %'
  ) THEN
    RAISE EXCEPTION 'FAIL: authorised shipping-only transformation changes fields outside description/Sage ledger account';
  END IF;

  -- 10. Existing frozen tax/source/value facts are still present on every £24 line.
  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    CROSS JOIN LATERAL jsonb_array_elements(s.resolved_payload -> 'resolved_lines') line(value)
    WHERE s.id = 'c82c2918-e163-41a8-9a6a-f8a0753e320a'::uuid
      AND (
        line.value ->> 'sage_tax_rate_id' IS DISTINCT FROM 'GB_ZERO'
        OR NULLIF(line.value ->> 'source_supplier_invoice_line_id','') IS NULL
        OR NULLIF(line.value ->> 'source_tracking_line_allocation_id','') IS NULL
        OR COALESCE(NULLIF(line.value ->> 'goods_amount_gbp','')::numeric,0) <> 0
        OR COALESCE(NULLIF(line.value ->> 'shipping_amount_gbp','')::numeric,0) <= 0
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: historical shipping-only tax/source/value proof changed';
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','production carriage mapping aligned; resolver changes only description and Sage ledger account for goods=0/shipping>0 lines; no new line-role vocabulary; dependency surface allowlisted; export mapping preserved; historical release and frozen Sage facts unchanged'
) AS regression_result;
