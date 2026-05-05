-- dva_import_void_guard_v1.sql
-- Status: EXECUTABLE SQL PATCH - RUN IN SUPABASE SQL EDITOR.
--
-- Purpose:
--   Add/replace guarded import void RPC for committed DVA/card statement imports.
--
-- Rules:
--   - admin/supervisor only;
--   - requires reason;
--   - blocks void if any committed statement line from the batch has confirmed/held allocations;
--   - marks import batch/rows/link inactive/voided;
--   - does not delete active DVA statement lines or allocation audit history;
--   - allows future re-upload by changing fingerprint uniqueness to active links only.

begin;

set local lock_timeout = '15s';
set local statement_timeout = '0';

-- Allow the same source fingerprint to be re-imported after the previous import link is voided/inactive.
alter table public.dva_statement_line_import_links
  drop constraint if exists dva_statement_line_import_links_unique_fingerprint;

create unique index if not exists dva_statement_line_import_links_unique_active_fingerprint
  on public.dva_statement_line_import_links(importer_id, source_bank, statement_line_fingerprint_hash)
  where active_yn = true;

create or replace function public.staff_void_dva_statement_import_batch(
  p_import_batch_id uuid,
  p_void_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_batch record;
  v_reason text := nullif(trim(coalesce(p_void_reason, '')), '');
  v_blocking_allocations integer := 0;
  v_linked_lines integer := 0;
  v_rows_voided integer := 0;
begin
  if v_auth_uid is null then
    raise exception 'Unauthenticated user: statement import void requires auth.uid()';
  end if;

  select s.id, s.role_type
    into v_staff
  from public.staff s
  where s.auth_user_id = v_auth_uid
    and coalesce(s.active, true) = true
  limit 1;

  if v_staff.id is null then
    raise exception 'Active staff user not found for auth user %', v_auth_uid;
  end if;

  if v_staff.role_type not in ('admin', 'supervisor') then
    raise exception 'Only admin or supervisor staff can void statement imports. Current role: %', v_staff.role_type;
  end if;

  if v_reason is null or length(v_reason) < 8 then
    raise exception 'A void reason of at least 8 characters is required.';
  end if;

  select *
    into v_batch
  from public.dva_statement_import_batches
  where id = p_import_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'Statement import batch not found: %', p_import_batch_id;
  end if;

  if v_batch.status = 'voided' then
    raise exception 'Statement import batch % is already voided.', p_import_batch_id;
  end if;

  select count(*)
    into v_linked_lines
  from public.dva_statement_line_import_links l
  where l.import_batch_id = p_import_batch_id
    and l.active_yn = true;

  select count(*)
    into v_blocking_allocations
  from public.dva_statement_line_import_links l
  join public.dva_statement_line_allocations a
    on a.dva_statement_line_id = l.dva_statement_line_id
   and a.allocation_status in ('confirmed', 'held')
  where l.import_batch_id = p_import_batch_id
    and l.active_yn = true;

  if v_blocking_allocations > 0 then
    raise exception 'Cannot void statement import %. % active allocation(s) exist. Reverse allocations first.', p_import_batch_id, v_blocking_allocations;
  end if;

  update public.dva_statement_line_import_links l
     set active_yn = false
   where l.import_batch_id = p_import_batch_id
     and l.active_yn = true;

  update public.dva_statement_import_rows r
     set parse_status = 'voided'
   where r.import_batch_id = p_import_batch_id
     and r.parse_status <> 'voided';

  get diagnostics v_rows_voided = row_count;

  update public.dva_statement_import_batches b
     set status = 'voided',
         voided_by_staff_id = v_staff.id,
         voided_at = now(),
         void_reason = v_reason,
         notes = concat_ws(E'\n', b.notes, 'VOID: ' || v_reason)
   where b.id = p_import_batch_id;

  return jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'linked_lines_inactivated', v_linked_lines,
    'rows_voided', v_rows_voided,
    'void_reason', v_reason
  );
end;
$$;

comment on function public.staff_void_dva_statement_import_batch(uuid, text) is
'Admin/supervisor RPC to void a DVA/card statement import batch only when no active confirmed/held allocations exist on its committed statement lines.';

revoke all on function public.staff_void_dva_statement_import_batch(uuid, text) from public;
grant execute on function public.staff_void_dva_statement_import_batch(uuid, text) to authenticated;

commit;

-- Smoke check:
-- select to_regprocedure('public.staff_void_dva_statement_import_batch(uuid,text)') as void_rpc;
