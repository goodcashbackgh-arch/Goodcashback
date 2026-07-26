-- Rollback-safe regression for supervisor supplier-invoice rejection classification.
-- Run after 20260726z_supervisor_supplier_invoice_rejection_classification_v1.sql.
-- Every fixture and production-RPC write is contained in this transaction.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $contract$
DECLARE
  v_count integer;
  v_default_count integer;
  v_arg_names text[];
  v_result text;
  v_definition text;
BEGIN
  SELECT COUNT(*)::integer
    INTO v_count
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'supplier_invoices'
    AND c.column_name = 'rejection_requires_resubmission_yn'
    AND c.data_type = 'boolean'
    AND c.is_nullable = 'YES';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: supplier_invoices.rejection_requires_resubmission_yn is missing, non-boolean or non-nullable';
  END IF;

  IF to_regprocedure('public.staff_reject_supplier_invoice_resubmission(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: existing rejection RPC signature staff_reject_supplier_invoice_resubmission(uuid,text) is missing';
  END IF;

  SELECT COUNT(*)::integer
    INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'staff_reject_supplier_invoice_resubmission';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: existing rejection RPC has % public overload(s), expected exactly one unchanged signature', v_count;
  END IF;

  SELECT p.pronargdefaults, p.proargnames, pg_get_function_result(p.oid)
    INTO v_default_count, v_arg_names, v_result
  FROM pg_proc p
  WHERE p.oid = 'public.staff_reject_supplier_invoice_resubmission(uuid,text)'::regprocedure;

  IF v_default_count <> 1
     OR v_arg_names[1] IS DISTINCT FROM 'p_supplier_invoice_id'
     OR v_arg_names[2] IS DISTINCT FROM 'p_review_notes'
     OR lower(v_result) IS DISTINCT FROM 'table(order_id uuid)' THEN
    RAISE EXCEPTION
      'FAIL: existing rejection RPC contract changed: defaults %, args %, result %',
      v_default_count,
      v_arg_names,
      v_result;
  END IF;

  IF to_regprocedure('public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: exclusion RPC signature staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text) is missing';
  END IF;

  SELECT COUNT(*)::integer
    INTO v_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'staff_exclude_supplier_invoice_no_resubmission_v1';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: exclusion RPC has % public overload(s), expected exactly one intended signature', v_count;
  END IF;

  SELECT p.pronargdefaults, p.proargnames, pg_get_function_result(p.oid)
    INTO v_default_count, v_arg_names, v_result
  FROM pg_proc p
  WHERE p.oid = 'public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text)'::regprocedure;

  IF v_default_count <> 0
     OR v_arg_names[1] IS DISTINCT FROM 'p_supplier_invoice_id'
     OR v_arg_names[2] IS DISTINCT FROM 'p_review_notes'
     OR lower(v_result) IS DISTINCT FROM 'table(order_id uuid)' THEN
    RAISE EXCEPTION
      'FAIL: exclusion RPC contract is wrong: defaults %, args %, result %',
      v_default_count,
      v_arg_names,
      v_result;
  END IF;

  IF to_regprocedure('public.internal_classify_supplier_invoice_rejection_v1(uuid,boolean,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: shared rejection-classification helper is missing';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL aclexplode(
      COALESCE(p.proacl, acldefault('f', p.proowner))
    ) privilege_row
    LEFT JOIN pg_roles grantee_role ON grantee_role.oid = privilege_row.grantee
    WHERE n.nspname = 'public'
      AND p.proname = 'internal_classify_supplier_invoice_rejection_v1'
      AND oidvectortypes(p.proargtypes) = 'uuid, boolean, text'
      AND privilege_row.privilege_type = 'EXECUTE'
      AND (
        privilege_row.grantee = 0
        OR grantee_role.rolname IN ('anon', 'authenticated')
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: internal rejection-classification helper is executable by PUBLIC, anon or authenticated';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.staff_reject_supplier_invoice_resubmission(uuid,text)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FAIL: authenticated execution grant is missing from a public rejection RPC';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.staff_reject_supplier_invoice_resubmission(uuid,text)'::regprocedure
  )) INTO v_definition;

  IF position('internal_classify_supplier_invoice_rejection_v1' IN v_definition) = 0
     OR position('true' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: existing rejection RPC no longer delegates the TRUE classification';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.staff_exclude_supplier_invoice_no_resubmission_v1(uuid,text)'::regprocedure
  )) INTO v_definition;

  IF position('internal_classify_supplier_invoice_rejection_v1' IN v_definition) = 0
     OR position('false' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: exclusion RPC no longer delegates the FALSE classification';
  END IF;

  IF to_regprocedure('public.staff_undo_supplier_invoice_rejection_v1(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'FAIL: rejection undo RPC is missing';
  END IF;

  SELECT lower(pg_get_functiondef(
    'public.staff_undo_supplier_invoice_rejection_v1(uuid,text)'::regprocedure
  )) INTO v_definition;

  IF position('invoice_before ->> ''rejection_requires_resubmission_yn''' IN v_definition) = 0
     OR position('set rejection_requires_resubmission_yn = v_classification_before' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'FAIL: rejection undo does not restore classification from invoice_before snapshot JSON';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.review_status::text = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: a deployed legacy rejected invoice was not backfilled fail-closed to require resubmission';
  END IF;
END
$contract$;

DO $behaviour$
DECLARE
  v_country_id uuid;
  v_staff_id uuid := gen_random_uuid();
  v_auth_uid uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_retailer_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_retailer_account_id uuid := gen_random_uuid();
  v_require_order_id uuid := gen_random_uuid();
  v_exclude_order_id uuid := gen_random_uuid();
  v_legacy_order_id uuid := gen_random_uuid();
  v_require_invoice_id uuid := gen_random_uuid();
  v_exclude_invoice_id uuid := gen_random_uuid();
  v_legacy_invoice_id uuid := gen_random_uuid();
  v_require_line_id uuid := gen_random_uuid();
  v_exclude_line_id uuid := gen_random_uuid();
  v_returned_order_id uuid;
  v_failed boolean;
  v_error text;
  v_invoice record;
  v_line record;
  v_snapshot_before jsonb;
  v_require_invoice_unchanged jsonb;
  v_exclude_invoice_unchanged jsonb;
  v_require_line_unchanged jsonb;
  v_exclude_line_unchanged jsonb;
  v_require_order_before jsonb;
  v_exclude_order_before jsonb;
  v_legacy_invoice_before jsonb;
BEGIN
  SELECT c.id
    INTO v_country_id
  FROM public.countries c
  WHERE c.iso_code = 'GHA'
  LIMIT 1;

  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: required GHA country seed is missing for isolated regression fixture';
  END IF;

  INSERT INTO public.staff(id, auth_user_id, role_type, full_name, email, active)
  VALUES (
    v_staff_id,
    v_auth_uid,
    'admin',
    'Invoice rejection regression admin',
    'invoice-rejection-regression-' || left(v_staff_id::text, 8) || '@example.test',
    true
  );

  INSERT INTO public.shippers(id, name, contact_email, vat_treatment, active)
  VALUES (
    v_shipper_id,
    'Invoice rejection regression shipper',
    'invoice-rejection-shipper-' || left(v_shipper_id::text, 8) || '@example.test',
    'outside_scope',
    true
  );

  INSERT INTO public.hubs(id, shipper_id, name, country_id, full_address, active)
  VALUES (
    v_hub_id,
    v_shipper_id,
    'Invoice rejection regression hub',
    v_country_id,
    'Rollback-only regression address',
    true
  );

  UPDATE public.shippers
  SET primary_hub_id = v_hub_id
  WHERE id = v_shipper_id;

  INSERT INTO public.retailers(id, name, website_url, global_enabled)
  VALUES (
    v_retailer_id,
    'Invoice rejection regression retailer ' || left(v_retailer_id::text, 8),
    'https://example.test',
    true
  );

  INSERT INTO public.importers(id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (
    v_importer_id,
    v_shipper_id,
    v_country_id,
    'Invoice Rejection Regression Importer Ltd',
    'Invoice Rejection Regression',
    true
  );

  INSERT INTO public.operators(id, email, full_name, auth_user_id, active)
  VALUES (
    v_operator_id,
    'invoice-rejection-operator-' || left(v_operator_id::text, 8) || '@example.test',
    'Invoice rejection regression operator',
    gen_random_uuid(),
    true
  );

  INSERT INTO public.operator_importers(operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO public.retailer_accounts(
    id,
    retailer_id,
    shipper_id,
    account_email,
    credential_delivery_method,
    delivery_address_locked_to_hub_id,
    status
  ) VALUES (
    v_retailer_account_id,
    v_retailer_id,
    v_shipper_id,
    'invoice-rejection-account-' || left(v_retailer_account_id::text, 8) || '@example.test',
    'vault_brokered',
    v_hub_id,
    'active'
  );

  INSERT INTO public.orders(
    id,
    order_ref,
    payment_auth_id,
    importer_id,
    operator_id,
    shipper_id,
    retailer_id,
    destination_hub_id,
    order_type,
    order_total_gbp_declared,
    total_qty_declared,
    bundled_quote_gbp,
    quote_fx_rate,
    quote_card_markup_pct,
    quote_total_ghs,
    status,
    sop_version
  ) VALUES
    (
      v_require_order_id,
      'REG-REQUIRE-' || left(v_require_order_id::text, 8),
      'AUTH-REQUIRE-' || left(v_require_order_id::text, 8),
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      12.34,
      1,
      12.34,
      1,
      0,
      12.34,
      'pending_dva_funding',
      'regression-v1'
    ),
    (
      v_exclude_order_id,
      'REG-EXCLUDE-' || left(v_exclude_order_id::text, 8),
      'AUTH-EXCLUDE-' || left(v_exclude_order_id::text, 8),
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      23.45,
      1,
      23.45,
      1,
      0,
      23.45,
      'pending_dva_funding',
      'regression-v1'
    ),
    (
      v_legacy_order_id,
      'REG-LEGACY-REJECTION-' || left(v_legacy_order_id::text, 8),
      'AUTH-LEGACY-REJECTION-' || left(v_legacy_order_id::text, 8),
      v_importer_id,
      v_operator_id,
      v_shipper_id,
      v_retailer_id,
      v_hub_id,
      'original',
      34.56,
      1,
      34.56,
      1,
      0,
      34.56,
      'pending_dva_funding',
      'regression-v1'
    );

  INSERT INTO public.supplier_invoices(
    id,
    order_id,
    retailer_id,
    retailer_account_id,
    invoice_ref,
    invoice_pdf_url,
    uploaded_by_operator_id,
    ocr_service_used,
    ocr_invoice_ref,
    ocr_invoice_total_gbp,
    reconciliation_gbp_total,
    review_status,
    rejection_requires_resubmission_yn,
    blocked_from_sage_yn,
    is_current_for_order,
    reviewed_by_staff_id,
    reviewed_at,
    review_notes
  ) VALUES
    (
      v_require_invoice_id,
      v_require_order_id,
      v_retailer_id,
      v_retailer_account_id,
      'REG-REQUIRE-' || left(v_require_invoice_id::text, 8),
      'regression://require-corrected-invoice',
      v_operator_id,
      'manual',
      'REG-REQUIRE-' || left(v_require_invoice_id::text, 8),
      12.34,
      12.34,
      'pending_review',
      NULL,
      false,
      true,
      NULL,
      NULL,
      'Original require-path note'
    ),
    (
      v_exclude_invoice_id,
      v_exclude_order_id,
      v_retailer_id,
      v_retailer_account_id,
      'REG-EXCLUDE-' || left(v_exclude_invoice_id::text, 8),
      'regression://exclude-without-corrected-invoice',
      v_operator_id,
      'manual',
      'REG-EXCLUDE-' || left(v_exclude_invoice_id::text, 8),
      23.45,
      23.45,
      'pending_review',
      NULL,
      false,
      true,
      NULL,
      NULL,
      'Original exclusion-path note'
    ),
    (
      v_legacy_invoice_id,
      v_legacy_order_id,
      v_retailer_id,
      v_retailer_account_id,
      'REG-LEGACY-REJECTION-' || left(v_legacy_invoice_id::text, 8),
      'regression://legacy-unclassified-rejection',
      v_operator_id,
      'manual',
      'REG-LEGACY-REJECTION-' || left(v_legacy_invoice_id::text, 8),
      34.56,
      34.56,
      'rejected_resubmit_required',
      NULL,
      true,
      false,
      v_staff_id,
      now(),
      'Synthetic legacy unclassified rejection'
    );

  INSERT INTO public.supplier_invoice_lines(
    id,
    supplier_invoice_id,
    line_order,
    description,
    qty,
    amount_inc_vat_gbp,
    line_source,
    qty_confirmed,
    amount_confirmed,
    eligible_for_invoice_yn
  ) VALUES
    (
      v_require_line_id,
      v_require_invoice_id,
      1,
      'Require-path physical item',
      1,
      12.34,
      'manually_added',
      1,
      12.34,
      'Y'
    ),
    (
      v_exclude_line_id,
      v_exclude_invoice_id,
      1,
      'Exclude-path physical item',
      1,
      23.45,
      'manually_added',
      1,
      23.45,
      'Y'
    );

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  SELECT
    to_jsonb(si) - ARRAY[
      'review_status',
      'rejection_requires_resubmission_yn',
      'blocked_from_sage_yn',
      'is_current_for_order',
      'reviewed_by_staff_id',
      'reviewed_at',
      'review_notes',
      'updated_at'
    ]::text[]
  INTO v_require_invoice_unchanged
  FROM public.supplier_invoices si
  WHERE si.id = v_require_invoice_id;

  SELECT
    to_jsonb(si) - ARRAY[
      'review_status',
      'rejection_requires_resubmission_yn',
      'blocked_from_sage_yn',
      'is_current_for_order',
      'reviewed_by_staff_id',
      'reviewed_at',
      'review_notes',
      'updated_at'
    ]::text[]
  INTO v_exclude_invoice_unchanged
  FROM public.supplier_invoices si
  WHERE si.id = v_exclude_invoice_id;

  SELECT
    to_jsonb(sil) - ARRAY[
      'eligible_for_invoice_yn',
      'qty_confirmed',
      'amount_confirmed',
      'updated_at'
    ]::text[]
  INTO v_require_line_unchanged
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = v_require_line_id;

  SELECT
    to_jsonb(sil) - ARRAY[
      'eligible_for_invoice_yn',
      'qty_confirmed',
      'amount_confirmed',
      'updated_at'
    ]::text[]
  INTO v_exclude_line_unchanged
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = v_exclude_line_id;

  SELECT to_jsonb(o)
    INTO v_require_order_before
  FROM public.orders o
  WHERE o.id = v_require_order_id;

  SELECT to_jsonb(o)
    INTO v_exclude_order_before
  FROM public.orders o
  WHERE o.id = v_exclude_order_id;

  SELECT to_jsonb(si)
    INTO v_legacy_invoice_before
  FROM public.supplier_invoices si
  WHERE si.id = v_legacy_invoice_id;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.id = v_legacy_invoice_id
      AND si.review_status::text = 'rejected_resubmit_required'
      AND si.rejection_requires_resubmission_yn IS NULL
      AND si.rejection_requires_resubmission_yn IS DISTINCT FROM false
  ) THEN
    RAISE EXCEPTION 'FAIL: NULL legacy classification is not interpreted fail-closed as requiring resubmission';
  END IF;

  v_failed := false;
  v_error := NULL;
  BEGIN
    PERFORM result.order_id
    FROM public.staff_reject_supplier_invoice_resubmission(
      v_require_invoice_id,
      NULL
    ) result;
  EXCEPTION
    WHEN OTHERS THEN
      v_failed := true;
      v_error := SQLERRM;
  END;

  IF NOT v_failed OR position('reason' IN lower(COALESCE(v_error, ''))) = 0 THEN
    RAISE EXCEPTION 'FAIL: corrected-invoice rejection accepted no reason or raised the wrong error: %', v_error;
  END IF;

  v_failed := false;
  v_error := NULL;
  BEGIN
    PERFORM result.order_id
    FROM public.staff_exclude_supplier_invoice_no_resubmission_v1(
      v_exclude_invoice_id,
      '   '
    ) result;
  EXCEPTION
    WHEN OTHERS THEN
      v_failed := true;
      v_error := SQLERRM;
  END;

  IF NOT v_failed OR position('reason' IN lower(COALESCE(v_error, ''))) = 0 THEN
    RAISE EXCEPTION 'FAIL: exclusion rejection accepted a blank reason or raised the wrong error: %', v_error;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.supplier_invoice_rejection_undo_snapshots s
    WHERE s.supplier_invoice_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) OR EXISTS (
    SELECT 1
    FROM public.supplier_invoices si
    WHERE si.id IN (v_require_invoice_id, v_exclude_invoice_id)
      AND si.review_status::text <> 'pending_review'
  ) THEN
    RAISE EXCEPTION 'FAIL: rejected no-reason call changed invoice state or created an undo snapshot';
  END IF;

  SELECT result.order_id
    INTO v_returned_order_id
  FROM public.staff_reject_supplier_invoice_resubmission(
    v_require_invoice_id,
    'Regression: corrected invoice required'
  ) result;

  IF v_returned_order_id IS DISTINCT FROM v_require_order_id THEN
    RAISE EXCEPTION 'FAIL: corrected-invoice rejection returned order %, expected %', v_returned_order_id, v_require_order_id;
  END IF;

  SELECT *
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = v_require_invoice_id;

  IF v_invoice.review_status::text IS DISTINCT FROM 'rejected_resubmit_required'
     OR v_invoice.rejection_requires_resubmission_yn IS DISTINCT FROM true
     OR v_invoice.blocked_from_sage_yn IS DISTINCT FROM true
     OR v_invoice.is_current_for_order IS DISTINCT FROM false
     OR v_invoice.reviewed_by_staff_id IS DISTINCT FROM v_staff_id
     OR v_invoice.reviewed_at IS NULL
     OR v_invoice.review_notes IS DISTINCT FROM 'Regression: corrected invoice required' THEN
    RAISE EXCEPTION 'FAIL: corrected-invoice rejection state is wrong: %', to_jsonb(v_invoice);
  END IF;

  SELECT *
    INTO v_line
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = v_require_line_id;

  IF v_line.eligible_for_invoice_yn IS DISTINCT FROM 'N'
     OR v_line.qty_confirmed IS NOT NULL
     OR v_line.amount_confirmed IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: corrected-invoice rejection did not retire its invoice line: %', to_jsonb(v_line);
  END IF;

  SELECT s.invoice_before
    INTO v_snapshot_before
  FROM public.supplier_invoice_rejection_undo_snapshots s
  WHERE s.supplier_invoice_id = v_require_invoice_id
    AND s.undone_at IS NULL;

  IF v_snapshot_before IS NULL
     OR NOT (v_snapshot_before ? 'rejection_requires_resubmission_yn')
     OR v_snapshot_before ->> 'rejection_requires_resubmission_yn' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: corrected-invoice rejection snapshot did not capture the previous NULL classification: %', v_snapshot_before;
  END IF;

  SELECT result.order_id
    INTO v_returned_order_id
  FROM public.staff_undo_supplier_invoice_rejection_v1(
    v_require_invoice_id,
    'Regression: restore exact pre-rejection state'
  ) result;

  IF v_returned_order_id IS DISTINCT FROM v_require_order_id THEN
    RAISE EXCEPTION 'FAIL: rejection undo returned order %, expected %', v_returned_order_id, v_require_order_id;
  END IF;

  SELECT *
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = v_require_invoice_id;

  IF v_invoice.review_status::text IS DISTINCT FROM 'pending_review'
     OR v_invoice.rejection_requires_resubmission_yn IS NOT NULL
     OR v_invoice.blocked_from_sage_yn IS DISTINCT FROM false
     OR v_invoice.is_current_for_order IS DISTINCT FROM true
     OR v_invoice.reviewed_by_staff_id IS NOT NULL
     OR v_invoice.reviewed_at IS NOT NULL
     OR v_invoice.review_notes IS DISTINCT FROM 'Original require-path note' THEN
    RAISE EXCEPTION 'FAIL: rejection undo did not restore exact invoice state and snapshot classification: %', to_jsonb(v_invoice);
  END IF;

  SELECT *
    INTO v_line
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = v_require_line_id;

  IF v_line.eligible_for_invoice_yn IS DISTINCT FROM 'Y'
     OR v_line.qty_confirmed IS DISTINCT FROM 1
     OR v_line.amount_confirmed IS DISTINCT FROM 12.34 THEN
    RAISE EXCEPTION 'FAIL: rejection undo did not restore exact invoice-line state: %', to_jsonb(v_line);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.supplier_invoice_rejection_undo_snapshots s
    WHERE s.supplier_invoice_id = v_require_invoice_id
      AND s.undone_at IS NOT NULL
      AND s.undo_reason = 'Regression: restore exact pre-rejection state'
      AND (s.invoice_before ->> 'rejection_requires_resubmission_yn') IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: rejection undo snapshot was not closed with its original classification and reason';
  END IF;

  SELECT result.order_id
    INTO v_returned_order_id
  FROM public.staff_exclude_supplier_invoice_no_resubmission_v1(
    v_exclude_invoice_id,
    'Regression: exclude invoice without replacement'
  ) result;

  IF v_returned_order_id IS DISTINCT FROM v_exclude_order_id THEN
    RAISE EXCEPTION 'FAIL: exclusion rejection returned order %, expected %', v_returned_order_id, v_exclude_order_id;
  END IF;

  SELECT *
    INTO v_invoice
  FROM public.supplier_invoices si
  WHERE si.id = v_exclude_invoice_id;

  IF v_invoice.review_status::text IS DISTINCT FROM 'rejected_resubmit_required'
     OR v_invoice.rejection_requires_resubmission_yn IS DISTINCT FROM false
     OR v_invoice.blocked_from_sage_yn IS DISTINCT FROM true
     OR v_invoice.is_current_for_order IS DISTINCT FROM false
     OR v_invoice.reviewed_by_staff_id IS DISTINCT FROM v_staff_id
     OR v_invoice.reviewed_at IS NULL
     OR v_invoice.review_notes IS DISTINCT FROM 'Regression: exclude invoice without replacement' THEN
    RAISE EXCEPTION 'FAIL: no-resubmission exclusion state is wrong: %', to_jsonb(v_invoice);
  END IF;

  SELECT *
    INTO v_line
  FROM public.supplier_invoice_lines sil
  WHERE sil.id = v_exclude_line_id;

  IF v_line.eligible_for_invoice_yn IS DISTINCT FROM 'N'
     OR v_line.qty_confirmed IS NOT NULL
     OR v_line.amount_confirmed IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: no-resubmission exclusion did not retire its invoice line: %', to_jsonb(v_line);
  END IF;

  IF (
    SELECT
      to_jsonb(si) - ARRAY[
        'review_status',
        'rejection_requires_resubmission_yn',
        'blocked_from_sage_yn',
        'is_current_for_order',
        'reviewed_by_staff_id',
        'reviewed_at',
        'review_notes',
        'updated_at'
      ]::text[]
    FROM public.supplier_invoices si
    WHERE si.id = v_require_invoice_id
  ) IS DISTINCT FROM v_require_invoice_unchanged THEN
    RAISE EXCEPTION 'FAIL: corrected-invoice rejection/undo changed unrelated invoice fields';
  END IF;

  IF (
    SELECT
      to_jsonb(si) - ARRAY[
        'review_status',
        'rejection_requires_resubmission_yn',
        'blocked_from_sage_yn',
        'is_current_for_order',
        'reviewed_by_staff_id',
        'reviewed_at',
        'review_notes',
        'updated_at'
      ]::text[]
    FROM public.supplier_invoices si
    WHERE si.id = v_exclude_invoice_id
  ) IS DISTINCT FROM v_exclude_invoice_unchanged THEN
    RAISE EXCEPTION 'FAIL: no-resubmission exclusion changed unrelated invoice fields';
  END IF;

  IF (
    SELECT
      to_jsonb(sil) - ARRAY[
        'eligible_for_invoice_yn',
        'qty_confirmed',
        'amount_confirmed',
        'updated_at'
      ]::text[]
    FROM public.supplier_invoice_lines sil
    WHERE sil.id = v_require_line_id
  ) IS DISTINCT FROM v_require_line_unchanged OR (
    SELECT
      to_jsonb(sil) - ARRAY[
        'eligible_for_invoice_yn',
        'qty_confirmed',
        'amount_confirmed',
        'updated_at'
      ]::text[]
    FROM public.supplier_invoice_lines sil
    WHERE sil.id = v_exclude_line_id
  ) IS DISTINCT FROM v_exclude_line_unchanged THEN
    RAISE EXCEPTION 'FAIL: rejection classification changed unrelated supplier-invoice-line fields';
  END IF;

  IF (SELECT to_jsonb(o) FROM public.orders o WHERE o.id = v_require_order_id)
       IS DISTINCT FROM v_require_order_before
     OR (SELECT to_jsonb(o) FROM public.orders o WHERE o.id = v_exclude_order_id)
       IS DISTINCT FROM v_exclude_order_before THEN
    RAISE EXCEPTION 'FAIL: rejection classification changed unrelated order state or totals';
  END IF;

  IF (SELECT to_jsonb(si) FROM public.supplier_invoices si WHERE si.id = v_legacy_invoice_id)
       IS DISTINCT FROM v_legacy_invoice_before THEN
    RAISE EXCEPTION 'FAIL: classifying other invoices changed the unrelated legacy invoice';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations a
    JOIN public.supplier_invoice_lines sil ON sil.id = a.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) OR EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batch_line_memberships m
    JOIN public.supplier_invoice_lines sil ON sil.id = m.supplier_invoice_line_id
    WHERE sil.supplier_invoice_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) OR EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines r
    WHERE r.supplier_invoice_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) OR EXISTS (
    SELECT 1
    FROM public.dva_statement_line_allocations a
    WHERE a.supplier_invoice_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots s
    WHERE s.source_table = 'supplier_invoices'
      AND s.source_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) OR EXISTS (
    SELECT 1
    FROM public.sage_postings p
    WHERE p.source_table = 'supplier_invoices'
      AND p.source_id IN (v_require_invoice_id, v_exclude_invoice_id)
  ) THEN
    RAISE EXCEPTION 'FAIL: rejection classification created or changed unrelated tracking, release, treasury or Sage state';
  END IF;

  RAISE NOTICE 'PASS: TRUE/FALSE rejection classification, fail-closed NULL, mandatory reasons, exact undo and unrelated-state preservation';
END
$behaviour$;

SELECT
  'PASS'::text AS result,
  'Supplier invoice rejection classification contract and rollback-safe behaviour verified.'::text AS detail;

ROLLBACK;
