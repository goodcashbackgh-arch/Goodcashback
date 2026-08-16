-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — BEHAVIOURAL REGRESSION
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- TRANSACTION WRAPPED. ALWAYS ENDS WITH ROLLBACK.
--
-- Safety rules:
--   * The installed product runtime is not changed by this file.
--   * Controlled NON-GROUPAGE fixtures are created only inside rollback-only
--     subtransactions and are never committed.
--   * Groupage is READ ONLY. This file never inserts, updates, deletes, cancels,
--     excludes, reviews, recomputes or otherwise mutates Groupage state.
--   * Existing protected function definitions/ACLs are fingerprinted before and
--     after the regression transaction.
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

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.clean_legacy_batch()
RETURNS uuid
LANGUAGE sql
AS $$
  SELECT b.id
  FROM public.shipper_shipment_batches b
  WHERE b.status = 'created'
    AND EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = b.id
        AND p.active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id = b.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_groupage_movement_batches gmb
      WHERE gmb.shipment_batch_id = b.id
        AND gmb.active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipping_documents sd
      WHERE sd.shipment_batch_id = b.id
        AND sd.active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipping_cost_allocations sca
      WHERE sca.shipment_batch_id = b.id
        AND sca.active = true
        AND sca.allocation_status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines csrl
      WHERE csrl.source_shipment_batch_id = b.id
        AND csrl.release_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.sage_posting_snapshots s
      WHERE s.shipment_batch_id = b.id
        AND (
          s.sage_posting_status = 'posted'
          OR (
            COALESCE(s.active, true) = true
            AND COALESCE(s.sage_posting_status, 'not_posted') <> 'voided'
          )
        )
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_final_export_evidence_documents d
      WHERE d.shipment_batch_id = b.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a
        ON a.id = e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL
         OR a.allocation_status = 'locked_for_export_pack'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.customer_sales_release_lines r
        ON r.tracking_line_allocation_id = e.tracking_line_allocation_id
       AND r.release_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.invoice_adjustment_consumption_ledger l
        ON l.source_allocation_id = e.tracking_line_allocation_id
       AND l.active = true
       AND l.outcome = 'progressed_allocated'
    )
  ORDER BY
    CASE WHEN b.id = '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid THEN 0 ELSE 1 END,
    b.created_at,
    b.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.set_shipper_auth_for_batch(p_batch_id uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_uid uuid;
BEGIN
  SELECT su.auth_user_id
    INTO v_uid
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su
    ON su.shipper_id = b.shipper_id
   AND su.active = true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id = p_batch_id
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No active shipper auth user for batch %', p_batch_id;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text,
    true
  );
  RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.base_actor(p_batch_id uuid)
RETURNS TABLE(shipper_user_id uuid, auth_user_id uuid, shipper_id uuid, importer_id uuid)
LANGUAGE sql
AS $$
  SELECT su.id, su.auth_user_id, b.shipper_id, b.importer_id
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su
    ON su.shipper_id = b.shipper_id
   AND su.active = true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id = p_batch_id
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.assert_real_blocker(
  p_test_name text,
  p_batch_id uuid,
  p_expected_error text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_error text;
BEGIN
  IF p_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      p_test_name,
      false,
      jsonb_build_object('reason', 'No suitable existing read-only fixture available.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(p_batch_id);

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(
      p_batch_id,
      'Regression blocker probe — rolled back'
    );
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      p_test_name,
      v_error ILIKE '%' || p_expected_error || '%',
      jsonb_build_object('shipment_batch_id', p_batch_id, 'error', v_error)
    );
  END;
END;
$$;

-- -----------------------------------------------------------------------------
-- 1. CLEAN LEGACY UNDO
-- -----------------------------------------------------------------------------

DO $clean_legacy$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_pass boolean := false;
  v_before_packages integer;
  v_after_packages integer;
  v_effective_after integer;
  v_status text;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_legacy_undo', false,
      jsonb_build_object('reason', 'No clean legacy base batch available.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    SELECT COUNT(*) INTO v_before_packages
    FROM public.shipper_shipment_batch_packages
    WHERE shipment_batch_id = v_batch_id;

    PERFORM public.shipper_undo_shipment_batch_v1(
      v_batch_id,
      'Regression clean legacy Undo — rolled back'
    );

    SELECT COUNT(*) INTO v_after_packages
    FROM public.shipper_shipment_batch_packages
    WHERE shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_effective_after
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);

    SELECT status INTO v_status
    FROM public.shipper_shipment_batches
    WHERE id = v_batch_id;

    v_pass :=
      v_status = 'voided'
      AND v_before_packages = v_after_packages
      AND v_effective_after = 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch_id
          AND p.active = true
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch_id
          AND (
            p.removed_at IS NULL
            OR p.removed_by_shipper_user_id IS NULL
            OR NULLIF(BTRIM(COALESCE(p.remove_reason, '')), '') IS NULL
          )
      );

    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_legacy_undo',
      v_pass AND v_error = '__REGRESSION_ROLLBACK__',
      jsonb_build_object(
        'shipment_batch_id', v_batch_id,
        'package_rows_preserved', v_before_packages = v_after_packages,
        'effective_lines_after', v_effective_after,
        'rolled_back', v_error = '__REGRESSION_ROLLBACK__'
      )
    );
  END;
END
$clean_legacy$;

-- -----------------------------------------------------------------------------
-- 2. CONTROLLED EXACT-LINE UNDO
--    Build an exact immutable snapshot on the clean legacy base only inside this
--    subtransaction, exercise Undo, verify one-way deactivation/immutability,
--    then force rollback of both fixture and Undo.
-- -----------------------------------------------------------------------------

