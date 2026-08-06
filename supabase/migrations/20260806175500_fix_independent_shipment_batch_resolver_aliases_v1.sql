BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow corrective migration for the resolver alias defect introduced by
-- 20260806173000_independent_shipment_batch_customer_sales_draft_compatibility_v1.sql.
-- Changes only invalid aliases inside the exact-batch has_active_draft expression.

DO $fix_resolver_aliases$
DECLARE
  v_definition text;
  v_before_normalised text;
  v_after_normalised text;
  v_expected_before text;
  v_expected_after text;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Resolver function is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = b.id') = 0
     OR strpos(v_definition, 'WHEN o.order_type = ''replacement_child''') = 0
     OR strpos(v_definition, 'AND o.parent_order_id IS NOT NULL') = 0
     OR strpos(v_definition, 'THEN o.parent_order_id') = 0
     OR strpos(v_definition, 'ELSE o.id') = 0
  THEN
    RAISE EXCEPTION 'Expected invalid resolver aliases were not all present.';
  END IF;

  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = batch_row.id') > 0
     OR strpos(v_definition, 'WHEN order_row.order_type = ''replacement_child''') > 0
  THEN
    RAISE EXCEPTION 'Resolver appears partially corrected; refusing ambiguous rewrite.';
  END IF;

  v_before_normalised := regexp_replace(v_definition, '\s+', ' ', 'g');

  v_definition := replace(
    v_definition,
    'active_membership.source_shipment_batch_id = b.id',
    'active_membership.source_shipment_batch_id = batch_row.id'
  );
  v_definition := replace(
    v_definition,
    'WHEN o.order_type = ''replacement_child''',
    'WHEN order_row.order_type = ''replacement_child'''
  );
  v_definition := replace(
    v_definition,
    'AND o.parent_order_id IS NOT NULL',
    'AND order_row.parent_order_id IS NOT NULL'
  );
  v_definition := replace(
    v_definition,
    'THEN o.parent_order_id',
    'THEN order_row.parent_order_id'
  );
  v_definition := replace(
    v_definition,
    'ELSE o.id',
    'ELSE order_row.id'
  );

  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = b.id') > 0
     OR strpos(v_definition, 'WHEN o.order_type = ''replacement_child''') > 0
     OR strpos(v_definition, 'AND o.parent_order_id IS NOT NULL') > 0
     OR strpos(v_definition, 'THEN o.parent_order_id') > 0
     OR strpos(v_definition, 'ELSE o.id') > 0
     OR strpos(v_definition, 'active_membership.source_shipment_batch_id = batch_row.id') = 0
     OR strpos(v_definition, 'WHEN order_row.order_type = ''replacement_child''') = 0
     OR strpos(v_definition, 'AND order_row.parent_order_id IS NOT NULL') = 0
     OR strpos(v_definition, 'THEN order_row.parent_order_id') = 0
     OR strpos(v_definition, 'ELSE order_row.id') = 0
  THEN
    RAISE EXCEPTION 'Resolver alias correction failed closed.';
  END IF;

  v_after_normalised := regexp_replace(v_definition, '\s+', ' ', 'g');
  v_expected_before := replace(
    replace(
      replace(
        replace(
          replace(
            v_after_normalised,
            'active_membership.source_shipment_batch_id = batch_row.id',
            'active_membership.source_shipment_batch_id = b.id'
          ),
          'WHEN order_row.order_type = ''replacement_child''',
          'WHEN o.order_type = ''replacement_child'''
        ),
        'AND order_row.parent_order_id IS NOT NULL',
        'AND o.parent_order_id IS NOT NULL'
      ),
      'THEN order_row.parent_order_id',
      'THEN o.parent_order_id'
    ),
    'ELSE order_row.id',
    'ELSE o.id'
  );

  IF v_expected_before IS DISTINCT FROM v_before_normalised THEN
    RAISE EXCEPTION 'Resolver correction would change more than the governed aliases.';
  END IF;

  EXECUTE v_definition;
END
$fix_resolver_aliases$;

DO $postflight$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = batch_row.id') = 0
     OR strpos(v_definition, 'WHEN order_row.order_type = ''replacement_child''') = 0
     OR strpos(v_definition, 'AND order_row.parent_order_id IS NOT NULL') = 0
     OR strpos(v_definition, 'THEN order_row.parent_order_id') = 0
     OR strpos(v_definition, 'ELSE order_row.id') = 0
     OR strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'released_shipping_exceeds_current_approved_allocation') = 0
     OR strpos(v_definition, 'shipping_only_main_not_permitted') = 0
  THEN
    RAISE EXCEPTION 'Resolver alias postflight failed or protected logic was lost.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
