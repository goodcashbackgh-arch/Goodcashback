BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Protective canonical-integrity patch only.
-- 1. Preserve the public order_reconciliation_vw contract and calculations while
--    preventing independent supplier-line and dispute-line sets from multiplying
--    one another through the previous order-level join fan-out.
-- 2. Prevent a confirmed retailer-refund allocation from being reversed after its
--    linked dispute has already reached a terminal state. A controlled reopen route
--    must be introduced before such a reversal is permitted.
--
-- No source rows are rewritten by this migration. No funding, supplier allocation,
-- hold, shipment, customer-sales, Sage or VAT calculation is changed.

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN RAISE EXCEPTION 'Missing public.orders'; END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoices'; END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoice_lines'; END IF;
  IF to_regclass('public.disputes') IS NULL THEN RAISE EXCEPTION 'Missing public.disputes'; END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dispute_lines'; END IF;
  IF to_regclass('public.supplier_invoice_line_resolutions') IS NULL THEN RAISE EXCEPTION 'Missing public.supplier_invoice_line_resolutions'; END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_line_allocations'; END IF;
END $$;

CREATE OR REPLACE VIEW public.order_reconciliation_vw AS
WITH supplier_line_totals AS (
  SELECT
    si.order_id,
    COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.qty_confirmed ELSE 0 END), 0) AS qty_progressed_invoiceable,
    COALESCE(SUM(CASE WHEN sil.eligible_for_invoice_yn = 'Y' THEN sil.amount_confirmed ELSE 0 END), 0) AS amount_progressed_invoiceable_gbp
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_lines sil ON sil.supplier_invoice_id = si.id
  GROUP BY si.order_id
),
dispute_line_totals AS (
  SELECT
    d.order_id,
    COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.qty_impact ELSE 0 END), 0) AS qty_resolved_noninvoiceable,
    COALESCE(SUM(CASE WHEN dl.line_status = 'resolved' THEN dl.amount_impact_gbp ELSE 0 END), 0) AS amount_resolved_dispute_gbp
  FROM public.disputes d
  JOIN public.dispute_lines dl ON dl.dispute_id = d.id
  GROUP BY d.order_id
),
resolved_nonphysical AS (
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
  COALESCE(slt.qty_progressed_invoiceable, 0) AS qty_progressed_invoiceable,
  COALESCE(dlt.qty_resolved_noninvoiceable, 0) AS qty_resolved_noninvoiceable,
  o.total_qty_declared
    - COALESCE(slt.qty_progressed_invoiceable, 0)
    - COALESCE(dlt.qty_resolved_noninvoiceable, 0)
    AS qty_unresolved,
  o.order_total_gbp_declared AS amount_target_gbp,
  COALESCE(slt.amount_progressed_invoiceable_gbp, 0) AS amount_progressed_invoiceable_gbp,
  COALESCE(dlt.amount_resolved_dispute_gbp, 0)
    + COALESCE(rn.signed_nonphysical_amount_gbp, 0)
    AS amount_resolved_noninvoiceable_gbp,
  o.order_total_gbp_declared
    - COALESCE(slt.amount_progressed_invoiceable_gbp, 0)
    - COALESCE(dlt.amount_resolved_dispute_gbp, 0)
    - COALESCE(rn.signed_nonphysical_amount_gbp, 0)
    AS amount_unresolved_gbp,
  EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil2
    JOIN public.supplier_invoices si2 ON si2.id = sil2.supplier_invoice_id
    WHERE si2.order_id = o.id
      AND sil2.eligible_for_invoice_yn = 'Y'
  ) AS invoiceable_subset_released_yn,
  (
    o.total_qty_declared
      - COALESCE(slt.qty_progressed_invoiceable, 0)
      - COALESCE(dlt.qty_resolved_noninvoiceable, 0) = 0
    AND o.order_total_gbp_declared
      - COALESCE(slt.amount_progressed_invoiceable_gbp, 0)
      - COALESCE(dlt.amount_resolved_dispute_gbp, 0)
      - COALESCE(rn.signed_nonphysical_amount_gbp, 0) = 0
  ) AS whole_order_cleared_yn,
  now() AS last_refreshed_at
FROM public.orders o
LEFT JOIN supplier_line_totals slt ON slt.order_id = o.id
LEFT JOIN dispute_line_totals dlt ON dlt.order_id = o.id
LEFT JOIN resolved_nonphysical rn ON rn.order_id = o.id;

COMMENT ON VIEW public.order_reconciliation_vw IS
'Order reconciliation using independently aggregated supplier-line, resolved-dispute-line and active non-physical financial facts, preventing cross-source join multiplication while preserving the existing public column contract and commercial signs.';

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

CREATE OR REPLACE FUNCTION public.prevent_terminal_retailer_refund_allocation_reversal_v1()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.allocation_type = 'retailer_refund'
     AND OLD.allocation_status = 'confirmed'
     AND NEW.allocation_status = 'reversed'
     AND OLD.dispute_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.disputes d
       WHERE d.id = OLD.dispute_id
         AND (
           d.resolved_at IS NOT NULL
           OR COALESCE(d.status::text, '') IN ('closed', 'resolved', 'refunded', 'replaced', 'closed_no_action')
         )
     ) THEN
    RAISE EXCEPTION
      'Cannot reverse confirmed retailer refund allocation % because linked dispute % is terminal. Use a controlled canonical reopen-and-reverse route.',
      OLD.id,
      OLD.dispute_id;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.prevent_terminal_retailer_refund_allocation_reversal_v1() IS
'Blocks reversal of a confirmed retailer-refund allocation after its linked dispute is terminal, preventing economic evidence from being removed while canonical status remains closed.';

DROP TRIGGER IF EXISTS trg_prevent_terminal_retailer_refund_reversal_v1
  ON public.dva_statement_line_allocations;

CREATE TRIGGER trg_prevent_terminal_retailer_refund_reversal_v1
BEFORE UPDATE OF allocation_status
ON public.dva_statement_line_allocations
FOR EACH ROW
EXECUTE FUNCTION public.prevent_terminal_retailer_refund_allocation_reversal_v1();

-- Guarded live regression: preserve the already-proven order result when present.
DO $$
DECLARE
  v_row public.order_reconciliation_vw%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM public.order_reconciliation_vw
  WHERE order_id = '4011beb5-ef07-4af1-9c06-72e44445777c'::uuid;

  IF FOUND THEN
    IF ROUND(COALESCE(v_row.qty_progressed_invoiceable, 0)::numeric, 2) <> 4.00
       OR ROUND(COALESCE(v_row.amount_progressed_invoiceable_gbp, 0)::numeric, 2) <> 879.96
       OR ROUND(COALESCE(v_row.amount_resolved_noninvoiceable_gbp, 0)::numeric, 2) <> 5.00
       OR ROUND(COALESCE(v_row.amount_unresolved_gbp, 0)::numeric, 2) <> 0.00
       OR COALESCE(v_row.whole_order_cleared_yn, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'Known order reconciliation changed unexpectedly after fan-out protection: %', row_to_json(v_row);
    END IF;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
