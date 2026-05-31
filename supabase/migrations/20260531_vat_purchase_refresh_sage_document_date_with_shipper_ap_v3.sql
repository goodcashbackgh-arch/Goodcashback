BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

CREATE OR REPLACE FUNCTION public.staff_refresh_vat_purchase_source_lines_v1(p_vat_return_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_staff_id uuid;
  v_ap_lines integer := 0;
  v_shipper_lines integer := 0;
  v_credit_lines integer := 0;
  v_box4 numeric(18,2) := 0;
  v_box7 numeric(18,2) := 0;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT purchase refresh action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.locked_at IS NOT NULL OR v_run.status IN (
    'admin_approved',
    'sage_adjustment_journals_pending',
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review',
    'superseded'
  ) THEN
    RAISE EXCEPTION 'Cannot refresh purchase source lines for VAT run in status %.', v_run.status;
  END IF;

  DELETE FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND line_kind IN (
      'supplier_purchase_invoice_box4_vat',
      'supplier_purchase_invoice_box7_net',
      'supplier_credit_note_box4_decrease',
      'supplier_credit_note_box7_decrease',
      'shipper_ap_box7_net'
    );

  WITH posted_ap AS (
    SELECT
      s.id AS snapshot_id,
      s.source_id AS original_source_id,
      s.order_id,
      s.order_ref::text AS order_ref,
      COALESCE(s.reference_text, s.sage_invoice_id, s.id::text)::text AS ref,
      NULLIF(s.resolved_payload #>> '{sage_header,date}', '')::date AS tax_date,
      s.sage_invoice_id,
      line.ordinality::integer AS line_no,
      line.value AS line_json,
      COALESCE(NULLIF(line.value->>'net_amount_gbp', '')::numeric, 0)::numeric(18,2) AS net_gbp,
      COALESCE(NULLIF(line.value->>'vat_amount_gbp', '')::numeric, 0)::numeric(18,2) AS vat_gbp
    FROM public.sage_posting_snapshots s
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.resolved_payload->'resolved_lines', '[]'::jsonb)) WITH ORDINALITY AS line(value, ordinality)
    WHERE s.active = true
      AND s.sage_posting_status = 'posted'
      AND s.document_lane = 'supplier_goods_ap'
      AND NULLIF(s.resolved_payload #>> '{sage_header,date}', '')::date
        BETWEEN v_run.period_start_date AND v_run.period_end_date
  ),
  ap_rows AS (
    SELECT *, 7 AS box_number, 'supplier_purchase_invoice_box7_net' AS line_kind, net_gbp AS amount_gbp, 0::numeric AS vat_amount_gbp, 'sage_document_date_supplier_goods_ap_net' AS basis
    FROM posted_ap WHERE net_gbp <> 0
    UNION ALL
    SELECT *, 4 AS box_number, 'supplier_purchase_invoice_box4_vat' AS line_kind, vat_gbp AS amount_gbp, vat_gbp AS vat_amount_gbp, 'sage_document_date_supplier_goods_ap_vat' AS basis
    FROM posted_ap WHERE vat_gbp <> 0
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
    box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
    natural_sage_covered, adjustment_required, adjustment_reason, status
  )
  SELECT
    p_vat_return_run_id,
    r.line_kind,
    'sage_posting_snapshots',
    r.snapshot_id,
    'supplier_goods_ap:' || r.ref || ':line:' || r.line_no::text || ':box:' || r.box_number::text,
    to_jsonb(r),
    jsonb_build_object(
      'source', 'posted_supplier_goods_ap_snapshot',
      'snapshot_id', r.snapshot_id,
      'original_source_id', r.original_source_id,
      'reference_text', r.ref,
      'order_ref', r.order_ref,
      'sage_invoice_id', r.sage_invoice_id,
      'sage_vat_date', r.tax_date,
      'line_json', r.line_json
    ),
    r.box_number,
    'natural',
    r.amount_gbp,
    r.vat_amount_gbp,
    r.basis,
    r.tax_date,
    v_run.return_period_label,
    true,
    false,
    'platform_posted_supplier_goods_ap_snapshot_sage_document_date',
    'active'
  FROM ap_rows r;

  GET DIAGNOSTICS v_ap_lines = ROW_COUNT;

  WITH posted_shipper AS (
    SELECT
      s.id AS snapshot_id,
      s.source_id AS original_source_id,
      s.order_id,
      s.order_ref::text AS order_ref,
      COALESCE(s.reference_text, s.sage_invoice_id, s.id::text)::text AS ref,
      NULLIF(s.resolved_payload #>> '{sage_header,date}', '')::date AS tax_date,
      s.sage_invoice_id,
      line.ordinality::integer AS line_no,
      line.value AS line_json,
      COALESCE(
        NULLIF(line.value->>'net_amount_gbp', '')::numeric,
        NULLIF(line.value->>'gross_amount_gbp', '')::numeric,
        NULLIF(line.value->>'total_line_amount_gbp', '')::numeric,
        NULLIF(line.value->>'unit_price_gbp', '')::numeric,
        s.amount_gbp,
        0
      )::numeric(18,2) AS net_gbp
    FROM public.sage_posting_snapshots s
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.resolved_payload->'resolved_lines', '[]'::jsonb)) WITH ORDINALITY AS line(value, ordinality)
    WHERE s.active = true
      AND s.sage_posting_status = 'posted'
      AND s.document_lane = 'shipper_ap'
      AND NULLIF(s.resolved_payload #>> '{sage_header,date}', '')::date
        BETWEEN v_run.period_start_date AND v_run.period_end_date
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
    box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
    natural_sage_covered, adjustment_required, adjustment_reason, status
  )
  SELECT
    p_vat_return_run_id,
    'shipper_ap_box7_net',
    'sage_posting_snapshots',
    r.snapshot_id,
    'shipper_ap:' || r.ref || ':line:' || r.line_no::text || ':box:7',
    to_jsonb(r),
    jsonb_build_object(
      'source', 'posted_shipper_ap_snapshot',
      'snapshot_id', r.snapshot_id,
      'original_source_id', r.original_source_id,
      'reference_text', r.ref,
      'order_ref', r.order_ref,
      'sage_invoice_id', r.sage_invoice_id,
      'sage_vat_date', r.tax_date,
      'line_json', r.line_json
    ),
    7,
    'natural',
    r.net_gbp,
    0,
    'sage_document_date_shipper_ap_net_zero_rated',
    r.tax_date,
    v_run.return_period_label,
    true,
    false,
    'platform_posted_shipper_ap_snapshot_sage_document_date',
    'active'
  FROM posted_shipper r
  WHERE r.net_gbp <> 0;

  GET DIAGNOSTICS v_shipper_lines = ROW_COUNT;

  WITH posted_cn AS (
    SELECT
      s.id AS snapshot_id,
      s.source_id AS original_source_id,
      s.order_id,
      s.order_ref::text AS order_ref,
      COALESCE(s.reference_text, s.sage_invoice_id, s.id::text)::text AS ref,
      NULLIF(s.resolved_payload #>> '{sage_header,date}', '')::date AS tax_date,
      s.sage_invoice_id,
      line.ordinality::integer AS line_no,
      line.value AS line_json,
      COALESCE(NULLIF(line.value->>'net_credit_gbp', '')::numeric, ABS(NULLIF(line.value->>'net_amount_gbp', '')::numeric), 0)::numeric(18,2) AS net_gbp,
      COALESCE(NULLIF(line.value->>'vat_credit_gbp', '')::numeric, ABS(NULLIF(line.value->>'vat_amount_gbp', '')::numeric), 0)::numeric(18,2) AS vat_gbp
    FROM public.sage_posting_snapshots s
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.resolved_payload->'resolved_lines', '[]'::jsonb)) WITH ORDINALITY AS line(value, ordinality)
    WHERE s.active = true
      AND s.sage_posting_status = 'posted'
      AND s.document_lane = 'supplier_credit_note'
      AND NULLIF(s.resolved_payload #>> '{sage_header,date}', '')::date
        BETWEEN v_run.period_start_date AND v_run.period_end_date
  ),
  cn_rows AS (
    SELECT *, 7 AS box_number, 'supplier_credit_note_box7_decrease' AS line_kind, net_gbp AS amount_gbp, 0::numeric AS vat_amount_gbp, 'sage_document_date_supplier_credit_note_net' AS basis
    FROM posted_cn WHERE net_gbp <> 0
    UNION ALL
    SELECT *, 4 AS box_number, 'supplier_credit_note_box4_decrease' AS line_kind, vat_gbp AS amount_gbp, vat_gbp AS vat_amount_gbp, 'sage_document_date_supplier_credit_note_vat' AS basis
    FROM posted_cn WHERE vat_gbp <> 0
  )
  INSERT INTO public.vat_return_run_lines (
    vat_return_run_id, line_kind, source_table, source_id, source_ref, source_json, source_lineage_json,
    box_number, direction, amount_gbp, vat_amount_gbp, vat_basis, tax_point_date, return_period_label,
    natural_sage_covered, adjustment_required, adjustment_reason, status
  )
  SELECT
    p_vat_return_run_id,
    r.line_kind,
    'sage_posting_snapshots',
    r.snapshot_id,
    'supplier_credit_note:' || r.ref || ':line:' || r.line_no::text || ':box:' || r.box_number::text,
    to_jsonb(r),
    jsonb_build_object(
      'source', 'posted_supplier_credit_note_snapshot',
      'snapshot_id', r.snapshot_id,
      'original_source_id', r.original_source_id,
      'reference_text', r.ref,
      'order_ref', r.order_ref,
      'sage_invoice_id', r.sage_invoice_id,
      'sage_vat_date', r.tax_date,
      'line_json', r.line_json
    ),
    r.box_number,
    'decrease',
    r.amount_gbp,
    r.vat_amount_gbp,
    r.basis,
    r.tax_date,
    v_run.return_period_label,
    true,
    false,
    'platform_posted_supplier_credit_note_snapshot_sage_document_date',
    'active'
  FROM cn_rows r;

  GET DIAGNOSTICS v_credit_lines = ROW_COUNT;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 4;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 7;

  UPDATE public.vat_return_runs
  SET expected_box4_gbp = v_box4,
      expected_box5_gbp = COALESCE(expected_box3_gbp, 0) - v_box4,
      expected_box7_gbp = v_box7,
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'supplier_goods_ap_box_lines', v_ap_lines,
        'shipper_ap_box7_lines', v_shipper_lines,
        'supplier_credit_note_box_lines', v_credit_lines,
        'purchase_source_refresh_version', '20260531_sage_document_date_basis_with_shipper_ap'
      ),
      updated_at = now()
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'supplier_goods_ap_box_lines', v_ap_lines,
    'shipper_ap_box7_lines', v_shipper_lines,
    'supplier_credit_note_box_lines', v_credit_lines,
    'expected_box4_gbp', v_box4,
    'expected_box7_gbp', v_box7,
    'date_basis', 'sage_document_date'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_purchase_source_lines_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_purchase_source_lines_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(p_vat_return_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_run record;
  v_staff_id uuid;
  v_purchase_refresh jsonb;
  v_box1 numeric(18,2) := 0;
  v_box2 numeric(18,2) := 0;
  v_box4 numeric(18,2) := 0;
  v_box6 numeric(18,2) := 0;
  v_box7 numeric(18,2) := 0;
BEGIN
  SELECT s.id INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type = 'admin'
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Admin-only VAT source snapshot refresh action.';
  END IF;

  SELECT * INTO v_run
  FROM public.vat_return_runs
  WHERE id = p_vat_return_run_id
  FOR UPDATE;

  IF v_run.id IS NULL THEN
    RAISE EXCEPTION 'VAT return run not found.';
  END IF;

  IF v_run.locked_at IS NOT NULL OR v_run.status IN (
    'admin_approved',
    'sage_adjustment_journals_pending',
    'sage_adjustment_journals_posted',
    'sage_return_review_required',
    'sage_return_submitted',
    'matched_to_sage_locked',
    'mismatch_needs_admin_review',
    'superseded'
  ) THEN
    RAISE EXCEPTION 'Cannot refresh VAT source snapshot for VAT run in status %.', v_run.status;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.vat_return_adjustment_journals j
    WHERE j.vat_return_run_id = p_vat_return_run_id
      AND COALESCE(j.status, '') IN (
        'platform_calculated',
        'dry_run_validated',
        'admin_approved',
        'posting_to_sage',
        'posted_to_sage',
        'included_in_sage_return'
      )
  ) THEN
    RAISE EXCEPTION 'Cannot refresh VAT source snapshot after adjustment journals have been prepared, approved or posted.';
  END IF;

  v_purchase_refresh := public.staff_refresh_vat_purchase_source_lines_v1(p_vat_return_run_id);

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box1
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 1;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box2
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 2;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box4
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 4;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box6
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 6;

  SELECT COALESCE(sum(CASE WHEN direction IN ('natural','increase') THEN amount_gbp WHEN direction = 'decrease' THEN -amount_gbp ELSE 0 END), 0)
  INTO v_box7
  FROM public.vat_return_run_lines
  WHERE vat_return_run_id = p_vat_return_run_id
    AND status = 'active'
    AND box_number = 7;

  UPDATE public.vat_return_runs
  SET expected_box1_gbp = v_box1,
      expected_box2_gbp = v_box2,
      expected_box3_gbp = v_box1 + v_box2,
      expected_box4_gbp = v_box4,
      expected_box5_gbp = (v_box1 + v_box2) - v_box4,
      expected_box6_gbp = v_box6,
      expected_box7_gbp = v_box7,
      expected_box8_gbp = COALESCE(expected_box8_gbp, 0),
      expected_box9_gbp = COALESCE(expected_box9_gbp, 0),
      source_counts_json = COALESCE(source_counts_json, '{}'::jsonb) || jsonb_build_object(
        'source_snapshot_refresh_version', '20260531_sage_document_date_basis_with_shipper_ap',
        'purchase_refresh', v_purchase_refresh
      ),
      updated_at = now()
  WHERE id = p_vat_return_run_id;

  RETURN jsonb_build_object(
    'vat_return_run_id', p_vat_return_run_id,
    'expected_box1_gbp', v_box1,
    'expected_box2_gbp', v_box2,
    'expected_box3_gbp', v_box1 + v_box2,
    'expected_box4_gbp', v_box4,
    'expected_box5_gbp', (v_box1 + v_box2) - v_box4,
    'expected_box6_gbp', v_box6,
    'expected_box7_gbp', v_box7,
    'purchase_refresh', v_purchase_refresh
  );
END;
$$;

REVOKE ALL ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_refresh_vat_return_source_snapshot_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
