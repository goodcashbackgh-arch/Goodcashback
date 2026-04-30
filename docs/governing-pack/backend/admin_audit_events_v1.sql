-- =============================================================================
-- admin_audit_events_v1.sql
-- Multi Tenant Platform Build — lightweight admin oversight queue
--
-- Purpose:
--   Log risky supervisor/staff decisions without blocking normal MVP flow.
--   Admin can review patterns and high-risk events after the fact.
--
-- Principle:
--   Supervisor decisions keep the process moving.
--   Money-impacting or unusual decisions become admin-visible.
--   Only explicit hard-block cases should stop Sage/final invoice flow.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.admin_audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type varchar NOT NULL CHECK (entity_type IN (
    'supplier_invoice',
    'supplier_invoice_line',
    'order_value_adjustment',
    'final_invoice_draft',
    'shipping_quote',
    'refund_return',
    'other'
  )),
  entity_id uuid NOT NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  importer_id uuid REFERENCES public.importers(id) ON DELETE SET NULL,
  event_type varchar NOT NULL,
  risk_level varchar NOT NULL DEFAULT 'medium' CHECK (risk_level IN ('low','medium','high','hard_block')),
  hard_block_yn boolean NOT NULL DEFAULT false,
  before_value text,
  after_value text,
  reason text,
  created_by_staff_id uuid REFERENCES public.staff(id),
  created_by_operator_id uuid REFERENCES public.operators(id),
  review_status varchar NOT NULL DEFAULT 'open' CHECK (review_status IN ('open','reviewed','escalated','closed')),
  reviewed_by_admin_id uuid REFERENCES public.staff(id),
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_audit_events_hard_block_risk_check CHECK (
    hard_block_yn = false OR risk_level = 'hard_block'
  )
);

COMMENT ON TABLE public.admin_audit_events IS
'Admin oversight log for risky supervisor/operator decisions. Most events do not block operational flow; hard_block_yn=true blocks downstream finalisation/Sage until resolved by separate business logic.';

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_entity
  ON public.admin_audit_events(entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_order
  ON public.admin_audit_events(order_id)
  WHERE order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_importer
  ON public.admin_audit_events(importer_id)
  WHERE importer_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_review_status
  ON public.admin_audit_events(review_status, risk_level, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_hard_block
  ON public.admin_audit_events(hard_block_yn)
  WHERE hard_block_yn = true;

ALTER TABLE public.admin_audit_events ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'admin_audit_events'
      AND policyname = 'admin_audit_events_admin_all'
  ) THEN
    CREATE POLICY admin_audit_events_admin_all
    ON public.admin_audit_events
    FOR ALL
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.staff s
        WHERE s.auth_user_id = auth.uid()
          AND s.active = true
          AND s.role_type = 'admin'
      )
    )
    WITH CHECK (
      EXISTS (
        SELECT 1
        FROM public.staff s
        WHERE s.auth_user_id = auth.uid()
          AND s.active = true
          AND s.role_type = 'admin'
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'admin_audit_events'
      AND policyname = 'admin_audit_events_staff_insert'
  ) THEN
    CREATE POLICY admin_audit_events_staff_insert
    ON public.admin_audit_events
    FOR INSERT
    TO authenticated
    WITH CHECK (
      EXISTS (
        SELECT 1
        FROM public.staff s
        WHERE s.auth_user_id = auth.uid()
          AND s.active = true
          AND s.role_type IN ('admin','supervisor')
          AND (admin_audit_events.created_by_staff_id IS NULL OR admin_audit_events.created_by_staff_id = s.id)
      )
    );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.log_admin_audit_event(
  p_entity_type text,
  p_entity_id uuid,
  p_order_id uuid DEFAULT NULL,
  p_importer_id uuid DEFAULT NULL,
  p_event_type text DEFAULT 'review_event',
  p_risk_level text DEFAULT 'medium',
  p_hard_block_yn boolean DEFAULT false,
  p_before_value text DEFAULT NULL,
  p_after_value text DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff_id uuid;
  v_event_id uuid;
BEGIN
  SELECT s.id
    INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active admin or supervisor staff user required.';
  END IF;

  INSERT INTO public.admin_audit_events (
    entity_type,
    entity_id,
    order_id,
    importer_id,
    event_type,
    risk_level,
    hard_block_yn,
    before_value,
    after_value,
    reason,
    created_by_staff_id
  ) VALUES (
    p_entity_type,
    p_entity_id,
    p_order_id,
    p_importer_id,
    p_event_type,
    p_risk_level,
    p_hard_block_yn,
    p_before_value,
    p_after_value,
    p_reason,
    v_staff_id
  )
  RETURNING id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.log_admin_audit_event(text, uuid, uuid, uuid, text, text, boolean, text, text, text) TO authenticated;

COMMIT;
