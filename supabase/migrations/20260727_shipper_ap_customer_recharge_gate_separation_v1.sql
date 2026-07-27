BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- One production-object correction only:
-- preserve the exact canonical Sage-ready queue, then add only accepted/current
-- shipper invoices withheld solely because customer shipping apportionment is
-- not yet approved. Customer recharge, UI/actions, Mini-build 4, freeze payload
-- construction and Sage posting remain unchanged.

DO $prerequisites$
BEGIN
  IF to_regprocedure(
       'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()'
     ) IS NOT NULL THEN
    RAISE EXCEPTION
      'Shipper AP gate-separation migration was already applied, or a later canonical queue exists. Refusing rerun.';
  END IF;

  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v2()';
  END IF;

  IF to_regclass('public.shipping_documents') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.shippers') IS NULL
     OR to_regclass('public.order_tracking_submissions') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.shipping_cost_allocations') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.sage_posting_batch_rows') IS NULL
     OR to_regclass('public.sage_posting_batches') IS NULL THEN
    RAISE EXCEPTION 'Shipper AP gate-separation table prerequisites are missing';
  END IF;

  IF to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_revalidate_sage_posting_snapshots_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Required shipper-AP or customer-sales function is missing';
  END IF;
END
$prerequisites$;

CREATE TEMP TABLE pg_temp.shipper_ap_gate_queue_metadata
ON COMMIT DROP
AS
SELECT
  procedure_row.oid AS function_oid,
  procedure_row.proowner AS owner_oid,
  pg_get_userbyid(procedure_row.proowner) AS owner_name,
  language_row.lanname AS language_name,
  procedure_row.provolatile,
  procedure_row.proparallel,
  procedure_row.prosecdef,
  procedure_row.proleakproof,
  procedure_row.proisstrict,
  procedure_row.procost,
  procedure_row.prorows,
  procedure_row.proconfig,
  procedure_row.proacl,
  pg_get_function_result(procedure_row.oid) AS result_shape
FROM pg_proc procedure_row
JOIN pg_namespace namespace_row
  ON namespace_row.oid = procedure_row.pronamespace
JOIN pg_language language_row
  ON language_row.oid = procedure_row.prolang
WHERE namespace_row.nspname = 'public'
  AND procedure_row.proname = 'internal_ready_for_sage_queue_v2'
  AND procedure_row.pronargs = 0;

CREATE TEMP TABLE pg_temp.shipper_ap_gate_queue_explicit_acl
ON COMMIT DROP
AS
SELECT
  privilege_row.grantee,
  privilege_row.privilege_type,
  privilege_row.is_grantable
FROM pg_proc procedure_row
JOIN pg_namespace namespace_row
  ON namespace_row.oid = procedure_row.pronamespace
CROSS JOIN LATERAL aclexplode(procedure_row.proacl) privilege_row
WHERE namespace_row.nspname = 'public'
  AND procedure_row.proname = 'internal_ready_for_sage_queue_v2'
  AND procedure_row.pronargs = 0
  AND procedure_row.proacl IS NOT NULL;

DO $preserve$
DECLARE
  v_metadata pg_temp.shipper_ap_gate_queue_metadata%ROWTYPE;
  v_expected_shape text :=
    'TABLE(queue_row_id text, document_lane text, document_type text, source_table text, source_id uuid, order_id uuid, order_ref text, shipment_batch_id uuid, booking_ref text, counterparty_name text, amount_gbp numeric, currency_code text, invoice_type text, sage_status text, sage_invoice_id text, sage_posted_at timestamp with time zone, readiness_status text, blocker text, reference_text text, notes_text text, detail_href text, source_payload jsonb)';
BEGIN
  SELECT * INTO v_metadata
  FROM pg_temp.shipper_ap_gate_queue_metadata;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Canonical Sage queue metadata could not be captured';
  END IF;

  IF trim(regexp_replace(v_metadata.result_shape, '\s+', ' ', 'g'))
       IS DISTINCT FROM v_expected_shape THEN
    RAISE EXCEPTION
      'Canonical Sage queue return shape drifted; refusing unsafe wrapper. Actual: %',
      v_metadata.result_shape;
  END IF;

  IF v_metadata.language_name IS DISTINCT FROM 'sql'
     OR v_metadata.provolatile IS DISTINCT FROM 'v'
     OR v_metadata.proparallel IS DISTINCT FROM 'u'
     OR v_metadata.prosecdef IS DISTINCT FROM true
     OR v_metadata.proleakproof IS DISTINCT FROM false
     OR v_metadata.proisstrict IS DISTINCT FROM false
     OR v_metadata.proconfig IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION
      'Canonical Sage queue execution properties drifted; refusing unsafe replacement';
  END IF;

  ALTER FUNCTION public.internal_ready_for_sage_queue_v2()
    RENAME TO internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1;
