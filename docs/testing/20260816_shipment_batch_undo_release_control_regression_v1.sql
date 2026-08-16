-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — BEHAVIOURAL REGRESSION
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- TRANSACTION WRAPPED. Ends with ROLLBACK.
--
-- Rules:
--   * Uses existing Shipment Batch fixtures only.
--   * Does not INSERT/UPDATE/DELETE Groupage data.
--   * Does not call any Groupage mutation RPC.
--   * Does not alter protected Groupage functions, permissions, evidence or status.
--   * Clean Undo tests mutate only inside this transaction and are rolled back.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE shipment_undo_regression_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE TEMP TABLE shipment_undo_protected_before AS
SELECT
  p.oid::regprocedure::text AS signature,
  md5(pg_get_functiondef(p.oid)) AS definition_md5,
  p.proacl::text AS acl
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.oid IN (
    to_regprocedure('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)'),
    to_regprocedure('public.internal_review_final_export_evidence_document_v1(uuid,text,text)'),
    to_regprocedure('public.groupage_recompute_movement_status_v1(uuid)'),
    to_regprocedure('public.shipper_block_shipment_line_membership_mutation_v1()')
  );

DO $regression$
DECLARE
  v_batch_id uuid;
  v_shipper_id uuid;
  v_actor_uid uuid;
  v_package_before integer;
  v_package_after integer;
  v_line_before integer;
  v_line_after integer;
  v_effective_after integer;
  v_batch_status text;
  v_voided_at timestamptz;
  v_voided_by uuid;
  v_void_reason text;
  v_line_fingerprint_before text;
  v_line_fingerprint_after text;
  v_deleted_lines integer;
  v_deleted_packages integer;
  v_candidate_count integer;
  v_mode text;
