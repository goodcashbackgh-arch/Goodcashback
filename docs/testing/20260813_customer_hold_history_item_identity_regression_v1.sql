-- CUSTOMER HOLD HISTORY ITEM IDENTITY REGRESSION v1
-- Governing authority:
-- docs/governing-pack/ui/CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1.md
-- Sections 16-17 only.
-- READ ONLY: no application-state writes and no RPC execution.
--
-- NOTE: md5(prosrc) is reported diagnostically only. It is intentionally not a
-- PASS/FAIL gate because SQL clients can preserve different line-ending/source
-- byte representations while PostgreSQL executes identical PL/pgSQL logic.
-- Correctness is therefore proved below from the stored function definition,
-- protected control shape, security metadata, and the exact live fixture.

BEGIN TRANSACTION READ ONLY;

DO $$
DECLARE
  v_fn_oid oid := to_regprocedure('public.customer_pre_shipment_hold_review_v1(text)');
  v_ready_oid oid := to_regprocedure('public.customer_review_ready_line_ids_v1(uuid)');
  v_fn_def text;
  v_body_hash text;
  v_security_definer boolean;
  v_config text[];
  v_owner text;
  v_hold_count integer;
  v_ready_count integer;
  v_description text;
  v_qty numeric;
  v_amount numeric;
  v_status text;
  v_reason text;
  v_line_id uuid;
  v_dispute_id uuid;
