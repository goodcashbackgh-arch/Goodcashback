-- Completion loyalty contract close-out simulation v1
-- Purpose: read-only verification for the 23/06 completion-loyalty control contract.
-- Safe to run in Supabase SQL editor. It only creates a temporary results table for this session.
-- It does not post to Sage, create VAT rows, unlock credit, allocate DVA lines, or mutate business data.

create temp table if not exists tmp_completion_loyalty_contract_results (
  check_no integer,
  area text,
  result text,
  detail text
) on commit drop;

truncate tmp_completion_loyalty_contract_results;

do $$
declare
  v_count integer := 0;
  v_amount numeric := 0;
  v_text text := '';
  v_has_object boolean := false;
  v_fn text := '';
begin
  -- 1. Required objects exist.
  insert into tmp_completion_loyalty_contract_results
  select 10, 'required objects',
         case when missing_count = 0 then 'PASS' else 'FAIL' end,
         case when missing_count = 0 then 'All required objects exist.' else 'Missing: ' || missing_list end
  from (
    select
      count(*) filter (where object_exists = false) as missing_count,
      string_agg(object_name, ', ' order by object_name) filter (where object_exists = false) as missing_list
    from (
      values
        ('completion_loyalty_reward_rejections table', to_regclass('public.completion_loyalty_reward_rejections') is not null),
        ('main_bank_completion_loyalty_funding_matches table', to_regclass('public.main_bank_completion_loyalty_funding_matches') is not null),
        ('importer_credit_ledger table', to_regclass('public.importer_credit_ledger') is not null),
        ('order_funding_events table', to_regclass('public.order_funding_events') is not null),
        ('dva_statement_line_allocations table', to_regclass('public.dva_statement_line_allocations') is not null),
        ('normal account-credit lots function', to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') is not null),
        ('completion-loyalty lots function', to_regprocedure('public.internal_importer_available_completion_loyalty_lots_v1(uuid)') is not null),
        ('applied accounting preview function', to_regprocedure('public.internal_completion_loyalty_applied_accounting_preview_v1(text,integer,integer)') is not null),
        ('accounting control rows function', to_regprocedure('public.internal_loyalty_accounting_control_rows_v1(text,integer,integer)') is not null)
    ) as required(object_name, object_exists)
  ) x;

  -- 2. Active rejections must not have released active completion-loyalty credits.
  if to_regclass('public.completion_loyalty_reward_rejections') is not null
     and to_regclass('public.importer_credit_ledger') is not null then
    execute $sql$
      select count(*)
      from public.completion_loyalty_reward_rejections r
      join public.importer_credit_ledger c
        on c.source_type = 'completion_loyalty_reward'
       and c.source_entity_type = 'order'
       and c.source_entity_id = r.order_id
       and c.lock_reason is null
      where r.active = true
    $sql$ into v_count;

    insert into tmp_completion_loyalty_contract_results values (
      20,
      'rejection lane',
      case when v_count = 0 then 'PASS' else 'FAIL' end,
      'Active rejected orders with active released completion-loyalty credit: ' || v_count
    );
  end if;

  -- 3. Normal available account-credit function must exclude completion_loyalty_reward lots.
  if to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') is not null
     and to_regclass('public.importers') is not null then
    execute $sql$
      select count(*)
      from public.importers i
      cross join lateral public.internal_importer_available_account_credit_lots_v1(i.id) lots
      where lots.source_type = 'completion_loyalty_reward'
    $sql$ into v_count;

    insert into tmp_completion_loyalty_contract_results values (
      30,
      'customer credit separation',
      case when v_count = 0 then 'PASS' else 'FAIL' end,
      'Normal account-credit lots exposing completion_loyalty_reward: ' || v_count
    );
  end if;

  -- 4. Completion-loyalty available lots should only expose completion_loyalty_reward source type.
  if to_regprocedure('public.internal_importer_available_completion_loyalty_lots_v1(uuid)') is not null
     and to_regclass('public.importers') is not null then
    execute $sql$
      select count(*)
      from public.importers i
      cross join lateral public.internal_importer_available_completion_loyalty_lots_v1(i.id) lots
      where lots.source_type <> 'completion_loyalty_reward'
    $sql$ into v_count;

    insert into tmp_completion_loyalty_contract_results values (
      40,
      'customer credit separation',
      case when v_count = 0 then 'PASS' else 'FAIL' end,
      'Completion-loyalty lots with wrong source type: ' || v_count
    );
  end if;

  -- 5. Applied loyalty source events: direct source-of-truth count and amount.
  if to_regclass('public.order_funding_events') is not null
     and to_regclass('public.importer_credit_ledger') is not null then
    execute $sql$
      select count(*), round(coalesce(sum(abs(ofe.amount_gbp)), 0)::numeric, 2)
      from public.order_funding_events ofe
      join public.importer_credit_ledger debit on debit.id = ofe.source_entity_id
      join public.importer_credit_ledger source_credit on source_credit.id = coalesce(debit.source_id, debit.source_entity_id)
      where ofe.event_type = 'credit_applied'
        and source_credit.source_type = 'completion_loyalty_reward'
    $sql$ into v_count, v_amount;

    insert into tmp_completion_loyalty_contract_results values (
      50,
      'applied loyalty source events',
      case when v_count > 0 then 'PASS' else 'INFO' end,
      'Applied completion-loyalty credit_applied events: ' || v_count || ', amount: GBP ' || v_amount
    );
  end if;

  -- 6. Applied preview function must remain preview-only and non-postable by definition.
  if to_regprocedure('public.internal_completion_loyalty_applied_accounting_preview_v1(text,integer,integer)') is not null then
    select pg_get_functiondef('public.internal_completion_loyalty_applied_accounting_preview_v1(text,integer,integer)'::regprocedure)
      into v_fn;

    insert into tmp_completion_loyalty_contract_results values (
      60,
      'applied sage preview',
      case when v_fn ilike '%false AS selectable%'
             and v_fn ilike '%false AS posting_enabled%'
             and v_fn ilike '%preview_only_mapping_not_confirmed%'
             and v_fn ilike '%order_funding_events%'
             and v_fn ilike '%credit_applied%'
             and v_fn not ilike '%completion_loyalty_reward_journal%'
           then 'PASS' else 'FAIL' end,
      'Function definition keeps rows non-selectable, non-postable, preview-only, sourced from credit_applied, and does not use old journal queue.'
    );
  end if;

  -- 7. New main-bank release should require paired destination IN, except documented legacy released OUT-only rows.
  if to_regclass('public.main_bank_completion_loyalty_funding_matches') is not null then
    execute $sql$
      select count(*)
      from public.main_bank_completion_loyalty_funding_matches m
      where m.match_status = 'released_available_dashboard_credit'
        and m.destination_in_statement_line_id is null
        and coalesce(m.transfer_pair_status, '') <> 'legacy_released_out_only'
    $sql$ into v_count;

    insert into tmp_completion_loyalty_contract_results values (
      70,
      'main-bank/destination pairing',
      case when v_count = 0 then 'PASS' else 'FAIL' end,
      'Non-legacy released loyalty rows missing destination IN pair: ' || v_count
    );

    execute $sql$
      select count(*)
      from public.main_bank_completion_loyalty_funding_matches m
      where m.destination_in_statement_line_id is null
        and coalesce(m.transfer_pair_status, '') = 'legacy_released_out_only'
    $sql$ into v_count;

    insert into tmp_completion_loyalty_contract_results values (
      71,
      'main-bank/destination pairing',
      case when v_count = 0 then 'INFO' else 'WARN' end,
      'Documented legacy released OUT-only rows: ' || v_count
    );
  end if;

  -- 8. No fake DVA allocation rows should have been created for completion loyalty.
  if to_regclass('public.dva_statement_line_allocations') is not null then
    execute $sql$
      select count(*)
      from public.dva_statement_line_allocations a
      where row_to_json(a)::text ilike '%completion_loyalty%'
         or row_to_json(a)::text ilike '%loyalty%'
    $sql$ into v_count;

    insert into tmp_completion_loyalty_contract_results values (
      80,
      'dva/card allocation safety',
      case when v_count = 0 then 'PASS' else 'FAIL' end,
      'DVA allocation rows that appear loyalty-labelled: ' || v_count
    );
  end if;

  -- 9. Accounting control function must include the three read-only lane categories and no posting enablement wording.
  if to_regprocedure('public.internal_loyalty_accounting_control_rows_v1(text,integer,integer)') is not null then
    select pg_get_functiondef('public.internal_loyalty_accounting_control_rows_v1(text,integer,integer)'::regprocedure)
      into v_fn;

    insert into tmp_completion_loyalty_contract_results values (
      90,
      'acc control rows',
      case when v_fn ilike '%bank_internal_transfer%'
             and v_fn ilike '%non_cash_loyalty_customer_balance_settlement%'
             and v_fn ilike '%released_unused_loyalty_control_balance%'
           then 'PASS' else 'FAIL' end,
      'ACC control row function contains the required read-only control categories.'
    );
  end if;

  -- 10. Old approval-stage loyalty journal queue should not be the source for applied preview.
  v_has_object := to_regclass('public.completion_loyalty_reward_journal') is not null;
  insert into tmp_completion_loyalty_contract_results values (
    100,
    'old approval-stage sage queue',
    case when v_has_object then 'INFO' else 'PASS' end,
    case when v_has_object
      then 'Old completion_loyalty_reward_journal object exists; confirm it remains unused/suppressed for current MVP.'
      else 'Old completion_loyalty_reward_journal object not present.'
    end
  );
end $$;

select check_no, area, result, detail
from tmp_completion_loyalty_contract_results
order by check_no;

-- Summary counts
select result, count(*) as checks
from tmp_completion_loyalty_contract_results
group by result
order by result;