DO $clean_exact$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_inserted integer := 0;
  v_before_fingerprint text;
  v_after_fingerprint text;
  v_active_lines_after integer;
  v_effective_after integer;
  v_status text;
  v_candidate_count integer;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_exact_undo', false,
      jsonb_build_object('reason', 'No clean legacy base available for controlled exact snapshot.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    INSERT INTO public.shipper_shipment_batch_line_memberships (
      shipment_batch_id,
      shipment_batch_package_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      order_id,
      supplier_invoice_line_id,
      qty_in_shipment,
      adjusted_net_value_gbp
    )
    SELECT
      p.shipment_batch_id,
      p.id,
      p.tracking_submission_id,
      a.id,
      a.order_id,
      a.supplier_invoice_line_id,
      a.qty_allocated,
      COALESCE(a.adjusted_net_value_gbp, 0)
    FROM public.shipper_shipment_batch_packages p
    JOIN public.order_tracking_line_allocations a
      ON a.tracking_submission_id = p.tracking_submission_id
     AND a.order_id = p.order_id
    WHERE p.shipment_batch_id = v_batch_id
      AND p.active = true
      AND COALESCE(a.qty_allocated, 0) > 0;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted <= 0 THEN
      RAISE EXCEPTION 'No exact allocation lines available for controlled snapshot.';
    END IF;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',
        id,
        shipment_batch_id,
        shipment_batch_package_id,
        tracking_submission_id,
        tracking_line_allocation_id,
        order_id,
        supplier_invoice_line_id,
        qty_in_shipment,
        adjusted_net_value_gbp
      ),
      ',' ORDER BY id
    ), ''))
    INTO v_before_fingerprint
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch_id;

    PERFORM public.shipper_undo_shipment_batch_v1(
      v_batch_id,
      'Regression controlled exact Undo — rolled back'
    );

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',
        id,
        shipment_batch_id,
        shipment_batch_package_id,
        tracking_submission_id,
        tracking_line_allocation_id,
        order_id,
        supplier_invoice_line_id,
        qty_in_shipment,
        adjusted_net_value_gbp
      ),
      ',' ORDER BY id
    ), ''))
    INTO v_after_fingerprint
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_active_lines_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch_id
      AND active = true;

    SELECT COUNT(*) INTO v_effective_after
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);

    SELECT status INTO v_status
    FROM public.shipper_shipment_batches
    WHERE id = v_batch_id;

    SELECT COUNT(*) INTO v_candidate_count
    FROM public.shipper_shipment_batch_candidates_v2() c
    WHERE c.tracking_submission_id IN (
      SELECT p.tracking_submission_id
      FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = v_batch_id
    );

    v_pass :=
      v_status = 'voided'
      AND v_active_lines_after = 0
      AND v_effective_after = 0
      AND v_before_fingerprint = v_after_fingerprint
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch_id
          AND p.active = true
      );

    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_exact_undo',
      v_pass AND v_error = '__REGRESSION_ROLLBACK__',
      jsonb_build_object(
        'shipment_batch_id', v_batch_id,
        'controlled_exact_lines', v_inserted,
        'immutable_line_identity_value_preserved', v_before_fingerprint = v_after_fingerprint,
        'active_exact_lines_after', v_active_lines_after,
        'effective_lines_after', v_effective_after,
        'candidate_query_succeeded', v_candidate_count IS NOT NULL,
        'released_tracking_candidates_after', v_candidate_count,
        'rolled_back', v_error = '__REGRESSION_ROLLBACK__',
        'error', CASE WHEN v_error <> '__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END
      )
    );
  END;
END
$clean_exact$;

-- -----------------------------------------------------------------------------
-- 3. INPUT / SECURITY / LIFECYCLE
-- -----------------------------------------------------------------------------

DO $input_security$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_actor record;
  v_other_shipper uuid;
  v_error text;
  v_pass boolean := false;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'blank_reason_rejected', false, jsonb_build_object('reason','No base batch.')
    );
    INSERT INTO shipment_undo_regression_results VALUES (
      'unauthenticated_rejected', false, jsonb_build_object('reason','No base batch.')
    );
    INSERT INTO shipment_undo_regression_results VALUES (
      'wrong_shipper_rejected', false, jsonb_build_object('reason','No base batch.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, '   ');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'blank_reason_rejected',
      v_error ILIKE '%Undo reason is required%',
      jsonb_build_object('error', v_error)
    );
  END;

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '{}', true);
  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Unauthenticated probe');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'unauthenticated_rejected',
      v_error ILIKE '%Unauthenticated user%',
      jsonb_build_object('error', v_error)
    );
  END;

  SELECT * INTO v_actor FROM pg_temp.base_actor(v_batch_id);
  SELECT s.id INTO v_other_shipper
  FROM public.shippers s
  WHERE s.id IS DISTINCT FROM v_actor.shipper_id
  ORDER BY s.created_at NULLS LAST, s.id
  LIMIT 1;

  IF v_other_shipper IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'wrong_shipper_rejected', false,
      jsonb_build_object('reason','No second shipper entity exists for rollback-only ownership probe.')
    );
  ELSE
    PERFORM set_config('request.jwt.claim.sub', v_actor.auth_user_id::text, true);
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object('sub',v_actor.auth_user_id::text,'role','authenticated')::text,
      true
    );

    BEGIN
      UPDATE public.shipper_users
      SET shipper_id = v_other_shipper
      WHERE id = v_actor.shipper_user_id;

      PERFORM public.shipper_undo_shipment_batch_v1(
        v_batch_id,
        'Wrong shipper rollback-only probe'
      );
      RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
    EXCEPTION WHEN OTHERS THEN
      v_error := SQLERRM;
      INSERT INTO shipment_undo_regression_results VALUES (
        'wrong_shipper_rejected',
        v_error ILIKE '%does not belong to this shipper%',
        jsonb_build_object('error',v_error,'controlled_shipper_user_reassignment_rolled_back',true)
      );
    END;
  END IF;
END
$input_security$;

