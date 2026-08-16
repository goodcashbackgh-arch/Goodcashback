-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — BEHAVIOURAL REGRESSION
-- Authority:
-- docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md
--
-- TRANSACTION WRAPPED. Ends with ROLLBACK.
-- Uses existing fixtures only. Never creates, updates, cancels, excludes or
-- otherwise mutates Groupage state. Groupage is read only throughout.
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
SELECT p.oid::regprocedure::text AS signature,
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
  );

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
    ON su.shipper_id=b.shipper_id
   AND su.active=true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id=p_batch_id
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No active shipper auth user for batch %', p_batch_id;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_uid::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_uid::text,'role','authenticated')::text,true);
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
      p_test_name,false,jsonb_build_object('reason','No existing fixture available.')
    );
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(p_batch_id);

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(p_batch_id,'Regression blocker probe — rolled back');
    INSERT INTO shipment_undo_regression_results VALUES (
      p_test_name,false,jsonb_build_object('shipment_batch_id',p_batch_id,'reason','Undo unexpectedly succeeded.')
    );
  EXCEPTION WHEN OTHERS THEN
    v_error:=SQLERRM;
    INSERT INTO shipment_undo_regression_results VALUES (
      p_test_name,
      v_error ILIKE '%'||p_expected_error||'%',
      jsonb_build_object('shipment_batch_id',p_batch_id,'error',v_error)
    );
  END;
END;
$$;

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
BEGIN
  SELECT b.id INTO v_batch_id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true)
    AND EXISTS (SELECT 1 FROM public.shipper_shipment_batch_line_memberships m WHERE m.shipment_batch_id=b.id AND m.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_cost_allocations a WHERE a.shipment_batch_id=b.id AND a.active=true AND a.allocation_status='approved')
    AND NOT EXISTS (SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active')
    AND NOT EXISTS (SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided')))
    AND NOT EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id)
    AND NOT EXISTS (
      SELECT 1
      FROM public.shipper_shipment_batch_effective_lines_v1(b.id) l
      JOIN public.order_tracking_line_allocations a ON a.id=l.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
    )
  ORDER BY b.created_at,b.id
  LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('clean_exact_undo',false,jsonb_build_object('reason','No existing clean exact fixture available.'));
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);

  SELECT COUNT(*) INTO v_package_rows_before FROM public.shipper_shipment_batch_packages WHERE shipment_batch_id=v_batch_id;
  SELECT COUNT(*) INTO v_line_rows_before FROM public.shipper_shipment_batch_line_memberships WHERE shipment_batch_id=v_batch_id;
  SELECT md5(COALESCE(string_agg(concat_ws('|',id,shipment_batch_id,shipment_batch_package_id,tracking_submission_id,tracking_line_allocation_id,order_id,supplier_invoice_line_id,qty_in_shipment,adjusted_net_value_gbp),',' ORDER BY id),''))
    INTO v_line_fingerprint_before
  FROM public.shipper_shipment_batch_line_memberships WHERE shipment_batch_id=v_batch_id;

  PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Regression clean exact Undo — rolled back');

  SELECT status,voided_at,voided_by_shipper_user_id,void_reason
    INTO v_status,v_voided_at,v_voided_by,v_void_reason
  FROM public.shipper_shipment_batches WHERE id=v_batch_id;
  SELECT COUNT(*) INTO v_package_rows_after FROM public.shipper_shipment_batch_packages WHERE shipment_batch_id=v_batch_id;
  SELECT COUNT(*) INTO v_line_rows_after FROM public.shipper_shipment_batch_line_memberships WHERE shipment_batch_id=v_batch_id;
  SELECT md5(COALESCE(string_agg(concat_ws('|',id,shipment_batch_id,shipment_batch_package_id,tracking_submission_id,tracking_line_allocation_id,order_id,supplier_invoice_line_id,qty_in_shipment,adjusted_net_value_gbp),',' ORDER BY id),''))
    INTO v_line_fingerprint_after
  FROM public.shipper_shipment_batch_line_memberships WHERE shipment_batch_id=v_batch_id;
  SELECT COUNT(*) INTO v_effective_after FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);
  SELECT COUNT(*) INTO v_candidates_after
  FROM public.shipper_shipment_batch_candidates_v2() c
  WHERE c.tracking_submission_id IN (SELECT p.tracking_submission_id FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id);

  INSERT INTO shipment_undo_regression_results VALUES (
    'clean_exact_undo',
    v_status='voided'
      AND v_voided_at IS NOT NULL
      AND v_voided_by IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(v_void_reason,'')),'') IS NOT NULL
      AND v_package_rows_before=v_package_rows_after
      AND v_line_rows_before=v_line_rows_after
      AND v_line_fingerprint_before=v_line_fingerprint_after
      AND NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id AND p.active=true)
      AND NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_line_memberships m WHERE m.shipment_batch_id=v_batch_id AND m.active=true)
      AND NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id AND (p.removed_at IS NULL OR p.removed_by_shipper_user_id IS NULL OR NULLIF(BTRIM(COALESCE(p.remove_reason,'')),'') IS NULL))
      AND v_effective_after=0,
    jsonb_build_object(
      'shipment_batch_id',v_batch_id,
      'package_rows_preserved',v_package_rows_before=v_package_rows_after,
      'line_rows_preserved',v_line_rows_before=v_line_rows_after,
      'immutable_line_values_preserved',v_line_fingerprint_before=v_line_fingerprint_after,
      'effective_lines_after',v_effective_after,
      'released_tracking_candidates_after',v_candidates_after
    )
  );

  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Regression repeat Undo');
    INSERT INTO shipment_undo_regression_results VALUES ('repeat_undo_rejected',false,'{}');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO shipment_undo_regression_results VALUES ('repeat_undo_rejected',SQLERRM ILIKE '%can no longer be undone%',jsonb_build_object('error',SQLERRM));
  END;
