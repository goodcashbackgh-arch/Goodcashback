BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Serialise legacy/v2 receipt history and exact remedy reservation without
-- replacing any pre-existing platform function.

DO $preflight$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt concurrency prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_v2_integrity_guard_v1()') IS NULL
     OR to_regprocedure('public.physical_receipt_review_guard_v1()') IS NULL
     OR to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt integrity guards must be installed first.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_write_compatibility_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.shipper_package_receipt_prepare_correction_v1()') IS NOT NULL
     OR to_regprocedure('public.physical_receipt_review_terminal_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.physical_remedy_sequence_guard_v1()') IS NOT NULL
  THEN
    RAISE EXCEPTION
      'One or more hybrid receipt concurrency guards already exist; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.shipper_package_receipt_write_compatibility_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order_id uuid;
BEGIN
  SELECT tracking_row.order_id
  INTO v_order_id
  FROM public.order_tracking_submissions tracking_row
  WHERE tracking_row.id = NEW.tracking_submission_id
    AND tracking_row.superseded_at IS NULL
  FOR UPDATE;

  IF v_order_id IS NULL
     OR NEW.order_id IS DISTINCT FROM v_order_id
  THEN
    RAISE EXCEPTION 'Receipt tracking identity is missing, superseded or does not match the order.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(v_order_id::text));
  PERFORM pg_advisory_xact_lock(hashtext(NEW.tracking_submission_id::text));

  IF NEW.receipt_model_version = 1
     AND EXISTS (
       SELECT 1
       FROM public.shipper_package_receipts receipt
       WHERE receipt.tracking_submission_id = NEW.tracking_submission_id
         AND receipt.receipt_model_version = 2
         AND receipt.receipt_state = 'finalised'
         AND receipt.finalised_at IS NOT NULL
         AND (TG_OP = 'INSERT' OR receipt.id <> NEW.id)
     )
  THEN
    RAISE EXCEPTION
      'Legacy package receipt cannot supersede an exact finalised v2 receipt. Use the controlled v2 correction route.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_00_write_compatibility_guard_v1
BEFORE INSERT OR UPDATE
ON public.shipper_package_receipts
FOR EACH ROW
EXECUTE FUNCTION public.shipper_package_receipt_write_compatibility_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_prepare_correction_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_review_id uuid;
  v_review_status text;
BEGIN
  IF NEW.receipt_model_version <> 2
     OR OLD.receipt_model_version <> 2
     OR OLD.receipt_state <> 'pending'
     OR NEW.receipt_state <> 'finalised'
     OR NEW.correction_of_receipt_id IS NULL
  THEN
    RETURN NEW;
  END IF;

  SELECT review_row.id, review_row.status
  INTO v_review_id, v_review_status
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.receipt_id = NEW.correction_of_receipt_id
  FOR UPDATE;

  IF v_review_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_review_status IN (
    'approved_for_investigation',
    'approved_to_existing_exception'
  ) OR EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = v_review_id
      AND remedy_row.status IN (
        'approved','linked_to_exception','in_progress',
        'completed','closed_no_action'
      )
  ) THEN
    RAISE EXCEPTION
      'The previous receipt has supervisor-approved or progressed remedy work. Resolve that work through the controlled exception route before correcting the physical receipt.';
  END IF;

  UPDATE public.physical_exception_remedy_allocations remedy_row
  SET status = 'cancelled',
      updated_at = now()
  WHERE remedy_row.physical_receipt_review_id = v_review_id
    AND remedy_row.status = 'proposed';

  IF v_review_status IN (
    'awaiting_importer_proposal',
    'awaiting_supervisor_review',
    'returned_for_information'
  ) THEN
    UPDATE public.physical_receipt_reviews review_row
    SET status = 'superseded',
        superseded_by_receipt_id = NEW.id,
        decision_note = concat_ws(
          ' ',
          NULLIF(BTRIM(COALESCE(review_row.decision_note, '')), ''),
          'Superseded by corrected finalised receipt ' || NEW.id::text || '.'
        ),
        updated_at = now()
    WHERE review_row.id = v_review_id;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_01_prepare_correction_v1
BEFORE UPDATE OF receipt_state
ON public.shipper_package_receipts
FOR EACH ROW
WHEN (OLD.receipt_state IS DISTINCT FROM NEW.receipt_state)
EXECUTE FUNCTION public.shipper_package_receipt_prepare_correction_v1();

CREATE FUNCTION public.physical_receipt_review_terminal_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.status = 'rejected' AND EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = NEW.id
      AND remedy_row.status NOT IN ('cancelled','rerouted')
  ) THEN
    RAISE EXCEPTION
      'Rejected physical review cannot retain proposed, approved or progressed remedy quantity.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_receipt_review_00_terminal_guard_v1
BEFORE UPDATE OF status
ON public.physical_receipt_reviews
FOR EACH ROW
EXECUTE FUNCTION public.physical_receipt_review_terminal_guard_v1();

CREATE FUNCTION public.physical_remedy_sequence_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_review_status text;
BEGIN
  PERFORM 1
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id = NEW.tracking_line_allocation_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Physical remedy tracking allocation does not exist.';
  END IF;

  SELECT review_row.status
  INTO v_review_status
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = NEW.physical_receipt_review_id
  FOR UPDATE;

  IF v_review_status IS NULL THEN
    RAISE EXCEPTION 'Physical remedy review does not exist.';
  END IF;

  IF TG_OP = 'INSERT'
     AND NEW.status = 'proposed'
     AND v_review_status NOT IN (
       'awaiting_importer_proposal','returned_for_information'
     )
  THEN
    RAISE EXCEPTION
      'Importer remedy proposals may be added only while the physical review awaits importer information.';
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.status = 'proposed'
     AND NEW.status = 'approved'
     AND v_review_status <> 'awaiting_supervisor_review'
  THEN
    RAISE EXCEPTION
      'Supervisor remedy approval requires the physical review to be awaiting supervisor review.';
  END IF;

  IF NEW.status IN ('linked_to_exception','in_progress','completed')
     AND NEW.approved_remedy_type IN ('refund','replacement')
     AND v_review_status <> 'approved_to_existing_exception'
  THEN
    RAISE EXCEPTION
      'Refund/replacement remedy progression requires the physical review to be approved into the existing exception route.';
  END IF;

  IF NEW.status = 'in_progress'
     AND NEW.approved_remedy_type = 'hold_investigate'
     AND v_review_status <> 'approved_for_investigation'
  THEN
    RAISE EXCEPTION
      'Investigation progression requires supervisor-approved investigation review state.';
  END IF;

  IF NEW.status = 'closed_no_action'
     AND NEW.approved_remedy_type = 'no_action'
     AND v_review_status NOT IN (
       'awaiting_supervisor_review','closed_no_action'
     )
  THEN
    RAISE EXCEPTION
      'No-action closure requires the physical review to be under supervisor decision or already closed no action.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_remedy_00_sequence_guard_v1
BEFORE INSERT OR UPDATE
ON public.physical_exception_remedy_allocations
FOR EACH ROW
EXECUTE FUNCTION public.physical_remedy_sequence_guard_v1();

REVOKE ALL ON FUNCTION public.shipper_package_receipt_write_compatibility_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_prepare_correction_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_receipt_review_terminal_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_remedy_sequence_guard_v1()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;