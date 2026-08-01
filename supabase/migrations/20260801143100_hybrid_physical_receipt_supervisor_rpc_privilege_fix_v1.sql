BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regprocedure(
    'public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION
      'Supervisor physical receipt decision RPC is missing; apply the ordered RPC migration first.';
  END IF;
END
$preflight$;

REVOKE ALL
ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
FROM PUBLIC, anon;

GRANT EXECUTE
ON FUNCTION public.staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)
TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
