BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

/*
  SQL Editor-safe end-to-end proof for NIN-240726-B.

  Run after:
    1. the three signed-financial migrations;
    2. B ordinary goods are progressed through the existing importer route;
    3. -10.00 is explicitly Parked as discount;
    4. +10.01 is explicitly Parked as delivery;
    5. supervisor Save all completes signed accounting coding;
    6. B is approved current and its supplier-goods AP Sage batch is frozen.

  No authenticated helper, auth.uid(), external Sage post or permanent mutation is
  executed. The private materialiser is called once with the exact persisted rows
  only to prove idempotency; the surrounding transaction is rolled back.
*/

DO $prerequisites$
DECLARE
  v_save_definition text;
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL
     OR to_regclass('public.supplier_invoice_accounting_coding_totals_vw') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Ninja B signed-financial regression prerequisite relation is missing.';
  END IF;

  IF to_regprocedure('public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid,jsonb)') IS NULL
     OR to_regprocedure('public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL
     OR to_regprocedure('public.enforce_supplier_invoice_line_accounting_code_amount_sign_v1()') IS NULL THEN
    RAISE EXCEPTION 'Permanent signed-financial function chain is incomplete.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)'::regprocedure
  ) INTO v_save_definition;

  IF position('internal_materialise_supplier_invoice_ocr_financial_rows_v1' IN v_save_definition) = 0
     OR position('staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1' IN v_save_definition) = 0 THEN
    RAISE EXCEPTION 'Canonical Mindee save does not preserve the old route and call the permanent financial-row materialiser.';
  END IF;
END
$prerequisites$;

DO $target_b$
DECLARE
  v_invoice_id uuid;
  v_header_total numeric;
  v_review_status text;
  v_blocked boolean;
  v_ocr_count integer;
  v_ocr_total numeric;
  v_discount_line_id uuid;
  v_delivery_line_id uuid;
  v_discount_count integer;
  v_discount_total numeric;
  v_delivery_count integer;
  v_delivery_total numeric;
  v_resolution_count integer;
  v_resolution_total numeric;
  v_discount_resolution_count integer;
  v_delivery_resolution_count integer;
  v_discount_net numeric;
  v_discount_vat numeric;
  v_discount_gross numeric;
  v_delivery_net numeric;
  v_delivery_vat numeric;
  v_delivery_gross numeric;
  v_accepted_gross numeric;
  v_total_coded_gross numeric;
  v_all_coded boolean;
  v_gross_reconciled boolean;
  v_snapshot_id uuid;
  v_snapshot_amount numeric;
  v_resolved_lines jsonb;
  v_payload_total numeric;
  v_payload_discount_count integer;
  v_payload_discount_gross numeric;
  v_payload_delivery_count integer;
  v_payload_delivery_gross numeric;
  v_repeat_inserted integer;
  v_repeat_lines jsonb;
