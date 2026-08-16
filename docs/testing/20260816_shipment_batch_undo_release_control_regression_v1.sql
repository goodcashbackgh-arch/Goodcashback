-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — BEHAVIOURAL REGRESSION
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- TRANSACTION WRAPPED. Ends with ROLLBACK.
-- Uses existing fixtures only.
-- NEVER creates, updates, cancels, excludes or otherwise mutates Groupage state.
-- Groupage is read only throughout.
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

-- One read-only fixture map. Blocker booleans follow the exact Undo evaluation
-- order so each blocker test can exclude all earlier blockers and prove the
-- intended boundary rather than accidentally passing for a different reason.
CREATE TEMP VIEW shipment_undo_fixture_map AS
SELECT
  b.id AS shipment_batch_id,
  b.shipper_id,
  b.status,
  b.created_at,
  b.dispatched_at,
  EXISTS (
    SELECT 1 FROM public.shipper_shipment_batch_packages p
    WHERE p.shipment_batch_id = b.id AND p.active = true
  ) AS has_active_packages,
  EXISTS (
    SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = b.id AND m.active = true
  ) AS has_active_exact_lines,
  EXISTS (
    SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.shipment_batch_id = b.id
  ) AS has_any_exact_lines,
  EXISTS (
    SELECT 1 FROM public.shipper_groupage_movement_batches g
    WHERE g.shipment_batch_id = b.id AND g.active = true
  ) AS block_groupage,
  EXISTS (
    SELECT 1 FROM public.shipping_documents d
    WHERE d.shipment_batch_id = b.id AND d.active = true
  ) AS block_shipping_document,
  EXISTS (
    SELECT 1 FROM public.shipping_cost_allocations a
    WHERE a.shipment_batch_id = b.id AND a.active = true AND a.allocation_status = 'approved'
  ) AS block_shipping_cost,
  EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_effective_lines_v1(b.id) l
    JOIN public.order_tracking_line_allocations a ON a.id = l.tracking_line_allocation_id
    WHERE a.locked_for_export_pack_at IS NOT NULL
       OR a.allocation_status = 'locked_for_export_pack'
  ) AS block_export_lock,
  EXISTS (
    SELECT 1 FROM public.customer_sales_release_lines r
    WHERE r.source_shipment_batch_id = b.id AND r.release_status = 'active'
  ) AS block_customer_release,
  EXISTS (
    SELECT 1 FROM public.sage_posting_snapshots s
    WHERE s.shipment_batch_id = b.id
      AND (
        s.sage_posting_status = 'posted'
        OR (COALESCE(s.active, true) = true AND COALESCE(s.sage_posting_status, 'not_posted') <> 'voided')
      )
  ) AS block_accounting,
  EXISTS (
    SELECT 1 FROM public.shipper_final_export_evidence_documents e
    WHERE e.shipment_batch_id = b.id
  ) AS block_final_evidence,
  EXISTS (
    SELECT 1 FROM public.invoice_adjustment_consumption_ledger l
    LEFT JOIN public.order_tracking_line_allocations a ON a.id = l.source_allocation_id
    WHERE l.shipment_batch_id = b.id
      AND l.active = true
      AND l.outcome = 'progressed_allocated'
      AND (
        a.id IS NULL
        OR a.locked_for_export_pack_at IS NOT NULL
        OR a.allocation_status = 'locked_for_export_pack'
        OR EXISTS (
          SELECT 1 FROM public.customer_sales_release_lines r
          WHERE r.tracking_line_allocation_id = a.id AND r.release_status = 'active'
        )
      )
  ) AS block_adjustment_immutability,
  EXISTS (
    SELECT 1 FROM public.shipper_groupage_movement_batches g
    WHERE g.shipment_batch_id = b.id AND g.active = false
  ) AS has_inactive_groupage_history,
  EXISTS (
    SELECT 1 FROM public.shipping_documents d
    WHERE d.shipment_batch_id = b.id AND d.active = false
  ) AS has_inactive_shipping_document_history,
  EXISTS (
    SELECT 1 FROM public.shipping_cost_allocations a
    WHERE a.shipment_batch_id = b.id
      AND (a.active = false OR a.allocation_status <> 'approved')
  ) AS has_inactive_shipping_cost_history,
  EXISTS (
    SELECT 1 FROM public.customer_sales_release_lines r
    WHERE r.source_shipment_batch_id = b.id AND r.release_status = 'reversed'
  ) AS has_reversed_customer_release_history,
  EXISTS (
    SELECT 1 FROM public.sage_posting_snapshots s
    WHERE s.shipment_batch_id = b.id
      AND COALESCE(s.active, true) = false
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
  ) AS has_inactive_never_posted_accounting_history,
  EXISTS (
    SELECT 1 FROM public.shipper_export_evidence_completion_fields f
    WHERE f.shipment_batch_id = b.id
  ) AS has_completion_fields,
  EXISTS (
    SELECT 1 FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id = b.id
      AND l.active = true
      AND l.outcome = 'progressed_allocated'
  ) AS has_mutable_progressed_adjustment
