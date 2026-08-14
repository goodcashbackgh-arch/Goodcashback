BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $migration$
DECLARE
  v_definition text;
  v_new_definition text;
  v_security_definer boolean;
  v_config text[];
  v_old_operator_block text;
  v_new_operator_block text;
  v_old_ownership_block text;
  v_new_ownership_block text;
BEGIN
  IF to_regprocedure('public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])') IS NULL THEN
    RAISE EXCEPTION 'Function missing: public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef, p.proconfig
  INTO v_definition, v_security_definer, v_config
  FROM pg_proc p
  WHERE p.oid = 'public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])'::regprocedure;

  IF NOT COALESCE(v_security_definer, false)
     OR NOT COALESCE(v_config, ARRAY[]::text[]) @> ARRAY['search_path=public, pg_temp']::text[] THEN
    RAISE EXCEPTION 'Correction RPC security boundary changed; stop.';
  END IF;

  IF position('corrected value would require credit release or financial-state repair' IN lower(v_definition)) = 0
     OR position('fully funded value correction must increase goods value beyond existing credit funding' IN lower(v_definition)) = 0
     OR position('perform public.recompute_order_platform_funded(p_order_id)' IN lower(v_definition)) = 0
     OR position('replacement screenshot row count postcondition failed' IN lower(v_definition)) = 0
     OR position('replacement screenshot display order postcondition failed' IN lower(v_definition)) = 0 THEN
    RAISE EXCEPTION 'Correction RPC is not the installed v1.4 authority; stop.';
  END IF;

  v_old_operator_block := $old$
  SELECT
    op.id AS operator_id,
    oi.importer_id
  INTO v_operator
  FROM public.operators op
  JOIN public.operator_importers oi
    ON oi.operator_id = op.id
   AND oi.revoked_at IS NULL
  WHERE op.auth_user_id = auth.uid()
    AND op.active = true
  ORDER BY oi.id DESC
  LIMIT 1;

  IF v_operator.operator_id IS NULL OR v_operator.importer_id IS NULL THEN
    RAISE EXCEPTION 'Active customer/operator assignment not found.';
  END IF;
$old$;

  v_new_operator_block := $new$
  SELECT
    op.id AS operator_id,
    NULL::uuid AS importer_id
  INTO v_operator
  FROM public.operators op
  WHERE op.auth_user_id = auth.uid()
    AND op.active = true
  LIMIT 1;

  IF v_operator.operator_id IS NULL THEN
    RAISE EXCEPTION 'Active customer/operator assignment not found.';
  END IF;
$new$;

  v_old_ownership_block := $old$
  IF v_order.importer_id IS DISTINCT FROM v_operator.importer_id
     OR v_order.operator_id IS DISTINCT FROM v_operator.operator_id THEN
    RAISE EXCEPTION 'Order does not belong to the active customer/operator assignment.';
  END IF;
$old$;

  v_new_ownership_block := $new$
  IF v_order.operator_id IS DISTINCT FROM v_operator.operator_id THEN
    RAISE EXCEPTION 'Order does not belong to the active customer/operator assignment.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator.operator_id
      AND oi.importer_id = v_order.importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Order does not belong to the active customer/operator assignment.';
  END IF;

  v_operator.importer_id := v_order.importer_id;
$new$;

  IF position(v_old_operator_block IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Expected v1.4 operator-resolution block not found; stop.';
  END IF;
  IF position(v_old_ownership_block IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Expected v1.4 ownership block not found; stop.';
  END IF;

  v_new_definition := replace(v_definition, v_old_operator_block, v_new_operator_block);
  v_new_definition := replace(v_new_definition, v_old_ownership_block, v_new_ownership_block);

  IF v_new_definition = v_definition
     OR position('oi.importer_id = v_order.importer_id' IN v_new_definition) = 0
     OR position('v_operator.importer_id := v_order.importer_id' IN v_new_definition) = 0
     OR position('ORDER BY oi.id DESC' IN v_new_definition) > 0 THEN
    RAISE EXCEPTION 'Order-scoped access rewrite postcondition failed; stop.';
  END IF;

  EXECUTE v_new_definition;
END
$migration$;

CREATE OR REPLACE FUNCTION public.customer_order_correction_eligibility_v1(
  p_order_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order record;
  v_funding record;
  v_probe jsonb;
  v_original_screenshot_count integer := 0;
  v_previously_fully_funded boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user.';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Order is required.';
  END IF;

  SELECT
    o.id,
    o.importer_id,
    o.total_qty_declared,
    o.order_total_gbp_declared,
    o.funded_at
  INTO v_order
  FROM public.orders o
  JOIN public.operators op
    ON op.id = o.operator_id
   AND op.auth_user_id = auth.uid()
   AND op.active = true
  WHERE o.id = p_order_id
    AND EXISTS (
      SELECT 1
      FROM public.operator_importers oi
      WHERE oi.operator_id = op.id
        AND oi.importer_id = o.importer_id
        AND oi.revoked_at IS NULL
    )
  FOR UPDATE OF o;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'Order does not belong to the active customer/operator assignment.';
  END IF;

  v_probe := public.customer_correct_unprocessed_order_v1(
    p_order_id,
    v_order.total_qty_declared,
    v_order.order_total_gbp_declared,
    NULL::text[]
  );

  IF NOT COALESCE((v_probe->>'ok')::boolean, false)
     OR COALESCE((v_probe->>'changed')::boolean, true) THEN
    RAISE EXCEPTION 'Order correction eligibility probe returned an unexpected result.';
  END IF;

  SELECT
    f.order_id,
    COALESCE(f.applied_credit_gbp, 0)::numeric AS applied_credit_gbp,
    COALESCE(f.funded_total_gbp, 0)::numeric AS funded_total_gbp,
    COALESCE(f.markup_applied_gbp, 0)::numeric AS markup_applied_gbp,
    COALESCE(f.gap_remaining_gbp, 0)::numeric AS gap_remaining_gbp,
    COALESCE(f.threshold_met_yn, false) AS threshold_met_yn
  INTO v_funding
  FROM public.order_funding_position_vw f
  WHERE f.order_id = p_order_id;

  IF v_funding.order_id IS NULL THEN
    RAISE EXCEPTION 'Order correction eligibility snapshot is unavailable.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_original_screenshot_count
  FROM public.order_screenshots os
  WHERE os.order_id = p_order_id
    AND os.note = 'Original order screenshot';

  v_previously_fully_funded := v_order.funded_at IS NOT NULL
    OR v_funding.threshold_met_yn
    OR v_funding.gap_remaining_gbp <= 0.01;

  RETURN jsonb_build_object(
    'ok', true,
    'eligible', true,
    'changed', false,
    'order_id', p_order_id,
    'importer_id', v_order.importer_id,
    'current_qty', v_order.total_qty_declared,
    'current_amount', ROUND(v_order.order_total_gbp_declared::numeric, 2),
    'original_screenshot_count', v_original_screenshot_count,
    'applied_credit_gbp', ROUND(v_funding.applied_credit_gbp, 2),
    'funded_total_gbp', ROUND(v_funding.funded_total_gbp, 2),
    'markup_applied_gbp', ROUND(v_funding.markup_applied_gbp, 2),
    'previously_fully_funded', v_previously_fully_funded
  );
END;
$$;

REVOKE ALL ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[]) TO service_role;

REVOKE ALL ON FUNCTION public.customer_order_correction_eligibility_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_order_correction_eligibility_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.customer_order_correction_eligibility_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_order_correction_eligibility_v1(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
