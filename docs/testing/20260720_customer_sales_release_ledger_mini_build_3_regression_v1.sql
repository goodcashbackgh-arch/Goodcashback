BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $$
DECLARE
  v_def text;
  v_count integer;
BEGIN
  IF to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.customer_sales_release_legacy_issues') IS NULL
  THEN RAISE EXCEPTION 'FAIL: Mini-build 3 durable release tables missing'; END IF;

  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid)') IS NULL
  THEN RAISE EXCEPTION 'FAIL: Mini-build 3 function chain incomplete'; END IF;

  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='customer_sales_release_lines'
    AND column_name IN (
      'sales_invoice_id','sales_invoice_type','order_id','commercial_parent_order_id',
      'source_shipment_batch_id','supplier_invoice_id','supplier_invoice_line_id',
      'tracking_submission_id','tracking_line_allocation_id','released_qty',
      'goods_amount_gbp','delivery_share_gbp','discount_share_gbp','shipping_amount_gbp',
      'customer_charge_amount_gbp','release_status','membership_fingerprint','created_at','reversed_at'
    );
  IF v_count<>19 THEN RAISE EXCEPTION 'FAIL: exact release provenance columns incomplete (%)',v_count; END IF;

  IF has_table_privilege('authenticated','public.customer_sales_release_lines','INSERT')
     OR has_table_privilege('authenticated','public.customer_sales_release_lines','UPDATE')
  THEN RAISE EXCEPTION 'FAIL: authenticated role has direct release-ledger write access'; END IF;

  IF NOT has_table_privilege('authenticated','public.customer_sales_release_lines','SELECT')
  THEN RAISE EXCEPTION 'FAIL: staff cannot read release provenance'; END IF;

  IF has_function_privilege('authenticated','public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid)','EXECUTE')
     OR has_function_privilege('anon','public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid)','EXECUTE')
  THEN RAISE EXCEPTION 'FAIL: pre-ledger Sage resolver remains directly callable'; END IF;

  IF NOT has_function_privilege('authenticated','public.internal_resolved_customer_sales_sage_payload_v1(uuid)','EXECUTE')
  THEN RAISE EXCEPTION 'FAIL: staff cannot execute the authoritative Sage resolver'; END IF;

  SELECT pg_get_functiondef('public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure)
    INTO v_def;
  IF position('pg_advisory_xact_lock' in v_def)=0
     OR position('customer_sales_release_lines' in v_def)=0
     OR position('source_tracking_line_allocation_id' in v_def)=0
     OR position('source_supplier_invoice_id' in v_def)=0
     OR position('linked_invoice_id' in v_def)=0
     OR position('skipped_draft_already_exists' in v_def)=0
     OR position('shipment_batch_ids' in v_def)=0
     OR position('update public.orders' in lower(v_def))>0
     OR position('update public.supplier_invoice_lines' in lower(v_def))>0
     OR position('recompute_order_status' in lower(v_def))>0
     OR position('reconciling' in lower(v_def))>0
  THEN RAISE EXCEPTION 'FAIL: draft RPC is not the bounded atomic existing-route patch'; END IF;

  SELECT pg_get_functiondef('public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure)
    INTO v_def;
  IF position('customer_sales_release_lines' in v_def)=0
     OR position('replacement_child' in v_def)=0
     OR position('received_clean' in v_def)=0
     OR position('customer_pre_shipment_hold_requests' in v_def)=0
     OR position('dispute_lines' in v_def)=0
     OR position('customer_sales_release_legacy_provenance_unresolved' in v_def)=0
     OR position('supplementary' in v_def)=0
  THEN RAISE EXCEPTION 'FAIL: source resolver misses release, replacement, receipt, hold, exception, legacy or repeated supplementary control'; END IF;

  SELECT pg_get_functiondef('public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure)
    INTO v_def;
  IF position('source_tracking_line_allocation_id' in v_def)=0
     OR position('source_supplier_invoice_id' in v_def)=0
     OR position('membership_fingerprint' in v_def)=0
  THEN RAISE EXCEPTION 'FAIL: existing preview does not preserve exact source membership'; END IF;

  SELECT pg_get_functiondef('public.customer_sales_release_guard_v1()'::regprocedure)
    INTO v_def;
  IF position('FOR UPDATE OF a' in v_def)=0
     OR position('received_clean' in v_def)=0
     OR position('Active customer hold' in v_def)=0
     OR position('Unresolved exception' in v_def)=0
     OR position('Release quantity exceeds exact tracking allocation' in v_def)=0
     OR position('active Sage snapshot' in v_def)=0
  THEN RAISE EXCEPTION 'FAIL: database release guard is incomplete'; END IF;

  SELECT pg_get_functiondef('public.internal_resolved_customer_sales_sage_payload_v1(uuid)'::regprocedure)
    INTO v_def;
  IF position('customer_sales_release_lines' in v_def)=0
     OR position('durable_release_membership_authoritative' in v_def)=0
     OR position('blocked_customer_sales_release_provenance_unresolved' in v_def)=0
     OR position('blocked_customer_sales_release_ledger_amount_mismatch' in v_def)=0
     OR position('resolver_control' in v_def)=0
  THEN RAISE EXCEPTION 'FAIL: existing Sage resolver is not ledger authoritative/fail closed'; END IF;

  SELECT pg_get_functiondef('public.customer_sales_release_financial_guard_v1()'::regprocedure)
    INTO v_def;
  IF position('commercial-parent customer hold' in v_def)=0
     OR position('Cumulative release delivery share' in v_def)=0
     OR position('Cumulative release discount share' in v_def)=0
     OR position('Shipping release requires exact source shipment batch' in v_def)=0
     OR position('Cumulative release shipping exceeds approved exact shipping allocation' in v_def)=0
  THEN RAISE EXCEPTION 'FAIL: cumulative financial and shipping release guard is incomplete'; END IF;

  SELECT pg_get_functiondef('public.customer_sales_release_total_guard_v1()'::regprocedure)
    INTO v_def;
  IF position('Durable release total does not match non-void customer sales invoice amount' in v_def)=0
  THEN RAISE EXCEPTION 'FAIL: deferred invoice-to-ledger total guard is missing'; END IF;

  SELECT pg_get_functiondef('public.operator_bulk_mark_supplier_invoice_lines_progressed(uuid,uuid[])'::regprocedure)
    INTO v_def;
  IF v_def ILIKE '%FOREACH%' OR v_def NOT ILIKE '%UPDATE public.supplier_invoice_lines%'
  THEN RAISE EXCEPTION 'FAIL: protected set-based bulk progression regressed'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='uq_sales_invoices_nonvoid_main_v1'
      AND lower(indexdef) LIKE '%invoice_type%'
      AND lower(indexdef) LIKE '%main%'
      AND lower(indexdef) LIKE '%sage_status%'
      AND lower(indexdef) LIKE '%void%'
  ) THEN RAISE EXCEPTION 'FAIL: one non-void main control missing'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='uq_sales_invoices_active_release_draft_v1'
      AND lower(indexdef) LIKE '%invoice_type%'
      AND lower(indexdef) LIKE '%main%'
      AND lower(indexdef) LIKE '%supplementary%'
      AND lower(indexdef) LIKE '%sage_status%'
      AND lower(indexdef) LIKE '%draft%'
  ) THEN RAISE EXCEPTION 'FAIL: active release draft concurrency control missing'; END IF;
END $$;

DO $$
DECLARE v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM (
    SELECT order_id FROM public.sales_invoices
    WHERE invoice_type='main' AND sage_status<>'void'
    GROUP BY order_id HAVING COUNT(*)>1
  ) x;
  IF v_count>0 THEN RAISE EXCEPTION 'FAIL: duplicate non-void main invoices exist'; END IF;

  SELECT COUNT(*) INTO v_count
  FROM (
    SELECT order_id FROM public.sales_invoices
    WHERE invoice_type IN ('main','supplementary') AND sage_status='draft'
    GROUP BY order_id HAVING COUNT(*)>1
  ) x;
  IF v_count>0 THEN RAISE EXCEPTION 'FAIL: concurrent active release drafts exist'; END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.customer_sales_release_lines l
  JOIN public.order_tracking_line_allocations a ON a.id=l.tracking_line_allocation_id
  JOIN public.supplier_invoice_lines sil ON sil.id=a.supplier_invoice_line_id
  WHERE l.order_id IS DISTINCT FROM a.order_id
     OR l.tracking_submission_id IS DISTINCT FROM a.tracking_submission_id
     OR l.supplier_invoice_line_id IS DISTINCT FROM a.supplier_invoice_line_id
     OR l.supplier_invoice_id IS DISTINCT FROM sil.supplier_invoice_id;
  IF v_count>0 THEN RAISE EXCEPTION 'FAIL: release ledger contains mismatched exact source identity'; END IF;

  SELECT COUNT(*) INTO v_count
  FROM (
    SELECT l.tracking_line_allocation_id,
      SUM(l.released_qty) qty,MAX(a.qty_allocated) max_qty,
      SUM(l.goods_amount_gbp) goods,MAX(a.adjusted_net_value_gbp) max_goods
    FROM public.customer_sales_release_lines l
    JOIN public.order_tracking_line_allocations a ON a.id=l.tracking_line_allocation_id
    WHERE l.release_status='active'
    GROUP BY l.tracking_line_allocation_id
    HAVING SUM(l.released_qty)>MAX(a.qty_allocated)+0.001
        OR SUM(l.goods_amount_gbp)>MAX(a.adjusted_net_value_gbp)+0.02
  ) x;
  IF v_count>0 THEN RAISE EXCEPTION 'FAIL: released quantity/value exceeds exact allocation'; END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.sales_invoices si
  LEFT JOIN LATERAL (
    SELECT COUNT(*) cnt,ROUND(COALESCE(SUM(l.customer_charge_amount_gbp),0),2) total
    FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id=si.id AND l.release_status='active'
  ) x ON true
  WHERE si.invoice_type IN ('main','supplementary') AND si.sage_status<>'void'
    AND NOT EXISTS (
      SELECT 1 FROM public.customer_sales_release_legacy_issues li
      WHERE li.sales_invoice_id=si.id AND li.resolved_at IS NULL
    )
    AND (x.cnt=0 OR ABS(x.total-si.amount_gbp)>0.02);
  IF v_count>0 THEN RAISE EXCEPTION 'FAIL: non-void sales invoice lacks exact matching ledger or explicit legacy blocker'; END IF;
END $$;

ROLLBACK;

SELECT 'PASS: Mini-build 3 durable exact customer-sales release ledger, repeated supplementary route, idempotency/concurrency guards, protected progression and existing Sage path are installed' AS regression_result;
