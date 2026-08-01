BEGIN;

CREATE OR REPLACE FUNCTION public.internal_guard_vat_adjustment_multi_source_approval_transition_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF NEW.source_allocation_version = 'multi_source_v1'
     AND NEW.status = 'admin_approved'
     AND OLD.status IS DISTINCT FROM 'admin_approved' THEN
    PERFORM public.internal_validate_vat_adjustment_source_allocations_v1(NEW.id);
  END IF;

  IF OLD.source_allocation_version = 'multi_source_v1'
     AND OLD.status IN (
       'admin_approved',
       'posting_to_sage',
       'posted_to_sage',
       'included_in_sage_return',
       'requires_reversal',
       'reversed'
     )
     AND (
       NEW.source_allocation_version IS DISTINCT FROM OLD.source_allocation_version
       OR NEW.source_allocation_hash IS DISTINCT FROM OLD.source_allocation_hash
     ) THEN
    RAISE EXCEPTION 'Allocation version and hash are immutable after approval.';
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS guard_vat_adjustment_multi_source_approval_transition_v1
  ON public.vat_return_adjustment_journals;
CREATE TRIGGER guard_vat_adjustment_multi_source_approval_transition_v1
BEFORE UPDATE OF status, source_allocation_version, source_allocation_hash
ON public.vat_return_adjustment_journals
FOR EACH ROW
EXECUTE FUNCTION public.internal_guard_vat_adjustment_multi_source_approval_transition_v1();

COMMENT ON FUNCTION public.internal_guard_vat_adjustment_multi_source_approval_transition_v1() IS
  'Database enforcement boundary: any multi_source_v1 journal must pass allocation validation on transition to admin_approved, including calls through legacy approval routes.';

COMMIT;
