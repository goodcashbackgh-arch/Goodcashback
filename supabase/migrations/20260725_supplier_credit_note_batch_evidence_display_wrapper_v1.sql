BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Preserve the exact live posting-batch detail implementation and add only the
-- missing supplier-credit evidence resolution around it. This fixes existing and
-- future supplier-credit batches without changing posting, freeze, payload, VAT,
-- supplier-goods AP, shipper AP or customer-sales behaviour.

DO $guard$
BEGIN
  IF to_regprocedure('public.internal_sage_posting_batch_detail_v1(uuid)') IS NULL
     AND to_regprocedure('public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_sage_posting_batch_detail_v1(uuid)';
  END IF;

  IF to_regprocedure('public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid)') IS NULL THEN
    ALTER FUNCTION public.internal_sage_posting_batch_detail_v1(uuid)
      RENAME TO internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1;
  END IF;
END
$guard$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid) FROM service_role;

CREATE OR REPLACE FUNCTION public.internal_sage_posting_batch_detail_v1(
  p_batch_id uuid
)
RETURNS TABLE (
  batch_id uuid,
  batch_ref text,
  batch_status text,
  status text,
  lane text,
  row_count integer,
  total_amount_gbp numeric,
  success_count integer,
  failed_count integer,
  blocked_count integer,
  notes text,
  created_at timestamptz,
  created_by_staff_id uuid,
  posting_started_at timestamptz,
  posting_completed_at timestamptz,
  batch_summary jsonb,
  row_id uuid,
  snapshot_id uuid,
  idempotency_key text,
  posting_status text,
  sage_object_type text,
  sage_object_id text,
  sage_reference text,
  payload_hash text,
  payload_validation_status text,
  exclusion_reason text,
  error_code text,
  error_message text,
  attempt_count integer,
  posted_at timestamptz,
  last_attempt_at timestamptz,
  source_table text,
  source_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  reference_text text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  request_payload_json jsonb,
  response_payload_json jsonb,
  ap_net_amount_gbp numeric,
  ap_vat_amount_gbp numeric,
  ap_gross_amount_gbp numeric,
  ap_vat_rate_summary text,
  ap_vat_control_status text,
  source_invoice_file_url text,
  source_evidence_status text,
  row_created_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH base AS (
    SELECT *
    FROM public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(p_batch_id)
  ), resolved AS (
    SELECT
      b.*,
      CASE
        WHEN b.document_lane = 'supplier_credit_note' THEN COALESCE(
          NULLIF(b.source_invoice_file_url, ''),
          NULLIF(b.request_payload_json #>> '{source_evidence,file_url}', ''),
          NULLIF(b.request_payload_json #>> '{evidence,credit_note_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{evidence,refund_proof_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{evidence,internal_no_cn_memo_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{evidence,file_url}', ''),
          NULLIF(b.request_payload_json #>> '{credit_note_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{refund_proof_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{internal_no_cn_memo_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,evidence,credit_note_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,evidence,refund_proof_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,evidence,internal_no_cn_memo_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,evidence,file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,credit_note_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,refund_proof_file_url}', ''),
          NULLIF(b.request_payload_json #>> '{source_payload,internal_no_cn_memo_file_url}', ''),
          NULLIF(dres.credit_note_file_url, ''),
          NULLIF(dres.refund_proof_file_url, '')
        )
        ELSE b.source_invoice_file_url
      END::text AS resolved_source_file_url
    FROM base b
    LEFT JOIN public.dispute_refund_evidence_submissions dres
      ON b.document_lane = 'supplier_credit_note'
     AND b.source_table = 'dispute_refund_evidence_submissions'
     AND dres.id = b.source_id
  )
  SELECT
    r.batch_id,
    r.batch_ref,
    r.batch_status,
    r.status,
    r.lane,
    r.row_count,
    r.total_amount_gbp,
    r.success_count,
    r.failed_count,
    r.blocked_count,
    r.notes,
    r.created_at,
    r.created_by_staff_id,
    r.posting_started_at,
    r.posting_completed_at,
    r.batch_summary,
    r.row_id,
    r.snapshot_id,
    r.idempotency_key,
    r.posting_status,
    r.sage_object_type,
    r.sage_object_id,
    r.sage_reference,
    r.payload_hash,
    r.payload_validation_status,
    r.exclusion_reason,
    r.error_code,
    r.error_message,
    r.attempt_count,
    r.posted_at,
    r.last_attempt_at,
    r.source_table,
    r.source_id,
    r.document_lane,
    r.document_type,
    r.order_ref,
    r.reference_text,
    r.counterparty_name,
    r.amount_gbp,
    r.currency_code,
    r.request_payload_json,
    r.response_payload_json,
    r.ap_net_amount_gbp,
    r.ap_vat_amount_gbp,
    r.ap_gross_amount_gbp,
    r.ap_vat_rate_summary,
    r.ap_vat_control_status,
    r.resolved_source_file_url AS source_invoice_file_url,
    CASE
      WHEN r.document_lane <> 'supplier_credit_note' THEN r.source_evidence_status
      WHEN NULLIF(r.resolved_source_file_url, '') IS NULL THEN 'missing_source_evidence_file'
      ELSE 'source_evidence_available'
    END::text AS source_evidence_status,
    r.row_created_at
  FROM resolved r;
$function$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) TO service_role;

COMMENT ON FUNCTION public.internal_sage_posting_batch_detail_v1_pre_supplier_credit_evidence_display_v1(uuid) IS
'Private exact posting-batch detail implementation preserved before supplier-credit evidence display restoration.';

COMMENT ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) IS
'Canonical posting-batch detail. Preserves the exact prior implementation and resolves supplier-credit source evidence from the frozen payload or existing refund evidence record for current and future batches.';

NOTIFY pgrst, 'reload schema';

COMMIT;
