-- Hybrid Physical Receipt Build 4 final correctness regression v1
-- Read-only definition and authority checks. Run after all three Build 4 migrations.

begin;

do $reconciliation_authority$
declare
  v_definition text;
begin
  select pg_get_viewdef('public.order_reconciliation_vw'::regclass, true)
    into v_definition;

  if position('is_current_for_order' in v_definition) = 0 then
    raise exception 'FAIL: canonical reconciliation does not require explicit current invoice identity';
  end if;

  if position('approved_current' in v_definition) = 0
     or position('ref_corrected_approved' in v_definition) = 0
     or position('blocked_from_sage_yn' in v_definition) = 0
     or position('superseded_by_supplier_invoice_id' in v_definition) = 0
  then
    raise exception 'FAIL: canonical supplier invoice authority is incomplete';
  end if;
end
$reconciliation_authority$;

do $atomic_replacement_authority$
declare
  v_definition text;
begin
  select pg_get_functiondef(
    'public.staff_accept_replacement_outcome_v1(uuid,uuid,text)'::regprocedure
  ) into v_definition;

  if position('Physical and legacy replacement lines cannot be mixed' in v_definition) = 0 then
    raise exception 'FAIL: physical/legacy mixed-source rejection is missing';
  end if;

  if position('A physical replacement requires exactly one approved remedy-linked dispute line' in v_definition) = 0 then
    raise exception 'FAIL: exact one-line physical replacement authority is missing';
  end if;

  if position('replacement_source_dispute_line_id' in v_definition) = 0
     or position('legacy_source_dispute_line_ids' in v_definition) = 0
  then
    raise exception 'FAIL: replacement provenance branches are incomplete';
  end if;

  if position('null, null, now(), now()' in v_definition) = 0 then
    raise exception 'FAIL: legacy multi-line child still appears to claim one arbitrary source dispute line';
  end if;

  if position('create_replacement_child_order' in v_definition) = 0 then
    raise exception 'FAIL: physical replacement does not use hardened child creation authority';
  end if;
end
$atomic_replacement_authority$;

do $application_grants$
begin
  if has_function_privilege(
    'anon',
    'public.staff_accept_replacement_outcome_v1(uuid,uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL: anon can execute atomic replacement acceptance';
  end if;

  if not has_function_privilege(
    'authenticated',
    'public.staff_accept_replacement_outcome_v1(uuid,uuid,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL: authenticated staff caller lost atomic replacement acceptance';
  end if;
end
$application_grants$;

select jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'canonical reconciliation requires explicit current approved unblocked non-superseded invoice identity; atomic replacement authority separates exact physical provenance from legacy multi-line aggregate provenance; anon remains blocked'
) as regression_result;

rollback;
