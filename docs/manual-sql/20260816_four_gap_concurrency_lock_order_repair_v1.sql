-- FOUR_GAP_CONCURRENCY_LOCK_ORDER_REPAIR_ADDENDUM_v1
-- Corrected combined transactional migration.
-- Governing authority: frozen addendum Sections 1-16.
-- Scope: exactly four existing function replacements; lock-order/revalidation only.

BEGIN;

DO $preflight$
DECLARE
  r record;
  v_proc regprocedure;
  v_md5 text;
  v_meta pg_catalog.pg_proc%ROWTYPE;
BEGIN
  -- Fingerprint method proven against the authoritative live extracts:
  -- md5(exact pg_get_functiondef text, including its terminal LF) reproduced
  -- every reviewed target/protected/wrapper fingerprint used below.
  FOR r IN
    SELECT *
    FROM (VALUES
      ('public.internal_classify_supplier_invoice_rejection_v1(uuid,boolean,text)', 'c3a67574fc43ea469ee5d5c79b0731c2'),
      ('public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)', 'e3cccb6bf607d035e1fbfacadc76d84a'),
      ('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)', '32ecb4c4bb7f4809e88a35241a8cf4d5'),
      ('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)', '0293a94d4eb17daf9c7e48131cd75ca1'),
      ('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)', '74e3144de22e56f01e73f91965fb60dc'),
      ('public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)', 'c423bbb2a1e1bd79b8a0915924eddcb7'),
      ('public.shipper_package_receipt_write_compatibility_guard_v1()', '8b4f88ff3b4633565805d6c1491bff1c'),
      ('public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text)', 'c25e19d36bb3891419c5ab58ad23b9b6'),
      ('public.staff_reject_supplier_invoice_resubmission(uuid,text)', '05e93b802ceecee5b5439dec8dcf58ee'),
      ('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)', '9b95dd57340cd844e80c349e0732b64d'),
      ('public.customer_active_order_review_link_v1(uuid)', 'f78b2fcb4186614396327e8c970e2ef9')
    ) AS expected(signature, expected_md5)
  LOOP
    v_proc := to_regprocedure(r.signature);

    IF v_proc IS NULL THEN
      RAISE EXCEPTION 'Concurrency repair preflight failed: required function % is missing.', r.signature;
    END IF;

    SELECT md5(pg_get_functiondef(v_proc::oid))
    INTO v_md5;

    IF v_md5 IS DISTINCT FROM r.expected_md5 THEN
      RAISE EXCEPTION
        'Concurrency repair preflight failed: % drifted. Expected %, got %. No changes applied.',
        r.signature, r.expected_md5, v_md5;
    END IF;
  END LOOP;


  FOR r IN
    SELECT *
    FROM (VALUES
      (
        'public.internal_classify_supplier_invoice_rejection_v1(uuid,boolean,text)',
        '{postgres=X/postgres,service_role=X/postgres}',
        'uuid'::regtype::oid,
        true,
        'uuid, boolean, text',
        ARRAY['uuid'::regtype::oid,'boolean'::regtype::oid,'text'::regtype::oid,'uuid'::regtype::oid]::oid[],
        ARRAY['i','i','i','t']::"char"[],
        ARRAY['p_supplier_invoice_id','p_requires_resubmission','p_review_notes','order_id']::text[]
      ),
      (
        'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)',
        '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
        'jsonb'::regtype::oid,
        false,
        'uuid, uuid, jsonb, jsonb, uuid, text',
        NULL::oid[],
        NULL::"char"[],
        ARRAY['p_tracking_submission_id','p_receipt_submission_id','p_dispositions','p_evidence','p_correction_of_receipt_id','p_correction_reason']::text[]
      ),
      (
        'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
        '{postgres=X/postgres,service_role=X/postgres}',
        'jsonb'::regtype::oid,
        false,
        'uuid, text, jsonb, text, text',
        NULL::oid[],
        NULL::"char"[],
        ARRAY['p_review_id','p_decision','p_allocations','p_liable_party','p_decision_note']::text[]
      ),
      (
        'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)',
        '{postgres=X/postgres,service_role=X/postgres}',
        'integer'::regtype::oid,
        false,
        'uuid, uuid',
        NULL::oid[],
        NULL::"char"[],
        ARRAY['p_order_id','p_created_by_staff_id']::text[]
      )
    ) AS expected(
      signature,
      expected_acl,
      expected_rettype,
      expected_returns_set,
      expected_argtypes,
      expected_allargtypes,
      expected_argmodes,
      expected_argnames
    )
  LOOP
    v_proc := to_regprocedure(r.signature);

    IF v_proc IS NULL THEN
      RAISE EXCEPTION 'Concurrency repair metadata check failed: required target function % is missing.', r.signature;
    END IF;

    SELECT p.*
    INTO v_meta
    FROM pg_catalog.pg_proc p
    WHERE p.oid = v_proc::oid;

    IF v_meta.proowner IS DISTINCT FROM 'postgres'::regrole::oid
       OR v_meta.proacl::text IS DISTINCT FROM r.expected_acl
       OR v_meta.proconfig IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[]
       OR v_meta.prosecdef IS DISTINCT FROM true
       OR v_meta.proleakproof IS DISTINCT FROM false
       OR v_meta.provolatile IS DISTINCT FROM 'v'::"char"
       OR v_meta.proparallel IS DISTINCT FROM 'u'::"char"
       OR v_meta.prokind IS DISTINCT FROM 'f'::"char"
       OR v_meta.prorettype IS DISTINCT FROM r.expected_rettype
       OR v_meta.proretset IS DISTINCT FROM r.expected_returns_set
       OR pg_catalog.oidvectortypes(v_meta.proargtypes) IS DISTINCT FROM r.expected_argtypes
       OR v_meta.proallargtypes IS DISTINCT FROM r.expected_allargtypes
       OR v_meta.proargmodes IS DISTINCT FROM r.expected_argmodes
       OR v_meta.proargnames IS DISTINCT FROM r.expected_argnames
    THEN
      RAISE EXCEPTION 'Concurrency repair metadata check failed for %. No changes may proceed.', r.signature;
    END IF;
  END LOOP;
END;
$preflight$;


