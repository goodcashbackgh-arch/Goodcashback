-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — ADJUSTMENT REGRESSION v5
--
-- Purpose:
--   Close the sole remaining behavioural proof gap after v3/v4 by reusing an
--   EXISTING active mutable progressed_allocated row instead of attempting to
--   create a duplicate row forbidden by the live unique index.
--
-- SAFETY:
--   * BEGIN ... ROLLBACK: every fixture mutation and Undo is rolled back.
--   * The only pre-Undo fixture mutation is shipment_batch_id NULL -> proven
--     batch id on one existing mutable progressed row.
--   * Groupage is READ ONLY. No Groupage INSERT/UPDATE/DELETE/RPC.
--   * No trigger disabling, ACL change, DDL or product-function replacement.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE shipment_undo_v5_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

DO $test$
DECLARE
  v_batch_id uuid := '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid;
  v_auth_uid uuid;
  v_progressed_before record;
  v_progressed_old record;
  v_progressed_new record;
  v_terminal_id uuid;
  v_terminal_before record;
  v_terminal_after record;
  v_undo_result jsonb;
  v_pass boolean := false;
  v_err text;
BEGIN
  -- Re-prove the already-used base is still created and free of every real Undo
  -- blocker. Mutable progressed rows are deliberately NOT blockers here.
  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batches b
    WHERE b.id = v_batch_id
      AND b.status = 'created'
      AND EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = b.id AND p.active = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_groupage_movement_batches g
        WHERE g.shipment_batch_id = b.id AND g.active = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipping_documents d
        WHERE d.shipment_batch_id = b.id AND d.active = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipping_cost_allocations c
        WHERE c.shipment_batch_id = b.id
          AND c.active = true
          AND c.allocation_status = 'approved'
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
        SELECT 1 FROM public.customer_sales_release_lines r
        WHERE r.source_shipment_batch_id = b.id AND r.release_status = 'active'
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.sage_posting_snapshots s
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
        SELECT 1 FROM public.shipper_final_export_evidence_documents e
        WHERE e.shipment_batch_id = b.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.invoice_adjustment_consumption_ledger l
        LEFT JOIN public.order_tracking_line_allocations a
          ON a.id = l.source_allocation_id
        WHERE l.shipment_batch_id = b.id
          AND l.active = true
          AND l.outcome = 'progressed_allocated'
          AND (
            a.id IS NULL
            OR a.locked_for_export_pack_at IS NOT NULL
            OR a.allocation_status = 'locked_for_export_pack'
            OR EXISTS (
              SELECT 1 FROM public.customer_sales_release_lines r
              WHERE r.tracking_line_allocation_id = a.id
                AND r.release_status = 'active'
            )
          )
      )
  ) THEN
    INSERT INTO shipment_undo_v5_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      false,
      jsonb_build_object('reason','Previously proven base batch is no longer clean/created.')
    );
    RETURN;
  END IF;

  SELECT su.auth_user_id
    INTO v_auth_uid
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su
    ON su.shipper_id = b.shipper_id
   AND su.active = true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id = v_batch_id
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    INSERT INTO shipment_undo_v5_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      false,
      jsonb_build_object('reason','No active shipper auth user for base batch.')
    );
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_auth_uid::text,true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',v_auth_uid::text,'role','authenticated')::text,
    true
  );

  -- v4 proved there is no eligible allocation WITHOUT an active progressed row.
  -- Therefore select one existing active progressed row on an effective allocation,
  -- provided it is currently unbound to a batch and still inside the mutable
  -- boundary used by the production Undo/recalculation authority.
  SELECT
    l.id,
    l.invoice_adjustment_basis_id,
    l.supplier_invoice_id,
    l.supplier_invoice_line_id,
    l.source_allocation_id,
    l.tracking_submission_id,
    l.shipment_batch_id,
    l.qty_consumed,
    l.base_value_consumed_gbp,
    l.discount_consumed_gbp,
    l.delivery_consumed_gbp,
    l.chargeable_adjusted_goods_basis_gbp,
    l.outcome,
    l.reason,
    l.active,
    l.created_by_staff_id,
    l.created_by_operator_id
  INTO v_progressed_before
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) e
  JOIN public.order_tracking_line_allocations a
    ON a.id = e.tracking_line_allocation_id
  JOIN public.invoice_adjustment_consumption_ledger l
    ON l.source_allocation_id = a.id
   AND l.active = true
   AND l.outcome = 'progressed_allocated'
  WHERE l.shipment_batch_id IS NULL
    AND a.locked_for_export_pack_at IS NULL
    AND a.allocation_status <> 'locked_for_export_pack'
    AND NOT EXISTS (
      SELECT 1 FROM public.customer_sales_release_lines r
      WHERE r.tracking_line_allocation_id = a.id
        AND r.release_status = 'active'
    )
  ORDER BY l.created_at,l.id
  LIMIT 1;

  IF v_progressed_before.id IS NULL THEN
    INSERT INTO shipment_undo_v5_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      false,
      jsonb_build_object(
        'reason','No existing active unbound mutable progressed row exists on the proven batch effective allocations.',
        'v4_observation','All effective allocations rejected duplicate progressed insertion; this probe requires one existing unbound row.'
      )
    );
    RETURN;
  END IF;

  BEGIN
    -- Rollback-only stale association fixture: change exactly the field that the
    -- governed Undo is designed to clear/rebuild. No financial/source field is
    -- altered before the RPC.
    UPDATE public.invoice_adjustment_consumption_ledger
    SET shipment_batch_id = v_batch_id
    WHERE id = v_progressed_before.id
      AND active = true
      AND outcome = 'progressed_allocated'
      AND shipment_batch_id IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Could not attach selected mutable progressed row to rollback-only batch fixture.';
    END IF;

    -- Terminal control row: terminal history is explicitly outside Undo mutation.
    -- It may share the source allocation because the live unique index protects
    -- only active progressed_allocated rows.
    INSERT INTO public.invoice_adjustment_consumption_ledger (
      invoice_adjustment_basis_id,
      supplier_invoice_id,
      supplier_invoice_line_id,
      source_allocation_id,
      tracking_submission_id,
      shipment_batch_id,
      qty_consumed,
      base_value_consumed_gbp,
      discount_consumed_gbp,
      delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,
      outcome,
      reason,
      active,
      created_by_staff_id,
      created_by_operator_id
    ) VALUES (
      v_progressed_before.invoice_adjustment_basis_id,
      v_progressed_before.supplier_invoice_id,
      v_progressed_before.supplier_invoice_line_id,
      v_progressed_before.source_allocation_id,
      v_progressed_before.tracking_submission_id,
      v_batch_id,
      0.001,
      0.01,
      0,
      0,
      0.01,
      'shipped_charged',
      'Rollback-only terminal control row for Shipment Undo v5',
      true,
      v_progressed_before.created_by_staff_id,
      v_progressed_before.created_by_operator_id
    ) RETURNING id INTO v_terminal_id;

    SELECT
      id,invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,qty_consumed,
      base_value_consumed_gbp,discount_consumed_gbp,delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,outcome,active,created_by_staff_id,
      created_by_operator_id
    INTO v_terminal_before
    FROM public.invoice_adjustment_consumption_ledger
    WHERE id = v_terminal_id;

    SELECT public.shipper_undo_shipment_batch_v1(
      v_batch_id,
      'Regression v5 mutable adjustment housekeeping — rolled back'
    ) INTO v_undo_result;

    SELECT
      id,invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,qty_consumed,
      base_value_consumed_gbp,discount_consumed_gbp,delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,outcome,reason,active,
      created_by_staff_id,created_by_operator_id,superseded_at
    INTO v_progressed_old
    FROM public.invoice_adjustment_consumption_ledger
    WHERE id = v_progressed_before.id;

    SELECT
      id,invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,qty_consumed,
      base_value_consumed_gbp,discount_consumed_gbp,delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,outcome,reason,active,
      created_by_staff_id,created_by_operator_id,superseded_at
    INTO v_progressed_new
    FROM public.invoice_adjustment_consumption_ledger
    WHERE source_allocation_id = v_progressed_before.source_allocation_id
      AND active = true
      AND outcome = 'progressed_allocated'
    ORDER BY created_at DESC,id DESC
    LIMIT 1;

    SELECT
      id,invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,qty_consumed,
      base_value_consumed_gbp,discount_consumed_gbp,delivery_consumed_gbp,
      chargeable_adjusted_goods_basis_gbp,outcome,active,created_by_staff_id,
      created_by_operator_id
    INTO v_terminal_after
    FROM public.invoice_adjustment_consumption_ledger
    WHERE id = v_terminal_id;

    v_pass :=
      -- Original mutable row became superseded history.
      v_progressed_old.id = v_progressed_before.id
      AND v_progressed_old.active = false
      AND v_progressed_old.outcome = 'superseded'
      AND v_progressed_old.superseded_at IS NOT NULL
      -- Exactly one replacement active progressed row exists and batch link cleared.
      AND v_progressed_new.id IS NOT NULL
      AND v_progressed_new.id IS DISTINCT FROM v_progressed_before.id
      AND v_progressed_new.active = true
      AND v_progressed_new.outcome = 'progressed_allocated'
      AND v_progressed_new.shipment_batch_id IS NULL
      -- Source identities preserved.
      AND v_progressed_new.invoice_adjustment_basis_id IS NOT DISTINCT FROM v_progressed_before.invoice_adjustment_basis_id
      AND v_progressed_new.supplier_invoice_id IS NOT DISTINCT FROM v_progressed_before.supplier_invoice_id
      AND v_progressed_new.supplier_invoice_line_id IS NOT DISTINCT FROM v_progressed_before.supplier_invoice_line_id
      AND v_progressed_new.source_allocation_id IS NOT DISTINCT FROM v_progressed_before.source_allocation_id
      AND v_progressed_new.tracking_submission_id IS NOT DISTINCT FROM v_progressed_before.tracking_submission_id
      -- Financial values preserved exactly.
      AND v_progressed_new.qty_consumed IS NOT DISTINCT FROM v_progressed_before.qty_consumed
      AND v_progressed_new.base_value_consumed_gbp IS NOT DISTINCT FROM v_progressed_before.base_value_consumed_gbp
      AND v_progressed_new.discount_consumed_gbp IS NOT DISTINCT FROM v_progressed_before.discount_consumed_gbp
      AND v_progressed_new.delivery_consumed_gbp IS NOT DISTINCT FROM v_progressed_before.delivery_consumed_gbp
      AND v_progressed_new.chargeable_adjusted_goods_basis_gbp IS NOT DISTINCT FROM v_progressed_before.chargeable_adjusted_goods_basis_gbp
      -- Creation actor attribution preserved.
      AND v_progressed_new.created_by_staff_id IS NOT DISTINCT FROM v_progressed_before.created_by_staff_id
      AND v_progressed_new.created_by_operator_id IS NOT DISTINCT FROM v_progressed_before.created_by_operator_id
      -- Terminal row byte-level business identity/value state untouched.
      AND v_terminal_after.id = v_terminal_before.id
      AND v_terminal_after.invoice_adjustment_basis_id IS NOT DISTINCT FROM v_terminal_before.invoice_adjustment_basis_id
      AND v_terminal_after.supplier_invoice_id IS NOT DISTINCT FROM v_terminal_before.supplier_invoice_id
      AND v_terminal_after.supplier_invoice_line_id IS NOT DISTINCT FROM v_terminal_before.supplier_invoice_line_id
      AND v_terminal_after.source_allocation_id IS NOT DISTINCT FROM v_terminal_before.source_allocation_id
      AND v_terminal_after.tracking_submission_id IS NOT DISTINCT FROM v_terminal_before.tracking_submission_id
      AND v_terminal_after.shipment_batch_id IS NOT DISTINCT FROM v_terminal_before.shipment_batch_id
      AND v_terminal_after.qty_consumed IS NOT DISTINCT FROM v_terminal_before.qty_consumed
      AND v_terminal_after.base_value_consumed_gbp IS NOT DISTINCT FROM v_terminal_before.base_value_consumed_gbp
      AND v_terminal_after.discount_consumed_gbp IS NOT DISTINCT FROM v_terminal_before.discount_consumed_gbp
      AND v_terminal_after.delivery_consumed_gbp IS NOT DISTINCT FROM v_terminal_before.delivery_consumed_gbp
      AND v_terminal_after.chargeable_adjusted_goods_basis_gbp IS NOT DISTINCT FROM v_terminal_before.chargeable_adjusted_goods_basis_gbp
      AND v_terminal_after.outcome = 'shipped_charged'
      AND v_terminal_after.active = true
      AND v_terminal_after.created_by_staff_id IS NOT DISTINCT FROM v_terminal_before.created_by_staff_id
      AND v_terminal_after.created_by_operator_id IS NOT DISTINCT FROM v_terminal_before.created_by_operator_id
      -- RPC reports exactly the one rebuilt row we attached.
      AND COALESCE((v_undo_result->>'rebuilt_progressed_adjustment_count')::integer,0) = 1;

    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    INSERT INTO shipment_undo_v5_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      v_pass AND v_err = '__ROLLBACK_TEST__',
      jsonb_build_object(
        'shipment_batch_id',v_batch_id,
        'original_progressed_id',v_progressed_before.id,
        'source_allocation_id',v_progressed_before.source_allocation_id,
        'fixture_changed_only_shipment_batch_id_before_undo',true,
        'old_progressed_superseded',COALESCE(v_progressed_old.active=false AND v_progressed_old.outcome='superseded' AND v_progressed_old.superseded_at IS NOT NULL,false),
        'replacement_row_created',COALESCE(v_progressed_new.id IS NOT NULL AND v_progressed_new.id IS DISTINCT FROM v_progressed_before.id,false),
        'rebuilt_progressed_batch_cleared',COALESCE(v_progressed_new.shipment_batch_id IS NULL,false),
        'source_identity_preserved',COALESCE(
          v_progressed_new.invoice_adjustment_basis_id IS NOT DISTINCT FROM v_progressed_before.invoice_adjustment_basis_id
          AND v_progressed_new.supplier_invoice_id IS NOT DISTINCT FROM v_progressed_before.supplier_invoice_id
          AND v_progressed_new.supplier_invoice_line_id IS NOT DISTINCT FROM v_progressed_before.supplier_invoice_line_id
          AND v_progressed_new.source_allocation_id IS NOT DISTINCT FROM v_progressed_before.source_allocation_id
          AND v_progressed_new.tracking_submission_id IS NOT DISTINCT FROM v_progressed_before.tracking_submission_id,
          false
        ),
        'financial_values_preserved',COALESCE(
          v_progressed_new.qty_consumed IS NOT DISTINCT FROM v_progressed_before.qty_consumed
          AND v_progressed_new.base_value_consumed_gbp IS NOT DISTINCT FROM v_progressed_before.base_value_consumed_gbp
          AND v_progressed_new.discount_consumed_gbp IS NOT DISTINCT FROM v_progressed_before.discount_consumed_gbp
          AND v_progressed_new.delivery_consumed_gbp IS NOT DISTINCT FROM v_progressed_before.delivery_consumed_gbp
          AND v_progressed_new.chargeable_adjusted_goods_basis_gbp IS NOT DISTINCT FROM v_progressed_before.chargeable_adjusted_goods_basis_gbp,
          false
        ),
        'terminal_row_untouched',COALESCE(
          v_terminal_after.id=v_terminal_before.id
          AND v_terminal_after.shipment_batch_id IS NOT DISTINCT FROM v_terminal_before.shipment_batch_id
          AND v_terminal_after.outcome='shipped_charged'
          AND v_terminal_after.active=true,
          false
        ),
        'rpc_rebuilt_count',v_undo_result->>'rebuilt_progressed_adjustment_count',
        'rolled_back',v_err='__ROLLBACK_TEST__',
        'error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END
      )
    );
  END;
