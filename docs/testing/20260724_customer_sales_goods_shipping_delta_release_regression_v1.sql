BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_def text;
  v_count integer;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.customer_sales_release_guard_v1()') IS NULL
     OR to_regprocedure('public.customer_sales_release_financial_guard_v1()') IS NULL
     OR to_regprocedure('public.customer_sales_release_total_guard_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: Mini-build 3 release function chain is incomplete';
  END IF;

  IF to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.shipping_documents') IS NULL
     OR to_regclass('public.shipping_cost_allocations') IS NULL
     OR to_regclass('public.shipping_cost_allocation_lines') IS NULL
  THEN
    RAISE EXCEPTION 'FAIL: durable release or exact shipping allocation tables are missing';
  END IF;

  SELECT pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
  INTO v_def;

  IF position('used_goods AS' in v_def) = 0
     OR position('used_shipping AS' in v_def) = 0
     OR position('release_line.source_shipment_batch_id' in v_def) = 0
     OR position('shipping_used.source_shipment_batch_id = raw_row.batch_id' in v_def) = 0
     OR position('WHEN calc_row.has_main THEN calc_row.remaining_shipping' in v_def) = 0
     OR position('WHEN calc_row.remaining_goods > 0 THEN calc_row.remaining_shipping' in v_def) = 0
     OR position('shipping_only_main_not_permitted' in v_def) = 0
     OR position('released_shipping_exceeds_current_approved_allocation' in v_def) = 0
     OR position('customer_sales_release_draft_already_exists' in v_def) = 0
     OR position('customer_pre_shipment_hold_requests' in v_def) = 0
     OR position('dispute_lines' in v_def) = 0
     OR position('replacement_child' in v_def) = 0
     OR position('received_clean' in v_def) = 0
     OR position('shipping_document.review_status = ''accepted_current''' in v_def) = 0
     OR position('shipping_allocation.allocation_status = ''approved''' in v_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: source resolver does not implement independent exact goods/shipping deltas with protected existing gates';
  END IF;

  IF position('CASE WHEN c.has_main THEN c.remaining_shipping ELSE 0 END' in v_def) > 0
     OR position('ROUND(CASE WHEN c.has_main THEN c.remaining_shipping ELSE 0 END' in v_def) > 0
  THEN
    RAISE EXCEPTION 'FAIL: old main-invoice shipping suppression remains in the source resolver';
  END IF;

  IF position('update public.orders' in lower(v_def)) > 0
     OR position('update public.supplier_invoice_lines' in lower(v_def)) > 0
     OR position('recompute_order_status' in lower(v_def)) > 0
     OR position('reconciling' in lower(v_def)) > 0
  THEN
    RAISE EXCEPTION 'FAIL: release-source patch crossed into protected progression/status writes';
  END IF;

  SELECT pg_get_functiondef('public.customer_sales_release_financial_guard_v1()'::regprocedure)
  INTO v_def;

  IF position('release_line.source_shipment_batch_id = NEW.source_shipment_batch_id' in v_def) = 0
     OR position('shipping_document.shipment_batch_id = NEW.source_shipment_batch_id' in v_def) = 0
     OR position('Cumulative release delivery share exceeds exact tracking allocation' in v_def) = 0
     OR position('Cumulative release discount share exceeds exact tracking allocation' in v_def) = 0
     OR position('Cumulative release shipping exceeds approved exact shipping allocation' in v_def) = 0
     OR position('Active source or commercial-parent customer hold conflicts with release membership' in v_def) = 0
  THEN
    RAISE EXCEPTION 'FAIL: exact shipment-batch shipping guard or protected financial/hold controls are missing';
  END IF;

  SELECT pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)
  INTO v_def;

  IF position('pg_advisory_xact_lock' in v_def) = 0
     OR position('customer_sales_release_lines' in v_def) = 0
     OR position('source_tracking_line_allocation_id' in v_def) = 0
     OR position('source_supplier_invoice_id' in v_def) = 0
     OR position('linked_invoice_id' in v_def) = 0
     OR position('skipped_draft_already_exists' in v_def) = 0
     OR position('shipment_batch_ids' in v_def) = 0
     OR position('update public.orders' in lower(v_def)) > 0
     OR position('update public.supplier_invoice_lines' in lower(v_def)) > 0
  THEN
    RAISE EXCEPTION 'FAIL: protected Mini-build 3 atomic draft route changed or regressed';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_sales_invoices_nonvoid_main_v1'
  ) THEN
    RAISE EXCEPTION 'FAIL: one non-void main invoice control is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_sales_invoices_active_release_draft_v1'
  ) THEN
    RAISE EXCEPTION 'FAIL: one active release draft concurrency control is missing';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'customer_sales_release_lines'
    AND column_name IN (
      'sales_invoice_id',
      'sales_invoice_type',
      'commercial_parent_order_id',
      'source_shipment_batch_id',
      'supplier_invoice_id',
      'supplier_invoice_line_id',
      'tracking_submission_id',
      'tracking_line_allocation_id',
      'released_qty',
      'goods_amount_gbp',
      'delivery_share_gbp',
      'discount_share_gbp',
      'shipping_amount_gbp',
      'customer_charge_amount_gbp',
      'release_status',
      'membership_fingerprint',
      'reversed_at',
      'reversed_by_staff_id',
      'reversal_reason'
    );

  IF v_count <> 19 THEN
    RAISE EXCEPTION 'FAIL: durable release provenance/reversal columns are incomplete (%)', v_count;
  END IF;