-- -----------------------------------------------------------------------------
-- AUTHORISED REPLACEMENT: public.internal_classify_supplier_invoice_rejection_v1
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.internal_classify_supplier_invoice_rejection_v1(p_supplier_invoice_id uuid, p_requires_resubmission boolean, p_review_notes text)
 RETURNS TABLE(order_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_staff_id uuid;
  v_role_type text;
  v_invoice record;
  v_order_id uuid;
  v_now timestamptz := now();
  v_notes text := NULLIF(btrim(COALESCE(p_review_notes, '')), '');
  v_blocker text;
  v_retirement_note text;
BEGIN
  SELECT s.id, s.role_type::text
    INTO v_staff_id, v_role_type
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL OR v_role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can review invoices.';
  END IF;

  IF p_requires_resubmission IS NULL THEN
    RAISE EXCEPTION 'A rejection classification is required.';
  END IF;

  IF v_notes IS NULL THEN
    RAISE EXCEPTION 'A rejection reason is required.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Resolve identity first without taking the supplier-invoice lock.
  -- This allows us to enter the platform's established order-first boundary.
  -- --------------------------------------------------------------------------

  SELECT si.order_id
    INTO v_order_id
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;


  -- --------------------------------------------------------------------------
  -- Canonical concurrency boundary:
  -- financial summaries -> order invoices -> bundle flag -> bundle advisory
  -- -> order row -> order advisory -> target invoice -> invoice lines.
  -- --------------------------------------------------------------------------

  PERFORM 1
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = v_order_id
  ORDER BY fs.id
  FOR UPDATE OF fs;

  PERFORM 1
  FROM public.supplier_invoices si
  WHERE si.order_id = v_order_id
  ORDER BY si.id
  FOR UPDATE OF si;

  PERFORM 1
  FROM public.supplier_invoice_review_flags f
  WHERE f.order_id = v_order_id
    AND f.supplier_invoice_id = p_supplier_invoice_id
    AND f.flag_type = 'order_bundle_limit_breach'
    AND f.status IN ('open','under_review')
  FOR UPDATE OF f;

  PERFORM pg_advisory_xact_lock(
    hashtext('order_bundle_limit:' || v_order_id::text)
  );

  PERFORM 1
  FROM public.orders o
  WHERE o.id = v_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supplier invoice order not found.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));


  SELECT si.id, si.order_id
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = p_supplier_invoice_id
  FOR UPDATE;

  IF v_invoice.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice not found.';
  END IF;

  IF v_invoice.order_id IS DISTINCT FROM v_order_id THEN
    RAISE EXCEPTION
      'Supplier invoice order identity changed during rejection. Retry the review.';
  END IF;


  -- Lock the invoice lines in deterministic order before blocker assessment
  -- and retirement.
  PERFORM 1
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id
  ORDER BY sil.id
  FOR UPDATE;


  -- --------------------------------------------------------------------------
  -- Existing blocker rules unchanged.
  -- --------------------------------------------------------------------------

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations otla
    JOIN public.supplier_invoice_lines sil
      ON sil.id = otla.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id = v_invoice.id
      AND COALESCE(otla.qty_allocated, 0) > 0
  ) THEN
    v_blocker := 'tracking allocation';

  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_order_review_links l
    WHERE l.order_id = v_invoice.order_id
      AND l.is_active = true
      AND (l.expires_at IS NULL OR l.expires_at > now())
  ) THEN
    v_blocker := 'active customer review';

  ELSIF EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = v_invoice.order_id
      AND h.resolved_at IS NULL
      AND h.status IN (
        'requested',
        'supervisor_approved',
        'converted_to_exception'
      )
      AND (
        h.requested_scope = 'order'
        OR (
          h.requested_scope = 'line'
          AND EXISTS (
            SELECT 1
            FROM public.supplier_invoice_lines sil
            WHERE sil.id = h.supplier_invoice_line_id
              AND sil.supplier_invoice_id = v_invoice.id
          )
        )
        OR (
          h.requested_scope = 'tracking'
          AND EXISTS (
            SELECT 1
            FROM public.order_tracking_line_allocations otla
            JOIN public.supplier_invoice_lines sil
              ON sil.id = otla.supplier_invoice_line_id
            WHERE otla.tracking_submission_id = h.tracking_submission_id
              AND sil.supplier_invoice_id = v_invoice.id
              AND COALESCE(otla.qty_allocated, 0) > 0
          )
        )
      )
  ) THEN
    v_blocker := 'active customer hold';

  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.supplier_invoice_lines sil
      ON sil.id = dl.supplier_invoice_line_id
    JOIN public.disputes d
      ON d.id = dl.dispute_id
    WHERE sil.supplier_invoice_id = v_invoice.id
      AND dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN
    v_blocker := 'unresolved exception';

  ELSIF EXISTS (
    SELECT 1
    FROM public.sales_invoices sales
    WHERE sales.order_id = v_invoice.order_id
      AND COALESCE(sales.invoice_type::text, '') IN ('main', 'supplementary')
      AND COALESCE(sales.sage_status::text, '') <> 'void'
  ) THEN
    v_blocker := 'non-void customer sales document';

  ELSIF EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.supplier_invoice_id = v_invoice.id
      AND a.allocation_type::text = 'supplier_invoice'
      AND a.allocation_status::text IN ('confirmed', 'held')
  ) THEN
    v_blocker := 'supplier-payment allocation';

  ELSIF EXISTS (
    SELECT 1
    FROM public.dispute_refund_evidence_submissions e
    WHERE e.original_supplier_invoice_id = v_invoice.id
  ) THEN
    v_blocker := 'supplier refund or credit evidence';

  ELSIF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.source_table = 'supplier_invoices'
      AND s.source_id = v_invoice.id
      AND COALESCE(s.active, true) = true
      AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  )
  OR EXISTS (
    SELECT 1
    FROM public.sage_postings sp
    WHERE sp.source_table = 'supplier_invoices'
      AND sp.source_id = v_invoice.id
  ) THEN
    v_blocker := 'frozen or posted supplier accounting artefact';
  END IF;


  IF v_blocker IS NOT NULL THEN
    RAISE EXCEPTION
      'Supplier invoice % cannot be rejected after downstream use (%). Use the controlled correction route.',
      v_invoice.id,
      v_blocker;
  END IF;


  v_retirement_note := CASE
    WHEN p_requires_resubmission
      THEN 'Retired because the source supplier invoice was rejected and corrected evidence is required.'
    ELSE
      'Retired because the source supplier invoice was excluded from this order with no resubmission required.'
  END;


  UPDATE public.supplier_invoices si
  SET
    review_status = 'rejected_resubmit_required',
    rejection_requires_resubmission_yn = p_requires_resubmission,
    blocked_from_sage_yn = true,
    is_current_for_order = false,
    reviewed_by_staff_id = v_staff_id,
    reviewed_at = v_now,
    review_notes = v_notes
  WHERE si.id = p_supplier_invoice_id;


  UPDATE public.supplier_invoice_lines sil
  SET
    eligible_for_invoice_yn = 'N',
    qty_confirmed = NULL,
    amount_confirmed = NULL
  WHERE sil.supplier_invoice_id = p_supplier_invoice_id;


  UPDATE public.supplier_invoice_line_resolutions r
  SET
    active = false,
    updated_at = v_now,
    notes = concat_ws(
      E'\n',
      NULLIF(r.notes, ''),
      v_retirement_note
    )
  WHERE r.supplier_invoice_id = p_supplier_invoice_id
    AND r.active = true;


  UPDATE public.order_value_adjustments ova
  SET
    approval_status = 'rejected',
    approved_by_staff_id = NULL,
    approved_at = NULL,
    notes = concat_ws(
      E'\n',
      NULLIF(ova.notes, ''),
      v_retirement_note || ': ' || v_notes
    ),
    updated_at = v_now
  WHERE ova.supplier_invoice_id = p_supplier_invoice_id
    AND ova.approval_status <> 'rejected';


  UPDATE public.supplier_invoice_review_flags f
  SET
    status = 'resolved',
    resolved_by_staff_id = v_staff_id,
    resolved_at = v_now,
    resolution_notes = v_notes,
    updated_at = v_now
  WHERE f.supplier_invoice_id = p_supplier_invoice_id
    AND f.status IN ('open', 'under_review');


  RETURN QUERY
  SELECT v_invoice.order_id::uuid;
END;
$function$;

