-- =============================================================================
-- Customer sales draft amount ambiguity regression v1
-- Read-only. Run after 20260724_customer_sales_draft_amount_ambiguity_v1.sql.
-- =============================================================================

DO $$
DECLARE
  v_definition text;
  v_arguments text;
  v_result text;
BEGIN
  IF to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL THEN
    RAISE EXCEPTION 'Customer sales bulk-draft RPC is missing.';
  END IF;

  SELECT pg_get_functiondef(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         )
    INTO v_definition;

  SELECT pg_get_function_arguments(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         ),
         pg_get_function_result(
           'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
         )
    INTO v_arguments, v_result;

  IF v_arguments IS DISTINCT FROM 'p_shipment_batch_ids uuid[]' THEN
    RAISE EXCEPTION 'Bulk-draft input contract changed unexpectedly: %', v_arguments;
  END IF;

  IF position('TABLE(shipment_batch_id uuid, order_id uuid, order_ref text, booking_ref text, invoice_type text, result_status text, sales_invoice_id uuid, amount_gbp numeric, message text)' in v_result) = 0 THEN
    RAISE EXCEPTION 'Bulk-draft output contract changed unexpectedly: %', v_result;
  END IF;

  IF position('si.amount_gbp' in v_definition) = 0
     OR position('si.invoice_type::text' in v_definition) = 0
     OR position('si.order_id = v_parent' in v_definition) = 0
     OR position('rs.customer_charge_amount_gbp' in v_definition) = 0
     OR position('RETURNING public.sales_invoices.id' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'Required column qualification is missing from the bulk-draft RPC.';
  END IF;

  IF position('SELECT id,amount_gbp,invoice_type::text' in replace(v_definition, ' ', '')) > 0
     OR position('SELECT id, amount_gbp, invoice_type::text' in v_definition) > 0
  THEN
    RAISE EXCEPTION 'Unqualified amount_gbp ambiguity remains in the bulk-draft RPC.';
  END IF;

  IF position('internal_customer_sales_release_sources_v1' in v_definition) = 0
     OR position('customer_sales_release_lines' in v_definition) = 0
     OR position('customer_sales_release_draft_already_exists' in v_definition) = 0
     OR position('pg_advisory_xact_lock' in v_definition) = 0
     OR position('supplementary' in v_definition) = 0
     OR position('membership_fingerprint' in v_definition) = 0
  THEN
    RAISE EXCEPTION 'Mini-build 3 durable release controls were not preserved.';
  END IF;
END $$;

SELECT
  'PASS'::text AS result,
  'Customer draft RPC amount_gbp ambiguity removed; Mini-build 3 exact release membership, main/supplementary grouping and duplicate-draft controls remain in the same function.'::text AS detail;
