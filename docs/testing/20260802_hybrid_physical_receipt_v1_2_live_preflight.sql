-- Hybrid Physical Receipt Implementation Alignment Addendum v1.2
-- Live database preflight and evidence capture.
--
-- This script is intentionally read-only. It must run before implementation SQL
-- is finalised or applied. Any failed assertion stops the build. The transaction
-- always ends in ROLLBACK.

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $required_objects$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.physical_receipt_reviews') IS NULL THEN
    v_missing := array_append(v_missing, 'public.physical_receipt_reviews');
  END IF;
  IF to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN
    v_missing := array_append(v_missing, 'public.physical_exception_remedy_allocations');
  END IF;
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL THEN
    v_missing := array_append(v_missing, 'public.shipper_package_receipt_line_dispositions');
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    v_missing := array_append(v_missing, 'public.order_tracking_line_allocations');
  END IF;
  IF to_regclass('public.physical_receipt_review_dispute_links') IS NULL THEN
    v_missing := array_append(v_missing, 'public.physical_receipt_review_dispute_links');
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    v_missing := array_append(v_missing, 'public.disputes');
  END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'public.dispute_lines');
  END IF;
  IF to_regclass('public.dispute_return_tracking_submissions') IS NULL THEN
    v_missing := array_append(v_missing, 'public.dispute_return_tracking_submissions');
  END IF;
  IF to_regclass('public.shipper_return_task_confirmations') IS NULL THEN
    v_missing := array_append(v_missing, 'public.shipper_return_task_confirmations');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'V1.2 preflight missing required relations: %', array_to_string(v_missing, ', ');
  END IF;
END
$required_objects$;

DO $required_columns$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_exception_remedy_allocations'
      AND column_name = 'customer_commercial_value_gbp'
  ) THEN
    v_missing := array_append(v_missing, 'physical_exception_remedy_allocations.customer_commercial_value_gbp');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_exception_remedy_allocations'
      AND column_name = 'tracking_line_allocation_id'
  ) THEN
    v_missing := array_append(v_missing, 'physical_exception_remedy_allocations.tracking_line_allocation_id');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_exception_remedy_allocations'
      AND column_name = 'replacement_child_order_id'
  ) THEN
    v_missing := array_append(v_missing, 'physical_exception_remedy_allocations.replacement_child_order_id');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_tracking_line_allocations'
      AND column_name = 'adjusted_net_value_gbp'
  ) THEN
    v_missing := array_append(v_missing, 'order_tracking_line_allocations.adjusted_net_value_gbp');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dispute_lines'
      AND column_name = 'physical_remedy_allocation_id'
  ) THEN
    v_missing := array_append(v_missing, 'dispute_lines.physical_remedy_allocation_id');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dispute_lines'
      AND column_name = 'resolved_via_child_order_id'
  ) THEN
    v_missing := array_append(v_missing, 'dispute_lines.resolved_via_child_order_id');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION 'V1.2 preflight missing required columns: %', array_to_string(v_missing, ', ');
  END IF;
END
$required_columns$;

CREATE TEMP TABLE v12_function_fingerprints (
  identity text PRIMARY KEY,
  function_oid oid,
  owner_name text,
  security_definer boolean,
  acl text,
  config text,
  definition_md5 text,
  canonical_md5 text
) ON COMMIT DROP;

DO $capture_functions$
DECLARE
  v_identity text;
  v_oid oid;
