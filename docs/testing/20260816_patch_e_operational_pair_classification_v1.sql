-- PATCH_E_OPERATIONAL_PAIR_CLASSIFICATION_V1
-- READ ONLY. No writes.
-- Governing authority: MULTI_TENANT_ONBOARDING_ACCESS_MVP_COMPLETION_ADDENDUM_v1 section 7 / Patch E.

WITH order_pairs AS (
  SELECT
    o.shipper_id,
    o.retailer_id,
    count(*)::int AS order_count,
    min(o.created_at) AS first_order_at,
    max(o.created_at) AS last_order_at,
    array_agg(DISTINCT o.destination_hub_id ORDER BY o.destination_hub_id) AS destination_hub_ids
  FROM public.orders o
  GROUP BY o.shipper_id, o.retailer_id
),
active_accounts AS (
  SELECT
    ra.shipper_id,
    ra.retailer_id,
    count(*) FILTER (WHERE ra.status = 'active')::int AS active_account_count,
    array_agg(ra.id ORDER BY ra.id) FILTER (WHERE ra.status = 'active') AS active_account_ids,
    array_agg(DISTINCT ra.delivery_address_locked_to_hub_id ORDER BY ra.delivery_address_locked_to_hub_id)
      FILTER (WHERE ra.status = 'active') AS active_account_hub_ids
  FROM public.retailer_accounts ra
  WHERE ra.shipper_id IS NOT NULL
  GROUP BY ra.shipper_id, ra.retailer_id
),
enabled_pairs AS (
  SELECT
    sr.shipper_id,
    sr.retailer_id,
    sr.enabled
  FROM public.shipper_retailers sr
),
classification AS (
  SELECT
    op.shipper_id,
    s.name AS shipper_name,
    op.retailer_id,
    r.name AS retailer_name,
    op.order_count,
    op.first_order_at,
    op.last_order_at,
    op.destination_hub_ids,
    COALESCE(ep.enabled, false) AS shipper_retailer_enabled,
    COALESCE(aa.active_account_count, 0) AS active_account_count,
    COALESCE(aa.active_account_ids, ARRAY[]::uuid[]) AS active_account_ids,
    COALESCE(aa.active_account_hub_ids, ARRAY[]::uuid[]) AS active_account_hub_ids,
    CASE
      WHEN COALESCE(aa.active_account_count, 0) = 1 THEN 'ready_exactly_one_active_account'
      WHEN COALESCE(aa.active_account_count, 0) = 0 THEN 'missing_active_account'
      ELSE 'ambiguous_multiple_active_accounts'
    END AS readiness
  FROM order_pairs op
  LEFT JOIN public.shippers s ON s.id = op.shipper_id
  LEFT JOIN public.retailers r ON r.id = op.retailer_id
  LEFT JOIN enabled_pairs ep
    ON ep.shipper_id = op.shipper_id
   AND ep.retailer_id = op.retailer_id
  LEFT JOIN active_accounts aa
    ON aa.shipper_id = op.shipper_id
   AND aa.retailer_id = op.retailer_id
),
duplicates AS (
  SELECT
    ra.shipper_id,
    ra.retailer_id,
    count(*)::int AS active_account_count,
    array_agg(ra.id ORDER BY ra.id) AS active_account_ids
  FROM public.retailer_accounts ra
  WHERE ra.shipper_id IS NOT NULL
    AND ra.status = 'active'
  GROUP BY ra.shipper_id, ra.retailer_id
  HAVING count(*) > 1
),
enabled_without_account AS (
  SELECT
    sr.shipper_id,
    s.name AS shipper_name,
    sr.retailer_id,
    r.name AS retailer_name
  FROM public.shipper_retailers sr
  LEFT JOIN public.shippers s ON s.id = sr.shipper_id
  LEFT JOIN public.retailers r ON r.id = sr.retailer_id
  LEFT JOIN active_accounts aa
    ON aa.shipper_id = sr.shipper_id
   AND aa.retailer_id = sr.retailer_id
  WHERE sr.enabled = true
    AND COALESCE(aa.active_account_count, 0) = 0
),
hub_columns AS (
  SELECT
    c.table_name,
    c.ordinal_position,
    c.column_name,
    c.data_type,
    c.is_nullable
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name IN ('hubs', 'shipper_hubs')
)
SELECT jsonb_build_object(
  'probe', 'PATCH_E_OPERATIONAL_PAIR_CLASSIFICATION_V1',
  'read_only', true,
  'operational_pairs', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.order_count DESC, c.shipper_name, c.retailer_name) FROM classification c), '[]'::jsonb),
  'operational_pair_count', (SELECT count(*) FROM classification),
  'operational_pairs_ready', (SELECT count(*) FROM classification WHERE readiness = 'ready_exactly_one_active_account'),
  'operational_pairs_missing_account', (SELECT count(*) FROM classification WHERE readiness = 'missing_active_account'),
  'operational_pairs_ambiguous', (SELECT count(*) FROM classification WHERE readiness = 'ambiguous_multiple_active_accounts'),
  'duplicate_active_retailer_shipper_pairs', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.shipper_id, d.retailer_id) FROM duplicates d), '[]'::jsonb),
  'duplicate_active_pair_count', (SELECT count(*) FROM duplicates),
  'enabled_pairs_without_active_account_count', (SELECT count(*) FROM enabled_without_account),
  'enabled_pairs_without_active_account', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.shipper_name, e.retailer_name) FROM enabled_without_account e), '[]'::jsonb),
  'hub_columns', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.table_name, h.ordinal_position) FROM hub_columns h), '[]'::jsonb),
  'historical_rows_modified_by_probe', false
) AS result;
