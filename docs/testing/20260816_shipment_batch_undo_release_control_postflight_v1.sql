-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — postflight
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- READ ONLY. No repair/backfill. No Groupage mutation. No legacy mutation.
-- =============================================================================

WITH function_defs AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    pg_get_functiondef(p.oid) AS definition,
    md5(pg_get_functiondef(p.oid)) AS md5,
    p.prosecdef AS security_definer,
    p.proconfig AS proconfig,
    p.proacl::text AS acl
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
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
),
undo AS (
  SELECT * FROM function_defs
  WHERE signature = 'shipper_undo_shipment_batch_v1(uuid,text)'
),
authorised_writers AS (
  SELECT * FROM function_defs
  WHERE signature IN (
    'shipper_update_shipment_batch_header_v1(uuid,text,timestamp with time zone,timestamp with time zone,integer,text,text,text)',
    'shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)',
    'shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)',
    'shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)'
  )
),
protected_authorities AS (
  SELECT * FROM function_defs
  WHERE signature IN (
    'shipper_create_groupage_movement_v1(uuid[],text,uuid)',
    'internal_review_final_export_evidence_document_v1(uuid,text,text)',
    'groupage_recompute_movement_status_v1(uuid)',
    'shipper_block_shipment_line_membership_mutation_v1()'
  )
),
writer_checks AS (
  SELECT jsonb_agg(
    jsonb_build_object(
      'signature', signature,
      'security_definer', security_definer,
      'search_path_ok', COALESCE(proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp'],
      'contains_parent_batch_for_update', definition ILIKE '%shipper_shipment_batches%' AND definition ILIKE '%FOR UPDATE%',
      'acl', acl,
      'definition_md5', md5
    ) ORDER BY signature
  ) AS result
  FROM authorised_writers
),
protected_checks AS (
  SELECT jsonb_agg(
    jsonb_build_object(
      'signature', signature,
      'definition_md5', md5,
      'acl', acl,
      'security_definer', security_definer,
      'search_path_ok', COALESCE(proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']
    ) ORDER BY signature
  ) AS result
  FROM protected_authorities
),
live_integrity AS (
  SELECT jsonb_build_object(
    'active_packages_in_voided_batches', (
      SELECT COUNT(*) FROM public.shipper_shipment_batch_packages p
      JOIN public.shipper_shipment_batches b ON b.id = p.shipment_batch_id
      WHERE p.active = true AND b.status = 'voided'
    ),
    'active_exact_lines_in_voided_batches', (
      SELECT COUNT(*) FROM public.shipper_shipment_batch_line_memberships m
      JOIN public.shipper_shipment_batches b ON b.id = m.shipment_batch_id
      WHERE m.active = true AND b.status = 'voided'
    ),
    'active_exact_lines_under_inactive_packages', (
      SELECT COUNT(*) FROM public.shipper_shipment_batch_line_memberships m
      JOIN public.shipper_shipment_batch_packages p ON p.id = m.shipment_batch_package_id
      WHERE m.active = true AND p.active = false
    ),
    'duplicate_active_tracking_memberships', (
      SELECT COUNT(*) FROM (
        SELECT tracking_submission_id
        FROM public.shipper_shipment_batch_packages
        WHERE active = true
        GROUP BY tracking_submission_id
        HAVING COUNT(*) > 1
      ) d
    ),
    'voided_batches_missing_audit', (
      SELECT COUNT(*) FROM public.shipper_shipment_batches b
      WHERE b.status = 'voided'
        AND (b.voided_at IS NULL OR b.voided_by_shipper_user_id IS NULL OR NULLIF(BTRIM(COALESCE(b.void_reason,'')), '') IS NULL)
    )
  ) AS result
),
latest_safety_map AS (
  SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC) AS result
  FROM (
    SELECT
      b.id AS shipment_batch_id,
      b.booking_ref,
      b.created_at,
      b.status,
      b.dispatched_at,
      (SELECT COUNT(*) FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true) AS active_package_count,
      (SELECT COUNT(*) FROM public.shipper_shipment_batch_line_memberships m WHERE m.shipment_batch_id=b.id AND m.active=true) AS active_exact_line_count,
      EXISTS (
        SELECT 1 FROM public.shipper_groupage_movement_batches gmb
        WHERE gmb.shipment_batch_id=b.id AND gmb.active=true
      ) AS blocks_active_groupage,
      EXISTS (
        SELECT 1 FROM public.shipping_documents sd
        WHERE sd.shipment_batch_id=b.id AND sd.active=true
      ) AS blocks_active_shipping_document,
      EXISTS (
        SELECT 1 FROM public.shipping_cost_allocations sca
        WHERE sca.shipment_batch_id=b.id AND sca.active=true AND sca.allocation_status='approved'
      ) AS blocks_active_shipping_cost,
      EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
        JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
        WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
      ) AS blocks_export_lock,
      EXISTS (
        SELECT 1 FROM public.customer_sales_release_lines csrl
        WHERE csrl.source_shipment_batch_id=b.id AND csrl.release_status='active'
      ) AS blocks_active_customer_release,
      EXISTS (
        SELECT 1 FROM public.sage_posting_snapshots s
        WHERE s.shipment_batch_id=b.id
          AND (
            s.sage_posting_status='posted'
            OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided')
          )
      ) AS blocks_accounting,
      EXISTS (
        SELECT 1 FROM public.shipper_final_export_evidence_documents d
        WHERE d.shipment_batch_id=b.id
      ) AS blocks_any_final_evidence,
      EXISTS (
        SELECT 1 FROM public.invoice_adjustment_consumption_ledger l
        WHERE l.shipment_batch_id=b.id AND l.active=true AND l.outcome='progressed_allocated'
      ) AS has_mutable_progressed_adjustment,
      EXISTS (
        SELECT 1 FROM public.customer_sales_release_lines csrl
        WHERE csrl.source_shipment_batch_id=b.id AND csrl.release_status='reversed'
      ) AS has_reversed_customer_release_history,
      CASE
        WHEN b.status <> 'created' THEN 'BLOCK_STATUS'
        WHEN NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true) THEN 'BLOCK_NO_ACTIVE_PACKAGES'
        WHEN EXISTS (SELECT 1 FROM public.shipper_groupage_movement_batches gmb WHERE gmb.shipment_batch_id=b.id AND gmb.active=true) THEN 'BLOCK_ACTIVE_GROUPAGE'
        WHEN EXISTS (SELECT 1 FROM public.shipping_documents sd WHERE sd.shipment_batch_id=b.id AND sd.active=true) THEN 'BLOCK_ACTIVE_SHIPPING_DOCUMENT'
        WHEN EXISTS (SELECT 1 FROM public.shipping_cost_allocations sca WHERE sca.shipment_batch_id=b.id AND sca.active=true AND sca.allocation_status='approved') THEN 'BLOCK_ACTIVE_SHIPPING_COST'
        WHEN EXISTS (
          SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
          JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
          WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
        ) THEN 'BLOCK_EXPORT_LOCK'
        WHEN EXISTS (SELECT 1 FROM public.customer_sales_release_lines csrl WHERE csrl.source_shipment_batch_id=b.id AND csrl.release_status='active') THEN 'BLOCK_ACTIVE_CUSTOMER_RELEASE'
        WHEN EXISTS (
          SELECT 1 FROM public.sage_posting_snapshots s
          WHERE s.shipment_batch_id=b.id
            AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
        ) THEN 'BLOCK_ACCOUNTING'
        WHEN EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents d WHERE d.shipment_batch_id=b.id) THEN 'BLOCK_FINAL_EVIDENCE'
        ELSE 'UNDO_CANDIDATE'
      END AS undo_state
    FROM public.shipper_shipment_batches b
    ORDER BY b.created_at DESC
    LIMIT 30
  ) x
)
SELECT jsonb_pretty(jsonb_build_object(
  'probe', 'shipment_batch_undo_release_control_postflight_v1',
  'undo_rpc', (
    SELECT jsonb_build_object(
      'exists', EXISTS(SELECT 1 FROM undo),
      'security_definer', COALESCE((SELECT security_definer FROM undo), false),
      'search_path_ok', COALESCE((SELECT proconfig FROM undo), ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp'],
      'anon_execute', has_function_privilege('anon','public.shipper_undo_shipment_batch_v1(uuid,text)','EXECUTE'),
      'authenticated_execute', has_function_privilege('authenticated','public.shipper_undo_shipment_batch_v1(uuid,text)','EXECUTE'),
      'locks_batch', COALESCE((SELECT definition ILIKE '%shipper_shipment_batches%FOR UPDATE%' FROM undo), false),
      'uses_create_advisory_locks', COALESCE((SELECT definition ILIKE '%pg_advisory_xact_lock(hashtext(v_package.order_id::text))%' AND definition ILIKE '%pg_advisory_xact_lock(hashtext(v_package.tracking_submission_id::text))%' FROM undo), false),
      'deactivates_packages', COALESCE((SELECT definition ILIKE '%shipper_shipment_batch_packages%SET active = false%' FROM undo), false),
      'deactivates_exact_lines', COALESCE((SELECT definition ILIKE '%shipper_shipment_batch_line_memberships%SET active = false%' FROM undo), false),
      'voids_parent_with_audit', COALESCE((SELECT definition ILIKE '%status = ''voided''%' AND definition ILIKE '%voided_at = now()%' AND definition ILIKE '%voided_by_shipper_user_id%' AND definition ILIKE '%void_reason%' FROM undo), false),
      'groupage_read_only_blocker', COALESCE((SELECT definition ILIKE '%shipper_groupage_movement_batches%' AND definition ILIKE '%gmb.active = true%' FROM undo), false),
      'blocks_active_shipping_document', COALESCE((SELECT definition ILIKE '%shipping_documents%' AND definition ILIKE '%sd.active = true%' FROM undo), false),
      'blocks_active_approved_shipping_cost', COALESCE((SELECT definition ILIKE '%shipping_cost_allocations%' AND definition ILIKE '%allocation_status = ''approved''%' FROM undo), false),
      'blocks_export_lock', COALESCE((SELECT definition ILIKE '%locked_for_export_pack_at IS NOT NULL%' AND definition ILIKE '%allocation_status = ''locked_for_export_pack''%' FROM undo), false),
      'blocks_active_customer_release', COALESCE((SELECT definition ILIKE '%source_shipment_batch_id%' AND definition ILIKE '%release_status = ''active''%' FROM undo), false),
      'blocks_posted_or_active_accounting', COALESCE((SELECT definition ILIKE '%sage_posting_status = ''posted''%' AND definition ILIKE '%sage_posting_status, ''not_posted''%<> ''voided''%' FROM undo), false),
      'blocks_any_final_evidence', COALESCE((SELECT definition ILIKE '%shipper_final_export_evidence_documents%' AND definition ILIKE '%WHERE d.shipment_batch_id = p_shipment_batch_id%' FROM undo), false),
      'does_not_block_dispatched_at', COALESCE((SELECT definition NOT ILIKE '%dispatched_at%RAISE EXCEPTION%' FROM undo), false),
      'rebuilds_mutable_progressed_adjustment', COALESCE((SELECT definition ILIKE '%Progressed allocation rebuilt after governed Shipment Batch Undo.%' FROM undo), false),
      'definition_md5', (SELECT md5 FROM undo)
    )
  ),
  'authorised_writer_hardening', (SELECT result FROM writer_checks),
  'protected_authorities_current_fingerprints', (SELECT result FROM protected_checks),
  'protected_line_mutation_trigger_expected_md5', 'c56d6a1a2b2c1bf0ef751a07e3b33ff2',
  'protected_line_mutation_trigger_matches', COALESCE((SELECT md5 = 'c56d6a1a2b2c1bf0ef751a07e3b33ff2' FROM protected_authorities WHERE signature='shipper_block_shipment_line_membership_mutation_v1()'), false),
  'live_integrity', (SELECT result FROM live_integrity),
  'latest_batch_safety_map', COALESCE((SELECT result FROM latest_safety_map), '[]'::jsonb)
)) AS result;
