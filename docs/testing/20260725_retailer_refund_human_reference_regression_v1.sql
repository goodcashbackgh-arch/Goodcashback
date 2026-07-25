DO $$
DECLARE
  v_def text;
  v_payload_mismatch integer;
  v_invalid_short_ref integer;
  v_unposted_payload_mismatch integer;
  v_cross_lane_spill integer;
BEGIN
  IF to_regprocedure('public.internal_retailer_refund_reference_source_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Regression failed: missing internal_retailer_refund_reference_source_v1(uuid).';
  END IF;

  IF to_regprocedure('public.internal_retailer_refund_short_reference_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Regression failed: missing internal_retailer_refund_short_reference_v1(uuid).';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_freeze_cash_control_rows_v1(text[],text)'::regprocedure
  ) INTO v_def;

  IF position('internal_retailer_refund_short_reference_v1' in v_def) = 0 THEN
    RAISE EXCEPTION 'Regression failed: retailer-refund freeze path does not use the canonical human-reference helper.';
  END IF;

  -- Existing unrelated cash-control reference expressions must remain present.
  IF position('GCB-FEE-' in v_def) = 0
     OR position('GCB-FX-' in v_def) = 0
     OR position('GCB-HOLD-' in v_def) = 0 THEN
    RAISE EXCEPTION 'Regression failed: an unrelated cash-control reference path changed.';
  END IF;

  -- Where an approved-current posted supplier-credit payload contains a reference,
  -- the retailer-refund helper must return that exact frozen payload reference.
  WITH allocations AS (
    SELECT adv.allocation_id, adv.dispute_id
    FROM public.dva_statement_line_allocation_detail_vw adv
    WHERE adv.allocation_type = 'retailer_refund'
      AND adv.allocation_status = 'confirmed'
  ), evidence AS (
    SELECT DISTINCT ON (a.allocation_id)
      a.allocation_id,
      s.id AS submission_id
    FROM allocations a
    JOIN public.dispute_refund_evidence_submissions s ON s.dispute_id = a.dispute_id
    WHERE s.supplier_approval_status = 'approved_current'
      AND s.supplier_control_status = 'approved_current'
    ORDER BY a.allocation_id, s.supplier_approved_at DESC NULLS LAST, s.created_at DESC
  ), payload_refs AS (
    SELECT DISTINCT ON (e.allocation_id)
      e.allocation_id,
      NULLIF(trim(COALESCE(
        sps.resolved_payload #>> '{sage_header,reference}',
        sps.resolved_payload ->> 'credit_note_ref',
        sps.resolved_payload #>> '{source_payload,sage_header,reference}',
        sps.resolved_payload #>> '{source_payload,credit_note_ref}',
        ''
      )), '') AS payload_reference
    FROM evidence e
    JOIN public.sage_posting_snapshots sps ON sps.source_id = e.submission_id
    WHERE sps.document_lane = 'supplier_credit_note'
      AND sps.sage_posting_status = 'posted'
      AND NULLIF(trim(COALESCE(sps.sage_invoice_id, '')), '') IS NOT NULL
    ORDER BY e.allocation_id, sps.sage_posted_at DESC NULLS LAST, sps.created_at DESC
  )
  SELECT count(*) INTO v_payload_mismatch
  FROM payload_refs p
  WHERE p.payload_reference IS NOT NULL
    AND public.internal_retailer_refund_reference_source_v1(p.allocation_id)
        IS DISTINCT FROM p.payload_reference;

  IF v_payload_mismatch <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % retailer-refund references do not match the frozen posted supplier-credit payload.', v_payload_mismatch;
  END IF;

  SELECT count(*) INTO v_invalid_short_ref
  FROM public.dva_statement_line_allocation_detail_vw adv
  WHERE adv.allocation_type = 'retailer_refund'
    AND adv.allocation_status = 'confirmed'
    AND (
      length(public.internal_retailer_refund_short_reference_v1(adv.allocation_id)) > 32
      OR public.internal_retailer_refund_short_reference_v1(adv.allocation_id) !~ '^[A-Z0-9-]+$'
      OR public.internal_retailer_refund_short_reference_v1(adv.allocation_id) NOT LIKE 'GCB-REF-%'
    );

  IF v_invalid_short_ref <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % retailer-refund references breach the established Sage 32-character/format contract.', v_invalid_short_ref;
  END IF;

  SELECT count(*) INTO v_unposted_payload_mismatch
  FROM public.cash_posting_snapshots s
  WHERE s.active = true
    AND s.posting_category = 'retailer_refund_received'
    AND COALESCE(s.sage_posting_status, 'not_posted') <> 'posted'
    AND NULLIF(trim(COALESCE(s.sage_object_id, '')), '') IS NULL
    AND (
      s.short_reference IS DISTINCT FROM public.internal_retailer_refund_short_reference_v1(s.source_id)
      OR s.request_payload #>> '{supplier_refund_candidate,reference}'
         IS DISTINCT FROM public.internal_retailer_refund_short_reference_v1(s.source_id)
      OR s.request_payload #>> '{supplier_refund_candidate,matched_target_ref}'
         IS DISTINCT FROM public.internal_retailer_refund_reference_source_v1(s.source_id)
    );

  IF v_unposted_payload_mismatch <> 0 THEN
    RAISE EXCEPTION 'Regression failed: % active unposted retailer-refund snapshots do not carry the canonical payload-derived reference.', v_unposted_payload_mismatch;
  END IF;

  SELECT count(*) INTO v_cross_lane_spill
  FROM public.cash_posting_snapshots s
  WHERE s.posting_category <> 'retailer_refund_received'
    AND (
      COALESCE(s.internal_reference_json, '{}'::jsonb) ? 'retailer_refund_reference_source'
      OR COALESCE(s.internal_reference_json, '{}'::jsonb) ? 'retailer_refund_short_reference'
    );

  IF v_cross_lane_spill <> 0 THEN
    RAISE EXCEPTION 'Regression failed: retailer-refund reference metadata leaked into % unrelated cash snapshots.', v_cross_lane_spill;
  END IF;
END $$;

SELECT
  'PASS'::text AS regression_result,
  'Retailer refund IN references reuse the frozen posted supplier-credit reference, remain within Sage''s established 32-character safe format, repair only active unposted retailer-refund payloads, and leave unrelated cash-control lanes unchanged.'::text AS details;
