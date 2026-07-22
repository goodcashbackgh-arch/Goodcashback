BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_reconcile_dva_line_to_order funding RPC.';
  END IF;
  IF to_regprocedure('public.order_funding_gap_gbp(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing order_funding_gap_gbp(uuid).';
  END IF;
  IF to_regclass('public.order_surplus_evidence_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing order_surplus_evidence_position_v1.';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.order_pending_surplus_positions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  dva_statement_line_id uuid NOT NULL REFERENCES public.dva_statement_lines(id) ON DELETE RESTRICT,
  amount_gbp numeric(12,2) NOT NULL CHECK (amount_gbp > 0),
  status text NOT NULL DEFAULT 'pending_evidence' CHECK (status IN ('pending_evidence','classified_credit','reversed')),
  classification_reason text,
  notes text,
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  classified_by_staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT,
  classified_at timestamptz,
  reversed_by_staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT,
  reversed_at timestamptz,
  reversal_reason text
);

CREATE UNIQUE INDEX IF NOT EXISTS order_pending_surplus_one_active_line_order_uidx
  ON public.order_pending_surplus_positions(order_id, dva_statement_line_id)
  WHERE status = 'pending_evidence';

CREATE INDEX IF NOT EXISTS order_pending_surplus_order_status_idx
  ON public.order_pending_surplus_positions(order_id, status, created_at DESC);

ALTER TABLE public.order_pending_surplus_positions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_pending_surplus_staff_select ON public.order_pending_surplus_positions;
CREATE POLICY order_pending_surplus_staff_select
ON public.order_pending_surplus_positions
FOR SELECT TO authenticated
USING (public.is_active_staff());

REVOKE ALL ON TABLE public.order_pending_surplus_positions FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE ON TABLE public.order_pending_surplus_positions FROM authenticated;
GRANT SELECT ON TABLE public.order_pending_surplus_positions TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reconciled_gbp_amount numeric,
  p_match_suggestion_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_line record;
  v_order record;
  v_requested numeric(12,2) := ROUND(COALESCE(p_reconciled_gbp_amount,0)::numeric,2);
  v_gap numeric(12,2);
  v_pending numeric(12,2);
  v_result jsonb;
  v_pending_id uuid;
BEGIN
  IF v_auth_uid IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT s.id, s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid AND COALESCE(s.active,true)=true
  LIMIT 1;

  IF v_staff.id IS NULL OR COALESCE(v_staff.role_type,'') NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only an active admin or supervisor can reconcile DVA funding.';
  END IF;

  SELECT dsl.id, dsl.direction, ds.importer_id, ROUND(COALESCE(dsl.amount_gbp_equivalent,0)::numeric,2) AS statement_gbp
    INTO v_line
  FROM public.dva_statement_lines dsl
  JOIN public.dva_statements ds ON ds.id=dsl.dva_statement_id
  WHERE dsl.id=p_dva_statement_line_id
  FOR UPDATE OF dsl;

  IF v_line.id IS NULL THEN RAISE EXCEPTION 'DVA statement line not found.'; END IF;
  IF v_line.direction <> 'in' THEN RAISE EXCEPTION 'Pending funding surplus requires an IN statement line.'; END IF;
  IF v_requested <= 0 OR v_requested > v_line.statement_gbp + 0.01 THEN
    RAISE EXCEPTION 'Requested amount % must be positive and cannot exceed statement amount %.', v_requested, v_line.statement_gbp;
  END IF;

  SELECT o.id, o.importer_id, COALESCE(o.order_type,'original') AS order_type, o.status
    INTO v_order
  FROM public.orders o
  WHERE o.id=p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_order.importer_id IS DISTINCT FROM v_line.importer_id THEN RAISE EXCEPTION 'Importer mismatch.'; END IF;
  IF v_order.order_type <> 'original' THEN RAISE EXCEPTION 'Original order required.'; END IF;
  IF v_order.status IN ('archived','cancelled') THEN RAISE EXCEPTION 'Order status % cannot receive funding.', v_order.status; END IF;

  v_gap := ROUND(COALESCE(public.order_funding_gap_gbp(p_order_id),0)::numeric,2);
  IF v_gap <= 0 THEN RAISE EXCEPTION 'Order has no remaining funding gap.'; END IF;
  IF v_requested <= v_gap THEN
    RETURN public.staff_reconcile_dva_line_to_order(
      p_dva_statement_line_id,p_order_id,v_requested,false,p_match_suggestion_id,p_notes
    );
  END IF;

  v_pending := ROUND(v_requested-v_gap,2);

  IF EXISTS (
    SELECT 1 FROM public.order_pending_surplus_positions p
    WHERE p.order_id=p_order_id
      AND p.dva_statement_line_id=p_dva_statement_line_id
      AND p.status='pending_evidence'
  ) THEN
    RAISE EXCEPTION 'This statement line already has a pending surplus position for the order.';
  END IF;

  v_result := public.staff_reconcile_dva_line_to_order(
    p_dva_statement_line_id,
    p_order_id,
    v_gap,
    false,
    p_match_suggestion_id,
    concat_ws(E'\n',p_notes,'Receipt exceeded order funding gap; residual retained pending operational evidence and supervisor classification.')
  );

  INSERT INTO public.order_pending_surplus_positions(
    order_id,dva_statement_line_id,amount_gbp,status,notes,created_by_staff_id
  ) VALUES (
    p_order_id,p_dva_statement_line_id,v_pending,'pending_evidence',
    concat('Requested receipt £',v_requested::text,'; order funding applied £',v_gap::text,'; pending surplus £',v_pending::text,'.'),
    v_staff.id
  ) RETURNING id INTO v_pending_id;

  RETURN v_result || jsonb_build_object(
    'pending_surplus_yn',true,
    'funding_amount_gbp',v_gap,
    'pending_surplus_gbp',v_pending,
    'pending_surplus_position_id',v_pending_id,
    'fx_gain_gbp',0,
    'credit_created_yn',false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text) TO authenticated;

CREATE OR REPLACE VIEW public.order_surplus_evidence_position_v2 AS
WITH pending AS (
  SELECT order_id, ROUND(COALESCE(SUM(amount_gbp),0)::numeric,2) AS pending_surplus_gbp
  FROM public.order_pending_surplus_positions
  WHERE status='pending_evidence'
  GROUP BY order_id
), credit AS (
  SELECT source_entity_id AS order_id,
         ROUND(COALESCE(SUM(CASE WHEN direction='credit' THEN ABS(amount_gbp) ELSE -ABS(amount_gbp) END),0)::numeric,2) AS credit_created_gbp
  FROM public.importer_credit_ledger
  WHERE source_type IN ('overfunding','settlement_credit')
    AND source_entity_type='order'
    AND source_entity_id IS NOT NULL
  GROUP BY source_entity_id
), base AS (
  SELECT v.*, COALESCE(p.pending_surplus_gbp,0)::numeric AS pending_surplus_gbp,
         GREATEST(COALESCE(v.credit_created_gbp,0),COALESCE(c.credit_created_gbp,0))::numeric AS effective_credit_created_gbp,
         ROUND((COALESCE(v.funding_total_gbp,0)+COALESCE(p.pending_surplus_gbp,0))::numeric,2) AS effective_receipt_gbp
  FROM public.order_surplus_evidence_position_v1 v
  LEFT JOIN pending p ON p.order_id=v.order_id
  LEFT JOIN credit c ON c.order_id=v.order_id
)
SELECT
  b.order_id,b.order_ref,b.importer_id,b.payment_auth_id,b.declared_order_gbp,
  b.effective_receipt_gbp AS funding_total_gbp,
  b.supplier_out_gbp,b.supplier_out_count,b.posted_invoice_gbp,b.posted_invoice_count,
  b.draft_invoice_gbp,b.draft_invoice_count,b.effective_credit_created_gbp AS credit_created_gbp,
  b.open_dispute_count,b.active_hold_count,b.evidence_value_gbp,
  ROUND((b.effective_receipt_gbp-b.evidence_value_gbp)::numeric,2) AS evidence_surplus_gbp,
  CASE
    WHEN b.effective_credit_created_gbp > 0 THEN 'credit_created'
    WHEN b.open_dispute_count > 0 OR b.active_hold_count > 0 THEN 'blocked_by_open_issue'
    WHEN b.effective_receipt_gbp <= 0 THEN 'no_confirmed_funding'
    WHEN b.posted_invoice_count > 0 AND ROUND((b.effective_receipt_gbp-b.posted_invoice_gbp)::numeric,2) > 0 THEN 'ready_posted_invoice_surplus'
    WHEN b.draft_invoice_count > 0 AND ROUND((b.effective_receipt_gbp-b.draft_invoice_gbp)::numeric,2) > 0 THEN 'ready_draft_invoice_surplus'
    WHEN b.supplier_out_count > 0 AND ROUND((b.effective_receipt_gbp-b.supplier_out_gbp)::numeric,2) > 0 THEN 'ready_strong_in_out_surplus'
    WHEN b.supplier_out_count > 0 THEN 'in_out_no_surplus'
    ELSE 'pending_insufficient_evidence'
  END AS evidence_status,
  b.evidence_basis
FROM base b;

GRANT SELECT ON public.order_surplus_evidence_position_v2 TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(
  p_order_id uuid,
  p_reason text DEFAULT 'supervisor_confirmed_credit',
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  s record;
  o record;
  e record;
  new_id uuid;
  existing_credit_gbp numeric := 0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  SELECT id,role_type INTO s FROM public.staff WHERE auth_user_id=auth.uid() AND COALESCE(active,true)=true LIMIT 1;
  IF s.id IS NULL OR s.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Supervisor/admin required.'; END IF;

  SELECT id,importer_id,COALESCE(order_type,'original') AS order_type INTO o
  FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF o.order_type <> 'original' THEN RAISE EXCEPTION 'Original order required.'; END IF;

  SELECT COALESCE(SUM(CASE WHEN direction='credit' THEN ABS(amount_gbp) ELSE -ABS(amount_gbp) END),0)
    INTO existing_credit_gbp
  FROM public.importer_credit_ledger
  WHERE importer_id=o.importer_id
    AND source_type IN ('overfunding','settlement_credit')
    AND source_entity_type='order'
    AND source_entity_id=p_order_id;

  IF existing_credit_gbp > 0 THEN
    RETURN jsonb_build_object('ok',true,'already_confirmed',true,'credit_gbp',ROUND(existing_credit_gbp::numeric,2));
  END IF;

  SELECT * INTO e FROM public.order_surplus_evidence_position_v2 WHERE order_id=p_order_id;
  IF e.evidence_status NOT IN ('ready_posted_invoice_surplus','ready_draft_invoice_surplus','ready_strong_in_out_surplus') THEN RAISE EXCEPTION 'Not ready: %',e.evidence_status; END IF;
  IF e.open_dispute_count > 0 OR e.active_hold_count > 0 THEN RAISE EXCEPTION 'Open issue blocks confirmation.'; END IF;
  IF e.evidence_surplus_gbp <= 0 THEN RAISE EXCEPTION 'No surplus.'; END IF;

  INSERT INTO public.importer_credit_ledger(
    importer_id,entry_type,source_table,source_id,linked_order_id,direction,amount_gbp,amount_local_ccy,local_ccy,effective_at,
    source_type,source_entity_type,source_entity_id,created_by_staff_id,notes
  ) VALUES (
    o.importer_id,'manual_credit','orders',p_order_id,p_order_id,'credit',e.evidence_surplus_gbp,e.evidence_surplus_gbp,'GBP',now(),
    'overfunding','order',p_order_id,s.id,COALESCE(p_notes,'Surplus confirmed from evidence')
  ) RETURNING id INTO new_id;

  UPDATE public.order_pending_surplus_positions
     SET status='classified_credit',classification_reason=COALESCE(NULLIF(btrim(p_reason),''),'supervisor_confirmed_credit'),
         classified_by_staff_id=s.id,classified_at=now()
   WHERE order_id=p_order_id AND status='pending_evidence';

  RETURN jsonb_build_object('ok',true,'credit_ledger_id',new_id,'credit_gbp',e.evidence_surplus_gbp,'basis',e.evidence_basis);
END;
$$;

REVOKE ALL ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text) TO authenticated;

COMMENT ON TABLE public.order_pending_surplus_positions IS
'Neutral order-linked receipt residual awaiting downstream operational evidence. It is neither order funding, FX nor customer credit until classified.';
COMMENT ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text) IS
'Funds only the current order gap and preserves an over-gap IN residual as pending evidence-based surplus; no FX or credit is created.';

NOTIFY pgrst, 'reload schema';
COMMIT;
