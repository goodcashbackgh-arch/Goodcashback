BEGIN;

-- VAT Return Workbench foundation v1
-- Additive schema only. No VAT calculation engine. No Sage API call. No posting.
-- Controlling contract: docs/governing-pack/ui/VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.internal_has_vat_return_admin_access_v1()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND s.active = true
      AND s.role_type = 'admin'
  )
$$;

REVOKE ALL ON FUNCTION public.internal_has_vat_return_admin_access_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_has_vat_return_admin_access_v1() TO authenticated;

CREATE TABLE IF NOT EXISTS public.vat_return_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_ref text NOT NULL UNIQUE DEFAULT ('VAT-' || extract(epoch from clock_timestamp())::bigint::text),
  return_period_label text NOT NULL,
  period_start_date date NOT NULL,
  period_end_date date NOT NULL,
  status text NOT NULL DEFAULT 'draft',
  contract_version text NOT NULL DEFAULT 'VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1',
  generated_by_staff_id uuid NULL REFERENCES public.staff(id),
  generated_by_auth_user_id uuid NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  admin_reviewed_by_staff_id uuid NULL REFERENCES public.staff(id),
  admin_reviewed_at timestamptz NULL,
  admin_approved_by_staff_id uuid NULL REFERENCES public.staff(id),
  admin_approved_at timestamptz NULL,
  expected_box1_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box2_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box3_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box4_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box5_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box6_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box7_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box8_gbp numeric(18,2) NOT NULL DEFAULT 0,
  expected_box9_gbp numeric(18,2) NOT NULL DEFAULT 0,
  source_counts_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  blockers_summary_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text NULL,
  locked_by_staff_id uuid NULL REFERENCES public.staff(id),
  locked_at timestamptz NULL,
  reopened_from_run_id uuid NULL REFERENCES public.vat_return_runs(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_runs_date_chk CHECK (period_end_date >= period_start_date),
  CONSTRAINT vat_return_runs_status_chk CHECK (status IN (
    'draft',
    'calculated',
    'admin_review_required',
    'blocked',
    'admin_approved',
    'sage_adjustment_journals_pending',
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review',
    'reopened_for_correction'
  ))
);

CREATE TABLE IF NOT EXISTS public.vat_return_run_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_run_id uuid NOT NULL REFERENCES public.vat_return_runs(id) ON DELETE CASCADE,
  line_kind text NOT NULL,
  source_table text NOT NULL,
  source_id uuid NULL,
  source_ref text NULL,
  source_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_lineage_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  box_number integer NULL,
  direction text NOT NULL DEFAULT 'no_box',
  amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  vat_amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  vat_basis text NULL,
  tax_point_date date NULL,
  return_period_label text NULL,
  natural_sage_covered boolean NOT NULL DEFAULT false,
  adjustment_required boolean NOT NULL DEFAULT false,
  adjustment_reason text NULL,
  prior_vat_return_line_id uuid NULL REFERENCES public.vat_return_run_lines(id),
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_run_lines_box_chk CHECK (box_number IS NULL OR box_number IN (1,4,6,7)),
  CONSTRAINT vat_return_run_lines_direction_chk CHECK (direction IN ('increase','decrease','natural','no_box')),
  CONSTRAINT vat_return_run_lines_status_chk CHECK (status IN ('active','superseded','corrected','ignored'))
);