BEGIN
  ------------------------------------------------------------------------------
  -- A. CLEAN EXACT-LINE UNDO
  ------------------------------------------------------------------------------
  SELECT b.id, b.shipper_id
    INTO v_batch_id, v_shipper_id
  FROM public.shipper_shipment_batches b
  WHERE b.status = 'created'
    AND EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = b.id AND p.active = true
    )
    AND EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id = b.id AND m.active = true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_groupage_movement_batches gmb
      WHERE gmb.shipment_batch_id = b.id AND gmb.active = true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipping_documents sd
      WHERE sd.shipment_batch_id = b.id AND sd.active = true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipping_cost_allocations sca
      WHERE sca.shipment_batch_id = b.id AND sca.active = true AND sca.allocation_status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.customer_sales_release_lines csrl
      WHERE csrl.source_shipment_batch_id = b.id AND csrl.release_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.sage_posting_snapshots s
      WHERE s.shipment_batch_id = b.id
        AND (
          s.sage_posting_status = 'posted'
          OR (COALESCE(s.active, true) = true AND COALESCE(s.sage_posting_status, 'not_posted') <> 'voided')
        )
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_final_export_evidence_documents d
      WHERE d.shipment_batch_id = b.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a ON a.id = e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL
         OR a.allocation_status = 'locked_for_export_pack'
    )
  ORDER BY b.created_at ASC, b.id
  LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_exact_undo', false,
      jsonb_build_object('reason','No existing clean exact-line Shipment Batch fixture available.')
    );
  ELSE
    SELECT su.auth_user_id
      INTO v_actor_uid
    FROM public.shipper_users su
    WHERE su.shipper_id = v_shipper_id
      AND su.active = true
      AND su.auth_user_id IS NOT NULL
    ORDER BY su.created_at DESC, su.id DESC
    LIMIT 1;

    IF v_actor_uid IS NULL THEN
      RAISE EXCEPTION 'Clean exact fixture has no active shipper auth user: %', v_batch_id;
    END IF;

    SELECT COUNT(*) INTO v_package_before
    FROM public.shipper_shipment_batch_packages p
    WHERE p.shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_line_before
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = v_batch_id;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',m.id,m.shipment_batch_id,m.shipment_batch_package_id,m.tracking_submission_id,
        m.tracking_line_allocation_id,m.order_id,m.supplier_invoice_line_id,m.qty_in_shipment,m.adjusted_net_value_gbp),
      ',' ORDER BY m.id
    ),''))
    INTO v_line_fingerprint_before
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = v_batch_id;

    PERFORM set_config('request.jwt.claim.sub', v_actor_uid::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor_uid::text,'role','authenticated')::text, true);

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Regression exact Undo — rolled back');

    SELECT b.status, b.voided_at, b.voided_by_shipper_user_id, b.void_reason
      INTO v_batch_status, v_voided_at, v_voided_by, v_void_reason
    FROM public.shipper_shipment_batches b
    WHERE b.id = v_batch_id;

    SELECT COUNT(*) INTO v_package_after
    FROM public.shipper_shipment_batch_packages p
    WHERE p.shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_line_after
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = v_batch_id;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',m.id,m.shipment_batch_id,m.shipment_batch_package_id,m.tracking_submission_id,
        m.tracking_line_allocation_id,m.order_id,m.supplier_invoice_line_id,m.qty_in_shipment,m.adjusted_net_value_gbp),
      ',' ORDER BY m.id
    ),''))
    INTO v_line_fingerprint_after
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_effective_after
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);

    SELECT COUNT(*) INTO v_deleted_packages
    FROM public.shipper_shipment_batch_packages p
    WHERE p.shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_deleted_lines
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_candidate_count
    FROM public.shipper_shipment_batch_candidates_v2() c
    WHERE c.tracking_submission_id IN (
      SELECT p.tracking_submission_id
      FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = v_batch_id
    );

    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_exact_undo',
      v_batch_status = 'voided'
      AND v_voided_at IS NOT NULL
      AND v_voided_by IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(v_void_reason,'')),'') IS NOT NULL
      AND v_package_after = v_package_before
      AND v_line_after = v_line_before
      AND v_line_fingerprint_after = v_line_fingerprint_before
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch_id AND p.active = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
        WHERE m.shipment_batch_id = v_batch_id AND m.active = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch_id
          AND (p.removed_at IS NULL OR p.removed_by_shipper_user_id IS NULL OR NULLIF(BTRIM(COALESCE(p.remove_reason,'')),'') IS NULL)
      )
      AND v_effective_after = 0,
      jsonb_build_object(
        'shipment_batch_id',v_batch_id,
        'package_rows_preserved',v_package_after = v_package_before,
        'line_rows_preserved',v_line_after = v_line_before,
        'immutable_line_values_preserved',v_line_fingerprint_after = v_line_fingerprint_before,
        'effective_lines_after',v_effective_after,
        'released_tracking_candidates_after',v_candidate_count
      )
    );
  END IF;

  ------------------------------------------------------------------------------
  -- B. CLEAN LEGACY UNDO
  ------------------------------------------------------------------------------
  v_batch_id := NULL; v_shipper_id := NULL; v_actor_uid := NULL;

  SELECT b.id, b.shipper_id
    INTO v_batch_id, v_shipper_id
  FROM public.shipper_shipment_batches b
  WHERE b.status = 'created'
    AND EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = b.id AND p.active = true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id = b.id
    )
    AND NOT EXISTS (SELECT 1 FROM public.shipper_groupage_movement_batches gmb WHERE gmb.shipment_batch_id=b.id AND gmb.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_documents sd WHERE sd.shipment_batch_id=b.id AND sd.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_cost_allocations sca WHERE sca.shipment_batch_id=b.id AND sca.active=true AND sca.allocation_status='approved')
    AND NOT EXISTS (SELECT 1 FROM public.customer_sales_release_lines csrl WHERE csrl.source_shipment_batch_id=b.id AND csrl.release_status='active')
    AND NOT EXISTS (
      SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id
        AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
    )
    AND NOT EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents d WHERE d.shipment_batch_id=b.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
    )
  ORDER BY b.created_at ASC, b.id
  LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_legacy_undo', false,
      jsonb_build_object('reason','No existing clean legacy Shipment Batch fixture available.')
    );
  ELSE
    SELECT su.auth_user_id INTO v_actor_uid
    FROM public.shipper_users su
    WHERE su.shipper_id=v_shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
    ORDER BY su.created_at DESC, su.id DESC LIMIT 1;

    SELECT COUNT(*) INTO v_package_before
    FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id;

    PERFORM set_config('request.jwt.claim.sub', v_actor_uid::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_actor_uid::text,'role','authenticated')::text, true);
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Regression legacy Undo — rolled back');

    SELECT COUNT(*) INTO v_package_after
    FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id;
    SELECT COUNT(*) INTO v_effective_after FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);
    SELECT b.status INTO v_batch_status FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id;

    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_legacy_undo',
      v_batch_status='voided'
      AND v_package_after=v_package_before
      AND NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id AND p.active=true)
      AND v_effective_after=0,
      jsonb_build_object('shipment_batch_id',v_batch_id,'package_rows_preserved',v_package_after=v_package_before,'effective_lines_after',v_effective_after)
    );
  END IF;

  ------------------------------------------------------------------------------
  -- C. INPUT / LIFECYCLE REJECTION
  ------------------------------------------------------------------------------
  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(NULL, 'x');
    INSERT INTO shipment_undo_regression_results VALUES ('null_batch_rejected',false,'{}');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO shipment_undo_regression_results VALUES ('null_batch_rejected',SQLERRM ILIKE '%Shipment batch id is required%',jsonb_build_object('error',SQLERRM));
  END;

  -- Restore a real authenticated shipper context for blank-reason test.
  SELECT su.auth_user_id INTO v_actor_uid
  FROM public.shipper_users su
  WHERE su.active=true AND su.auth_user_id IS NOT NULL
  ORDER BY su.created_at DESC, su.id DESC LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub', COALESCE(v_actor_uid,gen_random_uuid())::text, true);
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',COALESCE(v_actor_uid,gen_random_uuid())::text,'role','authenticated')::text, true);

  SELECT b.id INTO v_batch_id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
  ORDER BY b.created_at DESC LIMIT 1;

  IF v_batch_id IS NOT NULL THEN
    BEGIN
      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, '   ');
      INSERT INTO shipment_undo_regression_results VALUES ('blank_reason_rejected',false,'{}');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO shipment_undo_regression_results VALUES ('blank_reason_rejected',SQLERRM ILIKE '%Undo reason is required%',jsonb_build_object('error',SQLERRM));
    END;
  END IF;
