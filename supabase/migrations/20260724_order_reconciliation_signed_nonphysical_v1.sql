BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow reconciliation patch.
-- Preserve every existing order_reconciliation_vw calculation and join exactly,
-- then add each order's active non-physical financial resolution once.
-- No invoice-line, dispute, approval, tracking, banking, VAT or Sage data is
-- changed by this migration.
--
-- Commercial sign is deterministic only for explicit types:
--   delivery / fee  = increase accounted order value
--   discount        = reduce accounted order value
--   zero delivery   = zero
-- Ambiguous rounding / other rows remain unresolved rather than being guessed.

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoices'; END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoice_lines'; END IF;
  IF to_regclass('public.disputes') IS NULL THEN RAISE EXCEPTION 'Missing public.disputes'; END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dispute_lines'; END IF;
  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoice_line_resolutions'; END IF;
  IF to_regclass('public.order_reconciliation_vw') IS NULL THEN RAISE EXCEPTION 'Missing public.order_reconciliation_vw'; END IF;
END $$;

CREATE OR REPLACE VIEW public.order_reconciliation_vw AS
WITH resolved_nonphysical AS (
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
)
SELECT
  o.id AS order_id,
  o.total_qty_declared AS qty_target,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0) AS qty_progressed_invoiceable,
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) AS qty_resolved_noninvoiceable,
  o.total_qty_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0)
    AS qty_unresolved,
  o.order_total_gbp_declared AS amount_target_gbp,
  COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0) AS amount_progressed_invoiceable_gbp,
  COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    + COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0)
    AS amount_resolved_noninvoiceable_gbp,
  o.order_total_gbp_declared
    - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
    - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
    - COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0)
    AS amount_unresolved_gbp,
  CASE WHEN EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil2
    JOIN public.supplier_invoices si2 ON si2.id = sil2.supplier_invoice_id
    WHERE si2.order_id = o.id
      AND sil2.eligible_for_invoice_yn = 'Y'
  ) THEN true ELSE false END AS invoiceable_subset_released_yn,
  CASE WHEN (
    o.total_qty_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) = 0
    AND o.order_total_gbp_declared
      - COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0)
      - COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0)
      - COALESCE(MAX(rn.signed_nonphysical_amount_gbp), 0) = 0
  ) THEN true ELSE false END AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM public.orders o
LEFT JOIN public.supplier_invoices si ON si.order_id = o.id
LEFT JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
LEFT JOIN public.disputes d ON d.order_id = o.id
LEFT JOIN public.dispute_lines dl ON dl.dispute_id = d.id
LEFT JOIN resolved_nonphysical rn ON rn.order_id = o.id
GROUP BY o.id, o.total_qty_declared, o.order_total_gbp_declared;

COMMENT ON VIEW public.order_reconciliation_vw IS
'Baseline order reconciliation preserved, with active non-physical financial resolutions added once per order using explicit commercial sign: delivery/fee positive, discount negative and zero-value delivery zero. Ambiguous types remain unresolved.';

-- Preserve the exact public view contract used by existing pages and helpers.
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

-- Known live-order regression. It runs only when the exact £5 delivery evidence
-- exists and proves that the existing £5 gap is closed without changing qty.
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
