BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Narrow corrective migration for the resolver alias defect introduced by the
-- first installed form of 20260806173000. On a clean install the earlier
-- migration is already correct, so this migration safely no-ops.

DO $fix_resolver_aliases$
DECLARE
  v_definition text;
  v_invalid_batch_count integer;
  v_invalid_order_type_count integer;
  v_invalid_parent_check_count integer;
  v_invalid_parent_result_count integer;
  v_invalid_order_id_count integer;
  v_correct_batch_count integer;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Resolver function is missing.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  SELECT COUNT(*)::integer INTO v_invalid_batch_count
  FROM regexp_matches(
    v_definition,
    'active_membership\.source_shipment_batch_id[[:space:]]*=[[:space:]]*b\.id',
    'g'
  );

  SELECT COUNT(*)::integer INTO v_invalid_order_type_count
  FROM regexp_matches(v_definition, 'WHEN[[:space:]]+o\.order_type[[:space:]]*=', 'g');

  SELECT COUNT(*)::integer INTO v_invalid_parent_check_count
  FROM regexp_matches(
    v_definition,
    'AND[[:space:]]+o\.parent_order_id[[:space:]]+IS[[:space:]]+NOT[[:space:]]+NULL',
    'g'
  );

  SELECT COUNT(*)::integer INTO v_invalid_parent_result_count
  FROM regexp_matches(v_definition, 'THEN[[:space:]]+o\.parent_order_id', 'g');

  SELECT COUNT(*)::integer INTO v_invalid_order_id_count
  FROM regexp_matches(v_definition, 'ELSE[[:space:]]+o\.id', 'g');

  SELECT COUNT(*)::integer INTO v_correct_batch_count
  FROM regexp_matches(
    v_definition,
    'active_membership\.source_shipment_batch_id[[:space:]]*=[[:space:]]*batch_row\.id',
    'g'
  );

  IF v_invalid_batch_count = 0
     AND v_invalid_order_type_count = 0
     AND v_invalid_parent_check_count = 0
     AND v_invalid_parent_result_count = 0
     AND v_invalid_order_id_count = 0
     AND v_correct_batch_count = 1
  THEN
    -- Clean-install shape: no repair required.
    NULL;
  ELSIF v_invalid_batch_count = 1
     AND v_invalid_order_type_count = 1
     AND v_invalid_parent_check_count = 1
     AND v_invalid_parent_result_count = 1
     AND v_invalid_order_id_count = 1
     AND v_correct_batch_count = 0
  THEN
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

    EXECUTE v_definition;
  ELSE
    RAISE EXCEPTION
      'Resolver alias state is unknown. invalid counts=(%,%,%,%,%), correct batch count=%',
      v_invalid_batch_count,
      v_invalid_order_type_count,
      v_invalid_parent_check_count,
      v_invalid_parent_result_count,
      v_invalid_order_id_count,
      v_correct_batch_count;
  END IF;
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
