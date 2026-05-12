BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_ready_for_sage_queue_v2_raw_20260512()') IS NULL THEN
    IF to_regprocedure('public.internal_ready_for_sage_queue_v2()') IS NULL THEN
      RAISE EXCEPTION 'Prerequisite missing: public.internal_ready_for_sage_queue_v2()';
    END IF;

    ALTER FUNCTION public.internal_ready_for_sage_queue_v2()
      RENAME TO internal_ready_for_sage_queue_v2_raw_20260512;
  END IF;
END $$;

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
    q.readiness_status,
    q.blocker,
    q.reference_text,
    CASE
      WHEN COALESCE(q.source_payload->>'customer_hold_blocker', 'false') = 'true'
        OR q.document_type = 'customer_pre_shipment_hold'
        OR q.blocker = 'customer_pre_shipment_hold_unresolved'
      THEN concat_ws(' ',
        CASE
          WHEN counts.requested_count > 0 THEN
            counts.approved_count::text || ' approved and ' || counts.requested_count::text || ' requested customer hold(s) remain unresolved.'
          ELSE
            COALESCE(NULLIF(counts.approved_count, 0), counts.active_count)::text || ' approved customer hold(s) remain unresolved.'
        END,
        NULLIF(concat_ws(', ',
          CASE WHEN counts.line_count > 0 THEN counts.line_count::text || ' line-level hold(s)' END,
          CASE WHEN counts.tracking_count > 0 THEN counts.tracking_count::text || ' tracking hold(s)' END,
          CASE WHEN counts.order_count > 0 THEN counts.order_count::text || ' order hold(s)' END
        ), '')::text,
        CASE WHEN NULLIF(reasons.reason_text, '') IS NOT NULL THEN 'Reason: ' || reasons.reason_text || '.' END
      )
      ELSE q.notes_text
    END AS notes_text,
    q.detail_href,
    q.source_payload
  FROM public.internal_ready_for_sage_queue_v2_raw_20260512() q
  LEFT JOIN LATERAL (
    SELECT
      COALESCE(NULLIF(q.source_payload->>'active_hold_count','')::int, 0) AS active_count,
      COALESCE(NULLIF(q.source_payload->>'approved_hold_count','')::int, 0) AS approved_count,
      COALESCE(NULLIF(q.source_payload->>'requested_hold_count','')::int, 0) AS requested_count,
      COALESCE(NULLIF(q.source_payload->>'line_hold_count','')::int, 0) AS line_count,
      COALESCE(NULLIF(q.source_payload->>'tracking_hold_count','')::int, 0) AS tracking_count,
      COALESCE(NULLIF(q.source_payload->>'order_hold_count','')::int, 0) AS order_count
  ) counts ON true
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT NULLIF(btrim(reason), ''), ' | ' ORDER BY NULLIF(btrim(reason), '')) AS reason_text
    FROM jsonb_to_recordset(COALESCE(q.source_payload->'hold_rows', '[]'::jsonb)) AS hold_row(reason text)
  ) reasons ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