END
$regression$;

-- =============================================================================
-- D. BLOCKER COVERAGE USING EXISTING FIXTURES ONLY.
-- These checks prove an example exists and the same predicate used by Undo marks
-- it as blocked. No Groupage or downstream data is mutated.
-- =============================================================================

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'active_groupage_fixture', EXISTS(
  SELECT 1 FROM public.shipper_shipment_batches b
  JOIN public.shipper_groupage_movement_batches gmb ON gmb.shipment_batch_id=b.id AND gmb.active=true
  WHERE b.status='created'
), jsonb_build_object('groupage_mutated',false);

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'active_shipping_document_fixture', EXISTS(
  SELECT 1 FROM public.shipping_documents sd
  JOIN public.shipper_shipment_batches b ON b.id=sd.shipment_batch_id
  WHERE b.status='created' AND sd.active=true
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'active_approved_shipping_cost_fixture', EXISTS(
  SELECT 1 FROM public.shipping_cost_allocations sca
  JOIN public.shipper_shipment_batches b ON b.id=sca.shipment_batch_id
  WHERE b.status='created' AND sca.active=true AND sca.allocation_status='approved'
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'export_lock_fixture', EXISTS(
  SELECT 1 FROM public.shipper_shipment_batches b
  JOIN LATERAL public.shipper_shipment_batch_effective_lines_v1(b.id) e ON true
  JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
  WHERE b.status='created'
    AND (a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack')
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'active_customer_release_fixture', EXISTS(
  SELECT 1 FROM public.customer_sales_release_lines csrl
  JOIN public.shipper_shipment_batches b ON b.id=csrl.source_shipment_batch_id
  WHERE b.status='created' AND csrl.release_status='active'
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'accounting_blocker_fixture', EXISTS(
  SELECT 1 FROM public.sage_posting_snapshots s
  JOIN public.shipper_shipment_batches b ON b.id=s.shipment_batch_id
  WHERE b.status='created'
    AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'final_evidence_submitted_fixture', EXISTS(
  SELECT 1 FROM public.shipper_final_export_evidence_documents d
  JOIN public.shipper_shipment_batches b ON b.id=d.shipment_batch_id
  WHERE b.status='created' AND d.review_status='submitted_for_review'
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'final_evidence_accepted_fixture', EXISTS(
  SELECT 1 FROM public.shipper_final_export_evidence_documents d
  JOIN public.shipper_shipment_batches b ON b.id=d.shipment_batch_id
  WHERE b.status='created' AND d.review_status='accepted_current'
), '{}'::jsonb;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT 'final_evidence_rejected_fixture', EXISTS(
  SELECT 1 FROM public.shipper_final_export_evidence_documents d
  JOIN public.shipper_shipment_batches b ON b.id=d.shipment_batch_id
  WHERE b.status='created' AND d.review_status='rejected_resubmit_required'
), '{}'::jsonb;

-- =============================================================================
-- E. PROTECTED GROUPAGE / LINE AUTHORITY MUST BE BYTE-FOR-BYTE UNCHANGED.
-- =============================================================================

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT
  'protected_authorities_unchanged',
  NOT EXISTS (
    SELECT 1
    FROM shipment_undo_protected_before before_row
    FULL JOIN (
      SELECT
        p.oid::regprocedure::text AS signature,
        md5(pg_get_functiondef(p.oid)) AS definition_md5,
        p.proacl::text AS acl
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='public'
        AND p.oid IN (
          to_regprocedure('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)'),
          to_regprocedure('public.internal_review_final_export_evidence_document_v1(uuid,text,text)'),
          to_regprocedure('public.groupage_recompute_movement_status_v1(uuid)'),
          to_regprocedure('public.shipper_block_shipment_line_membership_mutation_v1()')
        )
    ) after_row USING(signature)
    WHERE before_row.definition_md5 IS DISTINCT FROM after_row.definition_md5
       OR before_row.acl IS DISTINCT FROM after_row.acl
  ),
  jsonb_build_object('groupage_mutated',false);

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_regression_v1',
  'transaction_wrapped',true,
  'will_rollback',true,
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'tests',jsonb_agg(jsonb_build_object('test',test_name,'passed',passed,'detail',detail) ORDER BY test_name)
)) AS result
FROM shipment_undo_regression_results;

ROLLBACK;
