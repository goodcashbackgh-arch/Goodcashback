BEGIN;

-- Make supplier_credit_note a first-class selectable/freezable Accounting Command Centre lane.
-- The previous backend queue showed the row, but grid/bulk candidate helpers still treated it as unsupported,
-- which made the UI row unselectable and made the freeze route return zero candidates.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid;
  v_sql text;
BEGIN
  v_oid := to_regprocedure('public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'internal_accounting_command_centre_bulk_candidates_v1 missing';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position('supplier_credit_note' in v_sql) = 0 THEN
    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$
    );

    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN NULL::text$$
    );

    EXECUTE v_sql;
  END IF;

  v_oid := to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'internal_accounting_command_centre_grid_v1 missing';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position('supplier_credit_note' in v_sql) = 0 THEN
    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'Freeze supplier credit note'$$
    );

    v_sql := replace(
      v_sql,
      $$(rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices')
        OR (rq.document_lane = 'supplier_goods_ap' AND rq.source_table = 'supplier_invoices')
        OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents') AS out_selectable$$,
      $$(rq.document_lane = 'customer_sales' AND rq.source_table = 'sales_invoices')
        OR (rq.document_lane = 'supplier_goods_ap' AND rq.source_table = 'supplier_invoices')
        OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents')
        OR (rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions') AS out_selectable$$
    );

    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$
    );

    EXECUTE v_sql;
  END IF;
END
$patch$;

NOTIFY pgrst, 'reload schema';
COMMIT;
