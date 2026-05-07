-- =============================================================================
-- 20260507_exception_refund_return_evidence_backend.sql
-- Goodcashback — structured refund/return evidence backend
--
-- Purpose
--   1) Stop treating return/collection tracking as an unstructured-only message.
--   2) Add structured backend tables for:
--      - refund exception return/collection tracking submissions
--      - refund/credit-note/no-document supplier-side evidence submissions
--   3) Preserve current UI compatibility by allowing the existing message-based
--      actions to save safely and mirroring those messages into structured tables.
--   4) Provide SECURITY DEFINER RPCs for the next app patch so the UI can move
--      off direct dispute_messages inserts without weakening RLS.
--
-- Governing alignment
--   - Exception Branching MVP Contract: parent order remains anchor; refund branch
--     requires supervisor final acceptance before downstream settlement.
--   - Existing order tracking pattern: order_tracking_submissions +
--     importer_add_order_tracking_submission SECURITY DEFINER RPC.
--   - Existing supplier draft ready path: refund/credit evidence feeds later Sage
--     readiness but does not post to Sage.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. Prerequisite checks
-- =============================================================================
DO $$
BEGIN
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
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
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
  IF to_regclass('public.couriers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.couriers';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;
  IF to_regclass('public.dispute_messages') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_messages';
  END IF;
END $$;

-- =============================================================================
-- 1. Structured return/collection tracking table
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.dispute_return_tracking_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,
  courier_id uuid REFERENCES public.couriers(id),
  tracking_ref text,
  tracking_date date,
  tracking_evidence_url text,
  retailer_return_instructions_file_url text,
  return_label_file_url text,
  return_proof_file_url text,
  submitted_by_operator_id uuid REFERENCES public.operators(id),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  is_final_return_yn boolean NOT NULL DEFAULT false,
  note text,
  source_dispute_message_id uuid UNIQUE REFERENCES public.dispute_messages(id),
  review_status text NOT NULL DEFAULT 'pending_review' CHECK (review_status IN ('pending_review','accepted','hold','rejected')),
  reviewed_by_staff_id uuid REFERENCES public.staff(id),
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispute_return_tracking_dispute
  ON public.dispute_return_tracking_submissions(dispute_id, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_dispute_return_tracking_review
  ON public.dispute_return_tracking_submissions(review_status, submitted_at DESC);

COMMENT ON TABLE public.dispute_return_tracking_submissions IS
'Structured return/collection tracking evidence for refund exceptions. Mirrors order_tracking_submissions but is anchored to a refund dispute.';

-- =============================================================================
-- 2. Structured refund/credit/no-document supplier evidence table
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.dispute_refund_evidence_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id uuid NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,
  original_order_id uuid REFERENCES public.orders(id),
  original_supplier_invoice_id uuid REFERENCES public.supplier_invoices(id),
  submitted_by_operator_id uuid REFERENCES public.operators(id),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  document_mode text NOT NULL CHECK (document_mode IN ('credit_note','refund_proof_no_credit_note','no_document','unknown')),
  message_type text NOT NULL CHECK (message_type IN ('credit_note_evidence','refund_evidence')),
  credit_note_ref text,
  credit_note_date date,
  expected_credit_note_total_gbp numeric(12,2),
  credit_note_file_url text,
  refund_proof_file_url text,
  refund_lines_json jsonb NOT NULL DEFAULT '[]'::jsonb,
  delivery_adjustment_gbp numeric(12,2) NOT NULL DEFAULT 0,
  discount_adjustment_gbp numeric(12,2) NOT NULL DEFAULT 0,
  expected_exception_amount_abs_gbp numeric(12,2),
  captured_refund_amount_abs_gbp numeric(12,2),
  variance_abs_gbp numeric(12,2),
  amount_balance_status text CHECK (amount_balance_status IS NULL OR amount_balance_status IN ('balanced','variance','unknown')),
  evidence_control_status text,
  supplier_readiness_route text,
  supplier_approval_status text NOT NULL DEFAULT 'pending' CHECK (supplier_approval_status IN ('pending','blocked','approved_current')),
  supplier_approved_by_staff_id uuid REFERENCES public.staff(id),
  supplier_approved_at timestamptz,
  supervisor_review_status text NOT NULL DEFAULT 'not_required' CHECK (supervisor_review_status IN ('not_required','pending_review','accepted','hold','rejected')),
  supervisor_reviewed_by_staff_id uuid REFERENCES public.staff(id),
  supervisor_reviewed_at timestamptz,
  supervisor_review_notes text,
  source_dispute_message_id uuid UNIQUE REFERENCES public.dispute_messages(id),
  raw_body text NOT NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_evidence_dispute
  ON public.dispute_refund_evidence_submissions(dispute_id, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_evidence_supplier_approval
  ON public.dispute_refund_evidence_submissions(supplier_approval_status, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_dispute_refund_evidence_review
  ON public.dispute_refund_evidence_submissions(supervisor_review_status, submitted_at DESC);

COMMENT ON TABLE public.dispute_refund_evidence_submissions IS
'Structured supplier-side refund evidence for credit note, refund proof without credit note, and no-document refund routes. Does not post to Sage.';

-- =============================================================================
-- 3. RLS for structured tables
-- =============================================================================
ALTER TABLE public.dispute_return_tracking_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dispute_refund_evidence_submissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "staff and linked operators can read return tracking" ON public.dispute_return_tracking_submissions;
CREATE POLICY "staff and linked operators can read return tracking"
ON public.dispute_return_tracking_submissions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id = op.id
    JOIN public.disputes d ON d.id = dispute_return_tracking_submissions.dispute_id
    JOIN public.orders o ON o.id = d.order_id
    WHERE op.auth_user_id = auth.uid()
      AND op.active = true
      AND oi.importer_id = o.importer_id
      AND oi.revoked_at IS NULL
  )
);

DROP POLICY IF EXISTS "staff and linked operators can read refund evidence" ON public.dispute_refund_evidence_submissions;
CREATE POLICY "staff and linked operators can read refund evidence"
ON public.dispute_refund_evidence_submissions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id = op.id
    JOIN public.disputes d ON d.id = dispute_refund_evidence_submissions.dispute_id
    JOIN public.orders o ON o.id = d.order_id
    WHERE op.auth_user_id = auth.uid()
      AND op.active = true
      AND oi.importer_id = o.importer_id
      AND oi.revoked_at IS NULL
  )
);