BEGIN
  SELECT
    si.id,
    round(si.ocr_invoice_total_gbp::numeric, 2),
    si.review_status::text,
    COALESCE(si.blocked_from_sage_yn, true)
  INTO
    v_invoice_id,
    v_header_total,
    v_review_status,
    v_blocked
  FROM public.supplier_invoices si
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND si.invoice_ref = 'NIN-240726-B'
  ORDER BY si.uploaded_at DESC, si.id DESC
  LIMIT 1;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Target invoice NIN-240726-B was not found.';
  END IF;

  IF v_header_total IS DISTINCT FROM 249.99::numeric THEN
    RAISE EXCEPTION 'B OCR header must remain 249.99; found %.', v_header_total;
  END IF;

  SELECT
    COUNT(*)::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE sil.amount_inc_vat_gbp < 0
        AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(discount|promotion|promotional|promo|voucher|coupon|saving|savings)( |$)'
    )::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (
      WHERE sil.amount_inc_vat_gbp < 0
    ), 0)::numeric, 2),
    (array_agg(sil.id ORDER BY sil.line_order, sil.id)
      FILTER (WHERE sil.amount_inc_vat_gbp < 0))[1],
    COUNT(*) FILTER (
      WHERE sil.amount_inc_vat_gbp > 0
        AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    )::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (
      WHERE sil.amount_inc_vat_gbp > 0
        AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
          ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
    ), 0)::numeric, 2),
    (array_agg(sil.id ORDER BY sil.line_order, sil.id)
      FILTER (
        WHERE sil.amount_inc_vat_gbp > 0
          AND lower(regexp_replace(sil.description, '[^a-zA-Z0-9]+', ' ', 'g'))
            ~ '(^| )(delivery|shipping|postage|freight|carriage)( |$)'
      ))[1]
  INTO
    v_ocr_count,
    v_ocr_total,
    v_discount_count,
    v_discount_total,
    v_discount_line_id,
    v_delivery_count,
    v_delivery_total,
    v_delivery_line_id
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = v_invoice_id
    AND sil.line_source = 'ocr_extracted';

  IF v_ocr_count <> 4
     OR v_ocr_total IS DISTINCT FROM 249.99::numeric
     OR v_discount_count <> 1
     OR v_discount_total IS DISTINCT FROM -10.00::numeric
     OR v_discount_line_id IS NULL
     OR v_delivery_count <> 1
     OR v_delivery_total IS DISTINCT FROM 10.01::numeric
     OR v_delivery_line_id IS NULL THEN
    RAISE EXCEPTION
      'B source evidence mismatch: rows %, total %, discount %/%/%, delivery %/%/%.',
      v_ocr_count, v_ocr_total,
      v_discount_count, v_discount_total, v_discount_line_id,
      v_delivery_count, v_delivery_total, v_delivery_line_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.id IN (v_discount_line_id, v_delivery_line_id)
      AND lower(btrim(COALESCE(sil.eligible_for_invoice_yn, 'n')))
          IN ('y', 'yes', 'true', '1')
  ) OR EXISTS (
    SELECT 1 FROM public.dispute_lines dl
    WHERE dl.supplier_invoice_line_id IN (v_discount_line_id, v_delivery_line_id)
  ) OR EXISTS (
    SELECT 1 FROM public.order_tracking_line_allocations a
    WHERE a.supplier_invoice_line_id IN (v_discount_line_id, v_delivery_line_id)
  ) OR EXISTS (
    SELECT 1 FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.supplier_invoice_line_id IN (v_discount_line_id, v_delivery_line_id)
  ) THEN
    RAISE EXCEPTION 'B financial rows leaked into a physical, exception, tracking or shipment lane.';
  END IF;

  SELECT
    COUNT(*)::integer,
    round(COALESCE(SUM(r.amount_gbp), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE r.supplier_invoice_line_id = v_discount_line_id
        AND r.financial_type = 'discount'
        AND round(r.amount_gbp::numeric, 2) = -10.00
    )::integer,
    COUNT(*) FILTER (
      WHERE r.supplier_invoice_line_id = v_delivery_line_id
        AND r.financial_type = 'delivery'
        AND round(r.amount_gbp::numeric, 2) = 10.01
    )::integer
  INTO
    v_resolution_count,
    v_resolution_total,
    v_discount_resolution_count,
    v_delivery_resolution_count
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.supplier_invoice_id = v_invoice_id
    AND r.supplier_invoice_line_id IN (v_discount_line_id, v_delivery_line_id)
    AND r.active = true
    AND r.resolution_type = 'non_physical_financial';

  IF v_resolution_count <> 2
     OR v_resolution_total IS DISTINCT FROM 0.01::numeric
     OR v_discount_resolution_count <> 1
     OR v_delivery_resolution_count <> 1 THEN
    RAISE EXCEPTION
      'B requires one active -10.00 discount resolution and one active +10.01 delivery resolution; count %, total %, discount %, delivery %.',
      v_resolution_count, v_resolution_total,
      v_discount_resolution_count, v_delivery_resolution_count;
  END IF;

  SELECT
    round(c.net_amount_gbp::numeric, 2),
    round(c.vat_amount_gbp::numeric, 2),
    round(c.gross_amount_gbp::numeric, 2)
  INTO v_discount_net, v_discount_vat, v_discount_gross
  FROM public.supplier_invoice_line_accounting_codes c
  WHERE c.supplier_invoice_line_id = v_discount_line_id;

  SELECT
    round(c.net_amount_gbp::numeric, 2),
    round(c.vat_amount_gbp::numeric, 2),
    round(c.gross_amount_gbp::numeric, 2)
  INTO v_delivery_net, v_delivery_vat, v_delivery_gross
  FROM public.supplier_invoice_line_accounting_codes c
  WHERE c.supplier_invoice_line_id = v_delivery_line_id;

  IF v_discount_gross IS DISTINCT FROM -10.00::numeric
     OR COALESCE(v_discount_net, 0) >= 0
     OR COALESCE(v_discount_vat, 0) > 0
     OR abs(COALESCE(v_discount_net, 0) + COALESCE(v_discount_vat, 0) - COALESCE(v_discount_gross, 0)) > 0.01
     OR v_delivery_gross IS DISTINCT FROM 10.01::numeric
     OR COALESCE(v_delivery_net, 0) < 0
     OR COALESCE(v_delivery_vat, 0) < 0
     OR abs(COALESCE(v_delivery_net, 0) + COALESCE(v_delivery_vat, 0) - COALESCE(v_delivery_gross, 0)) > 0.01 THEN
    RAISE EXCEPTION
      'B signed accounting is invalid: discount net/VAT/gross %/%/%, delivery net/VAT/gross %/%/%.',
      v_discount_net, v_discount_vat, v_discount_gross,
      v_delivery_net, v_delivery_vat, v_delivery_gross;
  END IF;

  SELECT
    round(t.accepted_invoice_gross_gbp::numeric, 2),
    round(t.total_coded_gross_gbp::numeric, 2),
    COALESCE(t.all_progressed_lines_coded_yn, false),
    COALESCE(t.gross_reconciled_to_invoice_yn, false)
  INTO
    v_accepted_gross,
    v_total_coded_gross,
    v_all_coded,
    v_gross_reconciled
  FROM public.supplier_invoice_accounting_coding_totals_vw t
  WHERE t.supplier_invoice_id = v_invoice_id;

  IF v_accepted_gross IS DISTINCT FROM 249.99::numeric
     OR v_total_coded_gross IS DISTINCT FROM 249.99::numeric
     OR NOT v_all_coded
     OR NOT v_gross_reconciled THEN
    RAISE EXCEPTION
      'B accounting totals are not reconciled: accepted %, coded %, all coded %, gross reconciled %.',
      v_accepted_gross, v_total_coded_gross, v_all_coded, v_gross_reconciled;
  END IF;

  IF COALESCE(v_review_status, '') NOT IN ('approved_current', 'ref_corrected_approved')
     OR v_blocked THEN
    RAISE EXCEPTION
      'B must complete the existing approval/current route before freeze; status %, blocked %.',
      v_review_status, v_blocked;
  END IF;

  SELECT
    s.id,
    round(s.amount_gbp::numeric, 2),
    COALESCE(s.resolved_payload->'resolved_lines', '[]'::jsonb)
  INTO
    v_snapshot_id,
    v_snapshot_amount,
    v_resolved_lines
  FROM public.sage_posting_snapshots s
  WHERE s.source_table = 'supplier_invoices'
    AND s.source_id = v_invoice_id
    AND s.document_lane = 'supplier_goods_ap'
    AND COALESCE(s.active, true) = true
    AND s.approval_status = 'approved_frozen'
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'superseded'
  ORDER BY s.created_at DESC, s.id DESC
  LIMIT 1;

  IF v_snapshot_id IS NULL
     OR v_snapshot_amount IS DISTINCT FROM 249.99::numeric
     OR jsonb_typeof(v_resolved_lines) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION
      'B frozen supplier-goods AP snapshot is missing or invalid: snapshot %, amount %, line type %.',
      v_snapshot_id, v_snapshot_amount, jsonb_typeof(v_resolved_lines);
  END IF;

  SELECT
    round(COALESCE(SUM(
      CASE
        WHEN COALESCE(
          line.value->>'gross_amount_gbp',
          line.value->>'total_line_amount_gbp',
          line.value->>'amount_gbp',
          line.value->>'unit_price_gbp',
          ''
        ) ~ '^-?[0-9]+(\.[0-9]+)?$'
          THEN COALESCE(
            line.value->>'gross_amount_gbp',
            line.value->>'total_line_amount_gbp',
            line.value->>'amount_gbp',
            line.value->>'unit_price_gbp'
          )::numeric
        ELSE 0
      END
    ), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE line.value->>'source_line_id' = v_discount_line_id::text
    )::integer,
    round(COALESCE(SUM((line.value->>'gross_amount_gbp')::numeric) FILTER (
      WHERE line.value->>'source_line_id' = v_discount_line_id::text
    ), 0)::numeric, 2),
    COUNT(*) FILTER (
      WHERE line.value->>'source_line_id' = v_delivery_line_id::text
    )::integer,
    round(COALESCE(SUM((line.value->>'gross_amount_gbp')::numeric) FILTER (
      WHERE line.value->>'source_line_id' = v_delivery_line_id::text
    ), 0)::numeric, 2)
  INTO
    v_payload_total,
    v_payload_discount_count,
    v_payload_discount_gross,
    v_payload_delivery_count,
    v_payload_delivery_gross
  FROM jsonb_array_elements(v_resolved_lines) line(value);

  IF v_payload_total IS DISTINCT FROM 249.99::numeric
     OR v_payload_discount_count <> 1
     OR v_payload_discount_gross IS DISTINCT FROM -10.00::numeric
     OR v_payload_delivery_count <> 1
     OR v_payload_delivery_gross IS DISTINCT FROM 10.01::numeric THEN
    RAISE EXCEPTION
      'B frozen Sage payload mismatch: total %, discount %/%, delivery %/%.',
      v_payload_total,
      v_payload_discount_count, v_payload_discount_gross,
      v_payload_delivery_count, v_payload_delivery_gross;
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'line_order', sil.line_order,
    'retailer_sku', sil.retailer_sku,
    'description', sil.description,
    'qty', sil.qty,
    'amount_inc_vat_gbp', sil.amount_inc_vat_gbp
  ) ORDER BY sil.line_order)
  INTO v_repeat_lines
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = v_invoice_id
    AND sil.line_source = 'ocr_extracted';

  v_repeat_inserted :=
    public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(
      v_invoice_id,
      v_repeat_lines
    );

  IF v_repeat_inserted <> 0 THEN
    RAISE EXCEPTION 'Permanent materialiser is not idempotent for exact B replay; inserted % row(s).', v_repeat_inserted;
  END IF;
END
$target_b$;

SELECT
  'PASS'::text AS regression_result,
  'NIN-240726-B proves the permanent route end to end: four signed OCR source rows total 249.99; -10.00 discount and +10.01 delivery are explicit non-physical resolutions; both retain signed accounting; ordinary goods complete the existing approval route; neither financial row leaks into physical, exception, tracking or shipment lanes; the frozen supplier-goods AP payload contains both financial rows exactly once and totals 249.99; exact replay inserts zero rows.'::text AS details;

ROLLBACK;