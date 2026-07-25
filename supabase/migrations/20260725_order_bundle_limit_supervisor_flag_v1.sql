BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- This patch extends the existing invoice-review flag lane. It does not create a
-- new workflow and does not alter invoice totals, adjustments, funding, banking,
-- progression, shipment, Sage, VAT or accounting data.
DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.supplier_invoice_financial_summary') IS NULL
     OR to_regclass('public.supplier_invoice_review_flags') IS NULL
     OR to_regclass('public.operators') IS NULL
     OR to_regclass('public.supplier_invoice_match_decision_vw') IS NULL THEN
    RAISE EXCEPTION 'Order-bundle-limit prerequisite relation is missing.';
  END IF;
END $$;

-- Extend only the flag-type constraint, retaining every existing value.
DO $$
DECLARE
  v_constraint record;
  v_flag_attnum smallint;
BEGIN
  SELECT a.attnum
    INTO v_flag_attnum
  FROM pg_attribute a
  WHERE a.attrelid = 'public.supplier_invoice_review_flags'::regclass
    AND a.attname = 'flag_type'
    AND NOT a.attisdropped;

  FOR v_constraint IN
    SELECT c.conname
    FROM pg_constraint c
    WHERE c.conrelid = 'public.supplier_invoice_review_flags'::regclass
      AND c.contype = 'c'
      AND v_flag_attnum = ANY(c.conkey)
  LOOP
    EXECUTE format('ALTER TABLE public.supplier_invoice_review_flags DROP CONSTRAINT %I', v_constraint.conname);
  END LOOP;

  ALTER TABLE public.supplier_invoice_review_flags
    ADD CONSTRAINT supplier_invoice_review_flags_flag_type_check
    CHECK (flag_type IN (
      'invoice_total_mismatch',
      'ocr_unclear',
      'wrong_invoice',
      'delivery_discount_query',
      'manual_line_needed',
      'order_bundle_limit_breach',
      'other'
    ));
END $$;

