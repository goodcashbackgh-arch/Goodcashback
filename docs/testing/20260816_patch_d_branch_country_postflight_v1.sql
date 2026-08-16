-- PATCH_D_BRANCH_COUNTRY_POSTFLIGHT_V1
-- READ ONLY. No writes.

WITH fn AS (
  SELECT
    p.proname,
    p.prosecdef AS security_definer,
    pg_get_functiondef(p.oid) AS definition,
    COALESCE(array_to_string(p.proconfig, ','), '') AS config
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'internal_upsert_shipper_branch_v1',
      'internal_upsert_importer_branch_v1'
    )
),
shipper_fn AS (
  SELECT * FROM fn WHERE proname = 'internal_upsert_shipper_branch_v1'
),
importer_fn AS (
  SELECT * FROM fn WHERE proname = 'internal_upsert_importer_branch_v1'
),
branch_country_counts AS (
  SELECT
    s.id AS shipper_id,
    s.name AS shipper_name,
    count(DISTINCT sc.country_id) FILTER (WHERE c.active = true)::int AS active_country_count,
    array_agg(DISTINCT sc.country_id) FILTER (WHERE c.active = true) AS active_country_ids
  FROM public.shippers s
  LEFT JOIN public.shipper_countries sc ON sc.shipper_id = s.id
  LEFT JOIN public.countries c ON c.id = sc.country_id
  WHERE s.active = true
  GROUP BY s.id, s.name
),
importer_alignment AS (
  SELECT
    i.id AS importer_id,
    i.company_name,
    i.shipper_id,
    i.country_id AS importer_country_id,
    b.active_country_count,
    CASE
      WHEN b.active_country_count = 1 THEN b.active_country_ids[1]
      ELSE NULL
    END AS resolved_branch_country_id,
    CASE
      WHEN b.active_country_count = 1 AND i.country_id = b.active_country_ids[1] THEN true
      ELSE false
    END AS aligned
  FROM public.importers i
  LEFT JOIN branch_country_counts b ON b.shipper_id = i.shipper_id
  WHERE i.active = true
),
checks AS (
  SELECT jsonb_build_object(
    'shipper_writer_exists', EXISTS (SELECT 1 FROM shipper_fn),
    'importer_writer_exists', EXISTS (SELECT 1 FROM importer_fn),
    'shipper_security_definer', COALESCE((SELECT security_definer FROM shipper_fn LIMIT 1), false),
    'importer_security_definer', COALESCE((SELECT security_definer FROM importer_fn LIMIT 1), false),
    'shipper_search_path_locked', COALESCE((SELECT config LIKE '%search_path=public, pg_temp%' FROM shipper_fn LIMIT 1), false),
    'importer_search_path_locked', COALESCE((SELECT config LIKE '%search_path=public, pg_temp%' FROM importer_fn LIMIT 1), false),
    'shipper_rejects_not_ready', COALESCE((SELECT definition LIKE '%shipper_branch_country_not_ready%' FROM shipper_fn LIMIT 1), false),
    'shipper_rejects_country_mismatch', COALESCE((SELECT definition LIKE '%shipper_branch_country_mismatch%' FROM shipper_fn LIMIT 1), false),
    'importer_derives_country_from_branch', COALESCE((SELECT definition LIKE '%v_resolved_country_id%' AND definition LIKE '%country_id = v_resolved_country_id%' FROM importer_fn LIMIT 1), false),
    'importer_rejects_not_ready', COALESCE((SELECT definition LIKE '%shipper_branch_country_not_ready%' FROM importer_fn LIMIT 1), false),
    'importer_rejects_submitted_mismatch', COALESCE((SELECT definition LIKE '%branch_importer_country_mismatch%' FROM importer_fn LIMIT 1), false),
    'historical_mismatch_requires_review', COALESCE((SELECT definition LIKE '%existing_importer_country_mismatch_requires_review%' FROM importer_fn LIMIT 1), false)
  ) AS value
),
status AS (
  SELECT
    value,
    NOT EXISTS (
      SELECT 1
      FROM jsonb_each(value) e
      WHERE e.value <> 'true'::jsonb
    ) AS structural_ready
  FROM checks
)
SELECT jsonb_build_object(
  'probe', 'PATCH_D_BRANCH_COUNTRY_POSTFLIGHT_V1',
  'read_only', true,
  'ready', status.structural_ready,
  'review_required', CASE WHEN status.structural_ready THEN 0 ELSE 1 END,
  'checks', status.value,
  'active_branch_country_state', COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.shipper_name) FROM branch_country_counts b), '[]'::jsonb),
  'existing_importer_alignment', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.company_name) FROM importer_alignment i), '[]'::jsonb),
  'historical_rows_modified_by_probe', false
) AS result
FROM status;
