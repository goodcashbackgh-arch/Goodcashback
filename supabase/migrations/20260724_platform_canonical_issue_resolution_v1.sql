BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.disputes') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.disputes';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.customer_pre_shipment_hold_requests';
  END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dispute_refund_evidence_submissions';
  END IF;
  IF to_regclass('public.dva_statement_line_allocations') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.dva_statement_line_allocations';
  END IF;
END $$;

/*
 * Do not create a second canonical status model.
 *
 * The existing platform canonical spine already derives exception_state,
 * hold_state, current_stage, next_owner and next_action from disputes and
 * customer_pre_shipment_hold_requests. The defect is stale source lifecycle
 * rows after the refund has actually completed.
 *
 * Canonical refund completion is therefore written back only when BOTH are true:
 *   1. approved-current supplier refund evidence exists; and
 *   2. a confirmed retailer_refund statement allocation exists.
 *
 * Once those source rows are terminal, all existing canonical consumers refresh
 * naturally without changing funding, treasury allocation, shipment, Sage or VAT.
 */
CREATE OR REPLACE FUNCTION public.refresh_completed_refund_issue_status_v1(
  p_order_id uuid DEFAULT NULL,
  p_dispute_id uuid DEFAULT NULL
)
RETURNS TABLE (
  disputes_closed integer,
  holds_closed integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_disputes integer := 0;
  v_holds integer := 0;
BEGIN
  WITH completed_refunds AS (
    SELECT d.id AS dispute_id
    FROM public.disputes d
    WHERE d.desired_outcome = 'refund'
      AND d.resolved_at IS NULL
      AND COALESCE(d.status, '') NOT IN (
        'closed',
        'resolved',
        'refunded',
        'replaced',
        'closed_no_action'
      )
      AND (p_order_id IS NULL OR d.order_id = p_order_id)
      AND (p_dispute_id IS NULL OR d.id = p_dispute_id)
      AND EXISTS (
        SELECT 1
        FROM public.dispute_refund_evidence_submissions s
        WHERE s.dispute_id = d.id
          AND s.supplier_approval_status = 'approved_current'
          AND s.supplier_control_status = 'approved_current'
      )
      AND EXISTS (
        SELECT 1
        FROM public.dva_statement_line_allocations a
        WHERE a.dispute_id = d.id
          AND a.allocation_type = 'retailer_refund'
          AND a.allocation_status = 'confirmed'
      )
  )
  UPDATE public.disputes d
  SET status = 'refunded',
      resolved_at = COALESCE(d.resolved_at, now())
  FROM completed_refunds c
  WHERE d.id = c.dispute_id
    AND d.resolved_at IS NULL;

  GET DIAGNOSTICS v_disputes = ROW_COUNT;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET status = 'resolved',
      resolved_at = COALESCE(h.resolved_at, d.resolved_at, now()),
      updated_at = now()
  FROM public.disputes d
  WHERE h.converted_dispute_id = d.id
    AND d.desired_outcome = 'refund'
    AND d.status = 'refunded'
    AND d.resolved_at IS NOT NULL
    AND h.resolved_at IS NULL
    AND h.status IN (
      'requested',
      'supervisor_approved',
      'converted_to_exception'
    )
    AND (p_order_id IS NULL OR h.order_id = p_order_id)
    AND (p_dispute_id IS NULL OR d.id = p_dispute_id);

  GET DIAGNOSTICS v_holds = ROW_COUNT;

  RETURN QUERY
  SELECT v_disputes, v_holds;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_completed_refund_issue_status_v1(uuid, uuid)
FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.trg_refresh_completed_refund_issue_status_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.dispute_id IS NOT NULL THEN
    PERFORM public.refresh_completed_refund_issue_status_v1(NULL, NEW.dispute_id);
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.trg_refresh_completed_refund_issue_status_v1()
FROM PUBLIC;

DROP TRIGGER IF EXISTS trg_refresh_completed_refund_from_allocation_v1
ON public.dva_statement_line_allocations;

CREATE TRIGGER trg_refresh_completed_refund_from_allocation_v1
AFTER INSERT OR UPDATE OF
  allocation_type,
  allocation_status,
  dispute_id
ON public.dva_statement_line_allocations
FOR EACH ROW
WHEN (NEW.dispute_id IS NOT NULL)
EXECUTE FUNCTION public.trg_refresh_completed_refund_issue_status_v1();

DROP TRIGGER IF EXISTS trg_refresh_completed_refund_from_evidence_v1
ON public.dispute_refund_evidence_submissions;

CREATE TRIGGER trg_refresh_completed_refund_from_evidence_v1
AFTER INSERT OR UPDATE OF
  supplier_approval_status,
  supplier_control_status,
  dispute_id
ON public.dispute_refund_evidence_submissions
FOR EACH ROW
WHEN (NEW.dispute_id IS NOT NULL)
EXECUTE FUNCTION public.trg_refresh_completed_refund_issue_status_v1();

/*
 * Backfill existing economically completed refund issues, including the current
 * ORD-1784498556959 lifecycle when both completion facts are present.
 */
SELECT *
FROM public.refresh_completed_refund_issue_status_v1(NULL, NULL);

NOTIFY pgrst, 'reload schema';

COMMIT;