-- Preserve the existing read-model contract. Only the serious-flag membership is
-- extended so a declared order-limit breach and an unresolved adjustment query
-- remain in the same supervisor review/approval gate already used by OCR issues.
CREATE OR REPLACE VIEW public.supplier_invoice_match_decision_vw AS
WITH active_summary AS (
  SELECT DISTINCT ON (sifs.supplier_invoice_id)
    sifs.supplier_invoice_id,
    sifs.invoice_total_gbp::numeric(12,2) AS operator_total_gbp
  FROM public.supplier_invoice_financial_summary sifs
  ORDER BY sifs.supplier_invoice_id, sifs.created_at DESC NULLS LAST
), line_counts AS (
  SELECT
    sil.supplier_invoice_id,
    COUNT(*) FILTER (WHERE sil.line_source = 'ocr_extracted')::int AS ocr_line_count,
    COUNT(*) FILTER (WHERE sil.eligible_for_invoice_yn = 'Y')::int AS progressed_line_count,
    COALESCE(SUM(sil.amount_inc_vat_gbp) FILTER (WHERE sil.line_source = 'ocr_extracted'), 0)::numeric(12,2) AS ocr_line_total_gbp
  FROM public.supplier_invoice_lines sil
  GROUP BY sil.supplier_invoice_id
), open_flags AS (
  SELECT
    sfrf.supplier_invoice_id,
    COUNT(*) FILTER (WHERE sfrf.status IN ('open','under_review'))::int AS open_review_flag_count,
    COUNT(*) FILTER (
      WHERE sfrf.status IN ('open','under_review')
        AND sfrf.flag_type IN (
          'wrong_invoice',
          'ocr_unclear',
          'invoice_total_mismatch',
          'delivery_discount_query',
          'manual_line_needed',
          'order_bundle_limit_breach'
        )
    )::int AS serious_open_review_flag_count
  FROM public.supplier_invoice_review_flags sfrf
  GROUP BY sfrf.supplier_invoice_id
), pending_adjustments AS (
  SELECT
    ova.supplier_invoice_id,
    COUNT(*) FILTER (WHERE ova.approval_status = 'pending_supervisor')::int AS pending_adjustment_count
  FROM public.order_value_adjustments ova
  GROUP BY ova.supplier_invoice_id
), normalized AS (
  SELECT
    si.id AS supplier_invoice_id,
    si.order_id,
    o.order_ref,
    r.name AS order_retailer_name,
    si.invoice_ref AS operator_invoice_ref,
    si.ocr_invoice_ref,
    si.ocr_retailer_name,
    si.ocr_invoice_date,
    si.ocr_invoice_total_gbp::numeric(12,2) AS ocr_total_gbp,
    asum.operator_total_gbp,
    COALESCE(lc.ocr_line_count, 0) AS ocr_line_count,
    COALESCE(lc.progressed_line_count, 0) AS progressed_line_count,
    COALESCE(lc.ocr_line_total_gbp, 0)::numeric(12,2) AS ocr_line_total_gbp,
    COALESCE(ofl.open_review_flag_count, 0) AS open_review_flag_count,
    COALESCE(ofl.serious_open_review_flag_count, 0) AS serious_open_review_flag_count,
    COALESCE(pa.pending_adjustment_count, 0) AS pending_adjustment_count,
    si.review_status,
    COALESCE(si.blocked_from_sage_yn, true) AS blocked_from_sage_yn,
    si.ocr_raw_json IS NOT NULL AS has_ocr_raw_json,
    si.ocr_extracted_at,
    regexp_replace(lower(COALESCE(r.name, '')), '[^a-z0-9]+', '', 'g') AS norm_order_retailer,
    regexp_replace(lower(COALESCE(si.ocr_retailer_name, '')), '[^a-z0-9]+', '', 'g') AS norm_ocr_retailer,
    regexp_replace(lower(COALESCE(si.invoice_ref, '')), '[^a-z0-9]+', '', 'g') AS norm_operator_ref,
    regexp_replace(lower(COALESCE(si.ocr_invoice_ref, '')), '[^a-z0-9]+', '', 'g') AS norm_ocr_ref
  FROM public.supplier_invoices si
  JOIN public.orders o ON o.id = si.order_id
  JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN active_summary asum ON asum.supplier_invoice_id = si.id
  LEFT JOIN line_counts lc ON lc.supplier_invoice_id = si.id
  LEFT JOIN open_flags ofl ON ofl.supplier_invoice_id = si.id
  LEFT JOIN pending_adjustments pa ON pa.supplier_invoice_id = si.id
)
SELECT
  n.supplier_invoice_id,
  n.order_id,
  n.order_ref,
  n.order_retailer_name,
  n.operator_invoice_ref,
  n.ocr_invoice_ref,
  CASE
    WHEN n.ocr_invoice_ref IS NULL OR btrim(n.ocr_invoice_ref) = '' THEN false
    ELSE n.norm_operator_ref = n.norm_ocr_ref
  END AS invoice_ref_match_yn,
  n.operator_total_gbp,
  n.ocr_total_gbp,
  CASE
    WHEN n.operator_total_gbp IS NULL OR n.ocr_total_gbp IS NULL THEN false
    ELSE abs(n.operator_total_gbp - n.ocr_total_gbp) <= 0.01
  END AS total_match_yn,
  n.ocr_retailer_name,
  CASE
    WHEN n.ocr_retailer_name IS NULL OR btrim(n.ocr_retailer_name) = '' THEN false
    WHEN n.norm_order_retailer = '' OR n.norm_ocr_retailer = '' THEN false
    WHEN n.norm_order_retailer = n.norm_ocr_retailer THEN true
    WHEN position(n.norm_order_retailer in n.norm_ocr_retailer) > 0 THEN true
    WHEN position(n.norm_ocr_retailer in n.norm_order_retailer) > 0 THEN true
    ELSE false
  END AS retailer_match_yn,
  n.ocr_invoice_date,
  n.ocr_line_count,
  n.progressed_line_count,
  n.ocr_line_total_gbp,
  (n.pending_adjustment_count > 0) AS pending_adjustment_yn,
  n.pending_adjustment_count,
  n.open_review_flag_count,
  n.serious_open_review_flag_count,
  n.review_status,
  n.blocked_from_sage_yn,
  n.has_ocr_raw_json,
  n.ocr_extracted_at,
  CASE
    WHEN n.review_status IN ('rejected_resubmit_required','superseded','duplicate_blocked') THEN 'rejected_audit_only'
    WHEN NOT n.has_ocr_raw_json AND n.ocr_invoice_ref IS NULL AND n.ocr_total_gbp IS NULL AND n.ocr_retailer_name IS NULL THEN 'ocr_pending'
    WHEN n.ocr_line_count = 0 THEN 'needs_invoice_review'
    WHEN n.serious_open_review_flag_count > 0 THEN 'needs_invoice_review'
    WHEN NOT (
      CASE
        WHEN n.ocr_retailer_name IS NULL OR btrim(n.ocr_retailer_name) = '' THEN false
        WHEN n.norm_order_retailer = '' OR n.norm_ocr_retailer = '' THEN false
        WHEN n.norm_order_retailer = n.norm_ocr_retailer THEN true
        WHEN position(n.norm_order_retailer in n.norm_ocr_retailer) > 0 THEN true
        WHEN position(n.norm_ocr_retailer in n.norm_order_retailer) > 0 THEN true
        ELSE false
      END
    ) THEN 'needs_invoice_review'
    WHEN n.ocr_invoice_ref IS NULL OR btrim(n.ocr_invoice_ref) = '' OR n.norm_operator_ref <> n.norm_ocr_ref THEN 'needs_invoice_review'
    WHEN n.operator_total_gbp IS NULL OR n.ocr_total_gbp IS NULL OR abs(n.operator_total_gbp - n.ocr_total_gbp) > 0.01 THEN 'needs_invoice_review'
    ELSE 'ready_for_operator_reconciliation'
  END AS routing_decision,
  CASE
    WHEN n.review_status IN ('rejected_resubmit_required','superseded','duplicate_blocked') THEN 'Invoice is audit-only due to rejected/superseded/duplicate status.'
    WHEN NOT n.has_ocr_raw_json AND n.ocr_invoice_ref IS NULL AND n.ocr_total_gbp IS NULL AND n.ocr_retailer_name IS NULL THEN 'OCR has not been saved yet.'
    WHEN n.ocr_line_count = 0 THEN 'No OCR invoice lines exist for reconciliation.'
    WHEN n.serious_open_review_flag_count > 0 THEN 'Serious open invoice review flag exists.'
    WHEN NOT (
      CASE
        WHEN n.ocr_retailer_name IS NULL OR btrim(n.ocr_retailer_name) = '' THEN false
        WHEN n.norm_order_retailer = '' OR n.norm_ocr_retailer = '' THEN false
        WHEN n.norm_order_retailer = n.norm_ocr_retailer THEN true
        WHEN position(n.norm_order_retailer in n.norm_ocr_retailer) > 0 THEN true
        WHEN position(n.norm_ocr_retailer in n.norm_order_retailer) > 0 THEN true
        ELSE false
      END
    ) THEN 'OCR supplier/retailer does not match the order-created retailer.'
    WHEN n.ocr_invoice_ref IS NULL OR btrim(n.ocr_invoice_ref) = '' THEN 'OCR invoice reference is missing.'
    WHEN n.norm_operator_ref <> n.norm_ocr_ref THEN 'Operator invoice reference does not match OCR invoice reference.'
    WHEN n.operator_total_gbp IS NULL THEN 'Operator-entered final invoice total is missing.'
    WHEN n.ocr_total_gbp IS NULL THEN 'OCR final invoice total is missing.'
    WHEN abs(n.operator_total_gbp - n.ocr_total_gbp) > 0.01 THEN 'Operator-entered final invoice total does not match OCR final invoice total.'
    ELSE 'Matched on order retailer, invoice reference, final gross total, and OCR line existence.'
  END AS routing_reason,
  CASE
    WHEN n.pending_adjustment_count > 0 THEN true
    WHEN n.serious_open_review_flag_count > 0 THEN true
    WHEN n.ocr_line_count = 0 THEN true
    ELSE false
  END AS supplier_approval_blocked_yn,
  CASE
    WHEN n.pending_adjustment_count > 0 THEN 'Pending delivery/discount adjustment blocks approve-current/Sage readiness, but not operator line reconciliation.'
    WHEN n.serious_open_review_flag_count > 0 THEN 'Serious invoice review flag blocks supplier approval.'
    WHEN n.ocr_line_count = 0 THEN 'No OCR lines exist.'
    ELSE NULL
  END AS supplier_approval_block_reason
