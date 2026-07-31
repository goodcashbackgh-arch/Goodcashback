BEGIN;

-- Main-bank shipper cash workbench restoration v1.
-- Preservation-first forward repair: restore only the omitted shipper row family.
-- Do not replace the current private pre-refund workbench implementation,
-- freeze/batch RPCs, payload normalisers, Sage posters, or applied reversal controls.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $guard$
BEGIN
  IF to_regclass('public.main_bank_shipper_ap_allocations') IS NULL THEN RAISE EXCEPTION 'Missing public.main_bank_shipper_ap_allocations'; END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dva_statement_lines'; END IF;
  IF to_regclass('public.shipping_documents') IS NULL THEN RAISE EXCEPTION 'Missing public.shipping_documents'; END IF;
  IF to_regclass('public.shippers') IS NULL THEN RAISE EXCEPTION 'Missing public.shippers'; END IF;
  IF to_regclass('public.sage_posting_snapshots') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_posting_snapshots'; END IF;
  IF to_regclass('public.sage_posting_batch_rows') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_posting_batch_rows'; END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_party_mappings'; END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN RAISE EXCEPTION 'Missing public.sage_mapping_settings'; END IF;
  IF to_regprocedure('public.internal_has_accounting_admin_access_v1()') IS NULL THEN RAISE EXCEPTION 'Missing public.internal_has_accounting_admin_access_v1()'; END IF;
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(text,text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing preserved private cash workbench implementation';
  END IF;
  IF to_regprocedure('public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer)') IS NULL THEN
    RAISE EXCEPTION 'Missing canonical cash workbench wrapper';
  END IF;
  IF to_regprocedure('public.internal_retailer_refund_has_posted_settlement_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Missing canonical retailer-refund settlement gate';
  END IF;
END
$guard$;

-- Dedicated row producer for the historically supported shipper cash family.
-- It does not mutate any accounting object and does not duplicate any other
-- workbench family. Bank/contact/target ids are resolved dynamically.
CREATE OR REPLACE FUNCTION public.internal_main_bank_shipper_cash_workbench_rows_v1(
  p_direction text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 300,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  queue_row_id text,
  source_type text,
  source_id uuid,
  statement_line_id uuid,
  statement_id uuid,
  statement_date_text text,
  direction text,
  category text,
  counterparty_type text,
  counterparty_id uuid,
  counterparty_name text,
  order_id uuid,
  order_ref text,
  auth_ref text,
  reference_raw text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  matched_target_type text,
  matched_target_id uuid,
  matched_target_ref text,
  sage_contact_id text,
  sage_contact_name text,
  sage_bank_account_id text,
  target_sage_object_id text,
  posting_status text,
  blocker text,
  selectable boolean,
  detail_json jsonb,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_direction text := lower(COALESCE(NULLIF(trim(p_direction), ''), 'all'));
  v_category text := lower(COALESCE(NULLIF(trim(p_category), ''), 'all'));
  v_search text := lower(NULLIF(trim(COALESCE(p_search, '')), ''));
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 300), 1), 300);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: cash posting workbench requires auth.uid()';
  END IF;
  IF NOT public.internal_has_accounting_admin_access_v1() THEN
    RAISE EXCEPTION 'Accounting admin access required for cash posting workbench.';
  END IF;

  RETURN QUERY
  WITH cash_defaults AS (
    SELECT
      MAX(sms.sage_external_id) FILTER (
        WHERE sms.mapping_code = 'DVA_CASH_BANK_ACCOUNT'
          AND sms.is_active = true
      ) AS bank_account_id
    FROM public.sage_mapping_settings sms
  ), shipper_rows AS (
    SELECT
      ('cash:shipper_invoice_payment:' || a.id::text)::text AS queue_row_id,
      'main_bank_shipper_ap_allocation'::text AS source_type,
      a.id AS source_id,
      dsl.id AS statement_line_id,
      dsl.dva_statement_id AS statement_id,
      dsl.statement_date::text AS statement_date_text,
      'out'::text AS direction,
      'shipper_invoice_payment'::text AS category,
      'shipper'::text AS counterparty_type,
      sd.shipper_id AS counterparty_id,
      COALESCE(NULLIF(sh.name, ''), 'Shipper')::text AS counterparty_name,
      NULL::uuid AS order_id,
      sps.order_ref::text AS order_ref,
      COALESCE(NULLIF(dsl.auth_id_ref, ''), a.id::text)::text AS auth_ref,
      dsl.reference_raw::text AS reference_raw,
      dsl.amount_local_ccy::numeric AS amount_local,
      dsl.local_ccy::text AS local_currency,
      round(a.allocated_gbp_amount::numeric, 2) AS amount_gbp,
      'posted_shipper_purchase_invoice'::text AS matched_target_type,
      sd.id AS matched_target_id,
      COALESCE(NULLIF(sd.document_ref, ''), NULLIF(sps.reference_text, ''), sd.id::text)::text AS matched_target_ref,
      pm.sage_contact_id::text AS sage_contact_id,
      pm.sage_contact_display_name::text AS sage_contact_name,
      cd.bank_account_id::text AS sage_bank_account_id,
      COALESCE(
        NULLIF(a.sage_purchase_invoice_id, ''),
        NULLIF(sps.sage_invoice_id, ''),
        NULLIF(posted_batch.sage_object_id, '')
      )::text AS target_sage_object_id,
      CASE
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'blocked_missing_sage_bank_account'
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'blocked_missing_sage_contact'
        WHEN NULLIF(trim(COALESCE(a.sage_purchase_invoice_id, sps.sage_invoice_id, posted_batch.sage_object_id, '')), '') IS NULL THEN 'blocked_target_invoice_not_posted'
        WHEN round(COALESCE(a.allocated_gbp_amount, 0)::numeric, 2) <= 0 THEN 'blocked_invalid_amount'
        ELSE 'ready_to_freeze'
      END::text AS posting_status,
      CASE
        WHEN NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NULL THEN 'DVA_CASH_BANK_ACCOUNT mapping missing'
        WHEN NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NULL THEN 'shipper Sage contact mapping missing'
        WHEN NULLIF(trim(COALESCE(a.sage_purchase_invoice_id, sps.sage_invoice_id, posted_batch.sage_object_id, '')), '') IS NULL THEN 'matched shipper AP purchase invoice has not been posted to Sage'
        WHEN round(COALESCE(a.allocated_gbp_amount, 0)::numeric, 2) <= 0 THEN 'cash amount must be positive'
        ELSE NULL::text
      END AS blocker,
      (
        NULLIF(trim(COALESCE(cd.bank_account_id, '')), '') IS NOT NULL
        AND NULLIF(trim(COALESCE(pm.sage_contact_id, '')), '') IS NOT NULL
        AND NULLIF(trim(COALESCE(a.sage_purchase_invoice_id, sps.sage_invoice_id, posted_batch.sage_object_id, '')), '') IS NOT NULL
        AND round(COALESCE(a.allocated_gbp_amount, 0)::numeric, 2) > 0
      ) AS selectable,
      jsonb_build_object(
        'allocation_id', a.id,
        'allocation_type', 'shipper_ap_payment',
        'statement_line_id', dsl.id,
        'shipping_document_id', sd.id,
        'shipper_id', sd.shipper_id,
        'shipper_invoice_ref', COALESCE(NULLIF(sd.document_ref, ''), NULLIF(sps.reference_text, ''), sd.id::text),
        'posting_category', 'shipper_invoice_payment',
        'target_sage_object_id', COALESCE(NULLIF(a.sage_purchase_invoice_id, ''), NULLIF(sps.sage_invoice_id, ''), NULLIF(posted_batch.sage_object_id, '')),
        'short_reference', ('GCB-OUT-' || left(COALESCE(NULLIF(sd.document_ref, ''), NULLIF(sps.reference_text, ''), a.id::text), 18)),
        'endpoint', 'POST /contact_payments · VENDOR_PAYMENT · allocated_artefacts',
        'bank_mapping_code', 'DVA_CASH_BANK_ACCOUNT'
      ) AS detail_json
    FROM public.main_bank_shipper_ap_allocations a
    JOIN public.dva_statement_lines dsl ON dsl.id = a.dva_statement_line_id
    JOIN public.shipping_documents sd ON sd.id = a.shipping_document_id
    LEFT JOIN public.shippers sh ON sh.id = sd.shipper_id
    LEFT JOIN public.sage_posting_snapshots sps ON sps.id = a.sage_posting_snapshot_id
    LEFT JOIN LATERAL (
      SELECT br.sage_object_id
      FROM public.sage_posting_batch_rows br
      WHERE br.snapshot_id = sps.id
        AND br.posting_status = 'posted'
        AND NULLIF(trim(COALESCE(br.sage_object_id, '')), '') IS NOT NULL
      ORDER BY br.posted_at DESC NULLS LAST, br.updated_at DESC NULLS LAST, br.created_at DESC
      LIMIT 1
    ) posted_batch ON true
    CROSS JOIN cash_defaults cd
    LEFT JOIN LATERAL (
      SELECT spm.sage_contact_id, spm.sage_contact_display_name
      FROM public.sage_party_mappings spm
      WHERE spm.platform_party_type = 'shipper'
        AND spm.platform_party_id = sd.shipper_id
        AND spm.active = true
      ORDER BY spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST
      LIMIT 1
    ) pm ON true
    WHERE a.allocation_status = 'confirmed'
  ), filtered AS (
    SELECT sr.*
    FROM shipper_rows sr
    WHERE (v_direction = 'all' OR lower(sr.direction) = v_direction)
      AND (v_category = 'all' OR lower(sr.category) = v_category)
      AND (
        v_search IS NULL
        OR lower(concat_ws(
          ' ',
          sr.counterparty_name,
          sr.order_ref,
          sr.auth_ref,
          sr.reference_raw,
          sr.matched_target_ref,
          sr.category,
          sr.source_type,
          sr.blocker,
          sr.detail_json->>'shipper_invoice_ref',
          sr.detail_json->>'bank_mapping_code'
        )) LIKE '%' || v_search || '%'
      )
  )
  SELECT
    f.queue_row_id,
    f.source_type,
    f.source_id,
    f.statement_line_id,
    f.statement_id,
    f.statement_date_text,
    f.direction,
    f.category,
    f.counterparty_type,
    f.counterparty_id,
    f.counterparty_name,
    f.order_id,
    f.order_ref,
    f.auth_ref,
    f.reference_raw,
    f.amount_local,
    f.local_currency,
    f.amount_gbp,
    f.matched_target_type,
    f.matched_target_id,
    f.matched_target_ref,
    f.sage_contact_id,
    f.sage_contact_name,
    f.sage_bank_account_id,
    f.target_sage_object_id,
    f.posting_status,
    f.blocker,
    f.selectable,
    f.detail_json,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date_text DESC NULLS LAST, f.counterparty_name, f.queue_row_id
  LIMIT v_limit OFFSET v_offset;