-- =============================================================================
-- 4. Narrow compatibility INSERT policies for current message-based app actions
-- =============================================================================
-- These are intentionally narrow. They do not open arbitrary dispute_messages writes.
-- They allow the currently deployed forms to work while structured RPC wiring is
-- adopted in the app.

DROP POLICY IF EXISTS "operators can insert refund exception evidence messages" ON public.dispute_messages;
CREATE POLICY "operators can insert refund exception evidence messages"
ON public.dispute_messages
FOR INSERT
TO authenticated
WITH CHECK (
  message_type IN ('return_collection_evidence','credit_note_evidence','refund_evidence')
  AND counterparty IN ('retailer','internal')
  AND EXISTS (
    SELECT 1
    FROM public.operators op
    JOIN public.operator_importers oi ON oi.operator_id = op.id
    JOIN public.disputes d ON d.id = dispute_messages.dispute_id
    JOIN public.orders o ON o.id = d.order_id
    WHERE op.auth_user_id = auth.uid()
      AND op.active = true
      AND oi.importer_id = o.importer_id
      AND oi.revoked_at IS NULL
      AND d.desired_outcome = 'refund'
      AND d.status = 'awaiting_refund_credit'
  )
);

DROP POLICY IF EXISTS "staff can insert exception review and approval messages" ON public.dispute_messages;
CREATE POLICY "staff can insert exception review and approval messages"
ON public.dispute_messages
FOR INSERT
TO authenticated
WITH CHECK (
  message_type IN (
    'supervisor_note',
    'refund_evidence_review',
    'return_collection_evidence_review',
    'supplier_refund_current_approved'
  )
  AND EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
      AND s.role_type IN ('admin','supervisor')
  )
);

