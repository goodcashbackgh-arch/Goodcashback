-- =============================================================================
-- Customer sales draft UUID aggregate regression v1
-- Read-only. Run after 20260724_customer_sales_draft_uuid_min_v1.sql.
-- =============================================================================

DO $$
DECLARE
  v_definition text;
  v_compact text;
  v_uuid_safe_count integer;
BEGIN
  IF to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Customer sales bulk-draft RPC is missing.';
  END IF;

  SELECT pg_get_functiondef(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         )
    INTO v_definition;

  v_compact := lower(regexp_replace(v_definition, '[[:space:]]+', '', 'g'));

  IF position('min(rs.shipment_batch_id)' in v_compact) > 0 THEN
    RAISE EXCEPTION 'Unsupported MIN(uuid) remains in the customer draft RPC.';
  END IF;

  SELECT (
    length(v_compact)
    - length(replace(
        v_compact,
        '(array_agg(distinctrs.shipment_batch_idorderbyrs.shipment_batch_id))[1]',
        ''
      ))
  ) / length('(array_agg(distinctrs.shipment_batch_idorderbyrs.shipment_batch_id))[1]')
  INTO v_uuid_safe_count;

  IF v_uuid_safe_count <> 2 THEN
    RAISE EXCEPTION
      'Expected exactly two UUID-safe representative batch selections; found %.',
      v_uuid_safe_count;
  END IF;

  IF position('si.amount_gbp' in v_definition) = 0
     OR position('rs.customer_charge_amount_gbp' in v_definition) = 0
     OR position('internal_customer_sales_release_sources_v1' in v_definition) = 0
     OR position('customer_sales_release_lines' in v_definition) = 0
     OR position('customer_sales_release_draft_already_exists' in v_definition) = 0
     OR position('pg_advisory_xact_lock' in v_definition) = 0
     OR position('membership_fingerprint' in v_definition) = 0
     OR position('supplementary' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'Mini-build 3 controls were not preserved by the UUID hotfix.';
  END IF;
END $$;

SELECT
  'PASS'::text AS result,
  'Unsupported MIN(uuid) removed from both representative shipment-batch selections; current Mini-build 3 release source, grouping, locking, durable membership and main/supplementary controls remain in the same RPC.'::text AS detail;
