BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- Non-vacuous, rollback-safe proof. No Sage adapter is called and no source is
-- marked posted. A real currently qualifying source is selected dynamically;
-- no production record identifier is embedded.

DO $prerequisites$
DECLARE
  v_auth_uid uuid;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_revalidate_sage_posting_snapshots_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'FAIL: governed migration or prerequisite route is missing';
  END IF;

  SELECT staff_row.auth_user_id
  INTO v_auth_uid
  FROM public.staff staff_row
  WHERE staff_row.active = true
    AND staff_row.auth_user_id IS NOT NULL
    AND (
      staff_row.role_type = 'admin'
      OR COALESCE((staff_row.permissions_json->>'accounting_admin_testing')::boolean, false)
      OR COALESCE((staff_row.permissions_json->>'admin_testing')::boolean, false)
    )
  ORDER BY CASE WHEN staff_row.role_type = 'admin' THEN 0 ELSE 1 END, staff_row.id
  LIMIT 1;

  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'FAIL: no active accounting-admin auth identity exists for rollback-safe freeze proof';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', v_auth_uid::text, 'role', 'authenticated')::text,
    true
  );

  IF auth.uid() IS DISTINCT FROM v_auth_uid
     OR NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'FAIL: regression could not establish accounting-admin JWT context';
  END IF;
END
$prerequisites$;

CREATE TEMP TABLE preserved_queue ON COMMIT DROP AS
SELECT *
FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1();

CREATE TEMP TABLE current_queue_before ON COMMIT DROP AS
SELECT *
FROM public.internal_ready_for_sage_queue_v2();

CREATE TEMP TABLE protected_fingerprints_before ON COMMIT DROP AS
SELECT
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sales_invoices t) AS sales_invoices_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_sales_release_lines t) AS release_lines_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocations t) AS allocations_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocation_lines t) AS allocation_lines_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_order_review_links t) AS review_links_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_memberships t) AS memberships_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_legacy_issues t) AS legacy_issues_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipper_shipment_batches t) AS shipment_batches_fp;

DO $catalogue_and_preservation$
DECLARE
  v_difference bigint;
  v_acl_mismatch bigint;
