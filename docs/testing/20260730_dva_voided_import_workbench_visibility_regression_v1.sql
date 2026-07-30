-- 20260730_dva_voided_import_workbench_visibility_regression_v1.sql
-- Read-only regression pack for:
-- docs/governing-pack/ui/DVA_VOIDED_IMPORT_WORKBENCH_VISIBILITY_ADDENDUM_v1.md
--
-- Controlled production evidence:
--   voided old IN  c39ff2fb-2e68-4c57-beae-229f5981cb62  £841.70
--   voided old OUT 4dc1fe60-86dc-40f1-92ad-519ca3199443  £896.57
--   active new IN   c488e84a-0e98-446a-9c5c-1def5f7f419f  £896.81
--   active new OUT  c62a750c-aa8d-4261-b594-dc9a315f4f4d  £896.57

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
      SELECT 1 FROM public.dva_statement_line_import_links l
      WHERE l.dva_statement_line_id = t.dva_statement_line_id
        AND l.active_yn = true
    ) AS has_active_import_link,
    EXISTS (
      SELECT 1 FROM public.dva_statement_line_import_links l
      WHERE l.dva_statement_line_id = t.dva_statement_line_id
        AND l.active_yn = false
    ) AS has_inactive_import_link
  FROM target_lines t
), view_presence AS (
  SELECT
    p.*,
    EXISTS (
      SELECT 1 FROM public.dva_statement_line_allocation_status_vw s
      WHERE s.dva_statement_line_id = p.dva_statement_line_id
    ) AS in_status_view,
    (SELECT count(*) FROM public.dva_statement_line_allocation_status_vw s
      WHERE s.dva_statement_line_id = p.dva_statement_line_id) AS status_view_count,
    EXISTS (
      SELECT 1 FROM public.dva_statement_line_allocation_summary_vw s
      WHERE s.dva_statement_line_id = p.dva_statement_line_id
    ) AS in_summary_view,
    (SELECT count(*) FROM public.dva_statement_line_allocation_summary_vw s
      WHERE s.dva_statement_line_id = p.dva_statement_line_id) AS summary_view_count
  FROM provenance p
), funding_presence AS (
  SELECT
    v.*,
    CASE WHEN v.expected_role IN ('VOIDED_OLD_IN','VALID_REPLACEMENT_IN') THEN
      EXISTS (
        SELECT 1 FROM public.day2_dva_review_worklist_vw w
        WHERE w.dva_statement_line_id = v.dva_statement_line_id
      )
    ELSE NULL END AS in_day2_funding_worklist
  FROM view_presence v
), historical_presence AS (
  SELECT
    f.*,
    EXISTS (
      SELECT 1 FROM public.dva_statement_lines l
      WHERE l.id = f.dva_statement_line_id
    ) AS physical_statement_line_retained,
    EXISTS (
      SELECT 1 FROM public.dva_statement_line_import_links l
      WHERE l.dva_statement_line_id = f.dva_statement_line_id
    ) AS import_provenance_retained
  FROM funding_presence f
), row_results AS (
  SELECT
    h.expected_role,
    h.dva_statement_line_id,
    h.has_active_import_link,
    h.has_inactive_import_link,
    h.in_status_view,
    h.status_view_count,
    h.in_summary_view,
    h.summary_view_count,
    h.in_day2_funding_worklist,
    h.physical_statement_line_retained,
    h.import_provenance_retained,
    CASE
      WHEN h.expected_active_visibility = false
        AND h.has_active_import_link = false
        AND h.has_inactive_import_link = true
        AND h.in_status_view = false
        AND h.in_summary_view = false
        AND h.physical_statement_line_retained = true
        AND h.import_provenance_retained = true
        AND (h.expected_role <> 'VOIDED_OLD_IN' OR h.in_day2_funding_worklist = false)
      THEN 'PASS'
      WHEN h.expected_active_visibility = true
        AND h.has_active_import_link = true
        AND h.in_status_view = true
        AND h.status_view_count = 1
        AND h.in_summary_view = true
        AND h.summary_view_count = 1
        AND h.physical_statement_line_retained = true
        AND h.import_provenance_retained = true
        AND (h.expected_role <> 'VALID_REPLACEMENT_IN' OR h.in_day2_funding_worklist = true)
      THEN 'PASS'
      ELSE 'FAIL'
    END AS result
  FROM historical_presence h
), guard_definition AS (
  SELECT
    pg_get_functiondef('public.staff_void_dva_statement_import_batch(uuid,text)'::regprocedure) AS function_definition
), guard_result AS (
  SELECT CASE
    WHEN function_definition ILIKE '%statement_line_control_position_v1%'
     AND function_definition ILIKE '%active_consumed_gbp%'
     AND function_definition ILIKE '%active_reserved_gbp%'
     AND function_definition ILIKE '%dva_statement_line_allocations%'
     AND function_definition ILIKE '%confirmed%held%'
    THEN 'PASS'
    ELSE 'FAIL'
  END AS result
  FROM guard_definition
), overall AS (
  SELECT CASE
    WHEN NOT EXISTS (SELECT 1 FROM row_results WHERE result <> 'PASS')
     AND (SELECT result FROM guard_result) = 'PASS'
    THEN 'PASS'
    ELSE 'FAIL'
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
    'in_status_view', r.in_status_view,
    'status_view_count', r.status_view_count,
    'in_summary_view', r.in_summary_view,
    'summary_view_count', r.summary_view_count,
    'in_day2_funding_worklist', r.in_day2_funding_worklist,
    'physical_statement_line_retained', r.physical_statement_line_retained,
    'import_provenance_retained', r.import_provenance_retained
  ) AS proof
FROM row_results r

UNION ALL

SELECT
  'guard_definition'::text,
  'void RPC retains old allocation guard and adds canonical control-position guard'::text,
  g.result,
  '{}'::jsonb
FROM guard_result g

UNION ALL

SELECT
  'regression_result'::text,
  'DVA voided import workbench visibility v1'::text,
  o.result,
  jsonb_build_object(
    'proof', 'inactive-only imported IN/OUT excluded from active status+summary views; active replacements remain exactly once; funding lane remains unchanged and already excludes voided IN; physical statement/provenance retained; void RPC contains existing confirmed/held allocation protection plus canonical consumed/reserved guard'
  )
FROM overall o
ORDER BY result_type, test_name;
