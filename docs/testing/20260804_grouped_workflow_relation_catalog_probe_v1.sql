-- READ-ONLY catalog discovery for grouped physical-receipt workflow relations.
-- No application-table guesses beyond already proven tables.
-- No DML. Safe to run repeatedly.

WITH matching_relations AS (
  SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    c.relkind,
    CASE c.relkind
      WHEN 'r' THEN 'table'
      WHEN 'p' THEN 'partitioned_table'
      WHEN 'v' THEN 'view'
      WHEN 'm' THEN 'materialized_view'
      WHEN 'f' THEN 'foreign_table'
      ELSE c.relkind::text
    END AS relation_type
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public'
    AND c.relkind IN ('r','p','v','m','f')
    AND (
      c.relname ILIKE '%physical%'
      OR c.relname ILIKE '%remedy%'
      OR c.relname ILIKE '%outcome%'
      OR c.relname ILIKE '%lane%'
      OR c.relname ILIKE '%replacement%'
      OR c.relname ILIKE '%route%'
    )
), matching_columns AS (
  SELECT
    cols.table_schema AS schema_name,
    cols.table_name AS relation_name,
    cols.ordinal_position,
    cols.column_name,
    cols.data_type,
    cols.udt_name,
    cols.is_nullable,
    cols.column_default
  FROM information_schema.columns cols
  JOIN matching_relations mr
    ON mr.schema_name=cols.table_schema
   AND mr.relation_name=cols.table_name
), target_review AS (
  SELECT to_jsonb(r) AS row
  FROM public.physical_receipt_reviews r
  WHERE r.id='23e51455-9186-4207-81ff-3e502bbe9f4c'::uuid
), order_reviews AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.id),'[]'::jsonb) AS rows
  FROM public.physical_receipt_reviews r
  WHERE r.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), receipts AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.id),'[]'::jsonb) AS rows
  FROM public.shipper_package_receipts p
  WHERE p.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), disputes AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY d.id),'[]'::jsonb) AS rows
  FROM public.disputes d
  WHERE d.order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
), child_orders AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(o) ORDER BY o.id),'[]'::jsonb) AS rows
  FROM public.orders o
  WHERE o.parent_order_id='1b4a2a43-5ddd-41ef-aef5-45e621eb5819'::uuid
)
SELECT jsonb_build_object(
  'probe','grouped_workflow_relation_catalog_probe_v1',
  'result','READY',
  'matching_relations',COALESCE((
    SELECT jsonb_agg(to_jsonb(mr) ORDER BY mr.schema_name,mr.relation_name)
    FROM matching_relations mr
  ),'[]'::jsonb),
  'matching_columns',COALESCE((
    SELECT jsonb_agg(to_jsonb(mc) ORDER BY mc.schema_name,mc.relation_name,mc.ordinal_position)
    FROM matching_columns mc
  ),'[]'::jsonb),
  'target_review',(SELECT row FROM target_review),
  'all_order_reviews',(SELECT rows FROM order_reviews),
  'all_order_receipts',(SELECT rows FROM receipts),
  'disputes',(SELECT rows FROM disputes),
  'child_orders',(SELECT rows FROM child_orders)
) AS result;