DO $repeat_undo$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_second_error text;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'repeat_undo_rejected', false, jsonb_build_object('reason','No base batch.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'First rollback-only Undo');
    BEGIN
      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Second rollback-only Undo');
      v_second_error := '__SECOND_UNEXPECTED_SUCCESS__';
    EXCEPTION WHEN OTHERS THEN
      v_second_error := SQLERRM;
    END;

    v_pass := v_second_error ILIKE '%can no longer be undone at status: voided%';
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'repeat_undo_rejected',
      v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object('second_error',v_second_error,'rolled_back',v_error='__REGRESSION_ROLLBACK__')
    );
  END;
END
$repeat_undo$;

-- -----------------------------------------------------------------------------
-- 4. ACTIVE GROUPAGE — REAL READ-ONLY FIXTURE ONLY
-- -----------------------------------------------------------------------------

DO $active_groupage$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT b.id INTO v_batch_id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS (
      SELECT 1
      FROM public.shipper_groupage_movement_batches g
      WHERE g.shipment_batch_id=b.id
        AND g.active=true
    )
  ORDER BY b.created_at DESC, b.id
  LIMIT 1;

  PERFORM pg_temp.assert_real_blocker(
    'active_groupage_blocks',
    v_batch_id,
    'active Groupage Movement'
  );
END
$active_groupage$;

-- -----------------------------------------------------------------------------
-- 5. ACTIVE SHIPPING DOCUMENT — CONTROLLED NON-GROUPAGE FIXTURE
-- -----------------------------------------------------------------------------

DO $active_doc$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_actor record;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('active_shipping_document_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT * INTO v_actor FROM pg_temp.base_actor(v_batch_id);
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    INSERT INTO public.shipping_documents (
      shipment_batch_id, shipper_id, importer_id, uploaded_by_shipper_user_id,
      document_kind, document_ref, document_date, currency_code, total_amount,
      file_url, ocr_status, review_status, notes, version_no, active
    ) VALUES (
      v_batch_id, v_actor.shipper_id, v_actor.importer_id, v_actor.shipper_user_id,
      'shipper_invoice', 'REG-ACTIVE-DOC', current_date, 'GBP', 1,
      'regression://active-document', 'not_started', 'uploaded_pending_ocr',
      'Rollback-only active document blocker', 999001, true
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Active doc blocker');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'active_shipping_document_blocks',
      v_error ILIKE '%active shipping document%',
      jsonb_build_object('error',v_error,'controlled_fixture_rolled_back',true)
    );
  END;
END
$active_doc$;

-- -----------------------------------------------------------------------------
-- 6. ACTIVE APPROVED SHIPPING COST — inactive document + active allocation
-- -----------------------------------------------------------------------------

DO $active_cost$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_actor record;
  v_doc_id uuid;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('active_approved_shipping_cost_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT * INTO v_actor FROM pg_temp.base_actor(v_batch_id);
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    INSERT INTO public.shipping_documents (
      shipment_batch_id, shipper_id, importer_id, uploaded_by_shipper_user_id,
      document_kind, document_ref, currency_code, total_amount,
      file_url, ocr_status, review_status, version_no, active, superseded_at
    ) VALUES (
      v_batch_id, v_actor.shipper_id, v_actor.importer_id, v_actor.shipper_user_id,
      'shipper_invoice', 'REG-INACTIVE-DOC-FOR-COST', 'GBP', 10,
      'regression://inactive-document-for-cost', 'complete', 'superseded', 999002,
      false, now()
    ) RETURNING id INTO v_doc_id;

    INSERT INTO public.shipping_cost_allocations (
      shipping_document_id, shipment_batch_id, importer_id, shipper_id,
      source_currency_code, source_total_amount, total_weighted_basis,
      total_allocated_amount, allocation_status, approval_note, approved_at, active
    ) VALUES (
      v_doc_id, v_batch_id, v_actor.importer_id, v_actor.shipper_id,
      'GBP', 10, 10, 10, 'approved', 'Rollback-only approved cost blocker', now(), true
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Active cost blocker');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'active_approved_shipping_cost_blocks',
      v_error ILIKE '%active approved shipping-cost allocation%',
      jsonb_build_object('error',v_error,'controlled_fixture_rolled_back',true)
    );
  END;
END
$active_cost$;

-- -----------------------------------------------------------------------------
-- 7. EXPORT LOCK
-- -----------------------------------------------------------------------------

DO $export_lock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_allocation_id uuid;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('export_lock_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT e.tracking_line_allocation_id INTO v_allocation_id
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) e
  ORDER BY e.tracking_line_allocation_id
  LIMIT 1;

  IF v_allocation_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('export_lock_blocks',false,jsonb_build_object('reason','Base batch has no effective allocation.'));
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    UPDATE public.order_tracking_line_allocations
    SET locked_for_export_pack_at = now()
    WHERE id = v_allocation_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Export lock blocker');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'export_lock_blocks',
      v_error ILIKE '%locked for export%',
      jsonb_build_object('error',v_error,'allocation_id',v_allocation_id,'controlled_lock_rolled_back',true)
    );
  END;
END
$export_lock$;

-- -----------------------------------------------------------------------------
-- 8. ACTIVE CUSTOMER RELEASE — existing real isolated fixture
-- -----------------------------------------------------------------------------

DO $active_release$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT b.id INTO v_batch_id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS (
      SELECT 1 FROM public.customer_sales_release_lines r
      WHERE r.source_shipment_batch_id=b.id AND r.release_status='active'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_groupage_movement_batches g
      WHERE g.shipment_batch_id=b.id AND g.active=true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipping_documents d
      WHERE d.shipment_batch_id=b.id AND d.active=true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipping_cost_allocations c
      WHERE c.shipment_batch_id=b.id AND c.active=true AND c.allocation_status='approved'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
    )
  ORDER BY b.created_at DESC,b.id
  LIMIT 1;

  PERFORM pg_temp.assert_real_blocker(
    'active_customer_release_blocks',
    v_batch_id,
    'active customer-sales release'
  );
END
$active_release$;

-- -----------------------------------------------------------------------------
-- 9. ACCOUNTING — active/frozen AND posted historical hard boundary
-- -----------------------------------------------------------------------------

DO $accounting_active$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_posting_batch uuid;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('active_accounting_snapshot_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    INSERT INTO public.sage_posting_batches (
      batch_ref, batch_kind, batch_status, notes, source
    ) VALUES (
      'REG-' || gen_random_uuid()::text,
      'preview_freeze', 'frozen_pending_posting',
      'Rollback-only active accounting blocker', 'shipment_undo_regression'
    ) RETURNING id INTO v_posting_batch;

    INSERT INTO public.sage_posting_snapshots (
      batch_id, source_table, source_id, document_lane, document_type,
      shipment_batch_id, booking_ref, amount_gbp, currency_code,
      resolved_payload, commercial_payload, mapping_snapshot,
      mapping_semantic_fingerprint, payload_semantic_fingerprint,
      idempotency_key, approval_status, sage_posting_status, active
    )
    SELECT
      v_posting_batch, 'shipment_undo_regression', gen_random_uuid(),
      'shipper_ap', 'regression_active_snapshot',
      b.id, b.booking_ref, 1, 'GBP',
      '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
      md5(gen_random_uuid()::text), md5(gen_random_uuid()::text),
      'REG-' || gen_random_uuid()::text,
      'approved_frozen', 'not_posted', true
    FROM public.shipper_shipment_batches b
    WHERE b.id=v_batch_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Active accounting blocker');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'active_accounting_snapshot_blocks',
      v_error ILIKE '%accounting snapshot%',
      jsonb_build_object('error',v_error,'controlled_fixture_rolled_back',true)
    );
  END;
