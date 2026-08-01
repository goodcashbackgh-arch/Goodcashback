BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Hybrid physical receipt foundation: integrity, immutability, correction and
-- quantity-reservation guards. No existing workflow function is replaced.

DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_receipt_v1_fingerprint text;
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_package_receipts');
  END IF;
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_package_receipt_line_dispositions');
  END IF;
  IF to_regclass('public.shipper_package_receipt_evidence') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_package_receipt_evidence');
  END IF;
  IF to_regclass('public.physical_receipt_reviews') IS NULL THEN
    v_missing := array_append(v_missing, 'physical_receipt_reviews');
  END IF;
  IF to_regclass('public.physical_exception_remedy_allocations') IS NULL THEN
    v_missing := array_append(v_missing, 'physical_exception_remedy_allocations');
  END IF;
  IF to_regprocedure('public.shipper_record_package_receipt_v1(uuid,text,text,text)') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_record_package_receipt_v1(uuid,text,text,text)');
  END IF;
  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_shipment_batch_effective_lines_v1(uuid)');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      'Hybrid receipt integrity prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)'::regprocedure
  ))
  INTO v_receipt_v1_fingerprint;

  IF v_receipt_v1_fingerprint <> '27fb972b34258990cfa9d752cd2f927b' THEN
    RAISE EXCEPTION
      'shipper_record_package_receipt_v1 changed after preflight (current fingerprint %). Stop rather than install guards over an unaudited baseline.',
      v_receipt_v1_fingerprint;
  END IF;

  IF to_regprocedure('public.shipper_receipt_line_disposition_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.shipper_receipt_evidence_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.shipper_package_receipt_v2_integrity_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.shipper_package_receipt_v2_pending_commit_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.physical_receipt_review_guard_v1()') IS NOT NULL
     OR to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NOT NULL
  THEN
    RAISE EXCEPTION
      'One or more hybrid receipt integrity functions already exist; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

-- The schema migration deliberately allowed a superseded review to retain its
-- historical dispute link. Make that explicit before installing lifecycle guards.
ALTER TABLE public.physical_receipt_reviews
  DROP CONSTRAINT physical_receipt_review_link_shape_chk;

ALTER TABLE public.physical_receipt_reviews
  ADD CONSTRAINT physical_receipt_review_link_shape_chk CHECK (
    (
      status = 'approved_to_existing_exception'
      AND linked_dispute_id IS NOT NULL
      AND approved_liable_party IS NOT NULL
    )
    OR
    (
      status = 'superseded'
      AND (
        linked_dispute_id IS NULL
        OR approved_liable_party IS NOT NULL
      )
    )
    OR
    (
      status NOT IN ('approved_to_existing_exception','superseded')
      AND linked_dispute_id IS NULL
    )
  );

ALTER TABLE public.physical_receipt_reviews
  DROP CONSTRAINT physical_receipt_reviews_status_check;

ALTER TABLE public.physical_receipt_reviews
  ADD CONSTRAINT physical_receipt_reviews_status_check CHECK (
    status IN (
      'awaiting_importer_proposal',
      'awaiting_supervisor_review',
      'returned_for_information',
      'approved_for_investigation',
      'approved_to_existing_exception',
      'rejected',
      'closed_no_action',
      'superseded'
    )
  );

CREATE FUNCTION public.shipper_receipt_line_disposition_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_receipt public.shipper_package_receipts%ROWTYPE;
  v_allocation public.order_tracking_line_allocations%ROWTYPE;
  v_existing_qty numeric := 0;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION
      'Physical receipt line dispositions are immutable; create a later complete corrected receipt snapshot.';
  END IF;

  SELECT receipt.*
  INTO v_receipt
  FROM public.shipper_package_receipts receipt
  WHERE receipt.id = NEW.receipt_id
  FOR UPDATE;

  IF v_receipt.id IS NULL
     OR v_receipt.receipt_model_version <> 2
     OR v_receipt.receipt_state <> 'pending'
     OR v_receipt.finalised_at IS NOT NULL
  THEN
    RAISE EXCEPTION
      'Line dispositions may be written only while a v2 receipt is pending in the same transaction.';
  END IF;

  IF NEW.tracking_submission_id IS DISTINCT FROM v_receipt.tracking_submission_id THEN
    RAISE EXCEPTION 'Disposition tracking identity does not match its receipt.';
  END IF;

  SELECT allocation.*
  INTO v_allocation
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id = NEW.tracking_line_allocation_id
  FOR UPDATE;

  IF v_allocation.id IS NULL
     OR v_allocation.order_id IS DISTINCT FROM v_receipt.order_id
     OR v_allocation.tracking_submission_id IS DISTINCT FROM v_receipt.tracking_submission_id
     OR v_allocation.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
     OR COALESCE(v_allocation.qty_allocated, 0) <= 0
  THEN
    RAISE EXCEPTION
      'Disposition does not match one positive exact tracking allocation.';
  END IF;

  IF NEW.disposition_type <> 'clean'
     AND NULLIF(BTRIM(COALESCE(NEW.condition_note, '')), '') IS NULL
  THEN
    RAISE EXCEPTION 'Every affected disposition requires a factual condition note.';
  END IF;

  SELECT COALESCE(SUM(disposition.quantity), 0)::numeric
  INTO v_existing_qty
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.receipt_id = NEW.receipt_id
    AND disposition.tracking_line_allocation_id = NEW.tracking_line_allocation_id;

  IF v_existing_qty + NEW.quantity > v_allocation.qty_allocated + 0.0005 THEN
    RAISE EXCEPTION
      'Cumulative disposition quantity exceeds the exact tracking allocation.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_receipt_line_disposition_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.shipper_package_receipt_line_dispositions
