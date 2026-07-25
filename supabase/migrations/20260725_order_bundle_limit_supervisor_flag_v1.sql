BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Extend the existing supplier-invoice review lane only. This migration does not
-- alter order values, invoice totals, delivery/discount values, funding, banking,
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

-- Replace only the single-column flag_type check. Any additional or differently
-- shaped constraint is left untouched and causes a fail-closed abort rather than
-- being removed by a broad constraint sweep.
DO $$
DECLARE
  v_flag_attnum smallint;
  v_constraint_count integer;
  v_constraint_name text;
  v_constraint_definition text;
BEGIN
  SELECT a.attnum
    INTO v_flag_attnum
  FROM pg_attribute a
  WHERE a.attrelid = 'public.supplier_invoice_review_flags'::regclass
    AND a.attname = 'flag_type'
    AND NOT a.attisdropped;

  SELECT
    count(*)::integer,
    min(c.conname),
    min(pg_get_constraintdef(c.oid, true))
  INTO v_constraint_count, v_constraint_name, v_constraint_definition
  FROM pg_constraint c
  WHERE c.conrelid = 'public.supplier_invoice_review_flags'::regclass
    AND c.contype = 'c'
    AND c.conkey = ARRAY[v_flag_attnum]::smallint[];

  IF v_constraint_count <> 1 OR v_constraint_name IS NULL THEN
    RAISE EXCEPTION 'Expected exactly one single-column flag_type check; found %. No constraint changed.', v_constraint_count;
  END IF;

  IF v_constraint_definition NOT LIKE '%invoice_total_mismatch%'
     OR v_constraint_definition NOT LIKE '%ocr_unclear%'
     OR v_constraint_definition NOT LIKE '%wrong_invoice%'
     OR v_constraint_definition NOT LIKE '%delivery_discount_query%'
     OR v_constraint_definition NOT LIKE '%manual_line_needed%'
     OR v_constraint_definition NOT LIKE '%other%' THEN
    RAISE EXCEPTION 'Existing flag_type constraint does not match the established review types. No constraint changed.';
  END IF;

  EXECUTE format(
    'ALTER TABLE public.supplier_invoice_review_flags DROP CONSTRAINT %I',
    v_constraint_name
  );

  ALTER TABLE public.supplier_invoice_review_flags
    ADD CONSTRAINT supplier_invoice_review_flags_flag_type_v2_check
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

-- Preserve the exact currently deployed match-decision implementation under a
-- stable internal name, then wrap it. The wrapper changes only serious-flag
-- classification/routing; every existing source, equation and output column is
-- returned unchanged from the preserved view.
DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_match_decision_pre_bundle_limit_v1') IS NULL THEN
    ALTER VIEW public.supplier_invoice_match_decision_vw
      RENAME TO supplier_invoice_match_decision_pre_bundle_limit_v1;
  END IF;
END $$;

