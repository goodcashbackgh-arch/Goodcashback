-- Staff credit source-lot provenance regression v1
-- Run after supabase/migrations/20260718_staff_credit_source_lot_provenance_v1.sql.
-- Read-only structural checks: no business data is changed.

BEGIN;

DO $$
DECLARE
  v_definition text;
  v_security_definer boolean;
  v_execute_granted boolean;
  v_trigger_enabled "char";
BEGIN