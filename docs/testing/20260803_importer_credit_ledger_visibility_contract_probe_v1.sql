-- Read-only probe for importer_credit_ledger visibility and RLS contract.

WITH table_meta AS (
  SELECT
    c.relrowsecurity AS rls_enabled,
    c.relforcerowsecurity AS force_rls
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='importer_credit_ledger'
), policies AS (
  SELECT
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
  FROM pg_policies
  WHERE schemaname='public' AND tablename='importer_credit_ledger'
), grants AS (
  SELECT grantee,privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema='public'
    AND table_name='importer_credit_ledger'
    AND grantee IN ('authenticated','anon','service_role','postgres')
)
SELECT jsonb_build_object(
  'probe','importer_credit_ledger_visibility_contract_v1',
  'table_meta',(SELECT to_jsonb(table_meta) FROM table_meta),
  'policies',(SELECT COALESCE(jsonb_agg(to_jsonb(policies) ORDER BY policyname),'[]'::jsonb) FROM policies),
  'grants',(SELECT COALESCE(jsonb_agg(to_jsonb(grants) ORDER BY grantee,privilege_type),'[]'::jsonb) FROM grants),
  'writer_function',jsonb_build_object(
    'signature','staff_confirm_order_settlement_credit_v1(uuid,text,text)',
    'security_definer',(
      SELECT p.prosecdef
      FROM pg_proc p
      WHERE p.oid='public.staff_confirm_order_settlement_credit_v1(uuid,text,text)'::regprocedure
    ),
    'md5',md5(pg_get_functiondef('public.staff_confirm_order_settlement_credit_v1(uuid,text,text)'::regprocedure))
  )
) AS result;
