BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing exact staff_reconcile_dva_line_to_order(uuid,uuid,numeric,boolean,uuid,text) prerequisite';
  END IF;
  IF to_regclass('public.order_surplus_evidence_position_v2') IS NULL THEN
    RAISE EXCEPTION 'Missing order_surplus_evidence_position_v2 prerequisite';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.order_pending_funding_surplus (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dva_reconciliation_id uuid NOT NULL UNIQUE REFERENCES public.dva_reconciliation(id),
  dva_statement_line_id uuid NOT NULL UNIQUE REFERENCES public.dva_statement_lines(id),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id),
  importer_id uuid NOT NULL REFERENCES public.importers(id),
  entered_gbp_amount numeric(12,2) NOT NULL CHECK (entered_gbp_amount > 0),
  funding_gbp_amount numeric(12,2) NOT NULL CHECK (funding_gbp_amount > 0),
  pending_surplus_gbp numeric(12,2) NOT NULL CHECK (pending_surplus_gbp > 0),
  status text NOT NULL DEFAULT 'pending_evidence' CHECK (status IN ('pending_evidence','credit_confirmed','reversed')),
  created_by_staff_id uuid NOT NULL REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  confirmed_credit_ledger_id uuid UNIQUE REFERENCES public.importer_credit_ledger(id),
  confirmed_by_staff_id uuid REFERENCES public.staff(id),
  confirmed_at timestamptz,
  notes text,
  CONSTRAINT order_pending_funding_surplus_amounts_ck CHECK (
    entered_gbp_amount = funding_gbp_amount + pending_surplus_gbp
  )
);

ALTER TABLE public.order_pending_funding_surplus ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_pending_funding_surplus FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_pending_funding_surplus TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reconciled_gbp_amount numeric,
  p_match_suggestion_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_staff record;
  v_line record;
  v_order record;
  v_entered numeric(12,2) := round(coalesce(p_reconciled_gbp_amount,0)::numeric,2);
  v_gap numeric(12,2);
  v_pending numeric(12,2);
  v_result jsonb;
  v_reconciliation_id uuid;
  v_pending_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  SELECT id, role_type INTO v_staff FROM public.staff
   WHERE auth_user_id=auth.uid() AND coalesce(active,true)=true LIMIT 1;
  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can reconcile DVA funding lines.';
  END IF;

  SELECT dsl.id, ds.importer_id INTO v_line
    FROM public.dva_statement_lines dsl JOIN public.dva_statements ds ON ds.id=dsl.dva_statement_id
   WHERE dsl.id=p_dva_statement_line_id FOR UPDATE OF dsl;
  SELECT id, importer_id INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF v_line.id IS NULL OR v_order.id IS NULL THEN RAISE EXCEPTION 'Statement line or order not found.'; END IF;
  IF v_line.importer_id IS DISTINCT FROM v_order.importer_id THEN RAISE EXCEPTION 'Importer mismatch.'; END IF;

  v_gap := round(coalesce(public.order_funding_gap_gbp(p_order_id),0)::numeric,2);
  IF v_gap <= 0 OR v_entered <= v_gap THEN
    RAISE EXCEPTION 'Pending surplus requires an entered amount above a positive order gap.';
  END IF;
  v_pending := round(v_entered-v_gap,2);

  v_result := public.staff_reconcile_dva_line_to_order(
    p_dva_statement_line_id,p_order_id,v_gap,false,p_match_suggestion_id,
    concat_ws(E'\n',p_notes,'Residual held neutral pending downstream surplus evidence.')
  );
  v_reconciliation_id := (v_result->>'dva_reconciliation_id')::uuid;

  INSERT INTO public.order_pending_funding_surplus(
    dva_reconciliation_id,dva_statement_line_id,order_id,importer_id,
    entered_gbp_amount,funding_gbp_amount,pending_surplus_gbp,created_by_staff_id,notes
  ) VALUES (
    v_reconciliation_id,p_dva_statement_line_id,p_order_id,v_order.importer_id,
    v_entered,v_gap,v_pending,v_staff.id,p_notes
  ) RETURNING id INTO v_pending_id;

  RETURN v_result || jsonb_build_object(
    'funding_amount_gbp',v_gap,'pending_surplus_gbp',v_pending,
    'pending_surplus_id',v_pending_id,'credit_created_yn',false,'fx_gain_gbp',0
  );