END
$clean_exact$;

DO $clean_legacy$
DECLARE
  v_batch_id uuid;
  v_package_rows_before integer;
  v_package_rows_after integer;
  v_effective_after integer;
  v_status text;
BEGIN
  SELECT b.id INTO v_batch_id
  FROM public.shipper_shipment_batches b
  WHERE b.status='created'
    AND EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=b.id AND p.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_line_memberships m WHERE m.shipment_batch_id=b.id)
    AND NOT EXISTS (SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true)
    AND NOT EXISTS (SELECT 1 FROM public.shipping_cost_allocations a WHERE a.shipment_batch_id=b.id AND a.active=true AND a.allocation_status='approved')
    AND NOT EXISTS (SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active')
    AND NOT EXISTS (SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided')))
    AND NOT EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) l
      JOIN public.order_tracking_line_allocations a ON a.id=l.tracking_line_allocation_id
      WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
    )
  ORDER BY b.created_at,b.id LIMIT 1;

  IF v_batch_id IS NULL THEN
    INSERT INTO shipment_undo_regression_results VALUES ('clean_legacy_undo',false,jsonb_build_object('reason','No existing clean legacy fixture available.'));
    RETURN;
  END IF;

  PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
  SELECT COUNT(*) INTO v_package_rows_before FROM public.shipper_shipment_batch_packages WHERE shipment_batch_id=v_batch_id;
  PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'Regression clean legacy Undo — rolled back');
  SELECT COUNT(*) INTO v_package_rows_after FROM public.shipper_shipment_batch_packages WHERE shipment_batch_id=v_batch_id;
  SELECT COUNT(*) INTO v_effective_after FROM public.shipper_shipment_batch_effective_lines_v1(v_batch_id);
  SELECT status INTO v_status FROM public.shipper_shipment_batches WHERE id=v_batch_id;

  INSERT INTO shipment_undo_regression_results VALUES (
    'clean_legacy_undo',
    v_status='voided'
      AND v_package_rows_before=v_package_rows_after
      AND NOT EXISTS (SELECT 1 FROM public.shipper_shipment_batch_packages p WHERE p.shipment_batch_id=v_batch_id AND p.active=true)
      AND v_effective_after=0,
    jsonb_build_object('shipment_batch_id',v_batch_id,'package_rows_preserved',v_package_rows_before=v_package_rows_after,'effective_lines_after',v_effective_after)
  );
END
$clean_legacy$;

