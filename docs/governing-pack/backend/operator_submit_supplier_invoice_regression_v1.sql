-- =============================================================================
-- operator_submit_supplier_invoice_regression_v1.sql
-- Regression smoke checks for operator_submit_supplier_invoice(...)
--
-- Run after:
--   1. goodcashback-complete.v4.sql
--   2. operator_submit_supplier_invoice_v1.sql
--
-- Proves:
--   1) Authorised operator can submit.
--   2) Unauthorised operator is blocked.
--   3) Zero retailer account is blocked.
--   4) Multiple retailer accounts are blocked.
--   5) No order status change after successful submit.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_country_id uuid;
  v_staff_id uuid := gen_random_uuid();
  v_shipper_id uuid := gen_random_uuid();
  v_hub_id uuid := gen_random_uuid();
  v_importer_id uuid := gen_random_uuid();
  v_operator_auth_uid uuid := gen_random_uuid();
  v_operator_id uuid := gen_random_uuid();
  v_unauth_auth_uid uuid := gen_random_uuid();
  v_unauth_operator_id uuid := gen_random_uuid();

  v_retailer_ok_id uuid := gen_random_uuid();
  v_retailer_zero_id uuid := gen_random_uuid();
  v_retailer_multi_id uuid := gen_random_uuid();

  v_order_ok_id uuid := gen_random_uuid();
  v_order_zero_id uuid := gen_random_uuid();
  v_order_multi_id uuid := gen_random_uuid();

  v_account_ok_id uuid := gen_random_uuid();
  v_account_multi_a_id uuid := gen_random_uuid();
  v_account_multi_b_id uuid := gen_random_uuid();

  v_result jsonb;
  v_before_status text;
  v_after_status text;
  v_count int;
