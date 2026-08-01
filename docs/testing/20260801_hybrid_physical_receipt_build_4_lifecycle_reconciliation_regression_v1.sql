-- Hybrid Physical Receipt Build 4 lifecycle and reconciliation regression v1
-- Read-only except for transaction-scoped controlled rows, all rolled back.

begin;

-- 1. Public reconciliation contract is unchanged.
do $contract$
declare
  v_columns text[];
begin
  select array_agg(column_name order by ordinal_position)
    into v_columns
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'order_reconciliation_vw';

  if v_columns is distinct from array[
    'order_id',
    'qty_target',
    'qty_progressed_invoiceable',
    'qty_resolved_noninvoiceable',
    'qty_unresolved',
    'amount_target_gbp',
    'amount_progressed_invoiceable_gbp',
    'amount_resolved_noninvoiceable_gbp',
    'amount_unresolved_gbp',
    'invoiceable_subset_released_yn',
    'whole_order_cleared_yn',
    'last_refreshed_at'
  ]::text[] then
    raise exception 'FAIL: reconciliation public contract changed: %', v_columns;
  end if;
end
$contract$;

-- 2. Known non-authoritative evidence must not progress canonical reconciliation.
do $known_anomaly$
declare
  v_order_id uuid;
  v_qty bigint;
  v_amount numeric;
  v_unresolved_qty bigint;
  v_unresolved_amount numeric;
  v_whole_clear boolean;
  v_non_authoritative_count integer;
  v_raw_qty_count integer;
  v_raw_amount_count integer;
begin
  select id into v_order_id
  from public.orders
  where order_ref = 'DAY3-TRACK-1d7cfa66';

  if v_order_id is null then
    raise exception 'FAIL: known anomaly order DAY3-TRACK-1d7cfa66 is missing';
  end if;

  select
    qty_progressed_invoiceable,
    amount_progressed_invoiceable_gbp,
    qty_unresolved,
    amount_unresolved_gbp,
    whole_order_cleared_yn
  into
    v_qty,
    v_amount,
    v_unresolved_qty,
    v_unresolved_amount,
    v_whole_clear
  from public.order_reconciliation_vw
  where order_id = v_order_id;

  if v_qty <> 0 or v_amount <> 0 or v_unresolved_qty <> 1 or v_unresolved_amount <> 100 or v_whole_clear then
    raise exception 'FAIL: known anomaly canonical result qty %, amount %, unresolved qty %, unresolved amount %, clear %',
      v_qty, v_amount, v_unresolved_qty, v_unresolved_amount, v_whole_clear;
  end if;

  select count(*) filter (where anomaly_code = 'NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE'),
         count(*) filter (where anomaly_code = 'RAW_QTY_OVER_PROGRESS'),
         count(*) filter (where anomaly_code = 'RAW_AMOUNT_OVER_PROGRESS')
  into v_non_authoritative_count, v_raw_qty_count, v_raw_amount_count
  from public.order_reconciliation_anomalies_v1
  where order_id = v_order_id;

  if v_non_authoritative_count <> 1 or v_raw_qty_count <> 1 or v_raw_amount_count <> 1 then
    raise exception 'FAIL: known anomaly read model counts non-authoritative %, raw qty %, raw amount %',
      v_non_authoritative_count, v_raw_qty_count, v_raw_amount_count;
  end if;
end
$known_anomaly$;

-- 3. Protected authorities remain unchanged.
do $protected$
declare
  v_md5 text;
begin
  select md5(pg_get_functiondef('public.approve_vat_release(uuid,uuid,jsonb)'::regprocedure)) into v_md5;
  if v_md5 <> '13491a2d250a480ebb1ac607ce7acce5' then raise exception 'FAIL: approve_vat_release drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.mark_order_accounting_release_ready(uuid,uuid)'::regprocedure)) into v_md5;
  if v_md5 <> 'dacaf00c6470a626cfc2d7e7aac2ccb8' then raise exception 'FAIL: mark_order_accounting_release_ready drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.recompute_order_status(uuid)'::regprocedure)) into v_md5;
  if v_md5 <> '110d55541d4f729ff9331e23515fb563' then raise exception 'FAIL: recompute_order_status drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v1()'::regprocedure)) into v_md5;
  if v_md5 <> '32e1d3eb9161cdc3e09114edb8c0d3c0' then raise exception 'FAIL: physical_remedy_allocation_guard_v1 drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) into v_md5;
  if v_md5 <> '3c5067f31d4f2112207e02d1f307e233' then raise exception 'FAIL: physical_remedy_sequence_guard_v1 drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.physical_remedy_terminal_immutability_guard_v1()'::regprocedure)) into v_md5;
  if v_md5 <> 'a7aa361f066b454a6f9c4f9b81734834' then raise exception 'FAIL: physical_remedy_terminal_immutability_guard_v1 drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.enforce_status_transition()'::regprocedure)) into v_md5;
  if v_md5 <> '5fc40897ac22a4adae838ecc6a3e1cb9' then raise exception 'FAIL: enforce_status_transition drift %', v_md5; end if;

  select md5(pg_get_functiondef('public.enforce_order_locks()'::regprocedure)) into v_md5;
  if v_md5 <> '497230d0cf04001f37c5e805cdd8da25' then raise exception 'FAIL: enforce_order_locks drift %', v_md5; end if;
