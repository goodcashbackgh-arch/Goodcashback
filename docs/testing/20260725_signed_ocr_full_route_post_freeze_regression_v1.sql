BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

/*
  SQL Editor-safe post-workflow regression.

  This script does not execute any authenticated RPC or helper. It inspects only
  PostgreSQL catalogues, persisted source/classification/accounting rows, approval
  state, physical-lane tables and the immutable Sage posting snapshot.

  Run only after the real UI workflow for NIN-240726-A has completed through:
    Park as discount -> supervisor Save all -> approve current -> freeze Sage batch.
*/

DO $prerequisites$
DECLARE
  v_helper_definition text;
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_lines') IS NULL
     OR to_regclass('public.supplier_invoice_line_resolutions') IS NULL
     OR to_regclass('public.supplier_invoice_line_accounting_codes') IS NULL
     OR to_regclass('public.supplier_invoice_accounting_coding_totals_vw') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regclass('public.shipper_shipment_batch_line_memberships') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Signed OCR full-route regression prerequisite relation is missing.';
  END IF;

  IF to_regprocedure('public.internal_supplier_goods_ap_ready_rows_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1()') IS NULL
     OR to_regprocedure('public.internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1()') IS NULL THEN
    RAISE EXCEPTION 'Supplier AP preserved/enriched/canonical helper chain is incomplete.';
  END IF;

  SELECT pg_get_functiondef('public.internal_supplier_goods_ap_ready_rows_v1()'::regprocedure)
    INTO v_helper_definition;

  IF position('internal_supplier_goods_ap_ready_rows_pre_signed_nonphysical_v1' IN v_helper_definition) = 0
     OR position('internal_supplier_goods_ap_ready_rows_signed_nonphysical_all_v1' IN v_helper_definition) = 0
     OR position('WHERE NOT EXISTS' IN v_helper_definition) = 0
     OR position('WHERE EXISTS' IN v_helper_definition) = 0 THEN
    RAISE EXCEPTION 'Canonical supplier AP helper no longer preserves unaffected invoices and scopes enrichment to affected invoices.';
  END IF;
END
$prerequisites$;

