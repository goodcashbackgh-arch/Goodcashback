BEGIN;

CREATE OR REPLACE FUNCTION public.internal_vat_adjustment_direction_compatible_v1(
  p_source_direction text,
  p_journal_direction text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p_journal_direction = 'increase' THEN p_source_direction IN ('natural','increase')
    WHEN p_journal_direction = 'decrease' THEN p_source_direction = 'decrease'
    ELSE false
  END;
$fn$;

REVOKE ALL ON FUNCTION public.internal_vat_adjustment_direction_compatible_v1(text, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.staff_replace_vat_adjustment_source_allocations_v1(
  p_journal_id uuid,
  p_allocations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_staff_id uuid;
  v_journal public.vat_return_adjustment_journals%rowtype;
  v_item jsonb;
  v_source public.vat_return_run_lines%rowtype;
  v_source_id uuid;
  v_amount numeric(18,2);
  v_basis_amount numeric(18,2);
  v_consumed numeric(18,2);
  v_total numeric(18,2) := 0;
  v_hash text;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT allocation action.';
  END IF;

  SELECT * INTO v_journal
  FROM public.vat_return_adjustment_journals
  WHERE id = p_journal_id
  FOR UPDATE;

  IF v_journal.id IS NULL THEN
    RAISE EXCEPTION 'VAT adjustment journal not found.';
  END IF;

  IF v_journal.status NOT IN ('platform_calculated','dry_run_validated','dry_run_failed') THEN
    RAISE EXCEPTION 'Journal status % is not editable for allocation.', v_journal.status;
  END IF;

  IF jsonb_typeof(p_allocations) <> 'array' OR jsonb_array_length(p_allocations) = 0 THEN
    RAISE EXCEPTION 'At least one allocation is required.';
  END IF;

  PERFORM 1
  FROM public.vat_return_run_lines l
  JOIN (
    SELECT DISTINCT (x ->> 'vat_return_run_line_id')::uuid AS id
    FROM jsonb_array_elements(p_allocations) x
  ) requested ON requested.id = l.id
  ORDER BY l.id
  FOR UPDATE OF l;

  DELETE FROM public.vat_return_adjustment_journal_source_allocations
  WHERE vat_return_adjustment_journal_id = p_journal_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations)
  LOOP
    v_source_id := (v_item ->> 'vat_return_run_line_id')::uuid;
    v_amount := round((v_item ->> 'allocated_amount_gbp')::numeric, 2);

    IF v_amount <= 0 THEN
      RAISE EXCEPTION 'Allocation amount must be positive for source %.', v_source_id;
    END IF;

    SELECT * INTO v_source
    FROM public.vat_return_run_lines
    WHERE id = v_source_id;

    IF v_source.id IS NULL THEN
      RAISE EXCEPTION 'VAT return source line % not found.', v_source_id;
    END IF;

    IF v_source.vat_return_run_id <> v_journal.vat_return_run_id THEN
      RAISE EXCEPTION 'Source % belongs to another VAT return.', v_source_id;
    END IF;

    IF v_source.status <> 'active' OR v_source.adjustment_required IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'Source % is not active and adjustment-eligible.', v_source_id;
    END IF;

    IF v_source.box_number <> v_journal.target_box
       OR NOT public.internal_vat_adjustment_direction_compatible_v1(
         v_source.direction,
         v_journal.direction
       ) THEN
      RAISE EXCEPTION 'Source % is incompatible with journal box/direction.', v_source_id;
    END IF;

    v_basis_amount := CASE
      WHEN v_journal.target_box IN (1,4) THEN abs(v_source.vat_amount_gbp)
      WHEN v_journal.target_box IN (6,7) THEN abs(v_source.amount_gbp)
      ELSE 0
    END;

    SELECT COALESCE(sum(a.allocated_amount_gbp), 0)
    INTO v_consumed
    FROM public.vat_return_adjustment_journal_source_allocations a
    JOIN public.vat_return_adjustment_journals j
      ON j.id = a.vat_return_adjustment_journal_id
    WHERE a.vat_return_run_line_id = v_source_id
      AND a.vat_return_adjustment_journal_id <> p_journal_id
      AND j.status IN (
        'admin_approved',
        'posting_to_sage',
        'posted_to_sage',
        'included_in_sage_return',
        'requires_reversal'
      );

    IF v_amount > round(v_basis_amount - v_consumed, 2) THEN
      RAISE EXCEPTION 'Allocation exceeds available amount for source %. Requested %, available %.',
        v_source_id, v_amount, round(v_basis_amount - v_consumed, 2);
    END IF;

    INSERT INTO public.vat_return_adjustment_journal_source_allocations (
      vat_return_adjustment_journal_id,
      vat_return_run_line_id,
      allocated_amount_gbp,
      source_snapshot_json
    ) VALUES (
      p_journal_id,
      v_source_id,
      v_amount,
      jsonb_build_object(
        'vat_return_run_id', v_source.vat_return_run_id,
        'line_kind', v_source.line_kind,
        'source_table', v_source.source_table,
        'source_id', v_source.source_id,
        'source_ref', v_source.source_ref,
        'box_number', v_source.box_number,
        'direction', v_source.direction,
        'amount_gbp', v_source.amount_gbp,
        'vat_amount_gbp', v_source.vat_amount_gbp,
        'vat_basis', v_source.vat_basis,
        'tax_point_date', v_source.tax_point_date,
        'prior_vat_return_line_id', v_source.prior_vat_return_line_id,
        'status', v_source.status,
        'adjustment_required', v_source.adjustment_required,
        'adjustment_reason', v_source.adjustment_reason
      )
    );

    v_total := v_total + v_amount;
  END LOOP;

  IF round(v_total, 2) <> round(v_journal.amount_gbp, 2) THEN
    RAISE EXCEPTION 'Allocation total % does not equal journal amount %.', v_total, v_journal.amount_gbp;
  END IF;

  v_hash := public.internal_vat_adjustment_allocation_hash_v1(p_journal_id);

  UPDATE public.vat_return_adjustment_journals
  SET source_allocation_version = 'multi_source_v1',
      source_allocation_hash = v_hash,
      updated_at = now()
  WHERE id = p_journal_id;

  RETURN jsonb_build_object(
    'journal_id', p_journal_id,
    'source_allocation_version', 'multi_source_v1',
    'source_allocation_hash', v_hash,
    'allocation_count', jsonb_array_length(p_allocations),
    'allocation_total_gbp', round(v_total, 2)
  );
END;
$fn$;

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

  PERFORM 1
  FROM public.vat_return_run_lines l
  JOIN public.vat_return_adjustment_journal_source_allocations a
    ON a.vat_return_run_line_id = l.id
  WHERE a.vat_return_adjustment_journal_id = p_journal_id
  ORDER BY l.id
  FOR UPDATE OF l;

  FOR v_allocation IN
    SELECT a.vat_return_run_line_id,
           a.allocated_amount_gbp,
           l.vat_return_run_id,
           l.box_number,
           l.direction,
           l.amount_gbp,
           l.vat_amount_gbp,
           l.status AS source_status,
           l.adjustment_required
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
        'source_line_id', v_allocation.vat_return_run_line_id
      ));
    END IF;

    IF v_allocation.box_number <> v_journal.target_box
       OR NOT public.internal_vat_adjustment_direction_compatible_v1(
         v_allocation.direction,
         v_journal.direction
       ) THEN
      v_errors := v_errors || jsonb_build_array(jsonb_build_object(
        'code', 'ALLOCATION_BOX_DIRECTION_MISMATCH',
        'source_line_id', v_allocation.vat_return_run_line_id
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
        'source_line_id', v_allocation.vat_return_run_line_id
      ));
    END IF;
  END LOOP;

  IF v_allocation_count = 0 THEN
    v_errors := v_errors || jsonb_build_array(jsonb_build_object('code', 'ALLOCATION_SET_EMPTY'));
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
      'code', 'ALLOCATION_HASH_MISMATCH'
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

NOTIFY pgrst, 'reload schema';

COMMIT;
