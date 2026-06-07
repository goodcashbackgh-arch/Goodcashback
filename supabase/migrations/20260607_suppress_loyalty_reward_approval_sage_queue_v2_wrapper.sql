BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2_legacy_with_loyalty_lane()') IS NULL THEN
    IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
      RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v2()';
    END IF;

    ALTER FUNCTION public.internal_ready_for_sage_queue_v2()
      RENAME TO internal_ready_for_sage_queue_v2_legacy_with_loyalty_lane;
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.internal_ready_for_sage_queue_v2();

CREATE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
  SELECT
    q.queue_row_id,
    q.document_lane,
    q.document_type,
    q.source_table,
    q.source_id,
    q.order_id,
    q.order_ref,
    q.shipment_batch_id,
    q.booking_ref,
    q.counterparty_name,
    q.amount_gbp,
    q.currency_code,
    q.invoice_type,
    q.sage_status,
    q.sage_invoice_id,
    q.sage_posted_at,
    q.readiness_status,
    q.blocker,
    q.reference_text,
    q.notes_text,
    q.detail_href,
    q.source_payload
  FROM public.internal_ready_for_sage_queue_v2_legacy_with_loyalty_lane() q
  WHERE q.document_type IS DISTINCT FROM 'completion_loyalty_reward_journal'
    AND NOT (
      q.document_lane = 'customer_credit'
      AND q.source_table = 'importer_credit_ledger'
      AND COALESCE(q.source_payload ->> 'document_type', '') = 'completion_loyalty_reward_journal'
    );
$func$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
