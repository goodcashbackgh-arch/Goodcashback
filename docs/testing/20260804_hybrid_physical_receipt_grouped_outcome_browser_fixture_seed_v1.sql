-- Persistent browser fixture for grouped physical receipt outcomes.
-- Creates one fresh five-line order and leaves its physical review at
-- awaiting_importer_proposal so importer and supervisor actions are exercised in UI.
--
-- Lines:
--   A clean control
--   B missing  -> propose replacement in UI
--   C damaged  -> propose replacement in UI
--   D missing  -> propose refund in UI
--   E wrong    -> propose refund in UI
--
-- The script uses fresh UUIDs and a unique PW-GROUPED-* marker. It does not
-- modify an existing order. Any failed invariant rolls back the entire fixture.
-- It creates no dispute, outcome lane, same-order route, refund credit, or
-- replacement child. Those must be produced by the real application workflow.

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
  SELECT string_agg(format('%I',a.attname),', ' ORDER BY a.attnum),
         string_agg(format('(jsonb_populate_record(NULL::%s,$1)).%I',p_table,a.attname),', ' ORDER BY a.attnum)
  INTO v_columns,v_values
  FROM pg_attribute a
  WHERE a.attrelid=p_table
    AND a.attnum>0
    AND NOT a.attisdropped
    AND a.attidentity=''
    AND a.attgenerated=''
    AND a.attname<>ALL(COALESCE(p_exclude,ARRAY[]::text[]));

  EXECUTE format('INSERT INTO %s (%s) SELECT %s RETURNING id',p_table,v_columns,v_values)
  USING p_source||p_overrides
  INTO v_id;
  RETURN v_id;
END
$function$;

DO $seed$
DECLARE
  v_run_id uuid:=gen_random_uuid();
  v_marker text;
  v_template_review public.physical_receipt_reviews%ROWTYPE;
  v_template_order public.orders%ROWTYPE;
  v_template_tracking public.order_tracking_submissions%ROWTYPE;
  v_template_receipt public.shipper_package_receipts%ROWTYPE;
  v_template_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_template_evidence public.shipper_package_receipt_evidence%ROWTYPE;
  v_template_storage storage.objects%ROWTYPE;
  v_template_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_template_line public.supplier_invoice_lines%ROWTYPE;
  v_template_invoice public.supplier_invoices%ROWTYPE;
  v_order_id uuid:=gen_random_uuid();
  v_invoice_id uuid:=gen_random_uuid();
  v_tracking_id uuid:=gen_random_uuid();
  v_receipt_id uuid:=gen_random_uuid();
  v_review_id uuid:=gen_random_uuid();
  v_line_id uuid;
  v_allocation_id uuid;
  v_disposition_id uuid;
  v_evidence_id uuid;
  v_storage_object_id uuid;
  v_storage_path text;
  v_filename text;
  v_code text;
  v_disposition_type text;
  v_line_ids jsonb:='{}'::jsonb;
