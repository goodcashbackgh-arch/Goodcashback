-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — REMAINING REGRESSION v3
--
-- Corrects the v2 fixture-selector defect only:
-- v2 incorrectly rejected batches carrying active mutable progressed_allocated
-- adjustment rows. Those rows are explicitly NON-BLOCKING under the governing
-- Undo authority unless their source has crossed an immutable boundary.
--
-- This script closes only the cases still unproved after the first live v1 run.
-- It is transaction wrapped and ALWAYS ends in ROLLBACK.
--
-- GROUPAGE SAFETY:
--   * Groupage is READ ONLY.
--   * No Groupage INSERT/UPDATE/DELETE/RPC is performed.
--   * No trigger disabling, ACL change, DDL, or product-function replacement.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE shipment_undo_v3_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.shipment_undo_v3_base_batch()
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
    -- We need a legacy base only so v3 can manufacture an exact snapshot and
    -- prove exact-line Undo without depending on an existing exact fixture.
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id = b.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_groupage_movement_batches g
      WHERE g.shipment_batch_id = b.id
        AND g.active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipping_documents d
      WHERE d.shipment_batch_id = b.id
        AND d.active = true
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipping_cost_allocations c
      WHERE c.shipment_batch_id = b.id
        AND c.active = true
        AND c.allocation_status = 'approved'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_sales_release_lines r
      WHERE r.source_shipment_batch_id = b.id
        AND r.release_status = 'active'
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
      FROM public.shipper_final_export_evidence_documents e
      WHERE e.shipment_batch_id = b.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a
        ON a.id = e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL
         OR a.allocation_status = 'locked_for_export_pack'
    )
    -- IMPORTANT v2 correction: mutable progressed rows are NOT excluded.
    -- Exclude only the actual immutable-adjustment boundary used by Undo.
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
            SELECT 1
            FROM public.customer_sales_release_lines r
            WHERE r.tracking_line_allocation_id = a.id
              AND r.release_status = 'active'
          )
        )
    )
  ORDER BY
    CASE WHEN b.id = '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid THEN 0 ELSE 1 END,
    b.created_at,
    b.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.shipment_undo_v3_set_auth(p_batch_id uuid)
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

-- Base-selection diagnostic. This is deliberately visible in the result so a
-- future fixture drift cannot masquerade as a product failure.
INSERT INTO shipment_undo_v3_results(test_name, passed, detail)
SELECT
  'corrected_base_fixture_available',
  pg_temp.shipment_undo_v3_base_batch() IS NOT NULL,
  jsonb_build_object(
    'shipment_batch_id', pg_temp.shipment_undo_v3_base_batch(),
    'v2_selector_defect_corrected', true,
    'mutable_progressed_rows_allowed', true
  );

