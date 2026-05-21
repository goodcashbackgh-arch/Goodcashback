BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.settlement_credit_original_local_value_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_rate numeric := 1;
BEGIN
  IF NEW.source_type = 'settlement_credit'
     AND NEW.source_entity_type = 'order'
     AND NEW.source_entity_id IS NOT NULL
     AND NEW.direction = 'credit' THEN

    SELECT
      o.order_total_gbp_declared,
      o.quote_total_ghs,
      COALESCE(o.quote_fx_rate_locked, o.quote_fx_rate, 0) AS quote_fx_rate,
      COALESCE(o.quote_card_markup_pct_locked, o.quote_card_markup_pct, 0) AS quote_card_markup_pct,
      COALESCE(cu.code, NEW.local_ccy, 'LOCAL') AS local_ccy
    INTO v_order
    FROM public.orders o
    JOIN public.importers i ON i.id = o.importer_id
    LEFT JOIN public.countries co ON co.id = i.country_id
    LEFT JOIN public.currencies cu ON cu.id = co.currency_id
    WHERE o.id = NEW.source_entity_id;

    IF v_order.order_total_gbp_declared IS NOT NULL
       AND v_order.order_total_gbp_declared > 0
       AND v_order.quote_total_ghs IS NOT NULL
       AND v_order.quote_total_ghs > 0 THEN
      v_rate := v_order.quote_total_ghs / v_order.order_total_gbp_declared;
    ELSIF COALESCE(v_order.quote_fx_rate, 0) > 0 THEN
      v_rate := v_order.quote_fx_rate * (1 + COALESCE(v_order.quote_card_markup_pct, 0) / 100);
    ELSE
      v_rate := 1;
    END IF;

    NEW.local_ccy := COALESCE(v_order.local_ccy, NEW.local_ccy, 'LOCAL');
    NEW.amount_local_ccy := ROUND((ABS(COALESCE(NEW.amount_gbp, 0)) * v_rate)::numeric, 2);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_settlement_credit_original_local_value_v1 ON public.importer_credit_ledger;
CREATE TRIGGER trg_settlement_credit_original_local_value_v1
BEFORE INSERT OR UPDATE OF source_type, source_entity_type, source_entity_id, direction, amount_gbp
ON public.importer_credit_ledger
FOR EACH ROW
EXECUTE FUNCTION public.settlement_credit_original_local_value_v1();

NOTIFY pgrst, 'reload schema';

COMMIT;