BEGIN
  SELECT id INTO v_country_id FROM public.countries WHERE iso_code = 'GHA' LIMIT 1;
  IF v_country_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: seed country GHA missing';
  END IF;

  INSERT INTO public.staff (id, auth_user_id, role_type, full_name, email, active)
  VALUES (v_staff_id, gen_random_uuid(), 'admin', 'Invoice RPC Smoke Admin', 'smoke-admin-' || left(v_staff_id::text, 8) || '@example.test', true);

  INSERT INTO public.shippers (id, name, contact_email, vat_treatment, active)
  VALUES (v_shipper_id, 'Invoice Smoke Shipper', 'shipper-' || left(v_shipper_id::text, 8) || '@example.test', 'outside_scope', true);

  INSERT INTO public.hubs (id, shipper_id, name, country_id, full_address, active)
  VALUES (v_hub_id, v_shipper_id, 'Invoice Smoke Hub', v_country_id, 'Smoke Address', true);

  UPDATE public.shippers
  SET primary_hub_id = v_hub_id
  WHERE id = v_shipper_id;

  INSERT INTO public.importers (id, shipper_id, country_id, company_name, trading_name, active)
  VALUES (v_importer_id, v_shipper_id, v_country_id, 'Invoice Smoke Importer Ltd', 'Invoice Smoke Importer', true);

  INSERT INTO public.operators (id, email, full_name, auth_user_id, active)
  VALUES
    (v_operator_id, 'op-' || left(v_operator_id::text, 8) || '@example.test', 'Authorised Operator', v_operator_auth_uid, true),
    (v_unauth_operator_id, 'op-' || left(v_unauth_operator_id::text, 8) || '@example.test', 'Unauthorised Operator', v_unauth_auth_uid, true);

  INSERT INTO public.operator_importers (operator_id, importer_id, relationship_type)
  VALUES (v_operator_id, v_importer_id, 'sole_owner');

  INSERT INTO public.retailers (id, name, website_url, global_enabled)
  VALUES
    (v_retailer_ok_id, 'Retailer OK', 'https://ok.example.test', true),
    (v_retailer_zero_id, 'Retailer ZERO', 'https://zero.example.test', true),
    (v_retailer_multi_id, 'Retailer MULTI', 'https://multi.example.test', true);

  INSERT INTO public.retailer_accounts (
    id, retailer_id, shipper_id, account_email, credential_delivery_method,
    delivery_address_locked_to_hub_id, status
  )
  VALUES
    (v_account_ok_id, v_retailer_ok_id, v_shipper_id, 'ok-account@example.test', 'vault_brokered', v_hub_id, 'active'),
    (v_account_multi_a_id, v_retailer_multi_id, v_shipper_id, 'multi-a@example.test', 'vault_brokered', v_hub_id, 'active'),
    (v_account_multi_b_id, v_retailer_multi_id, v_shipper_id, 'multi-b@example.test', 'vault_brokered', v_hub_id, 'active');

  INSERT INTO public.orders (
    id, order_ref, payment_auth_id, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared, total_qty_declared,
    status, sop_version
  ) VALUES
    (v_order_ok_id, 'SMOKE-INV-OK-' || left(v_order_ok_id::text, 8), 'AUTH-INV-OK', v_importer_id, v_operator_id, v_shipper_id, v_retailer_ok_id, v_hub_id, 'main', 100.00, 1, 'awaiting_invoice', 'smoke-v1'),
    (v_order_zero_id, 'SMOKE-INV-ZERO-' || left(v_order_zero_id::text, 8), 'AUTH-INV-ZERO', v_importer_id, v_operator_id, v_shipper_id, v_retailer_zero_id, v_hub_id, 'main', 100.00, 1, 'awaiting_invoice', 'smoke-v1'),
    (v_order_multi_id, 'SMOKE-INV-MULTI-' || left(v_order_multi_id::text, 8), 'AUTH-INV-MULTI', v_importer_id, v_operator_id, v_shipper_id, v_retailer_multi_id, v_hub_id, 'main', 100.00, 1, 'awaiting_invoice', 'smoke-v1');

  -- 1) Authorised operator can submit.
  PERFORM set_config('request.jwt.claim.sub', v_operator_auth_uid::text, true);

  SELECT status INTO v_before_status FROM public.orders WHERE id = v_order_ok_id;

  SELECT public.operator_submit_supplier_invoice(
    v_order_ok_id,
    'INV-SMOKE-001',
    'https://storage.example.test/invoices/inv-smoke-001.pdf'
  ) INTO v_result;

  IF COALESCE((v_result->>'success')::boolean, false) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: expected success=true, got %', v_result;
  END IF;

  IF (v_result->>'order_id')::uuid <> v_order_ok_id THEN
    RAISE EXCEPTION 'FAIL: success payload order_id mismatch, got % expected %', v_result->>'order_id', v_order_ok_id;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.supplier_invoices si
  WHERE si.id = (v_result->>'supplier_invoice_id')::uuid
    AND si.order_id = v_order_ok_id
    AND si.retailer_id = v_retailer_ok_id
    AND si.retailer_account_id = v_account_ok_id
    AND si.uploaded_by_operator_id = v_operator_id
    AND si.ocr_service_used = 'manual'
    AND si.invoice_ref = 'INV-SMOKE-001';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: authorised submission did not create expected supplier_invoices row';
  END IF;

  -- 5) No order status change.
  SELECT status INTO v_after_status FROM public.orders WHERE id = v_order_ok_id;

  IF v_after_status IS DISTINCT FROM v_before_status THEN
    RAISE EXCEPTION 'FAIL: order status changed from % to %; expected unchanged', v_before_status, v_after_status;
  END IF;

  -- 2) Unauthorised operator blocked.
  PERFORM set_config('request.jwt.claim.sub', v_unauth_auth_uid::text, true);
  BEGIN
    PERFORM public.operator_submit_supplier_invoice(
      v_order_ok_id,
      'INV-SMOKE-002',
      'https://storage.example.test/invoices/inv-smoke-002.pdf'
    );
    RAISE EXCEPTION 'FAIL: unauthorised operator submission unexpectedly succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('not authorised' in lower(SQLERRM)) = 0 THEN
        RAISE EXCEPTION 'FAIL: unauthorised operator threw unexpected error: %', SQLERRM;
      END IF;
  END;

  -- 3) Zero retailer account blocked.
  PERFORM set_config('request.jwt.claim.sub', v_operator_auth_uid::text, true);
  BEGIN
    PERFORM public.operator_submit_supplier_invoice(
      v_order_zero_id,
      'INV-SMOKE-003',
      'https://storage.example.test/invoices/inv-smoke-003.pdf'
    );
    RAISE EXCEPTION 'FAIL: zero-retailer-account submission unexpectedly succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('no active retailer_account found' in lower(SQLERRM)) = 0 THEN
        RAISE EXCEPTION 'FAIL: zero-account scenario threw unexpected error: %', SQLERRM;
      END IF;
  END;

  -- 4) Multiple retailer accounts blocked.
  BEGIN
    PERFORM public.operator_submit_supplier_invoice(
      v_order_multi_id,
      'INV-SMOKE-004',
      'https://storage.example.test/invoices/inv-smoke-004.pdf'
    );
    RAISE EXCEPTION 'FAIL: multi-retailer-account submission unexpectedly succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      IF position('multiple active retailer_accounts found' in lower(SQLERRM)) = 0 THEN
        RAISE EXCEPTION 'FAIL: multi-account scenario threw unexpected error: %', SQLERRM;
      END IF;
  END;

  RAISE NOTICE 'PASS: operator_submit_supplier_invoice regression checks passed';
END;
$$;

ROLLBACK;