END
$test$;

-- Reconfirm the absolute Groupage/protected-line boundary after the proof.
INSERT INTO shipment_undo_v5_results(test_name,passed,detail)
SELECT
  'protected_authorities_still_unchanged',
  bool_and(live_md5 = expected_md5),
  jsonb_build_object(
    'comparisons',jsonb_agg(jsonb_build_object(
      'signature',signature,
      'expected_md5',expected_md5,
      'live_md5',live_md5,
      'matches',live_md5=expected_md5
    ) ORDER BY signature)
  )
FROM (
  SELECT * FROM (VALUES
    ('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)'::text,'8691cf78f34912d9522f545ebb495529'::text),
    ('public.internal_review_final_export_evidence_document_v1(uuid,text,text)','87c619fbd1bcea84f90718dc538bf6ef'),
    ('public.groupage_recompute_movement_status_v1(uuid)','e78cc0c67e422a88afbae815bc600a0b'),
    ('public.shipper_block_shipment_line_membership_mutation_v1()','c56d6a1a2b2c1bf0ef751a07e3b33ff2')
  ) x(signature,expected_md5)
) expected
CROSS JOIN LATERAL (
  SELECT md5(pg_get_functiondef(to_regprocedure(expected.signature))) AS live_md5
) live;

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_adjustment_regression_v5',
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'transaction_wrapped',true,
  'will_rollback',true,
  'fixture_strategy','reuse existing active unbound mutable progressed row; temporarily attach shipment_batch_id only',
  'groupage_mutation_performed',false,
  'trigger_disabling_performed',false,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER(WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(
    jsonb_build_object('test',test_name,'passed',passed,'detail',detail)
    ORDER BY test_name
  )
)) AS result
FROM shipment_undo_v5_results;

ROLLBACK;