FROM public.shipper_shipment_batches b;

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
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
  RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.assert_undo_blocked(
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
      jsonb_build_object('reason', 'No isolated existing fixture available.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(p_batch_id);

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(p_batch_id, 'Regression blocker probe — rolled back');
    INSERT INTO shipment_undo_regression_results VALUES (
      p_test_name,
      false,
      jsonb_build_object('shipment_batch_id', p_batch_id, 'reason', 'Undo unexpectedly succeeded.')
    );
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

-- Basic success helper for non-blocking historical/current states. The inner
-- exception deliberately rolls back the successful Undo while retaining the
-- assertion result, so one fixture cannot contaminate another test.
CREATE OR REPLACE FUNCTION pg_temp.assert_undo_succeeds_basic(
  p_test_name text,
  p_batch_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_pass boolean := false;
  v_detail jsonb := '{}'::jsonb;
BEGIN
  IF p_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      p_test_name,
      false,
      jsonb_build_object('reason', 'No existing fixture available.')
    );
    RETURN;
  END IF;

  BEGIN
    PERFORM pg_temp.set_shipper_auth_for_batch(p_batch_id);
    PERFORM public.shipper_undo_shipment_batch_v1(p_batch_id, 'Regression non-blocker probe — rolled back');

    v_pass := EXISTS (
      SELECT 1 FROM public.shipper_shipment_batches b
      WHERE b.id = p_batch_id
        AND b.status = 'voided'
        AND b.voided_at IS NOT NULL
        AND b.voided_by_shipper_user_id IS NOT NULL
        AND NULLIF(BTRIM(COALESCE(b.void_reason, '')), '') IS NOT NULL
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = p_batch_id AND p.active = true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id = p_batch_id AND m.active = true
    );

    v_detail := jsonb_build_object('shipment_batch_id', p_batch_id, 'undo_succeeded', v_pass);
    RAISE EXCEPTION '__SHIPMENT_UNDO_TEST_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> '__SHIPMENT_UNDO_TEST_ROLLBACK__' THEN
      v_pass := false;
      v_detail := jsonb_build_object('shipment_batch_id', p_batch_id, 'error', SQLERRM);
    END IF;
  END;

  INSERT INTO shipment_undo_regression_results VALUES (p_test_name, v_pass, v_detail);
END;
$$;

-- =============================================================================
-- 1. Clean exact-line Undo: full mutation/audit/no-delete/immutability proof.
-- =============================================================================
DO $clean_exact$
DECLARE
  v_batch_id uuid;
  v_package_rows_before integer;
  v_package_rows_after integer;
  v_line_rows_before integer;
  v_line_rows_after integer;
  v_line_fingerprint_before text;
  v_line_fingerprint_after text;
  v_effective_after integer;
  v_status text;
  v_voided_at timestamptz;
  v_voided_by uuid;
  v_void_reason text;
  v_candidates_after integer;
  v_pass boolean := false;
  v_detail jsonb := '{}'::jsonb;
BEGIN
  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created'
    AND f.has_active_packages
    AND f.has_active_exact_lines
    AND NOT f.block_groupage
    AND NOT f.block_shipping_document
    AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock
    AND NOT f.block_customer_release
    AND NOT f.block_accounting
    AND NOT f.block_final_evidence
    AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at, f.shipment_batch_id
  LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'clean_exact_undo', false,
      jsonb_build_object('reason', 'No existing clean exact-line fixture available.')
    );
    RETURN;
  END IF;

  BEGIN
    PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

    SELECT COUNT(*) INTO v_package_rows_before
    FROM public.shipper_shipment_batch_packages WHERE shipment_batch_id = v_batch_id;
    SELECT COUNT(*) INTO v_line_rows_before
    FROM public.shipper_shipment_batch_line_memberships WHERE shipment_batch_id = v_batch_id;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', id, shipment_batch_id, shipment_batch_package_id,
        tracking_submission_id, tracking_line_allocation_id, order_id,
        supplier_invoice_line_id, qty_in_shipment, adjusted_net_value_gbp),
      ',' ORDER BY id
    ), ''))
    INTO v_line_fingerprint_before
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Regression clean exact Undo — rolled back');

    SELECT status, voided_at, voided_by_shipper_user_id, void_reason
      INTO v_status, v_voided_at, v_voided_by, v_void_reason
    FROM public.shipper_shipment_batches WHERE id = v_batch_id;
    SELECT COUNT(*) INTO v_package_rows_after
    FROM public.shipper_shipment_batch_packages WHERE shipment_batch_id = v_batch_id;
    SELECT COUNT(*) INTO v_line_rows_after
    FROM public.shipper_shipment_batch_line_memberships WHERE shipment_batch_id = v_batch_id;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', id, shipment_batch_id, shipment_batch_package_id,
        tracking_submission_id, tracking_line_allocation_id, order_id,
        supplier_invoice_line_id, qty_in_shipment, adjusted_net_value_gbp),
      ',' ORDER BY id
    ), ''))
    INTO v_line_fingerprint_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch_id;

    SELECT COUNT(*) INTO v_effective_after
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);

    SELECT COUNT(*) INTO v_candidates_after
    FROM public.shipper_shipment_batch_candidates_v2() c
    WHERE c.tracking_submission_id IN (
      SELECT p.tracking_submission_id
      FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = v_batch_id
    );

    v_pass := v_status = 'voided'
      AND v_voided_at IS NOT NULL
      AND v_voided_by IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(v_void_reason, '')), '') IS NOT NULL
      AND v_package_rows_before = v_package_rows_after
      AND v_line_rows_before = v_line_rows_after
      AND v_line_fingerprint_before = v_line_fingerprint_after
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
          AND (
            p.removed_at IS NULL
            OR p.removed_by_shipper_user_id IS NULL
            OR NULLIF(BTRIM(COALESCE(p.remove_reason, '')), '') IS NULL
          )
      )
      AND v_effective_after = 0;

    v_detail := jsonb_build_object(
      'shipment_batch_id', v_batch_id,
      'package_rows_preserved', v_package_rows_before = v_package_rows_after,
      'line_rows_preserved', v_line_rows_before = v_line_rows_after,
      'immutable_line_values_preserved', v_line_fingerprint_before = v_line_fingerprint_after,
      'effective_lines_after', v_effective_after,
      'released_tracking_candidates_after', v_candidates_after
    );

    RAISE EXCEPTION '__SHIPMENT_UNDO_TEST_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> '__SHIPMENT_UNDO_TEST_ROLLBACK__' THEN
      v_pass := false;
      v_detail := jsonb_build_object('shipment_batch_id', v_batch_id, 'error', SQLERRM);
    END IF;
  END;

  INSERT INTO shipment_undo_regression_results VALUES ('clean_exact_undo', v_pass, v_detail);
