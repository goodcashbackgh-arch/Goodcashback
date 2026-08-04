-- Read-only contract inspection for live supervisor lane authority dependencies.

WITH target_functions AS (
  SELECT
    p.oid::regprocedure::text AS signature,
    p.proargnames AS argument_names,
    pg_get_function_result(p.oid) AS result_type,
    p.prosecdef AS security_definer,
    p.proconfig AS config,
    md5(pg_get_functiondef(p.oid)) AS definition_md5,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid IN (
    'public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure,
    'public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure
  )
)
SELECT jsonb_build_object(
  'inspection','physical_outcome_lane_supervisor_authority_function_contracts_v1',
  'functions',jsonb_agg(jsonb_build_object(
    'signature',signature,
    'argument_names',argument_names,
    'result_type',result_type,
    'security_definer',security_definer,
    'config',config,
    'definition_md5',definition_md5,
    'definition',definition
  ) ORDER BY signature)
) AS result
FROM target_functions;
