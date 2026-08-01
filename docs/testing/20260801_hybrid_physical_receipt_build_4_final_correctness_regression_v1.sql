-- Hybrid Physical Receipt Build 4 final correctness regression v1
-- Read-only behavioural and authority checks. Run after both Build 4 migrations.

begin;

do $reconciliation_authority$
declare
  v_canonical text;
  v_anomaly text;
begin
  select lower(pg_get_viewdef('public.order_reconciliation_vw'::regclass, true)) into v_canonical;
  select lower(pg_get_viewdef('public.order_reconciliation_anomalies_v1'::regclass, true)) into v_anomaly;

  if position('is_current_for_order' in v_canonical) = 0
     or position('approved_current' in v_canonical) = 0
     or position('ref_corrected_approved' in v_canonical) = 0
     or position('blocked_from_sage_yn' in v_canonical) = 0
     or position('superseded_by_supplier_invoice_id' in v_canonical) = 0
  then
    raise exception 'FAIL: canonical supplier invoice authority is incomplete';
  end if;

  if position('is_current_for_order' in v_anomaly) = 0
     or position('review_status' in v_anomaly) = 0
     or position('blocked_from_sage_yn' in v_anomaly) = 0
     or position('superseded_by_supplier_invoice_id' in v_anomaly) = 0
     or position('non_authoritative_invoiceable_evidence' in v_anomaly) = 0
  then
    raise exception 'FAIL: anomaly authority fields or classification are missing';
  end if;
end
$reconciliation_authority$;

do $known_non_authoritative_evidence$
declare
  v_order_id uuid;
  v_qty_progressed numeric;
  v_amount_progressed numeric;
  v_anomaly_count integer;
begin
  select id into v_order_id
  from public.orders
  where order_ref = 'DAY3-TRACK-1d7cfa66';

  if v_order_id is null then
    raise exception 'FAIL: known regression order DAY3-TRACK-1d7cfa66 is missing';
  end if;

  select qty_progressed_invoiceable, amount_progressed_invoiceable_gbp
  into v_qty_progressed, v_amount_progressed
  from public.order_reconciliation_vw
  where order_id = v_order_id;

  select count(*) into v_anomaly_count
  from public.order_reconciliation_anomalies_v1
  where order_id = v_order_id
    and anomaly_code = 'NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE';

  if coalesce(v_qty_progressed, 0) <> 0
     or coalesce(v_amount_progressed, 0) <> 0
     or v_anomaly_count < 1
  then
    raise exception 'FAIL: known non-authoritative evidence is not excluded canonically and exposed as an anomaly';
  end if;
end
$known_non_authoritative_evidence$;

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
  'proof', 'canonical authority fields are installed; known non-authoritative evidence is excluded canonically and exposed as an anomaly; atomic physical and legacy branches and status sequence are installed; anon remains blocked'
) as regression_result;

rollback;
