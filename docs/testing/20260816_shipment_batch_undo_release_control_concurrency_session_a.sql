-- =============================================================================
-- Shipment Batch Undo & Release Control v1 — CONCURRENCY PROOF / SESSION A
--
-- RUN THIS IN SUPABASE SQL EDITOR TAB A.
-- Immediately after clicking Run here, run the matching Session B file in a
-- second SQL Editor tab.
--
-- This transaction executes the REAL Shipment Batch Undo authority, holds all
-- of its transaction locks for 20 seconds, then ROLLS BACK everything.
--
-- SAFETY:
--   * Always ends ROLLBACK.
--   * No Groupage mutation.
--   * No trigger disabling / ACL / DDL / function changes.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
DECLARE
  v_batch_id uuid := '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid;
  v_uid uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.shipper_shipment_batches b
    WHERE b.id = v_batch_id
      AND b.status = 'created'
      AND EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_packages p
        WHERE p.shipment_batch_id = b.id
          AND p.active = true
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_groupage_movement_batches g
        WHERE g.shipment_batch_id = b.id
          AND g.active = true
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipping_documents d
        WHERE d.shipment_batch_id = b.id
          AND d.active = true
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipping_cost_allocations c
        WHERE c.shipment_batch_id = b.id
          AND c.active = true
          AND c.allocation_status = 'approved'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_shipment_batch_effective_lines_v1(b.id) e
        JOIN public.order_tracking_line_allocations a
          ON a.id = e.tracking_line_allocation_id
        WHERE a.locked_for_export_pack_at IS NOT NULL
           OR a.allocation_status = 'locked_for_export_pack'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_sales_release_lines r
        WHERE r.source_shipment_batch_id = b.id
          AND r.release_status = 'active'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.sage_posting_snapshots s
        WHERE s.shipment_batch_id = b.id
          AND (
            s.sage_posting_status = 'posted'
            OR (
              COALESCE(s.active, true) = true
              AND COALESCE(s.sage_posting_status, 'not_posted') <> 'voided'
            )
          )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.shipper_final_export_evidence_documents e
        WHERE e.shipment_batch_id = b.id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.invoice_adjustment_consumption_ledger l
        LEFT JOIN public.order_tracking_line_allocations a
          ON a.id = l.source_allocation_id
        WHERE l.shipment_batch_id = b.id
          AND l.active = true
          AND l.outcome = 'progressed_allocated'
          AND (
            a.id IS NULL
            OR a.locked_for_export_pack_at IS NOT NULL
            OR a.allocation_status = 'locked_for_export_pack'
            OR EXISTS (
              SELECT 1
              FROM public.customer_sales_release_lines r
              WHERE r.tracking_line_allocation_id = a.id
                AND r.release_status = 'active'
            )
          )
      )
  ) THEN
    RAISE EXCEPTION 'Concurrency base batch is no longer a clean Undo fixture. Do not continue.';
  END IF;

  SELECT su.auth_user_id
    INTO v_uid
  FROM public.shipper_shipment_batches b
  JOIN public.shipper_users su
    ON su.shipper_id = b.shipper_id
   AND su.active = true
   AND su.auth_user_id IS NOT NULL
  WHERE b.id = v_batch_id
  ORDER BY su.created_at DESC, su.id DESC
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No active shipper auth user exists for concurrency base batch.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub',v_uid::text,'role','authenticated')::text,
    true
  );
END
$preflight$;

-- Real production authority: locks batch row, package memberships, order/tracking
-- advisory keys and effective order_tracking_line_allocations before blockers.
SELECT public.shipper_undo_shipment_batch_v1(
  '27171dc7-2d99-412a-af87-a2a0c0b0a922'::uuid,
  'Two-session concurrency proof — Session A — rolled back'
) AS undo_result;

-- Hold the real Undo transaction locks long enough for Session B to prove all
-- six competing lock edges. Nothing is committed while sleeping.
SELECT pg_sleep(20);

ROLLBACK;