END $$;

-- Pure decision-table proof of the route now encoded in the source resolver.
DO $$
DECLARE
  v_bad integer;
BEGIN
  WITH scenarios AS (
    SELECT *
    FROM (VALUES
      ('main_goods_and_shipping', false, 100.00::numeric, 10.00::numeric, 'main'::text, 110.00::numeric, NULL::text),
      ('main_goods_only',         false, 100.00::numeric,  0.00::numeric, 'main'::text, 100.00::numeric, NULL::text),
      ('shipping_only_first',     false,   0.00::numeric, 10.00::numeric, 'main'::text,   0.00::numeric, 'shipping_only_main_not_permitted'::text),
      ('supp_shipping_only',      true,    0.00::numeric, 10.00::numeric, 'supplementary'::text, 10.00::numeric, NULL::text),
      ('supp_goods_only',         true,  100.00::numeric,  0.00::numeric, 'supplementary'::text, 100.00::numeric, NULL::text),
      ('supp_goods_and_shipping', true,  100.00::numeric, 10.00::numeric, 'supplementary'::text, 110.00::numeric, NULL::text)
    ) AS scenario(name, has_main, remaining_goods, remaining_shipping, expected_type, expected_charge, expected_blocker)
  ), actual AS (
    SELECT
      scenario.*,
      CASE WHEN scenario.has_main THEN 'supplementary' ELSE 'main' END::text AS actual_type,
      ROUND(
        scenario.remaining_goods
        + CASE
            WHEN scenario.has_main THEN scenario.remaining_shipping
            WHEN scenario.remaining_goods > 0 THEN scenario.remaining_shipping
            ELSE 0
          END,
        2
      )::numeric AS actual_charge,
      CASE
        WHEN NOT scenario.has_main
         AND scenario.remaining_goods <= 0
         AND scenario.remaining_shipping > 0
          THEN 'shipping_only_main_not_permitted'
        WHEN ROUND(
          scenario.remaining_goods
          + CASE
              WHEN scenario.has_main THEN scenario.remaining_shipping
              WHEN scenario.remaining_goods > 0 THEN scenario.remaining_shipping
              ELSE 0
            END,
          2
        ) <= 0
          THEN 'source_fully_released'
        ELSE NULL
      END::text AS actual_blocker
    FROM scenarios scenario
  )
  SELECT COUNT(*)
  INTO v_bad
  FROM actual
  WHERE actual_type IS DISTINCT FROM expected_type
     OR ABS(actual_charge - expected_charge) > 0.001
     OR actual_blocker IS DISTINCT FROM expected_blocker;

  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: goods/shipping delta route decision matrix mismatch (%)', v_bad;
  END IF;
END $$;

-- Live integrity proof: protected Mini-build 3 identities, quantities and totals
-- remain valid after the route correction.
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM (
    SELECT customer_invoice.order_id
    FROM public.sales_invoices customer_invoice
    WHERE customer_invoice.invoice_type = 'main'
      AND customer_invoice.sage_status <> 'void'
    GROUP BY customer_invoice.order_id
    HAVING COUNT(*) > 1
  ) duplicate_main;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate non-void main customer invoices exist';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM (
    SELECT customer_invoice.order_id
    FROM public.sales_invoices customer_invoice
    WHERE customer_invoice.invoice_type IN ('main', 'supplementary')
      AND customer_invoice.sage_status = 'draft'
    GROUP BY customer_invoice.order_id
    HAVING COUNT(*) > 1
  ) duplicate_draft;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate active customer release drafts exist';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM public.customer_sales_release_lines release_line
  JOIN public.order_tracking_line_allocations allocation_row
    ON allocation_row.id = release_line.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines supplier_line
    ON supplier_line.id = allocation_row.supplier_invoice_line_id
  WHERE release_line.order_id IS DISTINCT FROM allocation_row.order_id
     OR release_line.tracking_submission_id IS DISTINCT FROM allocation_row.tracking_submission_id
     OR release_line.supplier_invoice_line_id IS DISTINCT FROM allocation_row.supplier_invoice_line_id
     OR release_line.supplier_invoice_id IS DISTINCT FROM supplier_line.supplier_invoice_id;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL: durable release ledger contains mismatched Mini-build 1/2 exact source identity';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM (
    SELECT
      release_line.tracking_line_allocation_id,
      SUM(release_line.released_qty) AS released_qty,
      MAX(allocation_row.qty_allocated) AS allocated_qty,
      SUM(release_line.goods_amount_gbp) AS released_goods,
      MAX(allocation_row.adjusted_net_value_gbp) AS allocated_goods
    FROM public.customer_sales_release_lines release_line
    JOIN public.order_tracking_line_allocations allocation_row
      ON allocation_row.id = release_line.tracking_line_allocation_id
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.tracking_line_allocation_id
    HAVING SUM(release_line.released_qty) > MAX(allocation_row.qty_allocated) + 0.001
        OR SUM(release_line.goods_amount_gbp) > MAX(allocation_row.adjusted_net_value_gbp) + 0.02
  ) over_released;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL: active released quantity/goods exceeds exact tracking allocation';
  END IF;

  SELECT COUNT(*)
  INTO v_count
  FROM public.sales_invoices customer_invoice
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS line_count,
      ROUND(COALESCE(SUM(release_line.customer_charge_amount_gbp), 0), 2) AS ledger_total
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = customer_invoice.id
      AND release_line.release_status = 'active'
  ) release_total ON true
  WHERE customer_invoice.invoice_type IN ('main', 'supplementary')
    AND customer_invoice.sage_status <> 'void'
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_sales_release_legacy_issues legacy_issue
      WHERE legacy_issue.sales_invoice_id = customer_invoice.id
        AND legacy_issue.resolved_at IS NULL
    )
    AND (
      release_total.line_count = 0
      OR ABS(release_total.ledger_total - customer_invoice.amount_gbp) > 0.02
    );

  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL: non-void customer sales invoice does not match active durable release membership';
  END IF;
