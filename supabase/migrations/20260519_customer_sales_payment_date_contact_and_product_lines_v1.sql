BEGIN;

-- Customer sales Sage payload hardening.
--
-- Fixes three posting-grade facts for customer sales invoices:
--   1. Contact ID comes from sage_party_mappings importer_customer mapping.
--   2. Invoice date comes from the order funding/payment statement date, not today's date.
--   3. Resolved sales invoice line descriptions prefer the underlying progressed supplier/retailer product lines.
--
-- No Sage API call. No posting. No mutation of source commercial invoices.

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.sales_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sales_invoices';
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: orders';
  END IF;
  IF to_regclass('public.sage_mapping_settings') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_mapping_settings';
  END IF;
  IF to_regclass('public.sage_party_mappings') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: sage_party_mappings';
  END IF;
  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: supplier_invoices';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: supplier_invoice_lines';
  END IF;
  IF to_regclass('public.dva_reconciliation') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dva_reconciliation';
  END IF;
  IF to_regclass('public.dva_statement_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: dva_statement_lines';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(
  p_sales_invoice_id uuid DEFAULT NULL
)
RETURNS TABLE (
  sales_invoice_id uuid,
  order_id uuid,
  order_ref text,
  document_lane text,
  document_type text,
  invoice_type text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  reference_text text,
  notes_text text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  commercial_payload jsonb,
  resolved_payload jsonb,
  mapping_snapshot jsonb,
  mapping_semantic_fingerprint text,
  payload_status text,
  blocker text,
  warning text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: customer sales Sage payload resolver requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for customer sales Sage payload resolver.';
  END IF;

  RETURN QUERY
  WITH mapping AS (
    SELECT
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'ZERO_RATED_EXPORT_TAX_RATE' AND sm.is_active = true AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL)::text AS zero_rated_export_tax_rate_id,
      MAX(sm.sage_display_name) FILTER (WHERE sm.mapping_code = 'ZERO_RATED_EXPORT_TAX_RATE' AND sm.is_active = true AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL)::text AS zero_rated_export_tax_rate_name,
      MAX(sm.configured_at) FILTER (WHERE sm.mapping_code = 'ZERO_RATED_EXPORT_TAX_RATE' AND sm.is_active = true AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL)::timestamptz AS zero_rated_export_tax_rate_configured_at,
      MAX(sm.sage_external_id) FILTER (WHERE sm.mapping_code = 'EXPORT_SALE_INCOME_LEDGER' AND sm.is_active = true AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL)::text AS export_sale_income_ledger_id,
      MAX(sm.sage_display_name) FILTER (WHERE sm.mapping_code = 'EXPORT_SALE_INCOME_LEDGER' AND sm.is_active = true AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL)::text AS export_sale_income_ledger_name,
      MAX(sm.configured_at) FILTER (WHERE sm.mapping_code = 'EXPORT_SALE_INCOME_LEDGER' AND sm.is_active = true AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL)::timestamptz AS export_sale_income_ledger_configured_at
    FROM public.sage_mapping_settings sm
    WHERE sm.mapping_code IN ('ZERO_RATED_EXPORT_TAX_RATE', 'EXPORT_SALE_INCOME_LEDGER')
  ), invoices AS (
    SELECT
      si.id,
      si.order_id,
      o.order_ref::text AS order_ref,
      si.invoice_type::text AS invoice_type,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Customer')::text AS counterparty_name,
      si.amount_gbp::numeric AS amount_gbp,
      si.sage_status::text AS sage_status,
      si.sage_invoice_id::text AS sage_invoice_id,
      si.sage_posted_at::timestamptz AS sage_posted_at,
      COALESCE(si.line_items_json, '{}'::jsonb) AS commercial_payload,
      COALESCE(si.line_items_json #>> '{sage_header,reference}', o.order_ref::text, si.id::text)::text AS reference_text,
      COALESCE(si.line_items_json #>> '{sage_header,notes}', '')::text AS notes_text,
      i.id AS importer_id,
      COALESCE(NULLIF(i.trading_name, ''), i.company_name, 'Customer')::text AS importer_display_name
    FROM public.sales_invoices si
    LEFT JOIN public.orders o ON o.id = si.order_id
    LEFT JOIN public.importers i ON i.id = o.importer_id
    WHERE p_sales_invoice_id IS NULL OR si.id = p_sales_invoice_id
  ), party AS (
    SELECT DISTINCT ON (inv.id)
      inv.id AS sales_invoice_id,
      spm.id AS sage_party_mapping_id,
      spm.sage_contact_id::text AS sage_contact_id,
      spm.sage_contact_display_name::text AS sage_contact_display_name,
      spm.sage_contact_reference::text AS sage_contact_reference,
      spm.sage_contact_type::text AS sage_contact_type,
      spm.verified_at AS sage_contact_verified_at,
      spm.sage_business_id::text AS sage_business_id,
      spm.sage_business_row_id::text AS sage_business_row_id,
      spm.sage_connection_id::text AS sage_connection_id
    FROM invoices inv
    LEFT JOIN public.sage_party_mappings spm
      ON spm.platform_party_type = 'importer_customer'
     AND spm.platform_party_id = inv.importer_id
     AND spm.active = true
    ORDER BY inv.id, spm.verified_at DESC NULLS LAST, spm.updated_at DESC NULLS LAST, spm.created_at DESC NULLS LAST
  ), payment_dates AS (
    SELECT
      inv.id AS sales_invoice_id,
      MAX(COALESCE(dsl.statement_date, dr.reconciled_at::date))::date AS payment_date,
      COUNT(dr.id)::integer AS funding_match_count,
      jsonb_agg(jsonb_build_object(
        'dva_reconciliation_id', dr.id,
        'dva_statement_line_id', dsl.id,
        'statement_date', dsl.statement_date,
        'reconciled_at', dr.reconciled_at,
        'reconciled_gbp_amount', dr.reconciled_gbp_amount,
        'reference_raw', dsl.reference_raw,
        'auth_id_ref', dsl.auth_id_ref
      ) ORDER BY COALESCE(dsl.statement_date, dr.reconciled_at::date), dr.reconciled_at, dr.id) FILTER (WHERE dr.id IS NOT NULL) AS funding_source_rows
    FROM invoices inv
    LEFT JOIN public.dva_reconciliation dr
      ON dr.order_id = inv.order_id
     AND dr.reconciliation_type = 'order_funding'
    LEFT JOIN public.dva_statement_lines dsl
      ON dsl.id = dr.dva_statement_line_id
    GROUP BY inv.id
  ), supplier_source_lines AS (
    SELECT
      inv.id AS sales_invoice_id,
      sil.id AS supplier_invoice_line_id,
      COALESCE(NULLIF(BTRIM(sil.description), ''), 'Goods')::text AS description,
      COALESCE(NULLIF(sil.qty_confirmed, 0), NULLIF(sil.qty, 0), 1)::numeric AS quantity,
      COALESCE(NULLIF(sil.amount_confirmed, 0), sil.amount_inc_vat_gbp, 0)::numeric(18,2) AS line_amount_gbp,
      COALESCE(sil.line_order, 999999)::integer AS sort_order
    FROM invoices inv
    JOIN public.supplier_invoices si2
      ON si2.order_id = inv.order_id
     AND (si2.review_status IN ('approved_current', 'ref_corrected_approved') OR COALESCE(si2.is_current_for_order, false) = true)
     AND COALESCE(si2.blocked_from_sage_yn, false) IS DISTINCT FROM true
    JOIN public.supplier_invoice_lines sil
      ON sil.supplier_invoice_id = si2.id
    WHERE lower(trim(COALESCE(sil.eligible_for_invoice_yn, 'Y'))) IN ('y','yes','true','1')
      AND COALESCE(NULLIF(sil.amount_confirmed, 0), sil.amount_inc_vat_gbp, 0) > 0
  ), supplier_line_totals AS (
    SELECT
      ssl.sales_invoice_id,
      COUNT(*)::integer AS source_line_count,
      ROUND(COALESCE(SUM(ssl.line_amount_gbp), 0)::numeric, 2) AS source_line_total_gbp,
      jsonb_agg(jsonb_build_object(
        'line_kind', 'customer_sales_from_supplier_invoice_line',
        'source_supplier_invoice_line_id', ssl.supplier_invoice_line_id,
        'source_description', ssl.description,
        'description', ssl.description,
        'quantity', ssl.quantity,
        'unit_price_gbp', CASE WHEN ssl.quantity IS NULL OR ssl.quantity = 0 THEN ssl.line_amount_gbp ELSE ROUND((ssl.line_amount_gbp / ssl.quantity)::numeric, 2) END,
        'total_line_amount_gbp', ssl.line_amount_gbp,
        'ledger_account_role', 'export_sale_income',
        'customer_gl_role', 'export_sale_income',
        'presentation', 'principal_export_sale_line_from_progressed_supplier_goods',
        'source', 'supplier_invoice_lines'
      ) ORDER BY ssl.sort_order, ssl.description, ssl.supplier_invoice_line_id) AS supplier_resolved_lines
    FROM supplier_source_lines ssl
    GROUP BY ssl.sales_invoice_id
  ), fallback_lines AS (
    SELECT
      inv.id AS sales_invoice_id,
      jsonb_agg(
        CASE
          WHEN jsonb_typeof(line.value) = 'object' THEN line.value
          ELSE jsonb_build_object(
            'line_kind', 'customer_sales_commercial_payload_line',
            'description', line.value::text,
            'quantity', 1,
            'total_line_amount_gbp', 0,
            'ledger_account_role', 'export_sale_income',
            'source', 'sales_invoices.line_items_json'
          )
        END
        ORDER BY line.ordinality
      ) AS commercial_lines
    FROM invoices inv
    LEFT JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(inv.commercial_payload->'lines') = 'array' THEN inv.commercial_payload->'lines'
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS line(value, ordinality) ON true
    GROUP BY inv.id
  ), chosen_lines AS (
    SELECT
      inv.id AS sales_invoice_id,
      CASE
        WHEN COALESCE(slt.source_line_count, 0) > 0
         AND ABS(COALESCE(slt.source_line_total_gbp, 0) - COALESCE(inv.amount_gbp, 0)) <= 0.01
        THEN slt.supplier_resolved_lines
        ELSE COALESCE(fl.commercial_lines, '[]'::jsonb)
      END AS base_lines,
      CASE
        WHEN COALESCE(slt.source_line_count, 0) > 0
         AND ABS(COALESCE(slt.source_line_total_gbp, 0) - COALESCE(inv.amount_gbp, 0)) <= 0.01
        THEN 'supplier_invoice_lines_matched_to_sales_invoice_total'
        WHEN COALESCE(slt.source_line_count, 0) > 0
        THEN 'supplier_invoice_lines_total_did_not_match_sales_invoice_amount_fallback_to_commercial_payload'
        ELSE 'commercial_payload_lines_only'
      END::text AS line_resolution_source,
      slt.source_line_count,
      slt.source_line_total_gbp
    FROM invoices inv
    LEFT JOIN supplier_line_totals slt ON slt.sales_invoice_id = inv.id
    LEFT JOIN fallback_lines fl ON fl.sales_invoice_id = inv.id
  ), resolved_lines AS (
    SELECT
      cl.sales_invoice_id,
      cl.line_resolution_source,
      cl.source_line_count,
      cl.source_line_total_gbp,
      jsonb_agg(
        CASE
          WHEN jsonb_typeof(line.value) = 'object' THEN
            line.value
            || jsonb_build_object(
              'resolved_tax_rate_id', m.zero_rated_export_tax_rate_id,
              'resolved_tax_rate_display', m.zero_rated_export_tax_rate_name,
              'resolved_ledger_account_id', m.export_sale_income_ledger_id,
              'resolved_ledger_account_display', m.export_sale_income_ledger_name,
              'resolver_ledger_account_role', COALESCE(line.value->>'ledger_account_role', 'export_sale_income'),
              'sage_tax_rate_id', m.zero_rated_export_tax_rate_id,
              'sage_tax_rate_display', m.zero_rated_export_tax_rate_name,
              'sage_ledger_account_id', m.export_sale_income_ledger_id,
              'sage_ledger_account_display', m.export_sale_income_ledger_name
            )
          ELSE line.value
        END
        ORDER BY line.ordinality
      ) AS resolved_lines
    FROM chosen_lines cl
    CROSS JOIN mapping m
    LEFT JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(cl.base_lines) = 'array' THEN cl.base_lines ELSE '[]'::jsonb END) WITH ORDINALITY AS line(value, ordinality) ON true
    GROUP BY cl.sales_invoice_id, cl.line_resolution_source, cl.source_line_count, cl.source_line_total_gbp
  )
  SELECT
    inv.id AS sales_invoice_id,
    inv.order_id,
    inv.order_ref,
    'customer_sales'::text AS document_lane,
    CASE
      WHEN inv.invoice_type = 'main' THEN 'customer_sales_invoice'
      WHEN inv.invoice_type = 'supplementary' THEN 'customer_supplementary_invoice'
      WHEN inv.invoice_type = 'credit_note' THEN 'customer_credit_note'
      ELSE ('customer_' || inv.invoice_type)
    END::text AS document_type,
    inv.invoice_type,
    inv.counterparty_name,
    inv.amount_gbp,
    'GBP'::text AS currency_code,
    inv.reference_text,
    inv.notes_text,
    inv.sage_status,
    inv.sage_invoice_id,
    inv.sage_posted_at,
    inv.commercial_payload,
    jsonb_build_object(
      'source', 'internal_resolved_customer_sales_sage_payload_v1',
      'source_table', 'sales_invoices',
      'source_id', inv.id,
      'source_order_id', inv.order_id,
      'source_order_ref', inv.order_ref,
      'document_lane', 'customer_sales',
      'document_type', CASE
        WHEN inv.invoice_type = 'main' THEN 'customer_sales_invoice'
        WHEN inv.invoice_type = 'supplementary' THEN 'customer_supplementary_invoice'
        WHEN inv.invoice_type = 'credit_note' THEN 'customer_credit_note'
        ELSE ('customer_' || inv.invoice_type)
      END,
      'commercial_payload', inv.commercial_payload,
      'sage_header', jsonb_build_object(
        'reference', inv.reference_text,
        'date', pd.payment_date,
        'invoice_date', pd.payment_date,
        'date_source', 'order_funding_final_payment_statement_date',
        'notes', inv.notes_text,
        'currency_code', 'GBP',
        'contact_id', party.sage_contact_id,
        'sage_contact_id', party.sage_contact_id
      ),
      'customer_target', jsonb_build_object(
        'platform_party_type', 'importer_customer',
        'platform_party_id', inv.importer_id,
        'importer_id', inv.importer_id,
        'display_name', inv.importer_display_name,
        'resolution_source', 'sage_party_mappings.importer_customer',
        'sage_party_mapping_id', party.sage_party_mapping_id,
        'sage_contact_id', party.sage_contact_id,
        'sage_contact_display_name', party.sage_contact_display_name,
        'sage_contact_reference', party.sage_contact_reference,
        'sage_contact_type', party.sage_contact_type,
        'sage_contact_verified_at', party.sage_contact_verified_at,
        'sage_business_id', party.sage_business_id,
        'sage_business_row_id', party.sage_business_row_id,
        'sage_connection_id', party.sage_connection_id
      ),
      'payment_date_resolution', jsonb_build_object(
        'invoice_date', pd.payment_date,
        'date_source', 'order_funding_final_payment_statement_date',
        'funding_match_count', COALESCE(pd.funding_match_count, 0),
        'funding_source_rows', COALESCE(pd.funding_source_rows, '[]'::jsonb)
      ),
      'line_resolution', jsonb_build_object(
        'source', rl.line_resolution_source,
        'source_line_count', COALESCE(rl.source_line_count, 0),
        'source_line_total_gbp', rl.source_line_total_gbp,
        'sales_invoice_amount_gbp', inv.amount_gbp
      ),
      'resolved_lines', COALESCE(rl.resolved_lines, '[]'::jsonb),
      'resolved_mappings', jsonb_build_object(
        'ZERO_RATED_EXPORT_TAX_RATE', jsonb_build_object(
          'mapping_code', 'ZERO_RATED_EXPORT_TAX_RATE',
          'sage_external_id', m.zero_rated_export_tax_rate_id,
          'sage_display_name', m.zero_rated_export_tax_rate_name,
          'configured_at', m.zero_rated_export_tax_rate_configured_at
        ),
        'EXPORT_SALE_INCOME_LEDGER', jsonb_build_object(
          'mapping_code', 'EXPORT_SALE_INCOME_LEDGER',
          'sage_external_id', m.export_sale_income_ledger_id,
          'sage_display_name', m.export_sale_income_ledger_name,
          'configured_at', m.export_sale_income_ledger_configured_at
        )
      ),
      'tax_resolution', jsonb_build_object(
        'tax_treatment', COALESCE(inv.commercial_payload #>> '{tax_resolution,tax_treatment}', 'zero_rated_export'),
        'display_vat_code', COALESCE(inv.commercial_payload #>> '{tax_resolution,display_vat_code}', 'zero-rated export'),
        'sage_tax_rate_id', m.zero_rated_export_tax_rate_id,
        'sage_tax_rate_display', m.zero_rated_export_tax_rate_name,
        'sage_tax_rate_resolution_required', m.zero_rated_export_tax_rate_id IS NULL
      ),
      'ledger_resolution', jsonb_build_object(
        'ledger_account_role', 'export_sale_income',
        'sage_ledger_account_id', m.export_sale_income_ledger_id,
        'sage_ledger_account_display', m.export_sale_income_ledger_name,
        'sage_ledger_resolution_required', m.export_sale_income_ledger_id IS NULL
      ),
      'resolver_control', jsonb_build_object(
        'status', CASE
          WHEN inv.sage_status = 'posted' AND inv.sage_invoice_id IS NULL AND inv.sage_posted_at IS NULL THEN 'internally_marked_posted_no_sage_confirmation'
          WHEN inv.sage_status = 'posted' THEN 'sage_confirmation_recorded'
          WHEN inv.sage_status = 'void' THEN 'voided_no_action'
          WHEN inv.sage_status = 'draft' AND party.sage_contact_id IS NULL THEN 'blocked_customer_sales_sage_contact_missing'
          WHEN inv.sage_status = 'draft' AND pd.payment_date IS NULL THEN 'blocked_customer_sales_payment_date_missing'
          WHEN inv.sage_status = 'draft' AND COALESCE(jsonb_array_length(COALESCE(rl.resolved_lines, '[]'::jsonb)), 0) = 0 THEN 'blocked_customer_sales_resolved_lines_missing'
          WHEN inv.sage_status = 'draft' AND (m.zero_rated_export_tax_rate_id IS NULL OR m.export_sale_income_ledger_id IS NULL) THEN 'blocked_sage_mapping_required'
          WHEN inv.sage_status = 'draft' THEN 'ready_for_sage_posting_preview'
          ELSE 'needs_review'
        END,
        'resolved_at', now(),
        'posting_payload_not_frozen', true,
        'freeze_required_before_posting', true
      )
    ) AS resolved_payload,
    jsonb_build_object(
      'CUSTOMER_CONTACT', jsonb_build_object(
        'platform_party_type', 'importer_customer',
        'platform_party_id', inv.importer_id,
        'sage_external_id', party.sage_contact_id,
        'sage_display_name', party.sage_contact_display_name,
        'configured_at', party.sage_contact_verified_at
      ),
      'ZERO_RATED_EXPORT_TAX_RATE', jsonb_build_object(
        'sage_external_id', m.zero_rated_export_tax_rate_id,
        'sage_display_name', m.zero_rated_export_tax_rate_name,
        'configured_at', m.zero_rated_export_tax_rate_configured_at
      ),
      'EXPORT_SALE_INCOME_LEDGER', jsonb_build_object(
        'sage_external_id', m.export_sale_income_ledger_id,
        'sage_display_name', m.export_sale_income_ledger_name,
        'configured_at', m.export_sale_income_ledger_configured_at
      )
    ) AS mapping_snapshot,
    md5(concat_ws('|',
      COALESCE(party.sage_contact_id, ''),
      COALESCE(party.sage_contact_display_name, ''),
      COALESCE(party.sage_contact_verified_at::text, ''),
      COALESCE(m.zero_rated_export_tax_rate_id, ''),
      COALESCE(m.zero_rated_export_tax_rate_name, ''),
      COALESCE(m.zero_rated_export_tax_rate_configured_at::text, ''),
      COALESCE(m.export_sale_income_ledger_id, ''),
      COALESCE(m.export_sale_income_ledger_name, ''),
      COALESCE(m.export_sale_income_ledger_configured_at::text, '')
    ))::text AS mapping_semantic_fingerprint,
    CASE
      WHEN inv.sage_status = 'posted' AND inv.sage_invoice_id IS NULL AND inv.sage_posted_at IS NULL THEN 'internally_marked_posted_no_sage_confirmation'
      WHEN inv.sage_status = 'posted' THEN 'sage_confirmation_recorded'
      WHEN inv.sage_status = 'void' THEN 'voided_no_action'
      WHEN inv.sage_status = 'draft' AND party.sage_contact_id IS NULL THEN 'blocked_customer_sales_sage_contact_missing'
      WHEN inv.sage_status = 'draft' AND pd.payment_date IS NULL THEN 'blocked_customer_sales_payment_date_missing'
      WHEN inv.sage_status = 'draft' AND COALESCE(jsonb_array_length(COALESCE(rl.resolved_lines, '[]'::jsonb)), 0) = 0 THEN 'blocked_customer_sales_resolved_lines_missing'
      WHEN inv.sage_status = 'draft' AND (m.zero_rated_export_tax_rate_id IS NULL OR m.export_sale_income_ledger_id IS NULL) THEN 'blocked_sage_mapping_required'
      WHEN inv.sage_status = 'draft' THEN 'ready_for_sage_posting_preview'
      ELSE 'needs_review'
    END::text AS payload_status,
    CASE
      WHEN inv.sage_status = 'posted' AND inv.sage_invoice_id IS NULL AND inv.sage_posted_at IS NULL THEN 'legacy_internal_posted_status_without_sage_confirmation'
      WHEN inv.sage_status = 'draft' AND party.sage_contact_id IS NULL THEN 'customer/importer Sage contact mapping missing'
      WHEN inv.sage_status = 'draft' AND pd.payment_date IS NULL THEN 'customer sales invoice payment date missing; reconcile order funding DVA/card statement line first'
      WHEN inv.sage_status = 'draft' AND COALESCE(jsonb_array_length(COALESCE(rl.resolved_lines, '[]'::jsonb)), 0) = 0 THEN 'customer sales invoice resolved lines missing'
      WHEN inv.sage_status = 'draft' AND (m.zero_rated_export_tax_rate_id IS NULL OR m.export_sale_income_ledger_id IS NULL) THEN concat_ws(', ',
        CASE WHEN m.zero_rated_export_tax_rate_id IS NULL THEN 'missing_zero_rated_export_tax_rate' END,
        CASE WHEN m.export_sale_income_ledger_id IS NULL THEN 'missing_export_sales_income_ledger' END
      )
      ELSE NULL::text
    END AS blocker,
    concat_ws(' | ',
      CASE
        WHEN inv.sage_status = 'draft' AND COALESCE(inv.commercial_payload #>> '{tax_resolution,sage_tax_rate_resolution_required}', 'false') = 'true' AND m.zero_rated_export_tax_rate_id IS NOT NULL
          THEN 'commercial_draft_json_still_has_unresolved_tax_marker_but_live_resolver_has_resolved_mapping'
      END,
      CASE
        WHEN rl.line_resolution_source = 'supplier_invoice_lines_total_did_not_match_sales_invoice_amount_fallback_to_commercial_payload'
          THEN 'supplier product lines exist but do not match sales invoice amount; commercial payload lines used'
      END
    ) AS warning
  FROM invoices inv
  CROSS JOIN mapping m
  LEFT JOIN party ON party.sales_invoice_id = inv.id
  LEFT JOIN payment_dates pd ON pd.sales_invoice_id = inv.id
  LEFT JOIN resolved_lines rl ON rl.sales_invoice_id = inv.id;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
