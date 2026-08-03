-- Align settlement-credit refund audit messages with the existing dispute_messages contract.
-- This changes only generated_by from the rejected supervisor_review value to allowed manual.

BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $preflight$
DECLARE
  v_def text:=pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure);
BEGIN
  IF v_def NOT ILIKE '%resolution_method=''refund''%'
     OR v_def NOT ILIKE '%status=''under_review''%'
     OR v_def NOT ILIKE '%status=''approved_refund''%'
     OR v_def NOT ILIKE '%status=''awaiting_refund_credit''%'
     OR v_def NOT ILIKE '%status=''refunded''%'
     OR v_def NOT ILIKE '%status=''closed''%'
     OR v_def NOT ILIKE '%''supervisor_review''%'
  THEN
    RAISE EXCEPTION 'Expected corrected settlement-credit authority with rejected supervisor_review audit value is not installed.';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.staff_close_refund_exception_as_settlement_credit_v1(
  p_dispute_id uuid,
  p_reason text DEFAULT 'not_charged_closure',
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $function$
DECLARE
  v_staff record;
  v_dispute record;
  v_position record;
  v_reason text;
  v_credit_result jsonb;
  v_amount_delta numeric:=0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user.'; END IF;

  SELECT s.id,s.role_type INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id=auth.uid() AND COALESCE(s.active,true)
  LIMIT 1;

  IF v_staff.id IS NULL THEN RAISE EXCEPTION 'Active staff user not found.'; END IF;
  IF v_staff.role_type NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can close refund exceptions as settlement credit.';
  END IF;

  v_reason:=lower(btrim(COALESCE(p_reason,'not_charged_closure')));
  IF v_reason NOT IN (
    'not_charged_closure','checkout_changed','discount_or_promo',
    'item_removed_before_charge','customer_hold_excluded','supervisor_confirmed_credit'
  ) THEN RAISE EXCEPTION 'Invalid closure reason %.',p_reason; END IF;

  SELECT d.id,d.order_id,d.desired_outcome,d.status,d.amount_impact_gbp,d.resolved_at
  INTO v_dispute
  FROM public.disputes d
  WHERE d.id=p_dispute_id
  FOR UPDATE;

  IF v_dispute.id IS NULL THEN RAISE EXCEPTION 'Dispute not found.'; END IF;
  IF v_dispute.desired_outcome<>'refund' THEN
    RAISE EXCEPTION 'Only refund-intent exceptions can be closed as no-refund settlement credit.';
  END IF;
  IF v_dispute.resolved_at IS NOT NULL THEN RAISE EXCEPTION 'Dispute is already resolved.'; END IF;
  IF v_dispute.status NOT IN ('raised','under_review','approved_refund','awaiting_refund_credit','refunded') THEN
    RAISE EXCEPTION 'Refund exception is not in a closable status. Current status: %',v_dispute.status;
  END IF;

  SELECT * INTO v_position
  FROM public.order_settlement_credit_position_v1 p
  WHERE p.order_id=v_dispute.order_id;

  IF v_position.order_id IS NULL THEN RAISE EXCEPTION 'Order settlement position not found.'; END IF;
  IF v_position.settlement_status<>'credit_due' THEN
    RAISE EXCEPTION 'Order is not in credit_due settlement status. Current status: %',v_position.settlement_status;
  END IF;

  v_amount_delta:=ABS(COALESCE(v_position.funding_less_posted_invoice_gbp,0)-COALESCE(v_dispute.amount_impact_gbp,0));
  IF v_amount_delta>0.01 THEN
    RAISE EXCEPTION 'Exception amount % does not match settlement credit due %.',
      v_dispute.amount_impact_gbp,v_position.funding_less_posted_invoice_gbp;
  END IF;

  UPDATE public.dispute_lines
  SET line_status='resolved',
      conversation_status='resolved_credit',
      resolution_method='refund',
      resolved_at=now()
  WHERE dispute_id=p_dispute_id AND resolved_at IS NULL;

  IF v_dispute.status='raised' THEN
    UPDATE public.disputes SET status='under_review' WHERE id=p_dispute_id;
    v_dispute.status:='under_review';
  END IF;
  IF v_dispute.status='under_review' THEN
    UPDATE public.disputes SET status='approved_refund' WHERE id=p_dispute_id;
    v_dispute.status:='approved_refund';
  END IF;
  IF v_dispute.status='approved_refund' THEN
    UPDATE public.disputes SET status='awaiting_refund_credit' WHERE id=p_dispute_id;
    v_dispute.status:='awaiting_refund_credit';
  END IF;
  IF v_dispute.status='awaiting_refund_credit' THEN
    UPDATE public.disputes SET status='refunded' WHERE id=p_dispute_id;
    v_dispute.status:='refunded';
  END IF;
  IF v_dispute.status='refunded' THEN
    UPDATE public.disputes
    SET status='closed',reviewed_by_staff_id=v_staff.id,reviewed_at=now(),
        resolved_at=now(),refund_settlement_mode='credit_balance'
    WHERE id=p_dispute_id;
  END IF;

  INSERT INTO public.dispute_messages(dispute_id,message_type,counterparty,body,generated_by)
  VALUES(
    p_dispute_id,'supervisor_note','internal',
    CONCAT('[NO_REFUND_SETTLEMENT_CREDIT_V1]',E'\n','reason: ',v_reason,E'\n',
      'credit_due_gbp: ',v_position.funding_less_posted_invoice_gbp,E'\n',
      'notes: ',COALESCE(p_notes,'No notes.')),
    'manual'
  );

  SELECT public.staff_confirm_order_settlement_credit_v1(v_dispute.order_id,v_reason,p_notes)
  INTO v_credit_result;

  RETURN jsonb_build_object(
    'ok',true,'dispute_id',p_dispute_id,'order_id',v_dispute.order_id,
    'reason',v_reason,'credit_result',v_credit_result
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text) TO authenticated;

DO $postflight$
DECLARE
  v_def text:=pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure);
BEGIN
  IF v_def NOT ILIKE '%''manual''%'
     OR v_def ILIKE '%''supervisor_review''%'
     OR v_def NOT ILIKE '%[NO_REFUND_SETTLEMENT_CREDIT_V1]%'
  THEN
    RAISE EXCEPTION 'Settlement-credit refund message audit correction did not install.';
  END IF;
END
$postflight$;

NOTIFY pgrst,'reload schema';
COMMIT;