-- =============================================================================
-- 5. Body parsing helpers for compatibility triggers
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gcb_message_body_value(p_body text, p_key text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_line text;
BEGIN
  FOR v_line IN SELECT regexp_split_to_table(coalesce(p_body, ''), E'\n') LOOP
    IF v_line LIKE p_key || ':%' THEN
      RETURN nullif(btrim(substr(v_line, length(p_key) + 2)), '');
    END IF;
  END LOOP;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.gcb_uuid_or_null(p_value text)
RETURNS uuid
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_value IS NULL OR btrim(p_value) IN ('', '—', '-') THEN
    RETURN NULL;
  END IF;

  IF btrim(p_value) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN btrim(p_value)::uuid;
  END IF;

  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.gcb_date_or_null(p_value text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_value IS NULL OR btrim(p_value) IN ('', '—', '-') THEN
    RETURN NULL;
  END IF;

  IF btrim(p_value) ~ '^\d{4}-\d{2}-\d{2}$' THEN
    RETURN btrim(p_value)::date;
  END IF;

  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.gcb_numeric_or_null(p_value text)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_clean text;
BEGIN
  IF p_value IS NULL OR btrim(p_value) IN ('', '—', '-') THEN
    RETURN NULL;
  END IF;

  v_clean := replace(btrim(p_value), ',', '');
  IF v_clean ~ '^-?\d+(\.\d+)?$' THEN
    RETURN v_clean::numeric;
  END IF;

  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.gcb_bool_or_false(p_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(btrim(coalesce(p_value, ''))) IN ('true','t','yes','y','1','on')
$$;

-- =============================================================================
-- 6. Compatibility trigger: mirror existing dispute_messages into structured tables
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gcb_sync_exception_evidence_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_source_evidence_message_id uuid;
  v_review_decision text;
  v_staff_id uuid;
  v_body text := coalesce(NEW.body, '');
  v_document_mode text;
  v_control_status text;
  v_supplier_route text;
BEGIN
  IF NEW.message_type = 'return_collection_evidence' THEN
    INSERT INTO public.dispute_return_tracking_submissions (
      dispute_id,
      courier_id,
      tracking_ref,
      tracking_date,
      tracking_evidence_url,
      retailer_return_instructions_file_url,
      return_label_file_url,
      return_proof_file_url,
      submitted_by_operator_id,
      submitted_at,
      is_final_return_yn,
      note,
      source_dispute_message_id
    )
    VALUES (
      NEW.dispute_id,
      public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'courier_id')),
      nullif(public.gcb_message_body_value(v_body, 'tracking_ref'), '—'),
      public.gcb_date_or_null(public.gcb_message_body_value(v_body, 'tracking_date')),
      nullif(public.gcb_message_body_value(v_body, 'tracking_evidence_url'), '—'),
      nullif(public.gcb_message_body_value(v_body, 'retailer_return_instructions_file_url'), '—'),
      nullif(public.gcb_message_body_value(v_body, 'return_label_file_url'), '—'),
      nullif(public.gcb_message_body_value(v_body, 'return_proof_file_url'), '—'),
      public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'operator_id')),
      coalesce(NEW.created_at, now()),
      public.gcb_bool_or_false(public.gcb_message_body_value(v_body, 'is_final_return_yn')),
      nullif(split_part(v_body, E'\n\n', 2), ''),
      NEW.id
    )
    ON CONFLICT (source_dispute_message_id) DO NOTHING;

  ELSIF NEW.message_type = 'return_collection_evidence_review' THEN
    v_source_evidence_message_id := public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'source_evidence_message_id'));
    v_review_decision := public.gcb_message_body_value(v_body, 'review_decision');
    v_staff_id := public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'reviewed_by_staff_id'));

    UPDATE public.dispute_return_tracking_submissions
    SET review_status = CASE
          WHEN v_review_decision IN ('accepted','hold','rejected') THEN v_review_decision
          ELSE review_status
        END,
        reviewed_by_staff_id = coalesce(v_staff_id, reviewed_by_staff_id),
        reviewed_at = coalesce(NEW.created_at, now()),
        review_notes = nullif(split_part(v_body, E'\n\n', 2), '')
    WHERE source_dispute_message_id = v_source_evidence_message_id;

  ELSIF NEW.message_type IN ('credit_note_evidence','refund_evidence') THEN
    v_document_mode := coalesce(nullif(public.gcb_message_body_value(v_body, 'document_mode'), ''), 'unknown');
    IF v_document_mode NOT IN ('credit_note','refund_proof_no_credit_note','no_document') THEN
      v_document_mode := 'unknown';
    END IF;

    v_control_status := public.gcb_message_body_value(v_body, 'evidence_control_status');
    v_supplier_route := public.gcb_message_body_value(v_body, 'supplier_readiness_route');

    INSERT INTO public.dispute_refund_evidence_submissions (
      dispute_id,
      original_order_id,
      original_supplier_invoice_id,
      submitted_by_operator_id,
      submitted_at,
      document_mode,
      message_type,
      credit_note_ref,
      credit_note_date,
      expected_credit_note_total_gbp,
      credit_note_file_url,
      refund_proof_file_url,
      delivery_adjustment_gbp,
      discount_adjustment_gbp,
      expected_exception_amount_abs_gbp,
      captured_refund_amount_abs_gbp,
      variance_abs_gbp,
      amount_balance_status,
      evidence_control_status,
      supplier_readiness_route,
      supplier_approval_status,
      supervisor_review_status,
      source_dispute_message_id,
      raw_body,
      notes
    )
    VALUES (
      NEW.dispute_id,
      public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'original_order_id')),
      public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'original_supplier_invoice_id')),
      public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'operator_id')),
      coalesce(NEW.created_at, now()),
      v_document_mode,
      NEW.message_type,
      nullif(public.gcb_message_body_value(v_body, 'credit_note_ref'), '—'),
      public.gcb_date_or_null(public.gcb_message_body_value(v_body, 'credit_note_date')),
      public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'expected_credit_note_total_gbp')),
      nullif(public.gcb_message_body_value(v_body, 'credit_note_file_url'), '—'),
      nullif(public.gcb_message_body_value(v_body, 'refund_proof_file_url'), '—'),
      coalesce(public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'delivery_adjustment_gbp')), 0),
      coalesce(public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'discount_adjustment_gbp')), 0),
      public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'expected_exception_amount_abs_gbp')),
      public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'captured_refund_amount_abs_gbp')),
      public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'variance_abs_gbp')),
      CASE
        WHEN lower(coalesce(public.gcb_message_body_value(v_body, 'amount_balance_status'), '')) IN ('balanced','variance','unknown')
          THEN lower(public.gcb_message_body_value(v_body, 'amount_balance_status'))
        WHEN coalesce(public.gcb_numeric_or_null(public.gcb_message_body_value(v_body, 'variance_abs_gbp')), 0) = 0
          THEN 'balanced'
        ELSE 'variance'
      END,
      v_control_status,
      v_supplier_route,
      CASE
        WHEN coalesce(v_control_status, '') LIKE '%pending_ocr%' OR coalesce(v_supplier_route, '') LIKE '%pending_ocr%'
          THEN 'blocked'
        ELSE 'pending'
      END,
      CASE
        WHEN coalesce(v_control_status, '') LIKE '%review_required%' OR coalesce(v_supplier_route, '') LIKE '%review_required%'
          THEN 'pending_review'
        ELSE 'not_required'
      END,
      NEW.id,
      v_body,
      nullif(split_part(v_body, E'\n\n', 2), '')
    )
    ON CONFLICT (source_dispute_message_id) DO NOTHING;

  ELSIF NEW.message_type = 'refund_evidence_review' THEN
    v_source_evidence_message_id := public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'source_evidence_message_id'));
    v_review_decision := public.gcb_message_body_value(v_body, 'review_decision');
    v_staff_id := public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'reviewed_by_staff_id'));

    UPDATE public.dispute_refund_evidence_submissions
    SET supervisor_review_status = CASE
          WHEN v_review_decision IN ('accepted','hold','rejected') THEN v_review_decision
          ELSE supervisor_review_status
        END,
        supervisor_reviewed_by_staff_id = coalesce(v_staff_id, supervisor_reviewed_by_staff_id),
        supervisor_reviewed_at = coalesce(NEW.created_at, now()),
        supervisor_review_notes = nullif(split_part(v_body, E'\n\n', 2), '')
    WHERE source_dispute_message_id = v_source_evidence_message_id;

  ELSIF NEW.message_type = 'supplier_refund_current_approved' THEN
    v_source_evidence_message_id := public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'source_evidence_message_id'));
    v_staff_id := public.gcb_uuid_or_null(public.gcb_message_body_value(v_body, 'approved_by_staff_id'));

    UPDATE public.dispute_refund_evidence_submissions
    SET supplier_approval_status = 'approved_current',
        supplier_approved_by_staff_id = coalesce(v_staff_id, supplier_approved_by_staff_id),
        supplier_approved_at = coalesce(NEW.created_at, now())
    WHERE source_dispute_message_id = v_source_evidence_message_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_gcb_sync_exception_evidence_message ON public.dispute_messages;
