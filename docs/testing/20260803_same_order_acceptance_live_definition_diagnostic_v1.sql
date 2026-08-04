-- Read-only diagnostic: report the installed same-order acceptance definition state.

WITH f AS (
  SELECT pg_get_functiondef(
    'public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)'::regprocedure
  ) AS definition
)
SELECT jsonb_build_object(
  'has_old_in_progress_assignment',
    position('SET supplier_cost_mode=''free_replacement'',status=''in_progress'',updated_at=v_now' in definition) > 0,
  'has_corrected_assignment',
    position('SET supplier_cost_mode=''free_replacement'',updated_at=v_now' in definition) > 0,
  'contains_any_in_progress_literal',
    position('in_progress' in definition) > 0,
  'function_md5',md5(definition),
  'definition',definition
) AS diagnostic
FROM f;
