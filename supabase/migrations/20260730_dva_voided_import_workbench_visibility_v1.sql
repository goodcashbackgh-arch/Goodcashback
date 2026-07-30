BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- DVA voided-import workbench visibility v1.
-- Governing addendum:
-- docs/governing-pack/ui/DVA_VOIDED_IMPORT_WORKBENCH_VISIBILITY_ADDENDUM_v1.md
--
-- Frozen production scope:
--   1) baseline-lock and surgically augment staff_void_dva_statement_import_batch(uuid,text);
--   2) patch exact live dva_statement_line_allocation_status_vw definition;
--   3) patch exact live dva_statement_line_allocation_summary_vw definition;
--   4) prove retained-row invariance inside this transaction;
--   5) no funding/day2, allocation-RPC, Sage, order, OCR, loyalty, shipper-AP, or UI changes.

DO $$
BEGIN
  IF to_regclass('public.dva_statement_import_batches') IS NULL
     OR to_regclass('public.dva_statement_import_rows') IS NULL
     OR to_regclass('public.dva_statement_line_import_links') IS NULL
     OR to_regclass('public.dva_statement_lines') IS NULL
     OR to_regclass('public.dva_statements') IS NULL
     OR to_regclass('public.dva_statement_line_allocations') IS NULL
     OR to_regclass('public.statement_line_control_position_v1') IS NULL
     OR to_regclass('public.dva_statement_line_allocation_status_vw') IS NULL
     OR to_regclass('public.dva_statement_line_allocation_summary_vw') IS NULL
     OR to_regclass('public.staff') IS NULL
  THEN
    RAISE EXCEPTION 'DVA voided-import visibility prerequisite relation/view is missing.';
  END IF;

  IF to_regprocedure('public.staff_void_dva_statement_import_batch(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.staff_void_dva_statement_import_batch(uuid,text).';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'statement_line_control_position_v1'
      AND column_name IN ('statement_line_id', 'active_consumed_gbp', 'active_reserved_gbp')
    GROUP BY table_schema, table_name
    HAVING COUNT(*) = 3
  ) THEN
    RAISE EXCEPTION 'statement_line_control_position_v1 does not expose the required active usage columns.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 1. Snapshot retained rows BEFORE any view change.
--    Rows with any inactive import link are excluded from byte-for-byte invariance
--    because the addendum explicitly permits their provenance/display visibility to
--    change. Active-only imported rows and no-link legacy/manual rows must not move.
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE _dva_void_status_before ON COMMIT DROP AS
SELECT
  s.dva_statement_line_id,
  to_jsonb(s) AS row_json,
  count(*) OVER (PARTITION BY s.dva_statement_line_id, to_jsonb(s)) AS row_multiplicity
FROM public.dva_statement_line_allocation_status_vw s
WHERE NOT EXISTS (
  SELECT 1
  FROM public.dva_statement_line_import_links l
  WHERE l.dva_statement_line_id = s.dva_statement_line_id
    AND l.active_yn = false
);

CREATE TEMP TABLE _dva_void_summary_before ON COMMIT DROP AS
SELECT
  s.dva_statement_line_id,
  to_jsonb(s) AS row_json,
  count(*) OVER (PARTITION BY s.dva_statement_line_id, to_jsonb(s)) AS row_multiplicity
FROM public.dva_statement_line_allocation_summary_vw s
WHERE NOT EXISTS (
  SELECT 1
  FROM public.dva_statement_line_import_links l
  WHERE l.dva_statement_line_id = s.dva_statement_line_id
    AND l.active_yn = false
);

