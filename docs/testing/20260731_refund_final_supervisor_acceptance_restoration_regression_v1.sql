BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_normalized_definition text;
  v_prosecdef boolean;
  v_proconfig text[];
  v_count integer;
  v_dispute_id uuid;
  v_importer_id uuid;
  v_auth_uid uuid;
  v_parent_status_before text;
  v_parent_status_after text;
  v_message_count_before integer;
  v_message_count_after integer;
  v_active_line_count integer;
  v_accepted_line_count integer;
  v_rpc_result jsonb;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. Lock the corrective RPC contract and blast radius.
  -- -------------------------------------------------------------------------
  IF to_regprocedure('public.operator_update_dispute_retailer_update(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: operator_update_dispute_retailer_update(uuid,text,text) is missing.';
  END IF;

  SELECT
    lower(pg_get_functiondef(p.oid)),
    p.prosecdef,
    p.proconfig
  INTO
    v_definition,
    v_prosecdef,
    v_proconfig
  FROM pg_proc p
  WHERE p.oid = 'public.operator_update_dispute_retailer_update(uuid,text,text)'::regprocedure;

  v_normalized_definition := regexp_replace(v_definition, '\s+', ' ', 'g');

  IF NOT COALESCE(v_prosecdef, false) THEN
    RAISE EXCEPTION 'FAIL: retailer-update RPC is no longer SECURITY DEFINER.';
  END IF;

  IF NOT COALESCE(v_proconfig, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'FAIL: retailer-update RPC search_path boundary changed: %', v_proconfig;
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.operator_update_dispute_retailer_update(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated role lost EXECUTE on retailer-update RPC.';
  END IF;

  IF has_function_privilege('anon', 'public.operator_update_dispute_retailer_update(uuid,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon role unexpectedly has EXECUTE on retailer-update RPC.';
  END IF;

  IF position('when ''still_waiting'' then ''retailer_contacted''' IN v_normalized_definition) = 0
     OR position('when ''retailer_accepted'' then ''retailer_response_received''' IN v_normalized_definition) = 0
     OR position('when ''retailer_disputed'' then ''awaiting_retailer_resolution''' IN v_normalized_definition) = 0
     OR position('when ''more_info_requested'' then ''retailer_draft_ready''' IN v_normalized_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: existing retailer outcome conversation-status mapping changed.';
  END IF;

  IF position('insert into public.dispute_messages' IN v_normalized_definition) = 0
     OR position('''retailer_reply''' IN v_definition) = 0
     OR position('update public.dispute_lines set conversation_status = v_status' IN v_normalized_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: retailer reply or dispute-line conversation update contract changed.';
  END IF;

  IF position('update public.disputes' IN v_normalized_definition) > 0
     OR position('set status = ''awaiting_refund_credit''' IN v_normalized_definition) > 0
  THEN
    RAISE EXCEPTION 'FAIL: operator/importer retailer-update RPC still contains parent dispute status advancement.';
  END IF;

  IF position('''advanced_to_refund_evidence'', v_advanced_to_refund_evidence' IN v_normalized_definition) = 0
     OR position('v_advanced_to_refund_evidence boolean := false' IN v_normalized_definition) = 0
  THEN
    RAISE EXCEPTION 'FAIL: existing retailer-update return payload compatibility changed.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. Lock the legal supervisor refund status spine.
  -- -------------------------------------------------------------------------
  SELECT count(*)::integer
  INTO v_count
  FROM public.status_transitions
  WHERE entity_type = 'dispute'
    AND active = true
    AND (
      (from_status = 'raised' AND to_status = 'under_review')
      OR (from_status = 'under_review' AND to_status = 'approved_refund')
      OR (from_status = 'approved_refund' AND to_status = 'awaiting_refund_credit')
    );

  IF v_count <> 3 THEN
    RAISE EXCEPTION 'FAIL: legal supervisor refund status spine is incomplete; expected 3 active transitions, found %.', v_count;
  END IF;

  SELECT count(*)::integer
  INTO v_count
  FROM public.status_transitions
  WHERE entity_type = 'dispute'
    AND active = true
    AND from_status = 'raised'
    AND to_status = 'awaiting_refund_credit';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: illegal direct raised -> awaiting_refund_credit transition has been introduced.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 3. Execute the real operator/importer accepted-retailer path against an
  --    existing eligible refund dispute. All writes are rolled back below.
  -- -------------------------------------------------------------------------
  SELECT d.id, o.importer_id, d.status::text
  INTO v_dispute_id, v_importer_id, v_parent_status_before
  FROM public.disputes d
  JOIN public.orders o ON o.id = d.order_id
  WHERE d.desired_outcome::text = 'refund'
    AND d.refund_approved_at IS NOT NULL
    AND d.status::text = 'raised'
    AND EXISTS (
      SELECT 1
      FROM public.dispute_lines dl
      WHERE dl.dispute_id = d.id
        AND dl.resolved_at IS NULL
    )
    AND EXISTS (
      SELECT 1
      FROM public.operator_importers oi
      JOIN public.operators op ON op.id = oi.operator_id
      WHERE oi.importer_id = o.importer_id
        AND oi.revoked_at IS NULL
        AND op.active = true
        AND op.auth_user_id IS NOT NULL
    )
  ORDER BY d.id
  LIMIT 1
  FOR UPDATE OF d;

  IF v_dispute_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: no eligible supervisor-approved raised refund dispute is available for live-path regression.';
  END IF;

  SELECT op.auth_user_id
  INTO v_auth_uid
  FROM public.operator_importers oi
  JOIN public.operators op ON op.id = oi.operator_id
  WHERE oi.importer_id = v_importer_id
    AND oi.revoked_at IS NULL
    AND op.active = true
    AND op.auth_user_id IS NOT NULL
  ORDER BY op.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: eligible dispute importer has no active linked operator auth user.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);

  IF auth.uid() IS DISTINCT FROM v_auth_uid THEN
    RAISE EXCEPTION 'FAIL: unable to establish linked operator auth context.';
  END IF;

  SELECT count(*)::integer
  INTO v_message_count_before
  FROM public.dispute_messages dm
  WHERE dm.dispute_id = v_dispute_id
    AND dm.message_type = 'retailer_reply'
    AND dm.counterparty = 'retailer';

  SELECT count(*)::integer
  INTO v_active_line_count
  FROM public.dispute_lines dl
  WHERE dl.dispute_id = v_dispute_id
    AND dl.resolved_at IS NULL;

  SELECT public.operator_update_dispute_retailer_update(
    v_dispute_id,
    '[REGRESSION_ONLY] retailer accepted refund/remedy',
    'retailer_accepted'
  )
  INTO v_rpc_result;

  IF COALESCE((v_rpc_result ->> 'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: retailer-update RPC did not return ok=true: %', v_rpc_result;
  END IF;

  IF v_rpc_result ->> 'conversation_status' IS DISTINCT FROM 'retailer_response_received' THEN
    RAISE EXCEPTION 'FAIL: retailer accepted did not return retailer_response_received: %', v_rpc_result;
  END IF;

  IF COALESCE((v_rpc_result ->> 'advanced_to_refund_evidence')::boolean, false) IS TRUE THEN
    RAISE EXCEPTION 'FAIL: operator/importer RPC still reports automatic refund-evidence advancement: %', v_rpc_result;
  END IF;

  SELECT d.status::text
  INTO v_parent_status_after
  FROM public.disputes d
  WHERE d.id = v_dispute_id;

  IF v_parent_status_after IS DISTINCT FROM v_parent_status_before
     OR v_parent_status_after IS DISTINCT FROM 'raised'
  THEN
    RAISE EXCEPTION 'FAIL: operator/importer retailer acceptance changed parent dispute status from % to %.', v_parent_status_before, v_parent_status_after;
  END IF;

  SELECT count(*)::integer
  INTO v_accepted_line_count
  FROM public.dispute_lines dl
  WHERE dl.dispute_id = v_dispute_id
    AND dl.resolved_at IS NULL
    AND dl.conversation_status::text = 'retailer_response_received';

  IF v_accepted_line_count <> v_active_line_count THEN
    RAISE EXCEPTION 'FAIL: accepted retailer outcome updated % of % active dispute lines.', v_accepted_line_count, v_active_line_count;
  END IF;

  SELECT count(*)::integer
  INTO v_message_count_after
  FROM public.dispute_messages dm
  WHERE dm.dispute_id = v_dispute_id
    AND dm.message_type = 'retailer_reply'
    AND dm.counterparty = 'retailer';

  IF v_message_count_after <> v_message_count_before + 1 THEN
    RAISE EXCEPTION 'FAIL: retailer reply count expected %, got %.', v_message_count_before + 1, v_message_count_after;
  END IF;

  -- Existing supervisor-button prerequisites are now present at the data layer:
  -- at least one retailer reply and every active line marked accepted.
  IF v_message_count_after < 1 OR v_accepted_line_count <> v_active_line_count THEN
    RAISE EXCEPTION 'FAIL: supervisor final-acceptance prerequisites were not established.';
  END IF;

  -- -------------------------------------------------------------------------
  -- 4. Execute the exact legal status sequence used by the existing supervisor
  --    final-acceptance action. The transition trigger remains active.
  -- -------------------------------------------------------------------------
  UPDATE public.disputes
  SET status = 'under_review'
  WHERE id = v_dispute_id
    AND status::text = 'raised';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: raised -> under_review supervisor transition did not execute.';
  END IF;

  UPDATE public.disputes
  SET status = 'approved_refund'
  WHERE id = v_dispute_id
    AND status::text = 'under_review';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: under_review -> approved_refund supervisor transition did not execute.';
  END IF;

  UPDATE public.disputes
  SET status = 'awaiting_refund_credit'
  WHERE id = v_dispute_id
    AND status::text = 'approved_refund';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: approved_refund -> awaiting_refund_credit supervisor transition did not execute.';
  END IF;

  SELECT d.status::text
  INTO v_parent_status_after
  FROM public.disputes d
  WHERE d.id = v_dispute_id;

  IF v_parent_status_after IS DISTINCT FROM 'awaiting_refund_credit' THEN
    RAISE EXCEPTION 'FAIL: legal supervisor sequence ended at %, expected awaiting_refund_credit.', v_parent_status_after;
  END IF;
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'real operator/importer retailer acceptance saves one retailer reply, marks all active dispute lines retailer_response_received, leaves the parent refund dispute at raised, and reports no automatic evidence advancement; with the existing transition guard still active, the supervisor legal sequence then succeeds raised -> under_review -> approved_refund -> awaiting_refund_credit; all test writes roll back'
) AS regression_result;

ROLLBACK;
