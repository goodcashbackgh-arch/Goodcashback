BEGIN;

-- Safe correction for Accounting Command Centre bulk freeze candidates.
-- The earlier version targeted an older candidate-filter shape. This version
-- patches only the live_ready CASE expressions used by the current function so
-- supplier_goods_ap is a supported selected/all-matching freeze group alongside
-- customer_sales and shipper_ap.
--
-- No data mutation. No Sage call. No schema change.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $do$
DECLARE
  v_oid oid := to_regprocedure('public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)');
  v_sql text;
BEGIN
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position('WHEN rq.document_lane = ''supplier_goods_ap'' AND rq.source_table = ''supplier_invoices'' THEN ''supplier_goods_ap''' in v_sql) = 0 THEN
    v_sql := replace(
      v_sql,
      'WHEN rq.document_lane = ''customer_sales'' AND rq.source_table = ''sales_invoices'' THEN ''customer_sales''
        WHEN rq.document_lane = ''shipper_ap'' AND rq.source_table = ''shipping_documents'' THEN ''shipper_ap''',
      'WHEN rq.document_lane = ''customer_sales'' AND rq.source_table = ''sales_invoices'' THEN ''customer_sales''
        WHEN rq.document_lane = ''supplier_goods_ap'' AND rq.source_table = ''supplier_invoices'' THEN ''supplier_goods_ap''
        WHEN rq.document_lane = ''shipper_ap'' AND rq.source_table = ''shipping_documents'' THEN ''shipper_ap'''
    );

    v_sql := replace(
      v_sql,
      'WHEN rq.document_lane = ''customer_sales'' AND rq.source_table = ''sales_invoices'' THEN NULL::text
        WHEN rq.document_lane = ''shipper_ap'' AND rq.source_table = ''shipping_documents'' THEN NULL::text',
      'WHEN rq.document_lane = ''customer_sales'' AND rq.source_table = ''sales_invoices'' THEN NULL::text
        WHEN rq.document_lane = ''supplier_goods_ap'' AND rq.source_table = ''supplier_invoices'' THEN NULL::text
        WHEN rq.document_lane = ''shipper_ap'' AND rq.source_table = ''shipping_documents'' THEN NULL::text'
    );

    EXECUTE v_sql;
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';
COMMIT;
