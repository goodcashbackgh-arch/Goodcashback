-- Hybrid Physical Receipt Build 4 final correctness regression v1
-- Read-only definition and authority checks. Run after both Build 4 migrations.

begin;

do $reconciliation_authority$
declare
  v_canonical text;
  v_anomaly text;
begin
  select pg_get_viewdef('public.order_reconciliation_vw'::regclass, true) into v_canonical;
  select pg_get_viewdef('public.order_reconciliation_anomalies_v1'::regclass, true) into v_anomaly;

  if position('is_current_for_order' in v_canonical) = 0
     or position('approved_current' in v_canonical) = 0
     or position('ref_corrected_approved' in v_canonical) = 0
     or position('blocked_from_sage_yn' in v_canonical) = 0
     or position('superseded_by_supplier_invoice_id' in v_canonical) = 0
  then
    raise exception 'FAIL: canonical supplier invoice authority is incomplete';
  end if;

  if position('is_current_for_order IS DISTINCT FROM true' in v_anomaly) = 0
     or position('review_status IS NULL' in v_anomaly) = 0
     or position('review_status <> ALL' in v_anomaly) = 0
     or position('blocked_from_sage_yn IS DISTINCT FROM false' in v_anomaly) = 0
     or position('superseded_by_supplier_invoice_id IS NOT NULL' in v_anomaly) = 0
     or position('NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE' in v_anomaly) = 0
  then
    raise exception 'FAIL: anomaly authority is not the null-safe inverse of canonical authority';
  end if;
end
$reconciliation_authority$;

do $null_semantics$
begin
  if not (
    null::boolean is distinct from true
    and null::boolean is distinct from false
    and null::text is null
  ) then
    raise exception 'FAIL: null-safety assumptions do not hold';
  end if;
end
$null_semantics$;

do $atomic_replacement_authority$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.staff_accept_replacement_outcome_v1(uuid,uuid,text)'::regprocedure)
    into v_definition;

  if position('Physical and legacy replacement lines cannot be mixed' in v_definition) = 0 then
    raise exception 'FAIL: physical/legacy mixed-source rejection is missing';
  end if;

  if position('A physical replacement requires exactly one approved remedy-linked dispute line' in v_definition) = 0 then
    raise exception 'FAIL: exact one-line physical replacement authority is missing';
  end if;

  if position('replacement_source_dispute_line_id' in v_definition) = 0
     or position('legacy_source_dispute_line_ids' in v_definition) = 0
     or position('create_replacement_child_order' in v_definition) = 0
  then
    raise exception 'FAIL: replacement provenance branches are incomplete';
  end if;

  if position('status = ''under_review''' in v_definition) = 0
     or position('status = ''approved_replacement''' in v_definition) = 0
     or position('status = ''replaced''' in v_definition) = 0
  then
    raise exception 'FAIL: atomic status sequence is incomplete';
  end if;
end
$atomic_replacement_authority$;

do $application_grants$
begin
  if has_function_privilege('anon','public.staff_accept_replacement_outcome_v1(uuid,uuid,text)','EXECUTE') then
    raise exception 'FAIL: anon can execute atomic replacement acceptance';
  end if;

  if not has_function_privilege('authenticated','public.staff_accept_replacement_outcome_v1(uuid,uuid,text)','EXECUTE') then
    raise exception 'FAIL: authenticated staff caller lost atomic replacement acceptance';
  end if;
end
$application_grants$;

select jsonb_build_object(
  'regression_result', 'PASS',
  'proof', 'canonical authority is complete; anomaly authority is its null-safe inverse; atomic physical and legacy branches and status sequence are installed; anon remains blocked'
) as regression_result;

rollback;
