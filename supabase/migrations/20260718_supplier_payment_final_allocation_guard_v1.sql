BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Supplier Payment Funding Provenance Governing Addendum v1 — micro implementation 3.
-- Replaces only the existing final supplier-invoice allocation RPC internals.
-- The final write repeats the Step 2 readiness gate, resolves one source for one
-- physical OUT, and removes the unproven default-real-D