BEGIN ISOLATION LEVEL REPEATABLE READ;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- Non-vacuous rollback-safe regression. It dynamically selects one existing
-- working approved-apportionment shipper-AP source, removes its approved
-- allocation only inside a savepoint, proves additive admission, full-amount
-- freeze, row persistence, revalidation, idempotency and terminal-posted
-- suppression, then rolls the savepoint back and proves exact table fingerprints.
-- No production identifier is embedded. No Sage adapter is called.

DO $prerequisites$
DECLARE
  v_auth_uid uuid;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL
     OR to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()') IS NULL
     OR to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_revalidate_sage_posting_snapshots_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN
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

CREATE TEMP TABLE protected_baseline ON COMMIT DROP AS
SELECT
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sales_invoices t) AS sales_invoices_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_sales_release_lines t) AS release_lines_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocations t) AS allocations_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocation_lines t) AS allocation_lines_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_order_review_links t) AS review_links_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_memberships t) AS memberships_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_legacy_issues t) AS legacy_issues_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipper_shipment_batches t) AS shipment_batches_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sage_posting_snapshots t) AS posting_snapshots_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sage_posting_batches t) AS posting_batches_fp,
  (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sage_posting_batch_rows t) AS posting_batch_rows_fp;

CREATE TEMP TABLE preserved_queue ON COMMIT DROP AS
SELECT *
FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1();

CREATE TEMP TABLE canonical_queue_before ON COMMIT DROP AS
SELECT *
FROM public.internal_ready_for_sage_queue_v2();

DO $catalogue_and_preservation$
DECLARE
  v_difference bigint;
  v_acl_mismatch bigint;
  v_owner text;
  v_language text;
  v_volatility "char";
  v_parallel "char";
  v_security_definer boolean;
  v_search_path text[];
  v_result_shape text;
BEGIN
  SELECT
    pg_get_userbyid(p.proowner),
    l.lanname,
    p.provolatile,
    p.proparallel,
    p.prosecdef,
    p.proconfig,
    pg_get_function_result(p.oid)
  INTO
    v_owner,
    v_language,
    v_volatility,
    v_parallel,
    v_security_definer,
    v_search_path,
    v_result_shape
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_ready_for_sage_queue_v2'
    AND p.pronargs = 0;

  IF v_owner IS DISTINCT FROM 'postgres'
     OR v_language IS DISTINCT FROM 'sql'
     OR v_volatility IS DISTINCT FROM 'v'
     OR v_parallel IS DISTINCT FROM 'u'
     OR v_security_definer IS DISTINCT FROM true
     OR v_search_path IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[]
     OR v_result_shape IS DISTINCT FROM
       'TABLE(queue_row_id text, document_lane text, document_type text, source_table text, source_id uuid, order_id uuid, order_ref text, shipment_batch_id uuid, booking_ref text, counterparty_name text, amount_gbp numeric, currency_code text, invoice_type text, sage_status text, sage_invoice_id text, sage_posted_at timestamp with time zone, readiness_status text, blocker text, reference_text text, notes_text text, detail_href text, source_payload jsonb)' THEN
    RAISE EXCEPTION 'FAIL: canonical queue catalogue properties differ from governed live state';
  END IF;

  WITH actual AS (
    SELECT
      pg_get_userbyid(a.grantor)::text AS grantor_name,
      CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END AS grantee_name,
      a.privilege_type::text AS privilege_type,
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
  ), differences AS (
    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
    UNION ALL
    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
  )
  SELECT COUNT(*) INTO v_acl_mismatch FROM differences;

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

  SELECT COUNT(*) INTO v_difference
  FROM (
    SELECT * FROM preserved_queue
    EXCEPT ALL
    SELECT * FROM canonical_queue_before
  ) missing_rows;

  IF v_difference <> 0 THEN
    RAISE EXCEPTION 'FAIL: % preserved canonical row(s) are missing or changed', v_difference;
  END IF;

  SELECT COUNT(*) INTO v_difference
  FROM (
    SELECT * FROM canonical_queue_before WHERE document_lane IS DISTINCT FROM 'shipper_ap'
    EXCEPT ALL
    SELECT * FROM preserved_queue WHERE document_lane IS DISTINCT FROM 'shipper_ap'
  ) changed_non_shipper_rows;

  IF v_difference <> 0 THEN
    RAISE EXCEPTION 'FAIL: % non-shipper-AP row(s) were added or changed', v_difference;
  END IF;

  SELECT COUNT(*) INTO v_difference
  FROM (
    SELECT document_lane, source_table, source_id
    FROM canonical_queue_before
    GROUP BY document_lane, source_table, source_id
    HAVING COUNT(*) > 1
  ) duplicate_rows;

  IF v_difference <> 0 THEN
    RAISE EXCEPTION 'FAIL: duplicate canonical lane/source identities exist';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM canonical_queue_before queue_row
    WHERE queue_row.document_lane = 'shipper_ap'
      AND queue_row.source_table = 'shipping_documents'
      AND NOT EXISTS (
        SELECT 1
        FROM preserved_queue old_row
        WHERE old_row.document_lane = queue_row.document_lane
          AND old_row.source_table = queue_row.source_table
          AND old_row.source_id = queue_row.source_id
      )
      AND (
        EXISTS (
          SELECT 1
          FROM public.sage_posting_snapshots snapshot_row
          WHERE snapshot_row.source_table = queue_row.source_table
            AND snapshot_row.source_id = queue_row.source_id
            AND snapshot_row.document_lane = queue_row.document_lane
            AND snapshot_row.active = true
            AND snapshot_row.sage_posting_status = 'posted'
        )
        OR EXISTS (
          SELECT 1
          FROM public.sage_posting_batch_rows batch_row
          WHERE batch_row.source_table = queue_row.source_table
            AND batch_row.source_id = queue_row.source_id
            AND batch_row.document_lane = queue_row.document_lane
            AND batch_row.posting_status = 'posted'
        )
      )
  ) THEN
    RAISE EXCEPTION 'FAIL: terminally posted additive shipper-AP source appears as live ready';
  END IF;