-- =============================================================================
-- 1. CLEAN EXACT-LINE UNDO + NO DELETE + AUDIT + IMMUTABILITY + CANDIDATE READ
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_pkg_before integer;
  v_pkg_after integer;
  v_line_before integer;
  v_line_after integer;
  v_active_after integer;
  v_effective_after integer;
  v_candidates integer;
  v_fingerprint_before text;
  v_fingerprint_after text;
  v_reactivation_blocked boolean := false;
  v_pass boolean := false;
  v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES(
      'clean_exact_undo', false,
      jsonb_build_object('reason','Corrected selector still found no base batch.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);

  BEGIN
    INSERT INTO public.shipper_shipment_batch_line_memberships(
      shipment_batch_id, shipment_batch_package_id, tracking_submission_id,
      tracking_line_allocation_id, order_id, supplier_invoice_line_id,
      qty_in_shipment, adjusted_net_value_gbp
    )
    SELECT
      e.shipment_batch_id,
      e.shipment_batch_package_id,
      e.tracking_submission_id,
      e.tracking_line_allocation_id,
      e.order_id,
      e.supplier_invoice_line_id,
      e.qty_in_shipment,
      e.adjusted_net_value_gbp
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch) e;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Base batch has no effective lines to snapshot.';
    END IF;

    SELECT COUNT(*) INTO v_pkg_before
    FROM public.shipper_shipment_batch_packages
    WHERE shipment_batch_id = v_batch;

    SELECT COUNT(*) INTO v_line_before
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', id, shipment_batch_id, shipment_batch_package_id,
        tracking_submission_id, tracking_line_allocation_id, order_id,
        supplier_invoice_line_id, qty_in_shipment, adjusted_net_value_gbp),
      ',' ORDER BY id
    ), ''))
    INTO v_fingerprint_before
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch;

    PERFORM public.shipper_undo_shipment_batch_v1(
      v_batch,
      'v3 exact-line regression — rolled back'
    );

    SELECT COUNT(*) INTO v_pkg_after
    FROM public.shipper_shipment_batch_packages
    WHERE shipment_batch_id = v_batch;

    SELECT COUNT(*) INTO v_line_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch;

    SELECT COUNT(*) INTO v_active_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch AND active = true;

    SELECT COUNT(*) INTO v_effective_after
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch);

    SELECT md5(COALESCE(string_agg(
      concat_ws('|', id, shipment_batch_id, shipment_batch_package_id,
        tracking_submission_id, tracking_line_allocation_id, order_id,
        supplier_invoice_line_id, qty_in_shipment, adjusted_net_value_gbp),
      ',' ORDER BY id
    ), ''))
    INTO v_fingerprint_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id = v_batch;

    SELECT COUNT(*) INTO v_candidates
    FROM public.shipper_shipment_batch_candidates_v2() c
    WHERE c.tracking_submission_id IN (
      SELECT p.tracking_submission_id
      FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id = v_batch
    );

    BEGIN
      UPDATE public.shipper_shipment_batch_line_memberships
      SET active = true
      WHERE shipment_batch_id = v_batch
        AND active = false;
    EXCEPTION WHEN OTHERS THEN
      v_reactivation_blocked := SQLERRM ILIKE '%cannot be reactivated%';
    END;

    v_pass :=
      EXISTS (
        SELECT 1 FROM public.shipper_shipment_batches b
        WHERE b.id = v_batch
          AND b.status = 'voided'
          AND b.voided_at IS NOT NULL
          AND b.voided_by_shipper_user_id IS NOT NULL
          AND NULLIF(BTRIM(COALESCE(b.void_reason,'')),'') IS NOT NULL
      )
      AND v_pkg_before = v_pkg_after
      AND v_line_before = v_line_after
      AND v_fingerprint_before = v_fingerprint_after
      AND v_active_after = 0
      AND v_effective_after = 0
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch
          AND p.active = true
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = v_batch
          AND (
            p.removed_at IS NULL
            OR p.removed_by_shipper_user_id IS NULL
            OR NULLIF(BTRIM(COALESCE(p.remove_reason,'')),'') IS NULL
          )
      )
      AND v_reactivation_blocked;

    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'clean_exact_undo',
      v_pass AND v_err = '__ROLLBACK_TEST__',
      jsonb_build_object(
        'shipment_batch_id',v_batch,
        'package_rows_preserved',v_pkg_before=v_pkg_after,
        'line_rows_preserved',v_line_before=v_line_after,
        'immutable_line_identity_values_preserved',v_fingerprint_before=v_fingerprint_after,
        'active_exact_lines_after',v_active_after,
        'effective_lines_after',v_effective_after,
        'inactive_line_reactivation_blocked',v_reactivation_blocked,
        'candidate_query_succeeded',v_candidates IS NOT NULL,
        'candidate_count_after',v_candidates,
        'rolled_back',v_err='__ROLLBACK_TEST__',
        'error',CASE WHEN v_err <> '__ROLLBACK_TEST__' THEN v_err ELSE NULL END
      )
    );
  END;
END
$t$;

