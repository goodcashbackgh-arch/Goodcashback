-- Rollback-only regression for the ordered hybrid receipt foundation:
--   20260801130000_hybrid_physical_receipt_foundation_v1.sql
--   20260801131000_hybrid_physical_receipt_integrity_v1.sql
--   20260801131500_hybrid_physical_receipt_concurrency_v1.sql
--   20260801132000_hybrid_physical_receipt_position_v1.sql
--
-- Run after all four migrations. This script leaves no test data.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $catalog$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_receipt_v1_fingerprint text;
  v_child_helper_fingerprint text;
  v_reconciliation_pretty text;
  v_reconciliation_compact text;
  v_positive_allocations bigint;
  v_position_rows bigint;
  v_legacy_clean_count bigint;
BEGIN
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_package_receipt_line_dispositions');
  END IF;
  IF to_regclass('public.shipper_package_receipt_evidence') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_package_receipt_evidence');
  END IF;
  IF to_regclass('public.physical_receipt_reviews') IS NULL THEN
    v_missing := array_append(v_missing, 'physical_receipt_reviews');
  END IF;
  IF to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN
    v_missing := array_append(v_missing, 'physical_exception_remedy_allocations');
  END IF;
  IF to_regclass('public.tracking_allocation_fulfilment_position_v1') IS NULL THEN
    v_missing := array_append(v_missing, 'tracking_allocation_fulfilment_position_v1');
  END IF;
  IF to_regclass('public.tracking_allocation_fulfilment_anomalies_v1') IS NULL THEN
    v_missing := array_append(v_missing, 'tracking_allocation_fulfilment_anomalies_v1');
  END IF;
  IF to_regprocedure(
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'
  ) IS NULL THEN
    v_missing := array_append(
      v_missing,
      'internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'
    );
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      'FAIL: hybrid receipt foundation objects missing: %',
      array_to_string(v_missing, ', ');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'shipper_package_receipts'
      AND column_name = 'receipt_model_version'
      AND data_type = 'smallint'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'shipper_package_receipts'
      AND column_name = 'receipt_state'
      AND data_type = 'text'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'shipper_package_receipts'
      AND column_name = 'finalised_at'
      AND data_type = 'timestamp with time zone'
  ) THEN
    RAISE EXCEPTION
      'FAIL: receipt model/state/finalisation columns missing or wrong type';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_exception_remedy_allocations'
      AND column_name = 'proposed_remedy_type'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_exception_remedy_allocations'
      AND column_name = 'approved_remedy_type'
  ) THEN
    RAISE EXCEPTION
      'FAIL: importer proposal and supervisor approval are not stored separately';
  END IF;

  IF to_regprocedure('public.shipper_record_package_receipt_v1(uuid,text,text,text)') IS NULL
     OR to_regprocedure('public.customer_review_cycle_candidates_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.customer_review_receipt_materialize_v1()') IS NULL
     OR to_regprocedure('public.shipper_tracking_review_state_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL
     OR to_regprocedure(
       'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'
     ) IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.customer_sales_release_guard_v1()') IS NULL
     OR to_regprocedure('public.customer_sales_release_financial_guard_v1()') IS NULL
     OR to_regprocedure('public.customer_hold_create_refund_exception_v2()') IS NULL
     OR to_regprocedure('public.customer_hold_refund_target_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.create_replacement_child_order(uuid,uuid,uuid,text)') IS NULL
     OR to_regprocedure('public.order_has_open_child_exceptions(uuid)') IS NULL
     OR to_regprocedure('public.approve_vat_release(uuid,uuid,jsonb)') IS NULL
     OR to_regprocedure('public.mark_order_accounting_release_ready(uuid,uuid)') IS NULL
     OR to_regprocedure('public.recompute_order_status(uuid)') IS NULL
  THEN
    RAISE EXCEPTION
      'FAIL: one or more protected workflow function contracts are missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = procedure_row.pronamespace
    WHERE namespace_row.nspname = 'public'
      AND procedure_row.proname = 'shipper_record_package_receipt_v2'
  ) THEN
    RAISE EXCEPTION
      'FAIL: foundation unexpectedly activated shipper_record_package_receipt_v2';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)'::regprocedure
  ))
  INTO v_receipt_v1_fingerprint;

  IF v_receipt_v1_fingerprint <> '27fb972b34258990cfa9d752cd2f927b' THEN
    RAISE EXCEPTION
      'FAIL: legacy receipt function fingerprint changed: %',
      v_receipt_v1_fingerprint;
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.order_has_open_child_exceptions(uuid)'::regprocedure
  ))
  INTO v_child_helper_fingerprint;

  IF v_child_helper_fingerprint <> '8dbf93826e18a04b61d8fbc1d5b1922c' THEN
    RAISE EXCEPTION
      'FAIL: child-exception helper changed in foundation build: %',
      v_child_helper_fingerprint;
  END IF;

  SELECT
    md5(pg_get_viewdef('public.order_reconciliation_vw'::regclass, true)),
    md5(pg_get_viewdef('public.order_reconciliation_vw'::regclass, false))
  INTO v_reconciliation_pretty, v_reconciliation_compact;

  IF '4f71ebb1a3743d470687ecaee2f23a9a' NOT IN (
    v_reconciliation_pretty,
    v_reconciliation_compact
  ) THEN
    RAISE EXCEPTION
      'FAIL: order_reconciliation_vw changed in foundation build (pretty %, compact %)',
      v_reconciliation_pretty,
      v_reconciliation_compact;
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'FAIL: legacy receipt RPC authenticated execute grant was removed';
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'service_role',
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'FAIL: scoped quantity-position function privilege boundary is wrong';
  END IF;

  IF has_table_privilege(
       'authenticated',
       'public.shipper_package_receipt_line_dispositions',
       'INSERT'
     )
     OR has_table_privilege(
       'authenticated',
       'public.shipper_package_receipt_line_dispositions',
       'UPDATE'
     )
     OR has_table_privilege(
       'authenticated',
       'public.shipper_package_receipt_line_dispositions',
       'DELETE'
     )
     OR has_table_privilege(
       'authenticated',
       'public.shipper_package_receipt_evidence',
       'INSERT'
     )
     OR has_table_privilege(
       'authenticated',
       'public.physical_receipt_reviews',
       'INSERT'
     )
     OR has_table_privilege(
       'authenticated',
       'public.physical_exception_remedy_allocations',
       'INSERT'
     )
  THEN
    RAISE EXCEPTION
      'FAIL: direct authenticated write privilege exists on foundation provenance';
  END IF;

  IF NOT has_table_privilege(
       'authenticated',
       'public.shipper_package_receipt_line_dispositions',
       'SELECT'
     )
     OR NOT has_table_privilege(
       'authenticated',
       'public.shipper_package_receipt_evidence',
       'SELECT'
     )
     OR NOT has_table_privilege(
       'authenticated',
       'public.physical_receipt_reviews',
       'SELECT'
     )
     OR NOT has_table_privilege(
       'authenticated',
       'public.physical_exception_remedy_allocations',
       'SELECT'
     )
  THEN
    RAISE EXCEPTION 'FAIL: scoped authenticated read grant is missing';
  END IF;

  IF has_table_privilege(
       'authenticated',
       'public.tracking_allocation_fulfilment_position_v1',
       'SELECT'
     )
     OR has_table_privilege(
       'authenticated',
       'public.tracking_allocation_fulfilment_anomalies_v1',
       'SELECT'
     )
     OR NOT has_table_privilege(
       'service_role',
       'public.tracking_allocation_fulfilment_position_v1',
       'SELECT'
     )
  THEN
    RAISE EXCEPTION
      'FAIL: quantity-position diagnostic views are not private to service_role';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class relation_row
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = relation_row.relnamespace
    WHERE namespace_row.nspname = 'public'
      AND relation_row.relname IN (
        'shipper_package_receipt_line_dispositions',
        'shipper_package_receipt_evidence',
        'physical_receipt_reviews',
        'physical_exception_remedy_allocations'
      )
      AND relation_row.relrowsecurity = false
  ) THEN
    RAISE EXCEPTION 'FAIL: RLS is not enabled on every new table';
  END IF;

  IF (
    SELECT COUNT(*)
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgname IN (
      'trg_shipper_receipt_line_disposition_guard_v1',
      'trg_shipper_receipt_evidence_guard_v1',
      'trg_shipper_package_receipt_v2_integrity_guard_v1',
      'trg_shipper_package_receipt_v2_pending_commit_guard_v1',
      'trg_physical_receipt_review_guard_v1',
      'trg_physical_remedy_allocation_guard_v1',
      'trg_shipper_package_receipt_v2_supersede_open_review_v1',
      'trg_shipper_package_receipt_00_write_compatibility_guard_v1',
      'trg_shipper_package_receipt_01_prepare_correction_v1',
      'trg_physical_receipt_review_00_terminal_guard_v1',
      'trg_physical_remedy_00_sequence_guard_v1'
    )
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled <> 'D'
  ) <> 11 THEN
    RAISE EXCEPTION
      'FAIL: one or more hybrid receipt integrity/concurrency triggers are missing or disabled';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    WHERE receipt.receipt_model_version <> 1
       OR receipt.receipt_state <> 'finalised'
       OR receipt.receipt_submission_id IS NOT NULL
       OR receipt.payload_fingerprint IS NOT NULL
       OR receipt.finalised_at IS NOT NULL
       OR receipt.correction_of_receipt_id IS NOT NULL
       OR receipt.correction_reason IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: foundation migrations rewrote legacy receipt history';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    WHERE receipt.receipt_model_version = 2
      AND (
        receipt.receipt_state <> 'finalised'
        OR receipt.finalised_at IS NULL
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: a pending or incomplete v2 receipt is persisted';
  END IF;

  IF EXISTS (SELECT 1 FROM public.shipper_package_receipt_line_dispositions)
     OR EXISTS (SELECT 1 FROM public.shipper_package_receipt_evidence)
     OR EXISTS (SELECT 1 FROM public.physical_receipt_reviews)
     OR EXISTS (SELECT 1 FROM public.physical_exception_remedy_allocations)
  THEN
    RAISE EXCEPTION
      'FAIL: foundation migrations created operational workflow data';
  END IF;

  SELECT COUNT(*)
  INTO v_positive_allocations
  FROM public.order_tracking_line_allocations allocation
  WHERE COALESCE(allocation.qty_allocated, 0) > 0;

  SELECT COUNT(*)
  INTO v_position_rows
  FROM public.tracking_allocation_fulfilment_position_v1;

  IF v_position_rows <> v_positive_allocations THEN
    RAISE EXCEPTION
      'FAIL: position row count % does not equal positive allocation count %',
      v_position_rows,
      v_positive_allocations;
  END IF;

  WITH latest_receipt AS (
    SELECT DISTINCT ON (receipt.tracking_submission_id)
      receipt.tracking_submission_id,
      receipt.receipt_status::text AS receipt_status,
      receipt.receipt_model_version
    FROM public.shipper_package_receipts receipt
    WHERE receipt.receipt_model_version = 1
       OR (
         receipt.receipt_model_version = 2
         AND receipt.receipt_state = 'finalised'
         AND receipt.finalised_at IS NOT NULL
       )
    ORDER BY
      receipt.tracking_submission_id,
      receipt.created_at DESC,
      receipt.id DESC
  )
  SELECT COUNT(*)
  INTO v_legacy_clean_count
  FROM public.order_tracking_line_allocations allocation
  JOIN latest_receipt receipt
    ON receipt.tracking_submission_id = allocation.tracking_submission_id
  WHERE COALESCE(allocation.qty_allocated, 0) > 0
    AND receipt.receipt_model_version = 1
    AND receipt.receipt_status = 'received_clean';

  IF v_legacy_clean_count = 0 THEN
    RAISE EXCEPTION 'FAIL: no legacy clean allocation exists to prove parity';
  END IF;

  IF EXISTS (
    WITH latest_receipt AS (
      SELECT DISTINCT ON (receipt.tracking_submission_id)
        receipt.tracking_submission_id,
        receipt.receipt_status::text AS receipt_status,
        receipt.receipt_model_version
      FROM public.shipper_package_receipts receipt
      WHERE receipt.receipt_model_version = 1
         OR (
           receipt.receipt_model_version = 2
           AND receipt.receipt_state = 'finalised'
           AND receipt.finalised_at IS NOT NULL
         )
      ORDER BY
        receipt.tracking_submission_id,
        receipt.created_at DESC,
        receipt.id DESC
    )
    SELECT 1
    FROM public.order_tracking_line_allocations allocation
    JOIN latest_receipt receipt
      ON receipt.tracking_submission_id = allocation.tracking_submission_id
    JOIN public.tracking_allocation_fulfilment_position_v1 position_row
      ON position_row.tracking_line_allocation_id = allocation.id
    WHERE COALESCE(allocation.qty_allocated, 0) > 0
      AND receipt.receipt_model_version = 1
      AND receipt.receipt_status = 'received_clean'
      AND (
        position_row.source_receipt_model <> 'legacy_v1'
        OR ABS(
          position_row.physical_clean_qty - allocation.qty_allocated
        ) > 0.0005
        OR position_row.physical_exception_qty <> 0
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: legacy clean quantity parity changed';
  END IF;

  IF EXISTS (
    WITH latest_receipt AS (
      SELECT DISTINCT ON (receipt.tracking_submission_id)
        receipt.tracking_submission_id,
        receipt.receipt_status::text AS receipt_status,
        receipt.receipt_model_version
      FROM public.shipper_package_receipts receipt
      WHERE receipt.receipt_model_version = 1
         OR (
           receipt.receipt_model_version = 2
           AND receipt.receipt_state = 'finalised'
           AND receipt.finalised_at IS NOT NULL
         )
      ORDER BY
        receipt.tracking_submission_id,
        receipt.created_at DESC,
        receipt.id DESC
    )
    SELECT 1
    FROM public.order_tracking_line_allocations allocation
    JOIN latest_receipt receipt
      ON receipt.tracking_submission_id = allocation.tracking_submission_id
    JOIN public.tracking_allocation_fulfilment_position_v1 position_row
      ON position_row.tracking_line_allocation_id = allocation.id
    WHERE COALESCE(allocation.qty_allocated, 0) > 0
      AND receipt.receipt_model_version = 1
      AND receipt.receipt_status IN (
        'received_damaged','held_query','not_received'
      )
      AND (
        position_row.position_valid_yn
        OR position_row.position_blocker <>
             'legacy_nonclean_quantity_unproven'
        OR position_row.review_available_qty <> 0
        OR position_row.shipment_available_qty <> 0
        OR position_row.remedy_available_qty <> 0
      )
  ) THEN
    RAISE EXCEPTION
      'FAIL: uncertain legacy non-clean quantity did not fail closed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tracking_allocation_fulfilment_position_v1 position_row
    WHERE position_row.source_receipt_model = 'none'
      AND (
        position_row.position_valid_yn
        OR position_row.position_blocker <> 'receipt_not_recorded'
        OR position_row.review_available_qty <> 0
        OR position_row.shipment_available_qty <> 0
        OR position_row.remedy_available_qty <> 0
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: allocation without receipt did not fail closed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.tracking_allocation_fulfilment_position_v1 position_row
    WHERE position_row.review_available_qty < 0
       OR position_row.shipment_available_qty < 0
       OR position_row.remedy_available_qty < 0
       OR (
         position_row.position_valid_yn = false
         AND (
           position_row.review_available_qty <> 0
           OR position_row.shipment_available_qty <> 0
           OR position_row.remedy_available_qty <> 0
         )
       )
       OR (
         position_row.position_valid_yn
         AND (
           position_row.physical_clean_qty
             + position_row.physical_exception_qty
             <> position_row.allocated_qty
           OR position_row.reviewed_qty
             > position_row.physical_clean_qty + 0.0005
           OR position_row.shipped_qty
             > position_row.physical_clean_qty + 0.0005
           OR position_row.customer_released_qty
             > position_row.shipped_qty + 0.0005
           OR position_row.remedy_assigned_qty
             > position_row.physical_exception_qty + 0.0005
         )
       )
  ) THEN
    RAISE EXCEPTION
      'FAIL: invalid or negative quantity escaped the private position model';
  END IF;
END
$catalog$;

DO $functional$
DECLARE
  v_tracking_id uuid;
  v_order_id uuid;
  v_importer_id uuid;
  v_shipper_id uuid;
  v_shipper_user_id uuid;
  v_operator_id uuid;
  v_staff_id uuid;
  v_prior_receipt_id uuid;
  v_prior_reason text;
  v_receipt_id uuid;
  v_submission_id uuid;
  v_review_id uuid;
  v_first_disposition_id uuid;
  v_first_allocation_id uuid;
  v_first_supplier_line_id uuid;
  v_first_qty numeric;
  v_remedy_id uuid;
  v_correction_id uuid;
  v_expected_failure boolean;
  v_position record;
  v_review_state record;
  v_remedy_state record;
BEGIN
  SELECT
    tracking_row.id,
    tracking_row.order_id,
    order_row.importer_id,
    order_row.shipper_id,
    shipper_user.id,
    operator_row.id,
    staff_row.id
  INTO
    v_tracking_id,
    v_order_id,
    v_importer_id,
    v_shipper_id,
    v_shipper_user_id,
    v_operator_id,
    v_staff_id
  FROM public.order_tracking_submissions tracking_row
  JOIN public.orders order_row
    ON order_row.id = tracking_row.order_id
  JOIN LATERAL (
    SELECT shipper_user_row.id
    FROM public.shipper_users shipper_user_row
    WHERE shipper_user_row.shipper_id = order_row.shipper_id
      AND shipper_user_row.active = true
    ORDER BY shipper_user_row.created_at DESC, shipper_user_row.id
    LIMIT 1
  ) shipper_user ON true
  JOIN LATERAL (
    SELECT operator_candidate.id
    FROM public.operator_importers access_row
    JOIN public.operators operator_candidate
      ON operator_candidate.id = access_row.operator_id
    WHERE access_row.importer_id = order_row.importer_id
      AND access_row.revoked_at IS NULL
      AND COALESCE(operator_candidate.active, true) = true
    ORDER BY operator_candidate.id
    LIMIT 1
  ) operator_row ON true
  JOIN LATERAL (
    SELECT staff_candidate.id
    FROM public.staff staff_candidate
    WHERE COALESCE(staff_candidate.active, true) = true
    ORDER BY staff_candidate.id
    LIMIT 1
  ) staff_row ON true
  WHERE tracking_row.superseded_at IS NULL
    AND COALESCE(order_row.status, '') NOT IN ('archived','cancelled')
    AND EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations allocation
      WHERE allocation.order_id = tracking_row.order_id
        AND allocation.tracking_submission_id = tracking_row.id
        AND COALESCE(allocation.qty_allocated, 0) > 0
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations allocation
      JOIN public.customer_review_cycle_memberships membership
        ON membership.tracking_line_allocation_id = allocation.id
      WHERE allocation.tracking_submission_id = tracking_row.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests hold_row
      WHERE hold_row.order_id = tracking_row.order_id
        AND hold_row.status IN ('requested','supervisor_approved')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batches batch_row
      CROSS JOIN LATERAL
        public.shipper_shipment_batch_effective_lines_v1(batch_row.id)
          effective_line
      WHERE batch_row.status <> 'voided'
        AND effective_line.tracking_submission_id = tracking_row.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines release_line
      WHERE release_line.tracking_submission_id = tracking_row.id
        AND release_line.release_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.order_tracking_line_allocations allocation
      JOIN public.dispute_lines dispute_line
        ON dispute_line.supplier_invoice_line_id =
           allocation.supplier_invoice_line_id
      WHERE allocation.tracking_submission_id = tracking_row.id
    )
  ORDER BY tracking_row.submitted_at DESC NULLS LAST, tracking_row.id
  LIMIT 1;

  IF v_tracking_id IS NULL THEN
    RAISE NOTICE
      'INFO: no unused live package exists for the v2 write simulation; catalog, security, legacy-parity and live-invariant regressions still ran.';
    RETURN;
  END IF;

  SELECT receipt.id
  INTO v_prior_receipt_id
  FROM public.shipper_package_receipts receipt
  WHERE receipt.tracking_submission_id = v_tracking_id
    AND (
      receipt.receipt_model_version = 1
      OR (
        receipt.receipt_model_version = 2
        AND receipt.receipt_state = 'finalised'
        AND receipt.finalised_at IS NOT NULL
      )
    )
  ORDER BY receipt.created_at DESC, receipt.id DESC
  LIMIT 1;

  v_prior_reason := CASE
    WHEN v_prior_receipt_id IS NULL THEN NULL
    ELSE 'Rollback-only v2 correction of the latest legacy receipt.'
  END;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.shipper_package_receipts (
      tracking_submission_id,
      order_id,
      shipper_id,
      shipper_user_id,
      receipt_status,
      condition_note,
      receipt_model_version,
      receipt_state,
      receipt_submission_id,
      payload_fingerprint,
      correction_of_receipt_id,
      correction_reason
    ) VALUES (
      v_tracking_id,
      v_order_id,
      v_shipper_id,
      v_shipper_user_id,
      'held_query',
      'Rollback-only pending commit rejection.',
      2,
      'pending',
      gen_random_uuid(),
      md5(gen_random_uuid()::text),
      v_prior_receipt_id,
      v_prior_reason
    );

    SET CONSTRAINTS
      trg_shipper_package_receipt_v2_pending_commit_guard_v1 IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    IF position('pending v2 receipt cannot be committed' IN lower(SQLERRM)) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  SET CONSTRAINTS ALL DEFERRED;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: pending v2 receipt survived forced constraint check';
  END IF;

  v_submission_id := gen_random_uuid();

  INSERT INTO public.shipper_package_receipts (
    tracking_submission_id,
    order_id,
    shipper_id,
    shipper_user_id,
    receipt_status,
    condition_note,
    receipt_model_version,
    receipt_state,
    receipt_submission_id,
    payload_fingerprint,
    correction_of_receipt_id,
    correction_reason
  ) VALUES (
    v_tracking_id,
    v_order_id,
    v_shipper_id,
    v_shipper_user_id,
    'held_query',
    'Rollback-only affected v2 receipt regression.',
    2,
    'pending',
    v_submission_id,
    md5('affected|' || v_submission_id::text),
    v_prior_receipt_id,
    v_prior_reason
  )
  RETURNING id INTO v_receipt_id;

  v_expected_failure := false;
  BEGIN
    UPDATE public.shipper_package_receipts
    SET receipt_state = 'finalised'
    WHERE id = v_receipt_id;
  EXCEPTION WHEN OTHERS THEN
    IF position('incomplete or unbalanced' IN lower(SQLERRM)) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: incomplete v2 receipt finalised';
  END IF;

  SELECT
    allocation.id,
    allocation.supplier_invoice_line_id,
    allocation.qty_allocated
  INTO
    v_first_allocation_id,
    v_first_supplier_line_id,
    v_first_qty
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.order_id = v_order_id
    AND allocation.tracking_submission_id = v_tracking_id
    AND COALESCE(allocation.qty_allocated, 0) > 0
  ORDER BY allocation.created_at, allocation.id
  LIMIT 1;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.shipper_package_receipt_line_dispositions (
      receipt_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      supplier_invoice_line_id,
      disposition_type,
      quantity,
      condition_note
    ) VALUES (
      v_receipt_id,
      v_tracking_id,
      v_first_allocation_id,
      v_first_supplier_line_id,
      'damaged',
      v_first_qty,
      NULL
    );
  EXCEPTION WHEN OTHERS THEN
    IF position('requires a factual condition note' IN lower(SQLERRM)) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: affected disposition without factual note was accepted';
  END IF;

  INSERT INTO public.shipper_package_receipt_line_dispositions (
    receipt_id,
    tracking_submission_id,
    tracking_line_allocation_id,
    supplier_invoice_line_id,
    disposition_type,
    quantity,
    condition_note
  )
  SELECT
    v_receipt_id,
    allocation.tracking_submission_id,
    allocation.id,
    allocation.supplier_invoice_line_id,
    'damaged',
    allocation.qty_allocated,
    'Rollback-only evidence-supported damage test.'
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.order_id = v_order_id
    AND allocation.tracking_submission_id = v_tracking_id
    AND COALESCE(allocation.qty_allocated, 0) > 0;

  SELECT disposition.id
  INTO v_first_disposition_id
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.receipt_id = v_receipt_id
    AND disposition.tracking_line_allocation_id = v_first_allocation_id
  LIMIT 1;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.shipper_package_receipt_line_dispositions (
      receipt_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      supplier_invoice_line_id,
      disposition_type,
      quantity
    ) VALUES (
      v_receipt_id,
      v_tracking_id,
      v_first_allocation_id,
      v_first_supplier_line_id,
      'clean',
      0.001
    );
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'cumulative disposition quantity exceeds' IN lower(SQLERRM)
    ) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: disposition over-allocation was accepted';
  END IF;

  v_expected_failure := false;
  BEGIN
    UPDATE public.shipper_package_receipts
    SET receipt_state = 'finalised'
    WHERE id = v_receipt_id;
  EXCEPTION WHEN OTHERS THEN
    IF position('requires linked evidence' IN lower(SQLERRM)) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: affected v2 receipt finalised without evidence';
  END IF;

  INSERT INTO public.shipper_package_receipt_evidence (
    receipt_id,
    line_disposition_id,
    storage_object_path,
    original_filename,
    content_type,
    display_order,
    uploaded_by_shipper_user_id
  ) VALUES (
    v_receipt_id,
    NULL,
    'regression/' || v_receipt_id::text || '/shared-damage-proof.jpg',
    'shared-damage-proof.jpg',
    'image/jpeg',
    0,
    v_shipper_user_id
  );

  INSERT INTO public.shipper_package_receipt_evidence (
    receipt_id,
    line_disposition_id,
    storage_object_path,
    original_filename,
    content_type,
    display_order,
    uploaded_by_shipper_user_id
  ) VALUES (
    v_receipt_id,
    v_first_disposition_id,
    'regression/' || v_receipt_id::text || '/line-damage-proof.jpg',
    'line-damage-proof.jpg',
    'image/jpeg',
    1,
    v_shipper_user_id
  );

  UPDATE public.shipper_package_receipts
  SET receipt_state = 'finalised'
  WHERE id = v_receipt_id;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    WHERE receipt.id = v_receipt_id
      AND receipt.receipt_model_version = 2
      AND receipt.receipt_state = 'finalised'
      AND receipt.receipt_status = 'received_damaged'
      AND receipt.finalised_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'FAIL: balanced evidence-supported v2 receipt did not finalise with derived damaged summary';
  END IF;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.shipper_package_receipts (
      tracking_submission_id,
      order_id,
      shipper_id,
      shipper_user_id,
      receipt_status,
      condition_note,
      receipt_model_version,
      receipt_state,
      receipt_submission_id,
      payload_fingerprint,
      correction_of_receipt_id,
      correction_reason
    ) VALUES (
      v_tracking_id,
      v_order_id,
      v_shipper_id,
      v_shipper_user_id,
      'held_query',
      'Duplicate idempotency test.',
      2,
      'pending',
      v_submission_id,
      md5('changed-payload|' || v_submission_id::text),
      v_receipt_id,
      'Duplicate submission-key regression.'
    );
  EXCEPTION WHEN unique_violation THEN
    v_expected_failure := true;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: duplicate v2 submission identity was accepted';
  END IF;

  INSERT INTO public.physical_receipt_reviews (
    receipt_id,
    order_id,
    importer_id,
    tracking_submission_id
  ) VALUES (
    v_receipt_id,
    v_order_id,
    v_importer_id,
    v_tracking_id
  )
  RETURNING id INTO v_review_id;

  INSERT INTO public.physical_exception_remedy_allocations (
    physical_receipt_review_id,
    receipt_line_disposition_id,
    tracking_line_allocation_id,
    supplier_invoice_line_id,
    proposed_remedy_type,
    proposed_remedy_qty,
    proposed_by_operator_id,
    status
  ) VALUES (
    v_review_id,
    v_first_disposition_id,
    v_first_allocation_id,
    v_first_supplier_line_id,
    'refund',
    v_first_qty,
    v_operator_id,
    'proposed'
  )
  RETURNING id INTO v_remedy_id;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.physical_exception_remedy_allocations (
      physical_receipt_review_id,
      receipt_line_disposition_id,
      tracking_line_allocation_id,
      supplier_invoice_line_id,
      proposed_remedy_type,
      proposed_remedy_qty,
      proposed_by_operator_id,
      status
    ) VALUES (
      v_review_id,
      v_first_disposition_id,
      v_first_allocation_id,
      v_first_supplier_line_id,
      'hold_investigate',
      0.001,
      v_operator_id,
      'proposed'
    );
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'exceeds the affected receipt quantity' IN lower(SQLERRM)
    ) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: proposed remedy over-allocation was accepted';
  END IF;

  v_expected_failure := false;
  BEGIN
    UPDATE public.physical_exception_remedy_allocations
    SET status = 'approved',
        approved_remedy_type = 'refund',
        approved_remedy_qty = v_first_qty,
        approved_by_staff_id = v_staff_id,
        approved_at = now(),
        supplier_cost_mode = 'not_applicable'
    WHERE id = v_remedy_id;
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'requires the physical review to be awaiting supervisor review'
      IN lower(SQLERRM)
    ) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION
      'FAIL: supervisor remedy approval was accepted before importer submission';
  END IF;

  UPDATE public.physical_receipt_reviews
  SET status = 'awaiting_supervisor_review',
      importer_proposed_by_operator_id = v_operator_id,
      importer_proposed_at = now()
  WHERE id = v_review_id;

  UPDATE public.physical_exception_remedy_allocations
  SET status = 'approved',
      approved_remedy_type = 'refund',
      approved_remedy_qty = v_first_qty,
      approved_by_staff_id = v_staff_id,
      approved_at = now(),
      supplier_cost_mode = 'not_applicable'
  WHERE id = v_remedy_id;

  SELECT *
  INTO v_remedy_state
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.id = v_remedy_id;

  IF v_remedy_state.proposed_remedy_type <> 'refund'
     OR ABS(v_remedy_state.proposed_remedy_qty - v_first_qty) > 0.0005
     OR v_remedy_state.approved_remedy_type <> 'refund'
     OR ABS(v_remedy_state.approved_remedy_qty - v_first_qty) > 0.0005
     OR v_remedy_state.proposed_by_operator_id IS DISTINCT FROM v_operator_id
     OR v_remedy_state.approved_by_staff_id IS DISTINCT FROM v_staff_id
  THEN
    RAISE EXCEPTION
      'FAIL: importer proposal and supervisor approval provenance were not retained separately';
  END IF;

  v_expected_failure := false;
  BEGIN
    UPDATE public.physical_receipt_reviews
    SET status = 'approved_to_existing_exception',
        supervisor_decided_by_staff_id = v_staff_id,
        supervisor_decided_at = now(),
        approved_liable_party = 'retailer'
    WHERE id = v_review_id;
  EXCEPTION WHEN check_violation THEN
    v_expected_failure := true;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION
      'FAIL: physical review entered retailer exception route without exact existing dispute link';
  END IF;

  SELECT *
  INTO v_position
  FROM public.internal_tracking_allocation_fulfilment_position_v1(
    NULL,
    NULL,
    v_first_allocation_id
  );

  IF v_position.source_receipt_model <> 'v2_exact'
     OR v_position.position_valid_yn IS DISTINCT FROM true
     OR ABS(
       v_position.physical_exception_qty - v_position.allocated_qty
     ) > 0.0005
     OR v_position.physical_clean_qty <> 0
     OR ABS(v_position.remedy_assigned_qty - v_first_qty) > 0.0005
     OR v_position.review_available_qty <> 0
     OR v_position.shipment_available_qty <> 0
     OR v_position.remedy_available_qty <> 0
  THEN
    RAISE EXCEPTION
      'FAIL: affected v2/remedy position is incorrect: %',
      row_to_json(v_position);
  END IF;

  v_expected_failure := false;
  BEGIN
    UPDATE public.shipper_package_receipt_line_dispositions
    SET condition_note = 'Attempted mutation'
    WHERE id = v_first_disposition_id;
  EXCEPTION WHEN OTHERS THEN
    IF position('immutable' IN lower(SQLERRM)) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: finalised physical disposition was mutable';
  END IF;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.shipper_package_receipts (
      tracking_submission_id,
      order_id,
      shipper_id,
      shipper_user_id,
      receipt_status,
      condition_note
    ) VALUES (
      v_tracking_id,
      v_order_id,
      v_shipper_id,
      v_shipper_user_id,
      'received_clean',
      'Legacy receipt after exact v2 regression.'
    );
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'legacy package receipt cannot supersede' IN lower(SQLERRM)
    ) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION 'FAIL: legacy v1 receipt superseded finalised v2 truth';
  END IF;

  v_expected_failure := false;
  BEGIN
    INSERT INTO public.shipper_package_receipts (
      tracking_submission_id,
      order_id,
      shipper_id,
      shipper_user_id,
      receipt_status,
      condition_note,
      receipt_model_version,
      receipt_state,
      receipt_submission_id,
      payload_fingerprint,
      correction_of_receipt_id,
      correction_reason
    ) VALUES (
      v_tracking_id,
      v_order_id,
      v_shipper_id,
      v_shipper_user_id,
      'held_query',
      'Unsafe correction while approved remedy exists.',
      2,
      'pending',
      gen_random_uuid(),
      md5(gen_random_uuid()::text),
      v_receipt_id,
      'Rollback-only unsafe-correction rejection.'
    )
    RETURNING id INTO v_correction_id;

    INSERT INTO public.shipper_package_receipt_line_dispositions (
      receipt_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      supplier_invoice_line_id,
      disposition_type,
      quantity
    )
    SELECT
      v_correction_id,
      allocation.tracking_submission_id,
      allocation.id,
      allocation.supplier_invoice_line_id,
      'clean',
      allocation.qty_allocated
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = v_order_id
      AND allocation.tracking_submission_id = v_tracking_id
      AND COALESCE(allocation.qty_allocated, 0) > 0;

    UPDATE public.shipper_package_receipts
    SET receipt_state = 'finalised'
    WHERE id = v_correction_id;
  EXCEPTION WHEN OTHERS THEN
    IF position(
      'supervisor-approved or progressed remedy work' IN lower(SQLERRM)
    ) > 0 THEN
      v_expected_failure := true;
    ELSE
      RAISE;
    END IF;
  END;

  IF NOT v_expected_failure THEN
    RAISE EXCEPTION
      'FAIL: correction bypassed supervisor-approved remedy work';
  END IF;

  UPDATE public.physical_exception_remedy_allocations
  SET status = 'cancelled'
  WHERE id = v_remedy_id;

  INSERT INTO public.shipper_package_receipts (
    tracking_submission_id,
    order_id,
    shipper_id,
    shipper_user_id,
    receipt_status,
    condition_note,
    receipt_model_version,
    receipt_state,
    receipt_submission_id,
    payload_fingerprint,
    correction_of_receipt_id,
    correction_reason
  ) VALUES (
    v_tracking_id,
    v_order_id,
    v_shipper_id,
    v_shipper_user_id,
    'held_query',
    'Rollback-only corrected clean receipt.',
    2,
    'pending',
    gen_random_uuid(),
    md5(gen_random_uuid()::text),
    v_receipt_id,
    'Evidence-supported clean correction after cancelling unprogressed remedy.'
  )
  RETURNING id INTO v_correction_id;

  INSERT INTO public.shipper_package_receipt_line_dispositions (
    receipt_id,
    tracking_submission_id,
    tracking_line_allocation_id,
    supplier_invoice_line_id,
    disposition_type,
    quantity
  )
  SELECT
    v_correction_id,
    allocation.tracking_submission_id,
    allocation.id,
    allocation.supplier_invoice_line_id,
    'clean',
    allocation.qty_allocated
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.order_id = v_order_id
    AND allocation.tracking_submission_id = v_tracking_id
    AND COALESCE(allocation.qty_allocated, 0) > 0;

  UPDATE public.shipper_package_receipts
  SET receipt_state = 'finalised'
  WHERE id = v_correction_id;

  SELECT
    review_row.status,
    review_row.superseded_by_receipt_id
  INTO v_review_state
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = v_review_id;

  IF v_review_state.status <> 'superseded'
     OR v_review_state.superseded_by_receipt_id IS DISTINCT FROM v_correction_id
  THEN
    RAISE EXCEPTION
      'FAIL: safe corrected receipt did not supersede the unlinked physical review';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    WHERE receipt.id = v_correction_id
      AND receipt.receipt_state = 'finalised'
      AND receipt.receipt_status = 'received_clean'
      AND receipt.correction_of_receipt_id = v_receipt_id
  ) THEN
    RAISE EXCEPTION
      'FAIL: corrected all-clean v2 receipt did not finalise with exact predecessor';
  END IF;

  SELECT *
  INTO v_position
  FROM public.internal_tracking_allocation_fulfilment_position_v1(
    NULL,
    NULL,
    v_first_allocation_id
  );

  IF v_position.source_receipt_id IS DISTINCT FROM v_correction_id
     OR v_position.source_receipt_model <> 'v2_exact'
     OR v_position.position_valid_yn IS DISTINCT FROM true
     OR ABS(v_position.physical_clean_qty - v_position.allocated_qty) > 0.0005
     OR v_position.physical_exception_qty <> 0
     OR v_position.remedy_assigned_qty <> 0
  THEN
    RAISE EXCEPTION
      'FAIL: corrected clean quantity position is wrong: %',
      row_to_json(v_position);
  END IF;
END
$functional$;

DO $$
BEGIN
  RAISE NOTICE
    'PASS: hybrid physical receipt foundation schema, legacy parity, atomic v2 finalisation, evidence, proposal/approval separation, remedy caps, correction protection, v1 compatibility guard and exact position regressions completed.';
END $$;

ROLLBACK;