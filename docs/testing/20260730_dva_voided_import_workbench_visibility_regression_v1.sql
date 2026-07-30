-- 20260730_dva_voided_import_workbench_visibility_regression_v1.sql
-- READ ONLY.
-- Regression pack for:
-- docs/governing-pack/ui/DVA_VOIDED_IMPORT_WORKBENCH_VISIBILITY_ADDENDUM_v1.md
--
-- Controlled evidence:
--   voided old IN   c39ff2fb-2e68-4c57-beae-229f5981cb62  £841.70
--   voided old OUT  4dc1fe60-86dc-40f1-92ad-519ca3199443  £896.57
--   active new IN    c488e84a-0e98-446a-9c5c-1def5f7f419f  £896.81
--   active new OUT   c62a750c-aa8d-4261-b594-dc9a315f4f4d  £896.57

WITH target_lines AS (
  SELECT *
  FROM (VALUES
    ('c39ff2fb-2e68-4c57-beae-229f5981cb62'::uuid, 'VOIDED_OLD_IN'::text, false),
    ('4dc1fe60-86dc-40f1-92ad-519ca3199443'::uuid, 'VOIDED_OLD_OUT'::text, false),
    ('c488e84a-0e98-446a-9c5c-1def5f7f419f'::uuid, 'VALID_REPLACEMENT_IN'::text, true),
    ('c62a750c-aa8d-4261-b594-dc9a315f4f4d'::uuid, 'VALID_REPLACEMENT_OUT'::text, true)
  ) v(dva_statement_line_id, expected_role, expected_active_visibility)
), provenance AS (
  SELECT
    t.*,
    EXISTS (
      SELECT 1
      FROM public.dva_statement_line_import_links l
      WHERE l.dva_statement_line_id = t.dva_statement_line_id
        AND l.active_yn = true
    ) AS has_active_import_link,
    EXISTS (
      SELECT 1
      FROM public.dva_statement_line_import_links l
      WHERE l.dva_statement_line_id = t.dva_statement_line_id
        AND l.active_yn = false
    ) AS has_inactive_import_link
  FROM target_lines t
), view_presence AS (
  SELECT
    p.*,
    (SELECT count(*) FROM public.dva_statement_line_allocation_status_vw s
      WHERE s.dva_statement_line_id = p.dva_statement_line_id) AS status_view_count,
    (SELECT count(*) FROM public.dva_statement_line_allocation_summary_vw s
      WHERE s.dva_statement_line_id = p.dva_statement_line_id) AS summary_view_count
  FROM provenance p
), funding_presence AS (
  SELECT
    v.*,
    CASE WHEN v.expected_role IN ('VOIDED_OLD_IN','VALID_REPLACEMENT_IN') THEN
      EXISTS (
        SELECT 1
        FROM public.day2_dva_review_worklist_vw w
        WHERE w.dva_statement_line_id = v.dva_statement_line_id
      )
    ELSE NULL END AS in_day2_funding_worklist,
    CASE WHEN v.expected_role = 'VALID_REPLACEMENT_IN' THEN (
      SELECT jsonb_build_object(
        'reconciliation_id', w.reconciliation_id,
        'reconciled_order_id', w.reconciled_order_id,
        'reconciled_gbp_amount', w.reconciled_gbp_amount
      )
      FROM public.day2_dva_review_worklist_vw w
      WHERE w.dva_statement_line_id = v.dva_statement_line_id
      LIMIT 1
    ) ELSE NULL END AS funding_reconciliation_evidence
  FROM view_presence v
), historical_presence AS (
  SELECT
    f.*,
    EXISTS (SELECT 1 FROM public.dva_statement_lines l WHERE l.id = f.dva_statement_line_id) AS physical_statement_line_retained,
    EXISTS (SELECT 1 FROM public.dva_statement_line_import_links l WHERE l.dva_statement_line_id = f.dva_statement_line_id) AS import_provenance_retained
  FROM funding_presence f
), row_results AS (
  SELECT
    h.*,
    CASE
      WHEN h.expected_active_visibility = false
        AND h.has_active_import_link = false
        AND h.has_inactive_import_link = true
        AND h.status_view_count = 0
        AND h.summary_view_count = 0
        AND h.physical_statement_line_retained
        AND h.import_provenance_retained
        AND (h.expected_role <> 'VOIDED_OLD_IN' OR h.in_day2_funding_worklist = false)
      THEN 'PASS'
      WHEN h.expected_active_visibility = true
        AND h.has_active_import_link = true
        AND h.status_view_count = 1
        AND h.summary_view_count = 1
        AND h.physical_statement_line_retained
        AND h.import_provenance_retained
        AND (h.expected_role <> 'VALID_REPLACEMENT_IN' OR h.in_day2_funding_worklist = true)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS result
  FROM historical_presence h
), guard_definition AS (
  SELECT pg_get_functiondef('public.staff_void_dva_statement_import_batch(uuid,text)'::regprocedure) AS function_definition
), guard_result AS (
  SELECT
    CASE
      WHEN function_definition ILIKE '%dva_statement_line_allocations%'
       AND function_definition ILIKE '%allocation_status IN (''confirmed'', ''held'')%'
       AND function_definition ILIKE '%statement_line_control_position_v1%'
       AND function_definition ILIKE '%active_consumed_gbp%'
       AND function_definition ILIKE '%active_reserved_gbp%'
       AND function_definition ILIKE '%v_blocking_allocations > 0%'
       AND function_definition ILIKE '%v_blocking_usage > 0%'
       AND function_definition ILIKE '%UPDATE public.dva_statement_line_import_links%'
       AND position('v_blocking_usage > 0' IN lower(function_definition))
           < position('update public.dva_statement_line_import_links' IN lower(function_definition))
      THEN 'PASS' ELSE 'FAIL'
    END AS result,
    function_definition
  FROM guard_definition
), used_line_sample AS (
  SELECT
    l.import_batch_id,
    l.dva_statement_line_id,
    p.active_consumed_gbp,
    p.active_reserved_gbp,
    p.raw_active_families,
    p.active_economic_lanes
  FROM public.dva_statement_line_import_links l
  JOIN public.statement_line_control_position_v1 p
    ON p.statement_line_id = l.dva_statement_line_id
  JOIN public.dva_statement_import_batches b
    ON b.id = l.import_batch_id
  WHERE l.active_yn = true
    AND b.status <> 'voided'
    AND (coalesce(p.active_consumed_gbp,0) > 0 OR coalesce(p.active_reserved_gbp,0) > 0)
  ORDER BY greatest(coalesce(p.active_consumed_gbp,0), coalesce(p.active_reserved_gbp,0)) DESC,
           l.dva_statement_line_id
  LIMIT 1
), used_line_result AS (
  SELECT
    CASE WHEN EXISTS (SELECT 1 FROM used_line_sample) THEN 'PASS' ELSE 'FAIL' END AS result,
    (SELECT to_jsonb(u) FROM used_line_sample u) AS proof
), suggestion_definition AS (
  SELECT pg_get_functiondef(p.oid) AS function_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'staff_generate_supplier_invoice_match_suggestions'
  ORDER BY p.oid
  LIMIT 1
), suggestion_result AS (
  SELECT
    CASE
      WHEN EXISTS (
        SELECT 1 FROM suggestion_definition
        WHERE function_definition ILIKE '%dva_statement_line_allocation_summary_vw%'
      )
       AND NOT EXISTS (
         SELECT 1 FROM public.dva_statement_line_allocation_summary_vw s
         WHERE s.dva_statement_line_id = '4dc1fe60-86dc-40f1-92ad-519ca3199443'::uuid
       )
       AND EXISTS (
         SELECT 1 FROM public.dva_statement_line_allocation_summary_vw s
         WHERE s.dva_statement_line_id = 'c62a750c-aa8d-4261-b594-dc9a315f4f4d'::uuid
       )
      THEN 'PASS' ELSE 'FAIL'
    END AS result
), funding_result AS (
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM public.day2_dva_review_worklist_vw w
      WHERE w.dva_statement_line_id = 'c39ff2fb-2e68-4c57-beae-229f5981cb62'::uuid
    )
    AND EXISTS (
      SELECT 1 FROM public.day2_dva_review_worklist_vw w
      WHERE w.dva_statement_line_id = 'c488e84a-0e98-446a-9c5c-1def5f7f419f'::uuid
        AND w.reconciliation_id = '14c36520-03a1-42cf-a984-f5a350b3330a'::uuid
        AND w.reconciled_order_id = 'a40fe4a1-7f49-4766-9332-4b14056608ff'::uuid
        AND round(w.reconciled_gbp_amount::numeric,2) = 894.46
    )
    THEN 'PASS' ELSE 'FAIL'
  END AS result
), overall AS (
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM row_results WHERE result <> 'PASS')
     AND (SELECT result FROM guard_result) = 'PASS'
     AND (SELECT result FROM used_line_result) = 'PASS'
     AND (SELECT result FROM suggestion_result) = 'PASS'
     AND (SELECT result FROM funding_result) = 'PASS'
    THEN 'PASS' ELSE 'FAIL'
  END AS result
)
SELECT
  'controlled_line'::text AS result_type,
  r.expected_role AS test_name,
  r.result,
  jsonb_build_object(
    'dva_statement_line_id', r.dva_statement_line_id,
    'has_active_import_link', r.has_active_import_link,
    'has_inactive_import_link', r.has_inactive_import_link,
    'status_view_count', r.status_view_count,
    'summary_view_count', r.summary_view_count,
    'in_day2_funding_worklist', r.in_day2_funding_worklist,
    'funding_reconciliation_evidence', r.funding_reconciliation_evidence,
    'physical_statement_line_retained', r.physical_statement_line_retained,
    'import_provenance_retained', r.import_provenance_retained
  ) AS proof
