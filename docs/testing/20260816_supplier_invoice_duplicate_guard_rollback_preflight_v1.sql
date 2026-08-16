-- Supplier invoice duplicate-guard rollback preflight v1
-- READ ONLY. Makes no database changes.
-- Governing authority:
-- docs/governing-pack/architecture/SUPPLIER_INVOICE_DUPLICATION_REVIEW_AND_ROLLBACK_CONTROL_ADDENDUM_v1.md

BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';

WITH
bad_trigger AS (
  SELECT
    t.oid AS trigger_oid,
    t.tgname,
    c.oid AS table_oid,
    n.nspname AS table_schema,
    c.relname AS table_name,
    p.oid AS function_oid,
    nsp.nspname AS function_schema,
    p.proname AS function_name,
    pg_get_triggerdef(t.oid, true) AS trigger_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'supplier_invoices'
    AND t.tgname = 'trg_supplier_invoice_cross_order_duplicate_guard_v1'
    AND NOT t.tgisinternal
),
bad_guard AS (
  SELECT
    p.oid,
    n.nspname AS schema_name,
    p.proname,
    pg_get_function_identity_arguments(p.oid) AS identity_args,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.oid = to_regprocedure('public.supplier_invoice_cross_order_duplicate_guard_v1()')
),
bad_normaliser AS (
  SELECT
    p.oid,
    n.nspname AS schema_name,
    p.proname,
    pg_get_function_identity_arguments(p.oid) AS identity_args,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE p.oid = to_regprocedure('public.supplier_invoice_reference_identity_v1(text)')
),
original_trigger AS (
  SELECT
    t.oid AS trigger_oid,
    t.tgname,
    p.oid AS function_oid,
    nsp.nspname AS function_schema,
    p.proname AS function_name,
    pg_get_triggerdef(t.oid, true) AS trigger_definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND c.relname = 'supplier_invoices'
    AND t.tgname = 'trg_supplier_invoice_post_ocr_duplicate_gate'
    AND NOT t.tgisinternal
),
required_indexes AS (
  SELECT
    i.indexname,
    i.indexdef
  FROM pg_indexes i
  WHERE i.schemaname = 'public'
    AND i.tablename = 'supplier_invoices'
    AND i.indexname IN (
      'uq_supplier_invoices_approved_ocr_ref_per_retailer',
      'uq_supplier_invoices_current_reference_family'
    )
),
reverse_dependencies AS (
  SELECT
    d.refobjid AS referenced_oid,
    pg_describe_object(d.refclassid, d.refobjid, d.refobjsubid) AS referenced_object,
    d.classid,
    d.objid,
    d.objsubid,
    d.deptype,
    pg_describe_object(d.classid, d.objid, d.objsubid) AS dependent_object
  FROM pg_depend d
  WHERE d.refclassid = 'pg_proc'::regclass
    AND d.refobjid IN (
      COALESCE(to_regprocedure('public.supplier_invoice_cross_order_duplicate_guard_v1()')::oid, 0),
      COALESCE(to_regprocedure('public.supplier_invoice_reference_identity_v1(text)')::oid, 0)
    )
),
unexpected_hard_dependencies AS (
  SELECT rd.*
  FROM reverse_dependencies rd
  WHERE NOT (
    rd.referenced_oid = COALESCE(to_regprocedure('public.supplier_invoice_cross_order_duplicate_guard_v1()')::oid, 0)
    AND rd.classid = 'pg_trigger'::regclass
    AND rd.objid = COALESCE((SELECT trigger_oid FROM bad_trigger LIMIT 1), 0)
  )
),
function_text_references AS (
  SELECT
    n.nspname AS schema_name,
    p.proname,
    pg_get_function_identity_arguments(p.oid) AS identity_args
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind IN ('f','p')
    AND p.oid NOT IN (
      COALESCE(to_regprocedure('public.supplier_invoice_cross_order_duplicate_guard_v1()')::oid, 0),
      COALESCE(to_regprocedure('public.supplier_invoice_reference_identity_v1(text)')::oid, 0)
    )
    AND (
      pg_get_functiondef(p.oid) ILIKE '%supplier_invoice_cross_order_duplicate_guard_v1%'
      OR pg_get_functiondef(p.oid) ILIKE '%supplier_invoice_reference_identity_v1%'
    )
),
view_text_references AS (
  SELECT
    n.nspname AS schema_name,
    c.relname AS view_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('v','m')
    AND (
      pg_get_viewdef(c.oid, true) ILIKE '%supplier_invoice_cross_order_duplicate_guard_v1%'
      OR pg_get_viewdef(c.oid, true) ILIKE '%supplier_invoice_reference_identity_v1%'
    )
),
other_trigger_text_references AS (
  SELECT
    n.nspname AS schema_name,
    c.relname AS table_name,
    t.tgname
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND NOT t.tgisinternal
    AND t.oid <> COALESCE((SELECT trigger_oid FROM bad_trigger LIMIT 1), 0)
    AND (
      pg_get_triggerdef(t.oid, true) ILIKE '%supplier_invoice_cross_order_duplicate_guard_v1%'
      OR pg_get_triggerdef(t.oid, true) ILIKE '%supplier_invoice_reference_identity_v1%'
    )
),
cross_order_ref_groups AS (
  SELECT
    si.retailer_id,
    lower(regexp_replace(btrim(COALESCE(si.invoice_ref, '')), '[^a-zA-Z0-9]+', '', 'g')) AS normalized_ref,
    count(*)::integer AS row_count,
    count(DISTINCT si.order_id)::integer AS order_count
  FROM public.supplier_invoices si
  WHERE NULLIF(btrim(COALESCE(si.invoice_ref, '')), '') IS NOT NULL
    AND COALESCE(si.review_status, 'pending_review') NOT IN (
      'rejected_resubmit_required',
      'superseded',
      'duplicate_blocked'
    )
  GROUP BY
    si.retailer_id,
    lower(regexp_replace(btrim(COALESCE(si.invoice_ref, '')), '[^a-zA-Z0-9]+', '', 'g'))
  HAVING count(DISTINCT si.order_id) > 1
),
approved_ocr_duplicate_groups AS (
  SELECT
    si.retailer_id,
    lower(regexp_replace(btrim(COALESCE(si.ocr_invoice_ref, '')), '[^a-zA-Z0-9]+', '', 'g')) AS normalized_ocr_ref,
    count(*)::integer AS row_count
  FROM public.supplier_invoices si
  WHERE si.review_status IN ('approved_current','ref_corrected_approved')
    AND COALESCE(si.blocked_from_sage_yn, true) = false
    AND NULLIF(btrim(COALESCE(si.ocr_invoice_ref, '')), '') IS NOT NULL
  GROUP BY
    si.retailer_id,
    lower(regexp_replace(btrim(COALESCE(si.ocr_invoice_ref, '')), '[^a-zA-Z0-9]+', '', 'g'))
  HAVING count(*) > 1
)
SELECT jsonb_build_object(
  'probe', 'supplier_invoice_duplicate_guard_rollback_preflight_v1',
  'safe_to_rollback',
    (SELECT count(*) = 1 FROM bad_trigger)
    AND (SELECT count(*) = 1 FROM bad_guard)
    AND (SELECT count(*) = 1 FROM bad_normaliser)
    AND (SELECT count(*) = 1 FROM original_trigger)
    AND (SELECT count(*) = 2 FROM required_indexes)
    AND (SELECT count(*) = 0 FROM unexpected_hard_dependencies)
    AND (SELECT count(*) = 0 FROM function_text_references)
    AND (SELECT count(*) = 0 FROM view_text_references)
    AND (SELECT count(*) = 0 FROM other_trigger_text_references),
  'rollback_objects', jsonb_build_object(
    'bad_trigger', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM bad_trigger x), '[]'::jsonb),
    'bad_guard_function', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM bad_guard x), '[]'::jsonb),
    'bad_normaliser_function', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM bad_normaliser x), '[]'::jsonb)
  ),
  'preserved_controls', jsonb_build_object(
    'original_post_ocr_trigger', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM original_trigger x), '[]'::jsonb),
    'required_indexes', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM required_indexes x), '[]'::jsonb)
  ),
  'dependency_check', jsonb_build_object(
    'all_reverse_dependencies', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM reverse_dependencies x), '[]'::jsonb),
    'unexpected_hard_dependencies', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM unexpected_hard_dependencies x), '[]'::jsonb),
    'other_function_text_references', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM function_text_references x), '[]'::jsonb),
    'view_text_references', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM view_text_references x), '[]'::jsonb),
    'other_trigger_text_references', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM other_trigger_text_references x), '[]'::jsonb)
  ),
  'data_baseline', jsonb_build_object(
    'supplier_invoice_row_count', (SELECT count(*) FROM public.supplier_invoices),
    'cross_order_live_typed_ref_group_count', (SELECT count(*) FROM cross_order_ref_groups),
    'cross_order_live_typed_ref_groups', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM cross_order_ref_groups x), '[]'::jsonb),
    'approved_ocr_duplicate_group_count', (SELECT count(*) FROM approved_ocr_duplicate_groups),
    'approved_ocr_duplicate_groups', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM approved_ocr_duplicate_groups x), '[]'::jsonb)
  )
) AS result;

COMMIT;
