BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL
     OR to_regclass('public.shipper_package_receipt_evidence') IS NULL
     OR to_regclass('public.physical_receipt_review_dispute_links') IS NULL
     OR to_regclass('public.operator_importers') IS NULL
     OR to_regclass('public.operators') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.retailers') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('storage.objects') IS NULL
  THEN
    RAISE EXCEPTION 'Physical receipt operational read prerequisites are missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_receipt_reviews'
      AND column_name = 'importer_proposal_note'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_exception_remedy_allocations'
      AND column_name = 'supplier_cost_mode'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_receipt_review_dispute_links'
      AND column_name = 'desired_outcome'
  ) THEN
    RAISE EXCEPTION 'Physical receipt operational read columns differ from the audited contract.';
  END IF;

  IF to_regprocedure('public.importer_physical_receipt_reviews_v1(uuid)') IS NOT NULL
     OR to_regprocedure('public.staff_physical_receipt_reviews_v1(uuid)') IS NOT NULL
     OR to_regprocedure('public.can_read_physical_receipt_evidence_v1(text)') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Physical receipt operational read authority already exists; inspect before replacing.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
        'physical_receipt_evidence_importer_read_v1',
        'physical_receipt_evidence_staff_read_v1'
      )
  ) THEN
    RAISE EXCEPTION 'Physical receipt evidence storage policy already exists; inspect before replacing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.can_read_physical_receipt_evidence_v1(
  p_storage_object_path text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  SELECT auth.uid() IS NOT NULL
    AND NULLIF(BTRIM(COALESCE(p_storage_object_path, '')), '') IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.shipper_package_receipt_evidence evidence
      JOIN public.physical_receipt_reviews review
        ON review.receipt_id = evidence.receipt_id
      WHERE evidence.storage_object_path = p_storage_object_path
        AND (
          EXISTS (
            SELECT 1
            FROM public.operators operator_row
            JOIN public.operator_importers access_row
              ON access_row.operator_id = operator_row.id
             AND access_row.importer_id = review.importer_id
             AND access_row.revoked_at IS NULL
            WHERE operator_row.auth_user_id = auth.uid()
              AND COALESCE(operator_row.active, true) = true
          )
          OR EXISTS (
            SELECT 1
            FROM public.staff staff_row
            WHERE staff_row.auth_user_id = auth.uid()
              AND COALESCE(staff_row.active, true) = true
              AND staff_row.role_type IN ('admin','supervisor')
          )
        )
    );
$function$;

COMMENT ON FUNCTION public.can_read_physical_receipt_evidence_v1(text) IS
'Exact object-path evidence authorization for an active importer operator assigned to the review importer or an active supervisor/admin. Read-only and auth.uid()-bound.';

REVOKE ALL ON FUNCTION public.can_read_physical_receipt_evidence_v1(text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_read_physical_receipt_evidence_v1(text)
TO authenticated;

CREATE POLICY physical_receipt_evidence_importer_read_v1
ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'invoice-evidence'
  AND public.can_read_physical_receipt_evidence_v1(name)
  AND EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_evidence evidence
    JOIN public.physical_receipt_reviews review
      ON review.receipt_id = evidence.receipt_id
    JOIN public.operator_importers access_row
      ON access_row.importer_id = review.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row
      ON operator_row.id = access_row.operator_id
    WHERE evidence.storage_object_path = storage.objects.name
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
);

CREATE POLICY physical_receipt_evidence_staff_read_v1
ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'invoice-evidence'
  AND public.can_read_physical_receipt_evidence_v1(name)
  AND EXISTS (
    SELECT 1
    FROM public.staff staff_row
    WHERE staff_row.auth_user_id = auth.uid()
      AND COALESCE(staff_row.active, true) = true
      AND staff_row.role_type IN ('admin','supervisor')
  )
);

