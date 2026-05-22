BEGIN;

-- Batch detail display fix: supplier credit note rows must expose the attached credit note file
-- through source_invoice_file_url/source_evidence_status, the same columns the batch UI already renders.
-- No Sage API call. No posting. No schema change.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: posting batch detail requires auth.uid()';
  END IF;

  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for posting batch detail.';
  END IF;

  RETURN QUERY
  WITH batch AS (
    SELECT b.*
    FROM public.sage_posting_batches b
    WHERE b.id = p_batch_id
  ), rows AS (
    SELECT r.*
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
  ), line_calc AS (
    SELECT
      r.id AS row_id,
      COALESCE(SUM(public.internal_sage_jsonb_num_v1(line.value->'net_amount_gbp')), 0)::numeric(18,2) AS ap_net_amount_gbp,
      COALESCE(SUM(public.internal_sage_jsonb_num_v1(line.value->'vat_amount_gbp')), 0)::numeric(18,2) AS ap_vat_amount_gbp,
      COALESCE(SUM(public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp')), 0)::numeric(18,2) AS ap_gross_amount_gbp,
      string_agg(DISTINCT COALESCE(line.value->>'vat_rate_percent', ''), ', ' ORDER BY COALESCE(line.value->>'vat_rate_percent', '')) FILTER (WHERE NULLIF(line.value->>'vat_rate_percent', '') IS NOT NULL) AS ap_vat_rate_summary,
      COUNT(*) FILTER (
        WHERE line.value ? 'net_amount_gbp'
          AND line.value ? 'vat_amount_gbp'
          AND line.value ? 'gross_amount_gbp'
      ) AS lines_with_net_vat_gross,
      COUNT(*) AS line_count,
      COUNT(*) FILTER (
        WHERE line.value ? 'net_amount_gbp'
          AND line.value ? 'vat_amount_gbp'
          AND line.value ? 'gross_amount_gbp'
          AND abs(
            round((COALESCE(public.internal_sage_jsonb_num_v1(line.value->'net_amount_gbp'), 0) + COALESCE(public.internal_sage_jsonb_num_v1(line.value->'vat_amount_gbp'), 0))::numeric, 2)
            - round(COALESCE(public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp'), 0)::numeric, 2)
          ) <= 0.01
      ) AS lines_balanced
    FROM rows r
    LEFT JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(r.request_payload_json->'resolved_lines') = 'array'
        THEN r.request_payload_json->'resolved_lines'
        ELSE '[]'::jsonb
      END
    ) AS line(value) ON true
    GROUP BY r.id
  ), supplier_evidence AS (
    SELECT
      r.id AS row_id,
      si.invoice_pdf_url::text AS supplier_invoice_file_url
    FROM rows r
    LEFT JOIN public.supplier_invoices si
      ON r.source_table = 'supplier_invoices'
     AND si.id = r.source_id
  ), refund_evidence AS (
    SELECT
      r.id AS row_id,
      COALESCE(dres.credit_note_file_url, dres.refund_proof_file_url)::text AS refund_source_file_url
    FROM rows r
    LEFT JOIN public.dispute_refund_evidence_submissions dres
      ON r.source_table = 'dispute_refund_evidence_submissions'
     AND dres.id = r.source_id
  ), summary AS (
    SELECT jsonb_build_object(
      'included_count', COUNT(*) FILTER (WHERE r.posting_status <> 'excluded'),
      'excluded_count', COUNT(*) FILTER (WHERE r.posting_status = 'excluded'),
      'validated_count', COUNT(*) FILTER (WHERE r.posting_status = 'validated'),
      'posted_count', COUNT(*) FILTER (WHERE r.posting_status = 'posted'),
      'failed_count', COUNT(*) FILTER (WHERE r.posting_status IN ('failed_retryable','failed_terminal')),
      'total_included_value', COALESCE(SUM(r.amount_gbp) FILTER (WHERE r.posting_status <> 'excluded'), 0),
      'customer_sales_count', COUNT(*) FILTER (WHERE r.document_lane = 'customer_sales' AND r.posting_status <> 'excluded'),
      'supplier_goods_ap_count', COUNT(*) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'),
      'shipper_ap_count', COUNT(*) FILTER (WHERE r.document_lane = 'shipper_ap' AND r.posting_status <> 'excluded'),
      'supplier_goods_ap_net_total_gbp', COALESCE(SUM(lc.ap_net_amount_gbp) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'), 0),
      'supplier_goods_ap_vat_total_gbp', COALESCE(SUM(lc.ap_vat_amount_gbp) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'), 0),
      'supplier_goods_ap_gross_total_gbp', COALESCE(SUM(lc.ap_gross_amount_gbp) FILTER (WHERE r.document_lane = 'supplier_goods_ap' AND r.posting_status <> 'excluded'), 0),
      'posting_disabled_reason', 'Posting disabled until Sage OAuth and dry-run validation are proven.'
    ) AS batch_summary
    FROM rows r
    LEFT JOIN line_calc lc ON lc.row_id = r.id
  )
  SELECT
    b.id AS batch_id,
    b.batch_ref,
    b.batch_status,
    b.status,
    b.lane,
    b.row_count,
    b.total_amount_gbp,
    b.success_count,
    b.failed_count,
    b.blocked_count,
    b.notes,
    b.created_at,
    b.created_by_staff_id,
    b.posting_started_at,
    b.posting_completed_at,
    s.batch_summary,
    r.id AS row_id,
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
    lc.ap_net_amount_gbp,
    lc.ap_vat_amount_gbp,
    lc.ap_gross_amount_gbp,
    COALESCE(NULLIF(lc.ap_vat_rate_summary, ''), '—')::text AS ap_vat_rate_summary,
    CASE
      WHEN r.document_lane <> 'supplier_goods_ap' THEN 'not_applicable'
      WHEN COALESCE(lc.line_count, 0) = 0 THEN 'missing_resolved_lines'
      WHEN COALESCE(lc.lines_with_net_vat_gross, 0) <> COALESCE(lc.line_count, 0) THEN 'missing_net_vat_gross_fields'
      WHEN COALESCE(lc.lines_balanced, 0) <> COALESCE(lc.line_count, 0) THEN 'net_plus_vat_not_equal_gross'
      WHEN abs(COALESCE(lc.ap_gross_amount_gbp, 0) - COALESCE(r.amount_gbp, 0)) > 0.01 THEN 'gross_total_mismatch'
      ELSE 'ok'
    END::text AS ap_vat_control_status,
    COALESCE(
      NULLIF(r.request_payload_json #>> '{source_evidence,file_url}', ''),
      NULLIF(r.request_payload_json #>> '{evidence,credit_note_file_url}', ''),
      NULLIF(r.request_payload_json #>> '{evidence,refund_proof_file_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,evidence,credit_note_file_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,evidence,refund_proof_file_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,credit_note_file_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,refund_proof_file_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,supplier_invoice_pdf_url}', ''),
      NULLIF(r.request_payload_json #>> '{source_payload,invoice_pdf_url}', ''),
      NULLIF(se.supplier_invoice_file_url, ''),
      NULLIF(re.refund_source_file_url, '')
    )::text AS source_invoice_file_url,
    CASE
      WHEN r.document_lane NOT IN ('supplier_goods_ap', 'shipper_ap', 'supplier_credit_note') THEN 'not_applicable'
      WHEN COALESCE(
        NULLIF(r.request_payload_json #>> '{source_evidence,file_url}', ''),
        NULLIF(r.request_payload_json #>> '{evidence,credit_note_file_url}', ''),
        NULLIF(r.request_payload_json #>> '{evidence,refund_proof_file_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,evidence,credit_note_file_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,evidence,refund_proof_file_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,credit_note_file_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,refund_proof_file_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,supplier_invoice_pdf_url}', ''),
        NULLIF(r.request_payload_json #>> '{source_payload,invoice_pdf_url}', ''),
        NULLIF(se.supplier_invoice_file_url, ''),
        NULLIF(re.refund_source_file_url, '')
      ) IS NULL THEN 'missing_source_evidence_file'
      ELSE 'source_evidence_available'
    END::text AS source_evidence_status,
    r.created_at AS row_created_at
  FROM batch b
  CROSS JOIN summary s
  LEFT JOIN rows r ON true
  LEFT JOIN line_calc lc ON lc.row_id = r.id
  LEFT JOIN supplier_evidence se ON se.row_id = r.id
  LEFT JOIN refund_evidence re ON re.row_id = r.id
  ORDER BY
    CASE r.posting_status
      WHEN 'included' THEN 0
      WHEN 'validated' THEN 1
      WHEN 'posting' THEN 2
      WHEN 'failed_retryable' THEN 3
      WHEN 'failed_terminal' THEN 4
      WHEN 'excluded' THEN 5
      WHEN 'posted' THEN 6
      ELSE 9
    END,
    r.document_lane NULLS LAST,
    r.order_ref NULLS LAST,
    r.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_sage_posting_batch_detail_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