END
$accounting_active$;

DO $accounting_posted$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_posting_batch uuid;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('posted_accounting_snapshot_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    INSERT INTO public.sage_posting_batches (
      batch_ref, batch_kind, batch_status, notes, source
    ) VALUES (
      'REG-' || gen_random_uuid()::text,
      'preview_freeze', 'posted',
      'Rollback-only posted accounting blocker', 'shipment_undo_regression'
    ) RETURNING id INTO v_posting_batch;

    INSERT INTO public.sage_posting_snapshots (
      batch_id, source_table, source_id, document_lane, document_type,
      shipment_batch_id, booking_ref, amount_gbp, currency_code,
      resolved_payload, commercial_payload, mapping_snapshot,
      mapping_semantic_fingerprint, payload_semantic_fingerprint,
      idempotency_key, approval_status, sage_posting_status,
      sage_invoice_id, sage_posted_at, active
    )
    SELECT
      v_posting_batch, 'shipment_undo_regression', gen_random_uuid(),
      'shipper_ap', 'regression_posted_snapshot',
      b.id, b.booking_ref, 1, 'GBP',
      '{}'::jsonb, '{}'::jsonb, '{}'::jsonb,
      md5(gen_random_uuid()::text), md5(gen_random_uuid()::text),
      'REG-' || gen_random_uuid()::text,
      'approved_frozen', 'posted', 'REG-POSTED', now(), false
    FROM public.shipper_shipment_batches b
    WHERE b.id=v_batch_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Posted accounting blocker');
    RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'posted_accounting_snapshot_blocks',
      v_error ILIKE '%accounting snapshot%',
      jsonb_build_object('error',v_error,'inactive_posted_history_hard_block',true,'controlled_fixture_rolled_back',true)
    );
  END;
END
$accounting_posted$;

-- -----------------------------------------------------------------------------
-- 10. ANY FINAL EXPORT EVIDENCE — all three review states
-- -----------------------------------------------------------------------------

DO $final_evidence$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_actor record;
  v_status text;
  v_test text;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('submitted_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    INSERT INTO shipment_undo_regression_results VALUES ('accepted_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    INSERT INTO shipment_undo_regression_results VALUES ('rejected_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT * INTO v_actor FROM pg_temp.base_actor(v_batch_id);
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  FOREACH v_status IN ARRAY ARRAY['submitted_for_review','accepted_current','rejected_resubmit_required'] LOOP
    v_test := CASE v_status
      WHEN 'submitted_for_review' THEN 'submitted_final_evidence_blocks'
      WHEN 'accepted_current' THEN 'accepted_final_evidence_blocks'
      ELSE 'rejected_final_evidence_blocks'
    END;

    BEGIN
      INSERT INTO public.shipper_final_export_evidence_documents (
        shipment_batch_id, shipper_id, document_kind, document_ref,
        file_url, notes, review_status, created_by_shipper_user_id
      ) VALUES (
        v_batch_id, v_actor.shipper_id, 'completed_cos',
        'REG-' || v_status,
        'regression://final-evidence/' || v_status,
        'Rollback-only final evidence blocker',
        v_status,
        v_actor.shipper_user_id
      );

      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Final evidence blocker');
      RAISE EXCEPTION '__UNDO_UNEXPECTED_SUCCESS__';
    EXCEPTION WHEN OTHERS THEN
      v_error := SQLERRM;
      INSERT INTO shipment_undo_regression_results VALUES (
        v_test,
        v_error ILIKE '%final export evidence exists%',
        jsonb_build_object('review_status',v_status,'error',v_error,'controlled_fixture_rolled_back',true)
      );
    END;
  END LOOP;
END
$final_evidence$;

-- -----------------------------------------------------------------------------
-- 11. NON-BLOCKERS — completion fields, dispatched_at, inactive document,
--     inactive cost, inactive never-posted accounting, reversed release history
-- -----------------------------------------------------------------------------

DO $completion_nonblock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('completion_fields_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
  BEGIN
    PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch_id);
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Completion fields nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'completion_fields_nonblocking',
      v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_error='__REGRESSION_ROLLBACK__','error',CASE WHEN v_error<>'__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END)
    );
  END;
END
$completion_nonblock$;

DO $dispatched_nonblock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('dispatched_at_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
  BEGIN
    UPDATE public.shipper_shipment_batches SET dispatched_at=now() WHERE id=v_batch_id;
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Dispatched nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'dispatched_at_nonblocking',v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_error='__REGRESSION_ROLLBACK__')
    );
  END;
