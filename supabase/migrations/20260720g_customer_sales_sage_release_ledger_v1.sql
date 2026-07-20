BEGIN;
SET LOCAL lock_timeout='15s';
SET LOCAL statement_timeout='0';

DO $$
BEGIN
  IF to_regprocedure('public.internal_resolved_customer_sales_sage_payload_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION 'Mini-build 3 prerequisite resolver missing';
  END IF;
END $$;

ALTER FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid)
  RENAME TO internal_customer_sales_sage_payload_pre_ledger_v1;

REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.internal_customer_sales_sage_payload_pre_ledger_v1(uuid) FROM service_role;

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
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff required for customer sales Sage payload resolution';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT *
    FROM public.internal_customer_sales_sage_payload_pre_ledger_v1(p_sales_invoice_id)
  ), ledger AS (
    SELECT
      l.sales_invoice_id,
      COUNT(*)::integer line_count,
      ROUND(SUM(l.customer_charge_amount_gbp),2)::numeric ledger_total,
      jsonb_agg(
        jsonb_build_object(
          'line_kind','customer_sales_from_durable_release_membership',
          'source_order_id',l.order_id,
          'source_commercial_parent_order_id',l.commercial_parent_order_id,
          'source_shipment_batch_id',l.source_shipment_batch_id,
          'source_supplier_invoice_id',l.supplier_invoice_id,
          'source_supplier_invoice_line_id',l.supplier_invoice_line_id,
          'source_tracking_submission_id',l.tracking_submission_id,
          'source_tracking_line_allocation_id',l.tracking_line_allocation_id,
          'released_qty',l.released_qty,
          'description',COALESCE(NULLIF(sil.description,''),'Export sale'),
          'quantity',CASE WHEN l.released_qty>0 THEN l.released_qty ELSE 1 END,
          'unit_price_gbp',CASE WHEN l.released_qty>0
            THEN ROUND(l.customer_charge_amount_gbp/l.released_qty,2)
            ELSE l.customer_charge_amount_gbp END,
          'goods_amount_gbp',l.goods_amount_gbp,
          'delivery_share_gbp',l.delivery_share_gbp,
          'discount_share_gbp',l.discount_share_gbp,
          'shipping_amount_gbp',l.shipping_amount_gbp,
          'total_line_amount_gbp',l.customer_charge_amount_gbp,
          'ledger_account_role','export_sale_income',
          'customer_gl_role','export_sale_income',
          'presentation','principal_export_sale_from_durable_release_membership',
          'source','customer_sales_release_lines'
        )
        ORDER BY l.created_at,l.id
      ) ledger_lines
    FROM public.customer_sales_release_lines l
    LEFT JOIN public.supplier_invoice_lines sil ON sil.id=l.supplier_invoice_line_id
    WHERE l.release_status='active'
    GROUP BY l.sales_invoice_id
  ), legacy AS (
    SELECT li.sales_invoice_id,string_agg(DISTINCT li.issue_code,', ' ORDER BY li.issue_code)::text issue_codes
    FROM public.customer_sales_release_legacy_issues li
    WHERE li.resolved_at IS NULL
    GROUP BY li.sales_invoice_id
  ), shaped AS (
    SELECT
      b.*,
      lg.line_count,
      lg.ledger_total,
      lg.ledger_lines,
      le.issue_codes,
      CASE
        WHEN b.invoice_type NOT IN ('main','supplementary') THEN b.payload_status
        WHEN le.issue_codes IS NOT NULL THEN 'blocked_customer_sales_release_provenance_unresolved'
        WHEN COALESCE(lg.line_count,0)=0 THEN 'blocked_customer_sales_release_provenance_unresolved'
        WHEN ABS(COALESCE(lg.ledger_total,0)-COALESCE(b.amount_gbp,0))>0.02
          THEN 'blocked_customer_sales_release_ledger_amount_mismatch'
        ELSE b.payload_status
      END::text final_status,
      CASE
        WHEN b.invoice_type NOT IN ('main','supplementary') THEN b.blocker
        WHEN le.issue_codes IS NOT NULL THEN 'customer sales release legacy provenance unresolved: '||le.issue_codes
        WHEN COALESCE(lg.line_count,0)=0 THEN 'customer sales release durable membership missing'
        WHEN ABS(COALESCE(lg.ledger_total,0)-COALESCE(b.amount_gbp,0))>0.02
          THEN 'customer sales release ledger total does not match sales invoice amount'
        ELSE b.blocker
      END::text final_blocker
    FROM base b
    LEFT JOIN ledger lg ON lg.sales_invoice_id=b.sales_invoice_id
    LEFT JOIN legacy le ON le.sales_invoice_id=b.sales_invoice_id
  )
  SELECT
    s.sales_invoice_id,s.order_id,s.order_ref,s.document_lane,s.document_type,s.invoice_type,
    s.counterparty_name,s.amount_gbp,s.currency_code,s.reference_text,s.notes_text,
    s.sage_status,s.sage_invoice_id,s.sage_posted_at,s.commercial_payload,
    (
      CASE
        WHEN s.invoice_type IN ('main','supplementary') AND s.final_status=s.payload_status
        THEN jsonb_set(
          jsonb_set(
            s.resolved_payload,
            '{resolved_lines}',
            COALESCE((
              SELECT jsonb_agg(
                line.value || jsonb_build_object(
                  'sage_tax_rate_id',s.resolved_payload #>> '{resolved_mappings,ZERO_RATED_EXPORT_TAX_RATE,sage_external_id}',
                  'sage_tax_rate_display',s.resolved_payload #>> '{resolved_mappings,ZERO_RATED_EXPORT_TAX_RATE,sage_display_name}',
                  'sage_ledger_account_id',s.resolved_payload #>> '{resolved_mappings,EXPORT_SALE_INCOME_LEDGER,sage_external_id}',
                  'sage_ledger_account_display',s.resolved_payload #>> '{resolved_mappings,EXPORT_SALE_INCOME_LEDGER,sage_display_name}'
                )
                ORDER BY line.ordinality
              )
              FROM jsonb_array_elements(COALESCE(s.ledger_lines,'[]'::jsonb))
                WITH ORDINALITY AS line(value,ordinality)
            ),'[]'::jsonb),
            true
          ),
          '{line_resolution}',
          jsonb_build_object(
            'source','durable_release_membership_authoritative',
            'source_line_count',COALESCE(s.line_count,0),
            'source_line_total_gbp',COALESCE(s.ledger_total,0),
            'sales_invoice_amount_gbp',s.amount_gbp
          ),
          true
        )
        ELSE s.resolved_payload
      END
      || jsonb_build_object(
        'resolver_control',
        COALESCE(s.resolved_payload->'resolver_control','{}'::jsonb)
          || jsonb_build_object('status',s.final_status,'blocker',s.final_blocker)
      )
    )::jsonb,
    s.mapping_snapshot,s.mapping_semantic_fingerprint,s.final_status,s.final_blocker,
    concat_ws(' | ',NULLIF(s.warning,''),CASE
      WHEN s.invoice_type IN ('main','supplementary') AND s.final_status=s.payload_status
      THEN 'durable_release_membership_authoritative'
      ELSE NULL END)::text
  FROM shaped s;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_resolved_customer_sales_sage_payload_v1(uuid) TO service_role;

DO $$
DECLARE
  v_oid oid;
  v_definition text;
BEGIN
  FOR v_oid IN
    SELECT p.oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.prokind='f'
      AND p.proname NOT IN (
        'internal_resolved_customer_sales_sage_payload_v1',
        'internal_customer_sales_sage_payload_pre_ledger_v1'
      )
      AND p.prosrc LIKE '%internal_resolved_customer_sales_sage_payload_v1%'
  LOOP
    SELECT pg_get_functiondef(v_oid) INTO v_definition;
    EXECUTE v_definition;
  END LOOP;
END $$;

NOTIFY pgrst,'reload schema';
COMMIT;
