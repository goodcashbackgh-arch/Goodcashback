-- Persistent five-line browser fixture for grouped physical receipt outcomes.
-- Built from the live-schema probe output only.
--
-- A clean
-- B missing  -> replacement in importer UI
-- C damaged  -> replacement in importer UI
-- D missing  -> refund in importer UI
-- E wrong    -> refund in importer UI
--
-- Stops at physical_receipt_reviews.status='awaiting_importer_proposal'.
-- Creates no dispute, remedy, outcome lane, credit, same-order route, or child order.
-- Any error rolls back the complete transaction.

BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.clone_row(
  p_table regclass,
  p_source jsonb,
  p_overrides jsonb
) RETURNS uuid
LANGUAGE plpgsql
AS $function$
DECLARE
  v_columns text;
  v_values text;
  v_id uuid;
BEGIN
  SELECT
    string_agg(format('%I',a.attname),', ' ORDER BY a.attnum),
    string_agg(format('(jsonb_populate_record(NULL::%s,$1)).%I',p_table,a.attname),', ' ORDER BY a.attnum)
  INTO v_columns,v_values
  FROM pg_attribute a
  WHERE a.attrelid=p_table
    AND a.attnum>0
    AND NOT a.attisdropped
    AND a.attidentity=''
    AND a.attgenerated='';

  EXECUTE format('INSERT INTO %s (%s) SELECT %s RETURNING id',p_table,v_columns,v_values)
  USING p_source||p_overrides
  INTO v_id;

  RETURN v_id;
END
$function$;

DO $seed$
DECLARE
  v_run_id uuid:=gen_random_uuid();
  v_token text:=replace(v_run_id::text,'-','');
  v_marker text:='grouped-outcome-browser:'||v_run_id::text;

  v_template_review public.physical_receipt_reviews%ROWTYPE;
  v_template_order public.orders%ROWTYPE;
  v_template_invoice public.supplier_invoices%ROWTYPE;
  v_template_line public.supplier_invoice_lines%ROWTYPE;
  v_template_tracking public.order_tracking_submissions%ROWTYPE;
  v_template_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_template_receipt public.shipper_package_receipts%ROWTYPE;
  v_template_evidence public.shipper_package_receipt_evidence%ROWTYPE;
  v_template_storage storage.objects%ROWTYPE;

  v_order_id uuid:=gen_random_uuid();
  v_invoice_id uuid:=gen_random_uuid();
  v_tracking_id uuid:=gen_random_uuid();
  v_receipt_id uuid:=gen_random_uuid();
  v_receipt_submission_id uuid:=gen_random_uuid();
  v_review_id uuid:=gen_random_uuid();

  v_line_id uuid;
  v_allocation_id uuid;
  v_disposition_id uuid;
  v_evidence_id uuid;
  v_storage_id uuid;
  v_code text;
  v_disposition text;
  v_storage_path text;
  v_filename text;
  v_line_manifest jsonb:='{}'::jsonb;