FOR EACH ROW
EXECUTE FUNCTION public.shipper_receipt_line_disposition_guard_v1();

CREATE FUNCTION public.shipper_receipt_evidence_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_receipt public.shipper_package_receipts%ROWTYPE;
  v_line_receipt_id uuid;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'Physical receipt evidence metadata is immutable.';
  END IF;

  SELECT receipt.*
  INTO v_receipt
  FROM public.shipper_package_receipts receipt
  WHERE receipt.id = NEW.receipt_id
  FOR UPDATE;

  IF v_receipt.id IS NULL
     OR v_receipt.receipt_model_version <> 2
     OR v_receipt.receipt_state <> 'pending'
     OR v_receipt.finalised_at IS NOT NULL
  THEN
    RAISE EXCEPTION
      'Evidence may be attached only while a v2 receipt is pending in the same transaction.';
  END IF;

  IF NEW.uploaded_by_shipper_user_id IS DISTINCT FROM v_receipt.shipper_user_id THEN
    RAISE EXCEPTION 'Evidence uploader does not match the receipt shipper user.';
  END IF;

  IF NEW.line_disposition_id IS NOT NULL THEN
    SELECT disposition.receipt_id
    INTO v_line_receipt_id
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.id = NEW.line_disposition_id;

    IF v_line_receipt_id IS DISTINCT FROM NEW.receipt_id THEN
      RAISE EXCEPTION 'Evidence disposition does not belong to the same receipt.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_receipt_evidence_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.shipper_package_receipt_evidence
