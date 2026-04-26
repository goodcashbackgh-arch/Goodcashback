-- =============================================================================
-- order_evidence_queries_v1.sql
-- Multi Tenant Platform Build — Day 3 Evidence Query Importer action
--
-- Purpose:
--   Add a controlled staff-created evidence clarification trail for asking an
--   importer/operator for missing or unclear evidence.
--
-- Governing contract:
--   docs/governing-pack/ui/EVIDENCE_QUERY_IMPORTER_ACTION_CONTRACT.md
--
-- Scope:
--   - Create order_evidence_queries table if missing.
--   - Create staff_create_order_evidence_query(...) SECURITY DEFINER wrapper.
--   - No order status changes.
--   - No dispute creation.
--   - No importer-facing answer function in v1.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PREREQUISITE ASSERTIONS
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.order_tracking_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_submissions';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'staff'
      AND column_name IN ('id', 'auth_user_id', 'role_type', 'active')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 4
  ) THEN
    RAISE EXCEPTION 'Prerequisite missing: expected staff identity columns';
  END IF;
END $$;

-- =============================================================================
-- 1. TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.order_evidence_queries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  query_type text NOT NULL CHECK (query_type IN (
    'missing_invoice',
    'missing_tracking',
    'ocr_unclear',
    'invoice_total_mismatch',
    'line_clarification',
    'general_evidence_question'
  )),
  message text NOT NULL CHECK (length(btrim(message)) > 0),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','closed','cancelled')),
  supplier_invoice_id uuid REFERENCES public.supplier_invoices(id),
  supplier_invoice_line_id uuid REFERENCES public.supplier_invoice_lines(id),
  order_tracking_submission_id uuid REFERENCES public.order_tracking_submissions(id),
  related_dispute_id uuid REFERENCES public.disputes(id),
  priority text NOT NULL DEFAULT 'normal' CHECK (priority IN ('low','normal','high')),
  due_at timestamptz,
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  answered_by_operator_id uuid REFERENCES public.operators(id),
  answered_at timestamptz,
  answer_text text,
  closed_by_staff_id uuid REFERENCES public.staff(id),
  closed_at timestamptz,
  cancelled_by_staff_id uuid REFERENCES public.staff(id),
  cancelled_at timestamptz,
  resolution_notes text,
  CONSTRAINT order_evidence_queries_answer_status_check CHECK (
    (status <> 'answered') OR (answered_by_operator_id IS NOT NULL AND answered_at IS NOT NULL AND answer_text IS NOT NULL)
  ),
  CONSTRAINT order_evidence_queries_closed_status_check CHECK (
    (status <> 'closed') OR (closed_by_staff_id IS NOT NULL AND closed_at IS NOT NULL)
  ),
  CONSTRAINT order_evidence_queries_cancelled_status_check CHECK (
    (status <> 'cancelled') OR (cancelled_by_staff_id IS NOT NULL AND cancelled_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_order_evidence_queries_order_status
  ON public.order_evidence_queries(order_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_order_evidence_queries_created_by_staff
  ON public.order_evidence_queries(created_by_staff_id, created_at DESC);

COMMENT ON TABLE public.order_evidence_queries IS
'Controlled Day 3 evidence clarification trail. Staff asks importer/operator for missing or unclear evidence without creating disputes or changing order status.';

COMMENT ON COLUMN public.order_evidence_queries.query_type IS
'Allowed evidence query type: missing_invoice, missing_tracking, ocr_unclear, invoice_total_mismatch, line_clarification, general_evidence_question.';

-- =============================================================================
-- 2. STAFF CREATE RPC
-- =============================================================================

CREATE OR REPLACE FUNCTION public.staff_create_order_evidence_query(
  p_order_id uuid,
  p_query_type text,
  p_message text,
  p_supplier_invoice_id uuid DEFAULT NULL,
  p_supplier_invoice_line_id uuid DEFAULT NULL,
  p_order_tracking_submission_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_order record;
  v_invoice_order_id uuid;
  v_line_order_id uuid;
  v_tracking_order_id uuid;
  v_query_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff evidence query creation requires auth.uid()';
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
    RAISE EXCEPTION 'Only admin or supervisor staff can create evidence queries. Current role: %', v_staff.role_type;
  END IF;

  SELECT o.id, o.order_ref, o.status
    INTO v_order
  FROM orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order not found: %', p_order_id;
  END IF;

  IF v_order.status IN ('archived', 'cancelled') THEN
    RAISE EXCEPTION 'Cannot create evidence query for order % with status %', p_order_id, v_order.status;
  END IF;

  IF p_query_type NOT IN (
    'missing_invoice',
    'missing_tracking',
    'ocr_unclear',
    'invoice_total_mismatch',
    'line_clarification',
    'general_evidence_question'
  ) THEN
    RAISE EXCEPTION 'Invalid evidence query type: %', p_query_type;
  END IF;

  IF p_message IS NULL OR length(btrim(p_message)) = 0 THEN
    RAISE EXCEPTION 'Evidence query message must not be blank';
  END IF;

  IF p_supplier_invoice_id IS NOT NULL THEN
    SELECT si.order_id
      INTO v_invoice_order_id
    FROM supplier_invoices si
    WHERE si.id = p_supplier_invoice_id;

    IF v_invoice_order_id IS NULL THEN
      RAISE EXCEPTION 'Supplier invoice not found: %', p_supplier_invoice_id;
    END IF;

    IF v_invoice_order_id IS DISTINCT FROM p_order_id THEN
      RAISE EXCEPTION 'Supplier invoice % does not belong to order %', p_supplier_invoice_id, p_order_id;
    END IF;
  END IF;

  IF p_supplier_invoice_line_id IS NOT NULL THEN
    SELECT si.order_id
      INTO v_line_order_id
    FROM supplier_invoice_lines sil
    JOIN supplier_invoices si
      ON si.id = sil.supplier_invoice_id
    WHERE sil.id = p_supplier_invoice_line_id;

    IF v_line_order_id IS NULL THEN
      RAISE EXCEPTION 'Supplier invoice line not found: %', p_supplier_invoice_line_id;
    END IF;

    IF v_line_order_id IS DISTINCT FROM p_order_id THEN
      RAISE EXCEPTION 'Supplier invoice line % does not belong to order %', p_supplier_invoice_line_id, p_order_id;
    END IF;
  END IF;

  IF p_order_tracking_submission_id IS NOT NULL THEN
    SELECT ots.order_id
      INTO v_tracking_order_id
    FROM order_tracking_submissions ots
    WHERE ots.id = p_order_tracking_submission_id;

    IF v_tracking_order_id IS NULL THEN
      RAISE EXCEPTION 'Order tracking submission not found: %', p_order_tracking_submission_id;
    END IF;

    IF v_tracking_order_id IS DISTINCT FROM p_order_id THEN
      RAISE EXCEPTION 'Tracking submission % does not belong to order %', p_order_tracking_submission_id, p_order_id;
    END IF;
  END IF;

  INSERT INTO order_evidence_queries (
    order_id,
    query_type,
    message,
    status,
    supplier_invoice_id,
    supplier_invoice_line_id,
    order_tracking_submission_id,
    created_by_staff_id
  )
  VALUES (
    p_order_id,
    p_query_type,
    btrim(p_message),
    'open',
    p_supplier_invoice_id,
    p_supplier_invoice_line_id,
    p_order_tracking_submission_id,
    v_staff.id
  )
  RETURNING id INTO v_query_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_evidence_query_id', v_query_id,
    'order_id', p_order_id,
    'order_ref', v_order.order_ref,
    'query_type', p_query_type,
    'status', 'open',
    'created_by_staff_id', v_staff.id,
    'created_at', now()
  );
END;
$$;

COMMENT ON FUNCTION public.staff_create_order_evidence_query(uuid, text, text, uuid, uuid, uuid) IS
'Staff-only SECURITY DEFINER wrapper to create an open evidence clarification query for an order. Does not change order status or create disputes.';

REVOKE ALL ON FUNCTION public.staff_create_order_evidence_query(uuid, text, text, uuid, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_create_order_evidence_query(uuid, text, text, uuid, uuid, uuid) TO authenticated;

-- =============================================================================
-- 3. RLS
-- =============================================================================

ALTER TABLE public.order_evidence_queries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_evidence_queries_staff_read ON public.order_evidence_queries;
CREATE POLICY order_evidence_queries_staff_read
ON public.order_evidence_queries
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM staff s
    WHERE s.auth_user_id = auth.uid()
      AND COALESCE(s.active, true) = true
      AND s.role_type IN ('admin', 'supervisor')
  )
);

DROP POLICY IF EXISTS order_evidence_queries_staff_insert_block_direct ON public.order_evidence_queries;
CREATE POLICY order_evidence_queries_staff_insert_block_direct
ON public.order_evidence_queries
FOR INSERT
TO authenticated
WITH CHECK (false);

DROP POLICY IF EXISTS order_evidence_queries_staff_update_block_direct ON public.order_evidence_queries;
CREATE POLICY order_evidence_queries_staff_update_block_direct
ON public.order_evidence_queries
FOR UPDATE
TO authenticated
USING (false)
WITH CHECK (false);

COMMIT;