CREATE FUNCTION public.importer_physical_receipt_reviews_v1(
  p_review_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH caller AS (
    SELECT op.id AS operator_id
    FROM public.operators op
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
    ORDER BY op.id
    LIMIT 1
  ), allowed AS (
    SELECT review.*
    FROM public.physical_receipt_reviews review
    JOIN caller c ON true
    JOIN public.operator_importers oi
      ON oi.operator_id = c.operator_id
     AND oi.importer_id = review.importer_id
     AND oi.revoked_at IS NULL
    WHERE (
      p_review_id IS NULL
      AND review.status IN ('awaiting_importer_proposal','returned_for_information')
    ) OR review.id = p_review_id
  ), rows AS (
    SELECT jsonb_build_object(
      'id', review.id,
      'status', review.status,
      'created_at', review.created_at,
      'updated_at', review.updated_at,
      'order_id', review.order_id,
      'order_ref', o.order_ref,
      'retailer_name', retailer.name,
      'tracking_submission_id', review.tracking_submission_id,
      'tracking_ref', tracking.tracking_ref,
      'receipt_id', review.receipt_id,
      'importer_proposal_note', review.importer_proposal_note,
      'decision_note', review.decision_note,
      'affected_quantity', COALESCE((
        SELECT SUM(d.quantity)
        FROM public.shipper_package_receipt_line_dispositions d
        WHERE d.receipt_id = review.receipt_id
          AND d.disposition_type <> 'clean'
      ), 0),
      'dispositions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', d.id,
          'tracking_line_allocation_id', d.tracking_line_allocation_id,
          'supplier_invoice_line_id', d.supplier_invoice_line_id,
          'item_description', sil.description,
          'disposition_type', d.disposition_type,
          'quantity', d.quantity,
          'condition_note', d.condition_note
        ) ORDER BY sil.line_order NULLS LAST, d.id)
        FROM public.shipper_package_receipt_line_dispositions d
        JOIN public.supplier_invoice_lines sil ON sil.id = d.supplier_invoice_line_id
        WHERE d.receipt_id = review.receipt_id
      ), '[]'::jsonb),
      'evidence', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', e.id,
          'line_disposition_id', e.line_disposition_id,
          'storage_object_path', e.storage_object_path,
          'original_filename', e.original_filename,
          'content_type', e.content_type,
          'display_order', e.display_order
        ) ORDER BY e.display_order, e.created_at, e.id)
        FROM public.shipper_package_receipt_evidence e
        WHERE e.receipt_id = review.receipt_id
      ), '[]'::jsonb),
      'proposals', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', remedy.id,
          'receipt_line_disposition_id', remedy.receipt_line_disposition_id,
          'proposed_remedy_type', remedy.proposed_remedy_type,
          'proposed_remedy_qty', remedy.proposed_remedy_qty,
          'status', remedy.status,
          'approved_remedy_type', remedy.approved_remedy_type,
          'approved_remedy_qty', remedy.approved_remedy_qty
        ) ORDER BY remedy.proposed_at, remedy.id)
        FROM public.physical_exception_remedy_allocations remedy
        WHERE remedy.physical_receipt_review_id = review.id
          AND remedy.status <> 'cancelled'
      ), '[]'::jsonb)
    ) AS row_json
    FROM allowed review
    JOIN public.orders o ON o.id = review.order_id
    LEFT JOIN public.retailers retailer ON retailer.id = o.retailer_id
    JOIN public.order_tracking_submissions tracking ON tracking.id = review.tracking_submission_id
    ORDER BY review.created_at DESC, review.id DESC
  )
  SELECT jsonb_build_object(
    'action_count', (SELECT COUNT(*) FROM allowed WHERE status IN ('awaiting_importer_proposal','returned_for_information')),
    'reviews', COALESCE((SELECT jsonb_agg(row_json) FROM rows), '[]'::jsonb)
  );
$function$;