END
$dispatched_nonblock$;

DO $inactive_doc_nonblock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_actor record;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('inactive_shipping_document_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT * INTO v_actor FROM pg_temp.base_actor(v_batch_id);
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
  BEGIN
    INSERT INTO public.shipping_documents (
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES (
      v_batch_id,v_actor.shipper_id,v_actor.importer_id,v_actor.shipper_user_id,
      'shipper_invoice','REG-INACTIVE-DOC','GBP',1,'regression://inactive-document',
      'complete','superseded',999003,false,now()
    );
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Inactive doc nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'inactive_shipping_document_history_nonblocking',v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_error='__REGRESSION_ROLLBACK__','error',CASE WHEN v_error<>'__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END)
    );
  END;
END
$inactive_doc_nonblock$;

DO $inactive_cost_nonblock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_actor record;
  v_doc_id uuid;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('inactive_shipping_cost_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT * INTO v_actor FROM pg_temp.base_actor(v_batch_id);
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
  BEGIN
    INSERT INTO public.shipping_documents (
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES (
      v_batch_id,v_actor.shipper_id,v_actor.importer_id,v_actor.shipper_user_id,
      'shipper_invoice','REG-INACTIVE-COST-DOC','GBP',10,'regression://inactive-cost-document',
      'complete','superseded',999004,false,now()
    ) RETURNING id INTO v_doc_id;

    INSERT INTO public.shipping_cost_allocations (
      shipping_document_id,shipment_batch_id,importer_id,shipper_id,
      source_currency_code,source_total_amount,total_weighted_basis,total_allocated_amount,
      allocation_status,approval_note,active
    ) VALUES (
      v_doc_id,v_batch_id,v_actor.importer_id,v_actor.shipper_id,
      'GBP',10,10,10,'superseded','Rollback-only inactive cost history',false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Inactive cost nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'inactive_shipping_cost_history_nonblocking',v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_error='__REGRESSION_ROLLBACK__','error',CASE WHEN v_error<>'__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END)
    );
  END;
END
$inactive_cost_nonblock$;

DO $inactive_accounting_nonblock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_posting_batch uuid;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('inactive_never_posted_accounting_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES ('REG-'||gen_random_uuid()::text,'preview_freeze','superseded','Rollback-only inactive accounting history','shipment_undo_regression')
    RETURNING id INTO v_posting_batch;

    INSERT INTO public.sage_posting_snapshots (
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,booking_ref,amount_gbp,currency_code,
      resolved_payload,commercial_payload,mapping_snapshot,
      mapping_semantic_fingerprint,payload_semantic_fingerprint,idempotency_key,
      approval_status,sage_posting_status,active
    )
    SELECT
      v_posting_batch,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','regression_inactive_history',
      b.id,b.booking_ref,1,'GBP','{}'::jsonb,'{}'::jsonb,'{}'::jsonb,
      md5(gen_random_uuid()::text),md5(gen_random_uuid()::text),'REG-'||gen_random_uuid()::text,
      'superseded','not_posted',false
    FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Inactive accounting nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'inactive_never_posted_accounting_history_nonblocking',v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_error='__REGRESSION_ROLLBACK__','error',CASE WHEN v_error<>'__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END)
    );
  END;
END
$inactive_accounting_nonblock$;

DO $reversed_release_nonblock$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_staff_id uuid;
  v_template record;
  v_alloc record;
  v_parent_order uuid;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('reversed_customer_release_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT s.id INTO v_staff_id FROM public.staff s WHERE s.active=true ORDER BY s.created_at,s.id LIMIT 1;
  SELECT r.sales_invoice_id,r.sales_invoice_type INTO v_template
  FROM public.customer_sales_release_lines r ORDER BY r.created_at,r.id LIMIT 1;

  SELECT a.id,a.order_id,a.tracking_submission_id,a.supplier_invoice_line_id,
         sil.supplier_invoice_id,a.qty_allocated,a.adjusted_net_value_gbp
    INTO v_alloc
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) e
  JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines sil ON sil.id=a.supplier_invoice_line_id
  ORDER BY a.id LIMIT 1;

  SELECT CASE WHEN o.order_type='replacement_child' AND o.parent_order_id IS NOT NULL THEN o.parent_order_id ELSE o.id END
    INTO v_parent_order
  FROM public.orders o WHERE o.id=v_alloc.order_id;

  IF v_staff_id IS NULL OR v_template.sales_invoice_id IS NULL OR v_alloc.id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'reversed_customer_release_history_nonblocking',false,
      jsonb_build_object('reason','Prerequisite staff/release-template/base-allocation missing for rollback-only synthetic reversed history.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    -- The release ledger's own trigger intentionally protects cross-source
    -- provenance. For this narrowly scoped Undo query test we insert one
    -- rollback-only already-reversed history row with triggers disabled for this
    -- session only, immediately restore trigger execution, and never commit it.
    PERFORM set_config('session_replication_role','replica',true);

    INSERT INTO public.customer_sales_release_lines (
      id,sales_invoice_id,sales_invoice_type,order_id,commercial_parent_order_id,
      source_shipment_batch_id,supplier_invoice_id,supplier_invoice_line_id,
      tracking_submission_id,tracking_line_allocation_id,released_qty,
      goods_amount_gbp,delivery_share_gbp,discount_share_gbp,shipping_amount_gbp,
      customer_charge_amount_gbp,release_status,membership_fingerprint,
      created_by_staff_id,reversed_at,reversed_by_staff_id,reversal_reason
    ) VALUES (
      gen_random_uuid(),v_template.sales_invoice_id,v_template.sales_invoice_type,
      v_alloc.order_id,v_parent_order,v_batch_id,v_alloc.supplier_invoice_id,
      v_alloc.supplier_invoice_line_id,v_alloc.tracking_submission_id,v_alloc.id,
      0.001,0.01,0,0,0,0.01,'reversed','REG-'||gen_random_uuid()::text,
      v_staff_id,now(),v_staff_id,'Rollback-only reversed release history'
    );

    PERFORM set_config('session_replication_role','origin',true);

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Reversed release history nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    -- Ensure trigger execution is restored even if fixture construction fails.
    PERFORM set_config('session_replication_role','origin',true);
    INSERT INTO shipment_undo_regression_results VALUES (
      'reversed_customer_release_history_nonblocking',
      v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object(
        'undo_succeeded',v_pass,
        'synthetic_reversed_history',true,
        'trigger_bypass_session_local_and_rolled_back',true,
        'rolled_back',v_error='__REGRESSION_ROLLBACK__',
        'error',CASE WHEN v_error<>'__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END
      )
    );
  END;
END
$reversed_release_nonblock$;

-- -----------------------------------------------------------------------------
-- 12. MUTABLE PROGRESSED ADJUSTMENT HOUSEKEEPING
-- -----------------------------------------------------------------------------

DO $adjustment_housekeeping$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_alloc record;
  v_basis_id uuid;
  v_staff_id uuid;
  v_operator_id uuid;
  v_progressed_id uuid;
  v_terminal_id uuid;
  v_old_qty numeric;
  v_old_base numeric;
  v_old_discount numeric;
  v_old_delivery numeric;
  v_old_chargeable numeric;
  v_new record;
  v_old record;
  v_terminal record;
  v_pass boolean := false;
  v_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('mutable_progressed_adjustment_housekeeping',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT a.id,a.order_id,a.tracking_submission_id,a.supplier_invoice_line_id,
         sil.supplier_invoice_id,a.qty_allocated,
         COALESCE(a.base_value_gbp,a.adjusted_net_value_gbp,0) AS base_value,
         COALESCE(a.discount_share_gbp,0) AS discount_value,
         COALESCE(a.retailer_delivery_share_gbp,0) AS delivery_value,
         COALESCE(a.adjusted_net_value_gbp,0) AS chargeable_value
    INTO v_alloc
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) e
  JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines sil ON sil.id=a.supplier_invoice_line_id
  WHERE NOT EXISTS (
    SELECT 1 FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id=a.id AND l.active=true AND l.outcome='progressed_allocated'
  )
  ORDER BY a.id LIMIT 1;

  SELECT s.id INTO v_staff_id FROM public.staff s WHERE s.active=true ORDER BY s.created_at,s.id LIMIT 1;
  SELECT o.id INTO v_operator_id FROM public.operators o WHERE o.active=true ORDER BY o.created_at,o.id LIMIT 1;

  IF v_alloc.id IS NULL OR (v_staff_id IS NULL AND v_operator_id IS NULL) THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'mutable_progressed_adjustment_housekeeping',false,
      jsonb_build_object('reason','No suitable base allocation or staff/operator actor for controlled adjustment fixture.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    SELECT b.id INTO v_basis_id
    FROM public.invoice_adjustment_basis b
    WHERE b.supplier_invoice_id=v_alloc.supplier_invoice_id
    LIMIT 1;

    IF v_basis_id IS NULL THEN
      INSERT INTO public.invoice_adjustment_basis (
        supplier_invoice_id,order_id,locked_goods_total_gbp,
        locked_discount_total_gbp,locked_delivery_total_gbp,
        locked_by_staff_id,locked_by_operator_id,notes
      ) VALUES (
        v_alloc.supplier_invoice_id,v_alloc.order_id,
        GREATEST(v_alloc.base_value,0),GREATEST(v_alloc.discount_value,0),GREATEST(v_alloc.delivery_value,0),
        v_staff_id,CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END,
        'Rollback-only Shipment Undo adjustment basis'
      ) RETURNING id INTO v_basis_id;
    END IF;

    v_old_qty := GREATEST(COALESCE(v_alloc.qty_allocated,0.001),0.001);
    v_old_base := GREATEST(COALESCE(v_alloc.base_value,0),0);
    v_old_discount := GREATEST(COALESCE(v_alloc.discount_value,0),0);
    v_old_delivery := GREATEST(COALESCE(v_alloc.delivery_value,0),0);
    v_old_chargeable := GREATEST(COALESCE(v_alloc.chargeable_value,0),0);

    INSERT INTO public.invoice_adjustment_consumption_ledger (
      invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,
      qty_consumed,base_value_consumed_gbp,discount_consumed_gbp,
      delivery_consumed_gbp,chargeable_adjusted_goods_basis_gbp,
      outcome,reason,active,created_by_staff_id,created_by_operator_id
    ) VALUES (
      v_basis_id,v_alloc.supplier_invoice_id,v_alloc.supplier_invoice_line_id,
      v_alloc.id,v_alloc.tracking_submission_id,v_batch_id,
      v_old_qty,v_old_base,v_old_discount,v_old_delivery,v_old_chargeable,
      'progressed_allocated','Rollback-only mutable progressed adjustment',true,
      v_staff_id,CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END
    ) RETURNING id INTO v_progressed_id;

    INSERT INTO public.invoice_adjustment_consumption_ledger (
      invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,
      qty_consumed,base_value_consumed_gbp,discount_consumed_gbp,
      delivery_consumed_gbp,chargeable_adjusted_goods_basis_gbp,
      outcome,reason,active,created_by_staff_id,created_by_operator_id
    ) VALUES (
      v_basis_id,v_alloc.supplier_invoice_id,v_alloc.supplier_invoice_line_id,
      NULL,v_alloc.tracking_submission_id,v_batch_id,
      0.001,0.01,0,0,0.01,
      'shipped_charged','Rollback-only terminal row must remain untouched',true,
      v_staff_id,CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END
    ) RETURNING id INTO v_terminal_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Mutable adjustment housekeeping');

    SELECT l.active,l.outcome,l.superseded_at INTO v_old
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.id=v_progressed_id;

    SELECT l.id,l.shipment_batch_id,l.qty_consumed,l.base_value_consumed_gbp,
           l.discount_consumed_gbp,l.delivery_consumed_gbp,
           l.chargeable_adjusted_goods_basis_gbp,l.active,l.outcome
      INTO v_new
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id=v_alloc.id
      AND l.active=true
      AND l.outcome='progressed_allocated'
    ORDER BY l.created_at DESC,l.id DESC LIMIT 1;

    SELECT l.active,l.outcome,l.shipment_batch_id INTO v_terminal
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.id=v_terminal_id;

    v_pass :=
      v_old.active=false
      AND v_old.outcome='superseded'
      AND v_old.superseded_at IS NOT NULL
      AND v_new.id IS NOT NULL
      AND v_new.shipment_batch_id IS NULL
      AND v_new.qty_consumed=v_old_qty
      AND v_new.base_value_consumed_gbp=v_old_base
      AND v_new.discount_consumed_gbp=v_old_discount
      AND v_new.delivery_consumed_gbp=v_old_delivery
      AND v_new.chargeable_adjusted_goods_basis_gbp=v_old_chargeable
      AND v_terminal.active=true
      AND v_terminal.outcome='shipped_charged'
      AND v_terminal.shipment_batch_id=v_batch_id;

    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      v_pass AND v_error='__REGRESSION_ROLLBACK__',
      jsonb_build_object(
        'old_progressed_superseded',COALESCE(v_old.active=false AND v_old.outcome='superseded',false),
        'rebuilt_progressed_batch_cleared',v_new.id IS NOT NULL AND v_new.shipment_batch_id IS NULL,
        'financial_values_preserved',v_new.id IS NOT NULL
          AND v_new.qty_consumed=v_old_qty
          AND v_new.base_value_consumed_gbp=v_old_base
          AND v_new.discount_consumed_gbp=v_old_discount
          AND v_new.delivery_consumed_gbp=v_old_delivery
          AND v_new.chargeable_adjusted_goods_basis_gbp=v_old_chargeable,
        'terminal_row_untouched',COALESCE(v_terminal.active=true AND v_terminal.outcome='shipped_charged' AND v_terminal.shipment_batch_id=v_batch_id,false),
        'rolled_back',v_error='__REGRESSION_ROLLBACK__',
        'error',CASE WHEN v_error<>'__REGRESSION_ROLLBACK__' THEN v_error ELSE NULL END
      )
    );
  END;
END
$adjustment_housekeeping$;

-- -----------------------------------------------------------------------------
-- 13. INACTIVE GROUPAGE HISTORY — READ ONLY
--     Never manufacture or alter Groupage. Prefer real behavioural fixture; if
--     none can safely be isolated, prove the installed Undo authority filters
--     only gmb.active=true and record the fallback explicitly.
-- -----------------------------------------------------------------------------

DO $inactive_groupage$
DECLARE
  v_batch_id uuid;
  v_pass boolean := false;
  v_error text;
  v_definition text;
BEGIN
  SELECT b.id INTO v_batch_id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS (
      SELECT 1 FROM public.shipper_groupage_movement_batches g
      WHERE g.shipment_batch_id=b.id AND g.active=false
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_groupage_movement_batches g
      WHERE g.shipment_batch_id=b.id AND g.active=true
    )
    AND EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id=b.id AND p.active=true
    )
    AND NOT EXISTS (SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_cost_allocations c WHERE c.shipment_batch_id=b.id AND c.active=true AND c.allocation_status='approved')
    AND NOT EXISTS (SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active')
    AND NOT EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id
      AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
    )
  ORDER BY b.created_at DESC,b.id LIMIT 1;

  IF v_batch_id IS NOT NULL THEN
    PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
    BEGIN
      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Inactive Groupage history nonblock');
      v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch_id AND b.status='voided');
      RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      INSERT INTO shipment_undo_regression_results VALUES (
        'inactive_groupage_history_nonblocking',
        v_pass AND v_error='__REGRESSION_ROLLBACK__',
        jsonb_build_object('coverage_mode','real_read_only_fixture','shipment_batch_id',v_batch_id,'undo_succeeded',v_pass,'rolled_back',v_error='__REGRESSION_ROLLBACK__')
      );
    END;
  ELSE
    SELECT pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure)
      INTO v_definition;
    INSERT INTO shipment_undo_regression_results VALUES (
      'inactive_groupage_history_nonblocking',
      v_definition ILIKE '%shipper_groupage_movement_batches%'
        AND v_definition ILIKE '%gmb.active = true%',
      jsonb_build_object(
        'coverage_mode','structural_fallback_no_safe_real_fixture',
        'groupage_mutated',false,
        'undo_filters_only_active_groupage',
          v_definition ILIKE '%shipper_groupage_movement_batches%'
          AND v_definition ILIKE '%gmb.active = true%'
      )
    );
  END IF;
END
$inactive_groupage$;

-- -----------------------------------------------------------------------------
-- 14. STALE WRITERS REJECT VOIDED BATCH
-- -----------------------------------------------------------------------------

DO $stale_writers$
DECLARE
  v_batch_id uuid := pg_temp.clean_legacy_batch();
  v_booking text;
  v_header boolean := false;
  v_completion boolean := false;
  v_shipping_doc boolean := false;
  v_final_evidence boolean := false;
  v_error text;
  v_outer_error text;
BEGIN
  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('stale_writers_reject_voided_batch',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT booking_ref INTO v_booking FROM public.shipper_shipment_batches WHERE id=v_batch_id;
  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Stale writer rollback-only probe');

    BEGIN
      PERFORM public.shipper_update_shipment_batch_header_v1(v_batch_id,v_booking);
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      v_header := v_error ILIKE '%can no longer be edited%' OR v_error ILIKE '%status%voided%';
    END;

    BEGIN
      PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch_id);
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      v_completion := v_error ILIKE '%cannot be edited%' OR v_error ILIKE '%status%voided%';
    END;

    BEGIN
      PERFORM public.shipper_submit_shipping_document_v1(
        v_batch_id,'shipper_invoice','REG-STALE',current_date,'GBP',1,
        'regression://stale-shipping-document','Rollback-only stale writer probe'
      );
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      v_shipping_doc := v_error ILIKE '%batch is voided%' OR v_error ILIKE '%not found for this shipper%';
    END;

    BEGIN
      PERFORM public.shipper_submit_final_export_evidence_v1(
        v_batch_id,'completed_cos','REG-STALE','regression://stale-final-evidence','Rollback-only stale writer probe'
      );
    EXCEPTION WHEN OTHERS THEN
      v_error:=SQLERRM;
      v_final_evidence := v_error ILIKE '%status: voided%' OR v_error ILIKE '%cannot be submitted%';
    END;

    RAISE EXCEPTION '__REGRESSION_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    v_outer_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      'stale_writers_reject_voided_batch',
      v_outer_error='__REGRESSION_ROLLBACK__'
        AND v_header AND v_completion AND v_shipping_doc AND v_final_evidence,
      jsonb_build_object(
        'shipment_batch_id',v_batch_id,
        'header_rejected',v_header,
        'completion_fields_rejected',v_completion,
        'shipping_document_rejected',v_shipping_doc,
        'final_evidence_rejected',v_final_evidence,
        'rolled_back',v_outer_error='__REGRESSION_ROLLBACK__'
      )
    );
  END;
