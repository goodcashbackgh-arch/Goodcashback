-- Supplier payment behavioural regression closure Pack B v2
-- Covers:
--   1. Released loyalty only: retailer-labelled OUT -> governed invoice suggestion
--      -> full allocation to the exact paired-released loyalty wallet.
--   2. £100 released loyalty + £300 proven cash -> one £400 retailer OUT/invoice.
--      Suggestion and readiness pass; final allocation fails closed because no one
--      proven source covers the single physical £400 OUT. No artificial split.
-- Safety: isolated UUID fixtures, real governed RPCs, final ROLLBACK, no Sage post.

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE supplier_payment_pack_b_results (
  scenario_no integer PRIMARY KEY,
  scenario text NOT NULL,
  status text NOT NULL CHECK (status IN ('PASS','FAIL')),
  finding text NOT NULL,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb
) ON COMMIT DROP;

CREATE OR REPLACE FUNCTION pg_temp.insert_clone(
  p_table regclass,
  p_template jsonb,
  p_overrides jsonb
) RETURNS void
LANGUAGE plpgsql
AS $fn$
BEGIN
  EXECUTE format(
    'INSERT INTO %s SELECT * FROM jsonb_populate_record(NULL::%s, $1)',
    p_table,
    p_table
  ) USING p_template || p_overrides;
END
$fn$;

DO $pack$
DECLARE
  v_staff_id uuid;
  v_auth_user_id uuid;
  v_template_match record;
  v_template_invoice record;
  v_order_template jsonb;
  v_credit_template jsonb;
  v_approval_template jsonb;
  v_line_template jsonb;
  v_invoice_template jsonb;
  v_retailer_name text;
  v_wallet_code text;
  v_mapping_code text;
  v_next_line_order integer;
  v_suggestion jsonb;
  v_allocation jsonb;
  v_ready boolean;
  v_blocker text;
  v_selectable boolean;
  v_candidate_blocker text;
  v_error text;
  v_count integer;
  v_line_status text;

  s1_order uuid := gen_random_uuid();
  s1_credit uuid := gen_random_uuid();
  s1_debit uuid := gen_random_uuid();
  s1_approval uuid := gen_random_uuid();
  s1_match uuid := gen_random_uuid();
  s1_loyalty_in uuid := gen_random_uuid();
  s1_out uuid := gen_random_uuid();
  s1_invoice uuid := gen_random_uuid();

  s2_order uuid := gen_random_uuid();
  s2_credit uuid := gen_random_uuid();
  s2_debit uuid := gen_random_uuid();
  s2_approval uuid := gen_random_uuid();
  s2_match uuid := gen_random_uuid();
  s2_loyalty_in uuid := gen_random_uuid();
  s2_cash_in uuid := gen_random_uuid();
  s2_cash_recon uuid := gen_random_uuid();
  s2_out uuid := gen_random_uuid();
  s2_invoice uuid := gen_random_uuid();
