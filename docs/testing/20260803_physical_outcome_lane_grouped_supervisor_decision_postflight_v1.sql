-- Read-only installation and security postflight for grouped supervisor decisions.

WITH fn AS (
  SELECT
    p.oid,
    p.oid::regprocedure::text AS signature,
    p.prosecdef,
    p.proconfig,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid=to_regprocedure('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)')
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN to_regclass('public.physical_receipt_outcome_lane_decisions') IS NULL THEN 'decision_table_missing' END,
    CASE WHEN to_regclass('public.physical_receipt_outcome_lane_decision_items') IS NULL THEN 'decision_items_table_missing' END,
    CASE WHEN to_regprocedure('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)') IS NULL THEN 'decision_function_missing' END,
    CASE WHEN EXISTS (SELECT 1 FROM fn WHERE NOT prosecdef) THEN 'function_not_security_definer' END,
    CASE WHEN EXISTS (SELECT 1 FROM fn WHERE NOT ('search_path=public, pg_temp'=ANY(proconfig))) THEN 'unsafe_search_path' END,
    CASE WHEN to_regprocedure('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)','EXECUTE')
      THEN 'authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)') IS NOT NULL
           AND has_function_privilege('anon','public.staff_decide_physical_outcome_lane_v1(uuid,uuid,jsonb,text)','EXECUTE')
      THEN 'anon_execute_present' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM fn
      WHERE definition NOT LIKE '%staff_accept_same_order_free_replacement_v1(%'
         OR definition NOT LIKE '%staff_close_refund_exception_as_settlement_credit_v1(%'
    ) THEN 'delegation_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM fn
      WHERE definition NOT LIKE '%Refund decision must select every unresolved physical item in each affected dispute.%'
    ) THEN 'refund_exact_coverage_guard_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM fn
      WHERE definition NOT LIKE '%Duplicate remedy allocation IDs are not allowed.%'
         OR definition NOT LIKE '%Mixed decisions are not allowed in one grouped call.%'
         OR definition NOT LIKE '%One or more selected items do not belong to the lane.%'
         OR definition NOT LIKE '%Decision type does not match the outcome lane.%'
    ) THEN 'fail_closed_selection_guards_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM fn
      WHERE definition NOT LIKE '%UNIQUE(lane_id,request_hash)%'
        AND NOT EXISTS (
          SELECT 1 FROM pg_constraint c
          WHERE c.conrelid='public.physical_receipt_outcome_lane_decisions'::regclass
            AND c.contype='u'
            AND pg_get_constraintdef(c.oid) LIKE '%lane_id, request_hash%'
        )
    ) THEN 'idempotency_constraint_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM fn
      WHERE definition NOT LIKE '%partially_resolved%'
         OR definition NOT LIKE '%resolved%'
    ) THEN 'lane_status_recompute_missing' END,
    CASE WHEN md5(pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure)) <> '78e94d6d76bf1c160068a3fd97ae4a87' THEN 'replacement_authority_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure)) <> '0698d2ab2e7301881dac862a18284f52' THEN 'refund_authority_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN 'remedy_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233' THEN 'remedy_sequence_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679' THEN 'review_guard_drift' END
  ],NULL) AS blockers
)
SELECT jsonb_build_object(
  'postflight','physical_outcome_lane_grouped_supervisor_decision_v1',
  'result',CASE WHEN COALESCE(array_length(blockers,1),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers',blockers,
  'function',(
    SELECT jsonb_build_object(
      'signature',signature,
      'md5',md5(definition),
      'security_definer',prosecdef,
      'search_path',proconfig,
      'authenticated_execute',has_function_privilege('authenticated',signature,'EXECUTE'),
      'anon_execute',has_function_privilege('anon',signature,'EXECUTE'),
      'contains_replacement_delegation',definition LIKE '%staff_accept_same_order_free_replacement_v1(%',
      'contains_refund_delegation',definition LIKE '%staff_close_refund_exception_as_settlement_credit_v1(%',
      'contains_refund_exact_coverage_guard',definition LIKE '%Refund decision must select every unresolved physical item in each affected dispute.%',
      'contains_lane_status_recompute',definition LIKE '%partially_resolved%' AND definition LIKE '%resolved%'
    ) FROM fn
  ),
  'tables',jsonb_build_object(
    'decisions_installed',to_regclass('public.physical_receipt_outcome_lane_decisions') IS NOT NULL,
    'decision_items_installed',to_regclass('public.physical_receipt_outcome_lane_decision_items') IS NOT NULL
  ),
  'delegated_authority_fingerprints',jsonb_build_object(
    'staff_accept_same_order_free_replacement_v1',md5(pg_get_functiondef('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure)),
    'staff_close_refund_exception_as_settlement_credit_v1',md5(pg_get_functiondef('public.staff_close_refund_exception_as_settlement_credit_v1(uuid,text,text)'::regprocedure))
  ),
  'protected_guard_fingerprints',jsonb_build_object(
    'physical_remedy_allocation_guard_v2',md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1',md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1',md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result
FROM blockers;