BEGIN
  SELECT r.* INTO STRICT v_template_review
  FROM public.physical_receipt_reviews r
  WHERE r.id='1987393f-47ba-4460-96f6-598e0e52792d'::uuid;

  SELECT o.* INTO STRICT v_template_order
  FROM public.orders o
  WHERE o.id=v_template_review.order_id
    AND o.order_type='original'
    AND o.parent_order_id IS NULL;

  SELECT si.* INTO STRICT v_template_invoice
  FROM public.supplier_invoices si
  WHERE si.id='a51707dd-5601-4943-89d3-94b9faedb2ea'::uuid;

  SELECT sil.* INTO STRICT v_template_line
  FROM public.supplier_invoice_lines sil
  WHERE sil.id='0985538e-e9bb-42f2-8e3c-8cf11063705e'::uuid;

  SELECT t.* INTO STRICT v_template_tracking
  FROM public.order_tracking_submissions t
  WHERE t.id=v_template_review.tracking_submission_id;

  SELECT a.* INTO STRICT v_template_allocation
  FROM public.order_tracking_line_allocations a
  WHERE a.id='5dbd95c5-c0d0-489d-973d-fab4c9083160'::uuid;

  SELECT p.* INTO STRICT v_template_receipt
  FROM public.shipper_package_receipts p
  WHERE p.id=v_template_review.receipt_id
    AND p.receipt_model_version=2
    AND p.receipt_state='finalised';

  SELECT e.* INTO STRICT v_template_evidence
  FROM public.shipper_package_receipt_evidence e
  WHERE e.id='519c8ab4-3d70-4733-b6f2-0d169ee2beab'::uuid;

  SELECT s.* INTO STRICT v_template_storage
  FROM storage.objects s
  WHERE s.bucket_id='invoice-evidence'
    AND s.name=v_template_evidence.storage_object_path;

  PERFORM pg_temp.clone_row(
    'public.orders',
    to_jsonb(v_template_order),
    jsonb_build_object(
      'id',v_order_id,
      'order_ref','PW-GROUPED-'||v_token,
      'payment_auth_id',NULL,
      'order_type','original',
      'parent_order_id',NULL,
      'replacement_source_dispute_line_id',NULL,
      'total_qty_declared',5,
      'created_at',now(),
      'updated_at',now(),
      'completed_at',NULL
    )
  );

  PERFORM pg_temp.clone_row(
    'public.supplier_invoices',
    to_jsonb(v_template_invoice),
    jsonb_build_object(
      'id',v_invoice_id,
      'order_id',v_order_id,
      'invoice_ref','PW-GROUPED-INV-'||v_token,
      'ocr_invoice_ref','PW-GROUPED-OCR-'||v_token,
      'mindee_job_id','pw-grouped-job-'||v_token,
      'mindee_inference_id','pw-grouped-inference-'||v_token,
      'uploaded_at',now(),
      'ocr_extracted_at',now(),
      'reviewed_at',now(),
      'mindee_completed_at',now(),
      'mindee_result_saved_at',now(),
      'superseded_by_supplier_invoice_id',NULL,
      'is_current_for_order',true
    )
  );

  PERFORM pg_temp.clone_row(
    'public.order_tracking_submissions',
    to_jsonb(v_template_tracking),
    jsonb_build_object(
      'id',v_tracking_id,
      'order_id',v_order_id,
      'tracking_ref','PWGRP-'||substr(v_token,1,20),
      'tracking_date',current_date,
      'submitted_at',now(),
      'superseded_at',NULL,
      'note',v_marker
    )
  );

  PERFORM pg_temp.clone_row(
    'public.shipper_package_receipts',
    to_jsonb(v_template_receipt),
    jsonb_build_object(
      'id',v_receipt_id,
      'tracking_submission_id',v_tracking_id,
      'order_id',v_order_id,
      'receipt_status','held_query',
      'recorded_at',now(),
      'created_at',now(),
      'receipt_model_version',2,
      'receipt_state','pending',
      'receipt_submission_id',v_receipt_submission_id,
      'payload_fingerprint',md5(v_marker),
      'finalised_at',NULL,
      'correction_of_receipt_id',NULL,
      'correction_reason',NULL
    )
  );

  FOREACH v_code IN ARRAY ARRAY['A','B','C','D','E'] LOOP
    v_line_id:=gen_random_uuid();
    v_allocation_id:=gen_random_uuid();
    v_disposition_id:=gen_random_uuid();

    v_disposition:=CASE v_code
      WHEN 'A' THEN 'clean'
      WHEN 'B' THEN 'missing'
      WHEN 'C' THEN 'damaged'
      WHEN 'D' THEN 'missing'
      WHEN 'E' THEN 'wrong'
    END;

    PERFORM pg_temp.clone_row(
      'public.supplier_invoice_lines',
      to_jsonb(v_template_line),
      jsonb_build_object(
        'id',v_line_id,
        'supplier_invoice_id',v_invoice_id,
        'line_order',ascii(v_code)-64,
        'retailer_sku','PW-GROUPED-'||v_code||'-'||substr(v_token,1,8),
        'description',v_marker||':LINE-'||v_code,
        'qty',1,
        'amount_inc_vat_gbp',10,
        'line_source','manually_added',
        'qty_confirmed',1,
        'amount_confirmed',10,
        'eligible_for_invoice_yn','Y',
        'created_at',now(),
        'updated_at',now()
      )
    );

    PERFORM pg_temp.clone_row(
      'public.order_tracking_line_allocations',
      to_jsonb(v_template_allocation),
      jsonb_build_object(
        'id',v_allocation_id,
        'order_id',v_order_id,
        'supplier_invoice_line_id',v_line_id,
        'tracking_submission_id',v_tracking_id,
        'qty_allocated',1,
        'base_value_gbp',10,
        'discount_share_gbp',0,
        'retailer_delivery_share_gbp',0,
        'adjusted_net_value_gbp',10,
        'allocation_status','allocated',
        'allocation_basis','retailer_dispatch_email',
        'notes',v_marker||':LINE-'||v_code,
        'supervisor_accepted_by_staff_id',NULL,
        'supervisor_accepted_at',NULL,
        'locked_for_export_pack_at',NULL,
        'created_at',now(),
        'updated_at',now()
      )
    );

    INSERT INTO public.shipper_package_receipt_line_dispositions(
      id,
      receipt_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      supplier_invoice_line_id,
      disposition_type,
      quantity,
      condition_note,
      created_at
    ) VALUES (
      v_disposition_id,
      v_receipt_id,
      v_tracking_id,
      v_allocation_id,
      v_line_id,
      v_disposition,
      1,
      v_marker||':LINE-'||v_code||':'||v_disposition,
      now()
    );

    IF v_disposition<>'clean' THEN
      v_evidence_id:=gen_random_uuid();
      v_storage_id:=gen_random_uuid();
      v_filename:='grouped-outcome-'||lower(v_code)||'-'||v_token||'.png';
      v_storage_path:='shipper-receipts/'||v_template_order.shipper_id::text||'/'||v_tracking_id::text||'/'||v_receipt_submission_id::text||'/'||v_filename;

      PERFORM pg_temp.clone_row(
        'storage.objects',
        to_jsonb(v_template_storage),
        jsonb_build_object(
          'id',v_storage_id,
          'bucket_id','invoice-evidence',
          'name',v_storage_path,
          'created_at',now(),
          'updated_at',now(),
          'last_accessed_at',now()
        )
      );

      INSERT INTO public.shipper_package_receipt_evidence(
        id,
        receipt_id,
        line_disposition_id,
        storage_object_path,
        original_filename,
        content_type,
        display_order,
        uploaded_by_shipper_user_id,
        created_at
      ) VALUES (
        v_evidence_id,
        v_receipt_id,
        v_disposition_id,
        v_storage_path,
        v_filename,
        'image/png',
        ascii(v_code)-66,
        v_template_receipt.shipper_user_id,
        now()
      );
    END IF;

    v_line_manifest:=v_line_manifest||jsonb_build_object(
      v_code,
      jsonb_build_object(
        'supplier_invoice_line_id',v_line_id,
        'tracking_line_allocation_id',v_allocation_id,
        'receipt_line_disposition_id',v_disposition_id,
        'disposition_type',v_disposition
      )
    );
  END LOOP;

  UPDATE public.shipper_package_receipts
  SET
    receipt_state='finalised',
    receipt_status='received_damaged',
    finalised_at=now()
  WHERE id=v_receipt_id
    AND receipt_state='pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Fixture receipt was not finalised.';
  END IF;

  INSERT INTO public.physical_receipt_reviews(
    id,
    receipt_id,
    order_id,
    importer_id,
    tracking_submission_id,
    source_stage,
    status,
    importer_proposed_by_operator_id,
    importer_proposed_at,
    supervisor_decided_by_staff_id,
    supervisor_decided_at,
    approved_liable_party,
    decision_note,
    linked_dispute_id,
    superseded_by_receipt_id,
    importer_proposal_note,
    created_at,
    updated_at
  ) VALUES (
    v_review_id,
    v_receipt_id,
    v_order_id,
    v_template_order.importer_id,
    v_tracking_id,
    'at_shipper_receipt',
    'awaiting_importer_proposal',
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    now(),
    now()
  );

  IF (SELECT count(*) FROM public.supplier_invoice_lines WHERE supplier_invoice_id=v_invoice_id)<>5 THEN
    RAISE EXCEPTION 'Expected five supplier invoice lines.';
  END IF;

  IF (SELECT count(*) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id)<>5 THEN
    RAISE EXCEPTION 'Expected five receipt dispositions.';
  END IF;

  IF (SELECT count(*) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id AND disposition_type='clean')<>1 THEN
    RAISE EXCEPTION 'Expected one clean control line.';
  END IF;

  IF (SELECT count(*) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id AND disposition_type<>'clean')<>4 THEN
    RAISE EXCEPTION 'Expected four affected lines.';
  END IF;

  IF (SELECT count(*) FROM public.shipper_package_receipt_evidence WHERE receipt_id=v_receipt_id)<>4 THEN
    RAISE EXCEPTION 'Expected four affected-line evidence rows.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.disputes WHERE order_id=v_order_id) THEN
    RAISE EXCEPTION 'Fixture unexpectedly created a dispute.';
  END IF;

  IF EXISTS (SELECT 1 FROM public.orders WHERE parent_order_id=v_order_id) THEN
    RAISE EXCEPTION 'Fixture unexpectedly created a child order.';
  END IF;

  PERFORM set_config(
    'app.grouped_fixture_manifest',
    jsonb_build_object(
      'result','SEEDED',
      'run_id',v_run_id,
      'order_id',v_order_id,
      'order_ref','PW-GROUPED-'||v_token,
      'payment_auth_id',NULL,
      'supplier_invoice_id',v_invoice_id,
      'tracking_submission_id',v_tracking_id,
      'receipt_id',v_receipt_id,
      'receipt_submission_id',v_receipt_submission_id,
      'review_id',v_review_id,
      'review_status','awaiting_importer_proposal',
      'line_plan',jsonb_build_object(
        'A','clean control',
        'B','replacement',
        'C','replacement',
        'D','refund',
        'E','refund'
      ),
      'lines',v_line_manifest
    )::text,
    true
  );
END
$seed$;

SELECT current_setting('app.grouped_fixture_manifest')::jsonb AS result;
COMMIT;
