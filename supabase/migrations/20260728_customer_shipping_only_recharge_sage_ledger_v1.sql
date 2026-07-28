BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- Customer shipping-only recharge Sage ledger v1
-- Governing contract:
-- docs/governing-pack/backend/CUSTOMER_SHIPPING_ONLY_RECHARGE_SAGE_LEDGER_ADDENDUM_v1.md
--
-- Scope only:
--   * create one production semantic mapping for customer shipping recharge;
--   * preserve the current canonical customer-sales Sage resolver;
--   * for durable lines where goods = 0 and shipping > 0 only:
--       - resolve to Carriage on Sales via the new production mapping;
--       - present description as "Shipping charge — {item}";
--   * preserve all other customer-sales behaviour unchanged.
-- =============================================================================

DO $$
DECLARE
  v_result text;
  v_def text;
BEGIN
  IF to_regclass('public.sage_mapping_settings') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Shipping-only recharge prerequisites missing';
  END IF;

  IF to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Canonical customer-sales Sage resolver missing';
  END IF;

  SELECT pg_get_function_result(p.oid), pg_get_functiondef(p.oid)
  INTO v_result, v_def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_resolved_customer_sales_sage_payload_v1'
    AND pg_get_function_identity_arguments(p.oid) = 'p_sales_invoice_id uuid';

  IF v_result IS NULL OR v_result NOT LIKE '%sales_invoice_id uuid%resolved_payload jsonb%mapping_snapshot jsonb%mapping_semantic_fingerprint text%payload_status text%blocker text%warning text%' THEN
    RAISE EXCEPTION 'Canonical customer-sales Sage resolver return shape differs; stop before patching';
  END IF;

  IF v_def NOT ILIKE '%customer_sales_release_lines%'
     OR v_def NOT ILIKE '%goods_amount_gbp%'
     OR v_def NOT ILIKE '%shipping_amount_gbp%'
     OR v_def NOT ILIKE '%EXPORT_SALE_INCOME_LEDGER%'
  THEN
    RAISE EXCEPTION 'Canonical customer-sales Sage resolver no longer matches durable-release-ledger contract; stop before patching';
  END IF;

  IF to_regprocedure('public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'Preserved pre-shipping-recharge resolver already exists; refusing ambiguous reapplication';
  END IF;
END $$;

-- Seed the production semantic mapping from the already-configured active
-- VAT Box 6 carriage-on-sales mapping. Do not hard-code the Sage UUID/nominal.
INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for,
  sage_external_id,
  sage_display_name,
  is_active,
  configured_at,
  notes
)
SELECT
  'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER',
  'customer_sales_posting',
  'Customer shipping recharge income ledger',
  'Sage income ledger for standalone customer shipping recharge lines where durable goods value is zero and durable shipping value is positive.',
  source.value_kind,
  ARRAY['customer_sales_posting','shipping_only_customer_recharge']::text[],
  source.sage_external_id,
  source.sage_display_name,
  true,
  now(),
  'Seeded from active VAT_BOX6_CARRIAGE_ON_SALES_LEDGER; production customer-sales posting semantic mapping.'
FROM public.sage_mapping_settings source
WHERE source.mapping_code = 'VAT_BOX6_CARRIAGE_ON_SALES_LEDGER'
  AND source.is_active = true
  AND NULLIF(BTRIM(COALESCE(source.sage_external_id, '')), '') IS NOT NULL
  AND NULLIF(BTRIM(COALESCE(source.sage_display_name, '')), '') IS NOT NULL
ON CONFLICT (mapping_code) DO UPDATE
SET sage_external_id = EXCLUDED.sage_external_id,
    sage_display_name = EXCLUDED.sage_display_name,
    is_active = true,
    updated_at = now();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.sage_mapping_settings sm
    WHERE sm.mapping_code = 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER'
      AND sm.is_active = true
      AND NULLIF(BTRIM(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(sm.sage_display_name, '')), '') IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Active carriage-on-sales source mapping unavailable; shipping recharge mapping not created';
  END IF;
END $$;

