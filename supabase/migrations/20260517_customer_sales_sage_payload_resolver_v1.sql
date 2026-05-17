BEGIN;

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
        'notes', inv.notes_text,
        'currency_code', 'GBP'
      ),
      'customer_target', jsonb_build_object(
        'importer_id', inv.importer_id,
        'display_name', inv.importer_display_name,
        'resolution_source', 'orders.importer_id'
      ),
      'resolved_lines', COALESCE(lines.resolved_lines, '[]'::jsonb),
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
      WHEN inv.sage_status = 'draft' AND (m.zero_rated_export_tax_rate_id IS NULL OR m.export_sale_income_ledger_id IS NULL) THEN 'blocked_sage_mapping_required'
      WHEN inv.sage_status = 'draft' THEN 'ready_for_sage_posting_preview'
      ELSE 'needs_review'
    END::text AS payload_status,
    CASE
      WHEN inv.sage_status = 'posted' AND inv.sage_invoice_id IS NULL AND inv.sage_posted_at IS NULL THEN 'legacy_internal_posted_status_without_sage_confirmation'
      WHEN inv.sage_status = 'draft' AND (m.zero_rated_export_tax_rate_id IS NULL OR m.export_sale_income_ledger_id IS NULL) THEN concat_ws(', ',
        CASE WHEN m.zero_rated_export_tax_rate_id IS NULL THEN 'missing_zero_rated_export_tax_rate' END,
        CASE WHEN m.export_sale_income_ledger_id IS NULL THEN 'missing_export_sales_income_ledger' END
      )
      ELSE NULL::text
    END AS blocker,
    CASE
      WHEN inv.sage_status = 'draft' AND COALESCE(inv.commercial_payload #>> '{tax_resolution,sage_tax_rate_resolution_required}', 'false') = 'true' AND m.zero_rated_export_tax_rate_id IS NOT NULL
        THEN 'commercial_draft_json_still_has_unresolved_tax_marker_but_live_resolver_has_resolved_mapping'
      ELSE NULL::text
    END AS warning
  FROM invoices inv
  CROSS JOIN mapping m
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      CASE
        WHEN jsonb_typeof(line.value) = 'object' THEN line.value || jsonb_build_object(
          'resolved_tax_rate_id', m.zero_rated_export_tax_rate_id,
          'resolved_ledger_account_id', m.export_sale_income_ledger_id,
          'resolver_ledger_account_role', COALESCE(line.value->>'ledger_account_role', 'export_sale_income')
        )
        ELSE line.value
      END
      ORDER BY line.ordinality
    ) AS resolved_lines
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(inv.commercial_payload->'lines') = 'array' THEN inv.commercial_payload->'lines'
        ELSE '[]'::jsonb
      END
    ) WITH ORDINALITY AS line(value, ordinality)
  ) lines ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.internal_ready_for_sage_queue_v2()
