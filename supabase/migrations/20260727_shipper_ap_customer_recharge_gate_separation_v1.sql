BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- One production-object correction only: preserve the exact canonical queue and
-- add accepted/current shipper invoices excluded solely because customer shipping
-- apportionment is outstanding. Frozen/not-posted rows remain resolvable for
-- revalidation; terminally posted sources are not re-admitted. Customer recharge,
-- UI/actions, freeze payload, revalidation, Mini-build 4 and Sage posting remain unchanged.

DO $guard$
DECLARE
  v_result_shape text;
  v_owner text;
  v_language text;
  v_volatility "char";
  v_parallel "char";
  v_security_definer boolean;
  v_search_path text[];
  v_acl_mismatch bigint;
  v_default_acl_mismatch bigint;
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
    RAISE EXCEPTION 'Missing canonical queue: public.internal_ready_for_sage_queue_v2()';
  END IF;

  IF to_regprocedure('public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()') IS NOT NULL THEN
    RAISE EXCEPTION 'Gate-separation migration has already been applied; refusing rerun';
  END IF;

  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_shipping_ap_recharge_readiness_preview_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_freeze_shipper_ap_sage_batch_v1(uuid[],text)') IS NULL
     OR to_regprocedure('public.internal_revalidate_sage_posting_snapshots_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Required governed route is missing';
  END IF;

  IF to_regclass('public.shipping_documents') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shippers') IS NULL
     OR to_regclass('public.shipping_cost_allocations') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.sage_posting_batch_rows') IS NULL THEN
    RAISE EXCEPTION 'Required governed relation is missing';
  END IF;

  SELECT
    pg_get_function_result(p.oid),
    pg_get_userbyid(p.proowner),
    l.lanname,
    p.provolatile,
    p.proparallel,
    p.prosecdef,
    p.proconfig
  INTO
    v_result_shape,
    v_owner,
    v_language,
    v_volatility,
    v_parallel,
    v_security_definer,
    v_search_path
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_ready_for_sage_queue_v2'
    AND p.pronargs = 0;

  IF v_result_shape IS DISTINCT FROM
    'TABLE(queue_row_id text, document_lane text, document_type text, source_table text, source_id uuid, order_id uuid, order_ref text, shipment_batch_id uuid, booking_ref text, counterparty_name text, amount_gbp numeric, currency_code text, invoice_type text, sage_status text, sage_invoice_id text, sage_posted_at timestamp with time zone, readiness_status text, blocker text, reference_text text, notes_text text, detail_href text, source_payload jsonb)'
  THEN
    RAISE EXCEPTION 'Canonical queue return shape differs from governed live evidence: %', v_result_shape;
  END IF;

  IF v_owner IS DISTINCT FROM 'postgres'
     OR v_language IS DISTINCT FROM 'sql'
     OR v_volatility IS DISTINCT FROM 'v'
     OR v_parallel IS DISTINCT FROM 'u'
     OR v_security_definer IS DISTINCT FROM true
     OR v_search_path IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'Canonical queue execution properties differ from governed live evidence';
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
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    UNION ALL
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
  )
  SELECT COUNT(*) INTO v_acl_mismatch FROM differences;

  IF v_acl_mismatch <> 0
     OR has_function_privilege('anon', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('postgres', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Canonical queue ACL differs from governed live evidence';
  END IF;

  WITH actual AS (
    SELECT
      pg_get_userbyid(a.grantor)::text AS grantor_name,
      CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee)::text END AS grantee_name,
      a.privilege_type::text AS privilege_type,
      a.is_grantable
    FROM pg_default_acl d
    JOIN pg_roles owner_role ON owner_role.oid = d.defaclrole
    JOIN pg_namespace n ON n.oid = d.defaclnamespace
    CROSS JOIN LATERAL aclexplode(d.defaclacl) a
    WHERE d.defaclobjtype = 'f'
      AND owner_role.rolname = 'postgres'
      AND n.nspname = 'public'
  ), expected(grantor_name, grantee_name, privilege_type, is_grantable) AS (
    VALUES
      ('postgres', 'postgres', 'EXECUTE', false),
      ('postgres', 'anon', 'EXECUTE', false),
      ('postgres', 'authenticated', 'EXECUTE', false),
      ('postgres', 'service_role', 'EXECUTE', false)
  ), differences AS (
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    UNION ALL
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
  )
  SELECT COUNT(*) INTO v_default_acl_mismatch FROM differences;

  IF v_default_acl_mismatch <> 0 THEN
    RAISE EXCEPTION 'Public-schema default function ACL differs from governed live evidence';
  END IF;
END
$guard$;

ALTER FUNCTION public.internal_ready_for_sage_queue_v2()
  RENAME TO internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() FROM anon;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() FROM service_role;

CREATE FUNCTION public.internal_ready_for_sage_queue_v2()
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
SET search_path = public, pg_temp
AS $function$
  WITH preserved_queue AS (
    SELECT q.*
    FROM public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1() q
  ), additive_shipper_ap AS (
    SELECT
      ('shipping_ap_intent:' || document_row.id::text)::text AS queue_row_id,
      'shipper_ap'::text AS document_lane,
      'shipper_ap_purchase_invoice_intent'::text AS document_type,
      'shipping_documents'::text AS source_table,
      document_row.id AS source_id,
      NULL::uuid AS order_id,
      effective_orders.order_ref,
      document_row.shipment_batch_id,
      batch_row.booking_ref::text AS booking_ref,
      shipper_row.name::text AS counterparty_name,
      COALESCE(document_row.extracted_total_amount, document_row.total_amount)::numeric AS amount_gbp,
      COALESCE(
        NULLIF(document_row.extracted_currency_code::text, ''),
        NULLIF(document_row.currency_code::text, ''),
        'GBP'
      )::text AS currency_code,
      'purchase_invoice'::text AS invoice_type,
      'not_drafted'::text AS sage_status,
      NULL::text AS sage_invoice_id,
      NULL::timestamptz AS sage_posted_at,
      'ready_for_ap_purchase_invoice_draft'::text AS readiness_status,
      NULL::text AS blocker,
      COALESCE(
        NULLIF(document_row.extracted_document_ref::text, ''),
        NULLIF(document_row.document_ref::text, ''),
        NULLIF(batch_row.booking_ref::text, ''),
        document_row.id::text
      )::text AS reference_text,
      ('Booking ' || COALESCE(batch_row.booking_ref::text, ''))::text AS notes_text,
      ('/internal/shipping-control/readiness/' || document_row.shipment_batch_id::text)::text AS detail_href,
      jsonb_build_object(
        'document_ref', COALESCE(
          NULLIF(document_row.extracted_document_ref::text, ''),
          NULLIF(document_row.document_ref::text, '')
        ),
        'document_date', COALESCE(document_row.extracted_document_date, document_row.document_date),
        'booking_ref', batch_row.booking_ref::text,
        'shipper_name', shipper_row.name::text,
        'document_total', COALESCE(document_row.extracted_total_amount, document_row.total_amount),
        'currency', COALESCE(
          NULLIF(document_row.extracted_currency_code::text, ''),
          NULLIF(document_row.currency_code::text, ''),
          'GBP'
        ),
        'route', 'shipper_ap_purchase_invoice_intent',
        'status', 'source_ready_not_posted_to_sage'
      ) AS source_payload
    FROM public.shipping_documents document_row
    JOIN public.shipper_shipment_batches batch_row
      ON batch_row.id = document_row.shipment_batch_id
     AND batch_row.shipper_id = document_row.shipper_id
    JOIN public.shippers shipper_row
      ON shipper_row.id = document_row.shipper_id
    LEFT JOIN LATERAL (
      SELECT string_agg(
        DISTINCT order_row.order_ref::text,
        ', ' ORDER BY order_row.order_ref::text
      )::text AS order_ref
      FROM public.shipper_shipment_batch_effective_lines_v1(document_row.shipment_batch_id) effective_line
      JOIN public.orders order_row ON order_row.id = effective_line.order_id
    ) effective_orders ON true
    WHERE document_row.active = true
      AND document_row.superseded_at IS NULL
      AND document_row.replaced_by_document_id IS NULL
      AND document_row.document_kind = 'shipper_invoice'
      AND document_row.review_status = 'accepted_current'
      AND COALESCE(document_row.extracted_total_amount, document_row.total_amount, 0) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations allocation_row
        WHERE allocation_row.shipping_document_id = document_row.id
          AND allocation_row.active = true
          AND allocation_row.allocation_status = 'approved'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM preserved_queue existing_row
        WHERE existing_row.document_lane = 'shipper_ap'
          AND existing_row.source_table = 'shipping_documents'
          AND existing_row.source_id = document_row.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_snapshots snapshot_row
        WHERE snapshot_row.source_table = 'shipping_documents'
          AND snapshot_row.source_id = document_row.id
          AND snapshot_row.document_lane = 'shipper_ap'
          AND snapshot_row.sage_posting_status = 'posted'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_batch_rows batch_row_posted
        WHERE batch_row_posted.source_table = 'shipping_documents'
          AND batch_row_posted.source_id = document_row.id
          AND batch_row_posted.document_lane = 'shipper_ap'
          AND batch_row_posted.posting_status = 'posted'
      )
  )
  SELECT p.* FROM preserved_queue p
  UNION ALL
  SELECT a.* FROM additive_shipper_ap a;
