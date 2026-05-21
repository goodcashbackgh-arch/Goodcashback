BEGIN;

CREATE OR REPLACE FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(p_order_id uuid, p_reason text DEFAULT 'supervisor_confirmed_credit', p_notes text DEFAULT NULL)
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
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;
  SELECT id, role_type INTO s FROM public.staff WHERE auth_user_id = auth.uid() AND COALESCE(active,true)=true LIMIT 1;
  IF s.id IS NULL OR s.role_type NOT IN ('admin','supervisor') THEN RAISE EXCEPTION 'Supervisor/admin required.'; END IF;
  SELECT id, importer_id, COALESCE(order_type,'original') AS order_type INTO o FROM public.orders WHERE id=p_order_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF o.order_type <> 'original' THEN RAISE EXCEPTION 'Original order required.'; END IF;
  SELECT * INTO e FROM public.order_surplus_evidence_position_v1 WHERE order_id=p_order_id;
  IF e.evidence_status NOT IN ('ready_posted_invoice_surplus','ready_draft_invoice_surplus','ready_strong_in_out_surplus') THEN RAISE EXCEPTION 'Not ready: %', e.evidence_status; END IF;
  IF e.open_dispute_count > 0 OR e.active_hold_count > 0 THEN RAISE EXCEPTION 'Open issue blocks confirmation.'; END IF;
  IF e.evidence_surplus_gbp <= 0 THEN RAISE EXCEPTION 'No surplus.'; END IF;

  INSERT INTO public.importer_credit_ledger(importer_id, entry_type, source_table, source_id, linked_order_id, direction, amount_gbp, amount_local_ccy, local_ccy, effective_at, source_type, source_entity_type, source_entity_id, created_by_staff_id, notes)
  VALUES(o.importer_id, 'manual_credit', 'orders', p_order_id, p_order_id, 'credit', e.evidence_surplus_gbp, e.evidence_surplus_gbp, 'GBP', now(), 'overfunding', 'order', p_order_id, s.id, COALESCE(p_notes,'Surplus confirmed from evidence'))
  ON CONFLICT DO NOTHING
  RETURNING id INTO new_id;

  RETURN jsonb_build_object('ok',true,'credit_ledger_id',new_id,'credit_gbp',e.evidence_surplus_gbp,'basis',e.evidence_basis);
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