BEGIN
  FOREACH v_identity IN ARRAY ARRAY[
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
    'public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)',
    'public.staff_accept_replacement_outcome_v1(uuid,uuid,text)',
    'public.create_replacement_child_order_v2(uuid,uuid,uuid,text)',
    'public.shipper_return_tasks_v1()',
    'public.shipper_submit_return_task_confirmation_v1(uuid,text,text,text,text)',
    'public.internal_shipper_return_task_confirmations_v1(boolean)',
    'public.physical_remedy_allocation_guard_v2()',
    'public.physical_remedy_sequence_guard_v1()',
    'public.physical_receipt_review_guard_v1()'
  ]
  LOOP
    v_oid := to_regprocedure(v_identity);
    IF v_oid IS NULL THEN
      RAISE EXCEPTION 'V1.2 preflight missing required function: %', v_identity;
    END IF;

    INSERT INTO v12_function_fingerprints(
      identity,
      function_oid,
      owner_name,
      security_definer,
      acl,
      config,
      definition_md5,
      canonical_md5
    )
    SELECT
      v_identity,
      p.oid,
      pg_get_userbyid(p.proowner),
      p.prosecdef,
      COALESCE(p.proacl::text, ''),
      COALESCE(array_to_string(p.proconfig, ','), ''),
      md5(pg_get_functiondef(p.oid)),
      md5(concat_ws('|',
        p.prosrc,
        l.lanname,
        p.provolatile,
        p.prosecdef::text,
        p.proisstrict::text,
        p.proparallel,
        p.proleakproof::text,
        p.prorettype::regtype::text,
        p.proargtypes::text,
        COALESCE(array_to_string(p.proconfig, ','), '')
      ))
    FROM pg_proc p
    JOIN pg_language l ON l.oid = p.prolang
    WHERE p.oid = v_oid;
  END LOOP;
END
$capture_functions$;

-- The refund evidence and return review functions have changed signatures across
-- historical builds. Capture every live overload by name rather than guessing one.
INSERT INTO v12_function_fingerprints(
  identity,
  function_oid,
  owner_name,
  security_definer,
  acl,
  config,
  definition_md5,
  canonical_md5
)
SELECT
  format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)),
  p.oid,
  pg_get_userbyid(p.proowner),
  p.prosecdef,
  COALESCE(p.proacl::text, ''),
  COALESCE(array_to_string(p.proconfig, ','), ''),
  md5(pg_get_functiondef(p.oid)),
  md5(concat_ws('|',
    p.prosrc,
    l.lanname,
    p.provolatile,
    p.prosecdef::text,
    p.proisstrict::text,
    p.proparallel,
    p.proleakproof::text,
    p.prorettype::regtype::text,
    p.proargtypes::text,
    COALESCE(array_to_string(p.proconfig, ','), '')
  ))
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
JOIN pg_language l ON l.oid = p.prolang
WHERE n.nspname = 'public'
  AND p.proname IN (
    'operator_submit_refund_document_evidence',
    'operator_submit_return_collection_tracking',
    'staff_review_return_collection_tracking',
    'staff_review_shipper_return_task_confirmation_v1'
  )
ON CONFLICT (identity) DO NOTHING;