BEGIN
  IF v_fn_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_pre_shipment_hold_review_v1(text) is missing';
  END IF;

  IF v_ready_oid IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_review_ready_line_ids_v1(uuid) is missing';
  END IF;

  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN
    RAISE EXCEPTION 'FAIL: customer_review_cycle_memberships is missing';
  END IF;

  SELECT pg_get_functiondef(v_fn_oid), md5(p.prosrc), p.prosecdef, p.proconfig, pg_get_userbyid(p.proowner)
    INTO v_fn_def, v_body_hash, v_security_definer, v_config, v_owner
  FROM pg_proc p
  WHERE p.oid = v_fn_oid;

  -- Security/ownership/access are protected non-change controls.
  IF v_security_definer IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL: customer review RPC is no longer SECURITY DEFINER';
  END IF;

  IF NOT ('search_path=public, pg_temp' = ANY(COALESCE(v_config, ARRAY[]::text[]))) THEN
    RAISE EXCEPTION 'FAIL: customer review RPC search_path changed: %', v_config;
  END IF;

  IF v_owner IS DISTINCT FROM 'postgres' THEN
    RAISE EXCEPTION 'FAIL: customer review RPC owner changed: %', v_owner;
  END IF;

  IF NOT has_function_privilege('anon', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon lost EXECUTE on customer review RPC';
  END IF;

  IF NOT has_function_privilege('authenticated', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on customer review RPC';
  END IF;

  IF NOT has_function_privilege('service_role', v_fn_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role lost EXECUTE on customer review RPC';
  END IF;

  -- Existing review-link resolution and audit touch must remain unchanged.
  IF position('SELECT link_row.id, link_row.order_id, link_row.expires_at' in v_fn_def) = 0
     OR position('link_row.secure_token = p_secure_token' in v_fn_def) = 0
     OR position('link_row.is_active = true' in v_fn_def) = 0
     OR position('(link_row.expires_at IS NULL OR link_row.expires_at > now())' in v_fn_def) = 0
     OR position('UPDATE public.customer_order_review_links' in v_fn_def) = 0
     OR position('SET last_used_at = now()' in v_fn_def) = 0
     OR position('WHERE id = v_link_id' in v_fn_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: protected review-link resolution or last_used_at behaviour changed';
  END IF;

  -- Existing order payload shape must remain present.
  IF position('''id'', order_row.id' in v_fn_def) = 0
     OR position('''order_ref'', order_row.order_ref' in v_fn_def) = 0
     OR position('''retailer_name'', retailer_row.name' in v_fn_def) = 0
     OR position('''status'', order_row.status' in v_fn_def) = 0
     OR position('''order_type'', order_row.order_type' in v_fn_def) = 0
     OR position('''total_qty_declared'', order_row.total_qty_declared' in v_fn_def) = 0
     OR position('''tracking'', ''[]''::jsonb' in v_fn_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: existing customer review order payload shape changed';
  END IF;

  -- Protected live review-cycle selection must remain exact in shape:
  -- timed links use immutable active memberships for this exact review link;
  -- legacy untimed links retain the existing ready-line fallback only.
  IF position('v_expires_at timestamptz' in v_fn_def) = 0
     OR position('WITH timed_lines AS (' in v_fn_def) = 0
     OR position('FROM public.customer_review_cycle_memberships membership' in v_fn_def) = 0
     OR position('membership.review_link_id = v_link_id' in v_fn_def) = 0
     OR position('membership.membership_status = ''active''' in v_fn_def) = 0
     OR position('v_expires_at IS NOT NULL' in v_fn_def) = 0
     OR position('legacy_lines AS (' in v_fn_def) = 0
     OR position('FROM public.customer_review_ready_line_ids_v1(v_order_id) ready_line' in v_fn_def) = 0
     OR position('WHERE v_expires_at IS NULL' in v_fn_def) = 0
     OR position('review_lines AS (' in v_fn_def) = 0
     OR position('SELECT * FROM timed_lines' in v_fn_def) = 0
     OR position('UNION' in v_fn_def) = 0
     OR position('SELECT * FROM legacy_lines' in v_fn_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: protected immutable timed-review / legacy fallback selection changed';
  END IF;

  -- Existing current-line payload and ordering must remain unchanged.
  IF position('''id'', supplier_line.id' in v_fn_def) = 0
     OR position('''description'', supplier_line.description' in v_fn_def) = 0
     OR position('''size'', supplier_line.size' in v_fn_def) = 0
     OR position('''retailer_sku'', supplier_line.retailer_sku' in v_fn_def) = 0
     OR position('''qty'', supplier_line.qty' in v_fn_def) = 0
     OR position('''amount_inc_vat_gbp'', supplier_line.amount_inc_vat_gbp' in v_fn_def) = 0
     OR position('''tracking_submission_id'', review_line.tracking_submission_id' in v_fn_def) = 0
     OR position('''eligible_for_invoice_yn'', supplier_line.eligible_for_invoice_yn' in v_fn_def) = 0
     OR position('ORDER BY supplier_line.created_at NULLS LAST, supplier_line.id' in v_fn_def) = 0
     OR position('ON supplier_line.id = review_line.supplier_invoice_line_id' in v_fn_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: existing current review-line payload or ordering changed';
  END IF;

  -- Existing hold keys must remain unchanged.
  IF position('''id'', hold_row.id' in v_fn_def) = 0
     OR position('''requested_scope'', hold_row.requested_scope' in v_fn_def) = 0
     OR position('''tracking_submission_id'', hold_row.tracking_submission_id' in v_fn_def) = 0
     OR position('''supplier_invoice_line_id'', hold_row.supplier_invoice_line_id' in v_fn_def) = 0
     OR position('''narrowed_from_hold_request_id'', hold_row.narrowed_from_hold_request_id' in v_fn_def) = 0
     OR position('''converted_dispute_id'', hold_row.converted_dispute_id' in v_fn_def) = 0
     OR position('''status'', hold_row.status' in v_fn_def) = 0
     OR position('''reason'', hold_row.reason' in v_fn_def) = 0
     OR position('''created_at'', hold_row.created_at' in v_fn_def) = 0
     OR position('''supervisor_review_note'', hold_row.supervisor_review_note' in v_fn_def) = 0
     OR position('ORDER BY hold_row.created_at DESC' in v_fn_def) = 0
     OR position('WHERE hold_row.order_id = order_row.id' in v_fn_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: an existing hold payload key, filter, or ordering changed';
  END IF;

  -- Only authorised history enrichment: direct hold-line FK plus three fields.
  IF position('''line_description'', hold_line.description' in v_fn_def) = 0
     OR position('''line_qty'', hold_line.qty' in v_fn_def) = 0
     OR position('''line_amount_inc_vat_gbp'', hold_line.amount_inc_vat_gbp' in v_fn_def) = 0
     OR position('LEFT JOIN public.supplier_invoice_lines hold_line' in v_fn_def) = 0
     OR position('hold_line.id = hold_row.supplier_invoice_line_id' in v_fn_def) = 0 THEN
    RAISE EXCEPTION 'FAIL: governed historical hold identity enrichment is missing or mis-sourced';
  END IF;

  -- No hold lifecycle or immutable membership mutation is authorised.
  IF v_fn_def ~* '(insert[[:space:]]+into|update|delete[[:space:]]+from)[[:space:]]+public[.]customer_pre_shipment_hold_requests' THEN
    RAISE EXCEPTION 'FAIL: customer review RPC contains prohibited hold-table DML';
  END IF;

  IF v_fn_def ~* '(insert[[:space:]]+into|update|delete[[:space:]]+from)[[:space:]]+public[.]customer_review_cycle_memberships' THEN
    RAISE EXCEPTION 'FAIL: customer review RPC contains prohibited review-membership DML';
  END IF;

  -- Exact historical fixture: underlying hold state and provenance remain intact.
  SELECT count(*)::integer
    INTO v_hold_count
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.id = 'f815a08d-afe9-4f86-98ed-67dc8f81a9af'::uuid
    AND h.order_id = 'a40fe4a1-7f49-4766-9332-4b14056608ff'::uuid;

  IF v_hold_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: regression hold fixture missing or duplicated';
  END IF;

  SELECT
    h.status::text,
    h.reason,
    h.supplier_invoice_line_id,
    h.converted_dispute_id,
    sil.description::text,
    sil.qty::numeric,
    sil.amount_inc_vat_gbp::numeric
  INTO
    v_status,
    v_reason,
    v_line_id,
    v_dispute_id,
    v_description,
    v_qty,
    v_amount
  FROM public.customer_pre_shipment_hold_requests h
  LEFT JOIN public.supplier_invoice_lines sil
    ON sil.id = h.supplier_invoice_line_id
  WHERE h.id = 'f815a08d-afe9-4f86-98ed-67dc8f81a9af'::uuid
    AND h.order_id = 'a40fe4a1-7f49-4766-9332-4b14056608ff'::uuid;

  IF v_status IS DISTINCT FROM 'resolved' THEN
    RAISE EXCEPTION 'FAIL: hold status changed; expected resolved, got %', v_status;
  END IF;

  IF v_reason IS DISTINCT FROM 'Wrong item' THEN
    RAISE EXCEPTION 'FAIL: hold reason changed; expected Wrong item, got %', v_reason;
  END IF;

  IF v_line_id IS DISTINCT FROM '2be4ba9f-3e11-4184-999b-9666b2957763'::uuid THEN
    RAISE EXCEPTION 'FAIL: historical supplier_invoice_line_id changed: %', v_line_id;
  END IF;

  IF v_dispute_id IS DISTINCT FROM 'df97ea23-00fa-4808-8b43-2eafd21b99e2'::uuid THEN
    RAISE EXCEPTION 'FAIL: converted dispute linkage changed: %', v_dispute_id;
  END IF;

  IF v_description IS DISTINCT FROM 'Ninja Foodi MAX Dual Zone Air Fryer - review/hold item' THEN
    RAISE EXCEPTION 'FAIL: historical item description is not joinable: %', v_description;
  END IF;

  IF v_qty IS DISTINCT FROM 1::numeric THEN
    RAISE EXCEPTION 'FAIL: historical item qty changed: %', v_qty;
  END IF;

  IF v_amount IS DISTINCT FROM 249.99::numeric THEN
    RAISE EXCEPTION 'FAIL: historical item amount changed: %', v_amount;
  END IF;

  SELECT count(*)::integer
    INTO v_ready_count
  FROM public.customer_review_ready_line_ids_v1('a40fe4a1-7f49-4766-9332-4b14056608ff'::uuid) rl
  WHERE rl.supplier_invoice_line_id = '2be4ba9f-3e11-4184-999b-9666b2957763'::uuid;

  IF v_ready_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: resolved historical line was reintroduced to current review-ready membership';
  END IF;
END $$;

SELECT jsonb_build_object(
  '00_verdict', 'PASS — CUSTOMER HOLD HISTORY ITEM IDENTITY REGRESSION',
  '01_write_safety', 'READ ONLY — NO RPC EXECUTED — NO APPLICATION STATE WRITES',
  '02_governing_authority', 'CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1 sections 16-17',
  '03_fixture', jsonb_build_object(
    'order_ref', o.order_ref,
    'hold_request_id', h.id,
    'status', h.status,
    'reason', h.reason,
    'supplier_invoice_line_id', h.supplier_invoice_line_id,
    'line_description', sil.description,
    'line_qty', sil.qty,
    'line_amount_inc_vat_gbp', sil.amount_inc_vat_gbp,
    'currently_review_ready', EXISTS (
      SELECT 1
      FROM public.customer_review_ready_line_ids_v1(h.order_id) rl
      WHERE rl.supplier_invoice_line_id = h.supplier_invoice_line_id
    )
  ),
  '04_function', jsonb_build_object(
    'body_hash_diagnostic_only', md5(p.prosrc),
    'owner', pg_get_userbyid(p.proowner),
    'security_definer', p.prosecdef,
    'function_config', p.proconfig,
    'function_acl', p.proacl,
    'anon_can_execute', has_function_privilege('anon', p.oid, 'EXECUTE'),
    'authenticated_can_execute', has_function_privilege('authenticated', p.oid, 'EXECUTE'),
    'service_role_can_execute', has_function_privilege('service_role', p.oid, 'EXECUTE'),
    'preserves_review_link_resolution', position('SELECT link_row.id, link_row.order_id, link_row.expires_at' in pg_get_functiondef(p.oid)) > 0,
    'preserves_last_used_at', position('SET last_used_at = now()' in pg_get_functiondef(p.oid)) > 0,
    'preserves_timed_memberships', position('FROM public.customer_review_cycle_memberships membership' in pg_get_functiondef(p.oid)) > 0,
    'preserves_legacy_ready_fallback', position('FROM public.customer_review_ready_line_ids_v1(v_order_id) ready_line' in pg_get_functiondef(p.oid)) > 0,
    'has_line_description_key', position('''line_description''' in pg_get_functiondef(p.oid)) > 0,
    'has_line_qty_key', position('''line_qty''' in pg_get_functiondef(p.oid)) > 0,
    'has_line_amount_key', position('''line_amount_inc_vat_gbp''' in pg_get_functiondef(p.oid)) > 0
  )
) AS customer_hold_history_item_identity_regression
FROM public.customer_pre_shipment_hold_requests h
JOIN public.orders o ON o.id = h.order_id
LEFT JOIN public.supplier_invoice_lines sil ON sil.id = h.supplier_invoice_line_id
JOIN pg_proc p ON p.oid = to_regprocedure('public.customer_pre_shipment_hold_review_v1(text)')
WHERE h.id = 'f815a08d-afe9-4f86-98ed-67dc8f81a9af'::uuid;

COMMIT;
