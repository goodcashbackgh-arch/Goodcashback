-- DO NOT RUN.
--
-- This migration is intentionally disabled pending correction after live-database
-- and repository audit. The previous versions failed transactionally and made no
-- persistent database change.
--
-- Governing contract:
-- docs/governing-pack/backend/SHIPPER_AP_AND_CUSTOMER_SHIPPING_RECHARGE_GATE_SEPARATION_ADDENDUM_v1.md
--
-- Confirmed defects requiring correction before execution:
-- 1. Function ACL restoration did not neutralise default anon EXECUTE before
--    replaying the captured canonical ACL.
-- 2. The additive queue incorrectly removed a shipper-AP row after freeze/batch
--    locking, while snapshot revalidation requires that row to remain available
--    in internal_ready_for_sage_queue_v2().
-- 3. The additive order-reference path did not reuse the authoritative effective
--    shipment-line route used by the existing AP/recharge preview.
-- 4. The regression did not execute controlled freeze/revalidation/idempotency
--    proof and could pass with no qualifying unapportioned document.
--
-- No replacement implementation is authorised until the complete corrected
-- migration and regression have been reviewed against the addendum and the live
-- evidence supplied on 2026-07-27.

DO $$
BEGIN
  RAISE EXCEPTION
    'DISABLED: shipper AP/customer recharge gate-separation migration requires corrected governed rebuild';
END
$$;
