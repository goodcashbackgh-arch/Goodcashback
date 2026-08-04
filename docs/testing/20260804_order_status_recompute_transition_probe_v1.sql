-- READ-ONLY probe for order status recomputation and transition authority.
-- No DML. Safe to run repeatedly.

WITH fn AS (
  SELECT
    n.nspname AS schema_name,
    p.proname AS function_name,
    pg_get_function_identity_arguments(p.oid) AS identity_arguments,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN (
      'recompute_order_status',
      'enforce_status_transition',
      'trg_recompute_order_status_from_invoice',
      'trg_recompute_order_status_from_invoice_line',
      'trg_recompute_order_status_from_tracking'
    )
), target_order AS (
  SELECT to_jsonb(o) AS row
  FROM public.orders o
  WHERE o.id='8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
), invoice_state AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(si) ORDER BY si.id),'[]'::jsonb) AS rows
  FROM public.supplier_invoices si
  WHERE si.order_id='8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
), line_state AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(sil) ORDER BY sil.id),'[]'::jsonb) AS rows
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id=sil.supplier_invoice_id
  WHERE si.order_id='8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
), tracking_state AS (
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb) AS rows
  FROM public.order_tracking_submissions t
  WHERE t.order_id='8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid
), trigger_defs AS (
  SELECT
    c.relname AS table_name,
    t.tgname AS trigger_name,
    pg_get_triggerdef(t.oid,true) AS definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid=t.tgrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public'
    AND NOT t.tgisinternal
    AND c.relname IN ('orders','supplier_invoices','supplier_invoice_lines','order_tracking_submissions')
)
SELECT jsonb_build_object(
  'probe','order_status_recompute_transition_probe_v1',
  'result','READY',
  'functions',COALESCE((SELECT jsonb_agg(to_jsonb(fn) ORDER BY function_name,identity_arguments) FROM fn),'[]'::jsonb),
  'triggers',COALESCE((SELECT jsonb_agg(to_jsonb(trigger_defs) ORDER BY table_name,trigger_name) FROM trigger_defs),'[]'::jsonb),
  'template_order',(SELECT row FROM target_order),
  'template_invoices',(SELECT rows FROM invoice_state),
  'template_invoice_lines',(SELECT rows FROM line_state),
  'template_tracking',(SELECT rows FROM tracking_state)
) AS result;
