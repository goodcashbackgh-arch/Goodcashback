-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — POSTFLIGHT
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- READ ONLY. No repair/backfill. No Groupage mutation. No legacy mutation.
--
-- IMPORTANT:
--   Run 20260816_shipment_batch_undo_release_control_preflight_v1.sql BEFORE the
--   migration. Freeze the returned pre-build MD5/ACL values into expected_baseline
--   below before using this file. Until then this postflight MUST report
--   BASELINE_REQUIRED and cannot report PASS.
-- =============================================================================

WITH expected_baseline(signature, expected_md5, expected_acl) AS (
  VALUES
    ('shipper_create_groupage_movement_v1(uuid[],text,uuid)', NULL::text, NULL::text),
    ('internal_review_final_export_evidence_document_v1(uuid,text,text)', NULL::text, NULL::text),
    ('groupage_recompute_movement_status_v1(uuid)', NULL::text, NULL::text),
    ('shipper_block_shipment_line_membership_mutation_v1()', NULL::text, NULL::text),
    ('shipper_update_shipment_batch_header_v1(uuid,text,timestamp with time zone,timestamp with time zone,integer,text,text,text)', NULL::text, NULL::text),
    ('shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)', NULL::text, NULL::text),
    ('shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)', NULL::text, NULL::text),
    ('shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)', NULL::text, NULL::text)
), function_defs AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    pg_get_functiondef(p.oid) AS definition,
    md5(pg_get_functiondef(p.oid)) AS md5,
    p.prosecdef AS security_definer,
    p.proconfig AS proconfig,
    p.proacl::text AS acl
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.oid IN (
      to_regprocedure('public.shipper_undo_shipment_batch_v1(uuid,text)'),
      to_regprocedure('public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text)'),
      to_regprocedure('public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)'),
      to_regprocedure('public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)'),
      to_regprocedure('public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)'),
      to_regprocedure('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)'),
      to_regprocedure('public.internal_review_final_export_evidence_document_v1(uuid,text,text)'),
      to_regprocedure('public.groupage_recompute_movement_status_v1(uuid)'),
      to_regprocedure('public.shipper_block_shipment_line_membership_mutation_v1()')
    )
), baseline_status AS (
  SELECT
    COUNT(*) FILTER (WHERE expected_md5 IS NULL OR expected_acl IS NULL)::integer AS missing_baseline_count
  FROM expected_baseline
), comparisons AS (
  SELECT
    e.signature,
    e.expected_md5,
    e.expected_acl,
    f.md5 AS live_md5,
    f.acl AS live_acl,
    e.expected_md5 IS NOT NULL AND e.expected_md5 = f.md5 AS definition_unchanged,
    e.expected_acl IS NOT NULL AND e.expected_acl IS NOT DISTINCT FROM f.acl AS acl_unchanged
  FROM expected_baseline e
  LEFT JOIN function_defs f USING(signature)
), protected_groupage AS (
  SELECT bool_and(definition_unchanged AND acl_unchanged) AS ok
  FROM comparisons
  WHERE signature IN (
    'shipper_create_groupage_movement_v1(uuid[],text,uuid)',
    'internal_review_final_export_evidence_document_v1(uuid,text,text)',
    'groupage_recompute_movement_status_v1(uuid)'
  )
), protected_line AS (
  SELECT bool_and(definition_unchanged AND acl_unchanged) AS ok
  FROM comparisons
  WHERE signature='shipper_block_shipment_line_membership_mutation_v1()'
), writer_acls AS (
  SELECT bool_and(acl_unchanged) AS ok
  FROM comparisons
  WHERE signature IN (
    'shipper_update_shipment_batch_header_v1(uuid,text,timestamp with time zone,timestamp with time zone,integer,text,text,text)',
    'shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)',
    'shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)',
    'shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)'
  )
), undo AS (
  SELECT * FROM function_defs WHERE signature='shipper_undo_shipment_batch_v1(uuid,text)'
), writer_checks AS (
  SELECT jsonb_agg(jsonb_build_object(
    'signature',signature,
    'security_definer',security_definer,
    'search_path_ok',COALESCE(proconfig,ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp'],
    'contains_parent_batch_for_update',definition ILIKE '%shipper_shipment_batches%' AND definition ILIKE '%FOR UPDATE%',
    'acl',acl,
    'definition_md5',md5
  ) ORDER BY signature) AS result
  FROM function_defs
  WHERE signature IN (
    'shipper_update_shipment_batch_header_v1(uuid,text,timestamp with time zone,timestamp with time zone,integer,text,text,text)',
    'shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)',
    'shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)',
    'shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)'
  )
), live_integrity AS (
  SELECT jsonb_build_object(
    'active_packages_in_voided_batches',(SELECT COUNT(*) FROM public.shipper_shipment_batch_packages p JOIN public.shipper_shipment_batches b ON b.id=p.shipment_batch_id WHERE p.active=true AND b.status='voided'),
    'active_exact_lines_in_voided_batches',(SELECT COUNT(*) FROM public.shipper_shipment_batch_line_memberships m JOIN public.shipper_shipment_batches b ON b.id=m.shipment_batch_id WHERE m.active=true AND b.status='voided'),
    'active_exact_lines_under_inactive_packages',(SELECT COUNT(*) FROM public.shipper_shipment_batch_line_memberships m JOIN public.shipper_shipment_batch_packages p ON p.id=m.shipment_batch_package_id WHERE m.active=true AND p.active=false),
    'duplicate_active_tracking_memberships',(SELECT COUNT(*) FROM (SELECT tracking_submission_id FROM public.shipper_shipment_batch_packages WHERE active=true GROUP BY tracking_submission_id HAVING COUNT(*)>1) d),
    'voided_batches_missing_audit',(SELECT COUNT(*) FROM public.shipper_shipment_batches b WHERE b.status='voided' AND (b.voided_at IS NULL OR b.voided_by_shipper_user_id IS NULL OR NULLIF(BTRIM(COALESCE(b.void_reason,'')),'') IS NULL))
  ) AS result
)
SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_postflight_v1',
  'result',CASE
    WHEN (SELECT missing_baseline_count FROM baseline_status) > 0 THEN 'BASELINE_REQUIRED'
    WHEN NOT COALESCE((SELECT ok FROM protected_groupage),false) THEN 'FAIL'
    WHEN NOT COALESCE((SELECT ok FROM protected_line),false) THEN 'FAIL'
    WHEN NOT COALESCE((SELECT ok FROM writer_acls),false) THEN 'FAIL'
    WHEN NOT EXISTS(SELECT 1 FROM undo) THEN 'FAIL'
    ELSE 'PASS'
  END,
  'missing_baseline_count',(SELECT missing_baseline_count FROM baseline_status),
  'protected_groupage_functions_unchanged',COALESCE((SELECT ok FROM protected_groupage),false),
  'protected_line_trigger_unchanged',COALESCE((SELECT ok FROM protected_line),false),
  'existing_writer_acls_unchanged',COALESCE((SELECT ok FROM writer_acls),false),
  'baseline_comparisons',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY signature) FROM comparisons c),'[]'::jsonb),
  'undo_rpc',(
    SELECT jsonb_build_object(
      'exists',true,
      'security_definer',security_definer,
      'search_path_ok',COALESCE(proconfig,ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp'],
      'anon_execute',has_function_privilege('anon','public.shipper_undo_shipment_batch_v1(uuid,text)','EXECUTE'),
      'authenticated_execute',has_function_privilege('authenticated','public.shipper_undo_shipment_batch_v1(uuid,text)','EXECUTE'),
      'groupage_read_only_blocker',definition ILIKE '%shipper_groupage_movement_batches%' AND definition ILIKE '%gmb.active = true%',
      'blocks_any_final_evidence',definition ILIKE '%shipper_final_export_evidence_documents%' AND definition ILIKE '%WHERE d.shipment_batch_id = p_shipment_batch_id%',
      'definition_md5',md5
    ) FROM undo
  ),
  'authorised_writer_hardening',(SELECT result FROM writer_checks),
  'live_integrity',(SELECT result FROM live_integrity)
)) AS result;