FROM normalized n;

COMMENT ON VIEW public.supplier_invoice_match_decision_vw IS
'Existing invoice OCR routing, extended only so unresolved delivery/discount queries and accepted-estimate bundle breaches use the established serious supervisor-review gate.';

CREATE OR REPLACE FUNCTION public.flag_order_bundle_limit_after_summary_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
  v_order_total numeric(12,2);
  v_active_total numeric(12,2);
  v_breach numeric(12,2);
  v_invoice_ref text;
BEGIN
  IF NEW.source IS DISTINCT FROM 'operator_entered'
     OR NEW.entered_by_operator_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT si.order_id, si.invoice_ref, ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2)
    INTO v_order_id, v_invoice_ref, v_order_total
  FROM public.supplier_invoices si
  JOIN public.orders o ON o.id = si.order_id
  WHERE si.id = NEW.supplier_invoice_id;

  IF v_order_id IS NULL OR v_order_total <= 0 THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('order_bundle_limit:' || v_order_id::text));

  SELECT ROUND(COALESCE(SUM(fs.invoice_total_gbp), 0)::numeric, 2)
    INTO v_active_total
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = v_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

  v_breach := ROUND((v_active_total - v_order_total)::numeric, 2);
  IF v_breach > 0.01
     AND NOT EXISTS (
       SELECT 1
       FROM public.supplier_invoice_review_flags f
       WHERE f.supplier_invoice_id = NEW.supplier_invoice_id
         AND f.flag_type = 'order_bundle_limit_breach'
         AND f.status IN ('open','under_review')
     ) THEN
    INSERT INTO public.supplier_invoice_review_flags (
      order_id,
      supplier_invoice_id,
      flag_type,
      message,
      status,
      raised_by_operator_id
    ) VALUES (
      v_order_id,
      NEW.supplier_invoice_id,
      'order_bundle_limit_breach',
      format(
        'Uploading %s takes active gross supplier invoices to GBP %s against the accepted estimate of GBP %s. The order exceeds the accepted estimate by GBP %s and requires supervisor review.',
        COALESCE(v_invoice_ref, NEW.supplier_invoice_id::text),
        to_char(v_active_total, 'FM999999990.00'),
        to_char(v_order_total, 'FM999999990.00'),
        to_char(v_breach, 'FM999999990.00')
      ),
      'open',
      NEW.entered_by_operator_id
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_flag_order_bundle_limit_after_summary_v1
  ON public.supplier_invoice_financial_summary;
CREATE TRIGGER trg_flag_order_bundle_limit_after_summary_v1
AFTER INSERT ON public.supplier_invoice_financial_summary
FOR EACH ROW
EXECUTE FUNCTION public.flag_order_bundle_limit_after_summary_v1();

-- Backfill only currently active over-limit bundles. The newest active invoice is
-- flagged because it is the upload that completed the current bundle position.
WITH active_positions AS (
  SELECT
    o.id AS order_id,
    ROUND(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS accepted_gbp,
    ROUND(COALESCE(SUM(fs.invoice_total_gbp), 0)::numeric, 2) AS active_gbp
  FROM public.orders o
  JOIN public.supplier_invoices si ON si.order_id = o.id
  JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
  GROUP BY o.id, o.order_total_gbp_declared
), newest_invoice AS (
  SELECT DISTINCT ON (si.order_id)
    si.order_id,
    si.id AS supplier_invoice_id,
    si.invoice_ref,
    fs.entered_by_operator_id
  FROM public.supplier_invoices si
  JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
  WHERE COALESCE(si.review_status, 'pending_review') NOT IN (
    'rejected_resubmit_required',
    'duplicate_blocked',
    'superseded'
  )
  ORDER BY si.order_id, si.uploaded_at DESC NULLS LAST, si.id DESC
)
INSERT INTO public.supplier_invoice_review_flags (
  order_id,
  supplier_invoice_id,
  flag_type,
  message,
  status,
  raised_by_operator_id
)
SELECT
  p.order_id,
  n.supplier_invoice_id,
  'order_bundle_limit_breach',
  format(
    'Uploading %s takes active gross supplier invoices to GBP %s against the accepted estimate of GBP %s. The order exceeds the accepted estimate by GBP %s and requires supervisor review.',
    COALESCE(n.invoice_ref, n.supplier_invoice_id::text),
    to_char(p.active_gbp, 'FM999999990.00'),
    to_char(p.accepted_gbp, 'FM999999990.00'),
    to_char(p.active_gbp - p.accepted_gbp, 'FM999999990.00')
  ),
  'open',
  n.entered_by_operator_id
FROM active_positions p
JOIN newest_invoice n ON n.order_id = p.order_id
WHERE p.accepted_gbp > 0
  AND p.active_gbp > p.accepted_gbp + 0.01
  AND n.entered_by_operator_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoice_review_flags f
    WHERE f.supplier_invoice_id = n.supplier_invoice_id
      AND f.flag_type = 'order_bundle_limit_breach'
      AND f.status IN ('open','under_review')
  );

REVOKE ALL ON FUNCTION public.flag_order_bundle_limit_after_summary_v1() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;