END
$catalogue_and_preservation$;

CREATE TEMP TABLE controlled_fixture ON COMMIT DROP AS
SELECT
  queue_row.source_id AS shipping_document_id,
  queue_row.shipment_batch_id,
  queue_row.amount_gbp,
  queue_row.currency_code,
  queue_row.reference_text,
  queue_row.order_ref
FROM preserved_queue queue_row
JOIN public.shipping_documents document_row
  ON document_row.id = queue_row.source_id
WHERE queue_row.document_lane = 'shipper_ap'
  AND queue_row.source_table = 'shipping_documents'
  AND queue_row.readiness_status LIKE 'ready%'
  AND document_row.active = true
  AND document_row.superseded_at IS NULL
  AND document_row.replaced_by_document_id IS NULL
  AND document_row.review_status = 'accepted_current'
  AND document_row.document_kind = 'shipper_invoice'
  AND NULLIF(document_row.file_url::text, '') IS NOT NULL
  AND EXISTS (
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
  )
ORDER BY queue_row.source_id
LIMIT 1;

DO $fixture_guard$
BEGIN
  IF (SELECT COUNT(*) FROM controlled_fixture) <> 1 THEN
    RAISE EXCEPTION 'FAIL: no existing approved-apportionment shipper-AP source satisfies all rollback fixture controls';
  END IF;
END
$fixture_guard$;

SAVEPOINT proof_mutations;

UPDATE public.shipping_cost_allocations allocation_row
SET active = false
FROM controlled_fixture fixture
WHERE allocation_row.shipping_document_id = fixture.shipping_document_id
  AND allocation_row.active = true
  AND allocation_row.allocation_status = 'approved';

CREATE TEMP TABLE additive_queue ON COMMIT DROP AS
SELECT queue_row.*
FROM public.internal_ready_for_sage_queue_v2() queue_row
JOIN controlled_fixture fixture ON fixture.shipping_document_id = queue_row.source_id
WHERE queue_row.document_lane = 'shipper_ap'
  AND queue_row.source_table = 'shipping_documents';

DO $additive_proof$
DECLARE
  v_fixture controlled_fixture%ROWTYPE;
  v_row additive_queue%ROWTYPE;
  v_expected_order_ref text;
  v_shipping_release numeric;