$function$;

ALTER FUNCTION public.internal_ready_for_sage_queue_v2() OWNER TO postgres;

-- The verified public-schema default ACL grants anon/authenticated/service_role.
-- Neutralise it, then restore the exact canonical caller set.
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM anon;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM service_role;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO service_role;

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()
IS 'Private exact canonical Sage-ready queue immediately before shipper AP/customer recharge gate separation. Application roles cannot execute it.';

COMMENT ON FUNCTION public.internal_ready_for_sage_queue_v2()
IS 'Canonical Sage-ready queue. Preserves all preceding rows exactly and additively admits accepted current unapportioned, not-posted shipper invoices to the existing shipper-AP route. Customer shipping recharge remains governed by approved apportionment.';

DO $verify$
DECLARE
  v_acl_mismatch bigint;
  v_definition text;
  v_result_shape text;
  v_owner text;
  v_language text;
  v_volatility "char";
  v_parallel "char";
  v_security_definer boolean;
  v_search_path text[];
BEGIN
  SELECT
    pg_get_function_result(p.oid),
    pg_get_userbyid(p.proowner),
    l.lanname,
    p.provolatile,
    p.proparallel,
    p.prosecdef,
    p.proconfig
  INTO
    v_result_shape,
    v_owner,
    v_language,
    v_volatility,
    v_parallel,
    v_security_definer,
    v_search_path
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = 'public'
    AND p.proname = 'internal_ready_for_sage_queue_v2'
    AND p.pronargs = 0;

  IF v_result_shape IS DISTINCT FROM
       'TABLE(queue_row_id text, document_lane text, document_type text, source_table text, source_id uuid, order_id uuid, order_ref text, shipment_batch_id uuid, booking_ref text, counterparty_name text, amount_gbp numeric, currency_code text, invoice_type text, sage_status text, sage_invoice_id text, sage_posted_at timestamp with time zone, readiness_status text, blocker text, reference_text text, notes_text text, detail_href text, source_payload jsonb)'
     OR v_owner IS DISTINCT FROM 'postgres'
     OR v_language IS DISTINCT FROM 'sql'
     OR v_volatility IS DISTINCT FROM 'v'
     OR v_parallel IS DISTINCT FROM 'u'
     OR v_security_definer IS DISTINCT FROM true
     OR v_search_path IS DISTINCT FROM ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'Replacement canonical queue catalogue properties do not match governed live state';
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
    (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    UNION ALL
    (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
  )
  SELECT COUNT(*) INTO v_acl_mismatch FROM differences;

  IF v_acl_mismatch <> 0
     OR has_function_privilege('anon', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE')
     OR NOT has_function_privilege('postgres', 'public.internal_ready_for_sage_queue_v2()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Replacement canonical queue ACL does not match governed live state';
  END IF;

  IF has_function_privilege('anon', 'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()', 'EXECUTE')
     OR has_function_privilege('service_role', 'public.internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Private preserved queue remains executable by an application role';
  END IF;

  SELECT lower(pg_get_functiondef('public.internal_ready_for_sage_queue_v2()'::regprocedure))
  INTO v_definition;

  IF position('shipper_shipment_batch_effective_lines_v1' IN v_definition) = 0
     OR position('internal_ready_for_sage_queue_v2_pre_shipper_ap_gate_separation_v1' IN v_definition) = 0
     OR position('allocation_status = ''approved''' IN v_definition) = 0
     OR position('sage_posting_status = ''posted''' IN v_definition) = 0
     OR position('posting_status = ''posted''' IN v_definition) = 0
     OR position('customer_recharge_apportionment_status' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'Replacement canonical queue does not match governed composition boundary';
  END IF;
END
$verify$;

NOTIFY pgrst, 'reload schema';

COMMIT;
