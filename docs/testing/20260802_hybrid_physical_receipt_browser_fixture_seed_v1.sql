\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- Required psql variables:
-- RUN_ID EXPECTED_DATABASE TEMPLATE_REVIEW_ID
-- IMPORTER_A_AUTH_USER_ID IMPORTER_B_AUTH_USER_ID SUPERVISOR_AUTH_USER_ID ORDINARY_STAFF_AUTH_USER_ID

DO $guard$
BEGIN
  IF current_setting('app.environment', true) IS DISTINCT FROM 'acceptance' THEN
    RAISE EXCEPTION 'Browser fixture provisioning is acceptance-only.';
  END IF;
  IF current_database() IS DISTINCT FROM :'EXPECTED_DATABASE' THEN
    RAISE EXCEPTION 'Acceptance database identity mismatch: expected %, got %.', :'EXPECTED_DATABASE', current_database();
  END IF;
  IF :'RUN_ID' !~ '^[0-9a-f-]{36}$' THEN
    RAISE EXCEPTION 'RUN_ID must be a UUID.';
  END IF;
END
$guard$;

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.clone_row(
  p_table regclass,
  p_source jsonb,
  p_overrides jsonb,
  p_exclude text[] DEFAULT ARRAY[]::text[]
) RETURNS uuid
LANGUAGE plpgsql
AS $function$
DECLARE
  v_columns text;
  v_values text;
  v_id uuid;
BEGIN
  SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum),
         string_agg(format('(jsonb_populate_record(NULL::%s, $1)).%I', p_table, a.attname), ', ' ORDER BY a.attnum)
  INTO v_columns, v_values
  FROM pg_attribute a
  WHERE a.attrelid = p_table
    AND a.attnum > 0
    AND NOT a.attisdropped
    AND a.attidentity = ''
    AND a.attgenerated = ''
    AND a.attname <> ALL(COALESCE(p_exclude, ARRAY[]::text[]));

  EXECUTE format('INSERT INTO %s (%s) SELECT %s RETURNING id', p_table, v_columns, v_values)
  USING p_source || p_overrides
  INTO v_id;
  RETURN v_id;
END
$function$;

DO $seed$
DECLARE
  v_marker text := 'physical-receipt-browser:' || :'RUN_ID';
  v_template_review public.physical_receipt_reviews%ROWTYPE;
  v_template_order public.orders%ROWTYPE;
  v_template_tracking public.order_tracking_submissions%ROWTYPE;
  v_template_receipt public.shipper_package_receipts%ROWTYPE;
  v_template_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_template_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_template_line public.supplier_invoice_lines%ROWTYPE;
  v_template_invoice public.supplier_invoices%ROWTYPE;
  v_importer_a_operator_id uuid;
  v_importer_b_operator_id uuid;
  v_supervisor_id uuid;
  v_ordinary_staff_id uuid;
  v_order_id uuid := gen_random_uuid();
  v_invoice_id uuid := gen_random_uuid();
  v_line_id uuid := gen_random_uuid();
  v_tracking_id uuid := gen_random_uuid();
  v_allocation_id uuid := gen_random_uuid();
  v_receipt_id uuid := gen_random_uuid();
  v_disposition_id uuid := gen_random_uuid();
  v_evidence_id uuid := gen_random_uuid();
  v_review_id uuid := gen_random_uuid();
  v_storage_path text;
  v_filename text;