END
$clean_exact$;

-- =============================================================================
-- 2. Clean legacy package-fallback Undo.
-- =============================================================================
DO $clean_legacy$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created'
    AND f.has_active_packages
    AND NOT f.has_any_exact_lines
    AND NOT f.block_groupage
    AND NOT f.block_shipping_document
    AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock
    AND NOT f.block_customer_release
    AND NOT f.block_accounting
    AND NOT f.block_final_evidence
    AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at, f.shipment_batch_id
  LIMIT 1;

  PERFORM pg_temp.assert_undo_succeeds_basic('clean_legacy_undo', v_batch_id);
END
$clean_legacy$;

-- =============================================================================
-- 3. Input / ownership / lifecycle rejection.
-- =============================================================================
DO $input_lifecycle$
DECLARE
  v_batch_id uuid;
  v_owner_shipper_id uuid;
  v_wrong_uid uuid;
  v_pass boolean := false;
  v_detail jsonb := '{}'::jsonb;
BEGIN
  SELECT f.shipment_batch_id, f.shipper_id
    INTO v_batch_id, v_owner_shipper_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
  ORDER BY f.created_at DESC LIMIT 1;

  IF v_batch_id IS NOT NULL THEN
    PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
    BEGIN
      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, '   ');
      INSERT INTO shipment_undo_regression_results VALUES ('blank_reason_rejected', false, '{}');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO shipment_undo_regression_results VALUES (
        'blank_reason_rejected',
        SQLERRM ILIKE '%Undo reason is required%',
        jsonb_build_object('error', SQLERRM)
      );
    END;

    SELECT su.auth_user_id INTO v_wrong_uid
    FROM public.shipper_users su
    WHERE su.active = true
      AND su.auth_user_id IS NOT NULL
      AND su.shipper_id IS DISTINCT FROM v_owner_shipper_id
    ORDER BY su.created_at DESC, su.id DESC
    LIMIT 1;

    IF v_wrong_uid IS NULL THEN
      INSERT INTO shipment_undo_regression_results VALUES (
        'wrong_shipper_rejected', false,
        jsonb_build_object('reason', 'No second active shipper auth user fixture available.')
      );
    ELSE
      PERFORM set_config('request.jwt.claim.sub', v_wrong_uid::text, true);
      PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', v_wrong_uid::text, 'role', 'authenticated')::text, true);
      BEGIN
        PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Wrong shipper probe');
        INSERT INTO shipment_undo_regression_results VALUES ('wrong_shipper_rejected', false, '{}');
      EXCEPTION WHEN OTHERS THEN
        INSERT INTO shipment_undo_regression_results VALUES (
          'wrong_shipper_rejected',
          SQLERRM ILIKE '%does not belong to this shipper%',
          jsonb_build_object('error', SQLERRM)
        );
      END;
    END IF;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '{}', true);
  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(COALESCE(v_batch_id, gen_random_uuid()), 'Unauthenticated probe');
    INSERT INTO shipment_undo_regression_results VALUES ('unauthenticated_rejected', false, '{}');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'unauthenticated_rejected',
      SQLERRM ILIKE '%Unauthenticated user%',
      jsonb_build_object('error', SQLERRM)
    );
  END;

  -- Repeat Undo: first succeeds inside the subtransaction; second must reject.
  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created'
    AND f.has_active_packages
    AND NOT f.block_groupage
    AND NOT f.block_shipping_document
    AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock
    AND NOT f.block_customer_release
    AND NOT f.block_accounting
    AND NOT f.block_final_evidence
    AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at, f.shipment_batch_id LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'repeat_undo_rejected', false,
      jsonb_build_object('reason', 'No clean fixture available.')
    );
  ELSE
    BEGIN
      PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'First Undo — regression rollback');
      BEGIN
        PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Second Undo');
        v_pass := false;
        v_detail := jsonb_build_object('reason', 'Second Undo unexpectedly succeeded.');
      EXCEPTION WHEN OTHERS THEN
        v_pass := SQLERRM ILIKE '%can no longer be undone%';
        v_detail := jsonb_build_object('second_error', SQLERRM);
      END;
      RAISE EXCEPTION '__SHIPMENT_UNDO_TEST_ROLLBACK__';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> '__SHIPMENT_UNDO_TEST_ROLLBACK__' THEN
        v_pass := false;
        v_detail := jsonb_build_object('error', SQLERRM);
      END IF;
    END;
    INSERT INTO shipment_undo_regression_results VALUES ('repeat_undo_rejected', v_pass, v_detail);
  END IF;