END $$;

REVOKE ALL ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_reconcile_dva_line_to_order_pending_surplus_v1(uuid,uuid,numeric,uuid,text) TO authenticated;

-- Preserve the established v2 column order and types. Only pending-neutral residuals
-- with live funding and downstream evidence replace the legacy calculated surplus.
CREATE OR REPLACE VIEW public.order_surplus_evidence_position_v2 AS
WITH credit AS (
  SELECT source_entity_id AS order_id,
    round(coalesce(sum(CASE WHEN direction='credit' THEN abs(amount_gbp) ELSE -abs(amount_gbp) END),0)::numeric,2) AS credit_created_gbp
  FROM public.importer_credit_ledger
  WHERE source_type IN ('overfunding','settlement_credit') AND source_entity_type='order' AND source_entity_id IS NOT NULL
  GROUP BY source_entity_id
), pending AS (
  SELECT p.order_id, round(sum(p.pending_surplus_gbp)::numeric,2) AS pending_surplus_gbp
  FROM public.order_pending_funding_surplus p
  WHERE p.status IN ('pending_evidence','credit_confirmed')
    AND EXISTS (
      SELECT 1 FROM public.order_funding_events e
      WHERE e.source_entity_type='dva_reconciliation' AND e.source_entity_id=p.dva_reconciliation_id
      GROUP BY e.source_entity_id
      HAVING sum(CASE WHEN e.event_type='funding_reversed' THEN -abs(e.amount_gbp) ELSE e.amount_gbp END) > 0
    )
  GROUP BY p.order_id
)
SELECT v.order_id,v.order_ref,v.importer_id,v.payment_auth_id,v.declared_order_gbp,v.funding_total_gbp,
  v.supplier_out_gbp,v.supplier_out_count,v.posted_invoice_gbp,v.posted_invoice_count,v.draft_invoice_gbp,
  v.draft_invoice_count,greatest(coalesce(v.credit_created_gbp,0),coalesce(c.credit_created_gbp,0))::numeric AS credit_created_gbp,
  v.open_dispute_count,v.active_hold_count,v.evidence_value_gbp,
  CASE WHEN coalesce(p.pending_surplus_gbp,0)>0 AND v.evidence_basis<>'none' THEN p.pending_surplus_gbp ELSE v.evidence_surplus_gbp END::numeric AS evidence_surplus_gbp,
  CASE
    WHEN greatest(coalesce(v.credit_created_gbp,0),coalesce(c.credit_created_gbp,0))>0 THEN 'credit_created'
    WHEN coalesce(p.pending_surplus_gbp,0)>0 AND v.open_dispute_count=0 AND v.active_hold_count=0 AND v.evidence_basis='posted_customer_invoice' THEN 'ready_posted_invoice_surplus'
    WHEN coalesce(p.pending_surplus_gbp,0)>0 AND v.open_dispute_count=0 AND v.active_hold_count=0 AND v.evidence_basis='draft_customer_invoice' THEN 'ready_draft_invoice_surplus'
    WHEN coalesce(p.pending_surplus_gbp,0)>0 AND v.open_dispute_count=0 AND v.active_hold_count=0 AND v.evidence_basis='matched_supplier_out' THEN 'ready_strong_in_out_surplus'
    ELSE v.evidence_status END AS evidence_status,
  v.evidence_basis