BEGIN
  IF to_regprocedure('public.staff_generate_supplier_invoice_match_suggestions(uuid,numeric,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_generate_supplier_invoice_match_suggestions';
  END IF;
  IF to_regprocedure('public.internal_supplier_payment_readiness_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_supplier_payment_readiness_v1';
  END IF;
  IF to_regprocedure('public.staff_allocate_statement_line_to_supplier_invoice(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing staff_allocate_statement_line_to_supplier_invoice';
  END IF;
  IF to_regprocedure('public.internal_completion_loyalty_statement_ledger_resolver_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing internal_completion_loyalty_statement_ledger_resolver_v1';
  END IF;
  IF to_regclass('public.supplier_payment_candidate_status_vw') IS NULL THEN
    RAISE EXCEPTION 'Missing supplier_payment_candidate_status_vw';
  END IF;

  SELECT s.id, s.auth_user_id
  INTO v_staff_id, v_auth_user_id
  FROM public.staff s
  WHERE s.active = true
    AND s.auth_user_id IS NOT NULL
    AND s.role_type IN ('admin','supervisor')
  ORDER BY CASE WHEN s.role_type = 'admin' THEN 0 ELSE 1 END, s.created_at, s.id
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'No active admin/supervisor fixture user';
  END IF;
  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);

  SELECT
    lm.*,
    o.retailer_id,
    r.name AS retailer_name,
    to_jsonb(dsl) AS destination_line_json,
    resolver.resolved_wallet_code
  INTO v_template_match
  FROM public.main_bank_completion_loyalty_funding_matches lm
  JOIN public.orders o ON o.id = lm.completed_order_id
  JOIN public.retailers r ON r.id = o.retailer_id
  JOIN public.dva_statement_lines dsl ON dsl.id = lm.destination_in_statement_line_id
  JOIN LATERAL public.internal_completion_loyalty_statement_ledger_resolver_v1(
    lm.destination_in_statement_line_id
  ) resolver
    ON resolver.blocker IS NULL
   AND resolver.resolved_wallet_code IN ('virtual_gbp_wallet','dva_ghs_wallet')
  WHERE lm.match_status = 'released_available_dashboard_credit'
    AND lm.transfer_pair_status = 'paired_released'
    AND lm.credit_ledger_id IS NOT NULL
    AND lm.approval_id IS NOT NULL
    AND length(regexp_replace(lower(coalesce(r.name,'')), '[^a-z0-9]+', '', 'g')) >= 3
    AND EXISTS (
      SELECT 1
      FROM public.supplier_invoices si
      WHERE si.order_id = o.id
        AND si.review_status = 'approved_current'
        AND coalesce(si.ocr_invoice_total_gbp, si.reconciliation_gbp_total) > 0
    )
  ORDER BY lm.created_at DESC, lm.id DESC
  LIMIT 1;

  IF v_template_match.id IS NULL THEN
    RAISE EXCEPTION 'Pack B needs one valid paired-released loyalty order with a retailer and approved invoice';
  END IF;

  SELECT to_jsonb(o) INTO v_order_template
  FROM public.orders o WHERE o.id = v_template_match.completed_order_id;
  SELECT to_jsonb(c) INTO v_credit_template
  FROM public.importer_credit_ledger c WHERE c.id = v_template_match.credit_ledger_id;
  SELECT to_jsonb(a) INTO v_approval_template
  FROM public.completion_loyalty_reward_approvals a WHERE a.id = v_template_match.approval_id;
  SELECT si.*, to_jsonb(si) AS invoice_json INTO v_template_invoice
  FROM public.supplier_invoices si
  WHERE si.order_id = v_template_match.completed_order_id
    AND si.review_status = 'approved_current'
    AND coalesce(si.ocr_invoice_total_gbp, si.reconciliation_gbp_total) > 0
  ORDER BY si.reviewed_at DESC NULLS LAST, si.created_at DESC NULLS LAST, si.id DESC
  LIMIT 1;

  v_line_template := v_template_match.destination_line_json;
  v_invoice_template := v_template_invoice.invoice_json;
  v_retailer_name := v_template_match.retailer_name;
  v_wallet_code := v_template_match.resolved_wallet_code;
  v_mapping_code := CASE v_wallet_code
    WHEN 'virtual_gbp_wallet' THEN 'LOYALTY_VIRTUAL_GBP_BANK_ACCOUNT'
    WHEN 'dva_ghs_wallet' THEN 'LOYALTY_DVA_GHS_BANK_ACCOUNT'
  END;

  IF v_order_template IS NULL OR v_credit_template IS NULL
     OR v_approval_template IS NULL OR v_line_template IS NULL
     OR v_invoice_template IS NULL OR v_mapping_code IS NULL THEN
    RAISE EXCEPTION 'Incomplete Pack B template';
  END IF;

  SELECT coalesce(max(line_order),0) + 1000 INTO v_next_line_order
  FROM public.dva_statement_lines
  WHERE dva_statement_id = (v_line_template->>'dva_statement_id')::uuid;

  -----------------------------------------------------------------------------
  -- Scenario 1: pure released loyalty, £100.
  -----------------------------------------------------------------------------
  PERFORM pg_temp.insert_clone('public.orders', v_order_template, jsonb_build_object(
    'id', s1_order, 'order_ref', 'REG-PACK-B-LOY-' || left(s1_order::text,8),
    'payment_auth_id', 'AUTH-PACK-B-LOY-' || left(s1_order::text,8),
    'order_type', 'original', 'order_total_gbp_declared', 100.00,
    'funded_at', now(), 'status', 'evidence_collecting',
    'created_at', now(), 'updated_at', now(), 'completed_at', null
  ));

  PERFORM pg_temp.insert_clone('public.dva_statement_lines', v_line_template, jsonb_build_object(
    'id', s1_loyalty_in, 'line_order', v_next_line_order, 'statement_date', current_date,
    'direction', 'in', 'amount_local_ccy', 100.00, 'amount_gbp_equivalent', 100.00,
    'auth_id_ref', 'AUTH-PACK-B-LOY-' || left(s1_order::text,8),
    'retailer_name_ref', null, 'reference_raw', 'IN PACK B LOYALTY',
    'match_status', 'confirmed', 'created_at', now()
  ));

  PERFORM pg_temp.insert_clone('public.importer_credit_ledger', v_credit_template, jsonb_build_object(
    'id', s1_credit, 'importer_id', v_template_match.importer_id,
    'entry_type', 'manual_credit', 'source_table', 'completion_loyalty_reward_funding_confirmations',
    'source_id', gen_random_uuid(), 'linked_order_id', s1_order, 'linked_dispute_id', null,
    'direction', 'credit', 'amount_gbp', 100.00, 'amount_local_ccy', 100.00,
    'local_ccy', 'GBP', 'source_type', 'completion_loyalty_reward',
    'source_entity_type', 'order', 'source_entity_id', s1_order,
    'applied_to_order_id', null, 'lock_reason', null,
    'created_by_staff_id', v_staff_id, 'effective_at', now(), 'created_at', now(),
    'notes', 'Pack B v2 scenario 1 loyalty source lot'
  ));

  PERFORM pg_temp.insert_clone('public.completion_loyalty_reward_approvals', v_approval_template, jsonb_build_object(
    'id', s1_approval, 'order_id', s1_order, 'importer_id', v_template_match.importer_id,
    'approved_by_staff_id', v_staff_id, 'qualifying_signed_gross_basis_gbp', 100.00,
    'qualifying_net_spend_gbp', 100.00, 'suggested_reward_gbp', 100.00,
    'approved_amount_gbp', 100.00, 'credit_ledger_id', s1_credit,
    'approval_status', 'released_available_dashboard_credit', 'funding_confirmation_id', null,
    'created_at', now(), 'updated_at', now(), 'notes', 'Pack B v2 scenario 1 approval'
  ));

  INSERT INTO public.main_bank_completion_loyalty_funding_matches (
    id, dva_statement_line_id, completed_order_id, importer_id, approval_id,
    funding_confirmation_id, credit_ledger_id, matched_gbp_amount, match_status,
    notes, created_by_staff_id, created_by_auth_user_id, created_at,
    destination_in_statement_line_id, activation_route, card_used_by,
    transfer_pair_status, paired_at, paired_by_staff_id, paired_by_auth_user_id, variance_gbp
  ) VALUES (
    s1_match, v_template_match.dva_statement_line_id, s1_order, v_template_match.importer_id,
    s1_approval, null, s1_credit, 100.00, 'released_available_dashboard_credit',
    'Pack B v2 scenario 1 paired release', v_staff_id, v_auth_user_id, now(),
    s1_loyalty_in, coalesce(v_template_match.activation_route,'dva_account_top_up'),
    coalesce(v_template_match.card_used_by,'staff'), 'paired_released', now(),
    v_staff_id, v_auth_user_id, 0
  );

  PERFORM pg_temp.insert_clone('public.importer_credit_ledger', v_credit_template, jsonb_build_object(
    'id', s1_debit, 'importer_id', v_template_match.importer_id,
    'entry_type', 'applied_to_order', 'source_table', 'importer_credit_ledger',
    'source_id', s1_credit, 'linked_order_id', s1_order, 'linked_dispute_id', null,
    'direction', 'debit', 'amount_gbp', 100.00, 'amount_local_ccy', 100.00,
    'local_ccy', 'GBP', 'source_type', 'credit_application',
    'source_entity_type', 'importer_credit_ledger', 'source_entity_id', s1_credit,
    'applied_to_order_id', s1_order, 'lock_reason', null,
    'created_by_staff_id', v_staff_id, 'effective_at', now(), 'created_at', now(),
    'notes', 'Pack B v2 scenario 1 exact application debit'
  ));

  INSERT INTO public.order_funding_events (
    order_id,event_type,amount_gbp,source_ref,source_entity_type,source_entity_id,
    created_by_staff_id,created_at,notes
  ) SELECT s1_order,'credit_applied',100.00,'importer_credit_ledger:'||s1_debit,
    'importer_credit_ledger',s1_debit,v_staff_id,now(),'Pack B v2 fallback event'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.order_funding_events
    WHERE event_type='credit_applied' AND source_entity_type='importer_credit_ledger'
      AND source_entity_id=s1_debit
  );

  PERFORM pg_temp.insert_clone('public.supplier_invoices', v_invoice_template, jsonb_build_object(
    'id', s1_invoice, 'order_id', s1_order, 'retailer_id', v_template_match.retailer_id,
    'invoice_ref', 'REG-PACK-B-LOY-INV-'||left(s1_invoice::text,8),
    'ocr_invoice_ref', 'REG-PACK-B-LOY-INV-'||left(s1_invoice::text,8),
    'ocr_invoice_total_gbp', 100.00, 'reconciliation_gbp_total', 100.00,
    'review_status', 'approved_current', 'blocked_from_sage_yn', false,
    'is_current_for_order', true, 'reviewed_by_staff_id', v_staff_id,
    'reviewed_at', now(), 'uploaded_at', now(), 'review_notes', 'Pack B v2 scenario 1 invoice'
  ));

  PERFORM pg_temp.insert_clone('public.dva_statement_lines', v_line_template, jsonb_build_object(
    'id', s1_out, 'line_order', v_next_line_order+1, 'statement_date', current_date,
    'direction', 'out', 'amount_local_ccy', 100.00, 'amount_gbp_equivalent', 100.00,
    'auth_id_ref', 'AUTH-PACK-B-LOY-'||left(s1_order::text,8),
    'retailer_name_ref', v_retailer_name,
    'reference_raw', v_retailer_name||' CARD PURCHASE PACK B LOYALTY',
    'match_status', 'unmatched', 'created_at', now()
  ));

  SELECT selectable_yn, blocker INTO v_selectable, v_candidate_blocker
  FROM public.supplier_payment_candidate_status_vw WHERE supplier_invoice_id=s1_invoice;
  IF v_selectable IS DISTINCT FROM true OR v_candidate_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Scenario 1 candidate blocked: %', v_candidate_blocker;
  END IF;

  v_suggestion := public.staff_generate_supplier_invoice_match_suggestions(s1_out,0.01,3);
  SELECT count(*)::integer INTO v_count FROM public.match_suggestions
  WHERE dva_statement_line_id=s1_out AND suggested_match_type='supplier_invoice'
    AND suggested_match_id=s1_invoice;
  SELECT match_status INTO v_line_status FROM public.dva_statement_lines WHERE id=s1_out;
  IF v_count<>1 OR v_line_status IS DISTINCT FROM 'suggested' THEN
    RAISE EXCEPTION 'Scenario 1 suggestion failed: count %, status %, rpc %',v_count,v_line_status,v_suggestion;
  END IF;

  SELECT supplier_payment_ready_yn, blocker INTO v_ready,v_blocker
  FROM public.internal_supplier_payment_readiness_v1(s1_order);
  IF v_ready IS DISTINCT FROM true OR v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Scenario 1 readiness failed: %',v_blocker;
  END IF;

  v_allocation := public.staff_allocate_statement_line_to_supplier_invoice(
    s1_out,s1_invoice,100.00,'Pack B v2 scenario 1 full physical OUT'
  );
  IF coalesce(v_allocation->>'source_bank_account_mapping_code','')<>v_mapping_code
     OR coalesce(v_allocation->>'source_wallet_code','')<>v_wallet_code
     OR coalesce(v_allocation->>'source_resolution_reason','')<>'exact_remaining_released_loyalty_source'
     OR coalesce((v_allocation->>'supplier_invoice_fully_allocated_yn')::boolean,false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Scenario 1 wrong allocation result: %',v_allocation;
  END IF;

  INSERT INTO supplier_payment_pack_b_results VALUES (
    1,'Released loyalty retailer match','PASS',
    'Retailer-labelled £100 OUT suggested the same-retailer invoice and resolved fully to the exact paired-released loyalty wallet.',
    jsonb_build_object('retailer',v_retailer_name,'suggestion',v_suggestion,'allocation',v_allocation)
  );

  -----------------------------------------------------------------------------
  -- Scenario 2: £100 loyalty + £300 cash, one £400 physical OUT.
  -----------------------------------------------------------------------------
  PERFORM pg_temp.insert_clone('public.orders', v_order_template, jsonb_build_object(
    'id',s2_order,'order_ref','REG-PACK-B-MIX-'||left(s2_order::text,8),
    'payment_auth_id','AUTH-PACK-B-MIX-'||left(s2_order::text,8),
    'order_type','original','order_total_gbp_declared',400.00,'funded_at',now(),
    'status','evidence_collecting','created_at',now(),'updated_at',now(),'completed_at',null
  ));

  PERFORM pg_temp.insert_clone('public.dva_statement_lines', v_line_template, jsonb_build_object(
    'id',s2_loyalty_in,'line_order',v_next_line_order+2,'statement_date',current_date,
    'direction','in','amount_local_ccy',100.00,'amount_gbp_equivalent',100.00,
    'auth_id_ref','AUTH-PACK-B-MIX-'||left(s2_order::text,8),'retailer_name_ref',null,
    'reference_raw','IN PACK B MIXED LOYALTY','match_status','confirmed','created_at',now()
  ));

  PERFORM pg_temp.insert_clone('public.importer_credit_ledger', v_credit_template, jsonb_build_object(
    'id',s2_credit,'importer_id',v_template_match.importer_id,'entry_type','manual_credit',
    'source_table','completion_loyalty_reward_funding_confirmations','source_id',gen_random_uuid(),
    'linked_order_id',s2_order,'linked_dispute_id',null,'direction','credit',
    'amount_gbp',100.00,'amount_local_ccy',100.00,'local_ccy','GBP',
    'source_type','completion_loyalty_reward','source_entity_type','order','source_entity_id',s2_order,
    'applied_to_order_id',null,'lock_reason',null,'created_by_staff_id',v_staff_id,
    'effective_at',now(),'created_at',now(),'notes','Pack B v2 scenario 2 loyalty source lot'
  ));

  PERFORM pg_temp.insert_clone('public.completion_loyalty_reward_approvals', v_approval_template, jsonb_build_object(
    'id',s2_approval,'order_id',s2_order,'importer_id',v_template_match.importer_id,
    'approved_by_staff_id',v_staff_id,'qualifying_signed_gross_basis_gbp',100.00,
    'qualifying_net_spend_gbp',100.00,'suggested_reward_gbp',100.00,'approved_amount_gbp',100.00,
    'credit_ledger_id',s2_credit,'approval_status','released_available_dashboard_credit',
    'funding_confirmation_id',null,'created_at',now(),'updated_at',now(),'notes','Pack B v2 scenario 2 approval'
  ));

  INSERT INTO public.main_bank_completion_loyalty_funding_matches (
    id,dva_statement_line_id,completed_order_id,importer_id,approval_id,funding_confirmation_id,
    credit_ledger_id,matched_gbp_amount,match_status,notes,created_by_staff_id,created_by_auth_user_id,
    created_at,destination_in_statement_line_id,activation_route,card_used_by,transfer_pair_status,
    paired_at,paired_by_staff_id,paired_by_auth_user_id,variance_gbp
  ) VALUES (
    s2_match,v_template_match.dva_statement_line_id,s2_order,v_template_match.importer_id,
    s2_approval,null,s2_credit,100.00,'released_available_dashboard_credit',
    'Pack B v2 scenario 2 paired release',v_staff_id,v_auth_user_id,now(),s2_loyalty_in,
    coalesce(v_template_match.activation_route,'dva_account_top_up'),
    coalesce(v_template_match.card_used_by,'staff'),'paired_released',now(),
    v_staff_id,v_auth_user_id,0
  );

  PERFORM pg_temp.insert_clone('public.importer_credit_ledger', v_credit_template, jsonb_build_object(
    'id',s2_debit,'importer_id',v_template_match.importer_id,'entry_type','applied_to_order',
    'source_table','importer_credit_ledger','source_id',s2_credit,'linked_order_id',s2_order,
    'linked_dispute_id',null,'direction','debit','amount_gbp',100.00,'amount_local_ccy',100.00,
    'local_ccy','GBP','source_type','credit_application','source_entity_type','importer_credit_ledger',
    'source_entity_id',s2_credit,'applied_to_order_id',s2_order,'lock_reason',null,
    'created_by_staff_id',v_staff_id,'effective_at',now(),'created_at',now(),
    'notes','Pack B v2 scenario 2 exact loyalty application debit'
  ));

  INSERT INTO public.order_funding_events (
    order_id,event_type,amount_gbp,source_ref,source_entity_type,source_entity_id,
    created_by_staff_id,created_at,notes
  ) SELECT s2_order,'credit_applied',100.00,'importer_credit_ledger:'||s2_debit,
    'importer_credit_ledger',s2_debit,v_staff_id,now(),'Pack B v2 fallback loyalty event'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.order_funding_events
    WHERE event_type='credit_applied' AND source_entity_type='importer_credit_ledger'
      AND source_entity_id=s2_debit
  );

  PERFORM pg_temp.insert_clone('public.dva_statement_lines', v_line_template, jsonb_build_object(
    'id',s2_cash_in,'line_order',v_next_line_order+3,'statement_date',current_date,
    'direction','in','amount_local_ccy',300.00,'amount_gbp_equivalent',300.00,
    'auth_id_ref','AUTH-PACK-B-MIX-'||left(s2_order::text,8),'retailer_name_ref',null,
    'reference_raw','IN PACK B MIXED CASH','match_status','confirmed','created_at',now()
  ));

  INSERT INTO public.dva_reconciliation (
    id,dva_statement_line_id,reconciliation_type,order_id,supplier_invoice_id,dispute_id,
    reconciled_gbp_amount,reconciled_by_staff_id,reconciled_at,notes
  ) VALUES (
    s2_cash_recon,s2_cash_in,'order_funding',s2_order,null,null,300.00,
    v_staff_id,now(),'Pack B v2 scenario 2 proven £300 cash leg'
  );

  INSERT INTO public.order_funding_events (
    order_id,event_type,amount_gbp,source_ref,source_entity_type,source_entity_id,
    created_by_staff_id,created_at,notes
  ) SELECT s2_order,'funding_contribution',300.00,'dva_reconciliation:'||s2_cash_recon,
    'dva_reconciliation',s2_cash_recon,v_staff_id,now(),'Pack B v2 fallback cash event'
  WHERE NOT EXISTS (
    SELECT 1 FROM public.order_funding_events
    WHERE event_type='funding_contribution' AND source_entity_type='dva_reconciliation'
      AND source_entity_id=s2_cash_recon
  );

  PERFORM pg_temp.insert_clone('public.supplier_invoices', v_invoice_template, jsonb_build_object(
    'id',s2_invoice,'order_id',s2_order,'retailer_id',v_template_match.retailer_id,
    'invoice_ref','REG-PACK-B-MIX-INV-'||left(s2_invoice::text,8),
    'ocr_invoice_ref','REG-PACK-B-MIX-INV-'||left(s2_invoice::text,8),
    'ocr_invoice_total_gbp',400.00,'reconciliation_gbp_total',400.00,
    'review_status','approved_current','blocked_from_sage_yn',false,'is_current_for_order',true,
    'reviewed_by_staff_id',v_staff_id,'reviewed_at',now(),'uploaded_at',now(),
    'review_notes','Pack B v2 scenario 2 £400 invoice'
  ));

  PERFORM pg_temp.insert_clone('public.dva_statement_lines', v_line_template, jsonb_build_object(
    'id',s2_out,'line_order',v_next_line_order+4,'statement_date',current_date,
    'direction','out','amount_local_ccy',400.00,'amount_gbp_equivalent',400.00,
    'auth_id_ref','AUTH-PACK-B-MIX-'||left(s2_order::text,8),'retailer_name_ref',v_retailer_name,
    'reference_raw',v_retailer_name||' CARD PURCHASE PACK B MIXED','match_status','unmatched','created_at',now()
  ));

  SELECT selectable_yn,blocker INTO v_selectable,v_candidate_blocker
  FROM public.supplier_payment_candidate_status_vw WHERE supplier_invoice_id=s2_invoice;
  IF v_selectable IS DISTINCT FROM true OR v_candidate_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Scenario 2 candidate blocked: %',v_candidate_blocker;
  END IF;

  v_suggestion := public.staff_generate_supplier_invoice_match_suggestions(s2_out,0.01,3);
  SELECT count(*)::integer INTO v_count FROM public.match_suggestions
  WHERE dva_statement_line_id=s2_out AND suggested_match_type='supplier_invoice'
    AND suggested_match_id=s2_invoice;
  SELECT match_status INTO v_line_status FROM public.dva_statement_lines WHERE id=s2_out;
  IF v_count<>1 OR v_line_status IS DISTINCT FROM 'suggested' THEN
    RAISE EXCEPTION 'Scenario 2 suggestion failed: count %, status %, rpc %',v_count,v_line_status,v_suggestion;
  END IF;

  SELECT supplier_payment_ready_yn,blocker INTO v_ready,v_blocker
  FROM public.internal_supplier_payment_readiness_v1(s2_order);
  IF v_ready IS DISTINCT FROM true OR v_blocker IS NOT NULL THEN
    RAISE EXCEPTION 'Scenario 2 readiness failed: %',v_blocker;
  END IF;

  v_error := null;
  BEGIN
    PERFORM public.staff_allocate_statement_line_to_supplier_invoice(
      s2_out,s2_invoice,400.00,'Pack B v2 one £400 OUT must not be split or guessed'
    );
    RAISE EXCEPTION 'Scenario 2 unexpectedly allocated mixed-funded £400 OUT';
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
    IF position('source_funding_required_for_supplier_payment_bank_resolution' in v_error)=0 THEN
      RAISE EXCEPTION 'Scenario 2 wrong blocker: %',v_error;
    END IF;
  END;

  SELECT count(*)::integer INTO v_count
  FROM public.dva_statement_line_allocations
  WHERE dva_statement_line_id=s2_out AND allocation_status<>'reversed';
  IF v_count<>0 THEN
    RAISE EXCEPTION 'Scenario 2 wrote % active allocation rows',v_count;
  END IF;

  INSERT INTO supplier_payment_pack_b_results VALUES (
    2,'£100 loyalty + £300 cash, one £400 retailer OUT','PASS',
    'Retailer/amount/date matching found the £400 invoice and readiness accepted both proven legs. Final allocation failed closed because neither source alone covered the one £400 OUT; no £100/£300 supplier-payment split or cash default was written.',
    jsonb_build_object('retailer',v_retailer_name,'suggestion',v_suggestion,
      'expected_error',v_error,'active_allocations_after_failure',v_count)
  );
END
$pack$;

SELECT scenario_no,scenario,status,finding,evidence
FROM supplier_payment_pack_b_results
ORDER BY scenario_no;

DO $assert$
DECLARE v_pass_count integer;
BEGIN
  SELECT count(*) INTO v_pass_count FROM supplier_payment_pack_b_results WHERE status='PASS';
  IF v_pass_count<>2 THEN
    RAISE EXCEPTION 'Pack B incomplete: expected 2 PASS rows, found %',v_pass_count;
  END IF;
END
$assert$;

ROLLBACK;