END
$preserve$;

REVOKE ALL ON FUNCTION
  public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()
FROM PUBLIC;

DO $privatise_preserved$
DECLARE
  v_acl record;
  v_owner_oid oid;
BEGIN
  SELECT owner_oid INTO v_owner_oid
  FROM pg_temp.shipper_ap_gate_queue_metadata;

  FOR v_acl IN
    SELECT DISTINCT grantee
    FROM pg_temp.shipper_ap_gate_queue_explicit_acl
    WHERE grantee <> 0
      AND grantee <> v_owner_oid
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() FROM %I',
      pg_get_userbyid(v_acl.grantee)
    );
  END LOOP;
END
$privatise_preserved$;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE sql
VOLATILE
PARALLEL UNSAFE
SECURITY DEFINER
CALLED ON NULL INPUT
SET search_path = public, pg_temp
AS $function$
  WITH preserved_queue AS (
    SELECT q.*
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() q
  ), accepted_unapportioned_shipper_documents AS (
    SELECT
      shipping_document.id AS shipping_document_id,
      shipping_document.shipment_batch_id,
      shipment_batch.booking_ref::text AS booking_ref,
      shipper.name::text AS shipper_name,
      COALESCE(
        NULLIF(shipping_document.extracted_document_ref::text, ''),
        NULLIF(shipping_document.document_ref::text, '')
      )::text AS document_ref,
      COALESCE(
        shipping_document.extracted_document_date,
        shipping_document.document_date
      ) AS document_date,
      COALESCE(
        shipping_document.extracted_total_amount,
        shipping_document.total_amount
      )::numeric AS document_total,
      COALESCE(
        NULLIF(shipping_document.extracted_currency_code::text, ''),
        NULLIF(shipping_document.currency_code::text, ''),
        'GBP'
      )::text AS currency_code,
      order_references.order_ref
    FROM public.shipping_documents shipping_document
    JOIN public.shipper_shipment_batches shipment_batch
      ON shipment_batch.id = shipping_document.shipment_batch_id
     AND shipment_batch.shipper_id = shipping_document.shipper_id
    JOIN public.shippers shipper
      ON shipper.id = shipping_document.shipper_id
    LEFT JOIN LATERAL (
      SELECT string_agg(
        DISTINCT order_row.order_ref::text,
        ', ' ORDER BY order_row.order_ref::text
      )::text AS order_ref
      FROM public.shipper_shipment_batch_packages package
      JOIN public.order_tracking_submissions tracking
        ON tracking.id = package.tracking_submission_id
      JOIN public.orders order_row
        ON order_row.id = tracking.order_id
      WHERE package.shipment_batch_id = shipping_document.shipment_batch_id
        AND package.active = true
    ) order_references ON true
    WHERE shipping_document.active = true
      AND shipping_document.superseded_at IS NULL
      AND shipping_document.replaced_by_document_id IS NULL
      AND shipping_document.document_kind = 'shipper_invoice'
      AND shipping_document.review_status = 'accepted_current'
      AND COALESCE(
        shipping_document.extracted_total_amount,
        shipping_document.total_amount,
        0
      ) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations allocation
        WHERE allocation.shipping_document_id = shipping_document.id
          AND allocation.active = true
          AND allocation.allocation_status = 'approved'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM preserved_queue existing
        WHERE existing.document_lane = 'shipper_ap'
          AND existing.source_table = 'shipping_documents'
          AND existing.source_id = shipping_document.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_snapshots snapshot
        WHERE snapshot.source_table = 'shipping_documents'
          AND snapshot.source_id = shipping_document.id
          AND snapshot.document_lane = 'shipper_ap'
          AND snapshot.active = true
          AND snapshot.approval_status = 'approved_frozen'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_batch_rows batch_row
        JOIN public.sage_posting_batches posting_batch
          ON posting_batch.id = batch_row.batch_id
        WHERE batch_row.source_table = 'shipping_documents'
          AND batch_row.source_id = shipping_document.id
          AND batch_row.document_lane = 'shipper_ap'
          AND batch_row.posting_status NOT IN ('excluded', 'cancelled')
          AND COALESCE(posting_batch.status, '') <> 'cancelled'
          AND COALESCE(posting_batch.batch_status, '') <> 'superseded'
      )
  ), additive_shipper_ap AS (
    SELECT
      ('shipping_ap_intent:' || source.shipping_document_id::text)::text AS queue_row_id,
      'shipper_ap'::text AS document_lane,
      'shipper_ap_purchase_invoice_intent'::text AS document_type,
      'shipping_documents'::text AS source_table,
      source.shipping_document_id AS source_id,
      NULL::uuid AS order_id,
      source.order_ref,
      source.shipment_batch_id,
      source.booking_ref,
      source.shipper_name AS counterparty_name,
      source.document_total AS amount_gbp,
      source.currency_code,
      'purchase_invoice'::text AS invoice_type,
      'not_drafted'::text AS sage_status,
      NULL::text AS sage_invoice_id,
      NULL::timestamptz AS sage_posted_at,
      'ready_for_ap_purchase_invoice_draft'::text AS readiness_status,
      NULL::text AS blocker,
      COALESCE(
        NULLIF(source.document_ref, ''),
        NULLIF(source.booking_ref, ''),
        source.shipping_document_id::text
      )::text AS reference_text,
      ('Booking ' || COALESCE(source.booking_ref, ''))::text AS notes_text,
      ('/internal/shipping-control/readiness/' || source.shipment_batch_id::text)::text AS detail_href,
      jsonb_build_object(
        'document_ref', source.document_ref,
        'document_date', source.document_date,
        'booking_ref', source.booking_ref,
        'shipper_name', source.shipper_name,
        'document_total', source.document_total,
        'currency', source.currency_code,
        'route', 'shipper_ap_purchase_invoice_intent',
        'status', 'source_ready_not_posted_to_sage'
      ) AS source_payload
    FROM accepted_unapportioned_shipper_documents source
  )
  SELECT * FROM preserved_queue
  UNION ALL
  SELECT * FROM additive_shipper_ap;
