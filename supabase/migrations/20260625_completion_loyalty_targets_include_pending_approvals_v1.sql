BEGIN;

-- Completion-loyalty target picker patch v1.
-- Purpose: allow the main-bank OUT reservation UI to show already-approved-pending-funding
-- completion-loyalty rewards that have not yet been staged to a main-bank OUT line.
-- This supports the corrected UX: select one OUT + tick multiple same-importer rewards.
-- It does not release credit, post to Sage, touch VAT, or change applied-loyalty credit use.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_main_bank_completion_loyalty_targets_v1(text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.internal_main_bank_completion_loyalty_targets_v1(text,integer,integer)';
  END IF;
  IF to_regclass('public.completion_loyalty_reward_approvals') IS NULL THEN
    RAISE EXCEPTION 'Missing public.completion_loyalty_reward_approvals';
  END IF;
  IF to_regclass('public.main_bank_completion_loyalty_funding_matches') IS NULL THEN
    RAISE EXCEPTION 'Missing public.main_bank_completion_loyalty_funding_matches';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  order_id uuid,
  order_ref text,
  importer_id uuid,
  importer_name text,
  qualifying_net_spend_gbp numeric,
  suggested_reward_gbp numeric,
  target_status text,
  blocker text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Unauthenticated user: main-bank loyalty targets require auth.uid()'; END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN RAISE EXCEPTION 'Accounting admin access required for main-bank loyalty targets.'; END IF;

  RETURN QUERY
  WITH proposed_targets AS (
    SELECT
      w.order_id,
      w.order_ref,
      w.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(COALESCE(w.qualifying_net_spend_gbp, 0)::numeric, 2) AS qualifying_net_spend_gbp,
      round(COALESCE(w.suggested_reward_gbp, 0)::numeric, 2) AS suggested_reward_gbp,
      w.workbench_status::text AS target_status,
      COALESCE(w.completion_blocker, w.basis_blocker)::text AS blocker,
      1 AS sort_priority
    FROM public.internal_completion_loyalty_reward_funding_workbench_v1(NULL::uuid) w
    LEFT JOIN public.importers i ON i.id = w.importer_id
    WHERE w.workbench_status = 'proposed_pending_supervisor_review'
      AND w.approval_id IS NULL
      AND round(COALESCE(w.suggested_reward_gbp, 0)::numeric, 2) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.main_bank_completion_loyalty_funding_matches lm
        WHERE lm.completed_order_id = w.order_id
          AND lm.match_status IN ('confirmed','released_available_dashboard_credit')
      )
  ), pending_approval_targets AS (
    SELECT
      o.id AS order_id,
      o.order_ref::text,
      a.importer_id,
      COALESCE(NULLIF(trim(i.trading_name), ''), NULLIF(trim(i.company_name), ''), 'Importer/customer')::text AS importer_name,
      round(COALESCE(a.qualifying_net_spend_gbp, 0)::numeric, 2) AS qualifying_net_spend_gbp,
      round(COALESCE(a.approved_amount_gbp, a.suggested_reward_gbp, 0)::numeric, 2) AS suggested_reward_gbp,
      a.approval_status::text AS target_status,
      NULL::text AS blocker,
      2 AS sort_priority
    FROM public.completion_loyalty_reward_approvals a
    JOIN public.orders o ON o.id = a.order_id
    LEFT JOIN public.importers i ON i.id = a.importer_id
    WHERE a.approval_status = 'approved_pending_funding'
      AND round(COALESCE(a.approved_amount_gbp, a.suggested_reward_gbp, 0)::numeric, 2) > 0
      AND NOT EXISTS (
        SELECT 1
        FROM public.completion_loyalty_reward_rejections r
        WHERE r.order_id = a.order_id
          AND r.active = true
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.main_bank_completion_loyalty_funding_matches lm
        WHERE lm.completed_order_id = a.order_id
          AND lm.match_status IN ('confirmed','released_available_dashboard_credit')
      )
  ), combined AS (
    SELECT * FROM proposed_targets
    UNION ALL
    SELECT p.*
    FROM pending_approval_targets p
    WHERE NOT EXISTS (
      SELECT 1 FROM proposed_targets t WHERE t.order_id = p.order_id
    )
  ), filtered AS (
    SELECT c.*
    FROM combined c
    WHERE v_search IS NULL
       OR lower(concat_ws(' ', c.order_ref, c.importer_name, c.suggested_reward_gbp::text, c.target_status)) LIKE '%' || v_search || '%'
  )
  SELECT
    f.order_id,
    f.order_ref,
    f.importer_id,
    f.importer_name,
    f.qualifying_net_spend_gbp,
    f.suggested_reward_gbp,
    f.target_status,
    f.blocker,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.sort_priority, f.order_ref DESC NULLS LAST, f.order_id DESC
  LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(text, integer, integer) TO authenticated;

COMMENT ON FUNCTION public.internal_main_bank_completion_loyalty_targets_v1(text, integer, integer) IS
'Main-bank loyalty OUT reservation targets: includes clean proposed rewards and approved_pending_funding rewards not yet staged to a main-bank OUT line. Used for one-OUT multi-reward reservation UX.';

NOTIFY pgrst, 'reload schema';

COMMIT;