BEGIN
  SELECT * INTO STRICT v_template_review
  FROM public.physical_receipt_reviews
  WHERE id = :'TEMPLATE_REVIEW_ID'::uuid;

  SELECT * INTO STRICT v_template_order FROM public.orders WHERE id=v_template_review.order_id;
  SELECT * INTO STRICT v_template_tracking FROM public.order_tracking_submissions WHERE id=v_template_review.tracking_submission_id;
  SELECT * INTO STRICT v_template_receipt FROM public.shipper_package_receipts WHERE id=v_template_review.receipt_id;

  SELECT d.* INTO STRICT v_template_disposition
  FROM public.shipper_package_receipt_line_dispositions d
  WHERE d.receipt_id=v_template_review.receipt_id
    AND d.disposition_type<>'clean'
    AND d.quantity>=2
  ORDER BY d.created_at, d.id
  LIMIT 1;

  SELECT * INTO STRICT v_template_allocation
  FROM public.order_tracking_line_allocations
  WHERE id=v_template_disposition.tracking_line_allocation_id;

  SELECT * INTO STRICT v_template_line
  FROM public.supplier_invoice_lines
  WHERE id=v_template_disposition.supplier_invoice_line_id;

  SELECT * INTO STRICT v_template_invoice
  FROM public.supplier_invoices
  WHERE id=v_template_line.supplier_invoice_id;

  SELECT op.id INTO STRICT v_importer_a_operator_id
  FROM public.operators op
  JOIN public.operator_importers oi ON oi.operator_id=op.id
  WHERE op.auth_user_id=:'IMPORTER_A_AUTH_USER_ID'::uuid
    AND COALESCE(op.active,true)=true
    AND oi.importer_id=v_template_review.importer_id
    AND oi.revoked_at IS NULL;

  SELECT op.id INTO STRICT v_importer_b_operator_id
  FROM public.operators op
  JOIN public.operator_importers oi ON oi.operator_id=op.id
  WHERE op.auth_user_id=:'IMPORTER_B_AUTH_USER_ID'::uuid
    AND COALESCE(op.active,true)=true
    AND oi.importer_id<>v_template_review.importer_id
    AND oi.revoked_at IS NULL
  LIMIT 1;

  SELECT id INTO STRICT v_supervisor_id FROM public.staff
  WHERE auth_user_id=:'SUPERVISOR_AUTH_USER_ID'::uuid
    AND COALESCE(active,true)=true
    AND role_type IN ('admin','supervisor');

  SELECT id INTO STRICT v_ordinary_staff_id FROM public.staff
  WHERE auth_user_id=:'ORDINARY_STAFF_AUTH_USER_ID'::uuid
    AND COALESCE(active,true)=true
    AND role_type NOT IN ('admin','supervisor');

  PERFORM pg_temp.clone_row(
    'public.orders', to_jsonb(v_template_order),
    jsonb_build_object('id',v_order_id,'order_ref','PW-PHYSICAL-'||:'RUN_ID','created_at',now(),'updated_at',now()),
    ARRAY[]::text[]
  );

  PERFORM pg_temp.clone_row(
    'public.supplier_invoices', to_jsonb(v_template_invoice),
    jsonb_build_object(
      'id',v_invoice_id,'order_id',v_order_id,
      'invoice_number','PW-PHYSICAL-'||:'RUN_ID',
      'supplier_invoice_number','PW-PHYSICAL-'||:'RUN_ID',
      'created_at',now(),'updated_at',now()
    ), ARRAY[]::text[]
  );

  PERFORM pg_temp.clone_row(
    'public.supplier_invoice_lines', to_jsonb(v_template_line),
    jsonb_build_object('id',v_line_id,'supplier_invoice_id',v_invoice_id,'quantity',2,'description',v_marker,'created_at',now(),'updated_at',now()),
    ARRAY[]::text[]
  );

  PERFORM pg_temp.clone_row(
    'public.order_tracking_submissions', to_jsonb(v_template_tracking),
    jsonb_build_object('id',v_tracking_id,'order_id',v_order_id,'tracking_ref','PWTRK-'||:'RUN_ID','superseded_at',NULL,'created_at',now(),'updated_at',now()),
    ARRAY[]::text[]
  );

  PERFORM pg_temp.clone_row(
    'public.order_tracking_line_allocations', to_jsonb(v_template_allocation),
    jsonb_build_object(
      'id',v_allocation_id,'order_id',v_order_id,'supplier_invoice_line_id',v_line_id,
      'tracking_submission_id',v_tracking_id,'qty_allocated',2,'notes',v_marker,
      'locked_for_export_pack_at',NULL,'created_at',now(),'updated_at',now()
    ), ARRAY[]::text[]
  );

  PERFORM pg_temp.clone_row(
    'public.shipper_package_receipts', to_jsonb(v_template_receipt),
    jsonb_build_object(
      'id',v_receipt_id,'order_id',v_order_id,'tracking_submission_id',v_tracking_id,
      'receipt_submission_id',gen_random_uuid(),'payload_fingerprint',md5(v_marker),
      'receipt_model_version',2,'receipt_state','finalised','finalised_at',now(),
      'correction_of_receipt_id',NULL,'correction_reason',NULL,'created_at',now(),'updated_at',now()
    ), ARRAY[]::text[]
  );

  INSERT INTO public.shipper_package_receipt_line_dispositions(
    id,receipt_id,tracking_submission_id,tracking_line_allocation_id,supplier_invoice_line_id,
    disposition_type,quantity,condition_note,created_at
  ) VALUES (
    v_disposition_id,v_receipt_id,v_tracking_id,v_allocation_id,v_line_id,
    'damaged',2,v_marker,now()
  );

  v_filename := 'physical-receipt-browser-' || :'RUN_ID' || '.png';
  v_storage_path := 'shipper-receipts/' || v_template_order.shipper_id::text || '/' || v_tracking_id::text || '/' || v_filename;

  INSERT INTO public.shipper_package_receipt_evidence(
    id,receipt_id,line_disposition_id,storage_object_path,original_filename,content_type,
    display_order,uploaded_by_shipper_user_id,created_at
  ) VALUES (
    v_evidence_id,v_receipt_id,v_disposition_id,v_storage_path,v_filename,'image/png',0,
    v_template_receipt.shipper_user_id,now()
  );

  INSERT INTO public.physical_receipt_reviews(
    id,receipt_id,order_id,importer_id,tracking_submission_id,source_stage,status,
    importer_proposed_by_operator_id,importer_proposed_at,supervisor_decided_by_staff_id,
    supervisor_decided_at,approved_liable_party,decision_note,linked_dispute_id,
    superseded_by_receipt_id,importer_proposal_note,created_at,updated_at
  ) VALUES (
    v_review_id,v_receipt_id,v_order_id,v_template_review.importer_id,v_tracking_id,
    'at_shipper_receipt','awaiting_importer_proposal',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,now(),now()
  );

  IF (SELECT count(*) FROM public.physical_exception_remedy_allocations WHERE physical_receipt_review_id=v_review_id)<>0
     OR (SELECT count(*) FROM public.physical_receipt_review_dispute_links WHERE physical_receipt_review_id=v_review_id)<>0
     OR (SELECT sum(quantity) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id AND disposition_type<>'clean')<>2
     OR (SELECT count(*) FROM public.shipper_package_receipt_evidence WHERE receipt_id=v_receipt_id)<>1
  THEN
    RAISE EXCEPTION 'Disposable browser fixture does not match its required starting state.';
  END IF;

  RAISE NOTICE 'fixture identities validated: importer_a=%, importer_b=%, supervisor=%, ordinary_staff=%',
    v_importer_a_operator_id,v_importer_b_operator_id,v_supervisor_id,v_ordinary_staff_id;

  PERFORM set_config('app.browser_fixture_manifest', jsonb_build_object(
    'run_id',:'RUN_ID','marker',v_marker,'review_id',v_review_id,'order_id',v_order_id,
    'tracking_submission_id',v_tracking_id,'receipt_id',v_receipt_id,'disposition_id',v_disposition_id,
    'allocation_id',v_allocation_id,'supplier_invoice_id',v_invoice_id,'supplier_invoice_line_id',v_line_id,
    'evidence_id',v_evidence_id,'evidence_filename',v_filename,'storage_object_path',v_storage_path
  )::text, true);
END
$seed$;

SELECT current_setting('app.browser_fixture_manifest');
COMMIT;
