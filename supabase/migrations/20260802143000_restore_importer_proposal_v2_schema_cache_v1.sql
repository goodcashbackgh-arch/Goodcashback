BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regprocedure('public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Importer proposal v1 authority is missing.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.operator_submit_physical_receipt_proposal_v2(
  p_physical_receipt_review_id uuid,
  p_proposals jsonb,
  p_proposal_note text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: importer proposal requires auth.uid()';
  END IF;

  IF p_physical_receipt_review_id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review identity is required.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_proposal_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Importer factual proposal note is required.';
  END IF;

  IF jsonb_typeof(COALESCE(p_proposals, 'null'::jsonb)) <> 'array'
     OR jsonb_array_length(p_proposals) = 0 THEN
    RAISE EXCEPTION 'A non-empty importer proposal array is required.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_proposals) proposal_row
    WHERE jsonb_typeof(proposal_row) <> 'object'
       OR EXISTS (
         SELECT 1
         FROM jsonb_object_keys(proposal_row) key_name
         WHERE key_name NOT IN ('receipt_line_disposition_id','proposed_remedy_type','proposed_remedy_qty')
       )
  ) THEN
    RAISE EXCEPTION 'Importer proposal rows contain unknown fields.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(p_proposals) AS proposal_row(
      receipt_line_disposition_id uuid,
      proposed_remedy_type text,
      proposed_remedy_qty numeric
    )
    WHERE proposal_row.receipt_line_disposition_id IS NULL
       OR proposal_row.proposed_remedy_type IS NULL
       OR proposal_row.proposed_remedy_type NOT IN ('refund','replacement','hold_investigate','no_action')
       OR proposal_row.proposed_remedy_qty IS NULL
       OR proposal_row.proposed_remedy_qty <= 0
       OR proposal_row.proposed_remedy_qty <> TRUNC(proposal_row.proposed_remedy_qty)
  ) THEN
    RAISE EXCEPTION 'Every importer proposal row requires a valid remedy type and a positive whole-unit quantity.';
  END IF;

  SELECT public.operator_submit_physical_receipt_proposal_v1(
    p_physical_receipt_review_id,
    p_proposals,
    p_proposal_note
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)
  FROM PUBLIC, anon, authenticated;

DO $postflight$
DECLARE
  v_args text;
BEGIN
  SELECT pg_get_function_identity_arguments(p.oid)
    INTO v_args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'operator_submit_physical_receipt_proposal_v2';

  IF v_args IS DISTINCT FROM 'p_physical_receipt_review_id uuid, p_proposals jsonb, p_proposal_note text' THEN
    RAISE EXCEPTION 'Importer proposal v2 RPC signature is not the exact PostgREST contract: %', v_args;
  END IF;

  IF has_function_privilege('anon', 'public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Anon unexpectedly retains importer proposal v2 execute.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Authenticated role cannot execute importer proposal v2.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