RETURNS TABLE (
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamptz,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH base AS (
    SELECT
      q.queue_row_id,
      q.document_lane,
      q.document_type,
      q.source_table,
      q.source_id,
      q.order_id,
      q.order_ref,
      q.shipment_batch_id,
      q.booking_ref,
      q.counterparty_name,
      q.amount_gbp,
      q.currency_code,
      q.invoice_type,
      q.sage_status,
      q.sage_invoice_id,
      q.sage_posted_at,
      CASE
        WHEN q.document_lane = 'customer_sales' AND r.sales_invoice_id IS NOT NULL THEN r.payload_status
        ELSE q.readiness_status
      END::text AS readiness_status,
      CASE
        WHEN q.document_lane = 'customer_sales' AND r.sales_invoice_id IS NOT NULL THEN r.blocker
        ELSE q.blocker
      END::text AS blocker,
      COALESCE(r.reference_text, q.reference_text)::text AS reference_text,
      COALESCE(r.notes_text, q.notes_text)::text AS notes_text,
      CASE
        WHEN q.document_lane = 'customer_sales'
          AND NULLIF(COALESCE(r.resolved_payload #>> '{commercial_payload,draft_control,shipment_batch_id}', q.source_payload #>> '{draft_control,shipment_batch_id}', ''), '') IS NOT NULL
          THEN '/internal/shipping-control/customer-invoice/' || COALESCE(r.resolved_payload #>> '{commercial_payload,draft_control,shipment_batch_id}', q.source_payload #>> '{draft_control,shipment_batch_id}')
        ELSE q.detail_href
      END::text AS detail_href,
      CASE
        WHEN q.document_lane = 'customer_sales' AND r.sales_invoice_id IS NOT NULL THEN r.resolved_payload
        ELSE q.source_payload
      END::jsonb AS source_payload
    FROM public.internal_ready_for_sage_queue_v2_raw_20260512() q
    LEFT JOIN LATERAL public.internal_resolved_customer_sales_sage_payload_v1(q.source_id) r
      ON q.document_lane = 'customer_sales'
     AND q.source_table = 'sales_invoices'
  )
  SELECT
    b.queue_row_id,
    b.document_lane,
    b.document_type,
    b.source_table,
    b.source_id,
    b.order_id,
    b.order_ref,
    b.shipment_batch_id,
    b.booking_ref,
    b.counterparty_name,
    b.amount_gbp,
    b.currency_code,
    b.invoice_type,
    b.sage_status,
    b.sage_invoice_id,
    b.sage_posted_at,
    b.readiness_status,
    b.blocker,
    b.reference_text,
    CASE
      WHEN COALESCE(b.source_payload->>'customer_hold_blocker', 'false') = 'true'
        OR b.document_type = 'customer_pre_shipment_hold'
        OR b.blocker = 'customer_pre_shipment_hold_unresolved'
      THEN concat_ws(' ',
        CASE
          WHEN counts.requested_count > 0 THEN
            counts.approved_count::text || ' approved and ' || counts.requested_count::text || ' requested customer hold(s) remain unresolved.'
          ELSE
            COALESCE(NULLIF(counts.approved_count, 0), counts.active_count)::text || ' approved customer hold(s) remain unresolved.'
        END,
        CASE
          WHEN NULLIF(scope.scope_text, '') IS NOT NULL THEN 'Scope: ' || scope.scope_text || '.'
        END,
        CASE
          WHEN NULLIF(reasons.reason_text, '') IS NOT NULL THEN 'Reason: ' || reasons.reason_text || '.'
        END
      )
      ELSE b.notes_text
    END AS notes_text,
    b.detail_href,
    b.source_payload
  FROM base b
  LEFT JOIN LATERAL (
    SELECT
      COALESCE(NULLIF(b.source_payload->>'active_hold_count','')::int, 0) AS active_count,
      COALESCE(NULLIF(b.source_payload->>'approved_hold_count','')::int, 0) AS approved_count,
      COALESCE(NULLIF(b.source_payload->>'requested_hold_count','')::int, 0) AS requested_count,
      COALESCE(NULLIF(b.source_payload->>'line_hold_count','')::int, 0) AS line_count,
      COALESCE(NULLIF(b.source_payload->>'tracking_hold_count','')::int, 0) AS tracking_count,
      COALESCE(NULLIF(b.source_payload->>'order_hold_count','')::int, 0) AS order_count
  ) counts ON true
  LEFT JOIN LATERAL (
    SELECT concat_ws(', ',
      CASE WHEN counts.line_count > 0 THEN counts.line_count::text || ' line-level hold(s)' END,
      CASE WHEN counts.tracking_count > 0 THEN counts.tracking_count::text || ' tracking hold(s)' END,
      CASE WHEN counts.order_count > 0 THEN counts.order_count::text || ' order hold(s)' END
    ) AS scope_text
  ) scope ON true
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT NULLIF(btrim(reason), ''), ' | ' ORDER BY NULLIF(btrim(reason), '')) AS reason_text
    FROM jsonb_to_recordset(COALESCE(b.source_payload->'hold_rows', '[]'::jsonb)) AS hold_row(reason text)
  ) reasons ON true;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
