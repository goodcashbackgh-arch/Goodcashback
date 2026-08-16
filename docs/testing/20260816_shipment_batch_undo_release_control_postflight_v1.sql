-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — POSTFLIGHT
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- READ ONLY. No repair/backfill. No Groupage mutation. No legacy mutation.
--
-- Baseline below was captured from the live database by
-- 20260816_shipment_batch_undo_release_control_preflight_v1.sql BEFORE the
-- Shipment Batch Undo migration was applied. The preflight returned READY with
-- missing_target_count=0 on 2026-08-16.
-- =============================================================================

WITH expected_baseline(
  signature,
  authority_class,
  expected_md5,
  expected_acl,
  expected_owner,
  expected_security_definer,
  expected_proconfig
) AS (
  VALUES
    (
      'shipper_create_groupage_movement_v1(uuid[],text,uuid)',
      'protected_groupage',
      '8691cf78f34912d9522f545ebb495529',
      '{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'internal_review_final_export_evidence_document_v1(uuid,text,text)',
      'protected_groupage',
      '87c619fbd1bcea84f90718dc538bf6ef',
      '{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'groupage_recompute_movement_status_v1(uuid)',
      'protected_groupage',
      'e78cc0c67e422a88afbae815bc600a0b',
      '{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'shipper_block_shipment_line_membership_mutation_v1()',
      'protected_line_trigger',
      'c56d6a1a2b2c1bf0ef751a07e3b33ff2',
      '{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      false,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'shipper_update_shipment_batch_header_v1(uuid,text,timestamp with time zone,timestamp with time zone,integer,text,text,text)',
      'authorised_existing_writer',
      '667aaeb9a45c844dc612948818ec1303',
      '{postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)',
      'authorised_existing_writer',
      '1f4686234ad78705e52b2dba2bda27f3',
      '{postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)',
      'authorised_existing_writer',
      '6404e0b7e2fd3905a461e4450967bee6',
      '{postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    ),
    (
      'shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)',
      'authorised_existing_writer',
      'd739071c439cff8ff7c8fa862a80c352',
      '{=X/postgres,postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
      'postgres',
      true,
      ARRAY['search_path=public, pg_temp']::text[]
    )
), function_defs AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    pg_get_functiondef(p.oid) AS definition,
    md5(pg_get_functiondef(p.oid)) AS md5,
    p.prosecdef AS security_definer,
    p.proconfig AS proconfig,
    p.proacl::text AS acl,
    pg_get_userbyid(p.proowner) AS owner_name
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
), comparisons AS (
  SELECT
    e.signature,
    e.authority_class,
    e.expected_md5,
    e.expected_acl,
    e.expected_owner,
    e.expected_security_definer,
    e.expected_proconfig,
    f.md5 AS live_md5,
    f.acl AS live_acl,
    f.owner_name AS live_owner,
    f.security_definer AS live_security_definer,
    f.proconfig AS live_proconfig,
    f.signature IS NOT NULL AS function_present,
    e.expected_md5 = f.md5 AS definition_unchanged,
    e.expected_acl IS NOT DISTINCT FROM f.acl AS acl_unchanged,
    e.expected_owner IS NOT DISTINCT FROM f.owner_name AS owner_unchanged,
    e.expected_security_definer IS NOT DISTINCT FROM f.security_definer AS security_definer_unchanged,
    e.expected_proconfig IS NOT DISTINCT FROM f.proconfig AS search_path_unchanged
  FROM expected_baseline e
  LEFT JOIN function_defs f USING(signature)
), protected_groupage AS (
  SELECT bool_and(
    function_present
    AND definition_unchanged
    AND acl_unchanged
    AND owner_unchanged
    AND security_definer_unchanged
    AND search_path_unchanged
  ) AS ok
  FROM comparisons
  WHERE authority_class='protected_groupage'
), protected_line AS (
  SELECT bool_and(
    function_present
    AND definition_unchanged
    AND acl_unchanged
    AND owner_unchanged
    AND security_definer_unchanged
    AND search_path_unchanged
  ) AS ok
  FROM comparisons
  WHERE authority_class='protected_line_trigger'
), writer_metadata AS (
  SELECT bool_and(
    function_present
    AND acl_unchanged
    AND owner_unchanged
    AND security_definer_unchanged
    AND search_path_unchanged
  ) AS ok
  FROM comparisons
  WHERE authority_class='authorised_existing_writer'
), undo AS (
  SELECT * FROM function_defs WHERE signature='shipper_undo_shipment_batch_v1(uuid,text)'
), writer_checks AS (
  SELECT jsonb_agg(jsonb_build_object(
    'signature',signature,
    'security_definer',security_definer,
    'search_path_ok',COALESCE(proconfig,ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp'],
    'contains_parent_batch_for_update',definition ILIKE '%shipper_shipment_batches%' AND definition ILIKE '%FOR UPDATE%',
    'acl',acl,
    'owner',owner_name,
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
    WHEN NOT COALESCE((SELECT ok FROM protected_groupage),false) THEN 'FAIL'
    WHEN NOT COALESCE((SELECT ok FROM protected_line),false) THEN 'FAIL'
    WHEN NOT COALESCE((SELECT ok FROM writer_metadata),false) THEN 'FAIL'
    WHEN NOT EXISTS(SELECT 1 FROM undo) THEN 'FAIL'
    WHEN COALESCE((SELECT security_definer FROM undo),false) = false THEN 'FAIL'
    WHEN NOT (COALESCE((SELECT proconfig FROM undo),ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']) THEN 'FAIL'
    WHEN has_function_privilege('anon','public.shipper_undo_shipment_batch_v1(uuid,text)','EXECUTE') THEN 'FAIL'
    WHEN NOT has_function_privilege('authenticated','public.shipper_undo_shipment_batch_v1(uuid,text)','EXECUTE') THEN 'FAIL'
    ELSE 'PASS'
  END,
  'baseline_source','20260816_shipment_batch_undo_release_control_preflight_v1.sql / live READY result supplied 2026-08-16',
  'protected_groupage_functions_unchanged',COALESCE((SELECT ok FROM protected_groupage),false),
  'protected_line_trigger_unchanged',COALESCE((SELECT ok FROM protected_line),false),
  'existing_writer_metadata_unchanged',COALESCE((SELECT ok FROM writer_metadata),false),
  'existing_writer_acls_unchanged',COALESCE((SELECT bool_and(acl_unchanged) FROM comparisons WHERE authority_class='authorised_existing_writer'),false),
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
