-- READ-ONLY live-schema probe for the grouped physical receipt browser fixture.
-- No DML. No temp table. No function creation. Safe to run repeatedly.

WITH target_tables AS (
  SELECT unnest(ARRAY[
    'orders',
    'supplier_invoices',
    'supplier_invoice_lines',
    'order_tracking_submissions',
    'order_tracking_line_allocations',
    'shipper_package_receipts',
    'shipper_package_receipt_line_dispositions',
    'shipper_package_receipt_evidence',
    'physical_receipt_reviews'
  ]) AS table_name
), constraints AS (
  SELECT
    c.conrelid::regclass::text AS table_name,
    c.conname AS constraint_name,
    c.contype AS constraint_type,
    pg_get_constraintdef(c.oid,true) AS definition
  FROM pg_constraint c
  JOIN pg_class r ON r.oid=c.conrelid
  JOIN pg_namespace n ON n.oid=r.relnamespace
  JOIN target_tables t ON t.table_name=r.relname
  WHERE n.nspname='public'
), unique_indexes AS (
  SELECT
    tbl.relname AS table_name,
    idx.relname AS index_name,
    pg_get_indexdef(i.indexrelid) AS definition,
    i.indisunique,
    i.indisprimary
  FROM pg_index i
  JOIN pg_class tbl ON tbl.oid=i.indrelid
  JOIN pg_namespace n ON n.oid=tbl.relnamespace
  JOIN pg_class idx ON idx.oid=i.indexrelid
  JOIN target_tables t ON t.table_name=tbl.relname
  WHERE n.nspname='public'
    AND i.indisunique
), triggers AS (
  SELECT
    event_object_table AS table_name,
    trigger_name,
    action_timing,
    event_manipulation,
    action_statement
  FROM information_schema.triggers
  JOIN target_tables t ON t.table_name=event_object_table
  WHERE trigger_schema='public'
), columns AS (
  SELECT
    table_name,
    column_name,
    data_type,
    is_nullable,
    column_default,
    is_identity,
    is_generated
  FROM information_schema.columns
  JOIN target_tables USING(table_name)
  WHERE table_schema='public'
), template AS (
  SELECT
    review.id AS template_review_id,
    review.order_id,
    review.receipt_id,
    review.tracking_submission_id,
    o.order_ref,
    o.payment_auth_id,
    o.order_type,
    o.status AS order_status,
    o.funded_at,
    o.total_qty_declared,
    o.parent_order_id,
    o.replacement_source_dispute_line_id,
    si.id AS supplier_invoice_id,
    si.invoice_number,
    si.supplier_invoice_number,
    ots.tracking_ref,
    spr.receipt_submission_id,
    spr.payload_fingerprint
  FROM public.physical_receipt_reviews review
  JOIN public.orders o ON o.id=review.order_id
  JOIN public.order_tracking_submissions ots ON ots.id=review.tracking_submission_id
  JOIN public.shipper_package_receipts spr ON spr.id=review.receipt_id
  LEFT JOIN LATERAL (
    SELECT si.*
    FROM public.supplier_invoices si
    WHERE si.order_id=review.order_id
    ORDER BY si.created_at,si.id
    LIMIT 1
  ) si ON true
  WHERE EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_line_dispositions d
    WHERE d.receipt_id=review.receipt_id
      AND d.disposition_type<>'clean'
  )
  ORDER BY review.created_at DESC,review.id DESC
  LIMIT 1
), enum_like_checks AS (
  SELECT
    table_name,
    constraint_name,
    definition
  FROM constraints
  WHERE constraint_type='c'
    AND (
      definition ILIKE '%order_type%'
      OR definition ILIKE '%status%'
      OR definition ILIKE '%receipt_state%'
      OR definition ILIKE '%receipt_status%'
      OR definition ILIKE '%disposition_type%'
    )
)
SELECT jsonb_build_object(
  'probe','grouped_fixture_live_schema_probe_v1',
  'result','READY',
  'template_row',(SELECT to_jsonb(template) FROM template),
  'constraints',COALESCE((SELECT jsonb_agg(to_jsonb(constraints) ORDER BY table_name,constraint_name) FROM constraints),'[]'::jsonb),
  'unique_indexes',COALESCE((SELECT jsonb_agg(to_jsonb(unique_indexes) ORDER BY table_name,index_name) FROM unique_indexes),'[]'::jsonb),
  'triggers',COALESCE((SELECT jsonb_agg(to_jsonb(triggers) ORDER BY table_name,trigger_name,event_manipulation) FROM triggers),'[]'::jsonb),
  'columns',COALESCE((SELECT jsonb_agg(to_jsonb(columns) ORDER BY table_name,ordinal_position) FROM (
    SELECT c.*,ic.ordinal_position
    FROM columns c
    JOIN information_schema.columns ic
      ON ic.table_schema='public'
     AND ic.table_name=c.table_name
     AND ic.column_name=c.column_name
  ) columns),'[]'::jsonb),
  'enum_like_checks',COALESCE((SELECT jsonb_agg(to_jsonb(enum_like_checks) ORDER BY table_name,constraint_name) FROM enum_like_checks),'[]'::jsonb)
) AS result;
