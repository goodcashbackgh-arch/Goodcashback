-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — ADJUSTMENT REGRESSION v4
--
-- Purpose:
--   Close the only behavioural gap remaining after v3:
--   mutable progressed_allocated adjustment housekeeping.
--
-- SAFETY:
--   * BEGIN ... ROLLBACK: no fixture or Undo mutation is committed.
--   * Uses the already-proven clean Shipment Batch base only.
--   * No Groupage INSERT/UPDATE/DELETE/RPC.
--   * No trigger disabling, ACL change, DDL or product-function replacement.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE shipment_undo_v4_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

DO $test$
DECLARE
  v_batch_id uuid := '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid;
  v_auth_uid uuid;
  v_alloc record;
  v_basis_id uuid;
  v_staff_id uuid;
  v_operator_id uuid;
  v_progressed_id uuid;
  v_terminal_id uuid;
  v_undo_result jsonb;
  v_old record;
  v_new record;
  v_terminal_before record;
  v_terminal_after record;
  v_pass boolean := false;
  v_err text;
BEGIN
  -- Re-prove the selected base is still eligible before constructing anything.
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
  ) THEN
    INSERT INTO shipment_undo_v4_results VALUES (
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
    INSERT INTO shipment_undo_v4_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      false,
      jsonb_build_object('reason','No active shipper auth user for base batch.')
    );
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',v_auth_uid::text,'role','authenticated')::text,
    true
  );

  -- Select one effective allocation that is inside the mutable boundary and has
  -- no existing active progressed row, so the fixture respects the live unique
  -- index rather than bypassing it.
  SELECT
    a.id AS source_allocation_id,
    a.order_id,
    a.tracking_submission_id,
    a.supplier_invoice_line_id,
    sil.supplier_invoice_id,
    a.qty_allocated,
    COALESCE(a.base_value_gbp,0) AS base_value_gbp,
    COALESCE(a.discount_share_gbp,0) AS discount_share_gbp,
    COALESCE(a.retailer_delivery_share_gbp,0) AS delivery_share_gbp,
    COALESCE(a.adjusted_net_value_gbp,0) AS adjusted_net_value_gbp
  INTO v_alloc
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id) e
  JOIN public.order_tracking_line_allocations a
    ON a.id = e.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines sil
    ON sil.id = a.supplier_invoice_line_id
  WHERE a.locked_for_export_pack_at IS NULL
    AND a.allocation_status <> 'locked_for_export_pack'
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines r
      WHERE r.tracking_line_allocation_id = a.id
        AND r.release_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.invoice_adjustment_consumption_ledger l
      WHERE l.source_allocation_id = a.id
        AND l.active = true
        AND l.outcome = 'progressed_allocated'
    )
  ORDER BY a.id
  LIMIT 1;

  IF v_alloc.source_allocation_id IS NULL THEN
    INSERT INTO shipment_undo_v4_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      false,
      jsonb_build_object('reason','No effective mutable allocation without an existing active progressed row.')
    );
    RETURN;
  END IF;

  SELECT id INTO v_basis_id
  FROM public.invoice_adjustment_basis
  WHERE supplier_invoice_id = v_alloc.supplier_invoice_id
  LIMIT 1;

  IF v_basis_id IS NULL THEN
    SELECT id INTO v_staff_id
    FROM public.staff
    WHERE active = true
    ORDER BY created_at, id
    LIMIT 1;

    IF v_staff_id IS NULL THEN
      SELECT id INTO v_operator_id
      FROM public.operators
      WHERE active = true
      ORDER BY created_at, id
      LIMIT 1;
    END IF;

    IF v_staff_id IS NULL AND v_operator_id IS NULL THEN
      INSERT INTO shipment_undo_v4_results VALUES (
        'mutable_progressed_adjustment_housekeeping',
        false,
        jsonb_build_object('reason','No staff/operator actor available to create rollback-only adjustment basis.')
      );
      RETURN;
    END IF;

    INSERT INTO public.invoice_adjustment_basis (
      supplier_invoice_id,
      order_id,
      locked_goods_total_gbp,
      locked_discount_total_gbp,
      locked_delivery_total_gbp,
      locked_by_staff_id,
      locked_by_operator_id,
      notes
    ) VALUES (
      v_alloc.supplier_invoice_id,
      v_alloc.order_id,
      GREATEST(v_alloc.base_value_gbp,0),
      GREATEST(v_alloc.discount_share_gbp,0),
      GREATEST(v_alloc.delivery_share_gbp,0),
      v_staff_id,
      CASE WHEN v_staff_id IS NULL THEN v_operator_id ELSE NULL END,
      'Rollback-only Shipment Undo v4 mutable adjustment fixture'
    )
    RETURNING id INTO v_basis_id;
  END IF;

  BEGIN
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
      active
    ) VALUES (
      v_basis_id,
      v_alloc.supplier_invoice_id,
      v_alloc.supplier_invoice_line_id,
      v_alloc.source_allocation_id,
      v_alloc.tracking_submission_id,
      v_batch_id,
      COALESCE(v_alloc.qty_allocated,0),
      v_alloc.base_value_gbp,
      v_alloc.discount_share_gbp,
      v_alloc.delivery_share_gbp,
      v_alloc.adjusted_net_value_gbp,
      'progressed_allocated',
      'Rollback-only mutable progressed fixture',
      true
    ) RETURNING id INTO v_progressed_id;

    -- Terminal control row: Undo must not touch this row.
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
      active
    ) VALUES (
      v_basis_id,
      v_alloc.supplier_invoice_id,
      v_alloc.supplier_invoice_line_id,
      v_alloc.source_allocation_id,
      v_alloc.tracking_submission_id,
      v_batch_id,
      0.001,
      0.01,
      0,
      0,
      0.01,
      'shipped_charged',
      'Rollback-only terminal control row',
      true
    ) RETURNING id INTO v_terminal_id;

    SELECT
      id, shipment_batch_id, source_allocation_id, qty_consumed,
      base_value_consumed_gbp, discount_consumed_gbp,
      delivery_consumed_gbp, chargeable_adjusted_goods_basis_gbp,
      outcome, active, superseded_at
    INTO v_terminal_before
    FROM public.invoice_adjustment_consumption_ledger
    WHERE id = v_terminal_id;

    SELECT public.shipper_undo_shipment_batch_v1(
      v_batch_id,
      'Regression v4 mutable adjustment housekeeping — rolled back'
    ) INTO v_undo_result;

    SELECT
      id, shipment_batch_id, source_allocation_id, qty_consumed,
      base_value_consumed_gbp, discount_consumed_gbp,
      delivery_consumed_gbp, chargeable_adjusted_goods_basis_gbp,
      outcome, active, superseded_at
    INTO v_old
    FROM public.invoice_adjustment_consumption_ledger
    WHERE id = v_progressed_id;

    SELECT
      id, shipment_batch_id, source_allocation_id, qty_consumed,
      base_value_consumed_gbp, discount_consumed_gbp,
      delivery_consumed_gbp, chargeable_adjusted_goods_basis_gbp,
      outcome, active, superseded_at
    INTO v_new
    FROM public.invoice_adjustment_consumption_ledger
    WHERE source_allocation_id = v_alloc.source_allocation_id
      AND active = true
      AND outcome = 'progressed_allocated'
    ORDER BY created_at DESC, id DESC
    LIMIT 1;

    SELECT
      id, shipment_batch_id, source_allocation_id, qty_consumed,
      base_value_consumed_gbp, discount_consumed_gbp,
      delivery_consumed_gbp, chargeable_adjusted_goods_basis_gbp,
      outcome, active, superseded_at
    INTO v_terminal_after
    FROM public.invoice_adjustment_consumption_ledger
    WHERE id = v_terminal_id;

    v_pass :=
      v_old.id = v_progressed_id
      AND v_old.active = false
      AND v_old.outcome = 'superseded'
      AND v_old.superseded_at IS NOT NULL
      AND v_new.id IS NOT NULL
      AND v_new.id IS DISTINCT FROM v_progressed_id
      AND v_new.shipment_batch_id IS NULL
      AND v_new.source_allocation_id = v_alloc.source_allocation_id
      AND v_new.qty_consumed = COALESCE(v_alloc.qty_allocated,0)
      AND v_new.base_value_consumed_gbp = v_alloc.base_value_gbp
      AND v_new.discount_consumed_gbp = v_alloc.discount_share_gbp
      AND v_new.delivery_consumed_gbp = v_alloc.delivery_share_gbp
      AND v_new.chargeable_adjusted_goods_basis_gbp = v_alloc.adjusted_net_value_gbp
      AND v_terminal_after.id = v_terminal_before.id
      AND v_terminal_after.shipment_batch_id IS NOT DISTINCT FROM v_terminal_before.shipment_batch_id
      AND v_terminal_after.source_allocation_id IS NOT DISTINCT FROM v_terminal_before.source_allocation_id
      AND v_terminal_after.qty_consumed IS NOT DISTINCT FROM v_terminal_before.qty_consumed
      AND v_terminal_after.base_value_consumed_gbp IS NOT DISTINCT FROM v_terminal_before.base_value_consumed_gbp
      AND v_terminal_after.discount_consumed_gbp IS NOT DISTINCT FROM v_terminal_before.discount_consumed_gbp
      AND v_terminal_after.delivery_consumed_gbp IS NOT DISTINCT FROM v_terminal_before.delivery_consumed_gbp
      AND v_terminal_after.chargeable_adjusted_goods_basis_gbp IS NOT DISTINCT FROM v_terminal_before.chargeable_adjusted_goods_basis_gbp
      AND v_terminal_after.outcome = 'shipped_charged'
      AND v_terminal_after.active = true
      AND COALESCE((v_undo_result->>'rebuilt_progressed_adjustment_count')::integer,0) = 1;

    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    INSERT INTO shipment_undo_v4_results VALUES (
      'mutable_progressed_adjustment_housekeeping',
      v_pass AND v_err = '__ROLLBACK_TEST__',
      jsonb_build_object(
        'shipment_batch_id',v_batch_id,
        'source_allocation_id',v_alloc.source_allocation_id,
        'old_progressed_superseded',COALESCE(v_old.active=false AND v_old.outcome='superseded' AND v_old.superseded_at IS NOT NULL,false),
        'rebuilt_progressed_batch_cleared',COALESCE(v_new.id IS NOT NULL AND v_new.shipment_batch_id IS NULL,false),
        'financial_values_preserved',COALESCE(
          v_new.qty_consumed=COALESCE(v_alloc.qty_allocated,0)
          AND v_new.base_value_consumed_gbp=v_alloc.base_value_gbp
          AND v_new.discount_consumed_gbp=v_alloc.discount_share_gbp
          AND v_new.delivery_consumed_gbp=v_alloc.delivery_share_gbp
          AND v_new.chargeable_adjusted_goods_basis_gbp=v_alloc.adjusted_net_value_gbp,
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

-- Protected Groupage authorities must still equal the frozen live preflight.
INSERT INTO shipment_undo_v4_results(test_name,passed,detail)
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
  'probe','shipment_batch_undo_release_control_adjustment_regression_v4',
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'transaction_wrapped',true,
  'will_rollback',true,
  'groupage_mutation_performed',false,
  'trigger_disabling_performed',false,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER(WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(
    jsonb_build_object('test',test_name,'passed',passed,'detail',detail)
    ORDER BY test_name
  )
)) AS result
FROM shipment_undo_v4_results;

ROLLBACK;
