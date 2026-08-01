BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_validate_vat_adjustment_source_allocations_v1(
  p_journal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_journal public.vat_return_adjustment_journals%rowtype;
  v_allocation record;
  v_allocation_count integer := 0;
  v_total numeric(18,2) := 0;
  v_basis_amount numeric(18,2);
  v_consumed numeric(18,2);
  v_current_hash text;
  v_errors jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_journal
  FROM public.vat_return_adjustment_journals
  WHERE id = p_journal_id
  FOR UPDATE;

  IF v_journal.id IS NULL THEN
    RAISE EXCEPTION 'VAT adjustment journal not found.';
  END IF;

  IF v_journal.source_allocation_version IS DISTINCT FROM 'multi_source_v1' THEN
    RAISE EXCEPTION 'Journal is not governed by multi_source_v1.';
  END IF;

  -- Lock all allocated source rows in deterministic order. Locks remain held
  -- through the caller transaction, including the final approval update.
  PERFORM 1
  FROM public.vat_return_run_lines l
  JOIN public.vat_return_adjustment_journal_source_allocations a
    ON a.vat_return_run_line_id = l.id
  WHERE a.vat_return_adjustment_journal_id = p_journal_id
  ORDER BY l.id
  FOR UPDATE OF l;

  FOR v_allocation IN
    SELECT
      a.id AS allocation_id,
      a.vat_return_run_line_id,
      a.allocated_amount_gbp,
      a.source_snapshot_json,
      l.vat_return_run_id,
      l.box_number,
      l.direction,
      l.amount_gbp,
      l.vat_amount_gbp,
      l.status AS source_status,
      l.adjustment_required,
      l.line_kind,
      l.vat_basis,
      l.tax_point_date,
      l.prior_vat_return_line_id
    FROM public.vat_return_adjustment_journal_source_allocations a
    JOIN public.vat_return_run_lines l
      ON l.id = a.vat_return_run_line_id
    WHERE a.vat_return_adjustment_journal_id = p_journal_id
    ORDER BY a.vat_return_run_line_id
  LOOP
    v_allocation_count := v_allocation_count + 1;
    v_total := v_total + v_allocation.allocated_amount_gbp;

    IF v_allocation.vat_return_run_id <> v_journal.vat_return_run_id THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'ALLOCATION_RETURN_MISMATCH',
        'source_line_id', v_allocation.vat_return_run_line_id
      ));
    END IF;

    IF v_allocation.source_status <> 'active'
       OR v_allocation.adjustment_required IS DISTINCT FROM true THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'ALLOCATION_SOURCE_NOT_ELIGIBLE',
        'source_line_id', v_allocation.vat_return_run_line_id,
        'source_status', v_allocation.source_status,
        'adjustment_required', v_allocation.adjustment_required
      ));
    END IF;

    IF v_allocation.box_number <> v_journal.target_box
       OR v_allocation.direction <> v_journal.direction THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'ALLOCATION_BOX_DIRECTION_MISMATCH',
        'source_line_id', v_allocation.vat_return_run_line_id,
        'source_box', v_allocation.box_number,
        'source_direction', v_allocation.direction,
        'journal_box', v_journal.target_box,
        'journal_direction', v_journal.direction
      ));
    END IF;

    v_basis_amount := CASE
      WHEN v_journal.target_box IN (1,4) THEN abs(v_allocation.vat_amount_gbp)
      WHEN v_journal.target_box IN (6,7) THEN abs(v_allocation.amount_gbp)
      ELSE 0
    END;

    SELECT COALESCE(sum(a2.allocated_amount_gbp), 0)
    INTO v_consumed
    FROM public.vat_return_adjustment_journal_source_allocations a2
    JOIN public.vat_return_adjustment_journals j2
      ON j2.id = a2.vat_return_adjustment_journal_id
    WHERE a2.vat_return_run_line_id = v_allocation.vat_return_run_line_id
      AND a2.vat_return_adjustment_journal_id <> p_journal_id
      AND j2.status IN (
        'admin_approved',
        'posting_to_sage',
        'posted_to_sage',
        'included_in_sage_return',
        'requires_reversal'
      );

    IF round(v_allocation.allocated_amount_gbp + v_consumed, 2) > round(v_basis_amount, 2) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'ALLOCATION_SOURCE_OVERALLOCATED',
        'source_line_id', v_allocation.vat_return_run_line_id,
        'allocated_here', v_allocation.allocated_amount_gbp,
        'consumed_elsewhere', v_consumed,
        'source_capacity', v_basis_amount
      ));
    END IF;
  END LOOP;

  IF v_allocation_count = 0 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'ALLOCATION_SET_EMPTY'
    ));
  END IF;

  IF round(v_total, 2) <> round(v_journal.amount_gbp, 2) THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'ALLOCATION_TOTAL_MISMATCH',
      'allocation_total_gbp', round(v_total, 2),
      'journal_amount_gbp', round(v_journal.amount_gbp, 2)
    ));
  END IF;

  v_current_hash := public.internal_vat_adjustment_allocation_hash_v1(p_journal_id);

  IF NULLIF(trim(COALESCE(v_journal.source_allocation_hash, '')), '') IS NULL
     OR v_journal.source_allocation_hash IS DISTINCT FROM v_current_hash THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object(
      'code', 'ALLOCATION_HASH_MISMATCH',
      'stored_hash', v_journal.source_allocation_hash,
      'current_hash', v_current_hash
    ));
  END IF;

  IF jsonb_array_length(v_errors) > 0 THEN
    RAISE EXCEPTION 'VAT source allocation validation failed: %', v_errors;
  END IF;

  RETURN jsonb_build_object(
    'journal_id', p_journal_id,
    'allocation_count', v_allocation_count,
    'allocation_total_gbp', round(v_total, 2),
    'source_allocation_hash', v_current_hash,
    'valid', true
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.internal_validate_vat_adjustment_source_allocations_v1(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_approve_vat_adjustment_journal_v2(
  p_vat_return_adjustment_journal_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_staff_id uuid;
  v_validation jsonb;
  v_result jsonb;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT journal approval action.';
  END IF;

  -- This locks the journal and every allocated source row and rechecks
  -- capacity immediately before approval. The locks are held until this
  -- entire function call commits or rolls back.
  v_validation := public.internal_validate_vat_adjustment_source_allocations_v1(
    p_vat_return_adjustment_journal_id
  );

  -- Reuse the established v1 approval checks and update. This preserves the
  -- existing line, payload-hash, blocker and VAT-return status semantics.
  v_result := public.staff_approve_vat_adjustment_journal_v1(
    p_vat_return_adjustment_journal_id
  );

  RETURN v_result || jsonb_build_object(
    'source_allocation_version', 'multi_source_v1',
    'source_allocation_validation', v_validation
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.staff_approve_vat_adjustment_journal_v2(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_approve_vat_adjustment_journal_v2(uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
