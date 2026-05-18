BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_sage_jsonb_num_v1(p_value jsonb)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text;
BEGIN
  IF p_value IS NULL OR p_value = 'null'::jsonb THEN
    RETURN NULL;
  END IF;
  IF jsonb_typeof(p_value) = 'number' THEN
    RETURN (p_value #>> '{}')::numeric;
  END IF;
  IF jsonb_typeof(p_value) = 'string' THEN
    v_text := trim(both from (p_value #>> '{}'));
    IF v_text ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
      RETURN v_text::numeric;
    END IF;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_validate_sage_posting_batch_payloads_v1(p_batch_id uuid)
RETURNS TABLE (
  row_id uuid,
  batch_id uuid,
  document_lane text,
  document_type text,
  order_ref text,
  idempotency_key text,
  posting_status text,
  payload_validation_status text,
  error_code text,
  error_message text,
  validation_summary jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_connection_count integer;
  v_business_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage payload validation requires auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for Sage payload validation.';
  END IF;

  SELECT public.internal_current_staff_id_v1() INTO v_staff_id;

  SELECT COUNT(DISTINCT c.id)::integer, COUNT(DISTINCT b.id)::integer
  INTO v_connection_count, v_business_count
  FROM public.sage_connections c
  JOIN public.sage_oauth_tokens t ON t.connection_id = c.id AND t.status = 'active'
  LEFT JOIN public.sage_businesses b ON b.connection_id = c.id AND b.status = 'active'
  WHERE c.status = 'connected';

  IF NOT EXISTS (SELECT 1 FROM public.sage_posting_batches b WHERE b.id = p_batch_id) THEN
    RAISE EXCEPTION 'Posting batch not found: %', p_batch_id;
  END IF;

  RETURN QUERY
  WITH target AS (
    SELECT r.*
    FROM public.sage_posting_batch_rows r
    WHERE r.batch_id = p_batch_id
  ), line_amounts AS (
    SELECT
      t.id AS row_id,
      COUNT(line.value)::integer AS line_count,
      COUNT(line.value) FILTER (WHERE COALESCE(
        public.internal_sage_jsonb_num_v1(line.value->'total_line_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'line_total_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price_gbp') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1)
      ) IS NOT NULL)::integer AS numeric_line_count,
      COALESCE(SUM(COALESCE(
        public.internal_sage_jsonb_num_v1(line.value->'total_line_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'line_total_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'gross_amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'amount_gbp'),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price_gbp') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1),
        public.internal_sage_jsonb_num_v1(line.value->'unit_price') * COALESCE(public.internal_sage_jsonb_num_v1(line.value->'quantity'), 1)
      )), 0)::numeric(18,2) AS line_total_gbp
    FROM target t
    LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(t.request_payload_json->'resolved_lines') = 'array' THEN t.request_payload_json->'resolved_lines' ELSE '[]'::jsonb END) AS line(value) ON true
    GROUP BY t.id
  ), assessed AS (
    SELECT
      t.*,
      COALESCE(l.line_count, 0) AS line_count,
      COALESCE(l.numeric_line_count, 0) AS numeric_line_count,
      COALESCE(l.line_total_gbp, 0)::numeric(18,2) AS line_total_gbp,
      array_remove(ARRAY[
        CASE WHEN t.posting_status = 'excluded' THEN 'excluded_before_validation' END,
        CASE WHEN v_connection_count = 0 THEN 'missing_active_sage_connection' END,
        CASE WHEN v_business_count = 0 THEN 'missing_selected_sage_business' END,
        CASE WHEN NULLIF(trim(COALESCE(t.idempotency_key, '')), '') IS NULL THEN 'missing_idempotency_key' END,
        CASE WHEN COALESCE(t.request_payload_json, '{}'::jsonb) = '{}'::jsonb THEN 'missing_request_payload' END,
        CASE WHEN NULLIF(trim(COALESCE(t.request_payload_json #>> '{sage_header,reference}', t.reference_text, '')), '') IS NULL THEN 'missing_sage_reference' END,
        CASE WHEN COALESCE(t.amount_gbp, 0) <= 0 THEN 'amount_must_be_positive' END,
        CASE WHEN COALESCE(NULLIF(t.currency_code, ''), 'GBP') <> 'GBP' THEN 'unsupported_currency' END,
        CASE WHEN COALESCE(l.line_count, 0) = 0 THEN 'missing_resolved_lines' END,
        CASE WHEN COALESCE(l.line_count, 0) > 0 AND COALESCE(l.numeric_line_count, 0) = 0 THEN 'line_amounts_missing' END,
        CASE WHEN COALESCE(l.numeric_line_count, 0) > 0 AND abs(COALESCE(l.line_total_gbp, 0) - COALESCE(t.amount_gbp, 0)) > 0.01 THEN 'line_total_does_not_match_header_amount' END,
        CASE WHEN t.document_lane = 'customer_sales' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{customer_target,display_name}', t.counterparty_name, '')), '') IS NULL THEN 'missing_customer_contact_target' END,
        CASE WHEN t.document_lane = 'customer_sales' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{tax_resolution,sage_tax_rate_id}', '')), '') IS NULL THEN 'missing_customer_sales_tax_mapping' END,
        CASE WHEN t.document_lane = 'customer_sales' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{ledger_resolution,sage_ledger_account_id}', '')), '') IS NULL THEN 'missing_customer_sales_ledger_mapping' END,
        CASE WHEN t.document_lane = 'shipper_ap' AND NULLIF(trim(COALESCE(t.counterparty_name, t.request_payload_json #>> '{counterparty_name}', '')), '') IS NULL THEN 'missing_shipper_ap_supplier_target' END,
        CASE WHEN t.document_lane = 'shipper_ap' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{resolved_lines,0,sage_ledger_account_id}', '')), '') IS NULL THEN 'missing_shipper_ap_ledger_mapping' END,
        CASE WHEN t.document_lane = 'shipper_ap' AND NULLIF(trim(COALESCE(t.request_payload_json #>> '{resolved_lines,0,sage_tax_rate_id}', '')), '') IS NULL THEN 'missing_shipper_ap_tax_mapping' END
      ]::text[], NULL) AS validation_errors
    FROM target t
    LEFT JOIN line_amounts l ON l.row_id = t.id
  ), updated AS (
    UPDATE public.sage_posting_batch_rows r
    SET payload_validation_status = CASE WHEN a.posting_status = 'excluded' THEN 'excluded_before_validation' WHEN array_length(a.validation_errors, 1) IS NULL THEN 'dry_run_validated' ELSE 'dry_run_failed' END,
        posting_status = CASE WHEN a.posting_status = 'included' AND array_length(a.validation_errors, 1) IS NULL THEN 'validated' ELSE a.posting_status END,
        error_code = CASE WHEN array_length(a.validation_errors, 1) IS NULL THEN NULL::text ELSE a.validation_errors[1] END,
        error_message = CASE WHEN array_length(a.validation_errors, 1) IS NULL THEN NULL::text ELSE array_to_string(a.validation_errors, '; ') END,
        response_payload_json = jsonb_build_object(
          'phase', 'phase_11_dry_run_payload_validation',
          'validated_at', now(),
          'sage_api_call_made', false,
          'sage_object_created', false,
          'active_sage_connection_count', v_connection_count,
          'active_sage_business_count', v_business_count,
          'line_count', a.line_count,
          'numeric_line_count', a.numeric_line_count,
          'line_total_gbp', a.line_total_gbp,
          'header_amount_gbp', a.amount_gbp,
          'validation_errors', COALESCE(to_jsonb(a.validation_errors), '[]'::jsonb)
        )
    FROM assessed a
    WHERE r.id = a.id
    RETURNING r.id, r.batch_id, r.document_lane, r.document_type, r.order_ref, r.idempotency_key, r.posting_status, r.payload_validation_status, r.error_code, r.error_message, r.response_payload_json
  ), batch_update AS (
    UPDATE public.sage_posting_batches b
    SET status = CASE
      WHEN NOT EXISTS (SELECT 1 FROM public.sage_posting_batch_rows r WHERE r.batch_id = p_batch_id AND r.posting_status <> 'excluded') THEN b.status
      WHEN NOT EXISTS (SELECT 1 FROM public.sage_posting_batch_rows r WHERE r.batch_id = p_batch_id AND r.posting_status <> 'excluded' AND r.payload_validation_status <> 'dry_run_validated') THEN 'validated'
      ELSE 'draft'
    END
    WHERE b.id = p_batch_id
    RETURNING b.id
  )
  SELECT u.id, u.batch_id, u.document_lane, u.document_type, u.order_ref, u.idempotency_key, u.posting_status, u.payload_validation_status, u.error_code, u.error_message, u.response_payload_json
  FROM updated u
  ORDER BY CASE u.payload_validation_status WHEN 'dry_run_failed' THEN 0 WHEN 'dry_run_validated' THEN 1 ELSE 2 END, u.document_lane, u.order_ref;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_validate_sage_posting_batch_payloads_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_validate_sage_posting_batch_payloads_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
