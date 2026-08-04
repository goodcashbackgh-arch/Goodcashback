-- READ-ONLY live-schema probe for the grouped physical receipt browser fixture.
-- No DML. No temp table. No function creation. Safe to run repeatedly.
-- This probe deliberately avoids naming application-table columns beyond proven join keys.

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
    r.relname AS table_name,
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
    udt_name,
    is_nullable,
    column_default,
    is_identity,
    is_generated,
    ordinal_position
  FROM information_schema.columns
  JOIN target_tables USING(table_name)
  WHERE table_schema='public'
), template_review AS (
  SELECT review.*
  FROM public.physical_receipt_reviews review
  WHERE EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_line_dispositions d
    WHERE d.receipt_id=review.receipt_id
      AND d.disposition_type<>'clean'
  )
  ORDER BY review.created_at DESC,review.id DESC
  LIMIT 1
), template_rows AS (
  SELECT jsonb_build_object(
    'physical_receipt_review',to_jsonb(r),
    'order',(SELECT to_jsonb(o) FROM public.orders o WHERE o.id=r.order_id),
    'tracking_submission',(SELECT to_jsonb(t) FROM public.order_tracking_submissions t WHERE t.id=r.tracking_submission_id),
    'receipt',(SELECT to_jsonb(p) FROM public.shipper_package_receipts p WHERE p.id=r.receipt_id),
    'supplier_invoices',COALESCE((
      SELECT jsonb_agg(to_jsonb(si) ORDER BY si.id)
      FROM public.supplier_invoices si
      WHERE si.order_id=r.order_id
    ),'[]'::jsonb),
    'receipt_dispositions',COALESCE((
      SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id)
      FROM public.shipper_package_receipt_line_dispositions d
      WHERE d.receipt_id=r.receipt_id
    ),'[]'::jsonb),
    'receipt_evidence',COALESCE((
      SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
      FROM public.shipper_package_receipt_evidence e
      WHERE e.receipt_id=r.receipt_id
    ),'[]'::jsonb),
    'tracking_allocations',COALESCE((
      SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
      FROM public.order_tracking_line_allocations a
      WHERE a.tracking_submission_id=r.tracking_submission_id
    ),'[]'::jsonb)
  ) AS payload
  FROM template_review r
), enum_like_checks AS (
  SELECT table_name,constraint_name,definition
  FROM constraints
  WHERE constraint_type='c'
)
SELECT jsonb_build_object(
  'probe','grouped_fixture_live_schema_probe_v2',
  'result','READY',
  'template_rows',(SELECT payload FROM template_rows),
  'constraints',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY table_name,constraint_name) FROM constraints c),'[]'::jsonb),
  'unique_indexes',COALESCE((SELECT jsonb_agg(to_jsonb(u) ORDER BY table_name,index_name) FROM unique_indexes u),'[]'::jsonb),
  'triggers',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY table_name,trigger_name,event_manipulation) FROM triggers t),'[]'::jsonb),
  'columns',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY table_name,ordinal_position) FROM columns c),'[]'::jsonb),
  'check_constraints',COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY table_name,constraint_name) FROM enum_like_checks e),'[]'::jsonb)
) AS result;