END
$input_lifecycle$;

-- =============================================================================
-- 4. Isolated blocker proofs. Every query excludes all earlier blockers.
-- =============================================================================
DO $blockers$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages AND f.block_groupage
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_groupage_blocks', v_batch_id, 'active Groupage Movement');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage
    AND f.block_shipping_document
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_shipping_document_blocks', v_batch_id, 'active shipping document');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document
    AND f.block_shipping_cost
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_approved_shipping_cost_blocks', v_batch_id, 'active approved shipping-cost allocation');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND f.block_export_lock
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('export_lock_blocks', v_batch_id, 'locked for export');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost AND NOT f.block_export_lock
    AND f.block_customer_release
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_customer_release_blocks', v_batch_id, 'active customer-sales release');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release
    AND f.block_accounting
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('accounting_blocks', v_batch_id, 'accounting snapshot');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND EXISTS (
      SELECT 1 FROM public.shipper_final_export_evidence_documents e
      WHERE e.shipment_batch_id = f.shipment_batch_id AND e.review_status = 'submitted_for_review'
    )
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('submitted_final_evidence_blocks', v_batch_id, 'final export evidence exists');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND EXISTS (
      SELECT 1 FROM public.shipper_final_export_evidence_documents e
      WHERE e.shipment_batch_id = f.shipment_batch_id AND e.review_status = 'accepted_current'
    )
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('accepted_final_evidence_blocks', v_batch_id, 'final export evidence exists');

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status = 'created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND EXISTS (
      SELECT 1 FROM public.shipper_final_export_evidence_documents e
      WHERE e.shipment_batch_id = f.shipment_batch_id AND e.review_status = 'rejected_resubmit_required'
    )
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('rejected_final_evidence_blocks', v_batch_id, 'final export evidence exists');
END
$blockers$;

