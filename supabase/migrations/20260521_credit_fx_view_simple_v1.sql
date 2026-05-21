BEGIN;

CREATE OR REPLACE VIEW public.importer_credit_current_fx_v1 AS
WITH latest_fx AS (
  SELECT DISTINCT ON (fr.country_id)
    fr.country_id,
    fr.rate_date,
    (fr.quote_rate * (1 + COALESCE(fr.quote_card_markup_pct, 0) / 100))::numeric AS effective_rate
  FROM public.fx_rates fr
  WHERE fr.rate_date <= CURRENT_DATE
  ORDER BY fr.country_id, fr.rate_date DESC, fr.created_at DESC
), ledger AS (
  SELECT
    i.id AS importer_id,
    COALESCE(cu.code, 'LOCAL') AS local_ccy,
    COALESCE(lfx.rate_date, CURRENT_DATE) AS fx_rate_date,
    COALESCE(NULLIF(lfx.effective_rate, 0), 1)::numeric AS effective_rate,
    CASE WHEN icl.direction = 'credit' THEN 1 WHEN icl.direction = 'debit' THEN -1 ELSE 0 END AS sign,
    CASE
      WHEN icl.local_ccy = COALESCE(cu.code, 'LOCAL') AND COALESCE(icl.amount_local_ccy, 0) > 0 THEN ABS(icl.amount_local_ccy)::numeric
      ELSE ABS(COALESCE(icl.amount_gbp, 0))::numeric * COALESCE(NULLIF(lfx.effective_rate, 0), 1)::numeric
    END AS local_value
  FROM public.importers i
  LEFT JOIN public.countries co ON co.id = i.country_id
  LEFT JOIN public.currencies cu ON cu.id = co.currency_id
  LEFT JOIN latest_fx lfx ON lfx.country_id = i.country_id
  LEFT JOIN public.importer_credit_ledger icl ON icl.importer_id = i.id AND icl.lock_reason IS NULL
)
SELECT
  importer_id,
  local_ccy,
  fx_rate_date,
  ROUND(effective_rate, 8) AS current_effective_rate,
  ROUND(COALESCE(SUM(sign * local_value), 0)::numeric, 2) AS available_credit_local_ccy,
  ROUND((COALESCE(SUM(sign * local_value), 0) / NULLIF(MAX(effective_rate), 0))::numeric, 2) AS available_credit_gbp
FROM ledger
GROUP BY importer_id, local_ccy, fx_rate_date, effective_rate;

NOTIFY pgrst, 'reload schema';

COMMIT;