-- -----------------------------------------------------------------------------
-- AUTHORISED REPLACEMENT: public.shipper_record_package_receipt_v2
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.shipper_record_package_receipt_v2(p_tracking_submission_id uuid, p_receipt_submission_id uuid, p_dispositions jsonb, p_evidence jsonb DEFAULT '[]'::jsonb, p_correction_of_receipt_id uuid DEFAULT NULL::uuid, p_correction_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_order_id uuid;
  v_locked_order_id uuid;
  v_order_shipper_id uuid;
  v_importer_id uuid;
  v_receipt_id uuid;
  v_review_id uuid;
  v_prior_receipt_id uuid;
  v_prior_created_at timestamptz;
  v_prior_review_status text;
  v_evidence_prefix text;
  v_existing public.shipper_package_receipts%ROWTYPE;
  v_dispositions jsonb;
  v_evidence jsonb;
  v_fingerprint text;
  v_expected_count integer;
  v_payload_count integer;
  v_affected_qty numeric;
  v_event_at timestamptz;
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

  SELECT ots.order_id
  INTO v_order_id
  FROM public.order_tracking_submissions ots
  WHERE ots.id = p_tracking_submission_id
    AND ots.superseded_at IS NULL;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Tracking/package record not found or superseded.';
  END IF;

  SELECT o.shipper_id, o.importer_id
  INTO v_order_shipper_id, v_importer_id
  FROM public.orders o
  WHERE o.id = v_order_id
  FOR UPDATE;

  PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));

  SELECT ots.order_id
  INTO v_locked_order_id
  FROM public.order_tracking_submissions ots
  WHERE ots.id = p_tracking_submission_id
    AND ots.superseded_at IS NULL
  FOR UPDATE;

  IF v_locked_order_id IS NULL
     OR v_locked_order_id IS DISTINCT FROM v_order_id THEN
    RAISE EXCEPTION 'Tracking/package record not found or superseded.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_tracking_submission_id::text));

  IF v_order_shipper_id IS DISTINCT FROM v_shipper_id THEN
    RAISE EXCEPTION 'Tracking/package does not belong to this shipper.';
  END IF;
  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Tracking order importer could not be resolved.';
  END IF;

  v_evidence_prefix :=
    'shipper-receipts/' || v_shipper_id::text || '/'
    || p_tracking_submission_id::text || '/';

  PERFORM 1
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id = v_order_id
    AND a.tracking_submission_id = p_tracking_submission_id
    AND COALESCE(a.qty_allocated, 0) > 0
  ORDER BY a.id
  FOR UPDATE;

  SELECT COUNT(*)::integer
  INTO v_expected_count
  FROM public.order_tracking_line_allocations a
  WHERE a.order_id = v_order_id
    AND a.tracking_submission_id = p_tracking_submission_id
    AND COALESCE(a.qty_allocated, 0) > 0;

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
       OR x.storage_object_path NOT LIKE v_evidence_prefix || '%'
       OR LENGTH(x.storage_object_path) <= LENGTH(v_evidence_prefix)
       OR POSITION('..' IN x.storage_object_path) > 0
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
    IF v_existing.receipt_model_version IS DISTINCT FROM 2
       OR v_existing.receipt_state IS DISTINCT FROM 'finalised'
       OR v_existing.finalised_at IS NULL
       OR v_existing.shipper_user_id IS DISTINCT FROM v_shipper_user_id
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

  SELECT r.id, r.created_at
  INTO v_prior_receipt_id, v_prior_created_at
  FROM public.shipper_package_receipts r
  WHERE r.tracking_submission_id = p_tracking_submission_id
    AND (r.receipt_model_version = 1
         OR (r.receipt_model_version = 2
             AND r.receipt_state = 'finalised'
             AND r.finalised_at IS NOT NULL))
  ORDER BY r.created_at DESC, r.id DESC
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

  IF p_correction_of_receipt_id IS NOT NULL THEN
    SELECT pr.status
    INTO v_prior_review_status
    FROM public.physical_receipt_reviews pr
    WHERE pr.receipt_id = p_correction_of_receipt_id
    FOR SHARE;

    IF v_prior_review_status IN (
      'approved_to_existing_exception',
      'rejected',
      'closed_no_action',
      'superseded'
    ) THEN
      RAISE EXCEPTION
        'Receipt correction is blocked because predecessor physical review is terminal or retailer-linked (%). Use controlled staff remediation.',
        v_prior_review_status;
    END IF;
  END IF;

  v_event_at := CASE
    WHEN v_prior_created_at IS NULL THEN clock_timestamp()
    ELSE GREATEST(clock_timestamp(), v_prior_created_at + INTERVAL '1 microsecond')
  END;

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
        'approved_for_investigation'
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