CREATE TABLE IF NOT EXISTS public.vat_return_adjustment_journals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_run_id uuid NOT NULL REFERENCES public.vat_return_runs(id) ON DELETE CASCADE,
  vat_return_run_line_id uuid NULL REFERENCES public.vat_return_run_lines(id),
  adjustment_type text NOT NULL,
  target_box integer NOT NULL,
  direction text NOT NULL,
  amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'platform_calculated',
  idempotency_key text NULL UNIQUE,
  endpoint_path text NOT NULL DEFAULT '/journals',
  method text NOT NULL DEFAULT 'POST',
  sage_business_id text NULL,
  payload_hash text NULL,
  request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  response_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_error text NULL,
  retry_count integer NOT NULL DEFAULT 0,
  sage_journal_id text NULL,
  sage_journal_ref text NULL,
  posted_at timestamptz NULL,
  approved_by_staff_id uuid NULL REFERENCES public.staff(id),
  approved_by_auth_user_id uuid NULL,
  approved_at timestamptz NULL,
  reversed_by_journal_id uuid NULL REFERENCES public.vat_return_adjustment_journals(id),
  reverses_journal_id uuid NULL REFERENCES public.vat_return_adjustment_journals(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_adjustment_journals_box_chk CHECK (target_box IN (1,4,6,7)),
  CONSTRAINT vat_return_adjustment_journals_direction_chk CHECK (direction IN ('increase','decrease')),
  CONSTRAINT vat_return_adjustment_journals_amount_chk CHECK (amount_gbp >= 0),
  CONSTRAINT vat_return_adjustment_journals_method_chk CHECK (method = 'POST'),
  CONSTRAINT vat_return_adjustment_journals_endpoint_chk CHECK (endpoint_path = '/journals'),
  CONSTRAINT vat_return_adjustment_journals_status_chk CHECK (status IN (
    'platform_calculated',
    'dry_run_validated',
    'dry_run_failed',
    'admin_approved',
    'posting_to_sage',
    'posted_to_sage',
    'failed_retryable',
    'failed_terminal',
    'included_in_sage_return',
    'requires_reversal',
    'reversed'
  ))
);

CREATE TABLE IF NOT EXISTS public.vat_return_adjustment_journal_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_adjustment_journal_id uuid NOT NULL REFERENCES public.vat_return_adjustment_journals(id) ON DELETE CASCADE,
  line_no integer NOT NULL,
  line_role text NOT NULL,
  account_role text NOT NULL,
  sage_ledger_account_id text NULL,
  sage_ledger_account_display text NULL,
  debit_amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  credit_amount_gbp numeric(18,2) NOT NULL DEFAULT 0,
  include_on_tax_return boolean NOT NULL DEFAULT false,
  target_box integer NULL,
  line_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_adjustment_journal_lines_unique_no UNIQUE (vat_return_adjustment_journal_id, line_no),
  CONSTRAINT vat_return_adjustment_journal_lines_role_chk CHECK (line_role IN ('vat_box_line','balancing_line')),
  CONSTRAINT vat_return_adjustment_journal_lines_amount_chk CHECK (
    debit_amount_gbp >= 0
    AND credit_amount_gbp >= 0
    AND NOT (debit_amount_gbp > 0 AND credit_amount_gbp > 0)
  ),
  CONSTRAINT vat_return_adjustment_journal_lines_box_chk CHECK (target_box IS NULL OR target_box IN (1,4,6,7)),
  CONSTRAINT vat_return_adjustment_journal_lines_tax_return_chk CHECK (
    (line_role = 'vat_box_line' AND include_on_tax_return = true)
    OR (line_role = 'balancing_line' AND include_on_tax_return = false)
  )
);

CREATE TABLE IF NOT EXISTS public.vat_return_sage_match_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_run_id uuid NOT NULL REFERENCES public.vat_return_runs(id) ON DELETE CASCADE,
  sage_submitted_box1_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box2_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box3_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box4_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box5_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box6_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box7_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box8_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_submitted_box9_gbp numeric(18,2) NOT NULL DEFAULT 0,
  sage_return_reference text NULL,
  sage_submission_timestamp timestamptz NULL,
  evidence_url text NULL,
  evidence_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  match_status text NOT NULL DEFAULT 'pending_review',
  tolerance_gbp numeric(18,2) NOT NULL DEFAULT 0.01,
  matched_by_staff_id uuid NULL REFERENCES public.staff(id),
  matched_at timestamptz NULL,
  locked_by_staff_id uuid NULL REFERENCES public.staff(id),
  locked_at timestamptz NULL,
  notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_sage_match_evidence_status_chk CHECK (match_status IN (
    'pending_review',
    'matched',
    'mismatch_needs_admin_review',
    'locked'
  )),
  CONSTRAINT vat_return_sage_match_evidence_tolerance_chk CHECK (tolerance_gbp >= 0)
);