end
$protected$;

-- 4. Current callers retain their grants and the atomic authority is staff-only.
do $grants$
begin
  if not has_function_privilege('authenticated', 'public.create_replacement_child_order(uuid,uuid,uuid,text)', 'EXECUTE') then
    raise exception 'FAIL: authenticated lost create_replacement_child_order execute';
  end if;

  if not has_function_privilege('service_role', 'public.create_replacement_child_order(uuid,uuid,uuid,text)', 'EXECUTE') then
    raise exception 'FAIL: service_role lost create_replacement_child_order execute';
  end if;

  if not has_function_privilege('authenticated', 'public.staff_accept_replacement_outcome_v1(uuid,uuid,text)', 'EXECUTE') then
    raise exception 'FAIL: authenticated cannot execute atomic replacement acceptance';
  end if;

  if has_function_privilege('anon', 'public.staff_accept_replacement_outcome_v1(uuid,uuid,text)', 'EXECUTE') then
    raise exception 'FAIL: anon can execute atomic replacement acceptance';
  end if;
end
$grants$;

-- 5. Parent blocker must include unfinished and already-cancelled replacement children.
do $parent_blocker$
declare
  v_parent public.orders%rowtype;
  v_open_child_id uuid := gen_random_uuid();
  v_cancelled_child_id uuid := gen_random_uuid();
  v_parent_id uuid := gen_random_uuid();
  v_ref_suffix text := replace(gen_random_uuid()::text, '-', '');
begin
  select * into v_parent
  from public.orders
  where order_type = 'original'
  order by created_at
  limit 1;

  if v_parent.id is null then
    raise exception 'FAIL: no original order available for controlled blocker test';
  end if;

  insert into public.orders (
    id, order_ref, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, order_type, order_total_gbp_declared,
    total_qty_declared, status, sop_version, created_at, updated_at
  ) values (
    v_parent_id, 'B4-PARENT-' || left(v_ref_suffix, 12), v_parent.importer_id,
    v_parent.operator_id, v_parent.shipper_id, v_parent.retailer_id,
    v_parent.destination_hub_id, 'original', 10, 1,
    'evidence_collecting', v_parent.sop_version, now(), now()
  );

  insert into public.orders (
    id, order_ref, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, parent_order_id, order_type,
    order_total_gbp_declared, total_qty_declared, status, sop_version,
    created_at, updated_at
  ) values (
    v_open_child_id, 'B4-OPEN-' || left(v_ref_suffix, 12), v_parent.importer_id,
    v_parent.operator_id, v_parent.shipper_id, v_parent.retailer_id,
    v_parent.destination_hub_id, v_parent_id, 'replacement_child',
    10, 1, 'evidence_collecting', v_parent.sop_version, now(), now()
  );

  if not public.order_has_open_child_exceptions(v_parent_id) then
    raise exception 'FAIL: unfinished replacement child did not block parent';
  end if;

  delete from public.orders where id = v_open_child_id;

  insert into public.orders (
    id, order_ref, importer_id, operator_id, shipper_id, retailer_id,
    destination_hub_id, parent_order_id, order_type,
    order_total_gbp_declared, total_qty_declared, status, sop_version,
    created_at, updated_at
  ) values (
    v_cancelled_child_id, 'B4-CANCEL-' || left(v_ref_suffix, 10), v_parent.importer_id,
    v_parent.operator_id, v_parent.shipper_id, v_parent.retailer_id,
    v_parent.destination_hub_id, v_parent_id, 'replacement_child',
    10, 1, 'cancelled', v_parent.sop_version, now(), now()
  );

  if not public.order_has_open_child_exceptions(v_parent_id) then
    raise exception 'FAIL: cancelled replacement child without reroute did not block parent';
  end if;
end
$parent_blocker$;

select jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'public reconciliation contract preserved; DAY3 pending-review qty 3 / GBP 155 excluded from canonical qty 1 / GBP 100 order and exposed as anomalies; protected authorities and grants unchanged; atomic replacement authority installed; unfinished and unrouted-cancelled replacement children block the parent'
) as regression_result;

rollback;