FROM public.order_surplus_evidence_position_v1 v
LEFT JOIN credit c ON c.order_id=v.order_id
LEFT JOIN pending p ON p.order_id=v.order_id;
GRANT SELECT ON public.order_surplus_evidence_position_v2 TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(
  p_order_id uuid,p_reason text DEFAULT 'supervisor_confirmed_credit',p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_staff record; v_order record; v_evidence record; v_pending record; v_credit_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  SELECT id,role_type INTO v_staff FROM public.staff WHERE auth_user_id=auth.uid() AND coalesce(active,true)=true LIMIT 1;
  IF v_staff.id IS NULL OR v_staff.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Supervisor/admin required.'; END IF;
  SELECT id,importer_id,coalesce(order_type,'original') order_type INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF v_order.id IS NULL OR v_order.order_type<>'original' THEN RAISE EXCEPTION 'Original order required.'; END IF;

  SELECT * INTO v_pending FROM public.order_pending_funding_surplus
   WHERE order_id=p_order_id AND status IN ('pending_evidence','credit_confirmed') ORDER BY created_at LIMIT 1 FOR UPDATE;
  IF v_pending.status='credit_confirmed' THEN
    RETURN jsonb_build_object('ok',true,'already_confirmed',true,'credit_ledger_id',v_pending.confirmed_credit_ledger_id,'credit_gbp',v_pending.pending_surplus_gbp);
  END IF;
  IF v_pending.id IS NULL THEN RAISE EXCEPTION 'No pending funding surplus for order.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.order_funding_events e
    WHERE e.source_entity_type='dva_reconciliation' AND e.source_entity_id=v_pending.dva_reconciliation_id
    GROUP BY e.source_entity_id
    HAVING sum(CASE WHEN e.event_type='funding_reversed' THEN -abs(e.amount_gbp) ELSE e.amount_gbp END)>0
  ) THEN
    UPDATE public.order_pending_funding_surplus SET status='reversed' WHERE id=v_pending.id;
    RAISE EXCEPTION 'Pending surplus funding has been reversed.';
  END IF;

  SELECT * INTO v_evidence FROM public.order_surplus_evidence_position_v2 WHERE order_id=p_order_id;
  IF v_evidence.evidence_status NOT IN ('ready_posted_invoice_surplus','ready_draft_invoice_surplus','ready_strong_in_out_surplus') THEN RAISE EXCEPTION 'Not ready: %',v_evidence.evidence_status; END IF;
  IF v_evidence.open_dispute_count>0 OR v_evidence.active_hold_count>0 THEN RAISE EXCEPTION 'Open issue blocks confirmation.'; END IF;

  INSERT INTO public.importer_credit_ledger(importer_id,entry_type,source_table,source_id,linked_order_id,direction,
    amount_gbp,amount_local_ccy,local_ccy,effective_at,source_type,source_entity_type,source_entity_id,created_by_staff_id,notes)
  VALUES(v_order.importer_id,'manual_credit','order_pending_funding_surplus',v_pending.id,p_order_id,'credit',
    v_pending.pending_surplus_gbp,v_pending.pending_surplus_gbp,'GBP',now(),'overfunding','order',p_order_id,v_staff.id,
    concat_ws(E'\n',p_reason,p_notes,'Confirmed only after downstream surplus evidence.')) RETURNING id INTO v_credit_id;

  UPDATE public.order_pending_funding_surplus SET status='credit_confirmed',confirmed_credit_ledger_id=v_credit_id,
    confirmed_by_staff_id=v_staff.id,confirmed_at=now() WHERE id=v_pending.id;
  RETURN jsonb_build_object('ok',true,'already_confirmed',false,'credit_ledger_id',v_credit_id,'credit_gbp',v_pending.pending_surplus_gbp,'basis',v_evidence.evidence_basis);
END $$;
REVOKE ALL ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text) TO authenticated;

COMMENT ON TABLE public.order_pending_funding_surplus IS 'Neutral, non-funding, non-FX, non-credit residual recorded after funding exactly an order gap; classified only after downstream evidence.';
NOTIFY pgrst,'reload schema';
COMMIT;