BEGIN
  IF (SELECT COUNT(*) FROM additive_queue) <> 1 THEN
    RAISE EXCEPTION 'FAIL: controlled unapportioned source did not produce exactly one canonical shipper-AP row';
  END IF;

  SELECT * INTO v_fixture FROM controlled_fixture;
  SELECT * INTO v_row FROM additive_queue;

  IF EXISTS (
    SELECT 1
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() old_row
    WHERE old_row.document_lane = 'shipper_ap'
      AND old_row.source_table = 'shipping_documents'
      AND old_row.source_id = v_fixture.shipping_document_id
  ) THEN
    RAISE EXCEPTION 'FAIL: preserved queue still admits the controlled source without approved apportionment';
  END IF;

  IF v_row.amount_gbp IS DISTINCT FROM v_fixture.amount_gbp
     OR v_row.readiness_status IS DISTINCT FROM 'ready_for_ap_purchase_invoice_draft'
     OR v_row.blocker IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: additive row amount or readiness differs from established shipper-AP semantics';
  END IF;

  SELECT string_agg(DISTINCT order_row.order_ref::text, ', ' ORDER BY order_row.order_ref::text)
  INTO v_expected_order_ref
  FROM public.shipper_shipment_batch_effective_lines_v1(v_fixture.shipment_batch_id) effective_line
  JOIN public.orders order_row ON order_row.id = effective_line.order_id;

  IF v_row.order_ref IS DISTINCT FROM v_expected_order_ref THEN
    RAISE EXCEPTION 'FAIL: additive order reference does not match authoritative effective-line route';
  END IF;

  IF v_row.source_payload - ARRAY[
       'document_ref','document_date','booking_ref','shipper_name',
       'document_total','currency','route','status'
     ]::text[] <> '{}'::jsonb
     OR NOT v_row.source_payload ?& ARRAY[
       'document_ref','document_date','booking_ref','shipper_name',
       'document_total','currency','route','status'
     ]::text[] THEN
    RAISE EXCEPTION 'FAIL: additive source payload differs from established shipper-AP shape';
  END IF;

  SELECT COALESCE(SUM(source_row.shipping_amount_gbp), 0)
  INTO v_shipping_release
  FROM public.internal_customer_sales_release_sources_v1(v_fixture.shipment_batch_id) source_row;

  IF v_shipping_release <> 0 THEN
    RAISE EXCEPTION 'FAIL: unapportioned shipping became customer-release eligible';
  END IF;
END
$additive_proof$;

CREATE TEMP TABLE first_freeze ON COMMIT DROP AS
SELECT freeze_row.*
FROM controlled_fixture fixture
CROSS JOIN LATERAL public.internal_freeze_shipper_ap_sage_batch_v1(
  ARRAY[fixture.shipping_document_id],
  'rollback regression: shipper AP/customer recharge gate separation v1.1'
) freeze_row;

DO $first_freeze_proof$
DECLARE
  v_row first_freeze%ROWTYPE;
  v_fixture controlled_fixture%ROWTYPE;
  v_payload jsonb;