-- =============================================================================
-- 5. Non-blockers: each fixture contains the stated historical/current state but
-- no actual blocker. A successful rolled-back Undo proves that state alone does
-- not block.
-- =============================================================================
DO $nonblockers$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_inactive_groupage_history
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('inactive_groupage_history_nonblocking', v_batch_id);

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_inactive_shipping_document_history
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('inactive_shipping_document_history_nonblocking', v_batch_id);

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_inactive_shipping_cost_history
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('inactive_shipping_cost_history_nonblocking', v_batch_id);

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_reversed_customer_release_history
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('reversed_customer_release_history_nonblocking', v_batch_id);

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_inactive_never_posted_accounting_history
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('inactive_never_posted_accounting_history_nonblocking', v_batch_id);

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_completion_fields
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('completion_fields_nonblocking', v_batch_id);

  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.dispatched_at IS NOT NULL
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_succeeds_basic('dispatched_at_nonblocking', v_batch_id);
END
$nonblockers$;

-- =============================================================================
-- 6. Mutable progressed-adjustment housekeeping.
-- =============================================================================
DO $adjustments$
DECLARE
  v_batch_id uuid;
  v_source_ids uuid[];
  v_before_fingerprint text;
  v_after_fingerprint text;
  v_terminal_before text;
  v_terminal_after text;
  v_old_rows_superseded integer;
  v_source_count integer;
  v_rebuilt_count integer;
  v_pass boolean := false;
  v_detail jsonb := '{}'::jsonb;
