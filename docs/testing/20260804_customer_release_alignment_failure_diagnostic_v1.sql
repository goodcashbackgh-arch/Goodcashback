-- Read-only diagnostic for the failed customer release alignment regression.
-- No writes. Captures the exact live definition and the three string checks that failed.

WITH target AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_userbyid(p.proowner) AS owner,
    p.prosecdef AS security_definer,
    p.provolatile AS volatility,
    p.proacl AS acl,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid = 'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure
), related AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid IN (
    'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure,
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'target', (
    SELECT jsonb_build_object(
      'identity', identity,
      'definition_md5', definition_md5,
      'owner', owner,
      'security_definer', security_definer,
      'volatility', volatility,
      'acl', acl,
      'contains_customer_sales_release_lines', position('customer_sales_release_lines' in definition) > 0,
      'contains_remaining_preview_call', position('internal_shipping_customer_invoice_remaining_preview_v1' in definition) > 0,
      'contains_already_bundled_reason', position('already_bundled_in_main_sales_invoice' in definition) > 0,
      'definition', definition
    )
    FROM target
  ),
  'related', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'identity', identity,
      'definition_md5', definition_md5,
      'definition', definition
    ) ORDER BY identity)
    FROM related
  ), '[]'::jsonb)
) AS customer_release_alignment_failure_diagnostic;
