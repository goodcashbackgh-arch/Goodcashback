-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — REMAINING REGRESSION v2
--
-- Purpose:
--   Close only the behavioural gaps reported by the first live regression run.
--   The already-proven cases are not repeated unnecessarily.
--
-- SAFETY:
--   * BEGIN ... ROLLBACK: nothing in this file is committed.
--   * Controlled fixtures are NON-GROUPAGE only.
--   * Groupage is READ ONLY; no Groupage INSERT/UPDATE/DELETE/RPC is performed.
--   * No trigger disabling, no ACL changes, no function replacement.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE shipment_undo_remaining_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.shipment_undo_clean_legacy_batch()
RETURNS uuid
LANGUAGE sql
AS $$
  SELECT b.id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id=b.id AND p.active=true
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
      WHERE m.shipment_batch_id=b.id
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
      SELECT 1 FROM public.customer_sales_release_lines r
      WHERE r.source_shipment_batch_id=b.id AND r.release_status='active'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.sage_posting_snapshots s
      WHERE s.shipment_batch_id=b.id
        AND (
          s.sage_posting_status='posted'
          OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided')
        )
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_final_export_evidence_documents e
      WHERE e.shipment_batch_id=b.id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL
         OR a.allocation_status='locked_for_export_pack'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.invoice_adjustment_consumption_ledger l
        ON l.source_allocation_id=e.tracking_line_allocation_id
       AND l.active=true
       AND l.outcome='progressed_allocated'
    )
  ORDER BY
    CASE WHEN b.id='27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid THEN 0 ELSE 1 END,
    b.created_at,
    b.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp.shipment_undo_set_auth(p_batch_id uuid)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE v_uid uuid;
BEGIN
  SELECT su.auth_user_id INTO v_uid
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su
    ON su.shipper_id=b.shipper_id
   AND su.active=true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id=p_batch_id
  ORDER BY su.created_at DESC,su.id DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No active shipper auth user for batch %',p_batch_id;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_uid::text,true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',v_uid::text,'role','authenticated')::text,
    true
  );
  RETURN v_uid;
END;
$$;