-- -----------------------------------------------------------------------------
-- AUTHORISED REPLACEMENT: public.staff_decide_physical_receipt_review_v1
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_decide_physical_receipt_review_v1(p_review_id uuid, p_decision text, p_allocations jsonb DEFAULT '[]'::jsonb, p_liable_party text DEFAULT 'unknown'::text, p_decision_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_staff record;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_order_id uuid;
  v_note text := NULLIF(BTRIM(COALESCE(p_decision_note, '')), '');
  v_decision text := lower(BTRIM(COALESCE(p_decision, '')));
  v_input_count integer := 0;
  v_proposed_count integer := 0;
  v_distinct_input_count integer := 0;
  v_bad_count integer := 0;
  v_refund_dispute_id uuid;
  v_replacement_dispute_id uuid;
  v_primary_dispute_id uuid;
  v_operator_id uuid;
  v_sop_version text;
  v_issue_type text;
  v_now timestamptz := clock_timestamp();
  v_item record;
  v_dispute_id uuid;
  v_dispute_line_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: supervisor physical receipt decision requires auth.uid().';
  END IF;

  SELECT s.id, s.role_type
  INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only active admin or supervisor staff can decide a physical receipt review.';
  END IF;

  IF v_decision NOT IN (
    'return_for_information',
    'reject',
    'close_no_action',
    'approve_investigation',
    'approve_existing_exception'
  ) THEN
    RAISE EXCEPTION 'Unsupported physical receipt decision: %', p_decision;
  END IF;

  IF v_note IS NULL THEN
    RAISE EXCEPTION 'A factual supervisor decision note is required.';
  END IF;

  IF p_liable_party NOT IN ('retailer','shipper','unknown','no_liability') THEN
    RAISE EXCEPTION 'Invalid approved liable party: %', p_liable_party;
  END IF;

  IF jsonb_typeof(COALESCE(p_allocations, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Supervisor allocation payload must be a JSON array.';
  END IF;

  SELECT review_row.order_id
  INTO v_order_id
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = p_review_id;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review not found: %', p_review_id;
  END IF;

  PERFORM 1
  FROM public.orders order_row
  WHERE order_row.id = v_order_id
  FOR UPDATE;

  PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));

  SELECT review_row.*
  INTO v_review
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = p_review_id
  FOR UPDATE;

  IF v_review.id IS NULL
     OR v_review.order_id IS DISTINCT FROM v_order_id THEN
    RAISE EXCEPTION 'Physical receipt review not found: %', p_review_id;
  END IF;

  IF v_review.status <> 'awaiting_supervisor_review' THEN
    RAISE EXCEPTION 'Physical receipt review is not awaiting supervisor review. Current status: %', v_review.status;
  END IF;

  PERFORM 1
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.physical_receipt_review_id = v_review.id
  FOR UPDATE;

  SELECT COUNT(*)::integer
  INTO v_proposed_count
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.physical_receipt_review_id = v_review.id
    AND remedy_row.status = 'proposed';

  IF v_proposed_count = 0 THEN
    RAISE EXCEPTION 'No active importer proposal rows are available for supervisor decision.';
  END IF;

  IF v_decision = 'return_for_information' THEN
    IF jsonb_array_length(COALESCE(p_allocations, '[]'::jsonb)) <> 0 THEN
      RAISE EXCEPTION 'Return-for-information must not approve remedy allocations.';
    END IF;

    UPDATE public.physical_receipt_reviews
    SET status = 'returned_for_information',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = NULL,
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'returned_for_information'
    );
  END IF;

  IF v_decision = 'reject' THEN
    IF jsonb_array_length(COALESCE(p_allocations, '[]'::jsonb)) <> 0 THEN
      RAISE EXCEPTION 'Rejected review must not approve remedy allocations.';
    END IF;

    UPDATE public.physical_exception_remedy_allocations
    SET status = 'cancelled',
        updated_at = v_now
    WHERE physical_receipt_review_id = v_review.id
      AND status = 'proposed';

    UPDATE public.physical_receipt_reviews
    SET status = 'rejected',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = NULL,
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'rejected'
    );
  END IF;

  WITH payload AS (
    SELECT *
    FROM jsonb_to_recordset(COALESCE(p_allocations, '[]'::jsonb)) AS x(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
  )
  SELECT COUNT(*)::integer,
         COUNT(DISTINCT remedy_allocation_id)::integer
  INTO v_input_count, v_distinct_input_count
  FROM payload;

  IF v_input_count = 0 THEN
    RAISE EXCEPTION 'This supervisor decision requires at least one exact allocation decision.';
  END IF;

  IF v_input_count <> v_distinct_input_count THEN
    RAISE EXCEPTION 'Each importer proposal row may appear only once. Return for a revised importer split proposal rather than inventing duplicate proposal history.';
  END IF;

  IF v_input_count <> v_proposed_count THEN
    RAISE EXCEPTION 'Every active importer proposal row must be explicitly decided. Return for information if a different split is required.';
  END IF;

  WITH payload AS (
    SELECT *
    FROM jsonb_to_recordset(COALESCE(p_allocations, '[]'::jsonb)) AS x(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
  )
  SELECT COUNT(*)::integer
  INTO v_bad_count
  FROM payload p
  LEFT JOIN public.physical_exception_remedy_allocations remedy_row
    ON remedy_row.id = p.remedy_allocation_id
   AND remedy_row.physical_receipt_review_id = v_review.id
   AND remedy_row.status = 'proposed'
  LEFT JOIN public.shipper_package_receipt_line_dispositions disposition
    ON disposition.id = remedy_row.receipt_line_disposition_id
  WHERE remedy_row.id IS NULL
     OR p.approved_remedy_type NOT IN ('refund','replacement','hold_investigate','no_action')
     OR COALESCE(p.approved_remedy_qty, 0) <= 0
     OR p.approved_remedy_qty > remedy_row.proposed_remedy_qty + 0.0005
     OR p.approved_remedy_qty > disposition.quantity + 0.0005
     OR (
       p.approved_remedy_type = 'replacement'
       AND p.supplier_cost_mode NOT IN (
         'free_replacement','charged_repurchase','pending_supplier_evidence'
       )
     )
     OR (
       p.approved_remedy_type <> 'replacement'
       AND COALESCE(p.supplier_cost_mode, 'not_applicable') <> 'not_applicable'
     );

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION 'One or more supervisor allocation decisions are invalid, exceed proposed/source quantity, or have incompatible supplier-cost mode.';
  END IF;

  IF v_decision = 'close_no_action' THEN
    IF p_liable_party <> 'no_liability' THEN
      RAISE EXCEPTION 'Close-no-action requires approved liable party no_liability.';
    END IF;

    WITH payload AS (
      SELECT *
      FROM jsonb_to_recordset(p_allocations) AS x(
        remedy_allocation_id uuid,
        approved_remedy_type text,
        approved_remedy_qty numeric,
        supplier_cost_mode text
      )
    )
    SELECT COUNT(*)::integer INTO v_bad_count
    FROM payload
    WHERE approved_remedy_type <> 'no_action';

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'Close-no-action may approve only no_action allocations.';
    END IF;
  ELSIF v_decision = 'approve_investigation' THEN
    WITH payload AS (
      SELECT *
      FROM jsonb_to_recordset(p_allocations) AS x(
        remedy_allocation_id uuid,
        approved_remedy_type text,
        approved_remedy_qty numeric,
        supplier_cost_mode text
      )
    )
    SELECT COUNT(*)::integer INTO v_bad_count
    FROM payload
    WHERE approved_remedy_type <> 'hold_investigate';

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'Investigation approval may approve only hold_investigate allocations.';
    END IF;
  ELSE
    WITH payload AS (
      SELECT *
      FROM jsonb_to_recordset(p_allocations) AS x(
        remedy_allocation_id uuid,
        approved_remedy_type text,
        approved_remedy_qty numeric,
        supplier_cost_mode text
      )
    )
    SELECT COUNT(*)::integer INTO v_bad_count
    FROM payload
    WHERE approved_remedy_type NOT IN ('refund','replacement')
       OR ABS(approved_remedy_qty - ROUND(approved_remedy_qty)) > 0.0005;

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'Existing refund/replacement routes accept whole-unit quantities only. Fractional quantities are not rounded.';
    END IF;

    IF p_liable_party = 'no_liability' THEN
      RAISE EXCEPTION 'Refund/replacement approval cannot use no_liability.';
    END IF;
  END IF;

  WITH payload AS (
    SELECT *
    FROM jsonb_to_recordset(p_allocations) AS x(
      remedy_allocation_id uuid,
      approved_remedy_type text,
      approved_remedy_qty numeric,
      supplier_cost_mode text
    )
  )
  UPDATE public.physical_exception_remedy_allocations remedy_row
  SET approved_remedy_type = payload.approved_remedy_type,
      approved_remedy_qty = ROUND(payload.approved_remedy_qty, 3),
      approved_by_staff_id = v_staff.id,
      approved_at = v_now,
      supplier_cost_mode = CASE
        WHEN payload.approved_remedy_type = 'replacement'
          THEN payload.supplier_cost_mode
        ELSE 'not_applicable'
      END,
      status = CASE
        WHEN payload.approved_remedy_type = 'no_action'
          THEN 'closed_no_action'
        ELSE 'approved'
      END,
      updated_at = v_now
  FROM payload
  WHERE remedy_row.id = payload.remedy_allocation_id;

  IF v_decision = 'close_no_action' THEN
    UPDATE public.physical_receipt_reviews
    SET status = 'closed_no_action',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = 'no_liability',
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'closed_no_action'
    );
  END IF;

  IF v_decision = 'approve_investigation' THEN
    UPDATE public.physical_exception_remedy_allocations
    SET status = 'in_progress',
        updated_at = v_now
    WHERE physical_receipt_review_id = v_review.id
      AND status = 'approved'
      AND approved_remedy_type = 'hold_investigate';

    UPDATE public.physical_receipt_reviews
    SET status = 'approved_for_investigation',
        supervisor_decided_by_staff_id = v_staff.id,
        supervisor_decided_at = v_now,
        approved_liable_party = p_liable_party,
        decision_note = v_note,
        updated_at = v_now
    WHERE id = v_review.id;

    RETURN jsonb_build_object(
      'ok', true,
      'review_id', v_review.id,
      'status', 'approved_for_investigation'
    );
  END IF;


  -- HYBRID_PHYSICAL_RECEIPT_V1_2_VALUE_PARTITION_BRIDGE
  SELECT o.operator_id, o.sop_version
  INTO v_operator_id, v_sop_version
  FROM public.orders o
  WHERE o.id = v_review.order_id
  FOR UPDATE;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Order operator could not be resolved for physical exception linkage.';
  END IF;

  -- Serialize the commercial-value source before deriving customer value.
  PERFORM 1
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id IN (
    SELECT remedy_row.tracking_line_allocation_id
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
  )
  ORDER BY allocation.id
  FOR UPDATE;

  IF EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    LEFT JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = remedy_row.tracking_line_allocation_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
      AND (
        allocation.id IS NULL
        OR allocation.order_id <> v_review.order_id
        OR allocation.supplier_invoice_line_id <> remedy_row.supplier_invoice_line_id
        OR allocation.qty_allocated <= 0
        OR allocation.adjusted_net_value_gbp <= 0
        OR remedy_row.approved_remedy_qty <= 0
        OR remedy_row.approved_remedy_qty > allocation.qty_allocated + 0.0005
      )
  ) THEN
    RAISE EXCEPTION 'Approved physical remedy has ambiguous or non-positive tracking-allocation commercial provenance.';
  END IF;

  -- Deterministic penny apportionment within each tracking allocation.
  WITH source_rows AS (
    SELECT
      remedy_row.id AS remedy_allocation_id,
      remedy_row.tracking_line_allocation_id,
      (allocation.adjusted_net_value_gbp * 100
        * remedy_row.approved_remedy_qty / allocation.qty_allocated) AS raw_cents
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.order_tracking_line_allocations allocation
      ON allocation.id = remedy_row.tracking_line_allocation_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
  ), ranked AS (
    SELECT
      source_rows.*,
      floor(raw_cents)::bigint AS floor_cents,
      row_number() OVER (
        PARTITION BY tracking_line_allocation_id
        ORDER BY (raw_cents - floor(raw_cents)) DESC, remedy_allocation_id
      ) AS remainder_rank,
      round(sum(raw_cents) OVER (PARTITION BY tracking_line_allocation_id))::bigint
        - sum(floor(raw_cents)::bigint) OVER (PARTITION BY tracking_line_allocation_id)
        AS pennies_to_distribute
    FROM source_rows
  ), apportioned AS (
    SELECT
      remedy_allocation_id,
      (floor_cents + CASE WHEN remainder_rank <= pennies_to_distribute THEN 1 ELSE 0 END)::numeric / 100
        AS commercial_value_gbp
    FROM ranked
  )
  UPDATE public.physical_exception_remedy_allocations remedy_row
  SET customer_commercial_value_gbp = apportioned.commercial_value_gbp,
      updated_at = v_now
  FROM apportioned
  WHERE remedy_row.id = apportioned.remedy_allocation_id;

  IF EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
      AND COALESCE(remedy_row.customer_commercial_value_gbp, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'Customer commercial value apportionment produced a missing or non-positive result.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines existing_line
    WHERE existing_line.supplier_invoice_line_id IN (
      SELECT remedy_row.supplier_invoice_line_id
      FROM public.physical_exception_remedy_allocations remedy_row
      WHERE remedy_row.physical_receipt_review_id = v_review.id
        AND remedy_row.status = 'approved'
        AND remedy_row.approved_remedy_type IN ('refund','replacement')
    )
      AND existing_line.resolved_at IS NULL
      AND existing_line.physical_remedy_allocation_id IS NULL
  ) THEN
    RAISE EXCEPTION 'An ambiguous unresolved legacy exception already exists for an approved physical source line.';
  END IF;

  FOR v_item IN
    SELECT
      remedy_row.id AS remedy_allocation_id,
      remedy_row.approved_remedy_type,
      remedy_row.approved_remedy_qty,
      remedy_row.supplier_invoice_line_id,
      remedy_row.customer_commercial_value_gbp,
      disposition.disposition_type
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN public.shipper_package_receipt_line_dispositions disposition
      ON disposition.id = remedy_row.receipt_line_disposition_id
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status = 'approved'
      AND remedy_row.approved_remedy_type IN ('refund','replacement')
    ORDER BY
      CASE remedy_row.approved_remedy_type WHEN 'refund' THEN 1 ELSE 2 END,
      remedy_row.supplier_invoice_line_id,
      disposition.disposition_type,
      remedy_row.id
  LOOP
    v_issue_type := CASE v_item.disposition_type
      WHEN 'missing' THEN 'missing'
      WHEN 'damaged' THEN 'damaged'
      WHEN 'wrong' THEN 'wrong_item'
      ELSE NULL
    END;

    IF v_issue_type IS NULL THEN
      RAISE EXCEPTION 'Disposition % cannot enter the existing refund/replacement route automatically.', v_item.disposition_type;
    END IF;

    v_dispute_id := NULL;

    IF v_item.approved_remedy_type = 'refund' THEN
      SELECT d.id
      INTO v_dispute_id
      FROM public.physical_receipt_review_dispute_links link_row
      JOIN public.disputes d ON d.id = link_row.dispute_id
      JOIN public.dispute_lines dl ON dl.dispute_id = d.id
      WHERE link_row.physical_receipt_review_id = v_review.id
        AND link_row.desired_outcome = 'refund'
        AND d.order_id = v_review.order_id
        AND d.issue_type = v_issue_type
        AND d.desired_outcome = 'refund'
        AND d.liable_party = p_liable_party
        AND dl.supplier_invoice_line_id = v_item.supplier_invoice_line_id
      ORDER BY d.id
      LIMIT 1;
    END IF;

    IF v_dispute_id IS NULL THEN
      INSERT INTO public.disputes (
        order_id,
        raised_by_operator_id,
        issue_type,
        desired_outcome,
        liable_party,
        stage_detected,
        amount_impact_gbp,
        comments_initial,
        status,
        sop_version,
        refund_approved_by_staff_id,
        refund_approved_at
      ) VALUES (
        v_review.order_id,
        v_operator_id,
        v_issue_type,
        v_item.approved_remedy_type,
        p_liable_party,
        'at_ghana_delivery',
        v_item.customer_commercial_value_gbp,
        'Created from physical receipt review ' || v_review.id::text || '. Customer commercial value is sourced only from order_tracking_line_allocations.adjusted_net_value_gbp; supplier recovery, settlement, VAT, accounting and funding remain separate.',
        'raised',
        v_sop_version,
        CASE WHEN v_item.approved_remedy_type = 'refund' THEN v_staff.id ELSE NULL END,
        CASE WHEN v_item.approved_remedy_type = 'refund' THEN v_now ELSE NULL END
      )
      RETURNING id INTO v_dispute_id;

      INSERT INTO public.physical_receipt_review_dispute_links (
        physical_receipt_review_id,
        dispute_id,
        desired_outcome,
        created_by_staff_id,
        created_at
      ) VALUES (
        v_review.id,
        v_dispute_id,
        v_item.approved_remedy_type,
        v_staff.id,
        v_now
      );
    ELSE
      -- A refund group may have only one physical remedy under the live one-line-per-invoice constraints.
      IF EXISTS (
        SELECT 1
        FROM public.dispute_lines dl
        WHERE dl.dispute_id = v_dispute_id
          AND dl.supplier_invoice_line_id = v_item.supplier_invoice_line_id
      ) THEN
        RAISE EXCEPTION 'Multiple approved physical refund allocations resolve to the same invoice/issue group under a one-line live constraint. Return for a revised importer split rather than guessing.';
      END IF;
    END IF;

    INSERT INTO public.dispute_lines (
      dispute_id,
      supplier_invoice_line_id,
      qty_impact,
      amount_impact_gbp,
      line_status,
      intended_remedy,
      conversation_status,
      physical_remedy_allocation_id
    ) VALUES (
      v_dispute_id,
      v_item.supplier_invoice_line_id,
      ROUND(v_item.approved_remedy_qty)::integer,
      v_item.customer_commercial_value_gbp,
      'affected',
      v_item.approved_remedy_type,
      CASE
        WHEN v_item.approved_remedy_type = 'refund' THEN 'refund_pending_approval'
        ELSE 'remedy_selected'
      END,
      v_item.remedy_allocation_id
    )
    RETURNING id INTO v_dispute_line_id;

    UPDATE public.physical_exception_remedy_allocations
    SET dispute_line_id = v_dispute_line_id,
        updated_at = v_now
    WHERE id = v_item.remedy_allocation_id;

    UPDATE public.disputes dispute_row
    SET amount_impact_gbp = (
      SELECT round(sum(dl.amount_impact_gbp), 2)
      FROM public.dispute_lines dl
      WHERE dl.dispute_id = dispute_row.id
    )
    WHERE dispute_row.id = v_dispute_id;

    IF v_item.approved_remedy_type = 'refund' AND v_refund_dispute_id IS NULL THEN
      v_refund_dispute_id := v_dispute_id;
    ELSIF v_item.approved_remedy_type = 'replacement' AND v_replacement_dispute_id IS NULL THEN
      v_replacement_dispute_id := v_dispute_id;
    END IF;
  END LOOP;

  SELECT link_row.dispute_id
  INTO v_primary_dispute_id
  FROM public.physical_receipt_review_dispute_links link_row
  WHERE link_row.physical_receipt_review_id = v_review.id
  ORDER BY
    CASE link_row.desired_outcome WHEN 'refund' THEN 1 ELSE 2 END,
    link_row.dispute_id
  LIMIT 1;

  IF v_primary_dispute_id IS NULL THEN
    RAISE EXCEPTION 'No outcome-specific dispute was linked for the approved physical review.';
  END IF;

  UPDATE public.physical_receipt_reviews
  SET status = 'approved_to_existing_exception',
      supervisor_decided_by_staff_id = v_staff.id,
      supervisor_decided_at = v_now,
      approved_liable_party = p_liable_party,
      decision_note = v_note,
      linked_dispute_id = v_primary_dispute_id,
      updated_at = v_now
  WHERE id = v_review.id;

  -- LINK_SHAPE_SEQUENCE_V1: establish the required review link before terminal remedy status.
  UPDATE public.physical_exception_remedy_allocations
  SET status = 'linked_to_exception',
      updated_at = v_now
  WHERE physical_receipt_review_id = v_review.id
    AND status = 'approved'
    AND approved_remedy_type IN ('refund','replacement')
    AND dispute_line_id IS NOT NULL;

  RETURN jsonb_build_object(
    'ok', true,
    'review_id', v_review.id,
    'status', 'approved_to_existing_exception',
    'primary_dispute_id', v_primary_dispute_id,
    'refund_dispute_id', v_refund_dispute_id,
    'replacement_dispute_id', v_replacement_dispute_id
  );
