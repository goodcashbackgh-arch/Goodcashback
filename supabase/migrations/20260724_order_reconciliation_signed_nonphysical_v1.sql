BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Reconcile explicit non-physical supplier-invoice resolutions without changing
-- source invoice lines, tracking eligibility, disputes, supplier approvals or
-- accounting postings.
--
-- Commercial sign is deterministic only for the currently explicit types:
--   delivery / fee  = increase the accounted order value
--   discount        = reduce the accounted order value
--   zero delivery   = zero
-- Ambiguous rounding / other rows remain in amount_unresolved_gbp rather than
-- being guessed into a sign.

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Missing public.orders';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Missing public.disputes';
  END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN
    RAISE EXCEPTION 'Missing public.dispute_lines';
  END IF;
  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN
    RAISE EXCEPTION 'Missing public.supplier_invoice_line_resolutions';
  END IF;
  IF to_regclass('public.order_reconciliation_vw') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_reconciliation_vw';
  END IF;
END $$;

CREATE OR REPLACE VIEW public.order_reconciliation_vw AS
WITH invoice_progress AS (
  SELECT
    si.order_id,
    COALESCE(SUM(CASE
      WHEN lower(btrim(COALESCE(sil.eligible_for_invoice_yn::text, ''))) IN ('y','yes','true','1')
      THEN COALESCE(sil.qty_confirmed, 0)
      ELSE 0
    END), 0)::numeric AS qty_progressed_invoiceable,
    COALESCE(SUM(CASE
      WHEN lower(btrim(COALESCE(sil.eligible_for_invoice_yn::text, ''))) IN ('y','yes','true','1')
      THEN COALESCE(sil.amount_confirmed, 0)
      ELSE 0
    END), 0)::numeric AS amount_progressed_invoiceable_gbp,
    BOOL_OR(
      lower(btrim(COALESCE(sil.eligible_for_invoice_yn::text, ''))) IN ('y','yes','true','1')
    ) AS invoiceable_subset_released_yn
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil
    ON sil.supplier_invoice_id = si.id
  GROUP BY si.order_id
), resolved_exceptions AS (
  SELECT
    d.order_id,
    COALESCE(SUM(CASE
      WHEN dl.line_status = 'resolved' THEN COALESCE(dl.qty_impact, 0)
      ELSE 0
    END), 0)::numeric AS qty_resolved_exception,
    COALESCE(SUM(CASE
      WHEN dl.line_status = 'resolved' THEN COALESCE(dl.amount_impact_gbp, 0)
      ELSE 0
    END), 0)::numeric AS amount_resolved_exception_gbp
  FROM public.disputes d
  JOIN public.dispute_lines dl
    ON dl.dispute_id = d.id
  GROUP BY d.order_id
), resolved_nonphysical AS (
  SELECT
    r.order_id,
    COALESCE(SUM(
      CASE r.financial_type
        WHEN 'delivery' THEN ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'fee' THEN ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'discount' THEN -ABS(COALESCE(r.amount_gbp, 0))
        WHEN 'zero_value_delivery' THEN 0::numeric
        ELSE 0::numeric
      END
    ), 0)::numeric AS signed_nonphysical_amount_gbp
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.active = true
    AND r.resolution_type = 'non_physical_financial'
  GROUP BY r.order_id
), reconciled AS (
  SELECT
    o.id AS order_id,
    o.total_qty_declared AS qty_target,
    COALESCE(ip.qty_progressed_invoiceable, 0)::numeric AS qty_progressed_invoiceable,
    COALESCE(re.qty_resolved_exception, 0)::numeric AS qty_resolved_noninvoiceable,
    (
      COALESCE(o.total_qty_declared, 0)::numeric
      - COALESCE(ip.qty_progressed_invoiceable, 0)::numeric
      - COALESCE(re.qty_resolved_exception, 0)::numeric
    ) AS qty_unresolved,
    o.order_total_gbp_declared AS amount_target_gbp,
    COALESCE(ip.amount_progressed_invoiceable_gbp, 0)::numeric AS amount_progressed_invoiceable_gbp,
    (
      COALESCE(re.amount_resolved_exception_gbp, 0)::numeric
      + COALESCE(rn.signed_nonphysical_amount_gbp, 0)::numeric
    ) AS amount_resolved_noninvoiceable_gbp,
    (
      COALESCE(o.order_total_gbp_declared, 0)::numeric
      - COALESCE(ip.amount_progressed_invoiceable_gbp, 0)::numeric
      - COALESCE(re.amount_resolved_exception_gbp, 0)::numeric
      - COALESCE(rn.signed_nonphysical_amount_gbp, 0)::numeric
    ) AS amount_unresolved_gbp,
    COALESCE(ip.invoiceable_subset_released_yn, false) AS invoiceable_subset_released_yn
  FROM public.orders o
  LEFT JOIN invoice_progress ip
    ON ip.order_id = o.id
  LEFT JOIN resolved_exceptions re
    ON re.order_id = o.id
  LEFT JOIN resolved_nonphysical rn
    ON rn.order_id = o.id
)
SELECT
  r.order_id,
  r.qty_target,
  r.qty_progressed_invoiceable,
  r.qty_resolved_noninvoiceable,
  r.qty_unresolved,
  r.amount_target_gbp,
  r.amount_progressed_invoiceable_gbp,
  r.amount_resolved_noninvoiceable_gbp,
  r.amount_unresolved_gbp,
  r.invoiceable_subset_released_yn,
  (
    ABS(COALESCE(r.qty_unresolved, 0)) < 0.001
    AND ABS(COALESCE(r.amount_unresolved_gbp, 0)) <= 0.01
  ) AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM reconciled r;

