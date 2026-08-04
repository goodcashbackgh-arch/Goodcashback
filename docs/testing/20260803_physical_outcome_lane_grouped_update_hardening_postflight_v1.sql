-- Read-only postflight for 20260803224500_physical_outcome_lane_grouped_update_hardening_v1.sql.

WITH f AS (
  SELECT
    p.prosecdef,
    p.proconfig,
    pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  WHERE p.oid=to_regprocedure(
    'public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)'
  )
), blockers AS (
  SELECT array_remove(ARRAY[
    CASE WHEN NOT EXISTS (SELECT 1 FROM f) THEN 'function_missing' END,
    CASE WHEN EXISTS (SELECT 1 FROM f WHERE NOT prosecdef) THEN 'not_security_definer' END,
    CASE WHEN EXISTS (SELECT 1 FROM f WHERE NOT ('search_path=public, pg_temp'=ANY(proconfig))) THEN 'unsafe_search_path' END,
    CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NOT NULL
           AND NOT has_function_privilege('authenticated','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE')
      THEN 'authenticated_execute_missing' END,
    CASE WHEN to_regprocedure('public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)') IS NOT NULL
           AND has_function_privilege('anon','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE')
      THEN 'anon_execute_present' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM f
      WHERE definition NOT LIKE '%SELECT ui.dispute_message_id INTO v_message_id%'
         OR definition NOT LIKE '%li.dispute_id=v_dispute_id%'
    ) THEN 'distinct_dispute_message_reuse_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM f
      WHERE definition NOT LIKE '%COUNT(DISTINCT ui.physical_remedy_allocation_id)%'
         OR definition NOT LIKE '%u.retailer_outcome=''retailer_accepted''%'
         OR definition NOT LIKE '%WHEN v_accepted_items=v_total_items AND v_total_items>0%'
    ) THEN 'cumulative_completion_logic_missing' END,
    CASE WHEN EXISTS (
      SELECT 1 FROM f
      WHERE definition NOT LIKE '%accepted_items_cumulative%'
         OR definition NOT LIKE '%lane_item_count%'
    ) THEN 'cumulative_result_fields_missing' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) <> 'f82d15d2de1199f9ab841d8c1ad44738' THEN 'remedy_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) <> '3c5067f31d4f2112207e02d1f307e233' THEN 'remedy_sequence_guard_drift' END,
    CASE WHEN md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) <> 'eaaf737e29580feb56272c55e6f1f679' THEN 'review_guard_drift' END
  ],NULL) AS blockers
)
SELECT jsonb_build_object(
  'postflight','physical_outcome_lane_grouped_update_hardening_v1',
  'result',CASE WHEN COALESCE(array_length(blockers,1),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  'blockers',blockers,
  'function',(
    SELECT jsonb_build_object(
      'installed',true,
      'md5',md5(definition),
      'security_definer',prosecdef,
      'search_path',proconfig,
      'authenticated_execute',has_function_privilege('authenticated','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE'),
      'anon_execute',has_function_privilege('anon','public.operator_record_physical_outcome_lane_update_v1(uuid,uuid[],text,text,text,uuid)','EXECUTE'),
      'contains_distinct_dispute_message_reuse',definition LIKE '%SELECT ui.dispute_message_id INTO v_message_id%' AND definition LIKE '%li.dispute_id=v_dispute_id%',
      'contains_cumulative_completion',definition LIKE '%COUNT(DISTINCT ui.physical_remedy_allocation_id)%' AND definition LIKE '%u.retailer_outcome=''retailer_accepted''%' AND definition LIKE '%WHEN v_accepted_items=v_total_items AND v_total_items>0%'
    ) FROM f
  ),
  'protected_guard_fingerprints',jsonb_build_object(
    'physical_remedy_allocation_guard_v2',md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)),
    'physical_remedy_sequence_guard_v1',md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)),
    'physical_receipt_review_guard_v1',md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))
  )
) AS result
FROM blockers;
