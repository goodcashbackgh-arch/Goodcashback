BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Keep the exact preserved OCR save implementation authoritative, replacing
-- only the former negative-row-only additive insert with the permanent private
-- financial-row materialiser installed immediately before this migration.

DO $guard$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure('public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Permanent OCR financial-row materialiser is missing.';
  END IF;

  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Preserved pre-signed Mindee save implementation is missing.';
  END IF;

  IF to_regprocedure('public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'Current canonical Mindee save function is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_save_mindee_invoice_ocr_result(uuid,character varying,integer,character varying,character varying,jsonb,character varying,character varying,date,numeric,integer,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;

  IF position('staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Current Mindee save is not the audited signed wrapper; refusing to replace a later definition.';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.staff_save_mindee_invoice_ocr_result(
  p_supplier_invoice_id uuid,
  p_model_id varchar,
  p_http_status integer,
  p_mindee_job_id varchar,
  p_mindee_inference_id varchar,
  p_raw_json jsonb,
  p_ocr_invoice_ref varchar,
  p_ocr_retailer_name varchar,
  p_ocr_invoice_date date,
  p_ocr_invoice_total_gbp numeric,
  p_pages_consumed integer,
  p_lines jsonb,
  p_flags jsonb DEFAULT '[]'::jsonb
)
RETURNS TABLE (
  supplier_invoice_id uuid,
  order_id uuid,
  inserted_line_count integer,
  inserted_flag_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_base record;
  v_financial_count integer := 0;
BEGIN
  -- This call preserves all existing authentication, invoice-state,
  -- idempotency, audit, gross-up, human-work and review-flag controls.
  SELECT *
  INTO v_base
  FROM public.staff_save_mindee_invoice_ocr_result_pre_signed_nonphysical_v1(
    p_supplier_invoice_id,
    p_model_id,
    p_http_status,
    p_mindee_job_id,
    p_mindee_inference_id,
    p_raw_json,
    p_ocr_invoice_ref,
    p_ocr_retailer_name,
    p_ocr_invoice_date,
    p_ocr_invoice_total_gbp,
    p_pages_consumed,
    p_lines,
    p_flags
  );

  -- Exact financial rows already inserted by the preserved route are no-ops.
  -- Omitted source-negative and recognised positive delivery rows are added once.
  v_financial_count :=
    public.internal_materialise_supplier_invoice_ocr_financial_rows_v1(
      p_supplier_invoice_id,
      p_lines
    );

  RETURN QUERY
  SELECT
    v_base.supplier_invoice_id::uuid,
    v_base.order_id::uuid,
    (COALESCE(v_base.inserted_line_count, 0) + COALESCE(v_financial_count, 0))::integer,
    COALESCE(v_base.inserted_flag_count, 0)::integer;
END;
$func$;

REVOKE ALL ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) FROM anon;
GRANT EXECUTE ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) TO authenticated;

COMMENT ON FUNCTION public.staff_save_mindee_invoice_ocr_result(
  uuid, varchar, integer, varchar, varchar, jsonb, varchar, varchar,
  date, numeric, integer, jsonb, jsonb
) IS
'Canonical Mindee supplier-invoice OCR save. It preserves the deployed save controls and routes omitted source-negative or recognised positive delivery rows through the private invoice-locked financial-row materialiser.';

NOTIFY pgrst, 'reload schema';

COMMIT;