ALTER FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid)
  RENAME TO internal_customer_sales_sage_payload_pre_shipping_recharge_v1;

REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(uuid) FROM service_role;

CREATE OR REPLACE FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(
  p_sales_invoice_id uuid DEFAULT NULL
)
RETURNS TABLE (
  sales_invoice_id uuid,
  order_id uuid,
  order_ref text,
  document_lane text,
  document_type text,
  invoice_type text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  reference_text text,
  notes_text text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  commercial_payload jsonb,
  resolved_payload jsonb,
  mapping_snapshot jsonb,
  mapping_semantic_fingerprint text,
  payload_status text,
  blocker text,
  warning text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required for customer sales Sage payload resolution';
  END IF;

  RETURN QUERY
  WITH carriage_mapping AS (
    SELECT
      MAX(sm.sage_external_id) FILTER (
        WHERE sm.mapping_code = 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER'
          AND sm.is_active = true
          AND NULLIF(BTRIM(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL
      )::text AS ledger_id,
      MAX(sm.sage_display_name) FILTER (
        WHERE sm.mapping_code = 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER'
          AND sm.is_active = true
          AND NULLIF(BTRIM(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL
      )::text AS ledger_name,
      MAX(sm.configured_at) FILTER (
        WHERE sm.mapping_code = 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER'
          AND sm.is_active = true
          AND NULLIF(BTRIM(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL
      )::timestamptz AS configured_at
    FROM public.sage_mapping_settings sm
  ), base AS (
    SELECT preserved.*
    FROM public.internal_customer_sales_sage_payload_pre_shipping_recharge_v1(p_sales_invoice_id) preserved
  ), inspected AS (
    SELECT
      base.*,
      EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(base.resolved_payload -> 'resolved_lines') = 'array'
              THEN base.resolved_payload -> 'resolved_lines'
            ELSE '[]'::jsonb
          END
        ) line(value)
        WHERE COALESCE(NULLIF(line.value ->> 'goods_amount_gbp', '')::numeric, 0) = 0
          AND COALESCE(NULLIF(line.value ->> 'shipping_amount_gbp', '')::numeric, 0) > 0
      ) AS has_shipping_only_line
    FROM base
  ), transformed AS (
    SELECT
      inspected.*,
      CASE
        WHEN inspected.invoice_type IN ('main', 'supplementary')
          AND inspected.sage_status = 'draft'
          AND inspected.has_shipping_only_line
          AND carriage_mapping.ledger_id IS NULL
          THEN 'blocked_sage_mapping_required'::text
        ELSE inspected.payload_status
      END AS patched_status,
      CASE
        WHEN inspected.invoice_type IN ('main', 'supplementary')
          AND inspected.sage_status = 'draft'
          AND inspected.has_shipping_only_line
          AND carriage_mapping.ledger_id IS NULL
          THEN 'missing_customer_shipping_recharge_income_ledger'::text
        ELSE inspected.blocker
      END AS patched_blocker,
      CASE
        WHEN inspected.invoice_type IN ('main', 'supplementary')
          AND inspected.sage_status = 'draft'
          AND inspected.has_shipping_only_line
          AND carriage_mapping.ledger_id IS NOT NULL
        THEN jsonb_set(
          jsonb_set(
            inspected.resolved_payload,
            '{resolved_lines}',
            COALESCE((
              SELECT jsonb_agg(
                CASE
                  WHEN COALESCE(NULLIF(line.value ->> 'goods_amount_gbp', '')::numeric, 0) = 0
                   AND COALESCE(NULLIF(line.value ->> 'shipping_amount_gbp', '')::numeric, 0) > 0
                  THEN line.value || jsonb_build_object(
                    'description', 'Shipping charge — ' || COALESCE(NULLIF(line.value ->> 'description', ''), 'Export sale'),
                    'ledger_account_role', 'customer_shipping_recharge_income',
                    'customer_gl_role', 'customer_shipping_recharge_income',
                    'presentation', 'standalone_customer_shipping_recharge_from_durable_release_membership',
                    'sage_ledger_account_id', carriage_mapping.ledger_id,
                    'sage_ledger_account_display', carriage_mapping.ledger_name
                  )
                  ELSE line.value
                END
                ORDER BY line.ordinality
              )
              FROM jsonb_array_elements(
                CASE
                  WHEN jsonb_typeof(inspected.resolved_payload -> 'resolved_lines') = 'array'
                    THEN inspected.resolved_payload -> 'resolved_lines'
                  ELSE '[]'::jsonb
                END
              ) WITH ORDINALITY AS line(value, ordinality)
            ), '[]'::jsonb),
            true
          ),
          '{resolved_mappings,CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER}',
          jsonb_build_object(
            'mapping_code', 'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER',
            'sage_external_id', carriage_mapping.ledger_id,
            'sage_display_name', carriage_mapping.ledger_name,
            'configured_at', carriage_mapping.configured_at
          ),
          true
        )
        ELSE inspected.resolved_payload
      END AS patched_resolved_payload,
      CASE
        WHEN inspected.invoice_type IN ('main', 'supplementary')
          AND inspected.sage_status = 'draft'
          AND inspected.has_shipping_only_line
          AND carriage_mapping.ledger_id IS NOT NULL
        THEN inspected.mapping_snapshot || jsonb_build_object(
          'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER', jsonb_build_object(
            'sage_external_id', carriage_mapping.ledger_id,
            'sage_display_name', carriage_mapping.ledger_name,
            'configured_at', carriage_mapping.configured_at
          )
        )
        ELSE inspected.mapping_snapshot
      END AS patched_mapping_snapshot,
      CASE
        WHEN inspected.invoice_type IN ('main', 'supplementary')
          AND inspected.sage_status = 'draft'
          AND inspected.has_shipping_only_line
          AND carriage_mapping.ledger_id IS NOT NULL
        THEN md5(concat_ws('|',
          inspected.mapping_semantic_fingerprint,
          'CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER',
          carriage_mapping.ledger_id,
          COALESCE(carriage_mapping.ledger_name, ''),
          COALESCE(carriage_mapping.configured_at::text, '')
        ))::text
        ELSE inspected.mapping_semantic_fingerprint
      END AS patched_mapping_fingerprint
    FROM inspected
    CROSS JOIN carriage_mapping
  )
  SELECT
    transformed.sales_invoice_id,
    transformed.order_id,
    transformed.order_ref,
    transformed.document_lane,
    transformed.document_type,
    transformed.invoice_type,
    transformed.counterparty_name,
    transformed.amount_gbp,
    transformed.currency_code,
    transformed.reference_text,
    transformed.notes_text,
    transformed.sage_status,
    transformed.sage_invoice_id,
    transformed.sage_posted_at,
    transformed.commercial_payload,
    CASE
      WHEN transformed.patched_status <> transformed.payload_status
      THEN transformed.patched_resolved_payload || jsonb_build_object(
        'resolver_control',
        COALESCE(transformed.patched_resolved_payload -> 'resolver_control', '{}'::jsonb)
          || jsonb_build_object('status', transformed.patched_status, 'blocker', transformed.patched_blocker)
      )
      ELSE transformed.patched_resolved_payload
    END AS resolved_payload,
    transformed.patched_mapping_snapshot AS mapping_snapshot,
    transformed.patched_mapping_fingerprint AS mapping_semantic_fingerprint,
    transformed.patched_status AS payload_status,
    transformed.patched_blocker AS blocker,
    transformed.warning
  FROM transformed;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO service_role;

-- PostgreSQL dependencies remain attached to the renamed preserved function OID.
-- Recreate existing textual dependants so they bind back to the canonical resolver.
DO $$
DECLARE
  v_oid oid;
  v_definition text;
BEGIN
  FOR v_oid IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname NOT IN (
        'internal_resolved_customer_sales_sage_payload_v1',
        'internal_customer_sales_sage_payload_pre_shipping_recharge_v1'
      )
      AND p.prosrc LIKE '%internal_resolved_customer_sales_sage_payload_v1%'
  LOOP
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    EXECUTE v_definition;
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
COMMIT;