$function$;

DO $restore_metadata$
DECLARE
  v_metadata pg_temp.shipper_ap_gate_queue_metadata%ROWTYPE;
  v_acl record;
  v_target text;
BEGIN
  SELECT * INTO v_metadata
  FROM pg_temp.shipper_ap_gate_queue_metadata;

  EXECUTE format(
    'ALTER FUNCTION public.internal_ready_for_sage_queue_v2() OWNER TO %I',
    v_metadata.owner_name
  );
  EXECUTE format(
    'ALTER FUNCTION public.internal_ready_for_sage_queue_v2() COST %s',
    v_metadata.procost
  );
  EXECUTE format(
    'ALTER FUNCTION public.internal_ready_for_sage_queue_v2() ROWS %s',
    v_metadata.prorows
  );

  REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;

  FOR v_acl IN
    SELECT grantee, privilege_type, is_grantable
    FROM pg_temp.shipper_ap_gate_queue_explicit_acl
  LOOP
    v_target := CASE
      WHEN v_acl.grantee = 0 THEN 'PUBLIC'
      ELSE format('%I', pg_get_userbyid(v_acl.grantee))
    END;

    EXECUTE format(
      'GRANT %s ON FUNCTION public.internal_ready_for_sage_queue_v2() TO %s%s',
      v_acl.privilege_type,
      v_target,
      CASE WHEN v_acl.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
    );
  END LOOP;
END
$restore_metadata$;

COMMENT ON FUNCTION
  public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()
IS
  'Private exact canonical Sage-ready queue immediately before shipper AP/customer recharge gate separation. Not callable by application roles.';

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2()
IS
  'Canonical Sage-ready queue. Preserves every preceding row unchanged and additively exposes accepted current shipper invoices for shipper AP before customer shipping apportionment. Customer shipping recharge remains governed by approved allocation and the existing customer-sales release route.';

DO $static_verify$
DECLARE
  v_before pg_temp.shipper_ap_gate_queue_metadata%ROWTYPE;
  v_after pg_temp.shipper_ap_gate_queue_metadata%ROWTYPE;
  v_definition text;
  v_acl_difference bigint;
  v_private_application_grants bigint;
