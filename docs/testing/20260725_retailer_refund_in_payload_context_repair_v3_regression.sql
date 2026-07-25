DO $$
DECLARE
  v_missing_snapshot_context integer;
  v_missing_row_context integer;
  v_terminal_contact_failures integer;
BEGIN
  SELECT count(*) INTO v_missing_snapshot_context
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.posting_category = 'retailer_refund_received'
    AND NULLIF(trim(COALESCE(s.sage_contact_id, '')), '') IS NOT NULL
    AND NULLIF(trim(COALESCE(s.sage_bank_account_id, '')), '') IS NOT NULL
    AND (
      NULLIF(trim(COALESCE(s.request_payload #>> '{supplier_refund_candidate,contact_id}', '')), '') IS NULL
      OR NULLIF(trim(COALESCE(s.request_payload #>> '{supplier_refund_candidate,bank_account_id}', '')), '') IS NULL
    );

  IF v_missing_snapshot_context <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % retailer refund snapshots still lack frozen Sage context.', v_missing_snapshot_context;
  END IF;

  SELECT count(*) INTO v_missing_row_context
  FROM public.cash_posting_batch_rows br
  JOIN public.cash_posting_snapshots s ON s.id = br.snapshot_id
  WHERE br.active = true
    AND br.posting_category = 'retailer_refund_received'
    AND br.sage_object_id IS NULL
    AND NULLIF(trim(COALESCE(s.sage_contact_id, '')), '') IS NOT NULL
    AND NULLIF(trim(COALESCE(s.sage_bank_account_id, '')), '') IS NOT NULL
    AND (
      NULLIF(trim(COALESCE(br.request_payload #>> '{supplier_refund_candidate,contact_id}', '')), '') IS NULL
      OR NULLIF(trim(COALESCE(br.request_payload #>> '{supplier_refund_candidate,bank_account_id}', '')), '') IS NULL
    );

  IF v_missing_row_context <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % retailer refund batch rows still lack frozen Sage context.', v_missing_row_context;
  END IF;

  SELECT count(*) INTO v_terminal_contact_failures
  FROM public.cash_posting_batch_rows br
  WHERE br.active = true
    AND br.posting_category = 'retailer_refund_received'
    AND br.sage_object_id IS NULL
    AND br.posting_status = 'failed_terminal'
    AND br.error_code = 'payload_builder_failed'
    AND br.error_message ILIKE '%contact_id%';

  IF v_terminal_contact_failures <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % retailer refund rows remain terminal because contact context is missing.', v_terminal_contact_failures;
  END IF;
END $$;

SELECT
  'PASS'::text AS regression_result,
  'Retailer refund IN frozen snapshots and active batch rows carry their existing Sage contact and bank context, and contact-context payload failures are retryable.'::text AS details;
