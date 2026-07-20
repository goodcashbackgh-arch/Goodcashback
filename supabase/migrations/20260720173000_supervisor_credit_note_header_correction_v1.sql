BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_correct_refund_credit_note_header_v1(
  p_refund_evidence_submission_id uuid,
  p_credit_note_ref text,
  p_credit_note_date date,
  p_expected_credit_note_total_gbp numeric,
  p_ocr_credit_note_ref text,
  p_ocr_retailer_name text,
  p_ocr_credit_note_date date,
  p_ocr_credit_note_total_gbp numeric,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_submission public.dispute_refund