-- -----------------------------------------------------------------------------
-- 2. Baseline-lock the existing Void RPC, then surgically insert only the new
--    canonical active-consumed / active-reserved guard into its exact live definition.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_oid oid := 'public.staff_void_dva_statement_import_batch(uuid,text)'::regprocedure::oid;
  v_live_body text;
  v_live_definition text;
  v_patched_definition text;
  v_expected_body text := $baseline$
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
$baseline$;
BEGIN
  SELECT p.prosrc
    INTO v_live_body
  FROM pg_proc p
  WHERE p.oid = v_oid;

  IF regexp_replace(lower(btrim(v_live_body)), '[[:space:]]+', ' ', 'g')
     <> regexp_replace(lower(btrim(v_expected_body)), '[[:space:]]+', ' ', 'g') THEN
    RAISE EXCEPTION 'Refusing void-RPC patch: live function body has drifted from reviewed dva_import_void_guard_v1 baseline.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_language l ON l.oid = p.prolang
    WHERE p.oid = v_oid
      AND l.lanname = 'plpgsql'
      AND p.prosecdef = true
      AND p.prorettype = 'jsonb'::regtype
      AND COALESCE(array_to_string(p.proconfig, ','), '') ILIKE '%search_path=public, pg_temp%'
  ) THEN
    RAISE EXCEPTION 'Refusing void-RPC patch: live function attributes differ from reviewed SECURITY DEFINER / plpgsql / jsonb / search_path baseline.';
  END IF;

  SELECT pg_get_functiondef(v_oid) INTO v_live_definition;
  v_patched_definition := v_live_definition;

  v_patched_definition := replace(
    v_patched_definition,
    'v_blocking_allocations integer := 0;',
    'v_blocking_allocations integer := 0;' || E'\n  ' || 'v_blocking_usage integer := 0;'
  );

  IF v_patched_definition = v_live_definition THEN
    RAISE EXCEPTION 'Refusing void-RPC patch: declaration anchor not found.';
  END IF;

  v_live_definition := v_patched_definition;
  v_patched_definition := replace(
    v_live_definition,
    $anchor$if v_blocking_allocations > 0 then
    raise exception 'Cannot void statement import %. % active allocation(s) exist. Reverse allocations first.', p_import_batch_id, v_blocking_allocations;
  end if;$anchor$,
    $replacement$if v_blocking_allocations > 0 then
    raise exception 'Cannot void statement import %. % active allocation(s) exist. Reverse allocations first.', p_import_batch_id, v_blocking_allocations;
  end if;

  select count(distinct l.dva_statement_line_id)
    into v_blocking_usage
  from public.dva_statement_line_import_links l
  join public.statement_line_control_position_v1 p
    on p.statement_line_id = l.dva_statement_line_id
  where l.import_batch_id = p_import_batch_id
    and l.active_yn = true
    and (
      coalesce(p.active_consumed_gbp, 0) > 0
      or coalesce(p.active_reserved_gbp, 0) > 0
    );

  if v_blocking_usage > 0 then
    raise exception 'Cannot void statement import %. % linked statement line(s) have active economic consumption or reservation. Reverse or resolve active usage first.', p_import_batch_id, v_blocking_usage;
  end if;$replacement$
  );

  IF v_patched_definition = v_live_definition THEN
    RAISE EXCEPTION 'Refusing void-RPC patch: existing confirmed/held guard anchor not found.';
  END IF;

  EXECUTE v_patched_definition;
END $$;

COMMENT ON FUNCTION public.staff_void_dva_statement_import_batch(uuid, text) IS
'Admin/supervisor RPC preserving the reviewed import-void baseline while additionally blocking linked statement lines with canonical active economic consumption/reservation.';

