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
-- 2. Allocation status view: preserve existing status calculations and signature,
--    but use only active import linkage for imported display metadata and exclude
--    physical lines whose import provenance is inactive-only.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_line_statement_date_expr text;
  v_line_transaction_date_expr text;
  v_line_description_expr text;
  v_line_reference_expr text;
  v_line_amount_local_expr text;
  v_line_currency_expr text;
  v_has_col boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'dva_statement_lines' AND column_name = 'statement_date'
  ) INTO v_has_col;
  v_line_statement_date_expr := CASE WHEN v_has_col THEN 'coalesce(dsl.statement_date, dir.statement_date)' ELSE 'dir.statement_date' END;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'dva_statement_lines' AND column_name = 'transaction_date'
  ) INTO v_has_col;
  v_line_transaction_date_expr := CASE WHEN v_has_col THEN 'coalesce(dsl.transaction_date, dir.transaction_date)' ELSE 'dir.transaction_date' END;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'dva_statement_lines' AND column_name = 'description'
  ) INTO v_has_col;
  v_line_description_expr := CASE WHEN v_has_col THEN 'dsl.description' ELSE 'dir.raw_text' END;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'dva_statement_lines' AND column_name = 'reference'
  ) INTO v_has_col;
  v_line_reference_expr := CASE WHEN v_has_col THEN 'dsl.reference' ELSE 'dir.bank_reference' END;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'dva_statement_lines' AND column_name = 'amount_local_ccy'
  ) INTO v_has_col;
  v_line_amount_local_expr := CASE WHEN v_has_col THEN 'dsl.amount_local_ccy' ELSE 'dir.amount_local_ccy' END;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'dva_statement_lines' AND column_name = 'currency'
  ) INTO v_has_col;
  v_line_currency_expr := CASE WHEN v_has_col THEN 'dsl.currency' ELSE 'dir.local_ccy' END;

  EXECUTE format($view$
    CREATE OR REPLACE VIEW public.dva_statement_line_allocation_status_vw AS
    WITH allocation_totals AS (
      SELECT
        a.dva_statement_line_id,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed'), 0)::numeric, 2) AS confirmed_allocated_gbp,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type = 'supplier_invoice'), 0)::numeric, 2) AS confirmed_supplier_invoice_gbp,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('retailer_refund', 'exception_hold', 'not_charged_closure', 'unmatched_hold')), 0)::numeric, 2) AS confirmed_operational_gbp,
        round(coalesce(sum(a.allocated_gbp_amount) filter (where a.allocation_status = 'confirmed' and a.allocation_type in ('fx_card_difference', 'bank_fee')), 0)::numeric, 2) AS confirmed_fx_fee_gbp,
        count(*) filter (where a.allocation_status = 'confirmed') AS confirmed_allocation_count,
        count(*) filter (where a.allocation_status = 'held') AS held_allocation_count,
        count(*) filter (where a.allocation_status = 'reversed') AS reversed_allocation_count,
        count(*) AS total_allocation_count
      FROM public.dva_statement_line_allocations a
      GROUP BY a.dva_statement_line_id
    )
    SELECT
      dsl.id AS dva_statement_line_id,
      dsl.dva_statement_id,
      ds.importer_id,
      %s AS statement_date,
      %s AS transaction_date,
      %s AS description,
      %s AS reference,
      dsl.direction,
      round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric, 2) AS statement_gbp_amount,
      round(coalesce(%s, 0)::numeric, 2) AS amount_local_ccy,
      %s AS currency,
      coalesce(t.confirmed_allocated_gbp, 0::numeric) AS confirmed_allocated_gbp,
      coalesce(t.confirmed_supplier_invoice_gbp, 0::numeric) AS confirmed_supplier_invoice_gbp,
      coalesce(t.confirmed_operational_gbp, 0::numeric) AS confirmed_operational_gbp,
      coalesce(t.confirmed_fx_fee_gbp, 0::numeric) AS confirmed_fx_fee_gbp,
      round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2) AS confirmed_unallocated_gbp,
      coalesce(t.confirmed_allocation_count, 0) AS confirmed_allocation_count,
      coalesce(t.held_allocation_count, 0) AS held_allocation_count,
      coalesce(t.reversed_allocation_count, 0) AS reversed_allocation_count,
      coalesce(t.total_allocation_count, 0) AS total_allocation_count,
      CASE
        WHEN coalesce(t.held_allocation_count, 0) > 0 THEN 'held'
        WHEN coalesce(t.confirmed_allocation_count, 0) = 0 AND coalesce(t.reversed_allocation_count, 0) > 0 THEN 'reversed_only'
        WHEN coalesce(t.confirmed_allocation_count, 0) = 0 THEN 'unmatched'
        WHEN abs(round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2)) < 0.01 THEN 'balanced'
        WHEN coalesce(t.confirmed_allocated_gbp, 0::numeric) > 0 THEN 'part_allocated'
        ELSE 'unmatched'
      END AS allocation_status_bucket,
      CASE
        WHEN coalesce(t.confirmed_allocation_count, 0) = 0 THEN true
        WHEN abs(round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2)) >= 0.01 THEN true
        ELSE false
      END AS selectable_for_new_allocation_yn,
      CASE
        WHEN abs(round(coalesce(dsl.amount_gbp_equivalent, 0)::numeric - coalesce(t.confirmed_allocated_gbp, 0::numeric), 2)) < 0.01
          AND coalesce(t.confirmed_allocation_count, 0) > 0
          AND coalesce(t.held_allocation_count, 0) = 0
        THEN true ELSE false
      END AS ready_for_supervisor_review_yn
    FROM public.dva_statement_lines dsl
    JOIN public.dva_statements ds
      ON ds.id = dsl.dva_statement_id
    LEFT JOIN public.dva_statement_line_import_links dlil
      ON dlil.dva_statement_line_id = dsl.id
     AND dlil.active_yn = true
    LEFT JOIN public.dva_statement_import_rows dir
      ON dir.id = dlil.import_row_id
    LEFT JOIN allocation_totals t
      ON t.dva_statement_line_id = dsl.id
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.dva_statement_line_import_links voided_link
      WHERE voided_link.dva_statement_line_id = dsl.id
        AND voided_link.active_yn = false
        AND NOT EXISTS (
          SELECT 1
          FROM public.dva_statement_line_import_links active_link
          WHERE active_link.dva_statement_line_id = dsl.id
            AND active_link.active_yn = true
        )
    );
  $view$,
    v_line_statement_date_expr,
    v_line_transaction_date_expr,
    v_line_description_expr,
    v_line_reference_expr,
    v_line_amount_local_expr,
    v_line_currency_expr
  );