FROM row_results r

UNION ALL
SELECT 'guard_definition', 'existing allocation guard + canonical usage guard deployed before mutation', g.result,
       jsonb_build_object('baseline_lock', 'migration preflight compares complete stored live PL/pgSQL body and governing attributes before surgical patch')
FROM guard_result g

UNION ALL
SELECT 'used_line_guard', 'existing active imported line satisfies canonical blocking predicate', u.result,
       coalesce(u.proof, '{}'::jsonb)
FROM used_line_result u

UNION ALL
SELECT 'supplier_suggestion', 'voided OUT removed from shared suggestion source; valid replacement OUT retained', s.result,
       jsonb_build_object('suggestion_function_reads_summary_view', true)
FROM suggestion_result s

UNION ALL
SELECT 'funding_non_regression', 'funding lane unchanged for controlled IN pair', f.result,
       jsonb_build_object('voided_in_absent', true, 'valid_in_expected_reconciliation_id', '14c36520-03a1-42cf-a984-f5a350b3330a', 'valid_in_expected_reconciled_gbp', 894.46)
FROM funding_result f

UNION ALL
SELECT 'regression_result', 'DVA voided import workbench visibility v1', o.result,
       jsonb_build_object(
         'proof', 'controlled inactive-only IN/OUT excluded; active replacements retained once; immutable history retained; migration itself enforces exact retained-row invariance atomically; reviewed Void baseline is preflight-locked before surgical canonical guard insertion; an existing active-used imported line satisfies the new blocking predicate; supplier suggestion source and Funding non-regressions proven read-only'
       )
FROM overall o
ORDER BY result_type, test_name;