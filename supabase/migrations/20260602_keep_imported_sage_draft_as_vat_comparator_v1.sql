-- Keep imported Sage draft VAT totals as the comparator of record.
-- Diagnostic/read-only Sage reconstructions must not override imported Sage draft totals
-- on pages that currently select the latest vat_return_sage_reconstruction_snapshots row.

create or replace function public.keep_imported_sage_draft_as_vat_comparator_v1()
returns trigger
language plpgsql
as $$
declare
  imported_created_at timestamptz;
begin
  if new.vat_return_run_id is null then
    return new;
  end if;

  if coalesce(new.source_basis, '') like 'sage_draft_vat_return_totals_import%' then
    return new;
  end if;

  select max(created_at)
    into imported_created_at
  from public.vat_return_sage_reconstruction_snapshots
  where vat_return_run_id = new.vat_return_run_id
    and coalesce(source_basis, '') like 'sage_draft_vat_return_totals_import%';

  if imported_created_at is not null
     and coalesce(new.created_at, now()) >= imported_created_at then
    new.created_at := imported_created_at - interval '1 millisecond';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_keep_imported_sage_draft_as_vat_comparator_v1
on public.vat_return_sage_reconstruction_snapshots;

create trigger trg_keep_imported_sage_draft_as_vat_comparator_v1
before insert on public.vat_return_sage_reconstruction_snapshots
for each row
execute function public.keep_imported_sage_draft_as_vat_comparator_v1();

-- One-off repair for any existing diagnostic snapshots created after an imported Sage draft.
with imported as (
  select
    vat_return_run_id,
    max(created_at) as imported_created_at
  from public.vat_return_sage_reconstruction_snapshots
  where coalesce(source_basis, '') like 'sage_draft_vat_return_totals_import%'
  group by vat_return_run_id
), diagnostics_to_move as (
  select
    s.id,
    i.imported_created_at,
    row_number() over (
      partition by s.vat_return_run_id
      order by s.created_at desc, s.id
    ) as rn
  from public.vat_return_sage_reconstruction_snapshots s
  join imported i on i.vat_return_run_id = s.vat_return_run_id
  where coalesce(s.source_basis, '') not like 'sage_draft_vat_return_totals_import%'
    and s.created_at >= i.imported_created_at
)
update public.vat_return_sage_reconstruction_snapshots s
set created_at = d.imported_created_at - (d.rn * interval '1 millisecond')
from diagnostics_to_move d
where s.id = d.id;
