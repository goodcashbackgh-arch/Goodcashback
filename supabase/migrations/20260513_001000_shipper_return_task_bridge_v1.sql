BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.dispute_return_tracking_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_return_tracking_submissions';
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.shipper_users') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shipper_users';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.shipper_return_task_confirmations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_tracking_submission_id uuid NOT NULL REFERENCES public.dispute_return_tracking_submissions(id) ON DELETE CASCADE,
  dispute_id uuid NOT NULL REFERENCES public.disputes(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  shipper_id uuid NOT NULL REFERENCES public.shippers(id),
  submitted_by_shipper_user_id uuid NOT NULL REFERENCES public.shipper_users(id),
  outcome text NOT NULL CHECK (outcome IN ('collected','handed_to_courier','returned_to_retailer','unable_to_return','query')),
  proof_file_url text,
  proof_url text,
  note text,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  review_status text NOT NULL DEFAULT 'pending_review' CHECK (review_status IN ('pending_review','accepted','hold','rejected')),
  reviewed_by_staff_id uuid REFERENCES public.staff(id),
  reviewed_at timestamptz,
  review_notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_shipper_return_confirmations_submission
  ON public.shipper_return_task_confirmations(return_tracking_submission_id, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_shipper_return_confirmations_review
  ON public.shipper_return_task_confirmations(review_status, submitted_at DESC);

CREATE INDEX IF NOT EXISTS idx_shipper_return_confirmations_order
  ON public.shipper_return_task_confirmations(order_id, submitted_at DESC);

ALTER TABLE public.shipper_return_task_confirmations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "staff can read shipper return confirmations" ON public.shipper_return_task_confirmations;
CREATE POLICY "staff can read shipper return confirmations"
ON public.shipper_return_task_confirmations
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
  )
);

DROP POLICY IF EXISTS "shipper users can read own return confirmations" ON public.shipper_return_task_confirmations;
CREATE POLICY "shipper users can read own return confirmations"
ON public.shipper_return_task_confirmations
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.shipper_users su
    WHERE su.auth_user_id = auth.uid()
      AND su.active = true
      AND su.shipper_id = shipper_return_task_confirmations.shipper_id
  )
);

