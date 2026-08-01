BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Hybrid physical receipt foundation: shared exact quantity position.
-- This is private read infrastructure only. Existing review, shipment and
-- customer-release functions are not replaced by this migration.

DO $preflight$
BEGIN
  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.customer_review_cycle_memberships') IS NULL
     OR to_regclass('public.customer_hold_review_memberships') IS NULL
     OR to_regclass('public.shipper_shipment_batches') IS NULL
     OR to_regclass('public.shipper_shipment_batch_packages') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid receipt position prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'Prerequisite function missing: shipper_shipment_batch_effective_lines_v1(uuid)';
  END IF;

  IF to_regprocedure(
    'public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)'
  ) IS NOT NULL
     OR to_regclass('public.tracking_allocation_fulfilment_position_v1') IS NOT NULL
     OR to_regclass('public.tracking_allocation_fulfilment_anomalies_v1') IS NOT NULL
  THEN
    RAISE EXCEPTION
      'Hybrid receipt quantity-position objects already exist; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

CREATE FUNCTION public.internal_tracking_allocation_fulfilment_position_v1(
  p_order_id uuid DEFAULT NULL,
  p_tracking_submission_id uuid DEFAULT NULL,
  p_tracking_line_allocation_id uuid DEFAULT NULL
)
RETURNS TABLE (
  order_id uuid,
  tracking_submission_id uuid,
  tracking_line_allocation_id uuid,
  supplier_invoice_line_id uuid,
  allocated_qty numeric,
  physical_clean_qty numeric,
  physical_exception_qty numeric,
  reviewed_qty numeric,
  active_hold_qty numeric,
  shipped_qty numeric,
  customer_released_qty numeric,
  remedy_assigned_qty numeric,
  review_available_qty numeric,
  shipment_available_qty numeric,
  remedy_available_qty numeric,
  position_valid_yn boolean,
  position_blocker text,
  source_receipt_id uuid,
  source_receipt_model text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH allocation_scope AS (
    SELECT
      allocation.id,
      allocation.order_id,
      allocation.tracking_submission_id,
      allocation.supplier_invoice_line_id,
      COALESCE(allocation.qty_allocated, 0)::numeric AS allocated_qty
    FROM public.order_tracking_line_allocations allocation
    WHERE COALESCE(allocation.qty_allocated, 0) > 0
      AND (
        p_order_id IS NULL
        OR allocation.order_id = p_order_id
      )
      AND (
        p_tracking_submission_id IS NULL
        OR allocation.tracking_submission_id = p_tracking_submission_id
      )
      AND (
        p_tracking_line_allocation_id IS NULL
        OR allocation.id = p_tracking_line_allocation_id
      )
  ),
  source_receipt AS (
    SELECT
      scope.id AS tracking_line_allocation_id,
      latest.id AS receipt_id,
      latest.receipt_status::text AS receipt_status,
      latest.receipt_model_version,
      latest.receipt_state,
      latest.finalised_at
    FROM allocation_scope scope
    LEFT JOIN LATERAL (
      SELECT receipt.*
      FROM public.shipper_package_receipts receipt
      WHERE receipt.tracking_submission_id = scope.tracking_submission_id
        AND (
          receipt.receipt_model_version = 1
          OR (
            receipt.receipt_model_version = 2
            AND receipt.receipt_state = 'finalised'
            AND receipt.finalised_at IS NOT NULL
          )
        )
      ORDER BY receipt.created_at DESC, receipt.id DESC
      LIMIT 1
    ) latest ON true
  ),
  v2_disposition AS (
    SELECT
      disposition.receipt_id,
      disposition.tracking_line_allocation_id,
      COALESCE(SUM(disposition.quantity) FILTER (
        WHERE disposition.disposition_type = 'clean'
      ), 0)::numeric AS clean_qty,
      COALESCE(SUM(disposition.quantity) FILTER (
        WHERE disposition.disposition_type <> 'clean'
      ), 0)::numeric AS exception_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    JOIN allocation_scope scope
      ON scope.id = disposition.tracking_line_allocation_id
    GROUP BY
      disposition.receipt_id,
      disposition.tracking_line_allocation_id
  ),
  reviewed AS (
    SELECT
      membership.tracking_line_allocation_id,
      COALESCE(SUM(membership.review_qty), 0)::numeric AS reviewed_qty
    FROM public.customer_review_cycle_memberships membership
    JOIN allocation_scope scope
      ON scope.id = membership.tracking_line_allocation_id
    GROUP BY membership.tracking_line_allocation_id
  ),
  exact_active_hold AS (
    SELECT
      review_membership.tracking_line_allocation_id,
      COALESCE(SUM(hold_membership.affected_qty), 0)::numeric
        AS active_hold_qty
    FROM public.customer_hold_review_memberships hold_membership
    JOIN public.customer_review_cycle_memberships review_membership
      ON review_membership.id = hold_membership.review_membership_id
    JOIN allocation_scope scope
      ON scope.id = review_membership.tracking_line_allocation_id
    JOIN public.customer_pre_shipment_hold_requests hold_row
      ON hold_row.id = hold_membership.hold_request_id
    WHERE hold_membership.membership_status = 'active'
      AND hold_row.status IN ('requested','supervisor_approved')
    GROUP BY review_membership.tracking_line_allocation_id
  ),
  legacy_unproven_hold AS (
    SELECT scope.id AS tracking_line_allocation_id
    FROM allocation_scope scope
    WHERE EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests hold_row
      WHERE hold_row.order_id = scope.order_id
        AND hold_row.status IN ('requested','supervisor_approved')
        AND (
          hold_row.requested_scope = 'order'
          OR (
            hold_row.requested_scope = 'tracking'
            AND hold_row.tracking_submission_id = scope.tracking_submission_id
          )
          OR (
            hold_row.requested_scope = 'line'
            AND hold_row.supplier_invoice_line_id = scope.supplier_invoice_line_id
            AND (
              hold_row.tracking_submission_id IS NULL
              OR hold_row.tracking_submission_id = scope.tracking_submission_id
            )
          )
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.customer_hold_review_memberships hold_membership
          JOIN public.customer_review_cycle_memberships review_membership
            ON review_membership.id = hold_membership.review_membership_id
          WHERE hold_membership.hold_request_id = hold_row.id
            AND review_membership.tracking_line_allocation_id = scope.id
        )
    )
  ),
  relevant_batches AS (
    SELECT DISTINCT batch_row.id AS shipment_batch_id
    FROM public.shipper_shipment_batches batch_row
    JOIN public.shipper_shipment_batch_packages package_row
      ON package_row.shipment_batch_id = batch_row.id
     AND package_row.active = true
    JOIN allocation_scope scope
      ON scope.order_id = package_row.order_id
     AND scope.tracking_submission_id = package_row.tracking_submission_id
    WHERE batch_row.status <> 'voided'
  ),
  shipped AS (
    SELECT
      effective_line.tracking_line_allocation_id,
      COALESCE(SUM(effective_line.qty_in_shipment), 0)::numeric AS shipped_qty
    FROM relevant_batches relevant_batch
    CROSS JOIN LATERAL
      public.shipper_shipment_batch_effective_lines_v1(
        relevant_batch.shipment_batch_id
      ) effective_line
    JOIN allocation_scope scope
      ON scope.id = effective_line.tracking_line_allocation_id
    GROUP BY effective_line.tracking_line_allocation_id
  ),
  released AS (
    SELECT
      release_line.tracking_line_allocation_id,
      COALESCE(SUM(release_line.released_qty), 0)::numeric
        AS customer_released_qty
    FROM public.customer_sales_release_lines release_line
    JOIN allocation_scope scope
      ON scope.id = release_line.tracking_line_allocation_id
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.tracking_line_allocation_id
  ),
  remedy AS (
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
      ), 0)::numeric AS remedy_assigned_qty
    FROM public.physical_exception_remedy_allocations remedy_row
    JOIN allocation_scope scope
      ON scope.id = remedy_row.tracking_line_allocation_id
    GROUP BY remedy_row.tracking_line_allocation_id
  ),
  position_source AS (
    SELECT
      scope.order_id,
      scope.tracking_submission_id,
      scope.id AS tracking_line_allocation_id,
      scope.supplier_invoice_line_id,
      scope.allocated_qty,
      source.receipt_id AS source_receipt_id,
      CASE
        WHEN source.receipt_id IS NULL THEN 'none'
        WHEN source.receipt_model_version = 2 THEN 'v2_exact'
        ELSE 'legacy_v1'
      END::text AS source_receipt_model,
      source.receipt_status,
      CASE
        WHEN source.receipt_model_version = 2
          THEN COALESCE(disposition.clean_qty, 0)
        WHEN source.receipt_model_version = 1
         AND source.receipt_status = 'received_clean'
          THEN scope.allocated_qty
        ELSE 0
      END::numeric AS physical_clean_qty,
      CASE
        WHEN source.receipt_model_version = 2
          THEN COALESCE(disposition.exception_qty, 0)
        ELSE 0
      END::numeric AS physical_exception_qty,
      COALESCE(reviewed.reviewed_qty, 0)::numeric AS reviewed_qty,
      COALESCE(active_hold.active_hold_qty, 0)::numeric AS active_hold_qty,
      COALESCE(shipped.shipped_qty, 0)::numeric AS shipped_qty,
      COALESCE(released.customer_released_qty, 0)::numeric
        AS customer_released_qty,
      COALESCE(remedy.remedy_assigned_qty, 0)::numeric
        AS remedy_assigned_qty,
      (unproven_hold.tracking_line_allocation_id IS NOT NULL)
        AS legacy_hold_unproven_yn
    FROM allocation_scope scope
    LEFT JOIN source_receipt source
      ON source.tracking_line_allocation_id = scope.id
    LEFT JOIN v2_disposition disposition
      ON disposition.receipt_id = source.receipt_id
     AND disposition.tracking_line_allocation_id = scope.id
    LEFT JOIN reviewed
      ON reviewed.tracking_line_allocation_id = scope.id
    LEFT JOIN exact_active_hold active_hold
      ON active_hold.tracking_line_allocation_id = scope.id
    LEFT JOIN legacy_unproven_hold unproven_hold
      ON unproven_hold.tracking_line_allocation_id = scope.id
    LEFT JOIN shipped
      ON shipped.tracking_line_allocation_id = scope.id
    LEFT JOIN released
      ON released.tracking_line_allocation_id = scope.id
    LEFT JOIN remedy
      ON remedy.tracking_line_allocation_id = scope.id
  ),
  validated AS (
    SELECT
      source.*,
      CASE
        WHEN source.source_receipt_model = 'none' THEN false
        WHEN source.source_receipt_model = 'legacy_v1'
         AND source.receipt_status IS DISTINCT FROM 'received_clean' THEN false
        WHEN source.source_receipt_model = 'v2_exact'
         AND ABS(
           source.physical_clean_qty
           + source.physical_exception_qty
           - source.allocated_qty
         ) > 0.0005 THEN false
        WHEN source.legacy_hold_unproven_yn THEN false
        WHEN source.reviewed_qty > source.physical_clean_qty + 0.0005 THEN false
        WHEN source.active_hold_qty > source.physical_clean_qty + 0.0005 THEN false
        WHEN source.source_receipt_model = 'v2_exact'
         AND source.active_hold_qty > source.reviewed_qty + 0.0005 THEN false
        WHEN source.shipped_qty > source.physical_clean_qty + 0.0005 THEN false
        WHEN source.source_receipt_model = 'v2_exact'
         AND source.shipped_qty > source.reviewed_qty + 0.0005 THEN false
        WHEN source.active_hold_qty + source.shipped_qty
             > source.physical_clean_qty + 0.0005 THEN false
        WHEN source.source_receipt_model = 'v2_exact'
         AND source.active_hold_qty + source.shipped_qty
             > source.reviewed_qty + 0.0005 THEN false
        WHEN source.customer_released_qty > source.shipped_qty + 0.0005 THEN false
        WHEN source.remedy_assigned_qty
             > source.physical_exception_qty + 0.0005 THEN false
        ELSE true
      END AS position_valid_yn,
      CASE
        WHEN source.source_receipt_model = 'none'
          THEN 'receipt_not_recorded'
        WHEN source.source_receipt_model = 'legacy_v1'
         AND source.receipt_status IS DISTINCT FROM 'received_clean'
          THEN 'legacy_nonclean_quantity_unproven'
        WHEN source.source_receipt_model = 'v2_exact'
         AND ABS(
           source.physical_clean_qty
           + source.physical_exception_qty
           - source.allocated_qty
         ) > 0.0005
          THEN 'physical_quantity_balance_mismatch'
        WHEN source.legacy_hold_unproven_yn
          THEN 'legacy_hold_quantity_unproven'
        WHEN source.reviewed_qty > source.physical_clean_qty + 0.0005
          THEN 'reviewed_quantity_exceeds_clean_quantity'
        WHEN source.active_hold_qty > source.physical_clean_qty + 0.0005
          THEN 'active_hold_quantity_exceeds_clean_quantity'
        WHEN source.source_receipt_model = 'v2_exact'
         AND source.active_hold_qty > source.reviewed_qty + 0.0005
          THEN 'v2_active_hold_quantity_exceeds_reviewed_quantity'
        WHEN source.shipped_qty > source.physical_clean_qty + 0.0005
          THEN 'shipped_quantity_exceeds_clean_quantity'
        WHEN source.source_receipt_model = 'v2_exact'
         AND source.shipped_qty > source.reviewed_qty + 0.0005
          THEN 'v2_shipped_quantity_exceeds_reviewed_quantity'
        WHEN source.active_hold_qty + source.shipped_qty
             > source.physical_clean_qty + 0.0005
          THEN 'active_hold_and_shipped_exceed_clean_quantity'
        WHEN source.source_receipt_model = 'v2_exact'
         AND source.active_hold_qty + source.shipped_qty
             > source.reviewed_qty + 0.0005
          THEN 'v2_active_hold_and_shipped_exceed_reviewed_quantity'
        WHEN source.customer_released_qty > source.shipped_qty + 0.0005
          THEN 'customer_release_exceeds_shipped_quantity'
        WHEN source.remedy_assigned_qty
             > source.physical_exception_qty + 0.0005
          THEN 'remedy_quantity_exceeds_physical_exception'
        ELSE NULL
      END::text AS position_blocker
    FROM position_source source
  ),
  available AS (
    SELECT
      validated.*,
      CASE
        WHEN validated.source_receipt_model = 'legacy_v1'
          THEN validated.physical_clean_qty
        ELSE LEAST(
          validated.physical_clean_qty,
          validated.reviewed_qty
        )
      END::numeric AS shipment_review_basis_qty
    FROM validated
  )
  SELECT
    available.order_id,
    available.tracking_submission_id,
    available.tracking_line_allocation_id,
    available.supplier_invoice_line_id,
    available.allocated_qty,
    available.physical_clean_qty,
    available.physical_exception_qty,
    available.reviewed_qty,
    available.active_hold_qty,
    available.shipped_qty,
    available.customer_released_qty,
    available.remedy_assigned_qty,
    CASE
      WHEN available.position_valid_yn THEN GREATEST(
        available.physical_clean_qty
        - GREATEST(
            available.reviewed_qty,
            available.shipped_qty,
            available.customer_released_qty
          ),
        0
      )
      ELSE 0
    END::numeric AS review_available_qty,
    CASE
      WHEN available.position_valid_yn THEN GREATEST(
        available.shipment_review_basis_qty
        - available.active_hold_qty
        - available.shipped_qty,
        0
      )
      ELSE 0
    END::numeric AS shipment_available_qty,
    CASE
      WHEN available.position_valid_yn THEN GREATEST(
        available.physical_exception_qty
        - available.remedy_assigned_qty,
        0
      )
      ELSE 0
    END::numeric AS remedy_available_qty,
    available.position_valid_yn,
    available.position_blocker,
    available.source_receipt_id,
    available.source_receipt_model
  FROM available;
