BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- A legacy package receipt has no exact physical quantity provenance. Where a
-- supplier line on that package also has historical dispute activity, a v2
-- correction must not guess whether that activity belongs to this package.

DO $preflight$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Legacy exception fail-closed prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_v2_integrity_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_package_receipt_prepare_correction_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt integrity and concurrency guards must be installed first.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_legacy_exception_guard_v1()') IS NOT NULL THEN
    RAISE EXCEPTION
      'Legacy exception fail-closed guard already exists; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.shipper_package_receipt_legacy_exception_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_prior_model smallint;
BEGIN
  IF NEW.receipt_model_version <> 2
     OR OLD.receipt_model_version <> 2
     OR OLD.receipt_state <> 'pending'
     OR NEW.receipt_state <> 'finalised'
     OR NEW.correction_of_receipt_id IS NULL
  THEN
    RETURN NEW;
  END IF;

  SELECT prior.receipt_model_version
  INTO v_prior_model
  FROM public.shipper_package_receipts prior
  WHERE prior.id = NEW.correction_of_receipt_id;

  IF v_prior_model = 1 AND EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations allocation
    JOIN public.dispute_lines dispute_line
      ON dispute_line.supplier_invoice_line_id =
         allocation.supplier_invoice_line_id
    WHERE allocation.order_id = NEW.order_id
      AND allocation.tracking_submission_id = NEW.tracking_submission_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
  ) THEN
    RAISE EXCEPTION
      'Legacy receipt correction is blocked because a source supplier line has dispute history without exact package provenance. Resolve it through controlled staff remediation; do not guess the affected quantity.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_00a_legacy_exception_guard_v1
BEFORE UPDATE OF receipt_state
ON public.shipper_package_receipts
FOR EACH ROW
WHEN (OLD.receipt_state IS DISTINCT FROM NEW.receipt_state)
EXECUTE FUNCTION public.shipper_package_receipt_legacy_exception_guard_v1();

REVOKE ALL ON FUNCTION public.shipper_package_receipt_legacy_exception_guard_v1()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;