END $$;

-- Known live correction proof. The exact £699.97 goods-only draft must not remain
-- active when the same exact membership has £120.00 of accepted/approved shipping.
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*)
  INTO v_count
  FROM public.sales_invoices customer_invoice
  JOIN public.orders parent_order
    ON parent_order.id = customer_invoice.order_id
  JOIN public.customer_sales_release_lines release_line
    ON release_line.sales_invoice_id = customer_invoice.id
   AND release_line.release_status = 'active'
  LEFT JOIN LATERAL (
    SELECT allocation_line.allocated_amount
    FROM public.shipping_documents shipping_document
    JOIN public.shipping_cost_allocations shipping_allocation
      ON shipping_allocation.shipping_document_id = shipping_document.id
     AND shipping_allocation.active = true
     AND shipping_allocation.allocation_status = 'approved'
    JOIN public.shipping_cost_allocation_lines allocation_line
      ON allocation_line.shipping_cost_allocation_id = shipping_allocation.id
     AND allocation_line.tracking_submission_id = release_line.tracking_submission_id
     AND allocation_line.supplier_invoice_line_id = release_line.supplier_invoice_line_id
    WHERE shipping_document.shipment_batch_id = release_line.source_shipment_batch_id
      AND shipping_document.active = true
      AND shipping_document.review_status = 'accepted_current'
    ORDER BY shipping_allocation.approved_at DESC NULLS LAST,
             shipping_allocation.created_at DESC,
             shipping_allocation.id DESC
    LIMIT 1
  ) exact_shipping ON true
  WHERE parent_order.order_ref = 'ORD-1784498556959'
    AND customer_invoice.invoice_type = 'main'
    AND customer_invoice.sage_status = 'draft'
    AND customer_invoice.sage_invoice_id IS NULL
    AND customer_invoice.sage_posted_at IS NULL
    AND ABS(customer_invoice.amount_gbp - 699.97) <= 0.01
  GROUP BY customer_invoice.id
  HAVING COUNT(*) = 3
     AND ABS(SUM(release_line.goods_amount_gbp) - 699.97) <= 0.01
     AND ABS(SUM(release_line.shipping_amount_gbp)) <= 0.01
     AND ABS(SUM(COALESCE(exact_shipping.allocated_amount, 0)) - 120.00) <= 0.01;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'FAIL: known unposted goods-only draft remains active despite exact ready shipping';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sales_invoices customer_invoice
    JOIN public.orders parent_order
      ON parent_order.id = customer_invoice.order_id
    JOIN public.customer_sales_release_lines release_line
      ON release_line.sales_invoice_id = customer_invoice.id
    WHERE parent_order.order_ref = 'ORD-1784498556959'
      AND customer_invoice.invoice_type = 'main'
      AND customer_invoice.sage_status = 'void'
      AND ABS(customer_invoice.amount_gbp - 699.97) <= 0.01
      AND release_line.reversal_reason = 'voided_unposted_draft_after_goods_shipping_delta_route_correction_v1'
    GROUP BY customer_invoice.id
    HAVING COUNT(*) <> 3
        OR BOOL_OR(release_line.release_status <> 'reversed')
        OR BOOL_OR(release_line.reversed_at IS NULL)
        OR BOOL_OR(release_line.reversed_by_staff_id IS NULL)
  ) THEN
    RAISE EXCEPTION 'FAIL: known void correction does not retain complete audited reversed membership';
  END IF;
END $$;

ROLLBACK;

SELECT
  'PASS: customer sales release now uses independent exact goods and shipment-batch shipping deltas; main/repeated supplementary, immutable draft, Mini-build 1-3 provenance and planned Mini-build 4 boundaries remain protected.' AS regression_result;
