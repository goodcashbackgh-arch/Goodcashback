BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE public.vat_return_adjustment_journals
  ADD COLUMN IF NOT EXISTS source_allocation_version text NULL,
  ADD COLUMN IF NOT EXISTS source_allocation_hash text NULL;

ALTER TABLE public.vat_return_adjustment_journals
  DROP CONSTRAINT IF EXISTS vat_return_adjustment_journals_source_allocation_version_chk;

ALTER TABLE public.vat_return_adjustment_journals
  ADD CONSTRAINT vat_return_adjustment_journals_source_allocation_version_chk
  CHECK (source_allocation_version IS NULL OR source_allocation_version = 'multi_source_v1');

CREATE TABLE IF NOT EXISTS public.vat_return_adjustment_journal_source_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_adjustment_journal_id uuid NOT NULL
    REFERENCES public.vat_return_adjustment_journals(id) ON DELETE CASCADE,
  vat_return_run_line_id uuid NOT NULL
    REFERENCES public.vat_return_run_lines(id),
  allocated_amount_gbp numeric(18,2) NOT NULL,
  source_snapshot_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_adjustment_journal_source_allocations_amount_chk
    CHECK (allocated_amount_gbp > 0),
  CONSTRAINT vat_return_adjustment_journal_source_allocations_unique_source
    UNIQUE (vat_return_adjustment_journal_id, vat_return_run_line_id)
);

CREATE INDEX IF NOT EXISTS vat_return_adjustment_journal_source_allocations_journal_idx
  ON public.vat_return_adjustment_journal_source_allocations(vat_return_adjustment_journal_id);

CREATE INDEX IF NOT EXISTS vat_return_adjustment_journal_source_allocations_source_idx
  ON public.vat_return_adjustment_journal_source_allocations(vat_return_run_line_id);

ALTER TABLE public.vat_return_adjustment_journal_source_allocations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vat_return_adjustment_journal_source_allocations_admin_select
  ON public.vat_return_adjustment_journal_source_allocations;
CREATE POLICY vat_return_adjustment_journal_source_allocations_admin_select
ON public.vat_return_adjustment_journal_source_allocations
FOR SELECT TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

REVOKE ALL ON public.vat_return_adjustment_journal_source_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vat_return_adjustment_journal_source_allocations TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_vat_adjustment_allocation_hash_v1(
  p_journal_id uuid
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
  SELECT encode(
    extensions.digest(
      COALESCE(
        string_agg(
          concat_ws('|',
            a.vat_return_run_line_id::text,
            to_char(a.allocated_amount_gbp, 'FM999999999999990.00'),
            encode(extensions.digest(a.source_snapshot_json::text, 'sha256'), 'hex'),
            'multi_source_v1'
          ),
          E'\n' ORDER BY a.vat_return_run_line_id
        ),
        ''
      ),
      'sha256'
    ),
    'hex'
  )
  FROM public.vat_return_adjustment_journal_source_allocations a
  WHERE a.vat_return_adjustment_journal_id = p_journal_id;
$fn$;

REVOKE ALL ON FUNCTION public.internal_vat_adjustment_allocation_hash_v1(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.internal_guard_vat_adjustment_allocation_mutation_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_journal public.vat_return_adjustment_journals%rowtype;
  v_journal_id uuid;
BEGIN
  v_journal_id := COALESCE(NEW.vat_return_adjustment_journal_id, OLD.vat_return_adjustment_journal_id);

  SELECT * INTO v_journal
  FROM public.vat_return_adjustment_journals
  WHERE id = v_journal_id;

  IF v_journal.id IS NULL THEN
    RAISE EXCEPTION 'VAT adjustment journal not found.';
  END IF;

  IF v_journal.status NOT IN ('platform_calculated','dry_run_validated','dry_run_failed') THEN
    RAISE EXCEPTION 'Source allocations are immutable for journal status %.', v_journal.status;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$fn$;

DROP TRIGGER IF EXISTS guard_vat_adjustment_allocation_mutation_v1
  ON public.vat_return_adjustment_journal_source_allocations;
CREATE TRIGGER guard_vat_adjustment_allocation_mutation_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.vat_return_adjustment_journal_source_allocations
FOR EACH ROW
EXECUTE FUNCTION public.internal_guard_vat_adjustment_allocation_mutation_v1();

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

    IF v_source.box_number <> v_journal.target_box OR v_source.direction <> v_journal.direction THEN
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

REVOKE ALL ON FUNCTION public.staff_replace_vat_adjustment_source_allocations_v1(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_replace_vat_adjustment_source_allocations_v1(uuid, jsonb) TO authenticated;

COMMENT ON TABLE public.vat_return_adjustment_journal_source_allocations IS
  'Internal many-to-one source provenance for versioned VAT adjustment journals. Does not alter Sage journal lines or payload.';

NOTIFY pgrst, 'reload schema';

COMMIT;