COMMENT ON VIEW public.order_reconciliation_vw IS
'Canonical order reconciliation. Progressed physical lines and resolved disputes retain their existing treatment. Active non-physical financial resolutions contribute with explicit commercial sign: delivery/fee positive, discount negative, zero-value delivery zero; ambiguous types remain unresolved rather than guessed.';

-- Preserve the public view contract relied on by existing pages and helpers.
DO $$
DECLARE
  v_columns text;
BEGIN
  SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    INTO v_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'order_reconciliation_vw';

  IF v_columns IS DISTINCT FROM
    'order_id,qty_target,qty_progressed_invoiceable,qty_resolved_noninvoiceable,qty_unresolved,amount_target_gbp,amount_progressed_invoiceable_gbp,amount_resolved_noninvoiceable_gbp,amount_unresolved_gbp,invoiceable_subset_released_yn,whole_order_cleared_yn,last_refreshed_at' THEN
    RAISE EXCEPTION 'order_reconciliation_vw contract changed unexpectedly: %', v_columns;
  END IF;
END $$;

-- Live-order regression: only run where the known evidence exists. This proves
-- the £5 delivery resolution closes the exact £5 amount gap without altering qty.
DO $$
DECLARE
  v_row record;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_line_resolutions r
    WHERE r.order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid
      AND r.active = true
      AND r.resolution_type = 'non_physical_financial'
      AND r.financial_type = 'delivery'
      AND ROUND(ABS(COALESCE(r.amount_gbp, 0))::numeric, 2) = 5.00
  ) THEN
    SELECT * INTO v_row
    FROM public.order_reconciliation_vw
    WHERE order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid;

    IF ROUND(COALESCE(v_row.amount_resolved_noninvoiceable_gbp, 0)::numeric, 2) < 5.00 THEN
      RAISE EXCEPTION 'Known £5 delivery resolution was not included in reconciliation';
    END IF;

    IF ABS(ROUND(COALESCE(v_row.amount_unresolved_gbp, 0)::numeric, 2)) > 0.01 THEN
      RAISE EXCEPTION 'Known order amount remains unresolved after signed non-physical reconciliation: %', v_row.amount_unresolved_gbp;
    END IF;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
