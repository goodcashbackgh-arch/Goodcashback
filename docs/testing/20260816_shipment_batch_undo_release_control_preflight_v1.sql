-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — PRE-FLIGHT BASELINE
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- READ ONLY.
-- Run BEFORE applying 20260816123000_shipment_batch_undo_release_control_v1.sql.
--
-- Purpose:
--   Capture the exact live pre-build definition fingerprints, ACLs, security
--   mode and search_path of every protected authority and every pre-existing
--   writer this build is allowed to harden.
--
-- This file performs no INSERT/UPDATE/DELETE/DDL and does not call any mutation
-- RPC. Groupage is inspected only.
-- =============================================================================

WITH targets(signature, authority_class) AS (
  VALUES
    ('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)', 'protected_groupage'),
    ('public.internal_review_final_export_evidence_document_v1(uuid,text,text)', 'protected_groupage'),
    ('public.groupage_recompute_movement_status_v1(uuid)', 'protected_groupage'),
    ('public.shipper_block_shipment_line_membership_mutation_v1()', 'protected_line_trigger'),
    ('public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text)', 'authorised_existing_writer'),
    ('public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)', 'authorised_existing_writer'),
    ('public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)', 'authorised_existing_writer'),
    ('public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)', 'authorised_existing_writer')
), resolved AS (
  SELECT
    t.signature AS requested_signature,
    t.authority_class,
    to_regprocedure(t.signature) AS regprocedure
  FROM targets t
), live AS (
  SELECT
    r.requested_signature,
    r.authority_class,
    r.regprocedure,
    p.oid::regprocedure::text AS live_signature,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    p.proacl::text AS acl,
    p.prosecdef AS security_definer,
    p.proconfig AS proconfig,
    pg_get_userbyid(p.proowner) AS owner_name,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute
  FROM resolved r
  LEFT JOIN pg_proc p ON p.oid = r.regprocedure
), missing AS (
  SELECT COUNT(*)::integer AS count
  FROM live
  WHERE regprocedure IS NULL
), trigger_expected AS (
  SELECT
    definition_md5 AS live_md5,
    'c56d6a1a2b2c1bf0ef751a07e3b33ff2'::text AS migration_expected_md5
  FROM live
  WHERE requested_signature = 'public.shipper_block_shipment_line_membership_mutation_v1()'
)
SELECT jsonb_pretty(
  jsonb_build_object(
    'probe', 'shipment_batch_undo_release_control_preflight_v1',
    'result', CASE WHEN (SELECT count FROM missing) = 0 THEN 'READY' ELSE 'FAIL' END,
    'read_only', true,
    'missing_target_count', (SELECT count FROM missing),
    'trigger_fingerprint', (
      SELECT jsonb_build_object(
        'live_md5', live_md5,
        'migration_expected_md5', migration_expected_md5,
        'matches_current_migration_constant', live_md5 = migration_expected_md5
      )
      FROM trigger_expected
    ),
    'baseline', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'authority_class', authority_class,
          'requested_signature', requested_signature,
          'live_signature', live_signature,
          'definition_md5', definition_md5,
          'acl', acl,
          'owner', owner_name,
          'security_definer', security_definer,
          'search_path', proconfig,
          'anon_execute', anon_execute,
          'authenticated_execute', authenticated_execute,
          'service_role_execute', service_role_execute
        )
        ORDER BY authority_class, requested_signature
      )
      FROM live
    ), '[]'::jsonb)
  )
) AS result;