CREATE TRIGGER trg_gcb_sync_exception_evidence_message
AFTER INSERT ON public.dispute_messages
FOR EACH ROW
WHEN (NEW.message_type IN (
  'return_collection_evidence',
  'return_collection_evidence_review',
  'credit_note_evidence',
  'refund_evidence',
  'refund_evidence_review',
  'supplier_refund_current_approved'
))
EXECUTE FUNCTION public.gcb_sync_exception_evidence_message();

-- =============================================================================
-- 7. Future-safe RPCs for the app to call instead of direct message inserts
-- =============================================================================
CREATE OR REPLACE FUNCTION public.operator_submit_return_collection_tracking(
  p_dispute_id uuid,
  p_courier_id uuid DEFAULT NULL,
  p_tracking_ref text DEFAULT NULL,
  p_tracking_date date DEFAULT NULL,
  p_tracking_evidence_url text DEFAULT NULL,
  p_is_final_return_yn boolean DEFAULT false,
  p_retailer_return_instructions_file_url text DEFAULT NULL,
  p_return_label_file_url text DEFAULT NULL,
  p_return_proof_file_url text DEFAULT NULL,
  p_note text DEFAULT NULL
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
  v_desired_outcome text;
  v_status text;
  v_courier_name text;
  v_message_id uuid;
  v_submission_id uuid;
  v_body text;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: return tracking requires auth.uid()';
  END IF;

  SELECT op.id INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id = v_auth_uid
    AND op.active = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found.';
  END IF;

  SELECT o.importer_id, d.desired_outcome, d.status
    INTO v_importer_id, v_desired_outcome, v_status
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  WHERE d.id = p_dispute_id
  LIMIT 1;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Dispute not found or parent importer missing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised to update this dispute.';
  END IF;

  IF v_desired_outcome <> 'refund' THEN
    RAISE EXCEPTION 'Return/collection tracking currently belongs to refund exceptions only.';
  END IF;

  IF v_status <> 'awaiting_refund_credit' THEN
    RAISE EXCEPTION 'Supervisor must accept the final retailer refund outcome before return/collection tracking is uploaded. Current status: %', v_status;
  END IF;

  IF p_is_final_return_yn AND (p_courier_id IS NULL OR nullif(btrim(coalesce(p_tracking_ref, '')), '') IS NULL OR p_tracking_date IS NULL) THEN
    RAISE EXCEPTION 'Final return/collection requires courier, tracking ref and tracking date.';
  END IF;

  IF p_courier_id IS NULL
     AND nullif(btrim(coalesce(p_tracking_ref, '')), '') IS NULL
     AND p_tracking_date IS NULL
     AND nullif(btrim(coalesce(p_tracking_evidence_url, '')), '') IS NULL
     AND nullif(btrim(coalesce(p_note, '')), '') IS NULL
     AND nullif(btrim(coalesce(p_retailer_return_instructions_file_url, '')), '') IS NULL
     AND nullif(btrim(coalesce(p_return_label_file_url, '')), '') IS NULL
     AND nullif(btrim(coalesce(p_return_proof_file_url, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Add tracking details, a URL, a file, or a note before saving return evidence.';
  END IF;

  IF p_courier_id IS NOT NULL THEN
    SELECT c.name INTO v_courier_name
    FROM public.couriers c
    WHERE c.id = p_courier_id
    LIMIT 1;

    IF v_courier_name IS NULL THEN
      RAISE EXCEPTION 'Courier not found.';
    END IF;
  END IF;

  v_body := array_to_string(array[
    '[RETURN_COLLECTION_EVIDENCE_V1]',
    'uploaded_by: operator',
    'operator_id: ' || v_operator_id::text,
    'dispute_id: ' || p_dispute_id::text,
    'courier_id: ' || coalesce(p_courier_id::text, '—'),
    'courier_name: ' || coalesce(v_courier_name, '—'),
    'tracking_ref: ' || coalesce(nullif(btrim(coalesce(p_tracking_ref, '')), ''), '—'),
    'tracking_date: ' || coalesce(p_tracking_date::text, '—'),
    'tracking_evidence_url: ' || coalesce(nullif(btrim(coalesce(p_tracking_evidence_url, '')), ''), '—'),
    'is_final_return_yn: ' || CASE WHEN coalesce(p_is_final_return_yn, false) THEN 'true' ELSE 'false' END,
    'retailer_return_instructions_file_url: ' || coalesce(nullif(btrim(coalesce(p_retailer_return_instructions_file_url, '')), ''), '—'),
    'return_label_file_url: ' || coalesce(nullif(btrim(coalesce(p_return_label_file_url, '')), ''), '—'),
    'return_proof_file_url: ' || coalesce(nullif(btrim(coalesce(p_return_proof_file_url, '')), ''), '—'),
    '',
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'No note.')
  ], E'\n');

  INSERT INTO public.dispute_messages (dispute_id, message_type, counterparty, generated_by, body)
  VALUES (p_dispute_id, 'return_collection_evidence', 'retailer', 'operator_upload', v_body)
  RETURNING id INTO v_message_id;

  SELECT id INTO v_submission_id
  FROM public.dispute_return_tracking_submissions
  WHERE source_dispute_message_id = v_message_id
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'dispute_id', p_dispute_id,
    'dispute_message_id', v_message_id,
    'return_tracking_submission_id', v_submission_id
  );
END;
$$;

COMMENT ON FUNCTION public.operator_submit_return_collection_tracking(uuid, uuid, text, date, text, boolean, text, text, text, text) IS
'Operator-only RPC for structured return/collection tracking evidence on refund exceptions. Mirrors order tracking semantics while preserving current dispute message audit.';

REVOKE ALL ON FUNCTION public.operator_submit_return_collection_tracking(uuid, uuid, text, date, text, boolean, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_submit_return_collection_tracking(uuid, uuid, text, date, text, boolean, text, text, text, text) TO authenticated;

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
  VALUES (v_dispute_id, 'return_collection_evidence_review', 'internal', 'supervisor_review', v_body)
  RETURNING id INTO v_message_id;

  UPDATE public.dispute_return_tracking_submissions
  SET review_status = p_review_decision,
      reviewed_by_staff_id = v_staff_id,
      reviewed_at = now(),
      review_notes = nullif(btrim(coalesce(p_review_notes, '')), '')
  WHERE id = p_return_tracking_submission_id;

  RETURN jsonb_build_object('ok', true, 'review_message_id', v_message_id, 'return_tracking_submission_id', p_return_tracking_submission_id);
END;
$$;

REVOKE ALL ON FUNCTION public.staff_review_return_collection_tracking(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_review_return_collection_tracking(uuid, text, text) TO authenticated;

-- =============================================================================
-- 8. Backfill structured tables from any messages already saved before this patch
-- =============================================================================
INSERT INTO public.dispute_return_tracking_submissions (
  dispute_id,
  courier_id,
  tracking_ref,
  tracking_date,
  tracking_evidence_url,
  retailer_return_instructions_file_url,
  return_label_file_url,
  return_proof_file_url,
  submitted_by_operator_id,
  submitted_at,
  is_final_return_yn,
  note,
  source_dispute_message_id
)
SELECT
  dm.dispute_id,
  public.gcb_uuid_or_null(public.gcb_message_body_value(dm.body, 'courier_id')),
  nullif(public.gcb_message_body_value(dm.body, 'tracking_ref'), '—'),
  public.gcb_date_or_null(public.gcb_message_body_value(dm.body, 'tracking_date')),
  nullif(public.gcb_message_body_value(dm.body, 'tracking_evidence_url'), '—'),
  nullif(public.gcb_message_body_value(dm.body, 'retailer_return_instructions_file_url'), '—'),
  nullif(public.gcb_message_body_value(dm.body, 'return_label_file_url'), '—'),
  nullif(public.gcb_message_body_value(dm.body, 'return_proof_file_url'), '—'),
  public.gcb_uuid_or_null(public.gcb_message_body_value(dm.body, 'operator_id')),
  dm.created_at,
  public.gcb_bool_or_false(public.gcb_message_body_value(dm.body, 'is_final_return_yn')),
  nullif(split_part(dm.body, E'\n\n', 2), ''),
  dm.id
FROM public.dispute_messages dm
WHERE dm.message_type = 'return_collection_evidence'
ON CONFLICT (source_dispute_message_id) DO NOTHING;

INSERT INTO public.dispute_refund_evidence_submissions (
  dispute_id,
  original_order_id,
  original_supplier_invoice_id,
  submitted_by_operator_id,
  submitted_at,
  document_mode,
  message_type,
  credit_note_ref,
  credit_note_date,
  expected_credit_note_total_gbp,
  credit_note_file_url,
  refund_proof_file_url,
  delivery_adjustment_gbp,
  discount_adjustment_gbp,
  expected_exception_amount_abs_gbp,
  captured_refund_amount_abs_gbp,
  variance_abs_gbp,
  amount_balance_status,
  evidence_control_status,
  supplier_readiness_route,
  supplier_approval_status,
  supervisor_review_status,
  source_dispute_message_id,
  raw_body,
  notes
)
SELECT
  dm.dispute_id,
  public.gcb_uuid_or_null(public.gcb_message_body_value(dm.body, 'original_order_id')),
  public.gcb_uuid_or_null(public.gcb_message_body_value(dm.body, 'original_supplier_invoice_id')),
  public.gcb_uuid_or_null(public.gcb_message_body_value(dm.body, 'operator_id')),
  dm.created_at,
  CASE
    WHEN public.gcb_message_body_value(dm.body, 'document_mode') IN ('credit_note','refund_proof_no_credit_note','no_document')
      THEN public.gcb_message_body_value(dm.body, 'document_mode')
    ELSE 'unknown'
  END,
  dm.message_type,
  nullif(public.gcb_message_body_value(dm.body, 'credit_note_ref'), '—'),
  public.gcb_date_or_null(public.gcb_message_body_value(dm.body, 'credit_note_date')),
  public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'expected_credit_note_total_gbp')),
  nullif(public.gcb_message_body_value(dm.body, 'credit_note_file_url'), '—'),
  nullif(public.gcb_message_body_value(dm.body, 'refund_proof_file_url'), '—'),
  coalesce(public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'delivery_adjustment_gbp')), 0),
  coalesce(public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'discount_adjustment_gbp')), 0),
  public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'expected_exception_amount_abs_gbp')),
  public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'captured_refund_amount_abs_gbp')),
  public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'variance_abs_gbp')),
  CASE
    WHEN lower(coalesce(public.gcb_message_body_value(dm.body, 'amount_balance_status'), '')) IN ('balanced','variance','unknown')
      THEN lower(public.gcb_message_body_value(dm.body, 'amount_balance_status'))
    WHEN coalesce(public.gcb_numeric_or_null(public.gcb_message_body_value(dm.body, 'variance_abs_gbp')), 0) = 0
      THEN 'balanced'
    ELSE 'variance'
  END,
  public.gcb_message_body_value(dm.body, 'evidence_control_status'),
  public.gcb_message_body_value(dm.body, 'supplier_readiness_route'),
  CASE
    WHEN coalesce(public.gcb_message_body_value(dm.body, 'evidence_control_status'), '') LIKE '%pending_ocr%'
      OR coalesce(public.gcb_message_body_value(dm.body, 'supplier_readiness_route'), '') LIKE '%pending_ocr%'
      THEN 'blocked'
    ELSE 'pending'
  END,
  CASE
    WHEN coalesce(public.gcb_message_body_value(dm.body, 'evidence_control_status'), '') LIKE '%review_required%'
      OR coalesce(public.gcb_message_body_value(dm.body, 'supplier_readiness_route'), '') LIKE '%review_required%'
      THEN 'pending_review'
    ELSE 'not_required'
  END,
  dm.id,
  dm.body,
  nullif(split_part(dm.body, E'\n\n', 2), '')
FROM public.dispute_messages dm
WHERE dm.message_type IN ('credit_note_evidence','refund_evidence')
ON CONFLICT (source_dispute_message_id) DO NOTHING;

COMMIT;
