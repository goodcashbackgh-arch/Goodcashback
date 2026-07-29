BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow patch only: teach the existing canonical settlement read model that a
-- confirmed FX allocation on a supplier-payment OUT is already a settlement
-- classification when that OUT line resolves to exactly one supplier order.
-- The OUT FX row itself is expected to have no order_id under the existing allocator.
-- Statement-line consumption, supplier payment, funding, sales and customer-credit
-- facts remain unchanged.
DO $migration$
DECLARE
  v_definition text;
  v_definition_lower text;
  v_patched text;
  v_start_anchor text := 'settlement_actions as (';
  v_end_anchor text := '), blockers as (';
  v_start integer;
  v_end integer;
  v_start_count integer;
  v_end_count integer;
  v_new text := $new$
settlement_actions AS (
   SELECT x.order_id,
      round(COALESCE(sum(x.fx_card_difference_gbp), (0)::numeric), 2) AS settlement_fx_card_difference_gbp,
      COALESCE(sum(x.active_resolution_action_count), (0)::bigint)::integer AS active_resolution_action_count,
      COALESCE(sum(x.reversed_resolution_action_count), (0)::bigint)::integer AS reversed_resolution_action_count
     FROM (
       SELECT a.order_id,
          COALESCE(sum(a.fx_card_difference_gbp) FILTER (WHERE (a.status = 'active'::text)), (0)::numeric) AS fx_card_difference_gbp,
          count(*) FILTER (WHERE (a.status = 'active'::text)) AS active_resolution_action_count,
          count(*) FILTER (WHERE (a.status = 'reversed'::text)) AS reversed_resolution_action_count
         FROM order_settlement_resolution_actions a
        GROUP BY a.order_id
       UNION ALL
       SELECT supplier_order.order_id,
          COALESCE(sum(abs(COALESCE(NULLIF(fx.fx_or_card_diff_gbp, (0)::numeric), fx.allocated_gbp_amount, (0)::numeric))), (0)::numeric) AS fx_card_difference_gbp,
          (0)::bigint AS active_resolution_action_count,
          (0)::bigint AS reversed_resolution_action_count
         FROM dva_statement_line_allocations fx
         JOIN dva_statement_lines dsl ON dsl.id = fx.dva_statement_line_id
         JOIN dva_statements ds ON ds.id = dsl.dva_statement_id
         JOIN LATERAL (
           WITH supplier_orders AS (
             SELECT DISTINCT COALESCE(si.order_id, supplier_alloc.order_id) AS order_id
               FROM dva_statement_line_allocations supplier_alloc
               LEFT JOIN supplier_invoices si ON si.id = supplier_alloc.supplier_invoice_id
              WHERE supplier_alloc.dva_statement_line_id = fx.dva_statement_line_id
                AND supplier_alloc.allocation_status = 'confirmed'::text
                AND supplier_alloc.allocation_type = 'supplier_invoice'::text
                AND COALESCE(si.order_id, supplier_alloc.order_id) IS NOT NULL
           )
           SELECT so.order_id
             FROM supplier_orders so
            WHERE (SELECT count(*) FROM supplier_orders) = 1
         ) supplier_order ON true
        WHERE fx.allocation_type = 'fx_card_difference'::text
          AND fx.allocation_status = 'confirmed'::text
          AND dsl.direction = 'out'::text
          AND COALESCE(ds.statement_account_context, 'importer_dva_card_account'::text) = 'importer_dva_card_account'::text
        GROUP BY supplier_order.order_id
     ) x
    GROUP BY x.order_id
), blockers AS (
$new$;
BEGIN
  IF to_regclass('public.order_settlement_resolution_position_v1') IS NULL THEN
    RAISE EXCEPTION 'Missing public.order_settlement_resolution_position_v1.';
  END IF;

  IF to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.supplier_invoices') IS NULL
     OR to_regclass('public.order_settlement_resolution_actions') IS NULL THEN
    RAISE EXCEPTION 'Required existing settlement/statement/supplier objects are missing.';
  END IF;

  SELECT pg_get_viewdef('public.order_settlement_resolution_position_v1'::regclass, true)
  INTO v_definition;
  v_definition_lower := lower(v_definition);

  IF position('supplier_order.order_id' IN v_definition_lower) > 0
     AND position('fx.allocation_type = ''fx_card_difference''::text' IN v_definition_lower) > 0
     AND position('dsl.direction = ''out''::text' IN v_definition_lower) > 0 THEN
    RAISE EXCEPTION 'Outbound supplier FX settlement classification appears already installed. Stop before patching.';
  END IF;

  v_start_count := (
    length(v_definition_lower) - length(replace(v_definition_lower, v_start_anchor, ''))
  ) / length(v_start_anchor);
  v_end_count := (
    length(v_definition_lower) - length(replace(v_definition_lower, v_end_anchor, ''))
  ) / length(v_end_anchor);

  IF v_start_count <> 1 OR v_end_count <> 1 THEN
    RAISE EXCEPTION 'Canonical settlement view CTE boundaries are not uniquely identifiable. settlement_actions %, blockers %. Stop before patching.', v_start_count, v_end_count;
  END IF;

  v_start := position(v_start_anchor IN v_definition_lower);
  v_end := position(v_end_anchor IN v_definition_lower);

  IF v_start <= 0 OR v_end <= v_start THEN
    RAISE EXCEPTION 'Canonical settlement view CTE order has drifted. Stop before patching.';
  END IF;

  -- Replace only the settlement_actions CTE. Matching is based on the stable CTE
  -- boundaries, not pg_get_viewdef whitespace/indent formatting.
  v_patched := substring(v_definition FROM 1 FOR v_start - 1)
    || v_new
    || substring(v_definition FROM v_end + length(v_end_anchor));

  IF v_patched = v_definition THEN
    RAISE EXCEPTION 'Canonical settlement view was not changed. Stop before patching.';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW public.order_settlement_resolution_position_v1 AS ' || v_patched;
END
$migration$;

-- Preserve the established permissions and validate the exact scoped behaviour.
REVOKE ALL ON public.order_settlement_resolution_position_v1 FROM PUBLIC, anon, authenticated;

DO $guard$
DECLARE
  v_definition text;
BEGIN
  SELECT lower(pg_get_viewdef('public.order_settlement_resolution_position_v1'::regclass, true))
  INTO v_definition;

  IF position('fx.allocation_type = ''fx_card_difference''::text' IN v_definition) = 0
     OR position('fx.allocation_status = ''confirmed''::text' IN v_definition) = 0
     OR position('supplier_alloc.allocation_type = ''supplier_invoice''::text' IN v_definition) = 0
     OR position('supplier_alloc.allocation_status = ''confirmed''::text' IN v_definition) = 0
     OR position('supplier_orders' IN v_definition) = 0
     OR position('select distinct coalesce(si.order_id, supplier_alloc.order_id)' IN v_definition) = 0
     OR position('dsl.direction = ''out''::text' IN v_definition) = 0
     OR position('statement_account_context' IN v_definition) = 0
     OR position('b.inbound_fx_receipt_residual_gbp' IN v_definition) = 0
     OR position('b.settlement_fx_card_difference_gbp' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Scoped outbound FX classification guard failed.';
  END IF;

  IF to_regprocedure('public.internal_order_settlement_resolution_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Existing internal settlement RPC contract is missing.';
  END IF;
END
$guard$;

COMMIT;
