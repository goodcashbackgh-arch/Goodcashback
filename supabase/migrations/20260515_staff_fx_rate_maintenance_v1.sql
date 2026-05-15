-- Staff FX rate maintenance RPC
-- Purpose: allow admin/supervisor staff to upsert one FX rate per country/date
-- without opening direct table writes through RLS.

CREATE OR REPLACE FUNCTION public.staff_upsert_fx_rate_v1(
  p_country_id uuid,
  p_rate_date date,
  p_quote_rate numeric,
  p_quote_card_markup_pct numeric DEFAULT 0,
  p_settlement_rate numeric DEFAULT NULL,
  p_settlement_card_markup_pct numeric DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  country_id uuid,
  rate_date date,
  quote_rate numeric,
  quote_card_markup_pct numeric,
  settlement_rate numeric,
  settlement_card_markup_pct numeric,
  entered_by_staff_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin', 'supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Only active admin or supervisor staff can maintain FX rates.';
  END IF;

  IF p_country_id IS NULL THEN
    RAISE EXCEPTION 'Country is required.';
  END IF;

  IF p_rate_date IS NULL THEN
    RAISE EXCEPTION 'Rate date is required.';
  END IF;

  IF p_quote_rate IS NULL OR p_quote_rate <= 0 THEN
    RAISE EXCEPTION 'Quote rate must be greater than zero.';
  END IF;

  IF COALESCE(p_settlement_rate, p_quote_rate) <= 0 THEN
    RAISE EXCEPTION 'Settlement rate must be greater than zero.';
  END IF;

  IF COALESCE(p_quote_card_markup_pct, 0) < 0 THEN
    RAISE EXCEPTION 'Quote card markup cannot be negative.';
  END IF;

  IF COALESCE(p_settlement_card_markup_pct, 0) < 0 THEN
    RAISE EXCEPTION 'Settlement card markup cannot be negative.';
  END IF;

  RETURN QUERY
  INSERT INTO public.fx_rates AS fx (
    country_id,
    rate_date,
    quote_rate,
    quote_card_markup_pct,
    settlement_rate,
    settlement_card_markup_pct,
    entered_by_staff_id
  ) VALUES (
    p_country_id,
    p_rate_date,
    p_quote_rate,
    COALESCE(p_quote_card_markup_pct, 0),
    COALESCE(p_settlement_rate, p_quote_rate),
    COALESCE(p_settlement_card_markup_pct, 0),
    v_staff_id
  )
  ON CONFLICT ON CONSTRAINT fx_rates_country_id_rate_date_key
  DO UPDATE SET
    quote_rate = EXCLUDED.quote_rate,
    quote_card_markup_pct = EXCLUDED.quote_card_markup_pct,
    settlement_rate = EXCLUDED.settlement_rate,
    settlement_card_markup_pct = EXCLUDED.settlement_card_markup_pct,
    entered_by_staff_id = v_staff_id
  RETURNING
    fx.id,
    fx.country_id,
    fx.rate_date,
    fx.quote_rate,
    fx.quote_card_markup_pct,
    fx.settlement_rate,
    fx.settlement_card_markup_pct,
    fx.entered_by_staff_id;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_upsert_fx_rate_v1(uuid, date, numeric, numeric, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_upsert_fx_rate_v1(uuid, date, numeric, numeric, numeric, numeric) TO authenticated;
