BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_importer_available_account_credit_lots_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.internal_importer_available_account_credit_lots_v1(uuid)';
  END IF;
  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;
  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;
END $$;

/*
 * Read-path repair only.
 *
 * Preserve the existing source-lot credit engine, bucket priorities,
 * sequential consumption, linked-debit handling, legacy debit compatibility,
 * loyalty separation and all write paths.
 *
 * The customer dashboard must resolve the same active importer assignment used
 * by the existing account-credit application function, then sum the canonical
 * available account-credit lots for that importer.
 */
CREATE OR REPLACE FUNCTION public.customer_importer_credit_balance_v1()
RETURNS TABLE (
  importer_id uuid,
  available_credit_gbp numeric
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH current_importer AS (
    SELECT oi.importer_id
    FROM public.operators op
    JOIN public.operator_importers oi
      ON oi.operator_id = op.id
     AND oi.revoked_at IS NULL
    WHERE op.auth_user_id = auth.uid()
      AND COALESCE(op.active, true) = true
    ORDER BY oi.granted_at DESC NULLS LAST, oi.id DESC
    LIMIT 1
  )
  SELECT
    ci.importer_id,
    ROUND(COALESCE(SUM(lot.available_amount_gbp), 0)::numeric, 2)
      AS available_credit_gbp
  FROM current_importer ci
  LEFT JOIN LATERAL
    public.internal_importer_available_account_credit_lots_v1(ci.importer_id) lot
    ON true
  GROUP BY ci.importer_id;
$$;

REVOKE ALL ON FUNCTION public.customer_importer_credit_balance_v1() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.customer_importer_credit_balance_v1() TO authenticated;

COMMENT ON FUNCTION public.customer_importer_credit_balance_v1() IS
  'Customer account-credit balance read using the canonical source-lot engine. Completion loyalty remains exposed separately by its dedicated balance RPC.';

NOTIFY pgrst, 'reload schema';

COMMIT;
