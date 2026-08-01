BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Build 2 correction boundary: an open physical triage review may be
-- superseded by a later complete receipt snapshot. Terminal or retailer-linked
-- provenance requires controlled staff remediation and must fail before insert.

DO $preflight$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
  THEN
    RAISE EXCEPTION 'Physical receipt terminal correction guard prerequisites are missing.';
  END IF;

  IF to_regprocedure(
    'public.shipper_package_receipt_v2_terminal_correction_guard_v1()'
  ) IS NOT NULL THEN
    RAISE EXCEPTION
      'Physical receipt terminal correction guard already exists; inspect before replacing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.shipper_package_receipt_v2_terminal_correction_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_review_status text;
BEGIN
  IF NEW.receipt_model_version <> 2
     OR NEW.correction_of_receipt_id IS NULL
  THEN
    RETURN NEW;
  END IF;

  SELECT review_row.status
  INTO v_review_status
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.receipt_id = NEW.correction_of_receipt_id
  FOR SHARE;

  IF v_review_status IN (
    'approved_to_existing_exception',
    'rejected',
    'closed_no_action',
    'superseded'
  ) THEN
    RAISE EXCEPTION
      'Receipt correction is blocked because predecessor physical review is terminal or retailer-linked (%). Use controlled staff remediation.',
      v_review_status;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_v2_terminal_correction_guard_v1
BEFORE INSERT
ON public.shipper_package_receipts
FOR EACH ROW
EXECUTE FUNCTION public.shipper_package_receipt_v2_terminal_correction_guard_v1();

REVOKE ALL ON FUNCTION
  public.shipper_package_receipt_v2_terminal_correction_guard_v1()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.shipper_package_receipt_v2_terminal_correction_guard_v1()
  TO service_role;

COMMIT;