DO $function_assertions$
DECLARE
  v_bridge text;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM v12_function_fingerprints
    WHERE identity LIKE 'public.operator_submit_refund_document_evidence(%'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight missing operator_submit_refund_document_evidence overload.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM v12_function_fingerprints
    WHERE identity LIKE 'public.operator_submit_return_collection_tracking(%'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight missing operator_submit_return_collection_tracking overload.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM v12_function_fingerprints
    WHERE identity LIKE 'public.staff_review_return_collection_tracking(%'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight missing staff_review_return_collection_tracking overload.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM v12_function_fingerprints
    WHERE identity LIKE 'public.staff_review_shipper_return_task_confirmation_v1(%'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight missing staff_review_shipper_return_task_confirmation_v1 overload.';
  END IF;

  SELECT pg_get_functiondef(
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'::regprocedure
  ) INTO v_bridge;

  IF position('LINK_SHAPE_SEQUENCE_V1' IN v_bridge) = 0 THEN
    RAISE EXCEPTION 'V1.2 preflight: supervisor bridge lost LINK_SHAPE_SEQUENCE_V1.';
  END IF;
  IF position('amount_impact_gbp' IN v_bridge) = 0
     OR position('physical_receipt_review_dispute_links' IN v_bridge) = 0 THEN
    RAISE EXCEPTION 'V1.2 preflight: supervisor bridge no longer matches reviewed structural shape.';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight: anon unexpectedly has direct supervisor bridge execute.';
  END IF;

  IF has_function_privilege(
    'authenticated',
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight: authenticated unexpectedly has direct supervisor bridge execute.';
  END IF;
END
$function_assertions$;

CREATE TEMP TABLE v12_trigger_bindings AS
SELECT
  c.oid::regclass::text AS relation_name,
  t.tgname AS trigger_name,
  t.tgfoid::regprocedure::text AS function_identity,
  t.tgenabled,
  md5(pg_get_triggerdef(t.oid)) AS trigger_definition_md5,
  pg_get_triggerdef(t.oid) AS trigger_definition
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND NOT t.tgisinternal
  AND (
    c.relname IN ('physical_receipt_reviews', 'physical_exception_remedy_allocations')
    OR t.tgfoid IN (
      'public.physical_remedy_allocation_guard_v2()'::regprocedure,
      'public.physical_remedy_sequence_guard_v1()'::regprocedure,
      'public.physical_receipt_review_guard_v1()'::regprocedure
    )
  );

DO $trigger_assertions$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM v12_trigger_bindings
    WHERE function_identity = 'physical_remedy_allocation_guard_v2()'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight: physical_remedy_allocation_guard_v2 is not attached.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM v12_trigger_bindings
    WHERE function_identity = 'physical_remedy_sequence_guard_v1()'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight: physical_remedy_sequence_guard_v1 is not attached.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM v12_trigger_bindings
    WHERE function_identity = 'physical_receipt_review_guard_v1()'
  ) THEN
    RAISE EXCEPTION 'V1.2 preflight: physical_receipt_review_guard_v1 is not attached.';
  END IF;
END
$trigger_assertions$;

CREATE TEMP TABLE v12_pending_confirmation_state AS
SELECT
  return_tracking_submission_id,
  count(*)::integer AS pending_count,
  array_agg(id ORDER BY submitted_at, id) AS confirmation_ids
FROM public.shipper_return_task_confirmations
WHERE review_status = 'pending_review'
GROUP BY return_tracking_submission_id;

DO $pending_confirmation_assertion$
DECLARE
  v_conflicts integer;
BEGIN
  SELECT count(*) INTO v_conflicts
  FROM v12_pending_confirmation_state
  WHERE pending_count > 1;

  IF v_conflicts > 0 THEN
    RAISE EXCEPTION
      'V1.2 preflight: % return submissions already have more than one pending shipper confirmation. Resolve before adding the uniqueness invariant.',
      v_conflicts;
  END IF;
END
$pending_confirmation_assertion$;

CREATE TEMP TABLE v12_confirmed_value_case AS
SELECT
  o.id AS order_id,
  o.order_ref,
  review_row.id AS review_id,
  remedy.id AS remedy_allocation_id,
  remedy.status AS remedy_status,
  remedy.approved_remedy_type,
  remedy.approved_remedy_qty,
  remedy.customer_commercial_value_gbp,
  remedy.replacement_child_order_id AS remedy_child_order_id,
  allocation.id AS tracking_allocation_id,
  allocation.qty_allocated,
  allocation.adjusted_net_value_gbp,
  remedy.supplier_invoice_line_id,
  dl.id AS dispute_line_id,
  dl.qty_impact,
  dl.amount_impact_gbp AS dispute_line_amount_gbp,
  dl.resolved_at AS dispute_line_resolved_at,
  dl.resolved_via_child_order_id,
  d.id AS dispute_id,
  d.desired_outcome,
  d.status AS dispute_status,
  d.amount_impact_gbp AS dispute_amount_gbp,
  d.resolved_at AS dispute_resolved_at,
  d.replacement_child_order_id AS dispute_child_order_id
FROM public.physical_exception_remedy_allocations remedy
JOIN public.physical_receipt_reviews review_row
  ON review_row.id = remedy.physical_receipt_review_id
JOIN public.orders o ON o.id = review_row.order_id
JOIN public.order_tracking_line_allocations allocation
  ON allocation.id = remedy.tracking_line_allocation_id
