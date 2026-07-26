-- Read-only. Makes no database changes.
-- Compares ORD-1784976429191 with real clean-flow orders in the live DB.
-- Shows canonical statuses for supervisor/customer/importer/shipper,
-- exact importer dashboard button gates, and any notification/reminder objects.

BEGIN;

DO $$
DECLARE
  v_auth_uid uuid;
BEGIN
  SELECT s.auth_user_id
  INTO v_auth_uid
  FROM public.staff s
  WHERE COALESCE(s.active, true) = true
    AND