-- =============================================================================
-- 2. APPROVED SHIPPING COST BLOCKS
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_shipper uuid; v_importer uuid; v_user uuid; v_doc uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('active_approved_shipping_cost_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT b.shipper_id,b.importer_id,su.id INTO v_shipper,v_importer,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);

  BEGIN
    INSERT INTO public.shipping_documents(
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES(
      v_batch,v_shipper,v_importer,v_user,'shipper_invoice','REG-V3-COST',
      'GBP',10,'regression://v3/cost-doc','complete','superseded',993001,false,now()
    ) RETURNING id INTO v_doc;

    INSERT INTO public.shipping_cost_allocations(
      shipping_document_id,shipment_batch_id,importer_id,shipper_id,
      source_currency_code,source_total_amount,total_weighted_basis,
      total_allocated_amount,allocation_status,approval_note,approved_at,active
    ) VALUES(
      v_doc,v_batch,v_importer,v_shipper,'GBP',10,10,10,'approved',
      'v3 rollback-only cost blocker',now(),true
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 cost blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'active_approved_shipping_cost_blocks',
      v_err ILIKE '%active approved shipping-cost allocation%',
      jsonb_build_object('error',v_err,'fixture_rolled_back',true)
    );
  END;
END
$t$;

-- =============================================================================
-- 3. EXPORT LOCK BLOCKS
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_alloc uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('export_lock_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT e.tracking_line_allocation_id INTO v_alloc
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch) e
  ORDER BY e.tracking_line_allocation_id LIMIT 1;
  IF v_alloc IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('export_lock_blocks',false,jsonb_build_object('reason','Base has no allocation.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    UPDATE public.order_tracking_line_allocations
    SET locked_for_export_pack_at=now()
    WHERE id=v_alloc;
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 export lock blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'export_lock_blocks',
      v_err ILIKE '%locked for export%',
      jsonb_build_object('error',v_err,'allocation_id',v_alloc,'fixture_rolled_back',true)
    );
  END;
END
$t$;

-- =============================================================================
-- 4. ACCOUNTING BOUNDARIES: ACTIVE/FROZEN AND INACTIVE POSTED
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_pb uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('active_accounting_snapshot_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES('REG-V3-'||gen_random_uuid()::text,'preview_freeze','frozen_pending_posting','v3 active snapshot','shipment_undo_regression')
    RETURNING id INTO v_pb;

    INSERT INTO public.sage_posting_snapshots(
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,amount_gbp,currency_code,resolved_payload,commercial_payload,
      mapping_snapshot,mapping_semantic_fingerprint,payload_semantic_fingerprint,
      idempotency_key,approval_status,sage_posting_status,active
    ) VALUES(
      v_pb,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','v3_active',
      v_batch,1,'GBP','{}'::jsonb,'{}'::jsonb,'{}'::jsonb,
      md5(gen_random_uuid()::text),md5(gen_random_uuid()::text),
      'REG-V3-'||gen_random_uuid()::text,'approved_frozen','not_posted',true
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 accounting blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'active_accounting_snapshot_blocks',
      v_err ILIKE '%accounting snapshot%',
      jsonb_build_object('error',v_err,'fixture_rolled_back',true)
    );
  END;
END
$t$;

DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_pb uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('posted_accounting_snapshot_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES('REG-V3-'||gen_random_uuid()::text,'preview_freeze','posted','v3 posted snapshot','shipment_undo_regression')
    RETURNING id INTO v_pb;

    INSERT INTO public.sage_posting_snapshots(
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,amount_gbp,currency_code,resolved_payload,commercial_payload,
      mapping_snapshot,mapping_semantic_fingerprint,payload_semantic_fingerprint,
      idempotency_key,approval_status,sage_posting_status,sage_invoice_id,sage_posted_at,active
    ) VALUES(
      v_pb,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','v3_posted',
      v_batch,1,'GBP','{}'::jsonb,'{}'::jsonb,'{}'::jsonb,
      md5(gen_random_uuid()::text),md5(gen_random_uuid()::text),
      'REG-V3-'||gen_random_uuid()::text,'approved_frozen','posted','REG-V3-POSTED',now(),false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 posted accounting blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'posted_accounting_snapshot_blocks',
      v_err ILIKE '%accounting snapshot%',
      jsonb_build_object('error',v_err,'inactive_posted_history_blocks',true,'fixture_rolled_back',true)
    );
  END;
END
$t$;

-- =============================================================================
-- 5. ANY FINAL EXPORT EVIDENCE BLOCKS — ALL THREE REVIEW STATES
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_shipper uuid; v_user uuid; v_status text; v_test text; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('submitted_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    INSERT INTO shipment_undo_v3_results VALUES('accepted_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    INSERT INTO shipment_undo_v3_results VALUES('rejected_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT b.shipper_id,su.id INTO v_shipper,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);

  FOREACH v_status IN ARRAY ARRAY['submitted_for_review','accepted_current','rejected_resubmit_required'] LOOP
    v_test := CASE v_status
      WHEN 'submitted_for_review' THEN 'submitted_final_evidence_blocks'
      WHEN 'accepted_current' THEN 'accepted_final_evidence_blocks'
      ELSE 'rejected_final_evidence_blocks'
    END;

    BEGIN
      INSERT INTO public.shipper_final_export_evidence_documents(
        shipment_batch_id,shipper_id,document_kind,document_ref,file_url,
        notes,review_status,created_by_shipper_user_id
      ) VALUES(
        v_batch,v_shipper,'completed_cos','REG-V3-'||v_status,
        'regression://v3/final/'||v_status,'v3 rollback-only final evidence',
        v_status,v_user
      );

      PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 final evidence blocker');
      RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
    EXCEPTION WHEN OTHERS THEN
      v_err:=SQLERRM;
      INSERT INTO shipment_undo_v3_results VALUES(
        v_test,
        v_err ILIKE '%final export evidence exists%',
        jsonb_build_object('review_status',v_status,'error',v_err,'fixture_rolled_back',true)
      );
    END;
  END LOOP;
END
$t$;

-- =============================================================================
-- 6. NON-BLOCKERS: COMPLETION FIELDS / INACTIVE DOC / COST / ACCOUNTING
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_pass boolean := false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('completion_fields_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch);
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 completion nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'completion_fields_nonblocking',v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$t$;

DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_shipper uuid; v_importer uuid; v_user uuid; v_pass boolean := false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('inactive_shipping_document_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT b.shipper_id,b.importer_id,su.id INTO v_shipper,v_importer,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    INSERT INTO public.shipping_documents(
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES(
      v_batch,v_shipper,v_importer,v_user,'shipper_invoice','REG-V3-INACTIVE-DOC',
      'GBP',1,'regression://v3/inactive-doc','complete','superseded',993002,false,now()
    );
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 inactive doc nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'inactive_shipping_document_history_nonblocking',v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$t$;

DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_shipper uuid; v_importer uuid; v_user uuid; v_doc uuid;
  v_pass boolean := false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('inactive_shipping_cost_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT b.shipper_id,b.importer_id,su.id INTO v_shipper,v_importer,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    INSERT INTO public.shipping_documents(
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES(
      v_batch,v_shipper,v_importer,v_user,'shipper_invoice','REG-V3-INACTIVE-COST-DOC',
      'GBP',10,'regression://v3/inactive-cost-doc','complete','superseded',993003,false,now()
    ) RETURNING id INTO v_doc;

    INSERT INTO public.shipping_cost_allocations(
      shipping_document_id,shipment_batch_id,importer_id,shipper_id,
      source_currency_code,source_total_amount,total_weighted_basis,total_allocated_amount,
      allocation_status,approval_note,active
    ) VALUES(
      v_doc,v_batch,v_importer,v_shipper,'GBP',10,10,10,'superseded',
      'v3 rollback-only inactive cost history',false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 inactive cost nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'inactive_shipping_cost_history_nonblocking',v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$t$;

DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_pb uuid; v_pass boolean := false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('inactive_never_posted_accounting_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES('REG-V3-'||gen_random_uuid()::text,'preview_freeze','superseded','v3 inactive history','shipment_undo_regression')
    RETURNING id INTO v_pb;

    INSERT INTO public.sage_posting_snapshots(
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,amount_gbp,currency_code,resolved_payload,commercial_payload,
      mapping_snapshot,mapping_semantic_fingerprint,payload_semantic_fingerprint,
      idempotency_key,approval_status,sage_posting_status,active
    ) VALUES(
      v_pb,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','v3_inactive',
      v_batch,1,'GBP','{}'::jsonb,'{}'::jsonb,'{}'::jsonb,
      md5(gen_random_uuid()::text),md5(gen_random_uuid()::text),
      'REG-V3-'||gen_random_uuid()::text,'superseded','not_posted',false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 inactive accounting nonblock');
    v_pass := EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'inactive_never_posted_accounting_history_nonblocking',v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$t$;

-- =============================================================================
-- 7. MUTABLE PROGRESSED ADJUSTMENT HOUSEKEEPING — USE REAL MUTABLE ROWS
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid;
  v_source_ids uuid[];
  v_source_count integer;
  v_old_superseded integer;
  v_rebuilt integer;
  v_before text;
  v_after text;
  v_terminal_before text;
  v_terminal_after text;
  v_pass boolean := false;
  v_err text;
BEGIN
  SELECT b.id INTO v_batch
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS(SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true)
    AND EXISTS(
      SELECT 1 FROM public.invoice_adjustment_consumption_ledger l
      WHERE l.shipment_batch_id=b.id AND l.active=true AND l.outcome='progressed_allocated'
    )
    AND NOT EXISTS(SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=true)
    AND NOT EXISTS(SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true)
    AND NOT EXISTS(SELECT 1 FROM public.shipping_cost_allocations c WHERE c.shipment_batch_id=b.id AND c.active=true AND c.allocation_status='approved')
    AND NOT EXISTS(SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active')
    AND NOT EXISTS(SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id)
    AND NOT EXISTS(
      SELECT 1 FROM public.sage_posting_snapshots s
      WHERE s.shipment_batch_id=b.id
        AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
    )
    AND NOT EXISTS(
      SELECT 1
      FROM public.invoice_adjustment_consumption_ledger l
      LEFT JOIN public.order_tracking_line_allocations a ON a.id=l.source_allocation_id
      WHERE l.shipment_batch_id=b.id AND l.active=true AND l.outcome='progressed_allocated'
        AND (
          a.id IS NULL OR a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
          OR EXISTS(SELECT 1 FROM public.customer_sales_release_lines r WHERE r.tracking_line_allocation_id=a.id AND r.release_status='active')
        )
    )
  ORDER BY CASE WHEN b.id='27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid THEN 0 ELSE 1 END,b.created_at,b.id
  LIMIT 1;

  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES(
      'mutable_progressed_adjustment_housekeeping',false,
      jsonb_build_object('reason','No real mutable progressed-adjustment batch currently exists.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);

  BEGIN
    SELECT array_agg(DISTINCT l.source_allocation_id ORDER BY l.source_allocation_id),
           COUNT(DISTINCT l.source_allocation_id)::integer
      INTO v_source_ids,v_source_count
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id=v_batch AND l.active=true AND l.outcome='progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',l.source_allocation_id,l.qty_consumed,l.base_value_consumed_gbp,
        l.discount_consumed_gbp,l.delivery_consumed_gbp,l.chargeable_adjusted_goods_basis_gbp),
      ',' ORDER BY l.source_allocation_id
    ),'')) INTO v_before
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id=v_batch AND l.active=true AND l.outcome='progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',l.id,l.outcome,l.active,l.shipment_batch_id,l.qty_consumed,
        l.base_value_consumed_gbp,l.discount_consumed_gbp,l.delivery_consumed_gbp,
        l.chargeable_adjusted_goods_basis_gbp),',' ORDER BY l.id
    ),'')) INTO v_terminal_before
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.outcome IN ('shipped_charged','refunded_nil_charge','replacement_child','written_off_nil_charge');

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 mutable adjustment housekeeping');

    SELECT COUNT(*)::integer INTO v_old_superseded
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id=v_batch
      AND l.source_allocation_id=ANY(v_source_ids)
      AND l.active=false AND l.outcome='superseded' AND l.superseded_at IS NOT NULL;

    SELECT COUNT(*)::integer INTO v_rebuilt
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id IS NULL
      AND l.source_allocation_id=ANY(v_source_ids)
      AND l.active=true AND l.outcome='progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',l.source_allocation_id,l.qty_consumed,l.base_value_consumed_gbp,
        l.discount_consumed_gbp,l.delivery_consumed_gbp,l.chargeable_adjusted_goods_basis_gbp),
      ',' ORDER BY l.source_allocation_id
    ),'')) INTO v_after
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.shipment_batch_id IS NULL
      AND l.source_allocation_id=ANY(v_source_ids)
      AND l.active=true AND l.outcome='progressed_allocated';

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',l.id,l.outcome,l.active,l.shipment_batch_id,l.qty_consumed,
        l.base_value_consumed_gbp,l.discount_consumed_gbp,l.delivery_consumed_gbp,
        l.chargeable_adjusted_goods_basis_gbp),',' ORDER BY l.id
    ),'')) INTO v_terminal_after
    FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.outcome IN ('shipped_charged','refunded_nil_charge','replacement_child','written_off_nil_charge');

    v_pass := v_source_count>0
      AND v_old_superseded>=v_source_count
      AND v_rebuilt=v_source_count
      AND v_before=v_after
      AND v_terminal_before=v_terminal_after;

    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'mutable_progressed_adjustment_housekeeping',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object(
        'shipment_batch_id',v_batch,
        'source_count',v_source_count,
        'old_rows_superseded',v_old_superseded,
        'rebuilt_rows',v_rebuilt,
        'financial_values_preserved',v_before=v_after,
        'terminal_rows_unchanged',v_terminal_before=v_terminal_after,
        'rolled_back',v_err='__ROLLBACK_TEST__',
        'error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END
      )
    );
  END;