CREATE TABLE IF NOT EXISTS public.vat_return_blockers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_run_id uuid NULL REFERENCES public.vat_return_runs(id) ON DELETE CASCADE,
  blocker_code text NOT NULL,
  severity text NOT NULL DEFAULT 'blocker',
  owner_role text NOT NULL DEFAULT 'admin',
  source_table text NULL,
  source_id uuid NULL,
  source_ref text NULL,
  message text NOT NULL,
  required_action text NULL,
  status text NOT NULL DEFAULT 'open',
  resolved_by_staff_id uuid NULL REFERENCES public.staff(id),
  resolved_at timestamptz NULL,
  resolution_notes text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vat_return_blockers_severity_chk CHECK (severity IN ('info','warning','blocker')),
  CONSTRAINT vat_return_blockers_owner_role_chk CHECK (owner_role IN ('admin','supervisor','operator','shipper','system')),
  CONSTRAINT vat_return_blockers_status_chk CHECK (status IN ('open','resolved','waived'))
);

CREATE INDEX IF NOT EXISTS vat_return_runs_period_idx
  ON public.vat_return_runs(period_start_date, period_end_date, status);

CREATE INDEX IF NOT EXISTS vat_return_runs_status_idx
  ON public.vat_return_runs(status, generated_at DESC);

CREATE INDEX IF NOT EXISTS vat_return_run_lines_run_idx
  ON public.vat_return_run_lines(vat_return_run_id, box_number, adjustment_required);

CREATE INDEX IF NOT EXISTS vat_return_run_lines_source_idx
  ON public.vat_return_run_lines(source_table, source_id);

CREATE INDEX IF NOT EXISTS vat_return_adjustment_journals_run_idx
  ON public.vat_return_adjustment_journals(vat_return_run_id, status, target_box);

CREATE INDEX IF NOT EXISTS vat_return_adjustment_journals_source_line_idx
  ON public.vat_return_adjustment_journals(vat_return_run_line_id);

CREATE INDEX IF NOT EXISTS vat_return_adjustment_journal_lines_journal_idx
  ON public.vat_return_adjustment_journal_lines(vat_return_adjustment_journal_id, line_no);

CREATE INDEX IF NOT EXISTS vat_return_sage_match_evidence_run_idx
  ON public.vat_return_sage_match_evidence(vat_return_run_id, match_status);

CREATE INDEX IF NOT EXISTS vat_return_blockers_run_idx
  ON public.vat_return_blockers(vat_return_run_id, status, severity);

CREATE INDEX IF NOT EXISTS vat_return_blockers_source_idx
  ON public.vat_return_blockers(source_table, source_id);