FOR EACH ROW
EXECUTE FUNCTION public.shipper_receipt_evidence_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_v2_integrity_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_prior_receipt public.shipper_package_receipts%ROWTYPE;
  v_expected_count integer := 0;
  v_missing_count integer := 0;
  v_mismatch_count integer := 0;
  v_clean_qty numeric := 0;
  v_damaged_qty numeric := 0;
  v_missing_qty numeric := 0;
  v_wrong_qty numeric := 0;
  v_held_qty numeric := 0;
  v_affected_qty numeric := 0;
  v_allocated_qty numeric := 0;
  v_downstream_conflict_count integer := 0;
  v_unproven_hold_count integer := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.receipt_model_version = 2 THEN
      RAISE EXCEPTION 'V2 receipt history is immutable and cannot be deleted.';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.receipt_model_version = 1 THEN
      RETURN NEW;
    END IF;

    IF NEW.receipt_model_version <> 2
       OR NEW.receipt_state <> 'pending'
       OR NEW.finalised_at IS NOT NULL
       OR NEW.receipt_status IS DISTINCT FROM 'held_query'
    THEN
      RAISE EXCEPTION
        'A v2 receipt must be inserted as pending with held_query as its temporary compatibility summary.';
    END IF;

    RETURN NEW;
  END IF;

  IF OLD.receipt_model_version = 1 THEN
    IF NEW.receipt_model_version IS DISTINCT FROM 1
       OR NEW.receipt_state IS DISTINCT FROM 'finalised'
       OR NEW.receipt_submission_id IS NOT NULL
       OR NEW.payload_fingerprint IS NOT NULL
       OR NEW.finalised_at IS NOT NULL
       OR NEW.correction_of_receipt_id IS NOT NULL
       OR NEW.correction_reason IS NOT NULL
    THEN
      RAISE EXCEPTION
        'Legacy receipt compatibility metadata is immutable; legacy facts may only use the existing v1 shape.';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.receipt_model_version <> 2
     OR NEW.receipt_model_version IS DISTINCT FROM OLD.receipt_model_version
  THEN
    RAISE EXCEPTION 'Receipt model version is immutable.';
  END IF;

  IF OLD.receipt_state = 'finalised' OR OLD.finalised_at IS NOT NULL THEN
    IF to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
      RAISE EXCEPTION 'Finalised v2 receipt headers are immutable.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.tracking_submission_id IS DISTINCT FROM OLD.tracking_submission_id
     OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.shipper_id IS DISTINCT FROM OLD.shipper_id
     OR NEW.shipper_user_id IS DISTINCT FROM OLD.shipper_user_id
     OR NEW.receipt_submission_id IS DISTINCT FROM OLD.receipt_submission_id
     OR NEW.payload_fingerprint IS DISTINCT FROM OLD.payload_fingerprint
     OR NEW.correction_of_receipt_id IS DISTINCT FROM OLD.correction_of_receipt_id
     OR NEW.correction_reason IS DISTINCT FROM OLD.correction_reason
     OR NEW.recorded_at IS DISTINCT FROM OLD.recorded_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'V2 receipt identity and idempotency fields are immutable.';
  END IF;

  IF NEW.receipt_state = 'pending' AND NEW.finalised_at IS NULL THEN
    IF NEW.receipt_status IS DISTINCT FROM 'held_query' THEN
      RAISE EXCEPTION 'A pending v2 receipt must retain held_query as its temporary summary.';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.receipt_state <> 'pending'
     OR NEW.receipt_state <> 'finalised'
  THEN
    RAISE EXCEPTION 'A v2 receipt may transition only from pending to finalised.';
  END IF;

  SELECT prior.*
  INTO v_prior_receipt
  FROM public.shipper_package_receipts prior
  WHERE prior.tracking_submission_id = NEW.tracking_submission_id
    AND prior.id <> NEW.id
    AND (
      prior.receipt_model_version = 1
      OR (
        prior.receipt_model_version = 2
        AND prior.receipt_state = 'finalised'
        AND prior.finalised_at IS NOT NULL
      )
    )
  ORDER BY prior.created_at DESC, prior.id DESC
  LIMIT 1
  FOR SHARE;

  IF v_prior_receipt.id IS NULL THEN
    IF NEW.correction_of_receipt_id IS NOT NULL THEN
      RAISE EXCEPTION 'First finalised receipt for a package cannot identify a correction predecessor.';
    END IF;
  ELSE
    IF NEW.correction_of_receipt_id IS DISTINCT FROM v_prior_receipt.id THEN
      RAISE EXCEPTION
        'A later v2 receipt must identify the latest finalised package receipt as its correction predecessor.';
    END IF;

    IF v_prior_receipt.order_id IS DISTINCT FROM NEW.order_id
       OR v_prior_receipt.shipper_id IS DISTINCT FROM NEW.shipper_id
    THEN
      RAISE EXCEPTION 'Correction predecessor does not match the same order and shipper.';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.physical_receipt_reviews review_row
      WHERE review_row.receipt_id = v_prior_receipt.id
        AND review_row.linked_dispute_id IS NOT NULL
        AND review_row.status = 'approved_to_existing_exception'
    ) THEN
      RAISE EXCEPTION
        'A receipt already linked to the existing retailer exception route requires controlled staff remediation before correction.';
    END IF;
  END IF;

  WITH expected AS (
    SELECT allocation.id, allocation.qty_allocated
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = NEW.order_id
      AND allocation.tracking_submission_id = NEW.tracking_submission_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
  ), actual AS (
    SELECT
      disposition.tracking_line_allocation_id AS id,
      SUM(disposition.quantity)::numeric AS disposition_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.id
    GROUP BY disposition.tracking_line_allocation_id
  )
  SELECT
    COUNT(*)::integer,
    COUNT(*) FILTER (WHERE actual.id IS NULL)::integer,
    COUNT(*) FILTER (
      WHERE actual.id IS NOT NULL
        AND ABS(actual.disposition_qty - expected.qty_allocated) > 0.0005
    )::integer,
    COALESCE(SUM(expected.qty_allocated), 0)::numeric
  INTO
    v_expected_count,
    v_missing_count,
    v_mismatch_count,
    v_allocated_qty
  FROM expected
  LEFT JOIN actual ON actual.id = expected.id;

  IF v_expected_count = 0 THEN
    RAISE EXCEPTION 'V2 receipt has no positive exact tracking allocations.';
  END IF;

  IF COALESCE(v_missing_count, 0) > 0
     OR COALESCE(v_mismatch_count, 0) > 0
  THEN
    RAISE EXCEPTION
      'V2 receipt is incomplete or unbalanced: % allocation(s) missing and % allocation(s) mismatched.',
      COALESCE(v_missing_count, 0),
      COALESCE(v_mismatch_count, 0);
  END IF;

  SELECT
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'clean'
    ), 0)::numeric,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'damaged'
    ), 0)::numeric,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'missing'
    ), 0)::numeric,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'wrong'
    ), 0)::numeric,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'held'
    ), 0)::numeric
  INTO
    v_clean_qty,
    v_damaged_qty,
    v_missing_qty,
    v_wrong_qty,
    v_held_qty
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.receipt_id = NEW.id;

  v_affected_qty :=
    v_damaged_qty + v_missing_qty + v_wrong_qty + v_held_qty;

  IF ABS(v_clean_qty + v_affected_qty - v_allocated_qty) > 0.0005 THEN
    RAISE EXCEPTION 'V2 receipt physical quantity total does not equal allocated quantity.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.id
      AND disposition.disposition_type <> 'clean'
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_package_receipt_evidence evidence
        WHERE evidence.receipt_id = NEW.id
          AND (
            evidence.line_disposition_id = disposition.id
            OR evidence.line_disposition_id IS NULL
          )
      )
  ) THEN
    RAISE EXCEPTION
      'Every affected disposition requires linked evidence or shared receipt evidence.';
  END IF;

  WITH actual AS (
    SELECT
      disposition.tracking_line_allocation_id,
      COALESCE(SUM(disposition.quantity) FILTER (
        WHERE disposition.disposition_type = 'clean'
      ), 0)::numeric AS clean_qty,
      COALESCE(SUM(disposition.quantity) FILTER (
        WHERE disposition.disposition_type <> 'clean'
      ), 0)::numeric AS exception_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.id
    GROUP BY disposition.tracking_line_allocation_id
  ), reviewed AS (
    SELECT
      membership.tracking_line_allocation_id,
      COALESCE(SUM(membership.review_qty), 0)::numeric AS qty
    FROM public.customer_review_cycle_memberships membership
    GROUP BY membership.tracking_line_allocation_id
  ), exact_hold AS (
    SELECT
      review_membership.tracking_line_allocation_id,
      COALESCE(SUM(hold_membership.affected_qty), 0)::numeric AS qty
    FROM public.customer_hold_review_memberships hold_membership
    JOIN public.customer_review_cycle_memberships review_membership
      ON review_membership.id = hold_membership.review_membership_id
    JOIN public.customer_pre_shipment_hold_requests hold_row
      ON hold_row.id = hold_membership.hold_request_id
    WHERE hold_membership.membership_status = 'active'
      AND hold_row.status IN ('requested','supervisor_approved')
    GROUP BY review_membership.tracking_line_allocation_id
  ), shipped AS (
    SELECT
      effective_line.tracking_line_allocation_id,
      COALESCE(SUM(effective_line.qty_in_shipment), 0)::numeric AS qty
    FROM public.shipper_shipment_batches batch_row
    CROSS JOIN LATERAL
      public.shipper_shipment_batch_effective_lines_v1(batch_row.id) effective_line
    WHERE batch_row.status <> 'voided'
    GROUP BY effective_line.tracking_line_allocation_id
  ), released AS (
    SELECT
      release_line.tracking_line_allocation_id,
      COALESCE(SUM(release_line.released_qty), 0)::numeric AS qty
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.tracking_line_allocation_id
  ), remedy AS (
    SELECT
      remedy_row.tracking_line_allocation_id,
      COALESCE(SUM(
        CASE
          WHEN remedy_row.status = 'proposed'
            THEN remedy_row.proposed_remedy_qty
          WHEN remedy_row.status IN (
            'approved','linked_to_exception','in_progress',
            'completed','closed_no_action'
          )
            THEN remedy_row.approved_remedy_qty
          ELSE 0
        END
      ), 0)::numeric AS qty
    FROM public.physical_exception_remedy_allocations remedy_row
    GROUP BY remedy_row.tracking_line_allocation_id
  )
  SELECT COUNT(*)::integer
  INTO v_downstream_conflict_count
  FROM actual
  LEFT JOIN reviewed
    ON reviewed.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN exact_hold
    ON exact_hold.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN shipped
    ON shipped.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN released
    ON released.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN remedy
    ON remedy.tracking_line_allocation_id = actual.tracking_line_allocation_id
  WHERE actual.clean_qty + 0.0005 < GREATEST(
          COALESCE(reviewed.qty, 0),
          COALESCE(shipped.qty, 0),
          COALESCE(released.qty, 0)
        )
     OR actual.clean_qty + 0.0005 <
          COALESCE(exact_hold.qty, 0) + COALESCE(shipped.qty, 0)
     OR actual.exception_qty + 0.0005 < COALESCE(remedy.qty, 0);

  SELECT COUNT(*)::integer
  INTO v_unproven_hold_count
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.order_id = NEW.order_id
    AND allocation.tracking_submission_id = NEW.tracking_submission_id
    AND COALESCE(allocation.qty_allocated, 0) > 0
    AND EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests hold_row
      WHERE hold_row.order_id = allocation.order_id
        AND hold_row.status IN ('requested','supervisor_approved')
        AND (
          hold_row.requested_scope = 'order'
          OR (
            hold_row.requested_scope = 'tracking'
            AND hold_row.tracking_submission_id = allocation.tracking_submission_id
          )
          OR (
            hold_row.requested_scope = 'line'
            AND hold_row.supplier_invoice_line_id = allocation.supplier_invoice_line_id
            AND (
              hold_row.tracking_submission_id IS NULL
              OR hold_row.tracking_submission_id = allocation.tracking_submission_id
            )
          )
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.customer_hold_review_memberships hold_membership
          JOIN public.customer_review_cycle_memberships review_membership
            ON review_membership.id = hold_membership.review_membership_id
          WHERE hold_membership.hold_request_id = hold_row.id
            AND review_membership.tracking_line_allocation_id = allocation.id
        )
    );

  IF v_downstream_conflict_count > 0 THEN
    RAISE EXCEPTION
      'V2 receipt would reduce quantity below existing review, hold, shipment, release or remedy provenance.';
  END IF;

  IF v_unproven_hold_count > 0 THEN
    RAISE EXCEPTION
      'V2 receipt cannot supersede an active legacy hold whose exact quantity is unproven.';
  END IF;

  NEW.receipt_status := CASE
    WHEN v_affected_qty = 0 THEN 'received_clean'
    WHEN v_clean_qty = 0
     AND ABS(v_missing_qty - v_allocated_qty) <= 0.0005 THEN 'not_received'
    WHEN v_damaged_qty = 0
     AND v_missing_qty = 0
     AND v_wrong_qty = 0
     AND v_held_qty > 0 THEN 'held_query'
    ELSE 'received_damaged'
  END;
  NEW.finalised_at := clock_timestamp();

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_v2_integrity_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.shipper_package_receipts
FOR EACH ROW
EXECUTE FUNCTION public.shipper_package_receipt_v2_integrity_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    WHERE receipt.id = COALESCE(NEW.id, OLD.id)
      AND receipt.receipt_model_version = 2
      AND (
        receipt.receipt_state <> 'finalised'
        OR receipt.finalised_at IS NULL
      )
  ) THEN
    RAISE EXCEPTION
      'A pending v2 receipt cannot be committed; the complete snapshot must finalise in the same transaction.';
  END IF;

  RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_shipper_package_receipt_v2_pending_commit_guard_v1