BEGIN
  WITH actual AS (
    SELECT
      pg_get_userbyid(a.grantor)::text AS grantor_name,
      CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END AS grantee_name,
      a.privilege_type::text,
      a.is_grantable
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL aclexplode(p.proacl) a
    WHERE n.nspname = 'public'
      AND p.proname = 'internal_ready_for_sage_queue_v2'
      AND p.pronargs = 0
  ), expected(grantor_name, grantee_name, privilege_type, is_grantable) AS (
    VALUES
      ('postgres', 'postgres', 'EXECUTE', false),
      ('postgres', 'authenticated', 'EXECUTE', false),
      ('postgres', 'service_role', 'EXECUTE', false)
  ), diff AS (
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
    UNION ALL
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
  )
  SELECT COUNT(*) INTO v_acl_mismatch FROM diff;

  IF v_acl_mismatch <> 0
     OR has_function_privilege('anon', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('postgres', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: canonical queue ACL/effective access differs from governed state';
  END IF;

  IF has_function_privilege('anon', 'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: private preserved queue is executable by an application role';
  END IF;

  SELECT COUNT(*)
  INTO v_difference
  FROM (
    SELECT * FROM preserved_queue
    EXCEPT ALL
    SELECT * FROM current_queue_before
  ) missing_rows;

  IF v_difference <> 0 THEN
    RAISE EXCEPTION 'FAIL: % preserved canonical row(s) are missing or changed', v_difference;
  END IF;

  SELECT COUNT(*)
  INTO v_difference
  FROM (
    SELECT * FROM current_queue_before WHERE document_lane IS DISTINCT FROM 'shipper_ap'
    EXCEPT ALL
    SELECT * FROM preserved_queue WHERE document_lane IS DISTINCT FROM 'shipper_ap'
  ) changed_non_shipper_rows;

  IF v_difference <> 0 THEN
    RAISE EXCEPTION 'FAIL: % non-shipper-AP row(s) were added or changed', v_difference;
  END IF;

  SELECT COUNT(*)
  INTO v_difference
  FROM (
    SELECT document_lane, source_table, source_id
    FROM current_queue_before
    GROUP BY document_lane, source_table, source_id
    HAVING COUNT(*) > 1
  ) duplicate_rows;

  IF v_difference <> 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate canonical lane/source identities exist';
  END IF;
END
$catalogue_and_preservation$;

CREATE TEMP TABLE controlled_candidate ON COMMIT DROP AS
SELECT
  queue_row.source_id AS shipping_document_id,
  queue_row.shipment_batch_id,
  queue_row.amount_gbp,
  queue_row.currency_code,
  queue_row.reference_text,
  queue_row.order_ref,
  queue_row.source_payload
FROM current_queue_before queue_row
JOIN public.shipping_documents document_row
  ON document_row.id = queue_row.source_id
WHERE queue_row.document_lane = 'shipper_ap'
  AND queue_row.source_table = 'shipping_documents'
  AND NOT EXISTS (
    SELECT 1
    FROM preserved_queue old_row
    WHERE old_row.document_lane = queue_row.document_lane
      AND old_row.source_table = queue_row.source_table
      AND old_row.source_id = queue_row.source_id
  )
  AND document_row.active = true
  AND document_row.review_status = 'accepted_current'
  AND document_row.document_kind = 'shipper_invoice'
  AND NULLIF(document_row.file_url::text, '') IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.shipping_cost_allocations allocation_row
    WHERE allocation_row.shipping_document_id = document_row.id
      AND allocation_row.active = true
      AND allocation_row.allocation_status = 'approved'
  )
  AND EXISTS (
    SELECT 1
    FROM public.sage_party_mappings party_row
    WHERE party_row.platform_party_type = 'shipper'
      AND party_row.platform_party_id = document_row.shipper_id
      AND party_row.active = true
      AND NULLIF(party_row.sage_contact_id, '') IS NOT NULL
  )
  AND EXISTS (
    SELECT 1
    FROM public.sage_mapping_settings mapping_row
    WHERE mapping_row.is_active = true
      AND mapping_row.mapping_code = 'SHIPPER_FREIGHT_COST_LEDGER'
      AND NULLIF(mapping_row.sage_external_id, '') IS NOT NULL
  )
  AND EXISTS (
    SELECT 1
    FROM public.sage_mapping_settings mapping_row
    WHERE mapping_row.is_active = true
      AND mapping_row.mapping_code = 'SHIPPER_AP_TAX_RATE_REVIEW'
      AND NULLIF(mapping_row.sage_external_id, '') IS NOT NULL
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot_row
    WHERE snapshot_row.source_table = 'shipping_documents'
      AND snapshot_row.source_id = document_row.id
      AND snapshot_row.document_lane = 'shipper_ap'
      AND snapshot_row.active = true
      AND snapshot_row.sage_posting_status = 'not_posted'
  )
ORDER BY document_row.created_at, document_row.id
LIMIT 1;

DO $candidate_proof$
DECLARE
  v_candidate_count integer;
  v_expected_order_ref text;
  v_actual controlled_candidate%ROWTYPE;
  v_shipping_release numeric;
BEGIN
  SELECT COUNT(*) INTO v_candidate_count FROM controlled_candidate;
  IF v_candidate_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: no real qualifying unapportioned shipper invoice currently satisfies all existing freeze controls';
  END IF;

  SELECT * INTO v_actual FROM controlled_candidate;

  IF v_actual.amount_gbp IS NULL OR v_actual.amount_gbp <= 0 THEN
    RAISE EXCEPTION 'FAIL: controlled candidate does not use a positive full document amount';
  END IF;

  SELECT string_agg(DISTINCT order_row.order_ref::text, ', ' ORDER BY order_row.order_ref::text)
  INTO v_expected_order_ref
  FROM public.shipper_shipment_batch_effective_lines_v1(v_actual.shipment_batch_id) effective_line
  JOIN public.orders order_row ON order_row.id = effective_line.order_id;

  IF v_actual.order_ref IS DISTINCT FROM v_expected_order_ref THEN
    RAISE EXCEPTION 'FAIL: additive order reference does not match authoritative effective-line route';
  END IF;

  IF v_actual.source_payload - ARRAY[
       'document_ref','document_date','booking_ref','shipper_name',
       'document_total','currency','route','status'
     ]::text[] <> '{}'::jsonb
     OR NOT v_actual.source_payload ?& ARRAY[
       'document_ref','document_date','booking_ref','shipper_name',
       'document_total','currency','route','status'
     ]::text[] THEN
    RAISE EXCEPTION 'FAIL: additive source payload differs from established shipper-AP shape';
  END IF;

  SELECT COALESCE(SUM(source_row.shipping_amount_gbp), 0)
  INTO v_shipping_release
  FROM public.internal_customer_sales_release_sources_v1(v_actual.shipment_batch_id) source_row;

  IF v_shipping_release <> 0 THEN
    RAISE EXCEPTION 'FAIL: unapportioned shipping became customer-release eligible';
  END IF;
END
$candidate_proof$;

CREATE TEMP TABLE first_freeze ON COMMIT DROP AS
SELECT freeze_row.*
FROM controlled_candidate candidate
CROSS JOIN LATERAL public.internal_freeze_shipper_ap_sage_batch_v1(
  ARRAY[candidate.shipping_document_id],
  'rollback regression: shipper AP/customer recharge gate separation v1'
) freeze_row;

DO $first_freeze_proof$
DECLARE
  v_row first_freeze%ROWTYPE;
  v_candidate controlled_candidate%ROWTYPE;
  v_payload jsonb;
BEGIN
  SELECT * INTO v_row FROM first_freeze;
  SELECT * INTO v_candidate FROM controlled_candidate;

  IF v_row.freeze_status IS DISTINCT FROM 'frozen'
     OR v_row.blocker IS NOT NULL
     OR v_row.snapshot_id IS NULL
     OR v_row.amount_gbp IS DISTINCT FROM v_candidate.amount_gbp THEN
    RAISE EXCEPTION 'FAIL: existing freeze route did not freeze the controlled unapportioned source';
  END IF;

  SELECT snapshot_row.resolved_payload
  INTO v_payload
  FROM public.sage_posting_snapshots snapshot_row
  WHERE snapshot_row.id = v_row.snapshot_id;

  IF jsonb_array_length(COALESCE(v_payload->'resolved_lines', '[]'::jsonb)) <> 1
     OR (v_payload #>> '{resolved_lines,0,quantity}')::numeric IS DISTINCT FROM 1
     OR (v_payload #>> '{resolved_lines,0,unit_price_gbp}')::numeric IS DISTINCT FROM v_candidate.amount_gbp
     OR (v_payload #>> '{resolved_lines,0,total_line_amount_gbp}')::numeric IS DISTINCT FROM v_candidate.amount_gbp THEN
    RAISE EXCEPTION 'FAIL: frozen payload does not contain one full-amount shipper-AP line';
  END IF;
END
$first_freeze_proof$;

CREATE TEMP TABLE queue_after_freeze ON COMMIT DROP AS
SELECT * FROM public.internal_ready_for_sage_queue_v2();

DO $persistence_proof$
DECLARE
  v_candidate controlled_candidate%ROWTYPE;
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT * INTO v_candidate FROM controlled_candidate;

  SELECT to_jsonb(q) INTO v_before
  FROM current_queue_before q
  WHERE q.document_lane = 'shipper_ap'
    AND q.source_table = 'shipping_documents'
    AND q.source_id = v_candidate.shipping_document_id;

  SELECT to_jsonb(q) INTO v_after
  FROM queue_after_freeze q
  WHERE q.document_lane = 'shipper_ap'
    AND q.source_table = 'shipping_documents'
    AND q.source_id = v_candidate.shipping_document_id;

  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'FAIL: additive source row disappeared or changed after freeze';
  END IF;
END
$persistence_proof$;

CREATE TEMP TABLE revalidation_result ON COMMIT DROP AS
SELECT revalidation_row.*
FROM first_freeze freeze_row
CROSS JOIN LATERAL public.internal_revalidate_sage_posting_snapshots_v1(
  ARRAY[freeze_row.snapshot_id]
) revalidation_row;

DO $revalidation_proof$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM revalidation_result
    WHERE document_lane = 'shipper_ap'
      AND revalidation_status = 'ok_to_post'
      AND revalidation_notes IS NULL
      AND current_payload_status LIKE 'ready%'
  ) THEN
    RAISE EXCEPTION 'FAIL: frozen shipper-AP snapshot did not revalidate as ok_to_post';
  END IF;
END
$revalidation_proof$;

CREATE TEMP TABLE second_freeze ON COMMIT DROP AS
SELECT freeze_row.*
FROM controlled_candidate candidate
CROSS JOIN LATERAL public.internal_freeze_shipper_ap_sage_batch_v1(
  ARRAY[candidate.shipping_document_id],
  'rollback regression repeat: idempotency proof'
) freeze_row;

DO $idempotency_and_scope_proof$
DECLARE
  v_first first_freeze%ROWTYPE;
  v_second second_freeze%ROWTYPE;
  v_candidate controlled_candidate%ROWTYPE;
  v_active_snapshot_count bigint;
  v_before protected_fingerprints_before%ROWTYPE;
  v_after protected_fingerprints_before%ROWTYPE;
BEGIN
  SELECT * INTO v_first FROM first_freeze;
  SELECT * INTO v_second FROM second_freeze;
  SELECT * INTO v_candidate FROM controlled_candidate;

  IF v_second.freeze_status IS DISTINCT FROM 'frozen'
     OR v_second.snapshot_id IS DISTINCT FROM v_first.snapshot_id
     OR v_second.idempotency_key IS DISTINCT FROM v_first.idempotency_key THEN
    RAISE EXCEPTION 'FAIL: repeated freeze did not follow existing snapshot idempotency';
  END IF;

  SELECT COUNT(*)
  INTO v_active_snapshot_count
  FROM public.sage_posting_snapshots snapshot_row
  WHERE snapshot_row.source_table = 'shipping_documents'
    AND snapshot_row.source_id = v_candidate.shipping_document_id
    AND snapshot_row.document_lane = 'shipper_ap'
    AND snapshot_row.active = true
    AND snapshot_row.sage_posting_status = 'not_posted';

  IF v_active_snapshot_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeated freeze created more than one active shipper-AP liability snapshot';
  END IF;

  SELECT * INTO v_before FROM protected_fingerprints_before;

  SELECT
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sales_invoices t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_sales_release_lines t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocations t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocation_lines t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_order_review_links t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_memberships t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_legacy_issues t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipper_shipment_batches t)
  INTO v_after;

  IF to_jsonb(v_after) IS DISTINCT FROM to_jsonb(v_before) THEN
    RAISE EXCEPTION 'FAIL: freeze/revalidation proof changed protected customer, allocation, review or shipment data';
  END IF;
END
$idempotency_and_scope_proof$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'shipping_document_id', candidate.shipping_document_id,
  'shipment_batch_id', candidate.shipment_batch_id,
  'amount_gbp', candidate.amount_gbp,
  'snapshot_id', first_run.snapshot_id,
  'revalidation_status', revalidation.revalidation_status,
  'proof', 'non-vacuous queue admission, freeze, persistence, revalidation, idempotency, customer-recharge protection and protected-data fingerprints all passed; transaction will roll back'
) AS regression_result
FROM controlled_candidate candidate
CROSS JOIN first_freeze first_run
CROSS JOIN revalidation_result revalidation;

ROLLBACK;
