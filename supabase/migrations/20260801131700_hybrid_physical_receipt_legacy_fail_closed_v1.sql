BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final foundation hardening:
--   * every v2 header matches the exact order shipper and active shipper user;
--   * every supervisor physical-review decision retains a decision note;
--   * a legacy receipt correction cannot guess around supplier-line dispute history;
--   * the deferred pending guard uses INSERT/UPDATE NEW identity directly;
--   * transactional correction preparation is the single supersession authority;
--   * terminal review/remedy provenance cannot be edited in place.

DO $preflight$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.shipper_users') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt final hardening prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_v2_integrity_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_package_receipt_v2_pending_commit_guard_v1()') IS NULL
     OR to_regprocedure('public.shipper_package_receipt_prepare_correction_v1()') IS NULL
     OR to_regprocedure('public.shipper_package_receipt_v2_supersede_open_review_v1()') IS NULL
     OR to_regprocedure('public.physical_receipt_review_guard_v1()') IS NULL
     OR to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt integrity and concurrency guards must be installed first.';
  END IF;

  IF to_regprocedure('public.shipper_package_receipt_header_identity_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.shipper_package_receipt_legacy_exception_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.physical_receipt_review_terminal_immutability_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.physical_remedy_terminal_immutability_guard_v1()') IS NOT NULL
  THEN
    RAISE EXCEPTION
      'One or more hybrid receipt final hardening guards already exist; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

ALTER TABLE public.physical_receipt_reviews
  ADD CONSTRAINT physical_receipt_review_supervisor_note_required_v1 CHECK (
    status NOT IN (
      'returned_for_information',
      'approved_for_investigation',
      'approved_to_existing_exception',
      'rejected',
      'closed_no_action'
    )
    OR NULLIF(BTRIM(COALESCE(decision_note, '')), '') IS NOT NULL
  );

-- Remove the earlier no-op fallback. The BEFORE correction preparation trigger
-- owns proposal cancellation, safety blocking and review supersession atomically.
DROP TRIGGER trg_shipper_package_receipt_v2_supersede_open_review_v1
  ON public.shipper_package_receipts;
DROP FUNCTION public.shipper_package_receipt_v2_supersede_open_review_v1();

-- Recreate the deferred guard with the only row identity valid for both events
-- on this INSERT/UPDATE-only constraint trigger.
DROP TRIGGER trg_shipper_package_receipt_v2_pending_commit_guard_v1
  ON public.shipper_package_receipts;
DROP FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    WHERE receipt.id = NEW.id
      AND receipt.receipt_model_version = 2
      AND (
        receipt.receipt_state <> 'finalised'
        OR receipt.finalised_at IS NULL
      )
  ) THEN
    RAISE EXCEPTION
      'A pending v2 receipt cannot be committed; the complete snapshot must finalise in the same transaction.';
  END IF;

  RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_shipper_package_receipt_v2_pending_commit_guard_v1
AFTER INSERT OR UPDATE
ON public.shipper_package_receipts
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_header_identity_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order_id uuid;
  v_order_shipper_id uuid;
BEGIN
  IF NEW.receipt_model_version <> 2 THEN
    RETURN NEW;
  END IF;

  SELECT tracking_row.order_id, order_row.shipper_id
  INTO v_order_id, v_order_shipper_id
  FROM public.order_tracking_submissions tracking_row
  JOIN public.orders order_row ON order_row.id = tracking_row.order_id
  WHERE tracking_row.id = NEW.tracking_submission_id
    AND tracking_row.superseded_at IS NULL;

  IF v_order_id IS NULL
     OR NEW.order_id IS DISTINCT FROM v_order_id
     OR NEW.shipper_id IS DISTINCT FROM v_order_shipper_id
  THEN
    RAISE EXCEPTION
      'V2 receipt header does not match the current tracking, order and order shipper identity.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_users shipper_user
    WHERE shipper_user.id = NEW.shipper_user_id
      AND shipper_user.shipper_id = NEW.shipper_id
      AND shipper_user.active = true
  ) THEN
    RAISE EXCEPTION
      'V2 receipt shipper user is not active for the order shipper.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_00b_header_identity_guard_v1
BEFORE INSERT OR UPDATE
ON public.shipper_package_receipts
FOR EACH ROW
EXECUTE FUNCTION public.shipper_package_receipt_header_identity_guard_v1();

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

CREATE FUNCTION public.physical_receipt_review_terminal_immutability_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF OLD.status IN (
    'approved_to_existing_exception',
    'rejected',
    'closed_no_action',
    'superseded'
  ) AND (to_jsonb(NEW) - 'updated_at')
       IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at')
  THEN
    RAISE EXCEPTION
      'Terminal physical receipt review provenance is immutable.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_receipt_review_00a_terminal_immutability_v1
BEFORE UPDATE
ON public.physical_receipt_reviews
FOR EACH ROW
EXECUTE FUNCTION public.physical_receipt_review_terminal_immutability_guard_v1();

CREATE FUNCTION public.physical_remedy_terminal_immutability_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF TG_OP = 'INSERT'
     AND NEW.status = 'proposed'
     AND (
       NEW.supplier_claim_amount_gbp IS NOT NULL
       OR NEW.customer_commercial_value_gbp IS NOT NULL
     )
  THEN
    RAISE EXCEPTION
      'Importer remedy proposal cannot invent supplier claim or customer commercial outcome amounts.';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status IN ('completed','closed_no_action','rerouted')
       AND (to_jsonb(NEW) - 'updated_at')
           IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at')
    THEN
      RAISE EXCEPTION 'Terminal physical remedy provenance is immutable.';
    END IF;

    IF OLD.dispute_line_id IS NOT NULL
       AND NEW.dispute_line_id IS DISTINCT FROM OLD.dispute_line_id
    THEN
      RAISE EXCEPTION 'Physical remedy dispute-line provenance is immutable once linked.';
    END IF;

    IF OLD.replacement_child_order_id IS NOT NULL
       AND NEW.replacement_child_order_id
           IS DISTINCT FROM OLD.replacement_child_order_id
    THEN
      RAISE EXCEPTION 'Physical remedy replacement-child provenance is immutable once linked.';
    END IF;

    IF OLD.replacement_child_tracking_allocation_id IS NOT NULL
       AND NEW.replacement_child_tracking_allocation_id
           IS DISTINCT FROM OLD.replacement_child_tracking_allocation_id
    THEN
      RAISE EXCEPTION
        'Physical remedy replacement-child tracking provenance is immutable once linked.';
    END IF;

    IF OLD.supplier_cost_mode IN ('free_replacement','charged_repurchase')
       AND NEW.supplier_cost_mode IS DISTINCT FROM OLD.supplier_cost_mode
    THEN
      RAISE EXCEPTION 'Final replacement supplier cost mode is immutable.';
    END IF;
  END IF;

  IF NEW.status = 'completed'
     AND NEW.approved_remedy_type = 'replacement'
     AND NEW.supplier_cost_mode = 'pending_supplier_evidence'
  THEN
    RAISE EXCEPTION
      'Replacement remedy cannot complete while supplier cost evidence remains pending.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_remedy_00a_terminal_immutability_v1
BEFORE INSERT OR UPDATE
ON public.physical_exception_remedy_allocations
FOR EACH ROW
EXECUTE FUNCTION public.physical_remedy_terminal_immutability_guard_v1();

REVOKE ALL ON FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_header_identity_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_legacy_exception_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_receipt_review_terminal_immutability_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_remedy_terminal_immutability_guard_v1()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;