DO $target_a$
DECLARE
  v_invoice_id uuid;
  v_header_total numeric;
  v_review_status text;
  v_blocked boolean;
  v_negative_line_id uuid;
  v_negative_count integer;
  v_negative_total numeric;
  v_signed_source_total numeric;
  v_resolution_count integer;
  v_resolution_amount numeric;
  v_resolution_type text;
  v_coded_net numeric;
  v_coded_vat numeric;
  v_coded_gross numeric;
  v_nominal_code text;
  v_sage_ledger_account_id text;
  v_accepted_gross numeric;
  v_total_coded_gross numeric;
  v_all_coded boolean;
  v_gross_reconciled boolean;
  v_net_reconciled boolean;
  v_vat_reconciled boolean;
  v_snapshot_id uuid;
  v_snapshot_amount numeric;
  v_resolved_lines jsonb;
  v_payload_line_total numeric;
  v_payload_discount_count integer;
  v_payload_discount_gross numeric;
  v_payload_discount_net numeric;
  v_payload_discount_vat numeric;
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
    AND si.invoice_ref = 'NIN-240726-A'
  ORDER BY si.uploaded_at DESC, si.id DESC
  LIMIT 1;

  IF v_invoice_id IS NULL THEN
    RAISE EXCEPTION 'Target invoice NIN-240726-A was not found.';
  END IF;

  IF v_header_total IS DISTINCT FROM 449.98::numeric THEN
    RAISE EXCEPTION 'A OCR header must remain 449.98; found %.', v_header_total;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE sil.amount_inc_vat_gbp < 0)::integer,
    round(COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (WHERE sil.amount_inc_vat_gbp < 0), 0)::numeric, 2),
    round(COALESCE(SUM(sil.amount_inc_vat_gbp), 0)::numeric, 2),
    MIN(sil.id) FILTER (WHERE sil.amount_inc_vat_gbp < 0)
  INTO
    v_negative_count,
    v_negative_total,
    v_signed_source_total,
    v_negative_line_id
  FROM public.supplier_invoice_lines sil
  WHERE sil.supplier_invoice_id = v_invoice_id
    AND sil.line_source = 'ocr_extracted';

  IF v_negative_count <> 1
     OR v_negative_total IS DISTINCT FROM -50.01::numeric
     OR v_signed_source_total IS DISTINCT FROM 449.98::numeric
     OR v_negative_line_id IS NULL THEN
    RAISE EXCEPTION
      'A signed OCR evidence mismatch: negative count %, negative total %, signed total %, line id %.',
      v_negative_count, v_negative_total, v_signed_source_total, v_negative_line_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_lines sil
    WHERE sil.id = v_negative_line_id
      AND lower(trim(COALESCE(sil.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1')
  ) THEN
    RAISE EXCEPTION 'A signed discount was physically progressed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    WHERE dl.supplier_invoice_line_id = v_negative_line_id
      AND dl.resolved_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A signed discount was incorrectly routed into an open refund/replacement exception.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    WHERE a.supplier_invoice_line_id = v_negative_line_id
  ) THEN
    RAISE EXCEPTION 'A signed discount was incorrectly allocated to tracking.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_line_memberships m
    WHERE m.supplier_invoice_line_id = v_negative_line_id
  ) THEN
    RAISE EXCEPTION 'A signed discount was incorrectly included in a shipment batch.';
  END IF;

  SELECT
    COUNT(*)::integer,
    round(MIN(r.amount_gbp)::numeric, 2),
    MIN(r.financial_type::text)
  INTO
    v_resolution_count,
    v_resolution_amount,
    v_resolution_type
  FROM public.supplier_invoice_line_resolutions r
  WHERE r.supplier_invoice_line_id = v_negative_line_id
    AND r.supplier_invoice_id = v_invoice_id
    AND r.active = true
    AND r.resolution_type = 'non_physical_financial';

  IF v_resolution_count <> 1
     OR v_resolution_type IS DISTINCT FROM 'discount'
     OR v_resolution_amount IS DISTINCT FROM -50.01::numeric THEN
    RAISE EXCEPTION
      'A signed line must have one active discount resolution preserving -50.01; count %, type %, amount %.',
      v_resolution_count, v_resolution_type, v_resolution_amount;
  END IF;

  SELECT
    round(c.net_amount_gbp::numeric, 2),
    round(c.vat_amount_gbp::numeric, 2),
    round(c.gross_amount_gbp::numeric, 2),
    NULLIF(btrim(COALESCE(c.nominal_code, '')), ''),
    NULLIF(btrim(COALESCE(c.sage_ledger_account_id, '')), '')
  INTO
    v_coded_net,
    v_coded_vat,
    v_coded_gross,
    v_nominal_code,
    v_sage_ledger_account_id
  FROM public.supplier_invoice_line_accounting_codes c
  WHERE c.supplier_invoice_line_id = v_negative_line_id;

  IF v_coded_gross IS DISTINCT FROM -50.01::numeric
     OR COALESCE(v_coded_net, 0) >= 0
     OR COALESCE(v_coded_vat, 0) > 0
     OR abs(COALESCE(v_coded_net, 0) + COALESCE(v_coded_vat, 0) - COALESCE(v_coded_gross, 0)) > 0.01 THEN
    RAISE EXCEPTION
      'A signed accounting coding is invalid: net %, VAT %, gross %.',
      v_coded_net, v_coded_vat, v_coded_gross;
  END IF;

  IF v_nominal_code IS NULL AND v_sage_ledger_account_id IS NULL THEN
    RAISE EXCEPTION 'A signed accounting line is missing both nominal code and Sage ledger account id.';
  END IF;

  SELECT
    round(t.accepted_invoice_gross_gbp::numeric, 2),
    round(t.total_coded_gross_gbp::numeric, 2),
    COALESCE(t.all_progressed_lines_coded_yn, false),
    COALESCE(t.gross_reconciled_to_invoice_yn, false),
    COALESCE(t.net_reconciled_to_invoice_yn, false),
    COALESCE(t.vat_reconciled_to_invoice_yn, false)
  INTO
    v_accepted_gross,
    v_total_coded_gross,
    v_all_coded,
    v_gross_reconciled,
    v_net_reconciled,
    v_vat_reconciled
  FROM public.supplier_invoice_accounting_coding_totals_vw t
  WHERE t.supplier_invoice_id = v_invoice_id;

  IF v_accepted_gross IS DISTINCT FROM 449.98::numeric
     OR v_total_coded_gross IS DISTINCT FROM 449.98::numeric
     OR NOT v_all_coded
     OR NOT v_gross_reconciled
     OR NOT v_net_reconciled
     OR NOT v_vat_reconciled THEN
    RAISE EXCEPTION
      'A accounting totals are not fully reconciled: accepted gross %, coded gross %, all coded %, gross %, net %, VAT %.',
      v_accepted_gross, v_total_coded_gross, v_all_coded,
      v_gross_reconciled, v_net_reconciled, v_vat_reconciled;
  END IF;

  IF v_review_status NOT IN ('approved_current', 'ref_corrected_approved') OR v_blocked THEN
    RAISE EXCEPTION
      'A must complete the existing approval/current route before freeze; status %, blocked_from_sage %.',
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

  IF v_snapshot_id IS NULL THEN
    RAISE EXCEPTION 'A has no active approved frozen supplier-goods AP Sage snapshot.';
  END IF;

  IF v_snapshot_amount IS DISTINCT FROM 449.98::numeric
     OR jsonb_typeof(v_resolved_lines) IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_resolved_lines) = 0 THEN
    RAISE EXCEPTION
      'A frozen Sage snapshot header/line payload is invalid: snapshot %, amount %, lines type/count %/%',
      v_snapshot_id,
      v_snapshot_amount,
      jsonb_typeof(v_resolved_lines),
      CASE WHEN jsonb_typeof(v_resolved_lines) = 'array' THEN jsonb_array_length(v_resolved_lines) ELSE NULL END;
  END IF;

  SELECT
    round(COALESCE(SUM(
      CASE
        WHEN COALESCE(line.value->>'gross_amount_gbp', line.value->>'total_line_amount_gbp', line.value->>'amount_gbp', line.value->>'unit_price_gbp', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
          THEN COALESCE(line.value->>'gross_amount_gbp', line.value->>'total_line_amount_gbp', line.value->>'amount_gbp', line.value->>'unit_price_gbp')::numeric
        ELSE 0
      END
    ), 0)::numeric, 2),
    COUNT(*) FILTER (WHERE line.value->>'source_line_id' = v_negative_line_id::text)::integer,
    round(COALESCE(SUM((line.value->>'gross_amount_gbp')::numeric)
      FILTER (WHERE line.value->>'source_line_id' = v_negative_line_id::text), 0)::numeric, 2),
    round(COALESCE(SUM((line.value->>'net_amount_gbp')::numeric)
      FILTER (WHERE line.value->>'source_line_id' = v_negative_line_id::text), 0)::numeric, 2),
    round(COALESCE(SUM((line.value->>'vat_amount_gbp')::numeric)
      FILTER (WHERE line.value->>'source_line_id' = v_negative_line_id::text), 0)::numeric, 2)
  INTO
    v_payload_line_total,
    v_payload_discount_count,
    v_payload_discount_gross,
    v_payload_discount_net,
    v_payload_discount_vat
  FROM jsonb_array_elements(v_resolved_lines) line(value);

  IF v_payload_line_total IS DISTINCT FROM 449.98::numeric
     OR v_payload_discount_count <> 1
     OR v_payload_discount_gross IS DISTINCT FROM -50.01::numeric
     OR COALESCE(v_payload_discount_net, 0) >= 0
     OR COALESCE(v_payload_discount_vat, 0) > 0
     OR abs(COALESCE(v_payload_discount_net, 0) + COALESCE(v_payload_discount_vat, 0) - COALESCE(v_payload_discount_gross, 0)) > 0.01 THEN
    RAISE EXCEPTION
      'A frozen signed Sage payload mismatch: line total %, discount count %, net %, VAT %, gross %.',
      v_payload_line_total,
      v_payload_discount_count,
      v_payload_discount_net,
      v_payload_discount_vat,
      v_payload_discount_gross;
  END IF;
END
$target_a$;

SELECT
  'PASS'::text AS regression_result,
  'NIN-240726-A completed the real signed route: -50.01 OCR evidence, explicit discount parking, signed supervisor coding, reconciled approval, no physical/exception/tracking/shipment leakage, and one signed line in the frozen 449.98 supplier-goods AP Sage payload. Unaffected invoices remain on the preserved helper branch.'::text AS details;

ROLLBACK;
