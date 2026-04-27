-- =============================================================================
-- order_evidence_queries_close_v1.sql
-- Multi Tenant Platform Build — Day 3 staff close/cancel evidence query actions
--
-- Purpose:
--   Add controlled staff RPCs to close or cancel order evidence queries.
--
-- Install after:
--   1. order_evidence_queries_v1.sql
--   2. order_evidence_queries_answer_v1.sql
--
-- Scope:
--   - staff_close_order_evidence_query(...)
--   - staff_cancel_order_evidence_query(...)
--   - No order status changes.
--   - No dispute creation.
--   - No importer-facing changes.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PREREQUISITE ASSERTIONS
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.order_evidence_queries') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_evidence_queries. Run order_evidence_queries_v1.sql first';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_evidence_queries'
      AND column_name IN ('id','order_id','status','closed_by_staff_id','closed_at','cancelled_by_staff_id','cancelled_at','resolution_notes')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 8
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: expected order_evidence_queries close/cancel columns';
  END IF;
END $$;

-- =============================================================================
-- 1. STAFF CLOSE RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION public.staff_close_order_evidence_query(
  p_order_evidence_query_id uuid,
  p_resolution_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_query record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: closing evidence query requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can close evidence queries. Current role: %', v_staff.role_type;
  END IF;

  SELECT q.id, q.order_id, q.query_type, q.status, o.order_ref
    INTO v_query
  FROM order_evidence_queries q
  JOIN orders o ON o.id = q.order_id
  WHERE q.id = p_order_evidence_query_id
  FOR UPDATE OF q;

  IF v_query.id IS NULL THEN
    RAISE EXCEPTION 'Evidence query not found: %', p_order_evidence_query_id;
  END IF;

  IF v_query.status NOT IN ('open', 'answered') THEN
    RAISE EXCEPTION 'Evidence query % is %, expected open or answered', p_order_evidence_query_id, v_query.status;
  END IF;

  UPDATE order_evidence_queries
  SET status = 'closed',
      closed_by_staff_id = v_staff.id,
      closed_at = now(),
      resolution_notes = NULLIF(btrim(COALESCE(p_resolution_notes, '')), '')
  WHERE id = p_order_evidence_query_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_evidence_query_id', p_order_evidence_query_id,
    'order_id', v_query.order_id,
    'order_ref', v_query.order_ref,
    'query_type', v_query.query_type,
    'status', 'closed',
    'closed_by_staff_id', v_staff.id,
    'closed_at', now()
  );
END;
$$;

COMMENT ON FUNCTION public.staff_close_order_evidence_query(uuid, text) IS
'Staff-only SECURITY DEFINER wrapper to close an open or answered order evidence query. Does not change order status or create disputes.';

REVOKE ALL ON FUNCTION public.staff_close_order_evidence_query(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_close_order_evidence_query(uuid, text) TO authenticated;

-- =============================================================================
-- 2. STAFF CANCEL RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION public.staff_cancel_order_evidence_query(
  p_order_evidence_query_id uuid,
  p_resolution_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_query record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: cancelling evidence query requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can cancel evidence queries. Current role: %', v_staff.role_type;
  END IF;

  SELECT q.id, q.order_id, q.query_type, q.status, o.order_ref
    INTO v_query
  FROM order_evidence_queries q
  JOIN orders o ON o.id = q.order_id
  WHERE q.id = p_order_evidence_query_id
  FOR UPDATE OF q;

  IF v_query.id IS NULL THEN
    RAISE EXCEPTION 'Evidence query not found: %', p_order_evidence_query_id;
  END IF;

  IF v_query.status NOT IN ('open', 'answered') THEN
    RAISE EXCEPTION 'Evidence query % is %, expected open or answered', p_order_evidence_query_id, v_query.status;
  END IF;

  UPDATE order_evidence_queries
  SET status = 'cancelled',
      cancelled_by_staff_id = v_staff.id,
      cancelled_at = now(),
      resolution_notes = NULLIF(btrim(COALESCE(p_resolution_notes, '')), '')
  WHERE id = p_order_evidence_query_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_evidence_query_id', p_order_evidence_query_id,
    'order_id', v_query.order_id,
    'order_ref', v_query.order_ref,
    'query_type', v_query.query_type,
    'status', 'cancelled',
    'cancelled_by_staff_id', v_staff.id,
    'cancelled_at', now()
  );
END;
$$;

COMMENT ON FUNCTION public.staff_cancel_order_evidence_query(uuid, text) IS
'Staff-only SECURITY DEFINER wrapper to cancel an open or answered order evidence query. Does not change order status or create disputes.';

REVOKE ALL ON FUNCTION public.staff_cancel_order_evidence_query(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_cancel_order_evidence_query(uuid, text) TO authenticated;

COMMIT;