BEGIN
  SELECT f.shipment_batch_id INTO v_batch_id
  FROM shipment_undo_fixture_map f
  WHERE f.status='created' AND f.has_active_packages AND f.has_mutable_progressed_adjustment
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at DESC LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'mutable_progressed_adjustment_housekeeping', false,
      jsonb_build_object('reason', 'No existing mutable progressed-adjustment fixture available.')
    );
    RETURN;
  END IF;

  BEGIN
    PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

    SELECT array_agg(l.source_allocation_id ORDER BY l.source_allocation_id),
           COUNT(DISTINCT l.source_allocation_id)::integer
      INTO v_source_ids, v_source_count
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id = v_batch_id
      AND l.active = true
      AND l.outcome = 'progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', l.source_allocation_id, l.qty_consumed, l.base_value_consumed_gbp,
        l.discount_consumed_gbp, l.delivery_consumed_gbp,
        l.chargeable_adjusted_goods_basis_gbp),
      ',' ORDER BY l.source_allocation_id
    ), ''))
    INTO v_before_fingerprint
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id = v_batch_id
      AND l.active = true
      AND l.outcome = 'progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', l.id, l.outcome, l.active, l.qty_consumed, l.base_value_consumed_gbp,
        l.discount_consumed_gbp, l.delivery_consumed_gbp,
        l.chargeable_adjusted_goods_basis_gbp, l.source_allocation_id),
      ',' ORDER BY l.id
    ), ''))
    INTO v_terminal_before
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.outcome IN ('shipped_charged','refunded_nil_charge','replacement_child','written_off_nil_charge');

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Regression adjustment Undo — rolled back');

    SELECT COUNT(*)::integer INTO v_old_rows_superseded
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id = ANY(v_source_ids)
      AND l.shipment_batch_id = v_batch_id
      AND l.active = false
      AND l.outcome = 'superseded'
      AND l.superseded_at IS NOT NULL;

    SELECT COUNT(*)::integer INTO v_rebuilt_count
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id = ANY(v_source_ids)
      AND l.shipment_batch_id IS NULL
      AND l.active = true
      AND l.outcome = 'progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', l.source_allocation_id, l.qty_consumed, l.base_value_consumed_gbp,
        l.discount_consumed_gbp, l.delivery_consumed_gbp,
        l.chargeable_adjusted_goods_basis_gbp),
      ',' ORDER BY l.source_allocation_id
    ), ''))
    INTO v_after_fingerprint
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id = ANY(v_source_ids)
      AND l.shipment_batch_id IS NULL
      AND l.active = true
      AND l.outcome = 'progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', l.id, l.outcome, l.active, l.qty_consumed, l.base_value_consumed_gbp,
        l.discount_consumed_gbp, l.delivery_consumed_gbp,
        l.chargeable_adjusted_goods_basis_gbp, l.source_allocation_id),
      ',' ORDER BY l.id
    ), ''))
    INTO v_terminal_after
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.outcome IN ('shipped_charged','refunded_nil_charge','replacement_child','written_off_nil_charge');

    v_pass := v_source_count > 0
      AND v_old_rows_superseded = v_source_count
      AND v_rebuilt_count = v_source_count
      AND v_before_fingerprint = v_after_fingerprint
      AND v_terminal_before = v_terminal_after;

    v_detail := jsonb_build_object(
      'shipment_batch_id', v_batch_id,
      'source_count', v_source_count,
      'old_rows_superseded', v_old_rows_superseded,
      'rebuilt_rows', v_rebuilt_count,
      'financial_fingerprint_preserved', v_before_fingerprint = v_after_fingerprint,
      'terminal_outcomes_unchanged', v_terminal_before = v_terminal_after
    );

    RAISE EXCEPTION '__SHIPMENT_UNDO_TEST_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> '__SHIPMENT_UNDO_TEST_ROLLBACK__' THEN
      v_pass := false;
      v_detail := jsonb_build_object('shipment_batch_id', v_batch_id, 'error', SQLERRM);
    END IF;
  END;

  INSERT INTO shipment_undo_regression_results VALUES (
    'mutable_progressed_adjustment_housekeeping', v_pass, v_detail
  );
