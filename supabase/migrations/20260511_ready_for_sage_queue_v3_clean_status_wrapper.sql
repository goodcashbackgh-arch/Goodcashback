BEGIN;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
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
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: ready for Sage queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for ready for Sage queue.';
  END IF;

  RETURN QUERY
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
    CASE
      WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'internally_marked_posted_no_sage_confirmation'
      WHEN q.sage_status = 'posted'
        THEN 'sage_confirmation_recorded'
      ELSE q.readiness_status
    END AS readiness_status,
    CASE
      WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'legacy_internal_posted_status_without_sage_confirmation'
      ELSE q.blocker
    END AS blocker,
    q.reference_text,
    q.notes_text,
    q.detail_href,
    q.source_payload
  FROM public.internal_ready_for_sage_queue_v1() q;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