REVOKE ALL ON FUNCTION public.staff_void_dva_statement_import_batch(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_void_dva_statement_import_batch(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Allocation status view: patch its exact live definition only.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_existing_definition text;
  v_patched_definition text;
  v_final_definition text;
BEGIN
  SELECT pg_get_viewdef('public.dva_statement_line_allocation_status_vw'::regclass, true)
    INTO v_existing_definition;

  IF v_existing_definition IS NULL OR btrim(v_existing_definition) = '' THEN
    RAISE EXCEPTION 'Could not read live definition of dva_statement_line_allocation_status_vw.';
  END IF;

  v_patched_definition := v_existing_definition;

  IF position('dlil.active_yn' IN lower(v_patched_definition)) = 0 THEN
    v_patched_definition := regexp_replace(
      v_patched_definition,
      '(left[[:space:]]+join[[:space:]]+(public\.)?dva_statement_line_import_links[[:space:]]+dlil[[:space:]]+on[[:space:]]+\(*dlil\.dva_statement_line_id[[:space:]]*=[[:space:]]*dsl\.id\)*)',
      E'\\1 AND dlil.active_yn = true',
      'i'
    );

    IF v_patched_definition = v_existing_definition THEN
      RAISE EXCEPTION 'Refusing status-view patch: expected dlil -> dsl import-link join anchor was not found.';
    END IF;
  END IF;

  v_final_definition := v_patched_definition;

  IF position('voided_link.dva_statement_line_id' IN lower(v_final_definition)) = 0 THEN
    v_final_definition :=
      'SELECT live_status.* FROM (' || v_final_definition || ') live_status '
      || 'WHERE NOT EXISTS ('
      || ' SELECT 1 FROM public.dva_statement_line_import_links voided_link'
      || ' WHERE voided_link.dva_statement_line_id = live_status.dva_statement_line_id'
      || '   AND voided_link.active_yn = false'
      || '   AND NOT EXISTS ('
      || '     SELECT 1 FROM public.dva_statement_line_import_links active_link'
      || '     WHERE active_link.dva_statement_line_id = live_status.dva_statement_line_id'
      || '       AND active_link.active_yn = true'
      || '   )'
      || ')';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW public.dva_statement_line_allocation_status_vw AS ' || v_final_definition;
END $$;

COMMENT ON VIEW public.dva_statement_line_allocation_status_vw IS
'Existing DVA/card allocation status read model with inactive-only imported lines excluded and imported display metadata restricted to active provenance; retained live calculations are unchanged.';
GRANT SELECT ON public.dva_statement_line_allocation_status_vw TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. Allocation summary view: patch its exact live definition only.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_existing_definition text;
  v_final_definition text;
BEGIN
  SELECT pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)
    INTO v_existing_definition;

  IF v_existing_definition IS NULL OR btrim(v_existing_definition) = '' THEN
    RAISE EXCEPTION 'Could not read live definition of dva_statement_line_allocation_summary_vw.';
  END IF;

  v_final_definition := v_existing_definition;
  IF position('voided_link.dva_statement_line_id' IN lower(v_final_definition)) = 0 THEN
    v_final_definition :=
      'SELECT live_summary.* FROM (' || v_final_definition || ') live_summary '
      || 'WHERE NOT EXISTS ('
      || ' SELECT 1 FROM public.dva_statement_line_import_links voided_link'
      || ' WHERE voided_link.dva_statement_line_id = live_summary.dva_statement_line_id'
      || '   AND voided_link.active_yn = false'
      || '   AND NOT EXISTS ('
      || '     SELECT 1 FROM public.dva_statement_line_import_links active_link'
      || '     WHERE active_link.dva_statement_line_id = live_summary.dva_statement_line_id'
      || '       AND active_link.active_yn = true'
      || '   )'
      || ')';
  END IF;

  EXECUTE 'CREATE OR REPLACE VIEW public.dva_statement_line_allocation_summary_vw AS ' || v_final_definition;
END $$;

COMMENT ON VIEW public.dva_statement_line_allocation_summary_vw IS
'Existing DVA/card allocation summary with inactive-only imported statement lines excluded; retained live columns/calculations are unchanged.';
GRANT SELECT ON public.dva_statement_line_allocation_summary_vw TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. Exact retained-row invariance. Any unexpected retained-row difference aborts
--    this transaction and rolls back the function and both views.
-- -----------------------------------------------------------------------------

CREATE TEMP TABLE _dva_void_status_after ON COMMIT DROP AS
SELECT
  s.dva_statement_line_id,
  to_jsonb(s) AS row_json,
  count(*) OVER (PARTITION BY s.dva_statement_line_id, to_jsonb(s)) AS row_multiplicity
FROM public.dva_statement_line_allocation_status_vw s
WHERE NOT EXISTS (
  SELECT 1
  FROM public.dva_statement_line_import_links l
  WHERE l.dva_statement_line_id = s.dva_statement_line_id
    AND l.active_yn = false
);

CREATE TEMP TABLE _dva_void_summary_after ON COMMIT DROP AS
SELECT
  s.dva_statement_line_id,
  to_jsonb(s) AS row_json,
  count(*) OVER (PARTITION BY s.dva_statement_line_id, to_jsonb(s)) AS row_multiplicity
FROM public.dva_statement_line_allocation_summary_vw s
WHERE NOT EXISTS (
  SELECT 1
  FROM public.dva_statement_line_import_links l
  WHERE l.dva_statement_line_id = s.dva_statement_line_id
    AND l.active_yn = false
);

DO $$
BEGIN
  IF EXISTS (
    (SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_status_before
     EXCEPT ALL
     SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_status_after)
    UNION ALL
    (SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_status_after
     EXCEPT ALL
     SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_status_before)
  ) THEN
    RAISE EXCEPTION 'Retained-line invariance failed for dva_statement_line_allocation_status_vw. Rolling back.';
  END IF;

  IF EXISTS (
    (SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_summary_before
     EXCEPT ALL
     SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_summary_after)
    UNION ALL
    (SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_summary_after
     EXCEPT ALL
     SELECT dva_statement_line_id, row_json, row_multiplicity FROM _dva_void_summary_before)
  ) THEN
    RAISE EXCEPTION 'Retained-line invariance failed for dva_statement_line_allocation_summary_vw. Rolling back.';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;