END
$stale_writers$;

-- -----------------------------------------------------------------------------
-- 15. CONCURRENCY LOCK CONTRACT
--     Single-session SQL cannot prove wall-clock two-session scheduling, but this
--     verifies every installed lock edge required by the addendum. A separate
--     two-session race remains the only manual concurrency proof.
-- -----------------------------------------------------------------------------

DO $concurrency_contract$
DECLARE
  v_undo text;
  v_create text;
  v_release_guard text;
  v_header text;
  v_completion text;
  v_shipping text;
  v_final text;
  v_pass boolean;
BEGIN
  SELECT pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure) INTO v_undo;
  SELECT pg_get_functiondef('public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure) INTO v_create;
  SELECT pg_get_functiondef('public.customer_sales_release_guard_v1()'::regprocedure) INTO v_release_guard;
  SELECT pg_get_functiondef('public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure) INTO v_header;
  SELECT pg_get_functiondef('public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)'::regprocedure) INTO v_completion;
  SELECT pg_get_functiondef('public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)'::regprocedure) INTO v_shipping;
  SELECT pg_get_functiondef('public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)'::regprocedure) INTO v_final;

  v_pass :=
    v_undo ILIKE '%FOR UPDATE%'
    AND v_undo ILIKE '%pg_advisory_xact_lock(hashtext(v_package.order_id::text))%'
    AND v_undo ILIKE '%pg_advisory_xact_lock(hashtext(v_package.tracking_submission_id::text))%'
    AND v_create ILIKE '%pg_advisory_xact_lock(hashtext(v_order_id::text))%'
    AND v_create ILIKE '%pg_advisory_xact_lock(hashtext(v_tracking_id::text))%'
    AND v_release_guard ILIKE '%FOR UPDATE OF allocation_row%'
    AND v_header ILIKE '%shipper_shipment_batches%FOR UPDATE%'
    AND v_completion ILIKE '%shipper_shipment_batches%FOR UPDATE%'
    AND v_shipping ILIKE '%shipper_shipment_batches%FOR UPDATE%'
    AND v_final ILIKE '%shipper_shipment_batches%FOR UPDATE%';

  INSERT INTO shipment_undo_regression_results VALUES (
    'concurrency_lock_contract_present',
    v_pass,
    jsonb_build_object(
      'undo_batch_and_allocation_locks',v_undo ILIKE '%FOR UPDATE%',
      'undo_order_tracking_advisory_locks',v_undo ILIKE '%pg_advisory_xact_lock(hashtext(v_package.order_id::text))%' AND v_undo ILIKE '%pg_advisory_xact_lock(hashtext(v_package.tracking_submission_id::text))%',
      'create_uses_same_advisory_lock_convention',v_create ILIKE '%pg_advisory_xact_lock(hashtext(v_order_id::text))%' AND v_create ILIKE '%pg_advisory_xact_lock(hashtext(v_tracking_id::text))%',
      'customer_release_locks_allocation',v_release_guard ILIKE '%FOR UPDATE OF allocation_row%',
      'four_authorised_writers_lock_batch',v_header ILIKE '%FOR UPDATE%' AND v_completion ILIKE '%FOR UPDATE%' AND v_shipping ILIKE '%FOR UPDATE%' AND v_final ILIKE '%FOR UPDATE%',
      'two_session_race_execution','not automated by this single-session rollback script'
    )
  );
END
$concurrency_contract$;

-- -----------------------------------------------------------------------------
-- 16. PROTECTED AUTHORITY / GROUPAGE IMMUTABILITY
-- -----------------------------------------------------------------------------

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT
  'protected_authorities_unchanged',
  NOT EXISTS (
    SELECT 1
    FROM shipment_undo_protected_before b
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
    ) a USING(signature)
    WHERE b.definition_md5 IS DISTINCT FROM a.definition_md5
       OR b.acl IS DISTINCT FROM a.acl
  ),
  jsonb_build_object('groupage_mutated',false);

-- -----------------------------------------------------------------------------
-- FINAL RESULT — then rollback everything.
-- -----------------------------------------------------------------------------

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_regression_v1',
  'transaction_wrapped',true,
  'will_rollback',true,
  'groupage_mutation_performed',false,
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER (WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(
    jsonb_build_object('test',test_name,'passed',passed,'detail',detail)
    ORDER BY test_name
  )
)) AS result
FROM shipment_undo_regression_results;

ROLLBACK;
