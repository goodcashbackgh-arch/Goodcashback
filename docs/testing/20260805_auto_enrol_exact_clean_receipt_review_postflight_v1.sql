WITH trigger_check AS (
  SELECT
    t.tgname,
    t.tgenabled,
    pg_get_triggerdef(t.oid, true) AS trigger_definition,
    p.oid::regprocedure::text AS trigger_function,
    md5(pg_get_functiondef(p.oid)) AS trigger_function_md5
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = 'public.shipper_package_receipts'::regclass
    AND t.tgname = 'trg_auto_enrol_exact_clean_receipt_review_v1'
    AND NOT t.tgisinternal
), acl_check AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    p.prosecdef AS security_definer,
    p.proconfig AS function_config,
    has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_execute,
    has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_execute,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid = 'public.auto_enrol_exact_clean_receipt_review_v1()'::regprocedure
), protected AS (
  SELECT
    p.oid::regprocedure::text AS identity,
    md5(pg_get_functiondef(p.oid)) AS definition_md5
  FROM pg_proc p
  WHERE p.oid IN (
    'public.customer_review_cycle_candidates_v1(uuid)'::regprocedure,
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure,
    'public.customer_review_cycle_component_guard_v1()'::regprocedure,
    'public.customer_review_cycle_membership_immutable_guard_v1()'::regprocedure,
    'public.shipper_shipment_batch_candidates_v1()'::regprocedure,
    'public.shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'trigger', COALESCE((SELECT to_jsonb(trigger_check) FROM trigger_check), '{}'::jsonb),
  'trigger_function', COALESCE((SELECT to_jsonb(acl_check) FROM acl_check), '{}'::jsonb),
  'protected_fingerprints', COALESCE((
    SELECT jsonb_agg(to_jsonb(protected) ORDER BY identity)
    FROM protected
  ), '[]'::jsonb),
  'postflight_passed',
    EXISTS (SELECT 1 FROM trigger_check)
    AND (SELECT tgenabled = 'O' FROM trigger_check)
    AND EXISTS (SELECT 1 FROM acl_check)
    AND (SELECT security_definer FROM acl_check)
    AND NOT (SELECT anon_execute FROM acl_check)
    AND NOT (SELECT authenticated_execute FROM acl_check)
    AND NOT (SELECT service_role_execute FROM acl_check)
    AND (SELECT COUNT(*) FROM protected) = 6
    AND NOT EXISTS (
      SELECT 1
      FROM protected
      WHERE (identity = 'customer_review_cycle_candidates_v1(uuid)' AND definition_md5 <> '80c5ca83374ed2ddaedeadd3b88dd95d')
         OR (identity = 'internal_materialize_customer_review_cycles_v1(uuid,uuid)' AND definition_md5 <> '0293a94d4eb17daf9c7e48131cd75ca1')
         OR (identity = 'customer_review_cycle_component_guard_v1()' AND definition_md5 <> 'c7b7727836dd6c49fdbcd415fb68d88a')
         OR (identity = 'customer_review_cycle_membership_immutable_guard_v1()' AND definition_md5 <> 'f08154042118c35eb4428af24623ae90')
         OR (identity = 'shipper_shipment_batch_candidates_v1()' AND definition_md5 <> '952f24084fed0dffcdebbfae988e7400')
         OR (identity = 'shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamp with time zone,timestamp with time zone,integer,text,text,text)' AND definition_md5 <> '4e4b86b0121a85523fe95c1530a41658')
    END
) AS auto_enrol_exact_clean_receipt_review_postflight;
