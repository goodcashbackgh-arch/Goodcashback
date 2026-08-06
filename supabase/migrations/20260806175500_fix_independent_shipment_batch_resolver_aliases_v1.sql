BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow corrective migration for the resolver alias defect introduced by
-- 20260806173000_independent_shipment_batch_customer_sales_draft_compatibility_v1.sql.
-- Changes only the five invalid alias tokens introduced inside has_active_draft.

DO $fix_resolver_aliases$
DECLARE
  v_definition text;
  v_count integer;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Resolver function is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  SELECT COUNT(*)::integer INTO v_count
  FROM regexp_matches(
    v_definition,
    'active_membership\.source_shipment_batch_id[[:space:]]*=[[:space:]]*b\.id',
    'g'
  );
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Invalid batch alias count was %, expected 1.', COALESCE(v_count, 0);
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM regexp_matches(v_definition, 'WHEN[[:space:]]+o\.order_type[[:space:]]*=', 'g');
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Invalid order_type alias count was %, expected 1.', COALESCE(v_count, 0);
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM regexp_matches(v_definition, 'AND[[:space:]]+o\.parent_order_id[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL', 'g');
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Invalid parent null-check alias count was %, expected 1.', COALESCE(v_count, 0);
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM regexp_matches(v_definition, 'THEN[[:space:]]+o\.parent_order_id', 'g');
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Invalid parent result alias count was %, expected 1.', COALESCE(v_count, 0);
  END IF;

  SELECT COUNT(*)::integer INTO v_count
  FROM regexp_matches(v_definition, 'ELSE[[:space:]]+o\.id', 'g');
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Invalid order id alias count was %, expected 1.', COALESCE(v_count, 0);
  END IF;

  v_definition := regexp_replace(
    v_definition,
    'active_membership\.source_shipment_batch_id([[:space:]]*=[[:space:]]*)b\.id',
    'active_membership.source_shipment_batch_id\1batch_row.id',
    'g'
  );
  v_definition := regexp_replace(
    v_definition,
    'WHEN([[:space:]]+)o\.order_type',
    'WHEN\1order_row.order_type',
    'g'
  );
  v_definition := regexp_replace(
    v_definition,
    'AND([[:space:]]+)o\.parent_order_id([[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL)',
    'AND\1order_row.parent_order_id\2',
    'g'
  );
  v_definition := regexp_replace(
    v_definition,
    'THEN([[:space:]]+)o\.parent_order_id',
    'THEN\1order_row.parent_order_id',
    'g'
  );
  v_definition := regexp_replace(
    v_definition,
    'ELSE([[:space:]]+)o\.id',
    'ELSE\1order_row.id',
    'g'
  );

  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = b.id') > 0
     OR strpos(v_definition, 'WHEN o.order_type') > 0
     OR strpos(v_definition, 'AND o.parent_order_id') > 0
     OR strpos(v_definition, 'THEN o.parent_order_id') > 0
     OR strpos(v_definition, 'ELSE o.id') > 0
     OR strpos(v_definition, 'active_membership.source_shipment_batch_id = batch_row.id') = 0
  THEN
    RAISE EXCEPTION 'Resolver alias correction failed closed.';
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