CREATE OR REPLACE VIEW public.supplier_invoice_match_decision_vw AS
WITH serious_flags AS (
  SELECT
    f.supplier_invoice_id,
    count(*)::integer AS serious_open_review_flag_count
  FROM public.supplier_invoice_review_flags f
  WHERE f.status IN ('open','under_review')
    AND f.flag_type IN (
      'wrong_invoice',
      'ocr_unclear',
      'invoice_total_mismatch',
      'delivery_discount_query',
      'manual_line_needed',
      'order_bundle_limit_breach'
    )
  GROUP BY f.supplier_invoice_id
)
SELECT
  base.supplier_invoice_id,
  base.order_id,
  base.order_ref,
  base.order_retailer_name,
  base.operator_invoice_ref,
  base.ocr_invoice_ref,
  base.invoice_ref_match_yn,
  base.operator_total_gbp,
  base.ocr_total_gbp,
  base.total_match_yn,
  base.ocr_retailer_name,
  base.retailer_match_yn,
  base.ocr_invoice_date,
  base.ocr_line_count,
  base.progressed_line_count,
  base.ocr_line_total_gbp,
  base.pending_adjustment_yn,
  base.pending_adjustment_count,
  base.open_review_flag_count,
  COALESCE(sf.serious_open_review_flag_count, 0) AS serious_open_review_flag_count,
  base.review_status,
  base.blocked_from_sage_yn,
  base.has_ocr_raw_json,
  base.ocr_extracted_at,
  CASE
    WHEN base.routing_decision = 'rejected_audit_only' THEN base.routing_decision
    WHEN COALESCE(sf.serious_open_review_flag_count, 0) > 0 THEN 'needs_invoice_review'
    ELSE base.routing_decision
  END AS routing_decision,
  CASE
    WHEN base.routing_decision = 'rejected_audit_only' THEN base.routing_reason
    WHEN COALESCE(sf.serious_open_review_flag_count, 0) > 0 THEN 'Serious open invoice review flag exists.'
    ELSE base.routing_reason
  END AS routing_reason,
  (
    COALESCE(base.supplier_approval_blocked_yn, false)
    OR COALESCE(sf.serious_open_review_flag_count, 0) > 0
  ) AS supplier_approval_blocked_yn,
  CASE
    WHEN base.supplier_approval_block_reason IS NOT NULL THEN base.supplier_approval_block_reason
    WHEN COALESCE(sf.serious_open_review_flag_count, 0) > 0 THEN 'Serious invoice review flag blocks supplier approval.'
    ELSE NULL
  END AS supplier_approval_block_reason
FROM public.supplier_invoice_match_decision_pre_bundle_limit_v1 base
LEFT JOIN serious_flags sf ON sf.supplier_invoice_id = base.supplier_invoice_id;

COMMENT ON VIEW public.supplier_invoice_match_decision_vw IS
'Exact preserved supplier-invoice match decision, wrapped only to classify delivery/discount queries and accepted-estimate bundle breaches as existing serious supervisor review flags.';

GRANT SELECT ON public.supplier_invoice_match_decision_vw TO authenticated, service_role;

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
  -- The existing upload path writes the operator-entered gross invoice total.
  -- OCR/staff/system summaries are not uploads and cannot create this warning.
  IF NEW.source IS DISTINCT FROM 'operator_entered'
     OR NEW.entered_by_operator_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT
    si.order_id,
    si.invoice_ref,
    round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2)
  INTO v_order_id, v_invoice_ref, v_order_total
  FROM public.supplier_invoices si
  JOIN public.orders o ON o.id = si.order_id
  WHERE si.id = NEW.supplier_invoice_id;

  IF v_order_id IS NULL OR v_order_total <= 0 THEN
    RETURN NEW;
  END IF;

  -- Serialise concurrent uploads for the same order. Under READ COMMITTED, the
  -- total query below obtains a fresh snapshot after this lock is acquired.
  PERFORM pg_advisory_xact_lock(hashtext('order_bundle_limit:' || v_order_id::text));

  SELECT round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2)
  INTO v_active_total
  FROM public.supplier_invoice_financial_summary fs
  JOIN public.supplier_invoices si ON si.id = fs.supplier_invoice_id
  WHERE si.order_id = v_order_id
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    );

  v_breach := round((v_active_total - v_order_total)::numeric, 2);

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

-- The trigger governs every future upload. Backfill only the exact current test
-- order that already breached before this trigger existed; unrelated historical
-- orders are deliberately not touched.
WITH active_position AS (
  SELECT
    o.id AS order_id,
    round(COALESCE(o.order_total_gbp_declared, 0)::numeric, 2) AS accepted_gbp,
    round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2) AS active_gbp
  FROM public.orders o
  JOIN public.supplier_invoices si ON si.order_id = o.id
  JOIN public.supplier_invoice_financial_summary fs ON fs.supplier_invoice_id = si.id
  WHERE o.id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
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
  WHERE si.order_id = 'abf15b7b-771f-482f-9751-2af0ee0bcbb1'::uuid
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
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
FROM active_position p
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