LEFT JOIN public.dispute_lines dl ON dl.id = remedy.dispute_line_id
LEFT JOIN public.disputes d ON d.id = dl.dispute_id
WHERE o.id = '8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
  AND review_row.id = '1987393f-47ba-4460-96f6-598e0e52792d'::uuid
  AND remedy.id = '9e7f6c25-e920-4c90-a16a-0ffb6381a3d6'::uuid
  AND allocation.id = '5dbd95c5-c0d0-489d-973d-fab4c9083160'::uuid
  AND remedy.supplier_invoice_line_id = '0985538e-e9bb-42f2-8e3c-8cf11063705e'::uuid
  AND dl.id = '126ed01a-09b4-47e4-a2db-c52e7480d814'::uuid
  AND d.id = 'd7b32314-603e-49bf-83d1-1a01e2e4d29f'::uuid;

DO $confirmed_case_assertion$
DECLARE
  v_case v12_confirmed_value_case%ROWTYPE;
BEGIN
  SELECT * INTO v_case FROM v12_confirmed_value_case;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'V1.2 preflight: confirmed GBP 60 provenance chain no longer matches.';
  END IF;

  IF v_case.qty_allocated IS DISTINCT FROM 1::numeric
     OR v_case.adjusted_net_value_gbp IS DISTINCT FROM 60::numeric
     OR v_case.approved_remedy_type IS DISTINCT FROM 'replacement'
     OR v_case.approved_remedy_qty IS DISTINCT FROM 1::numeric
     OR v_case.qty_impact IS DISTINCT FROM 1
  THEN
    RAISE EXCEPTION 'V1.2 preflight: confirmed GBP 60 source quantity/value facts differ from the reviewed case.';
  END IF;

  IF v_case.remedy_child_order_id IS NOT NULL
     OR v_case.dispute_child_order_id IS NOT NULL
     OR v_case.resolved_via_child_order_id IS NOT NULL
  THEN
    RAISE EXCEPTION 'V1.2 preflight: confirmed GBP 60 case has already created a replacement child; do not apply the repair blindly.';
  END IF;

  IF v_case.customer_commercial_value_gbp IS NULL
     AND COALESCE(v_case.dispute_line_amount_gbp, 0) = 0
     AND COALESCE(v_case.dispute_amount_gbp, 0) = 0
  THEN
    RAISE NOTICE 'V1.2 preflight: confirmed GBP 60 case is in the exact reviewed broken state.';
  ELSIF v_case.customer_commercial_value_gbp = 60
     AND v_case.dispute_line_amount_gbp = 60
     AND v_case.dispute_amount_gbp = 60
  THEN
    RAISE NOTICE 'V1.2 preflight: confirmed GBP 60 case is already repaired; the repair migration must be idempotent and verify this exact state.';
  ELSE
    RAISE EXCEPTION 'V1.2 preflight: confirmed GBP 60 case is neither the exact broken state nor the exact repaired state.';
  END IF;
END
$confirmed_case_assertion$;

-- Evidence output. Preserve these result sets with the implementation review.
SELECT *
FROM v12_function_fingerprints
ORDER BY identity;

SELECT *
FROM v12_trigger_bindings
ORDER BY relation_name, trigger_name;

SELECT
  indexname,
  indexdef
FROM pg_indexes
WHERE schemaname = 'public'
  AND tablename IN (
    'physical_receipt_review_dispute_links',
    'physical_exception_remedy_allocations',
    'dispute_lines',
    'shipper_return_task_confirmations'
  )
ORDER BY tablename, indexname;

SELECT
  table_name,
  column_name,
  data_type,
  udt_name,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
    'physical_receipt_reviews',
    'physical_exception_remedy_allocations',
    'shipper_package_receipt_line_dispositions',
    'order_tracking_line_allocations',
    'physical_receipt_review_dispute_links',
    'disputes',
    'dispute_lines',
    'dispute_return_tracking_submissions',
    'shipper_return_task_confirmations'
  )
ORDER BY table_name, ordinal_position;

SELECT *
FROM v12_pending_confirmation_state
ORDER BY return_tracking_submission_id;

SELECT *
FROM v12_confirmed_value_case;

ROLLBACK;