END
$adjustments$;

-- =============================================================================
-- 7. Stale direct writers after Undo. These are sequential status-boundary proofs
-- of the four authorised writer hardenings; true simultaneous-session locking is
-- separately represented by the lock-contract proof below.
-- =============================================================================
DO $stale_writers$
DECLARE
  v_batch_id uuid;
  v_booking_ref text;
  v_header_ok boolean := false;
  v_completion_ok boolean := false;
  v_shipping_doc_ok boolean := false;
  v_final_evidence_ok boolean := false;
  v_detail jsonb := '{}'::jsonb;
BEGIN
  SELECT f.shipment_batch_id, b.booking_ref
    INTO v_batch_id, v_booking_ref
  FROM shipment_undo_fixture_map f
  JOIN public.shipper_shipment_batches b ON b.id = f.shipment_batch_id
  WHERE f.status='created' AND f.has_active_packages
    AND NOT f.block_groupage AND NOT f.block_shipping_document AND NOT f.block_shipping_cost
    AND NOT f.block_export_lock AND NOT f.block_customer_release AND NOT f.block_accounting
    AND NOT f.block_final_evidence AND NOT f.block_adjustment_immutability
  ORDER BY f.created_at, f.shipment_batch_id LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES (
      'stale_writers_reject_voided_batch', false,
      jsonb_build_object('reason', 'No clean fixture available.')
    );
    RETURN;
  END IF;

  BEGIN
    PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id, 'Regression stale-writer Undo — rolled back');

    BEGIN
      PERFORM public.shipper_update_shipment_batch_header_v1(v_batch_id, v_booking_ref, NULL, NULL, NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN
      v_header_ok := SQLERRM ILIKE '%can no longer be edited%' OR SQLERRM ILIKE '%status%';
    END;

    BEGIN
      PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch_id, NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,NULL);
    EXCEPTION WHEN OTHERS THEN
      v_completion_ok := SQLERRM ILIKE '%cannot be edited%' OR SQLERRM ILIKE '%status%';
    END;

    BEGIN
      PERFORM public.shipper_submit_shipping_document_v1(v_batch_id,'shipper_invoice',NULL,NULL,NULL,NULL,'regression://should-not-write',NULL);
    EXCEPTION WHEN OTHERS THEN
      v_shipping_doc_ok := SQLERRM ILIKE '%voided%' OR SQLERRM ILIKE '%not found for this shipper%';
    END;

    BEGIN
      PERFORM public.shipper_submit_final_export_evidence_v1(v_batch_id,'pod_delivery_evidence',NULL,'regression://should-not-write',NULL);
    EXCEPTION WHEN OTHERS THEN
      v_final_evidence_ok := SQLERRM ILIKE '%cannot be submitted%' OR SQLERRM ILIKE '%status%';
    END;

    v_detail := jsonb_build_object(
      'shipment_batch_id', v_batch_id,
      'header_rejected', v_header_ok,
      'completion_fields_rejected', v_completion_ok,
      'shipping_document_rejected', v_shipping_doc_ok,
      'final_evidence_rejected', v_final_evidence_ok
    );

    RAISE EXCEPTION '__SHIPMENT_UNDO_TEST_ROLLBACK__';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> '__SHIPMENT_UNDO_TEST_ROLLBACK__' THEN
      v_detail := jsonb_build_object('shipment_batch_id', v_batch_id, 'error', SQLERRM);
      v_header_ok := false;
      v_completion_ok := false;
      v_shipping_doc_ok := false;
      v_final_evidence_ok := false;
    END IF;
  END;

  INSERT INTO shipment_undo_regression_results VALUES (
    'stale_writers_reject_voided_batch',
    v_header_ok AND v_completion_ok AND v_shipping_doc_ok AND v_final_evidence_ok,
    v_detail
  );
END
$stale_writers$;