DO $input_checks$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' ORDER BY b.created_at DESC LIMIT 1;

  IF v_batch_id IS NOT NULL THEN
    PERFORM pg_temp.set_shipper_auth_for_batch(v_batch_id);
    BEGIN
      PERFORM public.shipper_undo_shipment_batch_v1(v_batch_id,'   ');
      INSERT INTO shipment_undo_regression_results VALUES ('blank_reason_rejected',false,'{}');
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO shipment_undo_regression_results VALUES ('blank_reason_rejected',SQLERRM ILIKE '%Undo reason is required%',jsonb_build_object('error',SQLERRM));
    END;
  END IF;

  PERFORM set_config('request.jwt.claim.sub','',true);
  PERFORM set_config('request.jwt.claims','{}',true);
  BEGIN
    PERFORM public.shipper_undo_shipment_batch_v1(COALESCE(v_batch_id,gen_random_uuid()),'Unauthenticated probe');
    INSERT INTO shipment_undo_regression_results VALUES ('unauthenticated_rejected',false,'{}');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO shipment_undo_regression_results VALUES ('unauthenticated_rejected',SQLERRM ILIKE '%Unauthenticated user%',jsonb_build_object('error',SQLERRM));
  END;
END
$input_checks$;

DO $blockers$
DECLARE
  v_batch_id uuid;
BEGIN
  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.shipper_groupage_movement_batches g WHERE g.shipment_batch_id=b.id AND g.active=true) ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_groupage_blocks',v_batch_id,'active Groupage Movement');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.shipping_documents d WHERE d.shipment_batch_id=b.id AND d.active=true) ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_shipping_document_blocks',v_batch_id,'active shipping document');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.shipping_cost_allocations a WHERE a.shipment_batch_id=b.id AND a.active=true AND a.allocation_status='approved') ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_approved_shipping_cost_blocks',v_batch_id,'active approved shipping-cost allocation');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (
    SELECT 1 FROM public.shipper_shipment_batch_effective_lines_v1(b.id) l
    JOIN public.order_tracking_line_allocations a ON a.id=l.tracking_line_allocation_id
    WHERE a.locked_for_export_pack_at IS NOT NULL OR a.allocation_status='locked_for_export_pack'
  ) ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('export_lock_blocks',v_batch_id,'locked for export');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.customer_sales_release_lines r WHERE r.source_shipment_batch_id=b.id AND r.release_status='active') ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('active_customer_release_blocks',v_batch_id,'active customer-sales release');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (
    SELECT 1 FROM public.sage_posting_snapshots s WHERE s.shipment_batch_id=b.id AND (s.sage_posting_status='posted' OR (COALESCE(s.active,true)=true AND COALESCE(s.sage_posting_status,'not_posted')<>'voided'))
  ) ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('accounting_blocks',v_batch_id,'accounting snapshot');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id AND e.review_status='submitted_for_review') ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('submitted_final_evidence_blocks',v_batch_id,'final export evidence exists');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id AND e.review_status='accepted_current') ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('accepted_final_evidence_blocks',v_batch_id,'final export evidence exists');

  SELECT b.id INTO v_batch_id FROM public.shipper_shipment_batches b WHERE b.status='created' AND EXISTS (SELECT 1 FROM public.shipper_final_export_evidence_documents e WHERE e.shipment_batch_id=b.id AND e.review_status='rejected_resubmit_required') ORDER BY b.created_at DESC LIMIT 1;
  PERFORM pg_temp.assert_undo_blocked('rejected_final_evidence_blocks',v_batch_id,'final export evidence exists');
END
$blockers$;

INSERT INTO shipment_undo_regression_results(test_name,passed,detail)
SELECT
  'protected_authorities_unchanged',
  NOT EXISTS (
    SELECT 1
    FROM shipment_undo_protected_before b
    FULL JOIN (
      SELECT p.oid::regprocedure::text AS signature,
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

SELECT jsonb_pretty(jsonb_build_object(
  'probe','shipment_batch_undo_release_control_regression_v1',
  'transaction_wrapped',true,
  'will_rollback',true,
  'result',CASE WHEN bool_and(passed) THEN 'PASS' ELSE 'FAIL' END,
  'tests',jsonb_agg(jsonb_build_object('test',test_name,'passed',passed,'detail',detail) ORDER BY test_name)
)) AS result
FROM shipment_undo_regression_results;

ROLLBACK;
