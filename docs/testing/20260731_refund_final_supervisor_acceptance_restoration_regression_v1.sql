BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $regression$
DECLARE
  v_definition text;
  v_normalized_definition text;
  v_prosecdef boolean;
  v_proconfig text[];
  v_count integer;
BEGIN
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
END;
$regression$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'operator/importer retailer update preserves auth, reply storage, line conversation mappings and return payload compatibility; it contains no parent dispute status advancement; legal supervisor refund spine remains raised -> under_review -> approved_refund -> awaiting_refund_credit; direct raised -> awaiting_refund_credit remains forbidden'
) AS regression_result;

ROLLBACK;
