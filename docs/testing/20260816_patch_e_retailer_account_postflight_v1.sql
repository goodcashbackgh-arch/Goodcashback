-- PATCH_E_RETAILER_ACCOUNT_POSTFLIGHT_V1
-- READ ONLY. No writes.

WITH funcs AS (
  SELECT
    p.proname,
    p.prosecdef AS security_definer,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config,
    pg_get_functiondef(p.oid) AS definition,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN ('internal_retailer_account_readiness_v1','internal_upsert_retailer_account_v1')
),
idx AS (
  SELECT indexname, indexdef
  FROM pg_indexes
  WHERE schemaname='public'
    AND indexname='retailer_accounts_one_active_shipper_retailer_uidx'
),
dupes AS (
  SELECT shipper_id, retailer_id, count(*)::int AS active_count
  FROM public.retailer_accounts
  WHERE shipper_id IS NOT NULL AND status='active'
  GROUP BY shipper_id, retailer_id
  HAVING count(*)>1
),
operational AS (
  SELECT o.shipper_id, o.retailer_id,
    count(DISTINCT ra.id) FILTER (WHERE ra.status='active')::int AS active_account_count
  FROM public.orders o
  LEFT JOIN public.retailer_accounts ra
    ON ra.shipper_id=o.shipper_id AND ra.retailer_id=o.retailer_id
  GROUP BY o.shipper_id,o.retailer_id
)
SELECT jsonb_build_object(
  'probe','PATCH_E_RETAILER_ACCOUNT_POSTFLIGHT_V1',
  'read_only',true,
  'ready',
    (SELECT count(*)=2 FROM funcs)
    AND NOT EXISTS (SELECT 1 FROM funcs WHERE security_definer=false)
    AND NOT EXISTS (SELECT 1 FROM funcs WHERE authenticated_execute=false)
    AND NOT EXISTS (SELECT 1 FROM funcs WHERE anon_execute=true)
    AND NOT EXISTS (SELECT 1 FROM funcs WHERE config NOT ILIKE '%search_path=public, pg_temp%')
    AND (SELECT count(*)=1 FROM idx)
    AND NOT EXISTS (SELECT 1 FROM dupes),
  'review_required',
    (SELECT count(*) FROM dupes),
  'checks',jsonb_build_object(
    'readiness_function_exists', EXISTS(SELECT 1 FROM funcs WHERE proname='internal_retailer_account_readiness_v1'),
    'writer_function_exists', EXISTS(SELECT 1 FROM funcs WHERE proname='internal_upsert_retailer_account_v1'),
    'security_definer', NOT EXISTS(SELECT 1 FROM funcs WHERE security_definer=false),
    'search_path_locked', NOT EXISTS(SELECT 1 FROM funcs WHERE config NOT ILIKE '%search_path=public, pg_temp%'),
    'authenticated_execute', NOT EXISTS(SELECT 1 FROM funcs WHERE authenticated_execute=false),
    'anon_execute_revoked', NOT EXISTS(SELECT 1 FROM funcs WHERE anon_execute=true),
    'one_active_account_index_present', (SELECT count(*)=1 FROM idx),
    'writer_validates_enabled_lane', COALESCE((SELECT definition ILIKE '%shipper_retailer_lane_not_enabled%' FROM funcs WHERE proname='internal_upsert_retailer_account_v1'),false),
    'writer_validates_shipper_hub', COALESCE((SELECT definition ILIKE '%delivery_hub_not_active_for_shipper%' FROM funcs WHERE proname='internal_upsert_retailer_account_v1'),false),
    'writer_rejects_second_active_account', COALESCE((SELECT definition ILIKE '%active_retailer_account_already_exists_for_lane%' FROM funcs WHERE proname='internal_upsert_retailer_account_v1'),false),
    'duplicate_active_pairs', (SELECT count(*) FROM dupes)
  ),
  'operational_pair_state',jsonb_build_object(
    'total_pairs',(SELECT count(*) FROM operational),
    'exactly_one_active_account',(SELECT count(*) FROM operational WHERE active_account_count=1),
    'missing_active_account',(SELECT count(*) FROM operational WHERE active_account_count=0),
    'ambiguous_active_accounts',(SELECT count(*) FROM operational WHERE active_account_count>1)
  ),
  'historical_rows_modified_by_probe',false
) AS result;
