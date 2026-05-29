BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Read-only Sage VAT draft reconstruction snapshots.
-- This table stores calculated boxes from Sage GET endpoints only.
-- It does not create any Sage/HMRC posting, submission, payment, or journal route.

CREATE TABLE IF NOT EXISTS public.vat_return_sage_reconstruction_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vat_return_run_id uuid NOT NULL REFERENCES public.vat_return_runs(id) ON DELETE CASCADE,
  period_start_date date NOT NULL,
  period_end_date date NOT NULL,
  status text NOT NULL DEFAULT 'reconstructed' CHECK (status IN ('reconstructed','error')),
  source_basis text NOT NULL DEFAULT 'sage_posted_documents',
  box1_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box2_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box3_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box4_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box5_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box6_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box7_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box8_gbp numeric(14,2) NOT NULL DEFAULT 0,
  box9_gbp numeric(14,2) NOT NULL DEFAULT 0,
  sales_invoice_count integer NOT NULL DEFAULT 0,
  sales_credit_note_count integer NOT NULL DEFAULT 0,
  purchase_invoice_count integer NOT NULL DEFAULT 0,
  purchase_credit_note_count integer NOT NULL DEFAULT 0,
  source_counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  warning_notes text,
  created_by_staff_id uuid REFERENCES public.staff(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.vat_return_sage_reconstruction_snapshots ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vat_return_sage_reconstruction_snapshots_admin_select ON public.vat_return_sage_reconstruction_snapshots;
CREATE POLICY vat_return_sage_reconstruction_snapshots_admin_select
ON public.vat_return_sage_reconstruction_snapshots
FOR SELECT TO authenticated
USING (public.internal_has_vat_return_admin_access_v1());

DROP POLICY IF EXISTS vat_return_sage_reconstruction_snapshots_admin_insert ON public.vat_return_sage_reconstruction_snapshots;
CREATE POLICY vat_return_sage_reconstruction_snapshots_admin_insert
ON public.vat_return_sage_reconstruction_snapshots
FOR INSERT TO authenticated
WITH CHECK (public.internal_has_vat_return_admin_access_v1());

CREATE OR REPLACE FUNCTION public.internal_latest_sage_vat_reconstruction_v1()
RETURNS TABLE (
  id uuid,
  vat_return_run_id uuid,
  period_start_date date,
  period_end_date date,
  status text,
  source_basis text,
  box1_gbp numeric,
  box2_gbp numeric,
  box3_gbp numeric,
  box4_gbp numeric,
  box5_gbp numeric,
  box6_gbp numeric,
  box7_gbp numeric,
  box8_gbp numeric,
  box9_gbp numeric,
  sales_invoice_count integer,
  sales_credit_note_count integer,
  purchase_invoice_count integer,
  purchase_credit_note_count integer,
  warning_notes text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage VAT reconstruction requires auth.uid()';
  END IF;

  IF NOT public.internal_has_vat_return_admin_access_v1() THEN
    RAISE EXCEPTION 'Admin-only VAT Return Workbench access required.';
  END IF;

  RETURN QUERY
  SELECT
    s.id::uuid,
    s.vat_return_run_id::uuid,
    s.period_start_date::date,
    s.period_end_date::date,
    s.status::text,
    s.source_basis::text,
    s.box1_gbp::numeric,
    s.box2_gbp::numeric,
    s.box3_gbp::numeric,
    s.box4_gbp::numeric,
    s.box5_gbp::numeric,
    s.box6_gbp::numeric,
    s.box7_gbp::numeric,
    s.box8_gbp::numeric,
    s.box9_gbp::numeric,
    s.sales_invoice_count::integer,
    s.sales_credit_note_count::integer,
    s.purchase_invoice_count::integer,
    s.purchase_credit_note_count::integer,
    s.warning_notes::text,
    s.created_at::timestamptz
  FROM public.vat_return_sage_reconstruction_snapshots s
  ORDER BY s.created_at DESC
  LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_latest_sage_vat_reconstruction_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_latest_sage_vat_reconstruction_v1() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