ALTER TABLE public.vat_return_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vat_return_run_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vat_return_adjustment_journals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vat_return_adjustment_journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vat_return_sage_match_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vat_return_blockers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vat_return_runs_admin_select ON public.vat_return_runs;
CREATE POLICY vat_return_runs_admin_select
ON public.vat_return_runs
FOR SELECT
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_runs_admin_insert ON public.vat_return_runs;
CREATE POLICY vat_return_runs_admin_insert
ON public.vat_return_runs
FOR INSERT
TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_runs_admin_update ON public.vat_return_runs;
CREATE POLICY vat_return_runs_admin_update
ON public.vat_return_runs
FOR UPDATE
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1())
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_run_lines_admin_select ON public.vat_return_run_lines;
CREATE POLICY vat_return_run_lines_admin_select
ON public.vat_return_run_lines
FOR SELECT
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_run_lines_admin_insert ON public.vat_return_run_lines;
CREATE POLICY vat_return_run_lines_admin_insert
ON public.vat_return_run_lines
FOR INSERT
TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_run_lines_admin_update ON public.vat_return_run_lines;
CREATE POLICY vat_return_run_lines_admin_update
ON public.vat_return_run_lines
FOR UPDATE
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1())
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_adjustment_journals_admin_select ON public.vat_return_adjustment_journals;
CREATE POLICY vat_return_adjustment_journals_admin_select
ON public.vat_return_adjustment_journals
FOR SELECT
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_adjustment_journals_admin_insert ON public.vat_return_adjustment_journals;
CREATE POLICY vat_return_adjustment_journals_admin_insert
ON public.vat_return_adjustment_journals
FOR INSERT
TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_adjustment_journals_admin_update ON public.vat_return_adjustment_journals;
CREATE POLICY vat_return_adjustment_journals_admin_update
ON public.vat_return_adjustment_journals
FOR UPDATE
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1())
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_adjustment_journal_lines_admin_select ON public.vat_return_adjustment_journal_lines;
CREATE POLICY vat_return_adjustment_journal_lines_admin_select
ON public.vat_return_adjustment_journal_lines
FOR SELECT
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_adjustment_journal_lines_admin_insert ON public.vat_return_adjustment_journal_lines;
CREATE POLICY vat_return_adjustment_journal_lines_admin_insert
ON public.vat_return_adjustment_journal_lines
FOR INSERT
TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_adjustment_journal_lines_admin_update ON public.vat_return_adjustment_journal_lines;
CREATE POLICY vat_return_adjustment_journal_lines_admin_update
ON public.vat_return_adjustment_journal_lines
FOR UPDATE
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1())
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_sage_match_evidence_admin_select ON public.vat_return_sage_match_evidence;
CREATE POLICY vat_return_sage_match_evidence_admin_select
ON public.vat_return_sage_match_evidence
FOR SELECT
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_sage_match_evidence_admin_insert ON public.vat_return_sage_match_evidence;
CREATE POLICY vat_return_sage_match_evidence_admin_insert
ON public.vat_return_sage_match_evidence
FOR INSERT
TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_sage_match_evidence_admin_update ON public.vat_return_sage_match_evidence;
CREATE POLICY vat_return_sage_match_evidence_admin_update
ON public.vat_return_sage_match_evidence
FOR UPDATE
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1())
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_blockers_admin_select ON public.vat_return_blockers;
CREATE POLICY vat_return_blockers_admin_select
ON public.vat_return_blockers
FOR SELECT
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_blockers_admin_insert ON public.vat_return_blockers;
CREATE POLICY vat_return_blockers_admin_insert
ON public.vat_return_blockers
FOR INSERT
TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_blockers_admin_update ON public.vat_return_blockers;
CREATE POLICY vat_return_blockers_admin_update
ON public.vat_return_blockers
FOR UPDATE
TO authenticated
USING (public.internal_has_vat_return_admin_access_v1())
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

REVOKE ALL ON public.vat_return_runs FROM PUBLIC, anon;
REVOKE ALL ON public.vat_return_run_lines FROM PUBLIC, anon;
REVOKE ALL ON public.vat_return_adjustment_journals FROM PUBLIC, anon;
REVOKE ALL ON public.vat_return_adjustment_journal_lines FROM PUBLIC, anon;
REVOKE ALL ON public.vat_return_sage_match_evidence FROM PUBLIC, anon;
REVOKE ALL ON public.vat_return_blockers FROM PUBLIC, anon;

GRANT SELECT, INSERT, UPDATE ON public.vat_return_runs TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.vat_return_run_lines TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.vat_return_adjustment_journals TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.vat_return_adjustment_journal_lines TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.vat_return_sage_match_evidence TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.vat_return_blockers TO authenticated;

COMMENT ON FUNCTION public.internal_has_vat_return_admin_access_v1() IS 'Strict admin-only helper for live VAT Return Workbench controls. No supervisor/test override.';
COMMENT ON TABLE public.vat_return_runs IS 'Immutable VAT return run header/control record. No Sage submission; Sage remains MTD submission system.';
COMMENT ON TABLE public.vat_return_run_lines IS 'Source-linked VAT return line snapshot for Box 1/4/6/7 and adjustment analysis.';
COMMENT ON TABLE public.vat_return_adjustment_journals IS 'Sage /journals adjustment header queue. No posting performed by this migration.';
COMMENT ON TABLE public.vat_return_adjustment_journal_lines IS 'Balanced journal line template. VAT-box line included on return, balancing line excluded.';
COMMENT ON TABLE public.vat_return_sage_match_evidence IS 'Admin-recorded Sage/HMRC submitted return values and match/lock evidence.';
COMMENT ON TABLE public.vat_return_blockers IS 'Admin-only VAT return blockers and resolution tracking.';

NOTIFY pgrst, 'reload schema';

COMMIT;
