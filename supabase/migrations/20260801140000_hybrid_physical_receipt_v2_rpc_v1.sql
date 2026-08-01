BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Build 2: atomic exact physical receipt write authority.
-- The existing v1 RPC remains unchanged and executable.

DO $preflight$
DECLARE
  v_receipt_v1_fingerprint text;
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL
     OR to_regclass('public.shipper_package_receipt_evidence') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.shipper_users') IS NULL
     OR to_regclass('public.orders') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt v2 RPC prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_v2_integrity_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_package_receipt_v2_pending_commit_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_receipt_line_disposition_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_receipt_evidence_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_record_package_receipt_v1(uuid,text,text,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt v2 integrity authorities are missing.';
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)'::regprocedure
  ))
  INTO v_receipt_v1_fingerprint;

  IF v_receipt_v1_fingerprint <> '27fb972b34258990cfa9d752cd2f927b' THEN
    RAISE EXCEPTION
      'shipper_record_package_receipt_v1 changed after review (current fingerprint %).',
      v_receipt_v1_fingerprint;
  END IF;

  IF to_regprocedure(
    'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'shipper_record_package_receipt_v2 already exists; inspect before replacing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.shipper_record_package_receipt_v2(
  p_tracking_submission_id uuid,
  p_receipt_submission_id uuid,
  p_dispositions jsonb,
  p_evidence jsonb DEFAULT '[]'::jsonb,
  p_correction_of_receipt_id uuid DEFAULT NULL,
  p_correction_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_order_id uuid;
  v_order_shipper_id uuid;
  v_importer_id uuid;
  v_receipt_id uuid;
  v_review_id uuid;
  v_prior_receipt_id uuid;
  v_existing public.shipper_package_receipts%ROWTYPE;
  v_dispositions jsonb;
  v_evidence jsonb;
  v_fingerprint text;
  v_expected_count integer;
  v_payload_count integer;
  v_affected_qty numeric;
  v_event_at timestamptz := clock_timestamp();
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper package receipt requires auth.uid()';
  END IF;

  IF p_tracking_submission_id IS NULL OR p_receipt_submission_id IS NULL THEN
    RAISE EXCEPTION 'Tracking submission and receipt submission identities are required.';
  END IF;

  IF jsonb_typeof(COALESCE(p_dispositions, 'null'::jsonb)) <> 'array'
     OR jsonb_array_length(p_dispositions) = 0 THEN
    RAISE EXCEPTION 'A complete non-empty disposition array is required.';
  END IF;

  IF jsonb_typeof(COALESCE(p_evidence, 'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Evidence payload must be a JSON array.';
  END IF;

  SELECT su.id, su.shipper_id
  INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = v_auth_uid
    AND su.active = true
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT ots.order_id, o.shipper_id, o.importer_id
  INTO v_order_id, v_order_shipper_id, v_importer_id
  FROM public.order_tracking_submissions ots
  JOIN public.orders o ON o.id = ots.order_id
  WHERE ots.id = p_tracking_submission_id
    AND ots.superseded_at IS NULL
  FOR SHARE OF ots, o;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Tracking/package record not found or superseded.';
  END IF;
  IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Tracking/package does not belong to this shipper.';
  END IF;
  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Tracking order importer could not be resolved.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_tracking_submission_id::text));

  SELECT COUNT(*)::integer
  INTO v_expected_count
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id = v_order_id
    AND a.tracking_submission_id = p_tracking_submission_id
    AND COALESCE(a.qty_allocated, 0) > 0;

  PERFORM 1
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id = v_order_id
    AND a.tracking_submission_id = p_tracking_submission_id
    AND COALESCE(a.qty_allocated, 0) > 0
  ORDER BY a.id
  FOR UPDATE;

  IF v_expected_count = 0 THEN
    RAISE EXCEPTION 'Tracking/package has no positive exact allocations.';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'tracking_line_allocation_id', x.tracking_line_allocation_id,
      'supplier_invoice_line_id', x.supplier_invoice_line_id,
      'disposition_type', x.disposition_type,
      'quantity', x.quantity,
      'condition_note', NULLIF(BTRIM(COALESCE(x.condition_note, '')), '')
    ) ORDER BY x.tracking_line_allocation_id, x.disposition_type
  )
  INTO v_dispositions
  FROM jsonb_to_recordset(p_dispositions) AS x(
    tracking_line_allocation_id uuid,
    supplier_invoice_line_id uuid,
    disposition_type text,
    quantity numeric,
    condition_note text
  );

  SELECT COUNT(DISTINCT x.tracking_line_allocation_id)::integer
  INTO v_payload_count
  FROM jsonb_to_recordset(v_dispositions) AS x(
    tracking_line_allocation_id uuid,
    supplier_invoice_line_id uuid,
    disposition_type text,
    quantity numeric,
    condition_note text
  );

  IF v_payload_count <> v_expected_count THEN
    RAISE EXCEPTION 'Disposition payload must include every positive package allocation.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_dispositions) AS x(
      tracking_line_allocation_id uuid,
      supplier_invoice_line_id uuid,
      disposition_type text,
      quantity numeric,
      condition_note text
    )
    LEFT JOIN public.order_tracking_line_allocations a
      ON a.id = x.tracking_line_allocation_id
     AND a.order_id = v_order_id
     AND a.tracking_submission_id = p_tracking_submission_id
     AND a.supplier_invoice_line_id = x.supplier_invoice_line_id
     AND COALESCE(a.qty_allocated, 0) > 0
    WHERE a.id IS NULL
       OR x.disposition_type NOT IN ('clean','damaged','missing','wrong','held')
       OR x.quantity IS NULL OR x.quantity <= 0
       OR (x.disposition_type <> 'clean'
           AND NULLIF(BTRIM(COALESCE(x.condition_note, '')), '') IS NULL)
  ) THEN
    RAISE EXCEPTION 'One or more disposition rows are invalid.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_dispositions) AS x(
      tracking_line_allocation_id uuid,
      supplier_invoice_line_id uuid,
      disposition_type text,
      quantity numeric,
      condition_note text
    )
    GROUP BY x.tracking_line_allocation_id, x.disposition_type
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate allocation/disposition rows are not allowed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    LEFT JOIN (
      SELECT x.tracking_line_allocation_id, SUM(x.quantity)::numeric AS qty
      FROM jsonb_to_recordset(v_dispositions) AS x(
        tracking_line_allocation_id uuid,
        supplier_invoice_line_id uuid,
        disposition_type text,
        quantity numeric,
        condition_note text
      )
      GROUP BY x.tracking_line_allocation_id
    ) p ON p.tracking_line_allocation_id = a.id
    WHERE a.order_id = v_order_id
      AND a.tracking_submission_id = p_tracking_submission_id
      AND COALESCE(a.qty_allocated, 0) > 0
      AND (p.tracking_line_allocation_id IS NULL
           OR ABS(p.qty - a.qty_allocated) > 0.0005)
  ) THEN
    RAISE EXCEPTION 'Every exact package allocation must balance to allocated quantity.';
  END IF;

  SELECT COALESCE(SUM(x.quantity) FILTER (
    WHERE x.disposition_type <> 'clean'
  ), 0)::numeric
  INTO v_affected_qty
  FROM jsonb_to_recordset(v_dispositions) AS x(
    tracking_line_allocation_id uuid,
    supplier_invoice_line_id uuid,
    disposition_type text,
    quantity numeric,
    condition_note text
  );

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'storage_object_path', BTRIM(x.storage_object_path),
      'original_filename', NULLIF(BTRIM(COALESCE(x.original_filename, '')), ''),
      'content_type', NULLIF(BTRIM(COALESCE(x.content_type, '')), ''),
      'display_order', COALESCE(x.display_order, 0),
      'tracking_line_allocation_id', x.tracking_line_allocation_id,
      'disposition_type', NULLIF(BTRIM(COALESCE(x.disposition_type, '')), '')
    ) ORDER BY COALESCE(x.display_order, 0), BTRIM(x.storage_object_path)
  ), '[]'::jsonb)
  INTO v_evidence
  FROM jsonb_to_recordset(p_evidence) AS x(
    storage_object_path text,
    original_filename text,
    content_type text,
    display_order integer,
    tracking_line_allocation_id uuid,
    disposition_type text
  );

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_evidence) AS x(
      storage_object_path text,
      original_filename text,
      content_type text,
      display_order integer,
      tracking_line_allocation_id uuid,
      disposition_type text
    )
    WHERE NULLIF(BTRIM(COALESCE(x.storage_object_path, '')), '') IS NULL
       OR COALESCE(x.display_order, 0) < 0
       OR (x.tracking_line_allocation_id IS NULL AND x.disposition_type IS NOT NULL)
       OR (x.tracking_line_allocation_id IS NOT NULL
           AND x.disposition_type NOT IN ('damaged','missing','wrong','held'))
  ) THEN
    RAISE EXCEPTION 'One or more evidence rows are invalid.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_evidence) AS x(
      storage_object_path text,
      original_filename text,
      content_type text,
      display_order integer,
      tracking_line_allocation_id uuid,
      disposition_type text
    )
    GROUP BY x.storage_object_path
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate evidence storage paths are not allowed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_evidence) AS e(
      storage_object_path text,
      original_filename text,
      content_type text,
      display_order integer,
      tracking_line_allocation_id uuid,
      disposition_type text
    )
    WHERE e.tracking_line_allocation_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_to_recordset(v_dispositions) AS d(
          tracking_line_allocation_id uuid,
          supplier_invoice_line_id uuid,
          disposition_type text,
          quantity numeric,
          condition_note text
        )
        WHERE d.tracking_line_allocation_id = e.tracking_line_allocation_id
          AND d.disposition_type = e.disposition_type
          AND d.disposition_type <> 'clean'
      )
  ) THEN
    RAISE EXCEPTION 'Evidence references an affected disposition not in the receipt.';
  END IF;

  IF v_affected_qty > 0 AND jsonb_array_length(v_evidence) = 0 THEN
    RAISE EXCEPTION 'Affected quantity requires one or more evidence references.';
  END IF;

  v_fingerprint := md5(jsonb_build_object(
    'tracking_submission_id', p_tracking_submission_id,
    'dispositions', v_dispositions,
    'evidence', v_evidence,
    'correction_of_receipt_id', p_correction_of_receipt_id,
    'correction_reason', NULLIF(BTRIM(COALESCE(p_correction_reason, '')), '')
  )::text);

  SELECT r.* INTO v_existing
  FROM public.shipper_package_receipts r
  WHERE r.receipt_submission_id = p_receipt_submission_id
  FOR SHARE;

  IF v_existing.id IS NOT NULL THEN
    IF v_existing.shipper_user_id IS DISTINCT FROM v_shipper_user_id
       OR v_existing.tracking_submission_id IS DISTINCT FROM p_tracking_submission_id
       OR v_existing.payload_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RAISE EXCEPTION 'Receipt submission identity was already used for another context or payload.';
    END IF;

    SELECT pr.id INTO v_review_id
    FROM public.physical_receipt_reviews pr
    WHERE pr.receipt_id = v_existing.id;

    RETURN jsonb_build_object(
      'receipt_id', v_existing.id,
      'physical_receipt_review_id', v_review_id,
      'receipt_status', v_existing.receipt_status,
      'idempotent_retry', true
    );
  END IF;

  SELECT r.id INTO v_prior_receipt_id
  FROM public.shipper_package_receipts r
  WHERE r.tracking_submission_id = p_tracking_submission_id
    AND (r.receipt_model_version = 1
         OR (r.receipt_model_version = 2
             AND r.receipt_state = 'finalised'
             AND r.finalised_at IS NOT NULL))
  ORDER BY COALESCE(r.finalised_at, r.created_at) DESC,
           r.created_at DESC,
           r.id DESC
  LIMIT 1
  FOR SHARE;

  IF v_prior_receipt_id IS DISTINCT FROM p_correction_of_receipt_id THEN
    IF v_prior_receipt_id IS NULL THEN
      RAISE EXCEPTION 'First receipt cannot identify a correction predecessor.';
    ELSE
      RAISE EXCEPTION 'Later receipt must identify the latest finalised package receipt as predecessor.';
    END IF;
  END IF;

  IF p_correction_of_receipt_id IS NOT NULL
     AND NULLIF(BTRIM(COALESCE(p_correction_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Correction reason is required.';
  END IF;

  INSERT INTO public.shipper_package_receipts (
    tracking_submission_id, order_id, shipper_id, shipper_user_id,
    receipt_status, condition_note, evidence_url,
    recorded_at, created_at,
    receipt_model_version, receipt_state,
    receipt_submission_id, payload_fingerprint, finalised_at,
    correction_of_receipt_id, correction_reason
  ) VALUES (
    p_tracking_submission_id, v_order_id, v_shipper_id, v_shipper_user_id,
    'held_query', NULL, NULL,
    v_event_at, v_event_at,
    2, 'pending',
    p_receipt_submission_id, v_fingerprint, NULL,
    p_correction_of_receipt_id,
    NULLIF(BTRIM(COALESCE(p_correction_reason, '')), '')
  ) RETURNING id INTO v_receipt_id;

  INSERT INTO public.shipper_package_receipt_line_dispositions (
    receipt_id, tracking_submission_id, tracking_line_allocation_id,
    supplier_invoice_line_id, disposition_type, quantity, condition_note
  )
  SELECT v_receipt_id, p_tracking_submission_id,
         x.tracking_line_allocation_id, x.supplier_invoice_line_id,
         x.disposition_type, x.quantity,
         NULLIF(BTRIM(COALESCE(x.condition_note, '')), '')
  FROM jsonb_to_recordset(v_dispositions) AS x(
    tracking_line_allocation_id uuid,
    supplier_invoice_line_id uuid,
    disposition_type text,
    quantity numeric,
    condition_note text
  );

  INSERT INTO public.shipper_package_receipt_evidence (
    receipt_id, line_disposition_id, storage_object_path,
    original_filename, content_type, display_order,
    uploaded_by_shipper_user_id
  )
  SELECT v_receipt_id, d.id, e.storage_object_path,
         e.original_filename, e.content_type, e.display_order,
         v_shipper_user_id
  FROM jsonb_to_recordset(v_evidence) AS e(
    storage_object_path text,
    original_filename text,
    content_type text,
    display_order integer,
    tracking_line_allocation_id uuid,
    disposition_type text
  )
  LEFT JOIN public.shipper_package_receipt_line_dispositions d
    ON d.receipt_id = v_receipt_id
   AND d.tracking_line_allocation_id = e.tracking_line_allocation_id
   AND d.disposition_type = e.disposition_type;

  UPDATE public.shipper_package_receipts r
  SET receipt_state = 'finalised'
  WHERE r.id = v_receipt_id
    AND r.receipt_state = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'V2 receipt could not be finalised.';
  END IF;

  IF p_correction_of_receipt_id IS NOT NULL THEN
    UPDATE public.physical_receipt_reviews pr
    SET status = 'superseded',
        superseded_by_receipt_id = v_receipt_id,
        decision_note = COALESCE(
          NULLIF(BTRIM(COALESCE(pr.decision_note, '')), '') || E'\n',
          ''
        ) || 'Superseded by corrected physical receipt ' || v_receipt_id::text || '.',
        updated_at = clock_timestamp()
    WHERE pr.receipt_id = p_correction_of_receipt_id
      AND pr.status IN (
        'awaiting_importer_proposal',
        'awaiting_supervisor_review',
        'returned_for_information',
        'approved_for_investigation',
        'rejected',
        'closed_no_action'
      );
  END IF;

  IF v_affected_qty > 0 THEN
    INSERT INTO public.physical_receipt_reviews (
      receipt_id, order_id, importer_id, tracking_submission_id,
      source_stage, status
    ) VALUES (
      v_receipt_id, v_order_id, v_importer_id, p_tracking_submission_id,
      'at_shipper_receipt', 'awaiting_importer_proposal'
    ) RETURNING id INTO v_review_id;
  END IF;

  SELECT r.receipt_status INTO v_existing.receipt_status
  FROM public.shipper_package_receipts r
  WHERE r.id = v_receipt_id;

  RETURN jsonb_build_object(
    'receipt_id', v_receipt_id,
    'physical_receipt_review_id', v_review_id,
    'receipt_status', v_existing.receipt_status,
    'idempotent_retry', false
  );
END;
$function$;

COMMENT ON FUNCTION public.shipper_record_package_receipt_v2(
  uuid,uuid,jsonb,jsonb,uuid,text
) IS
'Atomic idempotent exact receipt snapshot authority. Records shipper facts only, finalises through installed integrity guards, supersedes a correctable prior triage review and creates one new physical review only for affected quantity.';

REVOKE ALL ON FUNCTION public.shipper_record_package_receipt_v2(
  uuid,uuid,jsonb,jsonb,uuid,text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shipper_record_package_receipt_v2(
  uuid,uuid,jsonb,jsonb,uuid,text
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
