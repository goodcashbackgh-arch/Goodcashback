BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive automatic-enrolment wiring for the exact clean review path.
-- Mini Builds 1–4 functions remain unchanged.
-- The bridge runs only after a v2 package receipt makes the real transition
-- into its finalised state, after its exact dispositions have been written.

DO $preflight$
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL
     OR to_regprocedure('public.internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)') IS NULL
     OR to_regprocedure('public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)') IS NULL
  THEN
    RAISE EXCEPTION 'Exact clean automatic review-enrolment prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.auto_enrol_exact_clean_receipt_review_v1()') IS NOT NULL THEN
    RAISE EXCEPTION 'auto_enrol_exact_clean_receipt_review_v1 already exists; inspect before replacing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.shipper_package_receipts'::regclass
      AND tgname = 'trg_auto_enrol_exact_clean_receipt_review_v1'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Exact clean automatic review-enrolment trigger already exists.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.auto_enrol_exact_clean_receipt_review_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_order_id uuid;
BEGIN
  IF NEW.receipt_model_version IS DISTINCT FROM 2
     OR NEW.receipt_state IS DISTINCT FROM 'finalised'
     OR NEW.finalised_at IS NULL
     OR NOT (
       OLD.receipt_state IS DISTINCT FROM NEW.receipt_state
       OR OLD.finalised_at IS DISTINCT FROM NEW.finalised_at
     )
  THEN
    RETURN NEW;
  END IF;

  SELECT submission.order_id
  INTO v_order_id
  FROM public.order_tracking_submissions submission
  WHERE submission.id = NEW.tracking_submission_id;

  IF v_order_id IS NULL THEN
    RAISE EXCEPTION
      'Finalised exact package receipt could not resolve its order for customer review enrolment.';
  END IF;

  PERFORM public.internal_bridge_exact_customer_review_candidates_v1(
    v_order_id,
    NULL
  );

  RETURN NEW;
END;
$function$;

ALTER FUNCTION public.auto_enrol_exact_clean_receipt_review_v1()
  OWNER TO postgres;

REVOKE ALL ON FUNCTION public.auto_enrol_exact_clean_receipt_review_v1()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER trg_auto_enrol_exact_clean_receipt_review_v1
AFTER UPDATE OF receipt_state, finalised_at
ON public.shipper_package_receipts
FOR EACH ROW
EXECUTE FUNCTION public.auto_enrol_exact_clean_receipt_review_v1();

DO $postflight$
DECLARE
  v_candidate_md5 text;
  v_materialiser_md5 text;
  v_component_md5 text;
  v_immutable_md5 text;
  v_shipper_candidates_md5 text;
  v_shipper_create_md5 text;
BEGIN
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_candidates_v1(uuid)'::regprocedure)) INTO v_candidate_md5;
  SELECT md5(pg_get_functiondef('public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure)) INTO v_materialiser_md5;
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_component_guard_v1()'::regprocedure)) INTO v_component_md5;
  SELECT md5(pg_get_functiondef('public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure)) INTO v_immutable_md5;
  SELECT md5(pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure)) INTO v_shipper_candidates_md5;
  SELECT md5(pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure)) INTO v_shipper_create_md5;

  IF v_candidate_md5 IS DISTINCT FROM '80c5ca83374ed2ddaedeadd3b88dd95d'
     OR v_materialiser_md5 IS DISTINCT FROM '0293a94d4eb17daf9c7e48131cd75ca1'
     OR v_component_md5 IS DISTINCT FROM 'c7b7727836dd6c49fdbcd415fb68d88a'
     OR v_immutable_md5 IS DISTINCT FROM 'f08154042118c35eb4428af24623ae90'
     OR v_shipper_candidates_md5 IS DISTINCT FROM '952f24084fed0dffcdebbfae988e7400'
     OR v_shipper_create_md5 IS DISTINCT FROM '4e4b86b0121a85523fe95c1530a41658'
  THEN
    RAISE EXCEPTION 'Protected Mini Build authority changed during automatic exact review enrolment wiring.';
  END IF;
END
$postflight$;

COMMIT;
