BEGIN;

-- Hard fix for supplier_credit_note Accounting Command Centre freeze support.
-- Previous patch partially exposed the lane in the UI, but bulk candidates and/or
-- selectable state could still remain unsupported. This patch uses precise checks
-- instead of a broad "supplier_credit_note exists" guard.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $patch$
DECLARE
  v_oid oid;
  v_sql text;
BEGIN
  -- 1) Bulk candidate resolver: required by all-matching freeze route.
  v_oid := to_regprocedure('public.internal_accounting_command_centre_bulk_candidates_v1(text,text,text,text,text,text,boolean,integer)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'internal_accounting_command_centre_bulk_candidates_v1 missing';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position($$WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$ in v_sql) = 0 THEN
    IF position($$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$ in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find shipper_ap selection-group insertion point in internal_accounting_command_centre_bulk_candidates_v1';
    END IF;

    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$
    );
  END IF;

  IF position($$WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN NULL::text$$ in v_sql) = 0 THEN
    IF position($$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text$$ in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find shipper_ap excluded-reason insertion point in internal_accounting_command_centre_bulk_candidates_v1';
    END IF;

    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN NULL::text
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN NULL::text$$
    );
  END IF;

  EXECUTE v_sql;

  -- 2) Grid resolver: required for checkbox/selectable state and row action.
  v_oid := to_regprocedure('public.internal_accounting_command_centre_grid_v1(text,text,text,text,integer,integer)');
  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'internal_accounting_command_centre_grid_v1 missing';
  END IF;

  v_sql := pg_get_functiondef(v_oid);

  IF position($$WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'Freeze supplier credit note'$$ in v_sql) = 0 THEN
    IF position($$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'$$ in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find shipper_ap next-action insertion point in internal_accounting_command_centre_grid_v1';
    END IF;

    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'Freeze shipper AP'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'Freeze supplier credit note'$$
    );
  END IF;

  IF position($$OR (rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions') AS out_selectable$$ in v_sql) = 0 THEN
    IF position($$OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents') AS out_selectable$$ in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find shipper_ap selectable insertion point in internal_accounting_command_centre_grid_v1';
    END IF;

    v_sql := replace(
      v_sql,
      $$OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents') AS out_selectable$$,
      $$OR (rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents')
        OR (rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions') AS out_selectable$$
    );
  END IF;

  IF position($$WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$ in v_sql) = 0 THEN
    IF position($$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$ in v_sql) = 0 THEN
      RAISE EXCEPTION 'Could not find shipper_ap selection-group insertion point in internal_accounting_command_centre_grid_v1';
    END IF;

    v_sql := replace(
      v_sql,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'$$,
      $$WHEN rq.document_lane = 'shipper_ap' AND rq.source_table = 'shipping_documents' THEN 'shipper_ap'
        WHEN rq.document_lane = 'supplier_credit_note' AND rq.source_table = 'dispute_refund_evidence_submissions' THEN 'supplier_credit_note'$$
    );
  END IF;

  EXECUTE v_sql;
END
$patch$;

NOTIFY pgrst, 'reload schema';
COMMIT;
