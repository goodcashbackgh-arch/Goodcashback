-- Fix staff_review_return_collection_tracking audit insert to use allowed dispute_messages values.
--
-- Scope:
--   - replaces only the existing staff review RPC body
--   - keeps the same review decisions: accepted / hold / rejected
--   - keeps the same return tracking table
--   - writes the audit message using allowed values: generated_by = manual
--   - does not touch refund document control, DVA/card, Sage, orders, or shipper flow

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_review_return_collection_tracking(
  p_return_tracking_submission_id uuid,
  p_review_decision text,
  p_review_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff_id uuid;
  v_dispute_id uuid;
  v_source_message_id uuid;
  v_message_id uuid;
  v_body text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff review requires auth.uid()';
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active supervisor/admin staff account not found.';
  END IF;

  IF p_review_decision NOT IN ('accepted','hold','rejected') THEN
    RAISE EXCEPTION 'Invalid return tracking review decision: %', p_review_decision;
  END IF;

  SELECT dispute_id, source_dispute_message_id
    INTO v_dispute_id, v_source_message_id
  FROM public.dispute_return_tracking_submissions
  WHERE id = p_return_tracking_submission_id
  LIMIT 1;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'Return tracking submission not found.';
  END IF;

  v_body := array_to_string(array[
    '[RETURN_COLLECTION_EVIDENCE_REVIEW_V1]',
    'reviewed_by_staff_id: ' || v_staff_id::text,
    'review_decision: ' || p_review_decision,
    'source_evidence_message_id: ' || coalesce(v_source_message_id::text, '—'),
    '',
    coalesce(nullif(btrim(coalesce(p_review_notes, '')), ''), 'No review notes.')
  ], E'\n');

  INSERT INTO public.dispute_messages (dispute_id, message_type, counterparty, generated_by, body)
  VALUES (v_dispute_id, 'return_collection_evidence_review', 'internal', 'manual', v_body)
  RETURNING id INTO v_message_id;

  UPDATE public.dispute_return_tracking_submissions
  SET review_status = p_review_decision,
      reviewed_by_staff_id = v_staff_id,
      reviewed_at = now(),
      review_notes = nullif(btrim(coalesce(p_review_notes, '')), '')
  WHERE id = p_return_tracking_submission_id;

  RETURN jsonb_build_object(
    'ok', true,
    'review_message_id', v_message_id,
    'return_tracking_submission_id', p_return_tracking_submission_id,
    'review_decision', p_review_decision
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_review_return_collection_tracking(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_review_return_collection_tracking(uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
