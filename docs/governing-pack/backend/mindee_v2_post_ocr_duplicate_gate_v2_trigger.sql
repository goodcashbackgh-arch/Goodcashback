-- =============================================================================
-- mindee_v2_post_ocr_duplicate_gate_v2_trigger.sql
-- Multi Tenant Platform Build — automatic post-OCR duplicate gate
--
-- Purpose:
--   Catch duplicates where operator-submitted ref/amount were wrong or different,
--   but OCR extracts the real invoice ref/total already processed elsewhere.
--
-- Behaviour:
--   When OCR fields are saved on supplier_invoices, the trigger compares:
--     - OCR invoice ref
--     - OCR gross total
--     - same retailer_id OR reasonably matching OCR supplier/retailer name
--   If duplicated, the invoice is marked duplicate_blocked and blocked from Sage.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_financial_summary') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_financial_summary';
  END IF;

  IF to_regclass('public.supplier_invoice_review_flags') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_review_flags';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.trg_supplier_invoice_post_ocr_duplicate_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_ref_norm text;
  v_current_total numeric;
  v_current_ocr_retailer_norm text;
  v_duplicate_id uuid;
  v_duplicate_order_id uuid;
  v_reason text;
  v_message text;
BEGIN
  IF TG_OP <> 'UPDATE' THEN
    RETURN NEW;
  END IF;

  IF NEW.review_status IN ('rejected_resubmit_required','superseded','duplicate_blocked') THEN
    RETURN NEW;
  END IF;

  IF NEW.ocr_raw_json IS NULL
     OR NEW.ocr_invoice_ref IS NULL
     OR NEW.ocr_invoice_total_gbp IS NULL THEN
    RETURN NEW;
  END IF;

  IF OLD.ocr_raw_json IS NOT NULL
     AND OLD.ocr_invoice_ref IS NOT DISTINCT FROM NEW.ocr_invoice_ref
     AND OLD.ocr_invoice_total_gbp IS NOT DISTINCT FROM NEW.ocr_invoice_total_gbp
     AND OLD.ocr_retailer_name IS NOT DISTINCT FROM NEW.ocr_retailer_name THEN
    RETURN NEW;
  END IF;

  v_current_ref_norm := lower(regexp_replace(COALESCE(NEW.ocr_invoice_ref, ''), '[^a-zA-Z0-9]+', '', 'g'));
  v_current_total := round(COALESCE(NEW.ocr_invoice_total_gbp, 0)::numeric, 2);
  v_current_ocr_retailer_norm := lower(regexp_replace(COALESCE(NEW.ocr_retailer_name, ''), '[^a-zA-Z0-9]+', '', 'g'));

  IF v_current_ref_norm = '' OR v_current_total <= 0 THEN
    RETURN NEW;
  END IF;

  WITH candidate AS (
    SELECT
      si.id,
      si.order_id,
      si.review_status,
      si.mindee_ocr_status,
      si.is_current_for_order,
      si.retailer_id,
      si.ocr_raw_json,
      lower(regexp_replace(COALESCE(si.ocr_invoice_ref, si.invoice_ref, ''), '[^a-zA-Z0-9]+', '', 'g')) AS candidate_ref_norm,
      lower(regexp_replace(COALESCE(si.ocr_retailer_name, ''), '[^a-zA-Z0-9]+', '', 'g')) AS candidate_ocr_retailer_norm,
      round(COALESCE(si.ocr_invoice_total_gbp, sifs.invoice_total_gbp, 0)::numeric, 2) AS candidate_total
    FROM public.supplier_invoices si
    LEFT JOIN public.supplier_invoice_financial_summary sifs
      ON sifs.supplier_invoice_id = si.id
    WHERE si.id <> NEW.id
      AND si.review_status NOT IN ('rejected_resubmit_required','superseded')
  ), matched AS (
    SELECT
      c.id,
      c.order_id,
      CASE
        WHEN c.retailer_id = NEW.retailer_id
          THEN 'same retailer, OCR invoice ref and OCR total'
        WHEN v_current_ocr_retailer_norm <> ''
          AND c.candidate_ocr_retailer_norm <> ''
          THEN 'matching OCR supplier name, OCR invoice ref and OCR total'
        ELSE 'matching OCR invoice ref and OCR total'
      END AS reason
    FROM candidate c
    WHERE c.candidate_ref_norm = v_current_ref_norm
      AND abs(c.candidate_total - v_current_total) <= 0.01
      AND (
        c.ocr_raw_json IS NOT NULL
        OR c.mindee_ocr_status IN ('queued','processing','completed')
        OR c.is_current_for_order = true
      )
      AND (
        c.retailer_id = NEW.retailer_id
        OR (
          v_current_ocr_retailer_norm <> ''
          AND c.candidate_ocr_retailer_norm <> ''
          AND (
            v_current_ocr_retailer_norm = c.candidate_ocr_retailer_norm
            OR v_current_ocr_retailer_norm LIKE '%' || c.candidate_ocr_retailer_norm || '%'
            OR c.candidate_ocr_retailer_norm LIKE '%' || v_current_ocr_retailer_norm || '%'
          )
        )
      )
    ORDER BY c.is_current_for_order DESC, c.review_status = 'duplicate_blocked', c.id
    LIMIT 1
  )
  SELECT id, order_id, reason
  INTO v_duplicate_id, v_duplicate_order_id, v_reason
  FROM matched;

  IF v_duplicate_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_message := 'Possible duplicate invoice blocked after OCR. OCR extracted invoice ref '
    || COALESCE(NEW.ocr_invoice_ref, '—')
    || ' and total '
    || COALESCE(NEW.ocr_invoice_total_gbp::text, '—')
    || ', matching existing supplier invoice '
    || v_duplicate_id::text
    || ' (' || COALESCE(v_reason, 'duplicate suspected') || ').';

  NEW.review_status := 'duplicate_blocked';
  NEW.blocked_from_sage_yn := true;
  NEW.review_notes := concat_ws(E'\n', NULLIF(NEW.review_notes, ''), v_message);

  IF NEW.uploaded_by_operator_id IS NOT NULL THEN
    INSERT INTO public.supplier_invoice_review_flags (
      order_id,
      supplier_invoice_id,
      flag_type,
      message,
      status,
      raised_by_operator_id
    )
    SELECT
      NEW.order_id,
      NEW.id,
      'wrong_invoice',
      v_message,
      'open',
      NEW.uploaded_by_operator_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.supplier_invoice_review_flags existing
      WHERE existing.supplier_invoice_id = NEW.id
        AND existing.flag_type = 'wrong_invoice'
        AND existing.status IN ('open','under_review')
    );
  END IF;

  RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'trg_supplier_invoice_post_ocr_duplicate_gate'
  ) THEN
    DROP TRIGGER trg_supplier_invoice_post_ocr_duplicate_gate ON public.supplier_invoices;
  END IF;

  CREATE TRIGGER trg_supplier_invoice_post_ocr_duplicate_gate
  BEFORE UPDATE OF ocr_raw_json, ocr_invoice_ref, ocr_invoice_total_gbp, ocr_retailer_name
  ON public.supplier_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_supplier_invoice_post_ocr_duplicate_gate();
END $$;

COMMIT;
