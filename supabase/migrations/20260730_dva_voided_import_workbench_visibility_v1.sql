BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- DVA voided-import workbench visibility v1.
-- Governing addendum:
-- docs/governing-pack/ui/DVA_VOIDED_IMPORT_WORKBENCH_VISIBILITY_ADDENDUM_v1.md
--
-- Frozen production scope:
--   1) strengthen staff_void_dva_statement_import_batch(uuid,text) guard only;
--   2) make dva_statement_line_allocation_status_vw exclude inactive-only imported lines
--      and use active import provenance for imported display metadata;
--   3) make dva_statement_line_allocation_summary_vw exclude inactive-only imported lines;
--   4) no funding/day2, allocation-RPC, Sage, order, OCR, loyalty, shipper-AP, or UI changes.
--
-- Important implementation rule:
--   both views are patched from their exact live pg_get_viewdef() definitions.
--   This preserves all current columns/calculations and fails closed if the expected
--   status-view import-link join cannot be identified.

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
-- 1. Existing Void action: retain mechanics, strengthen fail-closed guard.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.staff_void_dva_statement_import_batch(
  p_import_batch_id uuid,
  p_void_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_staff record;
  v_batch record;
  v_reason text := NULLIF(TRIM(COALESCE(p_void_reason, '')), '');
  v_blocking_allocations integer := 0;
  v_blocking_usage integer := 0;
  v_linked_lines integer := 0;
  v_rows_voided integer := 0;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: statement import void requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff
  FROM public.staff s
  WHERE s.auth_user_id = v_auth_uid
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Active staff user not found for auth user %', v_auth_uid;
  END IF;

  IF v_staff.role_type NOT IN ('admin', 'supervisor') THEN
    RAISE EXCEPTION 'Only admin or supervisor staff can void statement imports. Current role: %', v_staff.role_type;
  END IF;

  IF v_reason IS NULL OR LENGTH(v_reason) < 8 THEN
    RAISE EXCEPTION 'A void reason of at least 8 characters is required.';
  END IF;

  SELECT *
    INTO v_batch
  FROM public.dva_statement_import_batches
  WHERE id = p_import_batch_id
  FOR UPDATE;

  IF v_batch.id IS NULL THEN
    RAISE EXCEPTION 'Statement import batch not found: %', p_import_batch_id;
  END IF;

  IF v_batch.status = 'voided' THEN
    RAISE EXCEPTION 'Statement import batch % is already voided.', p_import_batch_id;
  END IF;

  SELECT COUNT(*)
    INTO v_linked_lines
  FROM public.dva_statement_line_import_links l
  WHERE l.import_batch_id = p_import_batch_id
    AND l.active_yn = true;

  -- Preserve the existing confirmed/held allocation guard exactly.
  SELECT COUNT(*)
    INTO v_blocking_allocations
  FROM public.dva_statement_line_import_links l
  JOIN public.dva_statement_line_allocations a
    ON a.dva_statement_line_id = l.dva_statement_line_id
   AND a.allocation_status IN ('confirmed', 'held')
  WHERE l.import_batch_id = p_import_batch_id
    AND l.active_yn = true;

  -- Add the canonical cross-lane control guard. This catches active economic
  -- consumption/reservation outside the narrow allocation table as well.
  SELECT COUNT(DISTINCT l.dva_statement_line_id)
    INTO v_blocking_usage
  FROM public.dva_statement_line_import_links l
  JOIN public.statement_line_control_position_v1 p
    ON p.statement_line_id = l.dva_statement_line_id
  WHERE l.import_batch_id = p_import_batch_id
    AND l.active_yn = true
    AND (
      COALESCE(p.active_consumed_gbp, 0) > 0
      OR COALESCE(p.active_reserved_gbp, 0) > 0
    );

  IF v_blocking_allocations > 0 OR v_blocking_usage > 0 THEN
    RAISE EXCEPTION
      'Cannot void statement import %. Active economic use exists on linked statement lines (confirmed/held allocations: %, canonical used/reserved lines: %). Reverse or resolve active usage first.',
      p_import_batch_id,
      v_blocking_allocations,
      v_blocking_usage;
  END IF;

  UPDATE public.dva_statement_line_import_links l
     SET active_yn = false
   WHERE l.import_batch_id = p_import_batch_id
     AND l.active_yn = true;

  UPDATE public.dva_statement_import_rows r
     SET parse_status = 'voided'
   WHERE r.import_batch_id = p_import_batch_id
     AND r.parse_status <> 'voided';

  GET DIAGNOSTICS v_rows_voided = ROW_COUNT;

  UPDATE public.dva_statement_import_batches b
     SET status = 'voided',
         voided_by_staff_id = v_staff.id,
         voided_at = now(),
         void_reason = v_reason,
         notes = concat_ws(E'\n', b.notes, 'VOID: ' || v_reason)
   WHERE b.id = p_import_batch_id;

  RETURN jsonb_build_object(
    'ok', true,
    'import_batch_id', p_import_batch_id,
    'linked_lines_inactivated', v_linked_lines,
    'rows_voided', v_rows_voided,
    'void_reason', v_reason
  );
END;
$$;

COMMENT ON FUNCTION public.staff_void_dva_statement_import_batch(uuid, text) IS
'Admin/supervisor RPC to void a DVA/card statement import batch only when linked statement lines have no active canonical economic consumption/reservation; historical statement evidence is retained.';

REVOKE ALL ON FUNCTION public.staff_void_dva_statement_import_batch(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_void_dva_statement_import_batch(uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Allocation status view: patch the exact live definition.
--    a) imported display metadata may come only from an active import link;
--    b) inactive-only imported physical lines are excluded from the active view.
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

  -- If the live view has not already restricted its dlil join to active provenance,
  -- add that restriction without reconstructing any existing columns/calculations.
  IF position('dlil.active_yn' IN lower(v_patched_definition)) = 0 THEN
    v_patched_definition := regexp_replace(
      v_patched_definition,
      '(left[[:space:]]+join[[:space:]]+(public\.)?dva_statement_line_import_links[[:space:]]+dlil[[:space:]]+on[[:space:]]+\(*dlil\.dva_statement_line_id[[:space:]]*=[[:space:]]*dsl\.id\)*)',
      E'\\1 AND dlil.active_yn = true',
      'i'
    );

    IF v_patched_definition = v_existing_definition THEN
      RAISE EXCEPTION 'Refusing status-view patch: expected dlil -> dsl active import-link join anchor was not found in the live definition.';
    END IF;
  END IF;

  v_final_definition := v_patched_definition;

  -- Apply the governing inactive-only visibility predicate at the outer edge so
  -- every existing live status calculation/column remains byte-for-byte sourced
  -- from the current definition.
  IF position('voided_link.dva_statement_line_id' IN lower(v_final_definition)) = 0 THEN
    v_final_definition :=
      'SELECT live_status.* FROM ('
      || v_final_definition
      || ') live_status '
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
'Existing DVA/card statement-line allocation status read model with inactive-only imported lines excluded from active workbench status and imported display metadata restricted to active import provenance; existing live columns/calculations are otherwise preserved.';

GRANT SELECT ON public.dva_statement_line_allocation_status_vw TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Allocation summary view: patch the exact live definition/signature and
--    calculations, adding only the same inactive-only provenance visibility rule.
--    This intentionally avoids reconstructing or changing loyalty/control logic.
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

  -- Idempotence: if this exact provenance guard is already present, do not nest it.
  IF position('voided_link.dva_statement_line_id' IN lower(v_final_definition)) = 0 THEN
    v_final_definition :=
      'SELECT live_summary.* FROM ('
      || v_final_definition
      || ') live_summary '
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
'Existing DVA/card statement-line allocation summary read model with inactive-only imported statement lines excluded from active workbench participation. Existing live columns and calculations are otherwise preserved.';

GRANT SELECT ON public.dva_statement_line_allocation_summary_vw TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
