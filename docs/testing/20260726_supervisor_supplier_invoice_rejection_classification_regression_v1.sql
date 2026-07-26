BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_missing text[];
  v_existing_signature_count integer;
  v_new_signature_count integer;
  v_internal_acl_count integer;
  v_unclassified_legacy_count integer;
BEGIN
  SELECT array_agg(required_object ORDER BY required