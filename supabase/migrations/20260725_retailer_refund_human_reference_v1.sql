BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Sage contact_payment.reference has an established 32-character limit in this repo.
-- Keep the existing GCB-REF- format, but source the readable component from the
-- already-frozen, posted supplier-credit payload that created the allocated Sage
-- purchase credit note. This reuses the same reference already visible on that credit.
-- Only retailer-refund IN freeze payloads and active unposted frozen rows are touched.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_line_allocation_detail_vw') IS NULL THEN
    RAISE EXCEPTION 'Missing dva_statement_line_allocation_detail_vw';
  END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Missing dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing sage_posting_snapshots';
  END IF;
  IF to_regclass('public.cash_posting_snapshots') IS NULL THEN
    RAISE EXCEPTION 'Missing cash_posting_snapshots';
  END IF;
  IF to_regclass('public.cash_posting_batch_rows') IS NULL THEN
    RAISE EXCEPTION 'Missing cash_posting_batch_rows';
  END IF;
  IF to_regprocedure('public.internal_freeze_cash_control_rows_v1(text[],text)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_freeze_cash_control_rows_v1(text[],text)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_retailer_refund_reference_source_v1(
  p_allocation_id uuid
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH allocation AS (
    SELECT
      adv.dispute_id,
      NULLIF(trim(COALESCE(adv.supplier_invoice_ref::text, '')), '') AS supplier_invoice_ref,
      NULLIF(trim(COALESCE(adv.order_ref::text, '')), '') AS order_ref
    FROM public.dva_statement_line_allocation_detail_vw adv
    WHERE adv.allocation_id = p_allocation_id
      AND adv.allocation_type = 'retailer_refund'
    LIMIT 1
  ), approved_evidence AS (
    SELECT
      s.id AS refund_evidence_submission_id,
      NULLIF(trim(COALESCE(s.credit_note_ref::text, '')), '') AS credit_note_ref
    FROM allocation a
    JOIN public.dispute_refund_evidence_submissions s
      ON s.dispute_id = a.dispute_id
    WHERE s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
    ORDER BY s.supplier_approved_at DESC NULLS LAST, s.created_at DESC
    LIMIT 1
  ), posted_credit_payload AS (
    SELECT NULLIF(trim(COALESCE(
      sps.resolved_payload #>> '{sage_header,reference}',
      sps.resolved_payload ->> 'credit_note_ref',
      sps.resolved_payload #>> '{source_payload,sage_header,reference}',
      sps.resolved_payload #>> '{source_payload,credit_note_ref}',
      ''
    )), '') AS payload_reference
    FROM approved_evidence ae
    JOIN public.sage_posting_snapshots sps
      ON sps.source_id = ae.refund_evidence_submission_id
    WHERE sps.document_lane = 'supplier_credit_note'
      AND sps.sage_posting_status = 'posted'
      AND NULLIF(trim(COALESCE(sps.sage_invoice_id, '')), '') IS NOT NULL
    ORDER BY sps.sage_posted_at DESC NULLS LAST, sps.created_at DESC
    LIMIT 1
  )
  SELECT COALESCE(
    (SELECT payload_reference FROM posted_credit_payload),
    (SELECT credit_note_ref FROM approved_evidence),
    (SELECT supplier_invoice_ref FROM allocation),
    (SELECT order_ref FROM allocation),
    p_allocation_id::text
  );
$$;

CREATE OR REPLACE FUNCTION public.internal_retailer_refund_short_reference_v1(
  p_allocation_id uuid
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT upper(left(
    'GCB-REF-' || COALESCE(
      NULLIF(
        trim(BOTH '-' FROM regexp_replace(
          regexp_replace(
            COALESCE(public.internal_retailer_refund_reference_source_v1(p_allocation_id), ''),
            '[^A-Za-z0-9-]+',
            '-',
            'g'
          ),
          '-+',
          '-',
          'g'
        )),
        ''
      ),
      replace(p_allocation_id::text, '-', '')
    ),
    32
  ));
$$;

REVOKE ALL ON FUNCTION public.internal_retailer_refund_reference_source_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_retailer_refund_short_reference_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_retailer_refund_reference_source_v1(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.internal_retailer_refund_short_reference_v1(uuid) TO authenticated, service_role;

DO $patch$
DECLARE
  v_def text;
  v_old_short text := $old$WHEN wb.category = 'retailer_refund_received' THEN 'GCB-REF-' || left(COALESCE(wb.matched_target_ref, wb.order_ref, wb.source_id::text), 20)$old$;
  v_new_short text := $new$WHEN wb.category = 'retailer_refund_received' THEN public.internal_retailer_refund_short_reference_v1(wb.source_id)$new$;
  v_old_payload text := $old$jsonb_build_object('endpoint','endpoint_prove_required','method','POST','posting_category',prepared.normal_category,'live_posting_status','blocked_endpoint_prove_required'),$old$;
  v_new_payload text := $new$CASE
        WHEN prepared.normal_category = 'retailer_refund_received' THEN
          jsonb_build_object(
            'endpoint','endpoint_prove_required',
            'method','POST',
            'posting_category',prepared.normal_category,
            'live_posting_status','blocked_endpoint_prove_required',
            'supplier_refund_candidate',jsonb_build_object(
              'contact_id',prepared.wb_sage_contact_id,
              'bank_account_id',prepared.wb_sage_bank_account_id,
              'date',prepared.post_date::text,
              'total_amount',prepared.wb_amount_gbp,
              'reference',prepared.short_ref,
              'matched_target_ref',public.internal_retailer_refund_reference_source_v1(prepared.wb_source_id)
            )
          )
        ELSE
          jsonb_build_object('endpoint','endpoint_prove_required','method','POST','posting_category',prepared.normal_category,'live_posting_status','blocked_endpoint_prove_required')
      END,$new$;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_freeze_cash_control_rows_v1(text[],text)'::regprocedure
  ) INTO v_def;

  IF position('internal_retailer_refund_short_reference_v1' in v_def) = 0 THEN
    IF position(v_old_short in v_def) = 0 THEN
      RAISE EXCEPTION 'Expected retailer-refund short-reference expression was not found; freeze function not patched.';
    END IF;
    v_def := replace(v_def, v_old_short, v_new_short);
  END IF;

  IF position('supplier_refund_candidate' in v_def) = 0 THEN
    IF position(v_old_payload in v_def) = 0 THEN
      RAISE EXCEPTION 'Expected generic cash-control request payload expression was not found; freeze payload not patched.';
    END IF;
    v_def := replace(v_def, v_old_payload, v_new_payload);
  END IF;

  EXECUTE v_def;
END
$patch$;

-- Repair only active, unposted retailer-refund snapshots/batch rows.
-- Posted Sage objects remain immutable and are deliberately excluded.
WITH candidates AS (
  SELECT
    s.id AS snapshot_id,
    public.internal_retailer_refund_short_reference_v1(s.source_id) AS safe_reference,
    public.internal_retailer_refund_reference_source_v1(s.source_id) AS source_reference
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.posting_category = 'retailer_refund_received'
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
    AND NULLIF(trim(COALESCE(s.sage_object_id, '')), '') IS NULL
), repaired_snapshots AS (
  UPDATE public.cash_posting_snapshots s
  SET
    short_reference = c.safe_reference,
    request_payload = jsonb_set(
      jsonb_set(
        COALESCE(s.request_payload, '{}'::jsonb),
        '{supplier_refund_candidate}',
        COALESCE(s.request_payload->'supplier_refund_candidate', '{}'::jsonb)
          || jsonb_build_object(
            'contact_id', s.sage_contact_id,
            'bank_account_id', s.sage_bank_account_id,
            'date', s.posting_date::text,
            'total_amount', s.amount_gbp,
            'reference', c.safe_reference,
            'matched_target_ref', c.source_reference
          ),
        true
      ),
      '{internal_reference_json}',
      COALESCE(s.request_payload->'internal_reference_json', '{}'::jsonb)
        || jsonb_build_object(
          'retailer_refund_reference_source', c.source_reference,
          'retailer_refund_short_reference', c.safe_reference
        ),
      true
    ),
    internal_reference_json = COALESCE(s.internal_reference_json, '{}'::jsonb)
      || jsonb_build_object(
        'retailer_refund_reference_source', c.source_reference,
        'retailer_refund_short_reference', c.safe_reference
      ),
    updated_at = now()
  FROM candidates c
  WHERE s.id = c.snapshot_id
  RETURNING s.id
), repaired_rows AS (
  UPDATE public.cash_posting_batch_rows br
  SET
    request_payload = s.request_payload,
    posting_status = CASE
      WHEN br.posting_status LIKE 'failed%'
       AND COALESCE(br.error_message, '') ILIKE '%maximum is 32%'
      THEN 'failed_retryable'
      ELSE br.posting_status
    END,
    response_payload = CASE
      WHEN br.posting_status LIKE 'failed%'
       AND COALESCE(br.error_message, '') ILIKE '%maximum is 32%'
      THEN NULL
      ELSE br.response_payload
    END,
    error_code = CASE
      WHEN br.posting_status LIKE 'failed%'
       AND COALESCE(br.error_message, '') ILIKE '%maximum is 32%'
      THEN NULL
      ELSE br.error_code
    END,
    error_message = CASE
      WHEN br.posting_status LIKE 'failed%'
       AND COALESCE(br.error_message, '') ILIKE '%maximum is 32%'
      THEN NULL
      ELSE br.error_message
    END,
    updated_at = now()
  FROM public.cash_posting_snapshots s
  JOIN repaired_snapshots rs ON rs.id = s.id
  WHERE br.active = true
    AND br.snapshot_id = s.id
    AND br.posting_category = 'retailer_refund_received'
    AND NULLIF(trim(COALESCE(br.sage_object_id, '')), '') IS NULL
  RETURNING br.batch_id
)
SELECT count(*) FROM repaired_rows;

NOTIFY pgrst, 'reload schema';

COMMIT;
