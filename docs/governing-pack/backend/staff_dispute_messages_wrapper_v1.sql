-- =============================================================================
-- staff_dispute_messages_wrapper_v1.sql
-- Multi Tenant Platform Build — staff dispute message insert wrapper
--
-- Purpose:
--   Add a narrow staff-only SECURITY DEFINER wrapper so internal exception actions
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

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.staff_add_dispute_message(
  p_dispute_id uuid,
  p_message_type text,
  p_counterparty text,
  p_body text,
  p_generated_by text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff_id uuid;
  v_message_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: dispute message logging requires auth.uid()';
  END IF;

  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND s.active = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account not found for auth user %', v_auth_uid;
  END IF;

  INSERT INTO public.dispute_messages (
    dispute_id,
    message_type,
    counterparty,
    body,
    generated_by,
    human_editor_staff_id
  )
  VALUES (
    p_dispute_id,
    p_message_type,
    p_counterparty,
    p_body,
    p_generated_by,
    v_staff_id
  )
  RETURNING id INTO v_message_id;

  RETURN jsonb_build_object(
    'ok', true,
    'dispute_message_id', v_message_id,
    'dispute_id', p_dispute_id
  );
END;
$$;

COMMENT ON FUNCTION public.staff_add_dispute_message(uuid, text, text, text, text) IS
'Staff-only SECURITY DEFINER wrapper to append a dispute conversation message while dispute_messages RLS is enabled.';

REVOKE ALL ON FUNCTION public.staff_add_dispute_message(uuid, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_add_dispute_message(uuid, text, text, text, text) TO authenticated;

COMMIT;