BEGIN
  SELECT * INTO v_row FROM first_freeze;
  SELECT * INTO v_fixture FROM controlled_fixture;

  IF v_row.freeze_status IS DISTINCT FROM 'frozen'
     OR v_row.blocker IS NOT NULL
     OR v_row.snapshot_id IS NULL
     OR v_row.amount_gbp IS DISTINCT FROM v_fixture.amount_gbp THEN
    RAISE EXCEPTION 'FAIL: existing freeze route did not freeze the controlled unapportioned source';
  END IF;

  SELECT snapshot_row.resolved_payload
  INTO v_payload
  FROM public.sage_posting_snapshots snapshot_row
  WHERE snapshot_row.id = v_row.snapshot_id;

  IF jsonb_array_length(COALESCE(v_payload->'resolved_lines', '[]'::jsonb)) <> 1
     OR (v_payload #>> '{resolved_lines,0,quantity}')::numeric IS DISTINCT FROM 1
     OR (v_payload #>> '{resolved_lines,0,unit_price_gbp}')::numeric IS DISTINCT FROM v_fixture.amount_gbp
     OR (v_payload #>> '{resolved_lines,0,total_line_amount_gbp}')::numeric IS DISTINCT FROM v_fixture.amount_gbp THEN
    RAISE EXCEPTION 'FAIL: frozen payload does not contain one full-amount shipper-AP line';
  END IF;
END
$first_freeze_proof$;

CREATE TEMP TABLE queue_after_freeze ON COMMIT DROP AS
SELECT * FROM public.internal_ready_for_sage_queue_v2();

DO $persistence_proof$
DECLARE
  v_fixture controlled_fixture%ROWTYPE;
  v_before jsonb;
  v_after jsonb;
BEGIN
  SELECT * INTO v_fixture FROM controlled_fixture;

  SELECT to_jsonb(q) INTO v_before
  FROM additive_queue q
  WHERE q.source_id = v_fixture.shipping_document_id;

  SELECT to_jsonb(q) INTO v_after
  FROM queue_after_freeze q
  WHERE q.document_lane = 'shipper_ap'
    AND q.source_table = 'shipping_documents'
    AND q.source_id = v_fixture.shipping_document_id;

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
FROM controlled_fixture fixture
CROSS JOIN LATERAL public.internal_freeze_shipper_ap_sage_batch_v1(
  ARRAY[fixture.shipping_document_id],
  'rollback regression repeat: idempotency proof'
) freeze_row;

DO $idempotency_proof$
DECLARE
  v_first first_freeze%ROWTYPE;
  v_second second_freeze%ROWTYPE;
  v_fixture controlled_fixture%ROWTYPE;
  v_active_snapshot_count bigint;
BEGIN
  SELECT * INTO v_first FROM first_freeze;
  SELECT * INTO v_second FROM second_freeze;
  SELECT * INTO v_fixture FROM controlled_fixture;

  IF v_second.freeze_status IS DISTINCT FROM 'frozen'
     OR v_second.snapshot_id IS DISTINCT FROM v_first.snapshot_id
     OR v_second.idempotency_key IS DISTINCT FROM v_first.idempotency_key THEN
    RAISE EXCEPTION 'FAIL: repeated freeze did not follow existing snapshot idempotency';
  END IF;

  SELECT COUNT(*) INTO v_active_snapshot_count
  FROM public.sage_posting_snapshots snapshot_row
  WHERE snapshot_row.source_table = 'shipping_documents'
    AND snapshot_row.source_id = v_fixture.shipping_document_id
    AND snapshot_row.document_lane = 'shipper_ap'
    AND snapshot_row.active = true
    AND snapshot_row.sage_posting_status = 'not_posted';

  IF v_active_snapshot_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: repeated freeze created more than one active shipper-AP liability snapshot';
  END IF;
END
$idempotency_proof$;

-- Prove terminal posting suppression without calling Sage. This status mutation is
-- confined to the savepoint and is rolled back below.
UPDATE public.sage_posting_snapshots snapshot_row
SET sage_posting_status = 'posted'
FROM first_freeze freeze_row
WHERE snapshot_row.id = freeze_row.snapshot_id;

DO $terminal_posted_suppression$
DECLARE
  v_fixture controlled_fixture%ROWTYPE;
BEGIN
  SELECT * INTO v_fixture FROM controlled_fixture;

  IF EXISTS (
    SELECT 1
    FROM public.internal_ready_for_sage_queue_v2() queue_row
    WHERE queue_row.document_lane = 'shipper_ap'
      AND queue_row.source_table = 'shipping_documents'
      AND queue_row.source_id = v_fixture.shipping_document_id
  ) THEN
    RAISE EXCEPTION 'FAIL: terminally posted additive source reappeared as live-ready shipper AP';
  END IF;
END
$terminal_posted_suppression$;

-- Before undoing proof mutations, verify customer, allocation-line, review and
-- shipment data remained unchanged. The allocation header and accounting tables
-- are intentionally changed only inside the savepoint and are checked after undo.
DO $protected_scope_before_undo$
DECLARE
  v_before protected_baseline%ROWTYPE;
  v_after protected_baseline%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM protected_baseline;

  SELECT
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sales_invoices t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_sales_release_lines t),
    NULL::text,
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocation_lines t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_order_review_links t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_memberships t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_legacy_issues t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipper_shipment_batches t),
    NULL::text,
    NULL::text,
    NULL::text
  INTO v_after;

  IF v_after.sales_invoices_fp IS DISTINCT FROM v_before.sales_invoices_fp
     OR v_after.release_lines_fp IS DISTINCT FROM v_before.release_lines_fp
     OR v_after.allocation_lines_fp IS DISTINCT FROM v_before.allocation_lines_fp
     OR v_after.review_links_fp IS DISTINCT FROM v_before.review_links_fp
     OR v_after.memberships_fp IS DISTINCT FROM v_before.memberships_fp
     OR v_after.legacy_issues_fp IS DISTINCT FROM v_before.legacy_issues_fp
     OR v_after.shipment_batches_fp IS DISTINCT FROM v_before.shipment_batches_fp THEN
    RAISE EXCEPTION 'FAIL: proof changed protected customer, allocation-line, review or shipment data';
  END IF;
END
$protected_scope_before_undo$;

ROLLBACK TO SAVEPOINT proof_mutations;

DO $post_savepoint_rollback_proof$
DECLARE
  v_before protected_baseline%ROWTYPE;
  v_after protected_baseline%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM protected_baseline;

  SELECT
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sales_invoices t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_sales_release_lines t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocations t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipping_cost_allocation_lines t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_order_review_links t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_memberships t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.customer_review_cycle_legacy_issues t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.shipper_shipment_batches t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sage_posting_snapshots t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sage_posting_batches t),
    (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM public.sage_posting_batch_rows t)
  INTO v_after;

  IF to_jsonb(v_after) IS DISTINCT FROM to_jsonb(v_before) THEN
    RAISE EXCEPTION 'FAIL: savepoint rollback did not restore protected source, allocation or accounting tables exactly';
  END IF;
END
$post_savepoint_rollback_proof$;

SELECT jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'approved allocation removed only inside savepoint; additive admission, full-amount freeze, frozen-row persistence, revalidation, idempotency, terminal-posted suppression and customer-recharge protection passed; savepoint rollback restored every protected fingerprint exactly'
) AS regression_result;

ROLLBACK;