$function$;

COMMENT ON FUNCTION
  public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)
IS
'Private scoped exact quantity authority per tracking allocation. Legacy received-clean remains fully clean; v2 hold/shipment quantity cannot exceed exact reviewed clean quantity; no receipt, uncertain legacy non-clean, unproven holds and broken cumulative invariants fail closed with an explicit blocker.';

REVOKE ALL ON FUNCTION
  public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)
  TO service_role;

CREATE VIEW public.tracking_allocation_fulfilment_position_v1 AS
SELECT *
FROM public.internal_tracking_allocation_fulfilment_position_v1(
  NULL::uuid,
  NULL::uuid,
  NULL::uuid
);

COMMENT ON VIEW public.tracking_allocation_fulfilment_position_v1 IS
'Private full diagnostic projection of the scoped hybrid receipt quantity-position function.';

CREATE VIEW public.tracking_allocation_fulfilment_anomalies_v1 AS
SELECT *
FROM public.tracking_allocation_fulfilment_position_v1 position_row
WHERE position_row.position_valid_yn = false;

COMMENT ON VIEW public.tracking_allocation_fulfilment_anomalies_v1 IS
'Private fail-closed allocations requiring remediation before automatic review, shipment, customer release or physical remedy progression.';

REVOKE ALL ON public.tracking_allocation_fulfilment_position_v1
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.tracking_allocation_fulfilment_anomalies_v1
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tracking_allocation_fulfilment_position_v1 TO service_role;
GRANT SELECT ON public.tracking_allocation_fulfilment_anomalies_v1 TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;