-- =============================================================================
-- operator_update_dispute_retailer_update_v1.sql
-- Multi Tenant Platform Build — operator retailer update atomic wrapper
--
-- Purpose:
--   Add an operator-only SECURITY DEFINER RPC to atomically persist retailer
--   conversation outcome plus optional pasted retailer response.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
  END IF;

  IF to_regclass('public.dispute_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_lines';
  END IF;

  IF to_regclass('public.dispute_messages') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_messages';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_update_dispute_retailer_update(
  p_dispute_id uuid,
  p_retailer_response text,
  p_retailer_outcome text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_importer_id uuid;
  v_status text;
  v_response text := btrim(coalesce(p_retailer_response, ''));
  v_message_id uuid;
  v_updated_lines integer := 0;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: retailer update requires auth.uid()';
  END IF;

  SELECT o.id
    INTO v_operator_id
  FROM public.operators o
  WHERE o.auth_user_id = v_auth_uid
    AND o.active = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found for auth user %', v_auth_uid;
  END IF;

  IF p_retailer_outcome NOT IN ('still_waiting', 'retailer_accepted', 'retailer_disputed', 'more_info_requested') THEN
    RAISE EXCEPTION 'Invalid retailer outcome: %', p_retailer_outcome;
  END IF;

  IF p_retailer_outcome IN ('retailer_accepted', 'retailer_disputed') AND v_response = '' THEN
    RAISE EXCEPTION 'Retailer response is required when outcome is %', p_retailer_outcome;
  END IF;

  SELECT ord.importer_id
    INTO v_importer_id
  FROM public.disputes d
  JOIN public.orders ord ON ord.id = d.order_id
  WHERE d.id = p_dispute_id
  LIMIT 1;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Dispute % not found or parent order importer missing', p_dispute_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % is not linked to dispute importer %', v_operator_id, v_importer_id;
  END IF;

  v_status := CASE p_retailer_outcome
    WHEN 'still_waiting' THEN 'retailer_contacted'
    WHEN 'retailer_accepted' THEN 'retailer_response_received'
    WHEN 'retailer_disputed' THEN 'awaiting_retailer_resolution'
    WHEN 'more_info_requested' THEN 'retailer_draft_ready'
  END;

  IF v_response <> '' THEN
    INSERT INTO public.dispute_messages (
      dispute_id,
      message_type,
      counterparty,
      generated_by,
      body
    )
    VALUES (
      p_dispute_id,
      'retailer_reply',
      'retailer',
      'retailer_paste',
      v_response
    )
    RETURNING id INTO v_message_id;
  END IF;

  UPDATE public.dispute_lines
  SET conversation_status = v_status
  WHERE dispute_id = p_dispute_id
    AND resolved_at IS NULL;

  GET DIAGNOSTICS v_updated_lines = ROW_COUNT;

  IF v_updated_lines = 0 THEN
    RAISE EXCEPTION 'No unresolved dispute lines found for dispute %', p_dispute_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dispute_id', p_dispute_id,
    'retailer_outcome', p_retailer_outcome,
    'conversation_status', v_status,
    'retailer_response_saved', (v_response <> ''),
    'dispute_message_id', v_message_id,
    'updated_lines', v_updated_lines
  );
END;
$$;

COMMENT ON FUNCTION public.operator_update_dispute_retailer_update(uuid, text, text) IS
'Operator-only SECURITY DEFINER wrapper to atomically save retailer response logs and dispute line retailer outcome updates.';

REVOKE ALL ON FUNCTION public.operator_update_dispute_retailer_update(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_update_dispute_retailer_update(uuid, text, text) TO authenticated;

COMMIT;
