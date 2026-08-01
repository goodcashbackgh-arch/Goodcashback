BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.shipper_users') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regprocedure('public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Build 3 shipper entry read prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.shipper_physical_receipt_entry_v1(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'shipper_physical_receipt_entry_v1 already exists; inspect before replacing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.shipper_physical_receipt_entry_v1(
  p_tracking_submission_id uuid
)
RETURNS TABLE (
  tracking_line_allocation_id uuid,
  supplier_invoice_line_id uuid,
  item_description text,
  qty_allocated numeric,
  latest_receipt_id uuid,
  latest_receipt_model_version smallint,
  latest_receipt_state text,
  latest_review_status text,
  correction_allowed boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH caller AS (
    SELECT su.shipper_id
    FROM public.shipper_users su
    WHERE su.auth_user_id = auth.uid()
      AND su.active = true
    ORDER BY su.created_at DESC, su.id DESC
    LIMIT 1
  ), package AS (
    SELECT ots.id, ots.order_id
    FROM public.order_tracking_submissions ots
    JOIN public.orders o ON o.id = ots.order_id
    JOIN caller c ON c.shipper_id = o.shipper_id
    WHERE ots.id = p_tracking_submission_id
      AND ots.superseded_at IS NULL
  ), latest AS (
    SELECT r.id,
           r.receipt_model_version,
           r.receipt_state,
           pr.status AS review_status
    FROM public.shipper_package_receipts r
    LEFT JOIN public.physical_receipt_reviews pr ON pr.receipt_id = r.id
    JOIN package p ON p.id = r.tracking_submission_id
    WHERE r.receipt_model_version = 1
       OR (r.receipt_model_version = 2
           AND r.receipt_state = 'finalised'
           AND r.finalised_at IS NOT NULL)
    ORDER BY r.created_at DESC, r.id DESC
    LIMIT 1
  )
  SELECT a.id,
         a.supplier_invoice_line_id,
         sil.description,
         a.qty_allocated::numeric,
         l.id,
         l.receipt_model_version,
         l.receipt_state,
         l.review_status,
         COALESCE(l.review_status NOT IN (
           'approved_to_existing_exception',
           'rejected',
           'closed_no_action',
           'superseded'
         ), true)
  FROM package p
  JOIN public.order_tracking_line_allocations a
    ON a.order_id = p.order_id
   AND a.tracking_submission_id = p.id
   AND COALESCE(a.qty_allocated, 0) > 0
  JOIN public.supplier_invoice_lines sil
    ON sil.id = a.supplier_invoice_line_id
  LEFT JOIN latest l ON true
  ORDER BY sil.line_order NULLS LAST, a.id;
$function$;

REVOKE ALL
ON FUNCTION public.shipper_physical_receipt_entry_v1(uuid)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.shipper_physical_receipt_entry_v1(uuid)
TO authenticated;

COMMENT ON FUNCTION public.shipper_physical_receipt_entry_v1(uuid) IS
'Shipper-scoped read model for exact v2 receipt entry. Exposes allocation identity and quantity only for the authenticated shipper package.';

COMMIT;