AFTER INSERT OR UPDATE
ON public.shipper_package_receipts
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1();

CREATE FUNCTION public.physical_receipt_review_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_receipt public.shipper_package_receipts%ROWTYPE;
  v_order_importer_id uuid;
  v_affected_qty numeric := 0;
  v_latest_receipt_id uuid;
  v_dispute_order_id uuid;
  v_active_remedy_count integer := 0;
  v_bad_remedy_count integer := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical receipt review provenance cannot be deleted.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT receipt.*
    INTO v_receipt
    FROM public.shipper_package_receipts receipt
    WHERE receipt.id = NEW.receipt_id
    FOR SHARE;

    SELECT order_row.importer_id
    INTO v_order_importer_id
    FROM public.orders order_row
    WHERE order_row.id = NEW.order_id;

    SELECT COALESCE(SUM(disposition.quantity), 0)::numeric
    INTO v_affected_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.receipt_id
      AND disposition.disposition_type <> 'clean';

    SELECT receipt.id
    INTO v_latest_receipt_id
    FROM public.shipper_package_receipts receipt
    WHERE receipt.tracking_submission_id = NEW.tracking_submission_id
      AND (
        receipt.receipt_model_version = 1
        OR (
          receipt.receipt_model_version = 2
          AND receipt.receipt_state = 'finalised'
          AND receipt.finalised_at IS NOT NULL
        )
      )
    ORDER BY receipt.created_at DESC, receipt.id DESC
    LIMIT 1;

    IF v_receipt.id IS NULL
       OR v_receipt.receipt_model_version <> 2
       OR v_receipt.receipt_state <> 'finalised'
       OR v_receipt.finalised_at IS NULL
       OR v_receipt.order_id IS DISTINCT FROM NEW.order_id
       OR v_receipt.tracking_submission_id IS DISTINCT FROM NEW.tracking_submission_id
       OR v_order_importer_id IS DISTINCT FROM NEW.importer_id
       OR v_latest_receipt_id IS DISTINCT FROM NEW.receipt_id
       OR v_affected_qty <= 0
    THEN
      RAISE EXCEPTION
        'Physical review must reference the latest finalised affected v2 receipt with matching order, importer and tracking identities.';
    END IF;

    IF NEW.status IS DISTINCT FROM 'awaiting_importer_proposal'
       OR NEW.importer_proposed_by_operator_id IS NOT NULL
       OR NEW.importer_proposed_at IS NOT NULL
       OR NEW.supervisor_decided_by_staff_id IS NOT NULL
       OR NEW.supervisor_decided_at IS NOT NULL
       OR NEW.approved_liable_party IS NOT NULL
       OR NEW.linked_dispute_id IS NOT NULL
       OR NEW.superseded_by_receipt_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'A physical receipt review must start in awaiting_importer_proposal without an invented decision or dispute link.';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
     OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.importer_id IS DISTINCT FROM OLD.importer_id
     OR NEW.tracking_submission_id IS DISTINCT FROM OLD.tracking_submission_id
     OR NEW.source_stage IS DISTINCT FROM OLD.source_stage
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'Physical review source identity is immutable.';
  END IF;

  IF OLD.status IN (
    'approved_to_existing_exception','rejected','closed_no_action','superseded'
  ) AND NEW.status IS DISTINCT FROM OLD.status
  THEN
    RAISE EXCEPTION 'Closed or linked physical review state cannot be reopened.';
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
     AND NOT (
       (OLD.status = 'awaiting_importer_proposal'
        AND NEW.status IN ('awaiting_supervisor_review','superseded'))
       OR
       (OLD.status = 'awaiting_supervisor_review'
        AND NEW.status IN (
          'returned_for_information',
          'approved_for_investigation',
          'approved_to_existing_exception',
          'rejected',
          'closed_no_action',
          'superseded'
        ))
       OR
       (OLD.status = 'returned_for_information'
        AND NEW.status IN ('awaiting_supervisor_review','superseded'))
       OR
       (OLD.status = 'approved_for_investigation'
        AND NEW.status IN ('awaiting_supervisor_review','superseded'))
     )
  THEN
    RAISE EXCEPTION
      'Invalid physical review state transition: % -> %',
      OLD.status,
      NEW.status;
  END IF;

  IF NEW.status = 'awaiting_supervisor_review' THEN
    IF NEW.importer_proposed_by_operator_id IS NULL
       OR NEW.importer_proposed_at IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM public.operators operator_row
         JOIN public.operator_importers access_row
           ON access_row.operator_id = operator_row.id
          AND access_row.importer_id = NEW.importer_id
          AND access_row.revoked_at IS NULL
         WHERE operator_row.id = NEW.importer_proposed_by_operator_id
           AND COALESCE(operator_row.active, true) = true
       )
    THEN
      RAISE EXCEPTION
        'Awaiting-supervisor review requires an active authorised importer proposal actor and timestamp.';
    END IF;

    SELECT COUNT(*)::integer
    INTO v_active_remedy_count
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = NEW.id
      AND remedy_row.status = 'proposed';

    IF v_active_remedy_count = 0 THEN
      RAISE EXCEPTION
        'Awaiting-supervisor review requires at least one exact proposed remedy allocation.';
    END IF;
  END IF;

  IF NEW.status IN (
    'returned_for_information',
    'approved_for_investigation',
    'approved_to_existing_exception',
    'rejected',
    'closed_no_action'
  ) THEN
    IF NEW.supervisor_decided_by_staff_id IS NULL
       OR NEW.supervisor_decided_at IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM public.staff staff_row
         WHERE staff_row.id = NEW.supervisor_decided_by_staff_id
           AND COALESCE(staff_row.active, true) = true
       )
    THEN
      RAISE EXCEPTION
        'Supervisor decision state requires an active staff actor and timestamp.';
    END IF;
  END IF;

  IF NEW.linked_dispute_id IS NOT NULL THEN
    SELECT dispute_row.order_id
    INTO v_dispute_order_id
    FROM public.disputes dispute_row
    WHERE dispute_row.id = NEW.linked_dispute_id;

    IF v_dispute_order_id IS DISTINCT FROM NEW.order_id THEN
      RAISE EXCEPTION 'Linked dispute does not belong to the physical review order.';
    END IF;
  END IF;

  IF NEW.status = 'approved_to_existing_exception' THEN
    SELECT COUNT(*)::integer,
           COUNT(*) FILTER (
             WHERE remedy_row.status NOT IN (
               'approved','linked_to_exception','in_progress','completed'
             )
                OR remedy_row.approved_remedy_type NOT IN ('refund','replacement')
           )::integer
    INTO v_active_remedy_count, v_bad_remedy_count
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = NEW.id
      AND remedy_row.status NOT IN ('cancelled','rerouted');

    IF v_active_remedy_count = 0 OR v_bad_remedy_count > 0 THEN
      RAISE EXCEPTION
        'Existing-exception approval requires only supervisor-approved refund/replacement remedy allocations.';
    END IF;
  END IF;

  IF NEW.status = 'approved_for_investigation' AND EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = NEW.id
      AND remedy_row.status NOT IN ('cancelled','rerouted')
      AND (
        remedy_row.status NOT IN ('approved','in_progress')
        OR remedy_row.approved_remedy_type <> 'hold_investigate'
      )
  ) THEN
    RAISE EXCEPTION
      'Investigation approval may contain only approved hold/investigate quantity.';
  END IF;

  IF NEW.status = 'closed_no_action' AND EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = NEW.id
      AND remedy_row.status NOT IN ('cancelled','rerouted')
      AND (
        remedy_row.status <> 'closed_no_action'
        OR remedy_row.approved_remedy_type <> 'no_action'
      )
  ) THEN
    RAISE EXCEPTION
      'Closed-no-action review may contain only supervisor-approved no-action allocations.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_receipt_review_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.physical_receipt_reviews
