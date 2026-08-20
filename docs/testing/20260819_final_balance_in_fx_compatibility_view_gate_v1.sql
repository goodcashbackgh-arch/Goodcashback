BEGIN TRANSACTION READ ONLY;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '30s';

DO $gate$
DECLARE
  v_actual_md5 text;
  v_actual_columns text[];
  v_expected_columns constant text[] := ARRAY[
    'dva_statement_line_id','dva_statement_id','importer_id','statement_date',
    'reference_raw','direction','amount_local_ccy','local_ccy','fx_rate_applied',
    'card_markup_pct_applied','statement_gbp_amount','auth_id_ref','retailer_name_ref',
    'match_status','confirmed_allocated_gbp','open_allocated_gbp',
    'supplier_invoice_allocated_gbp','retailer_refund_allocated_gbp',
    'fx_card_or_fee_allocated_gbp','exception_or_hold_allocated_gbp',
    'active_allocation_count','confirmed_unallocated_gbp','confirmed_balanced_yn',
    'final_balance_payment_allocated_gbp','statement_account_context',
    'statement_account_label','source_bank','loyalty_credit_funding_allocated_gbp',
    'main_bank_loyalty_match_count','control_match_reason',
    'loyalty_internal_transfer_out_gbp','loyalty_internal_transfer_in_gbp',
    'loyalty_internal_transfer_in_count'
  ];
  v_def text;
BEGIN
  IF to_regclass('public.dva_statement_line_allocation_summary_vw') IS NULL THEN
    RAISE EXCEPTION 'FAIL: compatibility view public.dva_statement_line_allocation_summary_vw is missing';
  END IF;

  SELECT md5(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true)),
         lower(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true))
    INTO v_actual_md5, v_def;

  IF v_actual_md5 IS DISTINCT FROM 'dc0d809fd2737f829259e3f1adaf4f96' THEN
    RAISE EXCEPTION 'FAIL: compatibility-view fingerprint changed. expected %, actual %',
      'dc0d809fd2737f829259e3f1adaf4f96', v_actual_md5;
  END IF;

  SELECT array_agg(c.column_name::text ORDER BY c.ordinal_position)
    INTO v_actual_columns
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'dva_statement_line_allocation_summary_vw';

  IF v_actual_columns IS DISTINCT FROM v_expected_columns THEN
    RAISE EXCEPTION 'FAIL: compatibility-view column contract changed. expected %, actual %',
      v_expected_columns, v_actual_columns;
  END IF;

  IF position('dva_reconciliation' IN v_def) = 0
     OR position('order_funding' IN v_def) = 0
     OR position('loyalty_internal_transfer_out_gbp' IN v_def) = 0
     OR position('loyalty_internal_transfer_in_gbp' IN v_def) = 0
     OR position('loyalty_internal_transfer_in_count' IN v_def) = 0
     OR position('dva_statement_line_import_links' IN v_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: compatibility view lost an August governed calculation/preservation seam';
  END IF;
END
$gate$;

SELECT jsonb_build_object(
  'gate', 'FINAL_BALANCE_IN_FX_COMPATIBILITY_VIEW_GATE_V1',
  'read_only', true,
  'result', 'PASS',
  'expected_md5', 'dc0d809fd2737f829259e3f1adaf4f96',
  'actual_md5', md5(pg_get_viewdef('public.dva_statement_line_allocation_summary_vw'::regclass, true))
) AS result;

ROLLBACK;