BEGIN
  v_marker:='grouped-outcome-browser:'||v_run_id::text;

  SELECT review.* INTO STRICT v_template_review
  FROM public.physical_receipt_reviews review
  WHERE EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_line_dispositions d
    WHERE d.receipt_id=review.receipt_id
      AND d.disposition_type<>'clean'
  )
  ORDER BY review.created_at DESC,review.id DESC
  LIMIT 1;

  SELECT * INTO STRICT v_template_order
  FROM public.orders WHERE id=v_template_review.order_id;

  IF v_template_order.order_type='replacement_child' THEN
    RAISE EXCEPTION 'Selected structural template is a replacement child; refusing to clone it.';
  END IF;

  SELECT * INTO STRICT v_template_tracking
  FROM public.order_tracking_submissions
  WHERE id=v_template_review.tracking_submission_id;

  SELECT * INTO STRICT v_template_receipt
  FROM public.shipper_package_receipts
  WHERE id=v_template_review.receipt_id;

  SELECT d.* INTO STRICT v_template_disposition
  FROM public.shipper_package_receipt_line_dispositions d
  WHERE d.receipt_id=v_template_review.receipt_id
  ORDER BY CASE WHEN d.disposition_type<>'clean' THEN 0 ELSE 1 END,d.created_at,d.id
  LIMIT 1;

  SELECT e.* INTO STRICT v_template_evidence
  FROM public.shipper_package_receipt_evidence e
  WHERE e.receipt_id=v_template_review.receipt_id
  ORDER BY e.display_order,e.created_at,e.id
  LIMIT 1;

  SELECT o.* INTO STRICT v_template_storage
  FROM storage.objects o
  WHERE o.bucket_id='invoice-evidence'
    AND o.name=v_template_evidence.storage_object_path;

  SELECT * INTO STRICT v_template_allocation
  FROM public.order_tracking_line_allocations
  WHERE id=v_template_disposition.tracking_line_allocation_id;

  SELECT * INTO STRICT v_template_line
  FROM public.supplier_invoice_lines
  WHERE id=v_template_disposition.supplier_invoice_line_id;

  SELECT * INTO STRICT v_template_invoice
  FROM public.supplier_invoices
  WHERE id=v_template_line.supplier_invoice_id;

  PERFORM pg_temp.clone_row(
    'public.orders',to_jsonb(v_template_order),
    jsonb_build_object(
      'id',v_order_id,
      'order_ref','PW-GROUPED-'||replace(v_run_id::text,'-',''),
      'order_type',v_template_order.order_type,
      'parent_order_id',NULL,
      'replacement_source_dispute_line_id',NULL,
      'total_qty_declared',5,
      'created_at',now(),
      'updated_at',now()
    )
  );

  PERFORM pg_temp.clone_row(
    'public.supplier_invoices',to_jsonb(v_template_invoice),
    jsonb_build_object(
      'id',v_invoice_id,
      'order_id',v_order_id,
      'invoice_number','PW-GROUPED-'||replace(v_run_id::text,'-',''),
      'supplier_invoice_number','PW-GROUPED-'||replace(v_run_id::text,'-',''),
      'created_at',now(),
      'updated_at',now()
    )
  );

  PERFORM pg_temp.clone_row(
    'public.order_tracking_submissions',to_jsonb(v_template_tracking),
    jsonb_build_object(
      'id',v_tracking_id,
      'order_id',v_order_id,
      'tracking_ref','PWGRP-'||substr(replace(v_run_id::text,'-',''),1,20),
      'superseded_at',NULL,
      'created_at',now(),
      'updated_at',now()
    )
  );

  PERFORM pg_temp.clone_row(
    'public.shipper_package_receipts',to_jsonb(v_template_receipt),
    jsonb_build_object(
      'id',v_receipt_id,
      'order_id',v_order_id,
      'tracking_submission_id',v_tracking_id,
      'receipt_submission_id',gen_random_uuid(),
      'payload_fingerprint',md5(v_marker),
      'receipt_model_version',2,
      'receipt_state','pending',
      'receipt_status','held_query',
      'finalised_at',NULL,
      'correction_of_receipt_id',NULL,
      'correction_reason',NULL,
      'created_at',now(),
      'updated_at',now()
    )
  );

  FOREACH v_code IN ARRAY ARRAY['A','B','C','D','E'] LOOP
    v_line_id:=gen_random_uuid();
    v_allocation_id:=gen_random_uuid();
    v_disposition_id:=gen_random_uuid();

    v_disposition_type:=CASE v_code
      WHEN 'A' THEN 'clean'
      WHEN 'B' THEN 'missing'
      WHEN 'C' THEN 'damaged'
      WHEN 'D' THEN 'missing'
      WHEN 'E' THEN 'wrong'
    END;

    PERFORM pg_temp.clone_row(
      'public.supplier_invoice_lines',to_jsonb(v_template_line),
      jsonb_build_object(
        'id',v_line_id,
        'supplier_invoice_id',v_invoice_id,
        'quantity',1,
        'qty',1,
        'line_order',ascii(v_code)-64,
        'description',v_marker||':LINE-'||v_code,
        'created_at',now(),
        'updated_at',now()
      )
    );

    PERFORM pg_temp.clone_row(
      'public.order_tracking_line_allocations',to_jsonb(v_template_allocation),
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
        'notes',v_marker||':LINE-'||v_code,
        'locked_for_export_pack_at',NULL,
        'created_at',now(),
        'updated_at',now()
      )
    );

    INSERT INTO public.shipper_package_receipt_line_dispositions(
      id,receipt_id,tracking_submission_id,tracking_line_allocation_id,
      supplier_invoice_line_id,disposition_type,quantity,condition_note,created_at
    ) VALUES(
      v_disposition_id,v_receipt_id,v_tracking_id,v_allocation_id,
      v_line_id,v_disposition_type,1,
      v_marker||':LINE-'||v_code||':'||v_disposition_type,now()
    );

    IF v_disposition_type<>'clean' THEN
      v_evidence_id:=gen_random_uuid();
      v_storage_object_id:=gen_random_uuid();
      v_filename:='grouped-outcome-'||v_run_id::text||'-'||lower(v_code)||'.png';
      v_storage_path:='shipper-receipts/'||v_template_order.shipper_id::text||'/'||v_tracking_id::text||'/'||v_filename;

      PERFORM pg_temp.clone_row(
        'storage.objects',to_jsonb(v_template_storage),
        jsonb_build_object(
          'id',v_storage_object_id,
          'bucket_id','invoice-evidence',
          'name',v_storage_path,
          'created_at',now(),
          'updated_at',now(),
          'last_accessed_at',now()
        )
      );

      INSERT INTO public.shipper_package_receipt_evidence(
        id,receipt_id,line_disposition_id,storage_object_path,original_filename,
        content_type,display_order,uploaded_by_shipper_user_id,created_at
      ) VALUES(
        v_evidence_id,v_receipt_id,v_disposition_id,v_storage_path,v_filename,
        'image/png',ascii(v_code)-65,v_template_receipt.shipper_user_id,now()
      );
    END IF;

    v_line_ids:=v_line_ids||jsonb_build_object(
      v_code,jsonb_build_object(
        'supplier_invoice_line_id',v_line_id,
        'tracking_line_allocation_id',v_allocation_id,
        'receipt_line_disposition_id',v_disposition_id,
        'disposition_type',v_disposition_type
      )
    );
  END LOOP;

  UPDATE public.shipper_package_receipts
  SET receipt_state='finalised',updated_at=now()
  WHERE id=v_receipt_id
    AND receipt_state='pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending fixture receipt could not be finalised.';
  END IF;

  INSERT INTO public.physical_receipt_reviews(
    id,receipt_id,order_id,importer_id,tracking_submission_id,source_stage,status,
    importer_proposed_by_operator_id,importer_proposed_at,
    supervisor_decided_by_staff_id,supervisor_decided_at,approved_liable_party,
    decision_note,linked_dispute_id,superseded_by_receipt_id,
    importer_proposal_note,created_at,updated_at
  ) VALUES(
    v_review_id,v_receipt_id,v_order_id,v_template_review.importer_id,v_tracking_id,
    'at_shipper_receipt','awaiting_importer_proposal',NULL,NULL,NULL,NULL,NULL,
    NULL,NULL,NULL,NULL,now(),now()
  );

  IF (SELECT COUNT(*) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id)<>5 THEN
    RAISE EXCEPTION 'Fixture must contain exactly five receipt dispositions.';
  END IF;
  IF (SELECT COUNT(*) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id AND disposition_type='clean')<>1 THEN
    RAISE EXCEPTION 'Fixture must contain exactly one clean control line.';
  END IF;
  IF (SELECT COUNT(*) FROM public.shipper_package_receipt_line_dispositions WHERE receipt_id=v_receipt_id AND disposition_type<>'clean')<>4 THEN
    RAISE EXCEPTION 'Fixture must contain exactly four affected lines.';
  END IF;
  IF (SELECT COUNT(*) FROM public.shipper_package_receipt_evidence WHERE receipt_id=v_receipt_id)<>4 THEN
    RAISE EXCEPTION 'Each affected line must have evidence.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.shipper_package_receipts
    WHERE id=v_receipt_id
      AND receipt_model_version=2
      AND receipt_state='finalised'
      AND finalised_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Fixture receipt did not pass normal v2 finalisation.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.orders WHERE parent_order_id=v_order_id) THEN
    RAISE EXCEPTION 'Fixture unexpectedly created a replacement child order.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.disputes WHERE order_id=v_order_id) THEN
    RAISE EXCEPTION 'Fixture must stop before dispute creation.';
  END IF;

  PERFORM set_config('app.grouped_fixture_manifest',jsonb_build_object(
    'result','SEEDED',
    'run_id',v_run_id,
    'marker',v_marker,
    'order_id',v_order_id,
    'order_ref','PW-GROUPED-'||replace(v_run_id::text,'-',''),
    'order_type',v_template_order.order_type,
    'supplier_invoice_id',v_invoice_id,
    'tracking_submission_id',v_tracking_id,
    'receipt_id',v_receipt_id,
    'review_id',v_review_id,
    'review_status','awaiting_importer_proposal',
    'line_plan',jsonb_build_object(
      'A','clean control',
      'B','propose replacement',
      'C','propose replacement',
      'D','propose refund',
      'E','propose refund'
    ),
    'lines',v_line_ids
  )::text,true);
END
$seed$;

SELECT current_setting('app.grouped_fixture_manifest')::jsonb AS result;
COMMIT;
