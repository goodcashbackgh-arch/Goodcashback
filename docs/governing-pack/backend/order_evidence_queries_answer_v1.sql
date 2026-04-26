-- =============================================================================
-- order_evidence_queries_answer_v1.sql
-- Multi Tenant Platform Build — Day 3 importer/operator answer action
--
-- Purpose:
--   Add a controlled operator-facing RPC to answer open order evidence queries.
--
-- Install after:
--   1. order_evidence_queries_v1.sql
--
-- Scope:
--   - Create operator_answer_order_evidence_query(...) SECURITY DEFINER wrapper.
--   - Update order_evidence_queries from open -> answered.
--   - Validate operator is authorised for the query order's importer.
--   - No order status changes.
--   - No dispute creation.
--   - No staff close/cancel flow in this file.
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

  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_evidence_queries'
      AND column_name IN ('id','order_id','status','answered_by_operator_id','answered_at','answer_text')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 6
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: expected order_evidence_queries answer columns';
  END IF;
END $$;

-- =============================================================================
-- 1. OPERATOR ANSWER RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION public.operator_answer_order_evidence_query(
  p_order_evidence_query_id uuid,
  p_answer_text text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator record;
  v_query record;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: answering evidence query requires auth.uid()';
  END IF;

  SELECT op.id, op.email, op.full_name
    INTO v_operator
  FROM operators op
  WHERE op.auth_user_id = v_auth_uid
    AND COALESCE(op.active, true) = true
  LIMIT 1;

  IF v_operator.id IS NULL THEN
    RAISE EXCEPTION 'Active operator not found for auth user %', v_auth_uid;
  END IF;

  IF p_answer_text IS NULL OR length(btrim(p_answer_text)) = 0 THEN
    RAISE EXCEPTION 'Evidence query answer must not be blank';
  END IF;

  SELECT
    q.id,
    q.order_id,
    q.query_type,
    q.status,
    o.order_ref,
    o.importer_id
  INTO v_query
  FROM order_evidence_queries q
  JOIN orders o
    ON o.id = q.order_id
  WHERE q.id = p_order_evidence_query_id
  FOR UPDATE OF q;

  IF v_query.id IS NULL THEN
    RAISE EXCEPTION 'Evidence query not found: %', p_order_evidence_query_id;
  END IF;

  IF v_query.status <> 'open' THEN
    RAISE EXCEPTION 'Evidence query % is %, expected open', p_order_evidence_query_id, v_query.status;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM operator_importers oi
    WHERE oi.operator_id = v_operator.id
      AND oi.importer_id = v_query.importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % is not authorised for importer %', v_operator.id, v_query.importer_id;
  END IF;

  UPDATE order_evidence_queries
  SET status = 'answered',
      answered_by_operator_id = v_operator.id,
      answered_at = now(),
      answer_text = btrim(p_answer_text)
  WHERE id = p_order_evidence_query_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_evidence_query_id', p_order_evidence_query_id,
    'order_id', v_query.order_id,
    'order_ref', v_query.order_ref,
    'query_type', v_query.query_type,
    'status', 'answered',
    'answered_by_operator_id', v_operator.id,
    'answered_at', now()
  );
END;
$$;

COMMENT ON FUNCTION public.operator_answer_order_evidence_query(uuid, text) IS
'Operator-facing SECURITY DEFINER wrapper to answer an open order evidence query. Requires operator access to the order importer. Does not change order status or create disputes.';

REVOKE ALL ON FUNCTION public.operator_answer_order_evidence_query(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_answer_order_evidence_query(uuid, text) TO authenticated;

-- =============================================================================
-- 2. OPERATOR RLS READ POLICY
-- =============================================================================

DROP POLICY IF EXISTS order_evidence_queries_operator_read ON public.order_evidence_queries;
CREATE POLICY order_evidence_queries_operator_read
ON public.order_evidence_queries
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM operators op
    JOIN operator_importers oi
      ON oi.operator_id = op.id
     AND oi.revoked_at IS NULL
    JOIN orders o
      ON o.importer_id = oi.importer_id
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
      AND o.id = order_evidence_queries.order_id
  )
);

COMMIT;