END;
$function$;

-- -----------------------------------------------------------------------------
-- AUTHORISED REPLACEMENT: public.internal_materialize_customer_review_cycles_v1
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.internal_materialize_customer_review_cycles_v1(p_order_id uuid, p_created_by_staff_id uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_active_total_count integer;
  v_active_timed_count integer;
  v_active_untimed_count integer;
  v_link_id uuid;
  v_deadline timestamptz;
  v_anchor_receipt timestamptz;
  v_inserted integer := 0;
  v_total_inserted integer := 0;
BEGIN
  PERFORM 1
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('customer_review_cycle|' || p_order_id::text)
  );

  UPDATE public.customer_order_review_links link_row
  SET is_active = false
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at <= now();

  UPDATE public.customer_review_cycle_memberships membership
  SET membership_status = 'expired',
      status_updated_at = COALESCE(membership.status_updated_at, now())
  FROM public.customer_order_review_links link_row
  WHERE link_row.id = membership.review_link_id
    AND link_row.order_id = p_order_id
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at <= now()
    AND membership.membership_status = 'active';

  SELECT COUNT(*)::integer
  INTO v_active_total_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true;

  IF v_active_total_count > 1 THEN
    INSERT INTO public.customer_review_cycle_legacy_issues (
      order_id,
      issue_code,
      issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_review_links',
      'More than one active review link exists. No membership is guessed and review-cycle materialisation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;

    RETURN 0;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_active_untimed_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NULL;

  IF v_active_untimed_count > 1 THEN
    INSERT INTO public.customer_review_cycle_legacy_issues (
      order_id,
      issue_code,
      issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_untimed_review_links',
      'More than one active untimed legacy review link exists. Compatibility is preserved and new timed-cycle creation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;

    RETURN 0;
  END IF;

  IF v_active_untimed_count = 1 THEN
    RETURN 0;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_review_cycle_legacy_issues issue
    WHERE issue.order_id = p_order_id
      AND issue.resolved_at IS NULL
  ) THEN
    RETURN 0;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_active_timed_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now();

  IF v_active_timed_count > 1 THEN
    INSERT INTO public.customer_review_cycle_legacy_issues (
      order_id,
      issue_code,
      issue_detail
    ) VALUES (
      p_order_id,
      'multiple_active_timed_review_links',
      'More than one active timed review link exists. No membership is guessed and cycle materialisation fails closed.'
    )
    ON CONFLICT (order_id, issue_code) DO NOTHING;

    RETURN 0;
  END IF;

  SELECT
    link_row.id,
    link_row.expires_at
  INTO
    v_link_id,
    v_deadline
  FROM public.customer_order_review_links link_row
  WHERE link_row.order_id = p_order_id
    AND link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now()
  ORDER BY link_row.created_at, link_row.id
  LIMIT 1
  FOR UPDATE;

  IF v_link_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = v_link_id
    ) THEN
      INSERT INTO public.customer_review_cycle_legacy_issues (
        order_id,
        review_link_id,
        issue_code,
        issue_detail
      ) VALUES (
        p_order_id,
        v_link_id,
        'pre_mini4_timed_membership_unproven',
        'The existing timed link and stored deadline were preserved, but exact historical membership cannot be proven without guessing.'
      )
      ON CONFLICT (order_id, issue_code) DO NOTHING;

      RETURN 0;
    END IF;

    INSERT INTO public.customer_review_cycle_memberships (
      review_link_id,
      order_id,
      supplier_invoice_id,
      supplier_invoice_line_id,
      tracking_submission_id,
      tracking_line_allocation_id,
      review_qty,
      goods_amount_gbp,
      delivery_share_gbp,
      discount_share_gbp,
      receipt_recorded_at,
      membership_status,
      membership_fingerprint,
      legacy_backfill_yn,
      created_by_staff_id
    )
    SELECT
      v_link_id,
      candidate.order_id,
      candidate.supplier_invoice_id,
      candidate.supplier_invoice_line_id,
      candidate.tracking_submission_id,
      candidate.tracking_line_allocation_id,
      candidate.review_qty,
      candidate.goods_amount_gbp,
      candidate.delivery_share_gbp,
      candidate.discount_share_gbp,
      candidate.receipt_recorded_at,
      'active',
      md5(v_link_id::text || '|' || candidate.source_fingerprint),
      false,
      p_created_by_staff_id
    FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
    WHERE candidate.receipt_recorded_at < v_deadline
      AND candidate.receipt_recorded_at + interval '2 minutes' > now()
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    RETURN v_inserted;
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS customer_review_cycle_candidate_buffer_v1
  ON COMMIT DROP
  AS
  SELECT candidate.*
  FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
  WHERE false;

  TRUNCATE TABLE pg_temp.customer_review_cycle_candidate_buffer_v1;

  INSERT INTO pg_temp.customer_review_cycle_candidate_buffer_v1
  SELECT candidate.*
  FROM public.customer_review_cycle_candidates_v1(p_order_id) candidate
  WHERE candidate.receipt_recorded_at <= now()
    AND candidate.receipt_recorded_at + interval '2 minutes' > now();

  SELECT MIN(candidate.receipt_recorded_at)
  INTO v_anchor_receipt
  FROM pg_temp.customer_review_cycle_candidate_buffer_v1 candidate;

  IF v_anchor_receipt IS NULL THEN
    RETURN 0;
  END IF;

  v_deadline := v_anchor_receipt + interval '2 minutes';

  INSERT INTO public.customer_order_review_links (
    order_id,
    is_active,
    expires_at,
    created_by_staff_id
  ) VALUES (
    p_order_id,
    true,
    v_deadline,
    p_created_by_staff_id
  )
  RETURNING id INTO v_link_id;

  INSERT INTO public.customer_review_cycle_memberships (
    review_link_id,
    order_id,
    supplier_invoice_id,
    supplier_invoice_line_id,
    tracking_submission_id,
    tracking_line_allocation_id,
    review_qty,
    goods_amount_gbp,
    delivery_share_gbp,
    discount_share_gbp,
    receipt_recorded_at,
    membership_status,
    membership_fingerprint,
    legacy_backfill_yn,
    created_by_staff_id
  )
  SELECT
    v_link_id,
    candidate.order_id,
    candidate.supplier_invoice_id,
    candidate.supplier_invoice_line_id,
    candidate.tracking_submission_id,
    candidate.tracking_line_allocation_id,
    candidate.review_qty,
    candidate.goods_amount_gbp,
    candidate.delivery_share_gbp,
    candidate.discount_share_gbp,
    candidate.receipt_recorded_at,
    'active',
    md5(v_link_id::text || '|' || candidate.source_fingerprint),
    false,
    p_created_by_staff_id
  FROM pg_temp.customer_review_cycle_candidate_buffer_v1 candidate
  WHERE candidate.receipt_recorded_at < v_deadline
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_total_inserted = ROW_COUNT;

  IF v_total_inserted = 0 THEN
    DELETE FROM public.customer_order_review_links
    WHERE id = v_link_id;

    RETURN 0;
  END IF;

  RETURN v_total_inserted;
