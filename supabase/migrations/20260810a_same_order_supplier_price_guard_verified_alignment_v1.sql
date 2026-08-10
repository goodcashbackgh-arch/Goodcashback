BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Corrective alignment for the new v1 guard only. Existing platform RPCs remain
-- untouched. An unverified OCR/header value must not create a false order-level
-- price block against a separate verified supplier invoice.

DO $$
BEGIN
  IF to_regprocedure('public.enforce_supplier_invoice_order_price_limit_v1()') IS NULL
     OR to_regclass('public.order_supplier_price_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Same-order supplier price v1 guard/read model is missing.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.enforce_supplier_invoice_order_price_limit_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_position record;
BEGIN
  IF COALESCE(NEW.review_status, '') NOT IN ('approved_current','ref_corrected_approved')
     OR COALESCE(NEW.blocked_from_sage_yn, true) = true THEN
    RETURN NEW;
  END IF;

  SELECT
    o.id,
    COALESCE(o.order_type, 'original')::text AS order_type,
    ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS order_total_gbp_declared
  INTO v_order
  FROM public.orders o
  WHERE o.id = NEW.order_id
  FOR UPDATE;

  IF v_order.id IS NULL OR v_order.order_type <> 'original' THEN
    RETURN NEW;
  END IF;

  SELECT p.*
  INTO v_position
  FROM public.order_supplier_price_position_v1 p
  WHERE p.order_id = NEW.order_id;

  -- Only a fully price-verified live bundle is authoritative for this new
  -- commercial guard. Existing document/header/adjustment controls remain the
  -- authority while any contributing live invoice is still unverified.
  IF COALESCE(v_position.unverified_invoice_count, 0) = 0
     AND COALESCE(v_position.missing_accepted_total_count, 0) = 0
     AND COALESCE(v_position.accepted_supplier_bundle_gbp, 0)
           > v_order.order_total_gbp_declared + 0.01 THEN
    RAISE EXCEPTION
      'Supplier invoice approval blocked: verified live supplier bundle GBP % exceeds accepted order value GBP %. Approve the order price increase first.',
      v_position.accepted_supplier_bundle_gbp,
      v_order.order_total_gbp_declared;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.enforce_supplier_invoice_order_price_limit_v1() FROM PUBLIC, anon, authenticated;

COMMIT;
