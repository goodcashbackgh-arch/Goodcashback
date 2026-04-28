-- =============================================================================
-- operator_dispute_messages_wrapper_v1.sql
-- Multi Tenant Platform Build — operator dispute message insert wrapper
--
-- Purpose:
--   Add an operator-only SECURITY DEFINER wrapper so importer exception workflow
--   can insert dispute conversation messages when dispute_messages RLS is enabled.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
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

CREATE OR REPLACE FUNCTION public.operator_add_dispute_message(
  p_dispute_id uuid,
  p_body text,
  p_message_type text,
  p_counterparty text,
  p_generated_by text
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
  v_message_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: dispute message logging requires auth.uid()';
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

  IF p_message_type NOT IN ('opening', 'retailer_reply', 'gc_draft', 'gc_sent', 'supervisor_note') THEN
    RAISE EXCEPTION 'Invalid dispute message_type: %', p_message_type;
  END IF;

  IF p_counterparty NOT IN ('retailer', 'shipper', 'internal') THEN
    RAISE EXCEPTION 'Invalid dispute counterparty: %', p_counterparty;
  END IF;

  IF p_generated_by NOT IN ('claude', 'manual', 'retailer_paste') THEN
    RAISE EXCEPTION 'Invalid dispute generated_by value: %', p_generated_by;
  END IF;

  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'Dispute message body cannot be blank';
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

  INSERT INTO public.dispute_messages (
    dispute_id,
    message_type,
    counterparty,
    body,
    generated_by
  )
  VALUES (
    p_dispute_id,
    p_message_type,
    p_counterparty,
    btrim(p_body),
    p_generated_by
  )
  RETURNING id INTO v_message_id;

  RETURN jsonb_build_object(
    'ok', true,
    'dispute_message_id', v_message_id,
    'dispute_id', p_dispute_id
  );
END;
$$;

COMMENT ON FUNCTION public.operator_add_dispute_message(uuid, text, text, text, text) IS
'Operator-only SECURITY DEFINER wrapper to append a dispute conversation message while dispute_messages RLS is enabled.';

REVOKE ALL ON FUNCTION public.operator_add_dispute_message(uuid, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_add_dispute_message(uuid, text, text, text, text) TO authenticated;

COMMIT;