END
$t$;

-- =============================================================================
-- 8. WRONG SHIPPER REJECTS — TEMPORARILY REASSIGN BATCH TO ANOTHER SHIPPER
--    inside the rollback-only subtransaction. No shipper user or Groupage row is
--    changed. The batch-row mutation is rolled back immediately after rejection.
-- =============================================================================
DO $t$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_v3_base_batch();
  v_owner_shipper uuid; v_other_shipper uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES('wrong_shipper_rejected',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT shipper_id INTO v_owner_shipper FROM public.shipper_shipment_batches WHERE id=v_batch;
  SELECT s.id INTO v_other_shipper
  FROM public.shippers s
  WHERE s.id IS DISTINCT FROM v_owner_shipper
  ORDER BY s.id LIMIT 1;

  IF v_other_shipper IS NULL THEN
    INSERT INTO shipment_undo_v3_results VALUES(
      'wrong_shipper_rejected',false,
      jsonb_build_object('reason','No second shipper entity exists for rollback-only ownership probe.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_v3_set_auth(v_batch);

  BEGIN
    UPDATE public.shipper_shipment_batches
    SET shipper_id=v_other_shipper
    WHERE id=v_batch;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'v3 wrong shipper probe');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_v3_results VALUES(
      'wrong_shipper_rejected',
      v_err ILIKE '%does not belong to this shipper%',
      jsonb_build_object('error',v_err,'batch_ownership_probe_rolled_back',true)
    );
  END;
END
$t$;

-- =============================================================================
-- 9. STRUCTURAL FALLBACKS ALREADY NEEDED BY LIVE DATA
-- =============================================================================
INSERT INTO shipment_undo_v3_results(test_name,passed,detail)
SELECT
  'inactive_groupage_history_nonblocking',
  pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure)
    ILIKE '%gmb.active = true%',
  jsonb_build_object('coverage_mode','structural_fallback_no_groupage_mutation','groupage_mutated',false);

INSERT INTO shipment_undo_v3_results(test_name,passed,detail)
SELECT
  'reversed_customer_release_history_nonblocking',
  pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure)
    ILIKE '%csrl.release_status = ''active''%',
  jsonb_build_object('coverage_mode','structural_fallback_no_real_reversed_fixture');

