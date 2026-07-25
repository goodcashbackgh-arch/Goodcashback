BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Final Mini 4 lifecycle alignment for preserved pre-Mini-4 timed links.
-- No accounting, invoice, credit-note, cash or Sage object is changed here.

DO $prerequisites$
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_review_cycle_legacy_issues') IS NULL
     OR to_regclass('public.order_tracking_line_allocations') IS NULL
     OR to_regprocedure(
       'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Mini 4 legacy deadline prerequisites are missing.';
  END IF;
END
$prerequisites$;

CREATE OR REPLACE FUNCTION public.customer_review_cycle_cumulative_qty_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_allocated_qty numeric;
  v_existing_review_qty numeric;
BEGIN
  -- The exclusive allocation-row lock serialises every membership insertion for
  -- the same exact allocation, including direct service-role writes.
  SELECT allocation.qty_allocated
  INTO v_allocated_qty
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id = NEW.tracking_line_allocation_id
  FOR UPDATE;

  SELECT COALESCE(SUM(membership.review_qty), 0)
  INTO v_existing_review_qty
  FROM public.customer_review_cycle_memberships membership
  WHERE membership.tracking_line_allocation_id =
        NEW.tracking_line_allocation_id;

  IF v_allocated_qty IS NULL
     OR v_existing_review_qty + NEW.review_qty > v_allocated_qty
  THEN
    RAISE EXCEPTION
      'Customer review membership would exceed the exact tracking allocation quantity.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_review_cycle_00_cumulative_qty_guard_v1
BEFORE INSERT ON public.customer_review_cycle_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_cycle_cumulative_qty_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_review_resolve_expired_legacy_issue_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.is_active = true
     AND NEW.is_active = false
     AND NEW.expires_at IS NOT NULL
     AND NEW.expires_at <= now()
  THEN
    UPDATE public.customer_review_cycle_legacy_issues issue
    SET resolved_at = COALESCE(issue.resolved_at, now()),
        resolution_note = COALESCE(
          issue.resolution_note,
          'Automatically closed when the preserved timed review link reached its original fixed deadline.'
        )
    WHERE issue.review_link_id = NEW.id
      AND issue.issue_code = 'pre_mini4_timed_membership_unproven'
      AND issue.resolved_at IS NULL;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_review_resolve_expired_legacy_issue_v1
AFTER UPDATE OF is_active
ON public.customer_order_review_links
FOR EACH ROW
EXECUTE FUNCTION public.customer_review_resolve_expired_legacy_issue_v1();

CREATE OR REPLACE FUNCTION public.customer_tracking_review_deadline_v1(
  p_order_id uuid,
  p_tracking_submission_id uuid,
  p_receipt_recorded_at timestamptz
)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(
    (
      SELECT MAX(link_row.expires_at)
      FROM public.customer_review_cycle_memberships membership
      JOIN public.customer_order_review_links link_row
        ON link_row.id = membership.review_link_id
      WHERE membership.order_id = p_order_id
        AND membership.tracking_submission_id = p_tracking_submission_id
        AND link_row.expires_at IS NOT NULL
    ),
    (
      SELECT MAX(link_row.expires_at)
      FROM public.customer_order_review_links link_row
      WHERE link_row.order_id = p_order_id
        AND link_row.expires_at IS NOT NULL
        AND p_receipt_recorded_at < link_row.expires_at
        AND NOT EXISTS (
          SELECT 1
          FROM public.customer_review_cycle_memberships membership
          WHERE membership.review_link_id = link_row.id
        )
    ),
    p_receipt_recorded_at + interval '24 hours'
  );
$$;

REVOKE ALL ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)
  TO authenticated, service_role;

DO $proof$
DECLARE
  v_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_review_cycle_memberships'::regclass
      AND trigger_row.tgname =
        'trg_customer_review_cycle_00_cumulative_qty_guard_v1'
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'Cumulative review-quantity guard was not installed.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_order_review_links'::regclass
      AND trigger_row.tgname =
        'trg_customer_review_resolve_expired_legacy_issue_v1'
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'Legacy review-expiry resolver was not installed.';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_review_cycle_cumulative_qty_guard_v1()'::regprocedure
  ) INTO v_definition;
  IF position('FOR UPDATE' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Cumulative review-quantity guard does not serialise inserts.';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_tracking_review_deadline_v1(uuid,uuid,timestamptz)'::regprocedure
  ) INTO v_definition;
  IF position('p_receipt_recorded_at < link_row.expires_at' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'Legacy deadline fallback can admit a later unrelated receipt.';
  END IF;
END
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
