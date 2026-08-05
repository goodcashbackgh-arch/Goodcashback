BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Additive exact shipment-eligible contents reader.
-- Reuses the existing package contents return shape and does not alter v1.

CREATE OR REPLACE FUNCTION public.shipper_package_contents_preview_v2(
  p_tracking_submission_id uuid DEFAULT NULL
)
RETURNS TABLE (
  tracking