-- Protected authority fingerprints captured before deployment must remain exact.
INSERT INTO shipment_undo_v3_results(test_name,passed,detail)
SELECT
  'protected_authorities_still_unchanged',
  bool_and(live_md5=expected_md5),
  jsonb_build_object('comparisons',jsonb_agg(jsonb_build_object(
    'signature',signature,'expected_md5',expected_md5,'live_md5',live_md5,'matches',live_md5=expected_md5
  ) ORDER BY signature))
FROM (
  SELECT x.signature,x.expected_md5,md5(pg_get_functiondef(x.signature::regprocedure)) AS live_md5
  FROM (VALUES
    ('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)','8691cf78f34912d9522f545ebb495529'),
    ('public.internal_review_final_export_evidence_document_v1(uuid,text,text)','87c619fbd1bcea84f90718dc538bf6ef'),
    ('public.groupage_recompute_movement_status_v1(uuid)','e78cc0c67e422a88afbae815bc600a0b'),
    ('public.shipper_block_shipment_line_membership_mutation_v1()','c56d6a1a2b2c1bf0ef751a07e3b33ff2')
  ) x(signature,expected_md5)
) q;

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_remaining_regression_v3',
  'selector_fix','mutable progressed_allocated rows are non-blocking unless immutable boundary crossed',
  'transaction_wrapped',true,
  'will_rollback',true,
  'groupage_mutation_performed',false,
  'trigger_disabling_performed',false,
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER(WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(jsonb_build_object('test',test_name,'passed',passed,'detail',detail) ORDER BY test_name)
)) AS result
FROM shipment_undo_v3_results;

ROLLBACK;
