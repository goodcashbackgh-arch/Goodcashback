BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.customer_order_review_links') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_order_review_links';
  END IF;
  IF to_regclass('public.sales_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.sales_invoices';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.customer_order_has_active_pre_shipment_hold_v1(p_order_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.order_id = p_order_id
      AND h.status IN ('requested','supervisor_approved')
  );
$$;

REVOKE ALL ON FUNCTION public.customer_order_has_active_pre_shipment_hold_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_order_has_active_pre_shipment_hold_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.customer_block_sales_invoice_when_hold_active_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.invoice_type::text, '') IN ('main','supplementary')
     AND COALESCE(NEW.sage_status::text, '') IN ('draft','posted')
     AND public.customer_order_has_active_pre_shipment_hold_v1(NEW.order_id)
  THEN
    RAISE EXCEPTION 'Cannot create or post customer sales invoice: unresolved customer pre-shipment hold exists for order %.', NEW.order_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_block_sales_invoice_when_hold_active_v1
  ON public.sales_invoices;

CREATE TRIGGER trg_customer_block_sales_invoice_when_hold_active_v1
BEFORE INSERT OR UPDATE OF sage_status, invoice_type, order_id
ON public.sales_invoices
FOR EACH ROW
EXECUTE FUNCTION public.customer_block_sales_invoice_when_hold_active_v1();

CREATE OR REPLACE FUNCTION public.customer_close_order_review_links_for_invoice_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.order_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.invoice_type::text, '') IN ('main','supplementary')
     AND COALESCE(NEW.sage_status::text, '') IN ('draft','posted')
  THEN
    UPDATE public.customer_order_review_links l
    SET is_active = false
    WHERE l.order_id = NEW.order_id
      AND l.is_active = true;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_close_order_review_links_for_invoice_v1
  ON public.sales_invoices;

CREATE TRIGGER trg_customer_close_order_review_links_for_invoice_v1
AFTER INSERT OR UPDATE OF sage_status, invoice_type, order_id
ON public.sales_invoices
FOR EACH ROW
EXECUTE FUNCTION public.customer_close_order_review_links_for_invoice_v1();

UPDATE public.customer_order_review_links l
SET is_active = false
WHERE l.is_active = true
  AND EXISTS (
    SELECT 1
    FROM public.sales_invoices si
    WHERE si.order_id = l.order_id
      AND COALESCE(si.invoice_type::text, '') IN ('main','supplementary')
      AND COALESCE(si.sage_status::text, '') IN ('draft','posted')
  );

NOTIFY pgrst, 'reload schema';

COMMIT;