CREATE OR REPLACE FUNCTION public.shipper_return_tasks_v1()
RETURNS TABLE (
  return_tracking_submission_id uuid,
  dispute_id uuid,
  order_id uuid,
  order_ref text,
  importer_name text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  tracking_evidence_url text,
  retailer_return_instructions_file_url text,
  return_label_file_url text,
  operator_return_proof_file_url text,
  operator_note text,
  is_final_return_yn boolean,
  operator_review_status text,
  submitted_at timestamptz,
  affected_lines jsonb,
  latest_confirmation_id uuid,
  latest_shipper_outcome text,
  latest_shipper_proof_url text,
  latest_shipper_note text,
  latest_shipper_submitted_at timestamptz,
  latest_shipper_review_status text,
  latest_shipper_review_notes text,
  task_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper return tasks require auth.uid()';
  END IF;

  SELECT su.shipper_id INTO v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.id DESC
  LIMIT 1;

  IF v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  RETURN QUERY
  WITH latest_confirmation AS (
    SELECT DISTINCT ON (c.return_tracking_submission_id)
      c.*
    FROM public.shipper_return_task_confirmations c
    ORDER BY c.return_tracking_submission_id, c.submitted_at DESC, c.id DESC
  ), lines AS (
    SELECT
      dl.dispute_id,
      jsonb_agg(jsonb_build_object(
        'supplier_invoice_line_id', dl.supplier_invoice_line_id,
        'description', sil.description,
        'qty', COALESCE(dl.qty_impact, sil.qty),
        'amount_gbp', COALESCE(dl.amount_impact_gbp, sil.amount_inc_vat_gbp),
        'intended_remedy', dl.intended_remedy,
        'line_status', dl.line_status
      ) ORDER BY sil.line_order NULLS LAST, sil.description) FILTER (WHERE dl.supplier_invoice_line_id IS NOT NULL) AS affected_lines
    FROM public.dispute_lines dl
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    GROUP BY dl.dispute_id
  )
  SELECT
    rt.id,
    d.id,
    o.id,
    o.order_ref::text,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Importer')::text,
    r.name::text,
    c.name::text,
    rt.tracking_ref::text,
    rt.tracking_date,
    rt.tracking_evidence_url::text,
    rt.retailer_return_instructions_file_url::text,
    rt.return_label_file_url::text,
    rt.return_proof_file_url::text,
    rt.note::text,
    rt.is_final_return_yn,
    rt.review_status::text,
    rt.submitted_at,
    COALESCE(lines.affected_lines, '[]'::jsonb),
    lc.id,
    lc.outcome::text,
    COALESCE(lc.proof_file_url, lc.proof_url)::text,
    lc.note::text,
    lc.submitted_at,
    lc.review_status::text,
    lc.review_notes::text,
    CASE
      WHEN lc.id IS NULL THEN 'ready_to_action'
      WHEN lc.review_status = 'pending_review' THEN 'submitted_for_review'
      WHEN lc.review_status = 'accepted' THEN 'accepted'
      WHEN lc.review_status = 'hold' THEN 'held_query'
      WHEN lc.review_status = 'rejected' THEN 'ready_to_action'
      ELSE 'ready_to_action'
    END::text AS task_status
  FROM public.dispute_return_tracking_submissions rt
  JOIN public.disputes d ON d.id = rt.dispute_id
  JOIN public.orders o ON o.id = d.order_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.couriers c ON c.id = rt.courier_id
  LEFT JOIN latest_confirmation lc ON lc.return_tracking_submission_id = rt.id
  LEFT JOIN lines ON lines.dispute_id = d.id
  WHERE o.shipper_id = v_shipper_id
    AND d.desired_outcome = 'refund'
    AND d.resolved_at IS NULL
    AND (
      NULLIF(rt.retailer_return_instructions_file_url, '') IS NOT NULL
      OR NULLIF(rt.return_label_file_url, '') IS NOT NULL
      OR NULLIF(rt.tracking_ref, '') IS NOT NULL
      OR NULLIF(rt.tracking_evidence_url, '') IS NOT NULL
      OR NULLIF(rt.note, '') IS NOT NULL
    )
  ORDER BY
    CASE
      WHEN lc.id IS NULL THEN 1
      WHEN lc.review_status = 'rejected' THEN 2
      WHEN lc.review_status = 'hold' THEN 3
      WHEN lc.review_status = 'pending_review' THEN 4
      WHEN lc.review_status = 'accepted' THEN 5
      ELSE 6
    END,
    rt.submitted_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.shipper_submit_return_task_confirmation_v1(
  p_return_tracking_submission_id uuid,
  p_outcome text,
  p_proof_file_url text DEFAULT NULL,
  p_proof_url text DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_shipper_user_id uuid;
  v_shipper_id uuid;
  v_dispute_id uuid;
  v_order_id uuid;
  v_confirmation_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: shipper return confirmation requires auth.uid()';
  END IF;

  IF p_outcome NOT IN ('collected','handed_to_courier','returned_to_retailer','unable_to_return','query') THEN
    RAISE EXCEPTION 'Invalid shipper return outcome: %', p_outcome;
  END IF;

  SELECT su.id, su.shipper_id
    INTO v_shipper_user_id, v_shipper_id
  FROM public.shipper_users su
  WHERE su.auth_user_id = auth.uid()
    AND su.active = true
  ORDER BY su.id DESC
  LIMIT 1;

  IF v_shipper_user_id IS NULL OR v_shipper_id IS NULL THEN
    RAISE EXCEPTION 'Active shipper user account not found.';
  END IF;

  SELECT d.id, o.id
    INTO v_dispute_id, v_order_id
  FROM public.dispute_return_tracking_submissions rt
  JOIN public.disputes d ON d.id = rt.dispute_id
  JOIN public.orders o ON o.id = d.order_id
  WHERE rt.id = p_return_tracking_submission_id
    AND o.shipper_id = v_shipper_id
    AND d.desired_outcome = 'refund'
    AND d.resolved_at IS NULL
  LIMIT 1;

  IF v_dispute_id IS NULL OR v_order_id IS NULL THEN
    RAISE EXCEPTION 'Return task not found for this shipper account.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_return_task_confirmations c
    WHERE c.return_tracking_submission_id = p_return_tracking_submission_id
      AND c.review_status = 'pending_review'
  ) THEN
    RAISE EXCEPTION 'A shipper return confirmation is already awaiting supervisor review for this task.';
  END IF;

  INSERT INTO public.shipper_return_task_confirmations (
    return_tracking_submission_id,
    dispute_id,
    order_id,
    shipper_id,
    submitted_by_shipper_user_id,
    outcome,
    proof_file_url,
    proof_url,
    note
  ) VALUES (
    p_return_tracking_submission_id,
    v_dispute_id,
    v_order_id,
    v_shipper_id,
    v_shipper_user_id,
    p_outcome,
    NULLIF(btrim(COALESCE(p_proof_file_url, '')), ''),
    NULLIF(btrim(COALESCE(p_proof_url, '')), ''),
    NULLIF(btrim(COALESCE(p_note, '')), '')
  )
  RETURNING id INTO v_confirmation_id;

  RETURN jsonb_build_object(
    'ok', true,
    'confirmation_id', v_confirmation_id,
    'return_tracking_submission_id', p_return_tracking_submission_id,
    'review_status', 'pending_review'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_shipper_return_task_confirmations_v1(p_include_closed boolean DEFAULT false)
RETURNS TABLE (
  confirmation_id uuid,
  return_tracking_submission_id uuid,
  dispute_id uuid,
  order_id uuid,
  order_ref text,
  shipper_name text,
  importer_name text,
  retailer_name text,
  courier_name text,
  tracking_ref text,
  tracking_date date,
  operator_return_instructions_file_url text,
  return_label_file_url text,
  operator_tracking_evidence_url text,
  operator_note text,
  affected_lines jsonb,
  outcome text,
  proof_url text,
  shipper_note text,
  submitted_at timestamptz,
  review_status text,
  reviewed_at timestamptz,
  review_notes text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: internal shipper return review requires auth.uid()';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
  ) THEN
    RAISE EXCEPTION 'Active staff account required.';
  END IF;

  RETURN QUERY
  WITH lines AS (
    SELECT
      dl.dispute_id,
      jsonb_agg(jsonb_build_object(
        'supplier_invoice_line_id', dl.supplier_invoice_line_id,
        'description', sil.description,
        'qty', COALESCE(dl.qty_impact, sil.qty),
        'amount_gbp', COALESCE(dl.amount_impact_gbp, sil.amount_inc_vat_gbp),
        'intended_remedy', dl.intended_remedy,
        'line_status', dl.line_status
      ) ORDER BY sil.line_order NULLS LAST, sil.description) FILTER (WHERE dl.supplier_invoice_line_id IS NOT NULL) AS affected_lines
    FROM public.dispute_lines dl
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id = dl.supplier_invoice_line_id
    GROUP BY dl.dispute_id
  )
  SELECT
    sc.id,
    rt.id,
    d.id,
    o.id,
    o.order_ref::text,
    sh.name::text,
    COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Importer')::text,
    r.name::text,
    c.name::text,
    rt.tracking_ref::text,
    rt.tracking_date,
    rt.retailer_return_instructions_file_url::text,
    rt.return_label_file_url::text,
    rt.tracking_evidence_url::text,
    rt.note::text,
    COALESCE(lines.affected_lines, '[]'::jsonb),
    sc.outcome::text,
    COALESCE(sc.proof_file_url, sc.proof_url)::text,
    sc.note::text,
    sc.submitted_at,
    sc.review_status::text,
    sc.reviewed_at,
    sc.review_notes::text
  FROM public.shipper_return_task_confirmations sc
  JOIN public.dispute_return_tracking_submissions rt ON rt.id = sc.return_tracking_submission_id
  JOIN public.disputes d ON d.id = sc.dispute_id
  JOIN public.orders o ON o.id = sc.order_id
  LEFT JOIN public.shippers sh ON sh.id = sc.shipper_id
  LEFT JOIN public.importers i ON i.id = o.importer_id
  LEFT JOIN public.retailers r ON r.id = o.retailer_id
  LEFT JOIN public.couriers c ON c.id = rt.courier_id
  LEFT JOIN lines ON lines.dispute_id = d.id
  WHERE p_include_closed = true OR sc.review_status = 'pending_review'
  ORDER BY
    CASE sc.review_status WHEN 'pending_review' THEN 1 WHEN 'hold' THEN 2 WHEN 'rejected' THEN 3 WHEN 'accepted' THEN 4 ELSE 5 END,
    sc.submitted_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_review_shipper_return_task_confirmation_v1(
  p_confirmation_id uuid,
  p_review_decision text,
  p_review_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: staff review requires auth.uid()';
  END IF;

  IF p_review_decision NOT IN ('accepted','hold','rejected') THEN
    RAISE EXCEPTION 'Invalid shipper return proof review decision: %', p_review_decision;
  END IF;

  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active supervisor/admin staff account required.';
  END IF;

  UPDATE public.shipper_return_task_confirmations c
  SET review_status = p_review_decision,
      reviewed_by_staff_id = v_staff_id,
      reviewed_at = now(),
      review_notes = NULLIF(btrim(COALESCE(p_review_notes, '')), '')
  WHERE c.id = p_confirmation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Shipper return confirmation not found.';
  END IF;

  RETURN jsonb_build_object('ok', true, 'confirmation_id', p_confirmation_id, 'review_status', p_review_decision);
END;
$$;

REVOKE ALL ON FUNCTION public.shipper_return_tasks_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_shipper_return_task_confirmations_v1(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.staff_review_shipper_return_task_confirmation_v1(uuid,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.shipper_return_tasks_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_shipper_return_task_confirmations_v1(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_review_shipper_return_task_confirmation_v1(uuid,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