END;
$function$;

REVOKE ALL ON FUNCTION public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer) FROM anon;
REVOKE ALL ON FUNCTION public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer) FROM service_role;

COMMENT ON FUNCTION public.internal_main_bank_shipper_cash_workbench_rows_v1(text,text,text,integer,integer) IS
'Private preservation helper restoring confirmed main-bank shipper AP rows to the canonical cash workbench without changing other row families.';

-- Preserve the current retailer-refund wrapper behaviour and integrate only the
-- dedicated shipper row producer. The private pre-refund implementation remains
-- untouched. Existing base rows are explicitly projected without their old
-- total_count so the combined canonical result owns pagination/counting.
CREATE OR REPLACE FUNCTION public.internal_cash_posting_workbench_rows_v1(
  p_direction text DEFAULT 'all',
  p_category text DEFAULT 'all',
  p_status text DEFAULT 'all',
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  queue_row_id text,
  source_type text,
  source_id uuid,
  statement_line_id uuid,
  statement_id uuid,
  statement_date_text text,
  direction text,
  category text,
  counterparty_type text,
  counterparty_id uuid,
  counterparty_name text,
  order_id uuid,
  order_ref text,
  auth_ref text,
  reference_raw text,
  amount_local numeric,
  local_currency text,
  amount_gbp numeric,
  matched_target_type text,
  matched_target_id uuid,
  matched_target_ref text,
  sage_contact_id text,
  sage_contact_name text,
  sage_bank_account_id text,
  target_sage_object_id text,
  posting_status text,
  blocker text,
  selectable boolean,
  detail_json jsonb,
  total_count bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  WITH base_rows AS (
    SELECT
      b.queue_row_id,
      b.source_type,
      b.source_id,
      b.statement_line_id,
      b.statement_id,
      b.statement_date_text,
      b.direction,
      b.category,
      b.counterparty_type,
      b.counterparty_id,
      b.counterparty_name,
      b.order_id,
      b.order_ref,
      b.auth_ref,
      b.reference_raw,
      b.amount_local,
      b.local_currency,
      b.amount_gbp,
      b.matched_target_type,
      b.matched_target_id,
      b.matched_target_ref,
      b.sage_contact_id,
      b.sage_contact_name,
      b.sage_bank_account_id,
      b.target_sage_object_id,
      b.posting_status,
      b.blocker,
      b.selectable,
      b.detail_json
    FROM public.internal_cash_posting_workbench_rows_pre_refund_readiness_v1(
      p_direction,
      p_category,
      'all',
      p_search,
      300,
      0
    ) b
  ), shipper_rows AS (
    SELECT
      s.queue_row_id,
      s.source_type,
      s.source_id,
      s.statement_line_id,
      s.statement_id,
      s.statement_date_text,
      s.direction,
      s.category,
      s.counterparty_type,
      s.counterparty_id,
      s.counterparty_name,
      s.order_id,
      s.order_ref,
      s.auth_ref,
      s.reference_raw,
      s.amount_local,
      s.local_currency,
      s.amount_gbp,
      s.matched_target_type,
      s.matched_target_id,
      s.matched_target_ref,
      s.sage_contact_id,
      s.sage_contact_name,
      s.sage_bank_account_id,
      s.target_sage_object_id,
      s.posting_status,
      s.blocker,
      s.selectable,
      s.detail_json
    FROM public.internal_main_bank_shipper_cash_workbench_rows_v1(
      p_direction,
      p_category,
      p_search,
      300,
      0
    ) s
  ), combined_rows AS (
    SELECT * FROM base_rows
    UNION ALL
    SELECT s.*
    FROM shipper_rows s
    WHERE NOT EXISTS (
      SELECT 1
      FROM base_rows b
      WHERE b.source_type = 'main_bank_shipper_ap_allocation'
        AND b.category = 'shipper_invoice_payment'
        AND b.source_id = s.source_id
    )
  ), resolved AS (
    SELECT
      b.queue_row_id,
      b.source_type,
      b.source_id,
      b.statement_line_id,
      b.statement_id,
      b.statement_date_text,
      b.direction,
      b.category,
      b.counterparty_type,
      b.counterparty_id,
      b.counterparty_name,
      b.order_id,
      b.order_ref,
      b.auth_ref,
      b.reference_raw,
      b.amount_local,
      b.local_currency,
      b.amount_gbp,
      b.matched_target_type,
      b.matched_target_id,
      b.matched_target_ref,
      b.sage_contact_id,
      b.sage_contact_name,
      b.sage_bank_account_id,
      b.target_sage_object_id,
      CASE
        WHEN b.category = 'retailer_refund_received'
         AND b.direction = 'in'
         AND public.internal_retailer_refund_has_posted_settlement_v1(b.source_id)
          THEN 'ready_to_freeze'
        ELSE b.posting_status
      END::text AS posting_status,
      CASE
        WHEN b.category = 'retailer_refund_received'
         AND b.direction = 'in'
         AND public.internal_retailer_refund_has_posted_settlement_v1(b.source_id)
          THEN NULL::text
        ELSE b.blocker
      END::text AS blocker,
      CASE
        WHEN b.category = 'retailer_refund_received'
         AND b.direction = 'in'
         AND public.internal_retailer_refund_has_posted_settlement_v1(b.source_id)
          THEN true
        ELSE b.selectable
      END AS selectable,
      CASE
        WHEN b.category = 'retailer_refund_received'
         AND b.direction = 'in'
         AND public.internal_retailer_refund_has_posted_settlement_v1(b.source_id)
          THEN COALESCE(b.detail_json, '{}'::jsonb) || jsonb_build_object(
            'settlement_gate', 'internal_retailer_refund_has_posted_settlement_v1',
            'settlement_gate_passed', true
          )
        ELSE b.detail_json
      END AS detail_json
    FROM combined_rows b
  ), filtered AS (
    SELECT r.*
    FROM resolved r
    WHERE lower(COALESCE(NULLIF(trim(p_status), ''), 'all')) = 'all'
       OR lower(r.posting_status) = lower(trim(p_status))
       OR (lower(trim(p_status)) = 'blocked' AND lower(r.posting_status) LIKE 'blocked%')
       OR (lower(trim(p_status)) = 'ready' AND lower(r.posting_status) = 'ready_to_freeze')
  )
  SELECT
    f.queue_row_id,
    f.source_type,
    f.source_id,
    f.statement_line_id,
    f.statement_id,
    f.statement_date_text,
    f.direction,
    f.category,
    f.counterparty_type,
    f.counterparty_id,
    f.counterparty_name,
    f.order_id,
    f.order_ref,
    f.auth_ref,
    f.reference_raw,
    f.amount_local,
    f.local_currency,
    f.amount_gbp,
    f.matched_target_type,
    f.matched_target_id,
    f.matched_target_ref,
    f.sage_contact_id,
    f.sage_contact_name,
    f.sage_bank_account_id,
    f.target_sage_object_id,
    f.posting_status,
    f.blocker,
    f.selectable,
    f.detail_json,
    count(*) over() AS total_count
  FROM filtered f
  ORDER BY f.statement_date_text DESC NULLS LAST, f.category, f.counterparty_name, f.queue_row_id
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 300)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$function$;

REVOKE ALL ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) TO service_role;

COMMENT ON FUNCTION public.internal_cash_posting_workbench_rows_v1(text,text,text,text,integer,integer) IS
'Canonical cash-posting workbench. Preserves the private pre-refund row families and retailer-refund readiness logic, and restores the historical main-bank shipper AP cash row family through a dedicated helper.';

NOTIFY pgrst, 'reload schema';

COMMIT;