-- -----------------------------------------------------------------------------
-- 1. CLEAN EXACT-LINE UNDO
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_inserted integer := 0;
  v_before text;
  v_after text;
  v_effective_after integer;
  v_active_after integer;
  v_candidates integer;
  v_pass boolean := false;
  v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('clean_exact_undo',false,jsonb_build_object('reason','No clean legacy base batch available.'));
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_set_auth(v_batch);

  BEGIN
    INSERT INTO public.shipper_shipment_batch_line_memberships(
      shipment_batch_id,shipment_batch_package_id,tracking_submission_id,
      tracking_line_allocation_id,order_id,supplier_invoice_line_id,
      qty_in_shipment,adjusted_net_value_gbp
    )
    SELECT
      p.shipment_batch_id,p.id,p.tracking_submission_id,a.id,
      a.order_id,a.supplier_invoice_line_id,a.qty_allocated,
      COALESCE(a.adjusted_net_value_gbp,0)
    FROM public.shipper_shipment_batch_packages p
    JOIN public.order_tracking_line_allocations a
      ON a.tracking_submission_id=p.tracking_submission_id
     AND a.order_id=p.order_id
    WHERE p.shipment_batch_id=v_batch
      AND p.active=true
      AND COALESCE(a.qty_allocated,0)>0;
    GET DIAGNOSTICS v_inserted=ROW_COUNT;

    IF v_inserted=0 THEN
      RAISE EXCEPTION 'No exact allocation lines available for controlled snapshot.';
    END IF;

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',id,shipment_batch_id,shipment_batch_package_id,
        tracking_submission_id,tracking_line_allocation_id,order_id,
        supplier_invoice_line_id,qty_in_shipment,adjusted_net_value_gbp),
      ',' ORDER BY id
    ),'')) INTO v_before
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id=v_batch;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Regression exact-line Undo');

    SELECT md5(COALESCE(string_agg(
      concat_ws('|',id,shipment_batch_id,shipment_batch_package_id,
        tracking_submission_id,tracking_line_allocation_id,order_id,
        supplier_invoice_line_id,qty_in_shipment,adjusted_net_value_gbp),
      ',' ORDER BY id
    ),'')) INTO v_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id=v_batch;

    SELECT COUNT(*) INTO v_active_after
    FROM public.shipper_shipment_batch_line_memberships
    WHERE shipment_batch_id=v_batch AND active=true;

    SELECT COUNT(*) INTO v_effective_after
    FROM public.shipper_shipment_batch_effective_lines_v1(v_batch);

    SELECT COUNT(*) INTO v_candidates
    FROM public.shipper_shipment_batch_candidates_v2() c
    WHERE c.tracking_submission_id IN (
      SELECT p.tracking_submission_id
      FROM public.shipper_shipment_batch_packages p
      WHERE p.shipment_batch_id=v_batch
    );

    v_pass :=
      EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided')
      AND v_active_after=0
      AND v_effective_after=0
      AND v_before=v_after
      AND NOT EXISTS(
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id=v_batch AND p.active=true
      )
      AND NOT EXISTS(
        SELECT 1 FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id=v_batch
          AND (p.removed_at IS NULL OR p.removed_by_shipper_user_id IS NULL OR NULLIF(BTRIM(COALESCE(p.remove_reason,'')),'') IS NULL)
      );

    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'clean_exact_undo',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object(
        'controlled_exact_lines',v_inserted,
        'immutable_identity_values_preserved',v_before=v_after,
        'active_exact_lines_after',v_active_after,
        'effective_lines_after',v_effective_after,
        'candidate_query_succeeded',v_candidates IS NOT NULL,
        'candidate_count_after',v_candidates,
        'rolled_back',v_err='__ROLLBACK_TEST__',
        'error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END
      )
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 2. ACTIVE APPROVED SHIPPING COST BLOCKS
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_shipper uuid; v_importer uuid; v_user uuid; v_doc uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('active_approved_shipping_cost_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT b.shipper_id,b.importer_id,su.id INTO v_shipper,v_importer,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);

  BEGIN
    INSERT INTO public.shipping_documents(
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES(
      v_batch,v_shipper,v_importer,v_user,'shipper_invoice','REG-COST-DOC',
      'GBP',10,'regression://cost-doc','complete','superseded',990001,false,now()
    ) RETURNING id INTO v_doc;

    INSERT INTO public.shipping_cost_allocations(
      shipping_document_id,shipment_batch_id,importer_id,shipper_id,
      source_currency_code,source_total_amount,total_weighted_basis,
      total_allocated_amount,allocation_status,approval_note,approved_at,active
    ) VALUES(
      v_doc,v_batch,v_importer,v_shipper,'GBP',10,10,10,'approved',
      'Rollback-only approved cost blocker',now(),true
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Approved cost blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'active_approved_shipping_cost_blocks',
      v_err ILIKE '%active approved shipping-cost allocation%',
      jsonb_build_object('error',v_err,'controlled_fixture_rolled_back',true)
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 3. EXPORT LOCK BLOCKS
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_alloc uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('export_lock_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT e.tracking_line_allocation_id INTO v_alloc
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch) e
  ORDER BY e.tracking_line_allocation_id LIMIT 1;

  IF v_alloc IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('export_lock_blocks',false,jsonb_build_object('reason','Base batch has no effective allocation.'));
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    UPDATE public.order_tracking_line_allocations SET locked_for_export_pack_at=now() WHERE id=v_alloc;
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Export lock blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'export_lock_blocks',
      v_err ILIKE '%locked for export%',
      jsonb_build_object('error',v_err,'allocation_id',v_alloc,'controlled_lock_rolled_back',true)
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 4. ACCOUNTING: ACTIVE/FROZEN AND INACTIVE POSTED BOTH BLOCK
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_pb uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('active_accounting_snapshot_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES('REG-'||gen_random_uuid()::text,'preview_freeze','frozen_pending_posting','Rollback-only active snapshot','shipment_undo_regression')
    RETURNING id INTO v_pb;

    INSERT INTO public.sage_posting_snapshots(
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,amount_gbp,currency_code,resolved_payload,commercial_payload,
      mapping_snapshot,mapping_semantic_fingerprint,payload_semantic_fingerprint,
      idempotency_key,approval_status,sage_posting_status,active
    ) VALUES(
      v_pb,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','regression_active',
      v_batch,1,'GBP','{}','{}','{}',md5(gen_random_uuid()::text),
      md5(gen_random_uuid()::text),'REG-'||gen_random_uuid()::text,
      'approved_frozen','not_posted',true
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Active accounting blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'active_accounting_snapshot_blocks',
      v_err ILIKE '%accounting snapshot%',
      jsonb_build_object('error',v_err,'controlled_fixture_rolled_back',true)
    );
  END;
END
$test$;

DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_pb uuid; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('posted_accounting_snapshot_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES('REG-'||gen_random_uuid()::text,'preview_freeze','posted','Rollback-only posted snapshot','shipment_undo_regression')
    RETURNING id INTO v_pb;

    INSERT INTO public.sage_posting_snapshots(
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,amount_gbp,currency_code,resolved_payload,commercial_payload,
      mapping_snapshot,mapping_semantic_fingerprint,payload_semantic_fingerprint,
      idempotency_key,approval_status,sage_posting_status,sage_invoice_id,sage_posted_at,active
    ) VALUES(
      v_pb,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','regression_posted',
      v_batch,1,'GBP','{}','{}','{}',md5(gen_random_uuid()::text),
      md5(gen_random_uuid()::text),'REG-'||gen_random_uuid()::text,
      'approved_frozen','posted','REG-POSTED',now(),false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Posted accounting blocker');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'posted_accounting_snapshot_blocks',
      v_err ILIKE '%accounting snapshot%',
      jsonb_build_object('error',v_err,'inactive_posted_history_hard_block',true,'controlled_fixture_rolled_back',true)
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 5. ANY FINAL EVIDENCE BLOCKS: ALL THREE STATUSES
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_shipper uuid; v_user uuid; v_status text; v_name text; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('submitted_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    INSERT INTO shipment_undo_remaining_results VALUES('accepted_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    INSERT INTO shipment_undo_remaining_results VALUES('rejected_final_evidence_blocks',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT b.shipper_id,su.id INTO v_shipper,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);

  FOREACH v_status IN ARRAY ARRAY['submitted_for_review','accepted_current','rejected_resubmit_required'] LOOP
    v_name:=CASE v_status
      WHEN 'submitted_for_review' THEN 'submitted_final_evidence_blocks'
      WHEN 'accepted_current' THEN 'accepted_final_evidence_blocks'
      ELSE 'rejected_final_evidence_blocks'
    END;

    BEGIN
      INSERT INTO public.shipper_final_export_evidence_documents(
        shipment_batch_id,shipper_id,document_kind,document_ref,file_url,
        notes,review_status,created_by_shipper_user_id
      ) VALUES(
        v_batch,v_shipper,'completed_cos','REG-'||v_status,
        'regression://final-evidence/'||v_status,'Rollback-only final evidence',
        v_status,v_user
      );

      PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Final evidence blocker');
      RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
    EXCEPTION WHEN OTHERS THEN
      v_err:=SQLERRM;
      INSERT INTO shipment_undo_remaining_results VALUES(
        v_name,
        v_err ILIKE '%final export evidence exists%',
        jsonb_build_object('review_status',v_status,'error',v_err,'controlled_fixture_rolled_back',true)
      );
    END;
  END LOOP;
END
$test$;

-- -----------------------------------------------------------------------------
-- 6. COMPLETION FIELDS DO NOT BLOCK
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_pass boolean:=false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('completion_fields_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    PERFORM public.shipper_save_export_evidence_completion_fields_v1(v_batch);
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Completion fields nonblock');
    v_pass:=EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'completion_fields_nonblocking',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 7. INACTIVE DOCUMENT / COST / NEVER-POSTED ACCOUNTING DO NOT BLOCK
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_shipper uuid; v_importer uuid; v_user uuid; v_pass boolean:=false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('inactive_shipping_document_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT b.shipper_id,b.importer_id,su.id INTO v_shipper,v_importer,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    INSERT INTO public.shipping_documents(
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES(
      v_batch,v_shipper,v_importer,v_user,'shipper_invoice','REG-INACTIVE-DOC',
      'GBP',1,'regression://inactive-doc','complete','superseded',990002,false,now()
    );
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Inactive document nonblock');
    v_pass:=EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'inactive_shipping_document_history_nonblocking',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$test$;

DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_shipper uuid; v_importer uuid; v_user uuid; v_doc uuid; v_pass boolean:=false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('inactive_shipping_cost_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  SELECT b.shipper_id,b.importer_id,su.id INTO v_shipper,v_importer,v_user
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    INSERT INTO public.shipping_documents(
      shipment_batch_id,shipper_id,importer_id,uploaded_by_shipper_user_id,
      document_kind,document_ref,currency_code,total_amount,file_url,
      ocr_status,review_status,version_no,active,superseded_at
    ) VALUES(
      v_batch,v_shipper,v_importer,v_user,'shipper_invoice','REG-INACTIVE-COST-DOC',
      'GBP',10,'regression://inactive-cost-doc','complete','superseded',990003,false,now()
    ) RETURNING id INTO v_doc;

    INSERT INTO public.shipping_cost_allocations(
      shipping_document_id,shipment_batch_id,importer_id,shipper_id,
      source_currency_code,source_total_amount,total_weighted_basis,total_allocated_amount,
      allocation_status,approval_note,active
    ) VALUES(
      v_doc,v_batch,v_importer,v_shipper,'GBP',10,10,10,'superseded','Rollback-only inactive cost',false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Inactive cost nonblock');
    v_pass:=EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'inactive_shipping_cost_history_nonblocking',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$test$;

DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_pb uuid; v_pass boolean:=false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('inactive_never_posted_accounting_history_nonblocking',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;
  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    INSERT INTO public.sage_posting_batches(batch_ref,batch_kind,batch_status,notes,source)
    VALUES('REG-'||gen_random_uuid()::text,'preview_freeze','superseded','Rollback-only inactive accounting','shipment_undo_regression')
    RETURNING id INTO v_pb;

    INSERT INTO public.sage_posting_snapshots(
      batch_id,source_table,source_id,document_lane,document_type,
      shipment_batch_id,amount_gbp,currency_code,resolved_payload,commercial_payload,
      mapping_snapshot,mapping_semantic_fingerprint,payload_semantic_fingerprint,
      idempotency_key,approval_status,sage_posting_status,active
    ) VALUES(
      v_pb,'shipment_undo_regression',gen_random_uuid(),'shipper_ap','regression_inactive',
      v_batch,1,'GBP','{}','{}','{}',md5(gen_random_uuid()::text),
      md5(gen_random_uuid()::text),'REG-'||gen_random_uuid()::text,
      'superseded','not_posted',false
    );

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Inactive accounting nonblock');
    v_pass:=EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'inactive_never_posted_accounting_history_nonblocking',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__','error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END)
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 8. WRONG SHIPPER REJECTS
--    Uses an existing second shipper entity if present. The shipper-user
--    reassignment is inside the exception subtransaction and is rolled back.
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_user uuid; v_uid uuid; v_owner_shipper uuid; v_other_shipper uuid;
  v_err text; v_def text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('wrong_shipper_rejected',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT su.id,su.auth_user_id,b.shipper_id INTO v_user,v_uid,v_owner_shipper
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su ON su.shipper_id=b.shipper_id AND su.active=true AND su.auth_user_id IS NOT NULL
  WHERE b.id=v_batch ORDER BY su.created_at DESC,su.id DESC LIMIT 1;

  SELECT s.id INTO v_other_shipper
  FROM public.shippers s
  WHERE s.id IS DISTINCT FROM v_owner_shipper
  ORDER BY s.id LIMIT 1;

  IF v_other_shipper IS NULL THEN
    SELECT pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure) INTO v_def;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'wrong_shipper_rejected',
      v_def ILIKE '%v_batch.shipper_id IS DISTINCT FROM v_shipper_id%'
        AND v_def ILIKE '%Shipment batch does not belong to this shipper%',
      jsonb_build_object('coverage_mode','structural_fallback_no_second_shipper_entity')
    );
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_uid::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_uid::text,'role','authenticated')::text,true);

  BEGIN
    UPDATE public.shipper_users SET shipper_id=v_other_shipper WHERE id=v_user;
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Wrong shipper probe');
    RAISE EXCEPTION '__UNEXPECTED_SUCCESS__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'wrong_shipper_rejected',
      v_err ILIKE '%does not belong to this shipper%',
      jsonb_build_object('error',v_err,'controlled_user_reassignment_rolled_back',true)
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 9. MUTABLE PROGRESSED ADJUSTMENT HOUSEKEEPING
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid := pg_temp.shipment_undo_clean_legacy_batch();
  v_alloc record; v_basis uuid; v_staff uuid; v_operator uuid;
  v_old_id uuid; v_terminal_id uuid;
  v_old_qty numeric; v_old_base numeric; v_old_discount numeric; v_old_delivery numeric; v_old_chargeable numeric;
  v_old record; v_new record; v_terminal record;
  v_pass boolean:=false; v_err text;
BEGIN
  IF v_batch IS NULL THEN
    INSERT INTO shipment_undo_remaining_results VALUES('mutable_progressed_adjustment_housekeeping',false,jsonb_build_object('reason','No base batch.'));
    RETURN;
  END IF;

  SELECT a.id,a.order_id,a.tracking_submission_id,a.supplier_invoice_line_id,
         sil.supplier_invoice_id,a.qty_allocated,a.base_value_gbp,
         a.discount_share_gbp,a.retailer_delivery_share_gbp,a.adjusted_net_value_gbp
    INTO v_alloc
  FROM public.shipper_shipment_batch_effective_lines_v1(v_batch) e
  JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines sil ON sil.id=a.supplier_invoice_line_id
  WHERE NOT EXISTS(
    SELECT 1 FROM public.invoice_adjustment_consumption_ledger l
    WHERE l.source_allocation_id=a.id AND l.active=true AND l.outcome='progressed_allocated'
  )
  ORDER BY a.id LIMIT 1;

  SELECT s.id INTO v_staff FROM public.staff s WHERE s.active=true ORDER BY s.created_at,s.id LIMIT 1;
  SELECT o.id INTO v_operator FROM public.operators o WHERE o.active=true ORDER BY o.created_at,o.id LIMIT 1;

  IF v_alloc.id IS NULL OR (v_staff IS NULL AND v_operator IS NULL) THEN
    INSERT INTO shipment_undo_remaining_results VALUES(
      'mutable_progressed_adjustment_housekeeping',false,
      jsonb_build_object('reason','No suitable allocation or actor for rollback-only adjustment fixture.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_set_auth(v_batch);

  BEGIN
    SELECT b.id INTO v_basis
    FROM public.invoice_adjustment_basis b
    WHERE b.supplier_invoice_id=v_alloc.supplier_invoice_id
    LIMIT 1;

    IF v_basis IS NULL THEN
      INSERT INTO public.invoice_adjustment_basis(
        supplier_invoice_id,order_id,locked_goods_total_gbp,
        locked_discount_total_gbp,locked_delivery_total_gbp,
        locked_by_staff_id,locked_by_operator_id,notes
      ) VALUES(
        v_alloc.supplier_invoice_id,v_alloc.order_id,
        GREATEST(COALESCE(v_alloc.base_value_gbp,0),0),
        GREATEST(COALESCE(v_alloc.discount_share_gbp,0),0),
        GREATEST(COALESCE(v_alloc.retailer_delivery_share_gbp,0),0),
        v_staff,CASE WHEN v_staff IS NULL THEN v_operator ELSE NULL END,
        'Rollback-only Shipment Undo adjustment basis'
      ) RETURNING id INTO v_basis;
    END IF;

    v_old_qty:=GREATEST(COALESCE(v_alloc.qty_allocated,0.001),0.001);
    v_old_base:=GREATEST(COALESCE(v_alloc.base_value_gbp,0),0);
    v_old_discount:=GREATEST(COALESCE(v_alloc.discount_share_gbp,0),0);
    v_old_delivery:=GREATEST(COALESCE(v_alloc.retailer_delivery_share_gbp,0),0);
    v_old_chargeable:=GREATEST(COALESCE(v_alloc.adjusted_net_value_gbp,0),0);

    INSERT INTO public.invoice_adjustment_consumption_ledger(
      invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,
      qty_consumed,base_value_consumed_gbp,discount_consumed_gbp,
      delivery_consumed_gbp,chargeable_adjusted_goods_basis_gbp,
      outcome,reason,active,created_by_staff_id,created_by_operator_id
    ) VALUES(
      v_basis,v_alloc.supplier_invoice_id,v_alloc.supplier_invoice_line_id,
      v_alloc.id,v_alloc.tracking_submission_id,v_batch,
      v_old_qty,v_old_base,v_old_discount,v_old_delivery,v_old_chargeable,
      'progressed_allocated','Rollback-only mutable progressed row',true,
      v_staff,CASE WHEN v_staff IS NULL THEN v_operator ELSE NULL END
    ) RETURNING id INTO v_old_id;

    INSERT INTO public.invoice_adjustment_consumption_ledger(
      invoice_adjustment_basis_id,supplier_invoice_id,supplier_invoice_line_id,
      source_allocation_id,tracking_submission_id,shipment_batch_id,
      qty_consumed,base_value_consumed_gbp,discount_consumed_gbp,
      delivery_consumed_gbp,chargeable_adjusted_goods_basis_gbp,
      outcome,reason,active,created_by_staff_id,created_by_operator_id
    ) VALUES(
      v_basis,v_alloc.supplier_invoice_id,v_alloc.supplier_invoice_line_id,
      NULL,v_alloc.tracking_submission_id,v_batch,
      0.001,0.01,0,0,0.01,
      'shipped_charged','Rollback-only terminal row',true,
      v_staff,CASE WHEN v_staff IS NULL THEN v_operator ELSE NULL END
    ) RETURNING id INTO v_terminal_id;

    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Mutable adjustment housekeeping');

    SELECT l.active,l.outcome,l.superseded_at INTO v_old
    FROM public.invoice_adjustment_consumption_ledger l WHERE l.id=v_old_id;

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
    FROM public.invoice_adjustment_consumption_ledger l WHERE l.id=v_terminal_id;

    v_pass:=
      v_old.active=false AND v_old.outcome='superseded' AND v_old.superseded_at IS NOT NULL
      AND v_new.id IS NOT NULL AND v_new.shipment_batch_id IS NULL
      AND v_new.qty_consumed=v_old_qty
      AND v_new.base_value_consumed_gbp=v_old_base
      AND v_new.discount_consumed_gbp=v_old_discount
      AND v_new.delivery_consumed_gbp=v_old_delivery
      AND v_new.chargeable_adjusted_goods_basis_gbp=v_old_chargeable
      AND v_terminal.active=true AND v_terminal.outcome='shipped_charged'
      AND v_terminal.shipment_batch_id=v_batch;

    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'mutable_progressed_adjustment_housekeeping',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object(
        'old_progressed_superseded',COALESCE(v_old.active=false AND v_old.outcome='superseded',false),
        'rebuilt_batch_reference_cleared',v_new.id IS NOT NULL AND v_new.shipment_batch_id IS NULL,
        'financial_values_preserved',v_new.id IS NOT NULL
          AND v_new.qty_consumed=v_old_qty
          AND v_new.base_value_consumed_gbp=v_old_base
          AND v_new.discount_consumed_gbp=v_old_discount
          AND v_new.delivery_consumed_gbp=v_old_delivery
          AND v_new.chargeable_adjusted_goods_basis_gbp=v_old_chargeable,
        'terminal_row_untouched',COALESCE(v_terminal.active=true AND v_terminal.outcome='shipped_charged' AND v_terminal.shipment_batch_id=v_batch,false),
        'rolled_back',v_err='__ROLLBACK_TEST__',
        'error',CASE WHEN v_err<>'__ROLLBACK_TEST__' THEN v_err ELSE NULL END
      )
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 10. INACTIVE GROUPAGE HISTORY DOES NOT BLOCK — GROUPAGE READ ONLY
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid; v_pass boolean:=false; v_err text; v_def text;
BEGIN
  SELECT b.id INTO v_batch
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS(SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=false)
    AND NOT EXISTS(SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=true)
    AND EXISTS(SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true)
    AND NOT EXISTS(SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true)
    AND NOT EXISTS(SELECT 1 FROM public.shipping_cost_allocations c WHERE c.shipment_batch_id=b.id AND c.active=true AND c.allocation_status='approved')
    AND NOT EXISTS(SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active')
    AND NOT EXISTS(SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id)
    AND NOT EXISTS(
      SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id
      AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
    )
    AND NOT EXISTS(
      SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
      JOIN public.order_tracking_line_allocations a ON a.id=e.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
    )
  ORDER BY b.created_at DESC,b.id LIMIT 1;

  IF v_batch IS NULL THEN
    SELECT pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure) INTO v_def;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'inactive_groupage_history_nonblocking',
      v_def ILIKE '%shipper_groupage_movement_batches%'
        AND v_def ILIKE '%gmb.active = true%',
      jsonb_build_object('coverage_mode','structural_fallback_no_safe_real_fixture','groupage_mutated',false)
    );
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Inactive Groupage history nonblock');
    v_pass:=EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'inactive_groupage_history_nonblocking',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('coverage_mode','real_read_only_fixture','undo_succeeded',v_pass,'groupage_mutated',false,'rolled_back',v_err='__ROLLBACK_TEST__')
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 11. REVERSED CUSTOMER RELEASE HISTORY DOES NOT BLOCK
--     Prefer real history. If none exists, structurally verify that both Undo
--     release checks are explicitly limited to release_status='active'.
-- -----------------------------------------------------------------------------
DO $test$
DECLARE
  v_batch uuid; v_pass boolean:=false; v_err text; v_def text;
BEGIN
  SELECT b.id INTO v_batch
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS(SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='reversed')
    AND NOT EXISTS(SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active')
    AND NOT EXISTS(SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=true)
    AND EXISTS(SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true)
    AND NOT EXISTS(SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true)
    AND NOT EXISTS(SELECT 1 FROM public.shipping_cost_allocations c WHERE c.shipment_batch_id=b.id AND c.active=true AND c.allocation_status='approved')
    AND NOT EXISTS(SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id)
    AND NOT EXISTS(
      SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id
      AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
    )
  ORDER BY b.created_at DESC,b.id LIMIT 1;

  IF v_batch IS NULL THEN
    SELECT pg_get_functiondef('public.shipper_undo_shipment_batch_v1(uuid,text)'::regprocedure) INTO v_def;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'reversed_customer_release_history_nonblocking',
      v_def ILIKE '%source_shipment_batch_id = p_shipment_batch_id%'
        AND v_def ILIKE '%release_status = ''active''%'
        AND v_def NOT ILIKE '%release_status = ''reversed''%',
      jsonb_build_object('coverage_mode','structural_fallback_no_real_reversed_fixture')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.shipment_undo_set_auth(v_batch);
  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch,'Reversed release history nonblock');
    v_pass:=EXISTS(SELECT 1 FROM public.shipper_shipment_batches b WHERE b.id=v_batch AND b.status='voided');
    RAISE EXCEPTION '__ROLLBACK_TEST__';
  EXCEPTION WHEN OTHERS THEN
    v_err:=SQLERRM;
    INSERT INTO shipment_undo_remaining_results VALUES(
      'reversed_customer_release_history_nonblocking',
      v_pass AND v_err='__ROLLBACK_TEST__',
      jsonb_build_object('coverage_mode','real_fixture','undo_succeeded',v_pass,'rolled_back',v_err='__ROLLBACK_TEST__')
    );
  END;
END
$test$;

-- -----------------------------------------------------------------------------
-- 12. PROTECTED AUTHORITIES STILL EXACTLY MATCH PRE-BUILD BASELINE
-- -----------------------------------------------------------------------------
INSERT INTO shipment_undo_remaining_results(test_name,passed,detail)
SELECT
  'protected_authorities_still_unchanged',
  bool_and(live_md5=expected_md5),
  jsonb_build_object('comparisons',jsonb_agg(jsonb_build_object('signature',signature,'expected_md5',expected_md5,'live_md5',live_md5,'matches',live_md5=expected_md5) ORDER BY signature))
FROM (
  SELECT x.signature,x.expected_md5,md5(pg_get_functiondef(to_regprocedure(x.signature))) AS live_md5
  FROM (VALUES
    ('public.shipper_create_groupage_movement_v1(uuid[],text,uuid)','8691cf78f34912d9522f545ebb495529'),
    ('public.internal_review_final_export_evidence_document_v1(uuid,text,text)','87c619fbd1bcea84f90718dc538bf6ef'),
    ('public.groupage_recompute_movement_status_v1(uuid)','e78cc0c67e422a88afbae815bc600a0b'),
    ('public.shipper_block_shipment_line_membership_mutation_v1()','c56d6a1a2b2c1bf0ef751a07e3b33ff2')
  ) x(signature,expected_md5)
) q;

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_remaining_regression_v2',
  'transaction_wrapped',true,
  'will_rollback',true,
  'groupage_mutation_performed',false,
  'trigger_disabling_performed',false,
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'failed_tests',COALESCE(jsonb_agg(test_name ORDER BY test_name) FILTER(WHERE NOT passed),'[]'::jsonb),
  'tests',jsonb_agg(jsonb_build_object('test',test_name,'passed',passed,'detail',detail) ORDER BY test_name)
)) AS result
FROM shipment_undo_remaining_results;

ROLLBACK;