BEGIN
  SELECT * INTO v_before
  FROM pg_temp.shipper_ap_gate_queue_metadata;

  SELECT
    procedure_row.oid,
    procedure_row.proowner,
    pg_get_userbyid(procedure_row.proowner),
    language_row.lanname,
    procedure_row.provolatile,
    procedure_row.proparallel,
    procedure_row.prosecdef,
    procedure_row.proleakproof,
    procedure_row.proisstrict,
    procedure_row.procost,
    procedure_row.prorows,
    procedure_row.proconfig,
    procedure_row.proacl,
    pg_get_function_result(procedure_row.oid)
  INTO v_after
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  JOIN pg_language language_row
    ON language_row.oid = procedure_row.prolang
  WHERE namespace_row.nspname = 'public'
    AND procedure_row.proname = 'internal_ready_for_sage_queue_v2'
    AND procedure_row.pronargs = 0;

  IF v_after.owner_oid IS DISTINCT FROM v_before.owner_oid
     OR v_after.language_name IS DISTINCT FROM v_before.language_name
     OR v_after.provolatile IS DISTINCT FROM v_before.provolatile
     OR v_after.proparallel IS DISTINCT FROM v_before.proparallel
     OR v_after.prosecdef IS DISTINCT FROM v_before.prosecdef
     OR v_after.proleakproof IS DISTINCT FROM v_before.proleakproof
     OR v_after.proisstrict IS DISTINCT FROM v_before.proisstrict
     OR v_after.procost IS DISTINCT FROM v_before.procost
     OR v_after.prorows IS DISTINCT FROM v_before.prorows
     OR v_after.proconfig IS DISTINCT FROM v_before.proconfig
     OR trim(regexp_replace(v_after.result_shape, '\s+', ' ', 'g'))
        IS DISTINCT FROM trim(regexp_replace(v_before.result_shape, '\s+', ' ', 'g')) THEN
    RAISE EXCEPTION 'Canonical Sage queue metadata was not preserved exactly';
  END IF;

  WITH current_explicit_acl AS (
    SELECT
      privilege_row.grantee,
      privilege_row.privilege_type,
      privilege_row.is_grantable
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace_row
      ON namespace_row.oid = procedure_row.pronamespace
    CROSS JOIN LATERAL aclexplode(procedure_row.proacl) privilege_row
    WHERE namespace_row.nspname = 'public'
      AND procedure_row.proname = 'internal_ready_for_sage_queue_v2'
      AND procedure_row.pronargs = 0
      AND procedure_row.proacl IS NOT NULL
  ), differences AS (
    (SELECT * FROM pg_temp.shipper_ap_gate_queue_explicit_acl
     EXCEPT SELECT * FROM current_explicit_acl)
    UNION ALL
    (SELECT * FROM current_explicit_acl
     EXCEPT SELECT * FROM pg_temp.shipper_ap_gate_queue_explicit_acl)
  )
  SELECT COUNT(*) INTO v_acl_difference
  FROM differences;

  IF v_acl_difference <> 0 THEN
    RAISE EXCEPTION 'Canonical Sage queue explicit EXECUTE grants were not preserved exactly';
  END IF;

  SELECT COUNT(*)
  INTO v_private_application_grants
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  CROSS JOIN LATERAL aclexplode(
    COALESCE(procedure_row.proacl, acldefault('f', procedure_row.proowner))
  ) privilege_row
  LEFT JOIN pg_roles grantee_role
    ON grantee_role.oid = privilege_row.grantee
  WHERE namespace_row.nspname = 'public'
    AND procedure_row.proname =
      'internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1'
    AND procedure_row.pronargs = 0
    AND privilege_row.privilege_type = 'EXECUTE'
    AND (
      privilege_row.grantee = 0
      OR grantee_role.rolname IN ('anon', 'authenticated', 'service_role')
    );

  IF v_private_application_grants <> 0 THEN
    RAISE EXCEPTION 'Private preserved Sage queue remains callable by an application role';
  END IF;

  SELECT lower(
    pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure)
  ) INTO v_definition;

  IF position(
       'internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1'
       IN v_definition
     ) = 0
     OR position('review_status = ''accepted_current''' IN v_definition) = 0
     OR position('document_kind = ''shipper_invoice''' IN v_definition) = 0
     OR position('shipping_cost_allocations' IN v_definition) = 0
     OR position('allocation_status = ''approved''' IN v_definition) = 0
     OR position('shipping_document.extracted_total_amount' IN v_definition) = 0
     OR position('shipping_document.total_amount' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Canonical Sage queue wrapper is missing a required governed condition';
  END IF;

  IF position('customer_recharge_apportionment_status' IN v_definition) > 0
     OR position('''shipping_document_date''' IN v_definition) > 0
     OR position('customer_order_review_links' IN v_definition) > 0
     OR position('customer_review_cycle_memberships' IN v_definition) > 0
     OR position('internal_materialize_customer_review_cycles_v1' IN v_definition) > 0
     OR position('shipper_tracking_review_state_v1' IN v_definition) > 0
     OR position('shipper_shipment_batch_candidates_v1' IN v_definition) > 0
     OR position('shipper_create_shipment_batch_v1' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'Canonical Sage queue wrapper exceeded the governed change boundary';
  END IF;
END
$static_verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