END;
$function$;

DO $postflight$
DECLARE
  r record;
  v_proc regprocedure;
  v_meta pg_catalog.pg_proc%ROWTYPE;
  v_def text;
  v_a integer;
  v_b integer;
  v_c integer;
  v_d integer;
  v_e integer;
  v_f integer;
BEGIN
  -- Exact target definitions must be the four reviewed replacements.
  FOR r IN
    SELECT *
    FROM (VALUES
      ('public.internal_classify_supplier_invoice_rejection_v1(uuid,boolean,text)', '52ccf4261d17111295c4334432d94589'),
      ('public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)', '35967513efb08b00088b0d3d7890e92a'),
      ('public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)', 'eed5b08c3a31857e1c05319ed80e5c87'),
      ('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)', '6d73f3fb4aeb25ba517f02412e845695')
    ) AS expected(signature, expected_md5)
  LOOP
    v_proc := to_regprocedure(r.signature);

    IF v_proc IS NULL
       OR md5(replace(pg_get_functiondef(v_proc::oid), E'\r\n', E'\n')) IS DISTINCT FROM r.expected_md5
    THEN
      RAISE EXCEPTION 'Postflight failed: target definition % is not the reviewed replacement.', r.signature;
    END IF;
  END LOOP;

  -- Gap 1: fs lock -> invoice lock -> breach-flag lock -> bundle advisory
  -- -> order-row lock -> generic order advisory.
  SELECT pg_get_functiondef(
    'public.internal_classify_supplier_invoice_rejection_v1(uuid,boolean,text)'::regprocedure
  ) INTO v_def;
  v_a := strpos(v_def, 'FOR UPDATE OF fs;');
  v_b := strpos(v_def, 'FOR UPDATE OF si;');
  v_c := strpos(v_def, 'FOR UPDATE OF f;');
  v_d := strpos(v_def, 'hashtext(''order_bundle_limit:'' || v_order_id::text)');
  v_e := strpos(v_def, 'WHERE o.id = v_order_id' || chr(13) || chr(10) || '  FOR UPDATE;');
  IF v_e = 0 THEN
    v_e := strpos(v_def, 'WHERE o.id = v_order_id' || chr(10) || '  FOR UPDATE;');
  END IF;
  v_f := strpos(v_def, 'hashtext(v_order_id::text)');
  IF NOT (v_a > 0 AND v_b > v_a AND v_c > v_b AND v_d > v_c AND v_e > v_d AND v_f > v_e) THEN
    RAISE EXCEPTION 'Postflight failed: Gap 1 actual lock clauses are not in the frozen order.';
  END IF;

  -- Gap 2: order-row lock -> order advisory -> tracking-row lock
  -- -> identity revalidation -> tracking advisory -> allocation-row lock.
  SELECT pg_get_functiondef(
    'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)'::regprocedure
  ) INTO v_def;
  v_a := strpos(v_def, 'WHERE o.id = v_order_id' || chr(13) || chr(10) || '  FOR UPDATE;');
  IF v_a = 0 THEN
    v_a := strpos(v_def, 'WHERE o.id = v_order_id' || chr(10) || '  FOR UPDATE;');
  END IF;
  v_b := strpos(v_def, 'hashtext(v_order_id::text)');
  v_c := strpos(v_def, 'WHERE ots.id = p_tracking_submission_id' || chr(13) || chr(10) ||
                       '    AND ots.superseded_at IS NULL' || chr(13) || chr(10) || '  FOR UPDATE;');
  IF v_c = 0 THEN
    v_c := strpos(v_def, 'WHERE ots.id = p_tracking_submission_id' || chr(10) ||
                         '    AND ots.superseded_at IS NULL' || chr(10) || '  FOR UPDATE;');
  END IF;
  v_d := strpos(v_def, 'OR v_locked_order_id IS DISTINCT FROM v_order_id THEN');
  v_e := strpos(v_def, 'hashtext(p_tracking_submission_id::text)');
  v_f := strpos(v_def, 'ORDER BY a.id' || chr(13) || chr(10) || '  FOR UPDATE;');
  IF v_f = 0 THEN
    v_f := strpos(v_def, 'ORDER BY a.id' || chr(10) || '  FOR UPDATE;');
  END IF;
  IF NOT (v_a > 0 AND v_b > v_a AND v_c > v_b AND v_d > v_c AND v_e > v_d AND v_f > v_e) THEN
    RAISE EXCEPTION 'Postflight failed: Gap 2 actual lock/revalidation clauses are not in the frozen order.';
  END IF;

  -- Gap 3: order-row lock -> generic order advisory -> exact review-row lock
  -- -> remedy-row lock.
  SELECT pg_get_functiondef(
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure
  ) INTO v_def;
  v_a := strpos(v_def, 'WHERE order_row.id = v_order_id' || chr(10) || '  FOR UPDATE;');
  IF v_a = 0 THEN
    v_a := strpos(v_def, 'WHERE order_row.id = v_order_id' || chr(13) || chr(10) || '  FOR UPDATE;');
  END IF;
  v_b := strpos(v_def, 'hashtext(v_order_id::text)');
  v_c := strpos(v_def, 'WHERE review_row.id = p_review_id' || chr(10) || '  FOR UPDATE;');
  IF v_c = 0 THEN
    v_c := strpos(v_def, 'WHERE review_row.id = p_review_id' || chr(13) || chr(10) || '  FOR UPDATE;');
  END IF;
  v_d := strpos(v_def, 'WHERE remedy_row.physical_receipt_review_id = v_review.id' || chr(10) || '  FOR UPDATE;');
  IF v_d = 0 THEN
    v_d := strpos(v_def, 'WHERE remedy_row.physical_receipt_review_id = v_review.id' || chr(13) || chr(10) || '  FOR UPDATE;');
  END IF;
  IF NOT (v_a > 0 AND v_b > v_a AND v_c > v_b AND v_d > v_c) THEN
    RAISE EXCEPTION 'Postflight failed: Gap 3 actual lock clauses are not in the frozen order.';
  END IF;

  -- Gap 4: order-row lock -> existing customer-review-cycle advisory.
  SELECT pg_get_functiondef(
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure
  ) INTO v_def;
  v_a := strpos(v_def, 'FROM public.orders' || chr(13) || chr(10) ||
                       '  WHERE id = p_order_id' || chr(13) || chr(10) || '  FOR UPDATE;');
  IF v_a = 0 THEN
    v_a := strpos(v_def, 'FROM public.orders' || chr(10) ||
                         '  WHERE id = p_order_id' || chr(10) || '  FOR UPDATE;');
  END IF;
  v_b := strpos(v_def, 'hashtext(''customer_review_cycle|'' || p_order_id::text)');
  IF NOT (v_a > 0 AND v_b > v_a) THEN
    RAISE EXCEPTION 'Postflight failed: Gap 4 actual lock clauses are not in the frozen order.';
  END IF;


  FOR r IN
    SELECT *
    FROM (VALUES
      (
        'public.internal_classify_supplier_invoice_rejection_v1(uuid,boolean,text)',
        '{postgres=X/postgres,service_role=X/postgres}',
        'uuid'::regtype::oid,
        true,
        'uuid, boolean, text',
        ARRAY['uuid'::regtype::oid,'boolean'::regtype::oid,'text'::regtype::oid,'uuid'::regtype::oid]::oid[],
        ARRAY['i','i','i','t']::"char"[],
        ARRAY['p_supplier_invoice_id','p_requires_resubmission','p_review_notes','order_id']::text[]
      ),
      (
        'public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)',
        '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
        'jsonb'::regtype::oid,
        false,
        'uuid, uuid, jsonb, jsonb, uuid, text',
        NULL::oid[],
        NULL::"char"[],
        ARRAY['p_tracking_submission_id','p_receipt_submission_id','p_dispositions','p_evidence','p_correction_of_receipt_id','p_correction_reason']::text[]
      ),
      (
        'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
        '{postgres=X/postgres,service_role=X/postgres}',
        'jsonb'::regtype::oid,
        false,
        'uuid, text, jsonb, text, text',
        NULL::oid[],
        NULL::"char"[],
        ARRAY['p_review_id','p_decision','p_allocations','p_liable_party','p_decision_note']::text[]
      ),
      (
        'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)',
        '{postgres=X/postgres,service_role=X/postgres}',
        'integer'::regtype::oid,
        false,
        'uuid, uuid',
        NULL::oid[],
        NULL::"char"[],
        ARRAY['p_order_id','p_created_by_staff_id']::text[]
      )
    ) AS expected(
      signature,
      expected_acl,
      expected_rettype,
      expected_returns_set,
      expected_argtypes,
      expected_allargtypes,
      expected_argmodes,
      expected_argnames
    )
  LOOP
    v_proc := to_regprocedure(r.signature);

    IF v_proc IS NULL THEN
      RAISE EXCEPTION 'Concurrency repair metadata check failed: required target function % is missing.', r.signature;
    END IF;

    SELECT p.*
    INTO v_meta
    FROM pg_catalog.pg_proc p
    WHERE p.oid = v_proc::oid;

    IF v_meta.proowner IS DISTINCT FROM 'postgres'::regrole::oid
       OR v_meta.proacl::text IS DISTINCT FROM r.expected_acl
       OR v_meta.proconfig IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[]
       OR v_meta.prosecdef IS DISTINCT FROM true
       OR v_meta.proleakproof IS DISTINCT FROM false
       OR v_meta.provolatile IS DISTINCT FROM 'v'::"char"
       OR v_meta.proparallel IS DISTINCT FROM 'u'::"char"
       OR v_meta.prokind IS DISTINCT FROM 'f'::"char"
       OR v_meta.prorettype IS DISTINCT FROM r.expected_rettype
       OR v_meta.proretset IS DISTINCT FROM r.expected_returns_set
       OR pg_catalog.oidvectortypes(v_meta.proargtypes) IS DISTINCT FROM r.expected_argtypes
       OR v_meta.proallargtypes IS DISTINCT FROM r.expected_allargtypes
       OR v_meta.proargmodes IS DISTINCT FROM r.expected_argmodes
       OR v_meta.proargnames IS DISTINCT FROM r.expected_argnames
    THEN
      RAISE EXCEPTION 'Concurrency repair metadata check failed for %. No changes may proceed.', r.signature;
    END IF;
  END LOOP;

  -- Protected authorities/wrappers/callers remain byte-identical.
  IF md5(pg_get_functiondef('public.staff_approve_order_supplier_price_increase_v1(uuid,uuid,text)'::regprocedure)) IS DISTINCT FROM '74e3144de22e56f01e73f91965fb60dc'
     OR md5(pg_get_functiondef('public.delivery_allocate_tracking_lines_bulk_v1(uuid,text,uuid,uuid[],boolean)'::regprocedure)) IS DISTINCT FROM 'c423bbb2a1e1bd79b8a0915924eddcb7'
     OR md5(pg_get_functiondef('public.shipper_package_receipt_write_compatibility_guard_v1()'::regprocedure)) IS DISTINCT FROM '8b4f88ff3b4633565805d6c1491bff1c'
     OR md5(pg_get_functiondef('public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text)'::regprocedure)) IS DISTINCT FROM 'c25e19d36bb3891419c5ab58ad23b9b6'
     OR md5(pg_get_functiondef('public.staff_reject_supplier_invoice_resubmission(uuid,text)'::regprocedure)) IS DISTINCT FROM '05e93b802ceecee5b5439dec8dcf58ee'
     OR md5(pg_get_functiondef('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)'::regprocedure)) IS DISTINCT FROM '9b95dd57340cd844e80c349e0732b64d'
     OR md5(pg_get_functiondef('public.customer_active_order_review_link_v1(uuid)'::regprocedure)) IS DISTINCT FROM 'f78b2fcb4186614396327e8c970e2ef9'
  THEN
    RAISE EXCEPTION 'Postflight failed: a protected authority or wrapper/caller changed.';
  END IF;
END;
$postflight$;


COMMIT;

-- Migration complete only if COMMIT succeeds.
-- Deterministic two-session concurrency proof remains a separate execution step.