FOR EACH ROW
EXECUTE FUNCTION public.physical_receipt_review_guard_v1();

CREATE FUNCTION public.physical_remedy_allocation_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_dispute_line_supplier_id uuid;
  v_dispute_order_id uuid;
  v_dispute_id uuid;
  v_child_order public.orders%ROWTYPE;
  v_child_allocation_order_id uuid;
  v_existing_qty numeric := 0;
  v_new_qty numeric := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION
      'Physical remedy provenance cannot be deleted; cancel or reroute it through an audited transition.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'proposed'
       OR NEW.approved_remedy_type IS NOT NULL
       OR NEW.approved_remedy_qty IS NOT NULL
       OR NEW.approved_by_staff_id IS NOT NULL
       OR NEW.approved_at IS NOT NULL
       OR NEW.dispute_line_id IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
       OR NEW.rerouted_to_remedy_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'A remedy allocation must start as the importer proposal only.';
    END IF;
  ELSE
    IF NEW.physical_receipt_review_id IS DISTINCT FROM OLD.physical_receipt_review_id
       OR NEW.receipt_line_disposition_id IS DISTINCT FROM OLD.receipt_line_disposition_id
       OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
       OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
       OR NEW.proposed_remedy_type IS DISTINCT FROM OLD.proposed_remedy_type
       OR NEW.proposed_remedy_qty IS DISTINCT FROM OLD.proposed_remedy_qty
       OR NEW.proposed_by_operator_id IS DISTINCT FROM OLD.proposed_by_operator_id
       OR NEW.proposed_at IS DISTINCT FROM OLD.proposed_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
      RAISE EXCEPTION
        'Importer remedy proposal and exact source identity are immutable; reroute with a new allocation.';
    END IF;

    IF OLD.approved_at IS NOT NULL
       AND (
         NEW.approved_remedy_type IS DISTINCT FROM OLD.approved_remedy_type
         OR NEW.approved_remedy_qty IS DISTINCT FROM OLD.approved_remedy_qty
         OR NEW.approved_by_staff_id IS DISTINCT FROM OLD.approved_by_staff_id
         OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       )
    THEN
      RAISE EXCEPTION
        'Supervisor-approved remedy route and quantity are immutable; reroute with a new allocation.';
    END IF;

    IF OLD.status IN ('completed','closed_no_action','rerouted')
       AND NEW.status IS DISTINCT FROM OLD.status
    THEN
      RAISE EXCEPTION 'Completed, no-action or rerouted remedy state cannot be reopened.';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (
         (OLD.status = 'proposed'
          AND NEW.status IN ('approved','cancelled','rerouted'))
         OR
         (OLD.status = 'approved'
          AND NEW.status IN (
            'linked_to_exception','in_progress','completed',
            'closed_no_action','cancelled','rerouted'
          ))
         OR
         (OLD.status = 'linked_to_exception'
          AND NEW.status IN ('in_progress','completed','cancelled','rerouted'))
         OR
         (OLD.status = 'in_progress'
          AND NEW.status IN ('completed','cancelled','rerouted'))
         OR
         (OLD.status = 'cancelled' AND NEW.status = 'rerouted')
       )
    THEN
      RAISE EXCEPTION
        'Invalid physical remedy state transition: % -> %',
        OLD.status,
        NEW.status;
    END IF;
  END IF;

  SELECT disposition.*
  INTO v_disposition
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.id = NEW.receipt_line_disposition_id
  FOR UPDATE;

  SELECT review_row.*
  INTO v_review
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = NEW.physical_receipt_review_id
  FOR SHARE;

  IF v_disposition.id IS NULL
     OR v_disposition.disposition_type = 'clean'
     OR v_review.id IS NULL
     OR v_review.receipt_id IS DISTINCT FROM v_disposition.receipt_id
     OR v_disposition.tracking_line_allocation_id IS DISTINCT FROM NEW.tracking_line_allocation_id
     OR v_disposition.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
  THEN
    RAISE EXCEPTION
      'Physical remedy does not match one affected receipt disposition and review.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators operator_row
    JOIN public.operator_importers access_row
      ON access_row.operator_id = operator_row.id
     AND access_row.importer_id = v_review.importer_id
     AND access_row.revoked_at IS NULL
    WHERE operator_row.id = NEW.proposed_by_operator_id
      AND COALESCE(operator_row.active, true) = true
  ) THEN
    RAISE EXCEPTION
      'Remedy proposal actor is not an active operator for the review importer.';
  END IF;

  IF NEW.status IN (
    'approved','linked_to_exception','in_progress','completed','closed_no_action'
  ) THEN
    IF NEW.approved_remedy_type IS NULL
       OR NEW.approved_remedy_qty IS NULL
       OR NEW.approved_by_staff_id IS NULL
       OR NEW.approved_at IS NULL
       OR NOT EXISTS (
         SELECT 1
         FROM public.staff staff_row
         WHERE staff_row.id = NEW.approved_by_staff_id
           AND COALESCE(staff_row.active, true) = true
       )
    THEN
      RAISE EXCEPTION
        'Approved remedy state requires the exact supervisor-approved route, quantity, actor and timestamp.';
    END IF;
  END IF;

  IF NEW.approved_remedy_type = 'replacement' THEN
    IF NEW.supplier_cost_mode NOT IN (
      'free_replacement','charged_repurchase','pending_supplier_evidence'
    ) THEN
      RAISE EXCEPTION
        'Approved replacement requires an explicit supplier cost mode.';
    END IF;
  ELSIF NEW.approved_remedy_type IS NOT NULL THEN
    IF COALESCE(NEW.supplier_cost_mode, 'not_applicable') <> 'not_applicable'
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'Non-replacement remedy cannot carry replacement supplier cost or child provenance.';
    END IF;
  ELSE
    IF NEW.supplier_cost_mode IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION
        'Unapproved proposal cannot carry replacement cost or child provenance.';
    END IF;
  END IF;

  IF NEW.status IN ('linked_to_exception','in_progress','completed')
     AND NEW.approved_remedy_type IN ('refund','replacement')
  THEN
    IF NEW.dispute_line_id IS NULL THEN
      RAISE EXCEPTION
        'Progressed refund/replacement remedy requires its exact existing dispute line.';
    END IF;
  END IF;

  IF NEW.dispute_line_id IS NOT NULL THEN
    SELECT
      dispute_line.supplier_invoice_line_id,
      dispute_row.order_id,
      dispute_row.id
    INTO
      v_dispute_line_supplier_id,
      v_dispute_order_id,
      v_dispute_id
    FROM public.dispute_lines dispute_line
    JOIN public.disputes dispute_row ON dispute_row.id = dispute_line.dispute_id
    WHERE dispute_line.id = NEW.dispute_line_id;

    IF v_dispute_line_supplier_id IS DISTINCT FROM NEW.supplier_invoice_line_id
       OR v_dispute_order_id IS DISTINCT FROM v_review.order_id
       OR (
         v_review.linked_dispute_id IS NOT NULL
         AND v_review.linked_dispute_id IS DISTINCT FROM v_dispute_id
       )
    THEN
      RAISE EXCEPTION
        'Physical remedy dispute line does not match the exact source line, order and linked dispute.';
    END IF;
  END IF;

  IF NEW.approved_remedy_type = 'replacement'
     AND NEW.status IN ('in_progress','completed')
  THEN
    IF NEW.replacement_child_order_id IS NULL THEN
      RAISE EXCEPTION
        'Replacement in progress or completed requires its exact replacement child order.';
    END IF;

    SELECT child.*
    INTO v_child_order
    FROM public.orders child
    WHERE child.id = NEW.replacement_child_order_id;

    IF v_child_order.id IS NULL
       OR v_child_order.order_type IS DISTINCT FROM 'replacement_child'
       OR v_child_order.parent_order_id IS DISTINCT FROM v_review.order_id
       OR (
         v_child_order.replacement_source_dispute_line_id IS NOT NULL
         AND v_child_order.replacement_source_dispute_line_id IS DISTINCT FROM NEW.dispute_line_id
       )
    THEN
      RAISE EXCEPTION
        'Replacement child does not match the parent order and source dispute line.';
    END IF;
  END IF;

  IF NEW.status = 'completed'
     AND NEW.approved_remedy_type = 'replacement'
  THEN
    IF NEW.replacement_child_tracking_allocation_id IS NULL THEN
      RAISE EXCEPTION
        'Completed replacement requires exact replacement-child tracking allocation provenance.';
    END IF;

    SELECT allocation.order_id
    INTO v_child_allocation_order_id
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.id = NEW.replacement_child_tracking_allocation_id;

    IF v_child_allocation_order_id IS DISTINCT FROM NEW.replacement_child_order_id THEN
      RAISE EXCEPTION
        'Replacement-child tracking allocation does not belong to the replacement child order.';
    END IF;
  END IF;

  IF NEW.status = 'closed_no_action'
     AND NEW.approved_remedy_type IS DISTINCT FROM 'no_action'
  THEN
    RAISE EXCEPTION 'Closed-no-action status requires an approved no-action route.';
  END IF;

  IF NEW.status = 'rerouted' THEN
    IF NEW.rerouted_to_remedy_allocation_id IS NULL
       OR NEW.rerouted_to_remedy_allocation_id = NEW.id
       OR NOT EXISTS (
         SELECT 1
         FROM public.physical_exception_remedy_allocations target
         WHERE target.id = NEW.rerouted_to_remedy_allocation_id
           AND target.physical_receipt_review_id = NEW.physical_receipt_review_id
           AND target.receipt_line_disposition_id = NEW.receipt_line_disposition_id
       )
    THEN
      RAISE EXCEPTION
        'Rerouted remedy must identify a different allocation for the same review and affected disposition.';
    END IF;
  ELSIF NEW.rerouted_to_remedy_allocation_id IS NOT NULL THEN
    RAISE EXCEPTION 'Only a rerouted remedy may carry a reroute target.';
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN remedy_row.status = 'proposed'
        THEN remedy_row.proposed_remedy_qty
      WHEN remedy_row.status IN (
        'approved','linked_to_exception','in_progress',
        'completed','closed_no_action'
      )
        THEN remedy_row.approved_remedy_qty
      ELSE 0
    END
  ), 0)::numeric
  INTO v_existing_qty
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.receipt_line_disposition_id = NEW.receipt_line_disposition_id
    AND (TG_OP = 'INSERT' OR remedy_row.id <> NEW.id);

  v_new_qty := CASE
    WHEN NEW.status = 'proposed' THEN NEW.proposed_remedy_qty
    WHEN NEW.status IN (
      'approved','linked_to_exception','in_progress',
      'completed','closed_no_action'
    ) THEN NEW.approved_remedy_qty
    ELSE 0
  END;

  IF v_existing_qty + COALESCE(v_new_qty, 0)
       > v_disposition.quantity + 0.0005
  THEN
    RAISE EXCEPTION
      'Proposed/approved remedy quantity exceeds the affected receipt quantity.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_remedy_allocation_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.physical_exception_remedy_allocations