CREATE FUNCTION public.staff_physical_receipt_reviews_v1(
  p_review_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH caller AS (
    SELECT s.id
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND COALESCE(s.active, true) = true
      AND s.role_type IN ('admin','supervisor')
    ORDER BY s.id
    LIMIT 1
  ), allowed AS (
    SELECT review.*
    FROM public.physical_receipt_reviews review
    JOIN caller c ON true
    WHERE (
      p_review_id IS NULL
      AND review.status = 'awaiting_supervisor_review'
    ) OR review.id = p_review_id
  ), rows AS (
    SELECT jsonb_build_object(
      'id', review.id,
      'status', review.status,
      'created_at', review.created_at,
      'updated_at', review.updated_at,
      'order_id', review.order_id,
      'order_ref', o.order_ref,
      'retailer_name', retailer.name,
      'tracking_submission_id', review.tracking_submission_id,
      'tracking_ref', tracking.tracking_ref,
      'receipt_id', review.receipt_id,
      'importer_proposal_note', review.importer_proposal_note,
      'decision_note', review.decision_note,
      'affected_quantity', COALESCE((
        SELECT SUM(d.quantity)
        FROM public.shipper_package_receipt_line_dispositions d
        WHERE d.receipt_id = review.receipt_id
          AND d.disposition_type <> 'clean'
      ), 0),
      'dispositions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', d.id,
          'supplier_invoice_line_id', d.supplier_invoice_line_id,
          'item_description', sil.description,
          'disposition_type', d.disposition_type,
          'quantity', d.quantity,
          'condition_note', d.condition_note
        ) ORDER BY sil.line_order NULLS LAST, d.id)
        FROM public.shipper_package_receipt_line_dispositions d
        JOIN public.supplier_invoice_lines sil ON sil.id = d.supplier_invoice_line_id
        WHERE d.receipt_id = review.receipt_id
      ), '[]'::jsonb),
      'evidence', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', e.id,
          'storage_object_path', e.storage_object_path,
          'original_filename', e.original_filename,
          'content_type', e.content_type,
          'display_order', e.display_order
        ) ORDER BY e.display_order, e.created_at, e.id)
        FROM public.shipper_package_receipt_evidence e
        WHERE e.receipt_id = review.receipt_id
      ), '[]'::jsonb),
      'proposals', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', remedy.id,
          'receipt_line_disposition_id', remedy.receipt_line_disposition_id,
          'proposed_remedy_type', remedy.proposed_remedy_type,
          'proposed_remedy_qty', remedy.proposed_remedy_qty,
          'status', remedy.status,
          'approved_remedy_type', remedy.approved_remedy_type,
          'approved_remedy_qty', remedy.approved_remedy_qty,
          'supplier_cost_mode', remedy.supplier_cost_mode
        ) ORDER BY remedy.proposed_at, remedy.id)
        FROM public.physical_exception_remedy_allocations remedy
        WHERE remedy.physical_receipt_review_id = review.id
          AND remedy.status <> 'cancelled'
      ), '[]'::jsonb),
      'linked_disputes', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'dispute_id', link.dispute_id,
          'remedy_type', link.desired_outcome
        ) ORDER BY link.created_at, link.dispute_id)
        FROM public.physical_receipt_review_dispute_links link
        WHERE link.physical_receipt_review_id = review.id
      ), '[]'::jsonb)
    ) AS row_json
    FROM allowed review
    JOIN public.orders o ON o.id = review.order_id
    LEFT JOIN public.retailers retailer ON retailer.id = o.retailer_id
    JOIN public.order_tracking_submissions tracking ON tracking.id = review.tracking_submission_id
    ORDER BY review.created_at DESC, review.id DESC
  )
  SELECT jsonb_build_object(
    'action_count', (SELECT COUNT(*) FROM allowed WHERE status = 'awaiting_supervisor_review'),
    'reviews', COALESCE((SELECT jsonb_agg(row_json) FROM rows), '[]'::jsonb)
  );
$function$;

REVOKE ALL ON FUNCTION public.importer_physical_receipt_reviews_v1(uuid)
FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.staff_physical_receipt_reviews_v1(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.importer_physical_receipt_reviews_v1(uuid)
TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_physical_receipt_reviews_v1(uuid)
TO authenticated;

COMMENT ON FUNCTION public.importer_physical_receipt_reviews_v1(uuid) IS
'Importer-tenant-scoped action queue and exact detail read. NULL returns only importer-actionable reviews; a supplied UUID returns that authorised detail regardless of state.';
COMMENT ON FUNCTION public.staff_physical_receipt_reviews_v1(uuid) IS
'Active supervisor/admin action queue and exact detail read. NULL returns only supervisor-actionable reviews; a supplied UUID returns that authorised detail regardless of state.';

NOTIFY pgrst, 'reload schema';

COMMIT;