END $$;

COMMENT ON VIEW public.dva_statement_line_allocation_status_vw IS
'DVA/card statement-line allocation status view. Inactive-only imported statement lines are historical and excluded from active workbench status; active and non-import lines retain existing allocation calculations.';

GRANT SELECT ON public.dva_statement_line_allocation_status_vw TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. Allocation summary view: preserve the exact live definition/signature and
--    calculations, adding only the same inactive-only provenance visibility rule.
--    This intentionally avoids reconstructing or changing loyalty/control logic.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_existing_definition text;
BEGIN
  SELECT pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)
    INTO v_existing_definition;

  IF v_existing_definition IS NULL OR btrim(v_existing_definition) = '' THEN
    RAISE EXCEPTION 'Could not read live definition of dva_statement_line_allocation_summary_vw.';
  END IF;

  -- Idempotence: if this exact provenance guard is already present, do not nest it.
  IF position('voided_link.dva_statement_line_id' IN v_existing_definition) = 0 THEN
    EXECUTE
      'CREATE OR REPLACE VIEW public.dva_statement_line_allocation_summary_vw AS '
      || 'SELECT live_summary.* FROM ('
      || v_existing_definition
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
END $$;

COMMENT ON VIEW public.dva_statement_line_allocation_summary_vw IS
'Existing DVA/card statement-line allocation summary read model with inactive-only imported statement lines excluded from active workbench participation. Existing live columns and calculations are otherwise preserved.';

GRANT SELECT ON public.dva_statement_line_allocation_summary_vw TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