FOR EACH ROW
EXECUTE FUNCTION public.physical_remedy_allocation_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_v2_supersede_open_review_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  IF NEW.receipt_model_version = 2
     AND NEW.receipt_state = 'finalised'
     AND OLD.receipt_state = 'pending'
     AND NEW.correction_of_receipt_id IS NOT NULL
  THEN
    UPDATE public.physical_receipt_reviews review_row
    SET status = 'superseded',
        superseded_by_receipt_id = NEW.id,
        decision_note = concat_ws(
          ' ',
          NULLIF(BTRIM(COALESCE(review_row.decision_note, '')), ''),
          'Superseded by corrected finalised receipt ' || NEW.id::text || '.'
        ),
        updated_at = now()
    WHERE review_row.receipt_id = NEW.correction_of_receipt_id
      AND review_row.status IN (
        'awaiting_importer_proposal',
        'awaiting_supervisor_review',
        'returned_for_information',
        'approved_for_investigation'
      );
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_v2_supersede_open_review_v1
AFTER UPDATE OF receipt_state
ON public.shipper_package_receipts
FOR EACH ROW
WHEN (OLD.receipt_state IS DISTINCT FROM NEW.receipt_state)
EXECUTE FUNCTION public.shipper_package_receipt_v2_supersede_open_review_v1();

REVOKE ALL ON FUNCTION public.shipper_receipt_line_disposition_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_receipt_evidence_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_v2_integrity_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_v2_pending_commit_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_receipt_review_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v1()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_v2_supersede_open_review_v1()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;