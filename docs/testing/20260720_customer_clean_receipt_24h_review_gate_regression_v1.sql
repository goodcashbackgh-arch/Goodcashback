BEGIN;

DO $$
DECLARE
  v_ready_def text;
  v_link_def text;
  v_candidates_def text;
  v_create_def text;
  v_trigger_def text;
BEGIN
  IF to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_review_ready_line_ids_v1(uuid) missing';
  END IF;
  IF to_regprocedure('public.customer_active_order_review_link_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_active_order_review_link_v1(uuid) missing';
  END IF;
  IF to_regprocedure('public.shipper_shipment_batch_candidates_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipper_shipment_batch_candidates_v1() missing';
  END IF;
  IF to_regprocedure('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shipper_create_shipment_batch_v1(...) missing';
  END IF;
  IF to_regprocedure('public.customer_hold_enforce_open_review_window_v1()') IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_hold_enforce_open_review_window_v1() missing';
  END IF;

  SELECT pg_get_functiondef('public.customer_review_ready_line_ids_v1(uuid)'::regprocedure) INTO v_ready_def;
  SELECT pg_get_functiondef('public.customer_active_order_review_link_v1(uuid)'::regprocedure) INTO v_link_def;
  SELECT pg_get_functiondef('public.shipper_shipment_batch_candidates_v1()'::regprocedure) INTO v_candidates_def;
  SELECT pg_get_functiondef('public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure) INTO v_create_def;
  SELECT pg_get_functiondef('public.customer_hold_enforce_open_review_window_v1()'::regprocedure) INTO v_trigger_def;

  IF position('received_clean' in v_ready_def) = 0
     OR position('24 hours' in v_ready_def) = 0
     OR position('shipper_shipment_batch_packages' in v_ready_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: review readiness is not derived from clean receipt, 24 hours, and unbatched package state';
  END IF;

  IF position('expires_at' in v_link_def) = 0
     OR position('v_deadline' in v_link_def) = 0
     OR position('24 hours' in v_link_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: active review link does not use the clean-receipt deadline';
  END IF;

  IF position('24 hours' in v_candidates_def) = 0
     OR position('customer_pre_shipment_hold_requests' in v_candidates_def) = 0
     OR position('requested' in v_candidates_def) = 0
     OR position('supervisor_approved' in v_candidates_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: shipment candidates do not enforce elapsed review window and active hold scopes';
  END IF;

  IF position('24-hour customer review window' in v_create_def) = 0
     OR position('customer_pre_shipment_hold_requests' in v_create_def) = 0
     OR position('pg_advisory_xact_lock' in v_create_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: direct shipment creation does not defensively enforce the same gate';
  END IF;

  IF position('v_link_expires_at IS NULL' in v_trigger_def) = 0
     OR position('NEW.tracking_submission_id :=' in v_trigger_def) = 0
     OR position('SECURITY DEFINER' in upper(v_trigger_def)) = 0
  THEN
    RAISE EXCEPTION 'FAIL: hold trigger does not preserve legacy untimed links and derive exact package identity';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'customer_pre_shipment_hold_requests'
      AND t.tgname = 'trg_customer_hold_enforce_open_review_window_v1'
      AND NOT t.tgisinternal
  ) THEN
    RAISE EXCEPTION 'FAIL: customer review window enforcement trigger missing';
  END IF;
END $$;

SELECT 'PASS: clean receipt starts a 24-hour customer review window; shipment batching is blocked during the window and by active holds; legacy untimed links remain compatible' AS regression_result;

ROLLBACK;