-- =============================================================================
-- 8. Lock-contract proof for the concurrency boundaries that can be verified in
-- one session. This does not pretend to be a two-session race test; it proves
-- the exact locking primitives required by the governing addendum are installed.
-- =============================================================================
INSERT INTO shipment_undo_regression_results(test_name, passed, detail)
WITH defs AS (
  SELECT
    pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure) AS undo_def,
    pg_get_functiondef('public.shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure) AS create_def,
    pg_get_functiondef('public.customer_sales_release_guard_v1()'::regprocedure) AS release_guard_def,
    pg_get_functiondef('public.shipper_update_shipment_batch_header_v1(uuid,text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure) AS header_def,
    pg_get_functiondef('public.shipper_save_export_evidence_completion_fields_v1(uuid,text,text,text,text,text,text,text,date,text,text,boolean,text)'::regprocedure) AS completion_def,
    pg_get_functiondef('public.shipper_submit_shipping_document_v1(uuid,text,text,date,text,numeric,text,text)'::regprocedure) AS shipping_doc_def,
    pg_get_functiondef('public.shipper_submit_final_export_evidence_v1(uuid,text,text,text,text)'::regprocedure) AS final_evidence_def
)
SELECT
  'concurrency_lock_contract_present',
  undo_def ILIKE '%FOR UPDATE%'
    AND undo_def ILIKE '%pg_advisory_xact_lock(hashtext(v_package.order_id::text))%'
    AND undo_def ILIKE '%pg_advisory_xact_lock(hashtext(v_package.tracking_submission_id::text))%'
    AND create_def ILIKE '%pg_advisory_xact_lock(hashtext(v_order_id::text))%'
    AND create_def ILIKE '%pg_advisory_xact_lock(hashtext(v_tracking_id::text))%'
    AND release_guard_def ILIKE '%FOR UPDATE OF allocation_row%'
    AND header_def ILIKE '%FOR UPDATE%'
    AND completion_def ILIKE '%FOR UPDATE%'
    AND shipping_doc_def ILIKE '%FOR UPDATE%'
    AND final_evidence_def ILIKE '%FOR UPDATE%',
  jsonb_build_object(
    'undo_batch_and_allocation_locks', undo_def ILIKE '%FOR UPDATE%',
    'undo_order_tracking_advisory_locks', undo_def ILIKE '%pg_advisory_xact_lock(hashtext(v_package.order_id::text))%' AND undo_def ILIKE '%pg_advisory_xact_lock(hashtext(v_package.tracking_submission_id::text))%',
    'create_uses_same_advisory_lock_convention', create_def ILIKE '%pg_advisory_xact_lock(hashtext(v_order_id::text))%' AND create_def ILIKE '%pg_advisory_xact_lock(hashtext(v_tracking_id::text))%',
    'customer_release_locks_allocation', release_guard_def ILIKE '%FOR UPDATE OF allocation_row%',
    'four_authorised_writers_lock_batch', header_def ILIKE '%FOR UPDATE%' AND completion_def ILIKE '%FOR UPDATE%' AND shipping_doc_def ILIKE '%FOR UPDATE%' AND final_evidence_def ILIKE '%FOR UPDATE%',
    'two_session_race_execution', 'not automated by this single-session rollback script'
  )
FROM defs;

-- =============================================================================
-- 9. Protected authority proof: Groupage and exact-line mutation authority must
-- be byte-identical before and after this regression. Regression itself never
-- mutates Groupage data.
-- =============================================================================
INSERT INTO shipment_undo_regression_results(test_name, passed, detail)
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
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
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
  jsonb_build_object('groupage_mutated', false);

SELECT jsonb_pretty(jsonb_build_object(
  'probe', 'shipment_batch_undo_release_control_regression_v1',
  'transaction_wrapped', true,
  'will_rollback', true,
  'result', CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'tests', jsonb_agg(
    jsonb_build_object('test', test_name, 'passed', passed, 'detail', detail)
    ORDER BY test_name
  )
)) AS result
FROM shipment_undo_regression_results;

ROLLBACK;
