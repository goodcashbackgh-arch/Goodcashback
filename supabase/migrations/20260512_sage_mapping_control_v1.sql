BEGIN;

CREATE TABLE IF NOT EXISTS public.sage_mapping_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mapping_code text NOT NULL UNIQUE,
  mapping_group text NOT NULL,
  display_name text NOT NULL,
  description text NOT NULL,
  value_kind text NOT NULL CHECK (value_kind IN ('tax_rate_id','ledger_account_id','contact_id','free_text')),
  required_for text[] NOT NULL DEFAULT ARRAY[]::text[],
  sage_external_id text,
  sage_display_name text,
  is_active boolean NOT NULL DEFAULT true,
  configured_at timestamptz,
  configured_by_staff_id uuid REFERENCES public.staff(id),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.sage_mapping_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sage_mapping_settings_staff_select ON public.sage_mapping_settings;
CREATE POLICY sage_mapping_settings_staff_select
ON public.sage_mapping_settings
FOR SELECT
TO authenticated
USING (public.is_active_staff());

INSERT INTO public.sage_mapping_settings (
  mapping_code,
  mapping_group,
  display_name,
  description,
  value_kind,
  required_for
)
VALUES
  (
    'ZERO_RATED_EXPORT_TAX_RATE',
    'customer_sales',
    'Zero-rated export sales tax rate',
    'Sage tax rate id/name used for UK zero-rated export customer sales invoices. Do not assume this is T0 until checked in the connected Sage tenant.',
    'tax_rate_id',
    ARRAY['customer_sales_invoice','customer_supplementary_invoice']::text[]
  ),
  (
    'EXPORT_SALE_INCOME_LEDGER',
    'customer_sales',
    'Export sales income ledger account',
    'Sage ledger/account id/name used for bundled customer export sale lines.',
    'ledger_account_id',
    ARRAY['customer_sales_invoice','customer_supplementary_invoice']::text[]
  ),
  (
    'SHIPPER_FREIGHT_COST_LEDGER',
    'shipper_ap',
    'Shipper freight/AP cost ledger account',
    'Sage ledger/account id/name used for shipper freight or logistics purchase invoice cost lines.',
    'ledger_account_id',
    ARRAY['shipper_ap_purchase_invoice']::text[]
  ),
  (
    'SHIPPER_AP_TAX_RATE_REVIEW',
    'shipper_ap',
    'Shipper/AP tax rate review setting',
    'Placeholder mapping/control note for shipper/AP tax handling. This must be confirmed before real AP posting is enabled.',
    'tax_rate_id',
    ARRAY['shipper_ap_purchase_invoice']::text[]
  )
ON CONFLICT (mapping_code) DO UPDATE
SET mapping_group = EXCLUDED.mapping_group,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    value_kind = EXCLUDED.value_kind,
    required_for = EXCLUDED.required_for,
    updated_at = now();

CREATE OR REPLACE FUNCTION public.internal_sage_mapping_control_v1()
RETURNS TABLE (
  mapping_code text,
  mapping_group text,
  display_name text,
  description text,
  value_kind text,
  required_for text[],
  sage_external_id text,
  sage_display_name text,
  is_active boolean,
  mapping_status text,
  blocker text,
  configured_at timestamptz,
  configured_by_staff_name text,
  notes text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage mapping control requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for Sage mapping control.';
  END IF;

  RETURN QUERY
  SELECT
    sm.mapping_code,
    sm.mapping_group,
    sm.display_name,
    sm.description,
    sm.value_kind,
    sm.required_for,
    sm.sage_external_id,
    sm.sage_display_name,
    sm.is_active,
    CASE
      WHEN sm.is_active IS DISTINCT FROM true THEN 'disabled'
      WHEN NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NULL THEN 'missing'
      ELSE 'configured'
    END::text AS mapping_status,
    CASE
      WHEN sm.is_active IS DISTINCT FROM true THEN 'mapping_disabled'
      WHEN NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NULL THEN 'sage_external_id_missing'
      ELSE NULL::text
    END AS blocker,
    sm.configured_at,
    st.full_name AS configured_by_staff_name,
    sm.notes
  FROM public.sage_mapping_settings sm
  LEFT JOIN public.staff st ON st.id = sm.configured_by_staff_id
  ORDER BY
    CASE sm.mapping_group
      WHEN 'customer_sales' THEN 0
      WHEN 'shipper_ap' THEN 1
      ELSE 2
    END,
    sm.display_name;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_upsert_sage_mapping_v1(
  p_mapping_code text,
  p_sage_external_id text,
  p_sage_display_name text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS TABLE (
  mapping_code text,
  mapping_status text,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_role text;
  v_clean_external_id text := NULLIF(trim(COALESCE(p_sage_external_id, '')), '');
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: Sage mapping update requires auth.uid()';
  END IF;

  SELECT s.id, s.role_type
    INTO v_staff_id, v_role
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND COALESCE(s.active, true) = true
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active staff account required for Sage mapping update.';
  END IF;

  IF v_role NOT IN ('admin','supervisor') THEN
    RAISE EXCEPTION 'Admin or supervisor role required for Sage mapping update.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.sage_mapping_settings sm WHERE sm.mapping_code = p_mapping_code
  ) THEN
    RAISE EXCEPTION 'Unknown Sage mapping code: %', p_mapping_code;
  END IF;

  UPDATE public.sage_mapping_settings sm
  SET sage_external_id = v_clean_external_id,
      sage_display_name = NULLIF(trim(COALESCE(p_sage_display_name, '')), ''),
      notes = NULLIF(trim(COALESCE(p_notes, '')), ''),
      configured_at = CASE WHEN v_clean_external_id IS NULL THEN NULL ELSE now() END,
      configured_by_staff_id = CASE WHEN v_clean_external_id IS NULL THEN NULL ELSE v_staff_id END,
      updated_at = now(),
      is_active = true
  WHERE sm.mapping_code = p_mapping_code;

  RETURN QUERY
  SELECT
    p_mapping_code,
    CASE WHEN v_clean_external_id IS NULL THEN 'missing' ELSE 'configured' END::text,
    CASE WHEN v_clean_external_id IS NULL THEN 'Mapping cleared.' ELSE 'Mapping saved.' END::text;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_sage_mapping_configured_v1(p_mapping_code text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.sage_mapping_settings sm
    WHERE sm.mapping_code = p_mapping_code
      AND sm.is_active = true
      AND NULLIF(trim(COALESCE(sm.sage_external_id, '')), '') IS NOT NULL
  )
$$;

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
DECLARE
  v_customer_tax_ready boolean;
  v_customer_sales_ledger_ready boolean;
  v_shipper_ap_ledger_ready boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: ready for Sage queue requires auth.uid()';
  END IF;

  IF NOT public.is_active_staff() THEN
    RAISE EXCEPTION 'Active staff account required for ready for Sage queue.';
  END IF;

  v_customer_tax_ready := public.internal_sage_mapping_configured_v1('ZERO_RATED_EXPORT_TAX_RATE');
  v_customer_sales_ledger_ready := public.internal_sage_mapping_configured_v1('EXPORT_SALE_INCOME_LEDGER');
  v_shipper_ap_ledger_ready := public.internal_sage_mapping_configured_v1('SHIPPER_FREIGHT_COST_LEDGER');

  RETURN QUERY
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
      WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'internally_marked_posted_no_sage_confirmation'
      WHEN q.sage_status = 'posted'
        THEN 'sage_confirmation_recorded'
      WHEN q.document_lane = 'customer_sales'
        AND q.sage_status = 'draft'
        AND (v_customer_tax_ready IS DISTINCT FROM true OR v_customer_sales_ledger_ready IS DISTINCT FROM true)
        THEN 'blocked_sage_mapping_required'
      WHEN q.document_lane = 'customer_sales'
        AND q.sage_status = 'draft'
        THEN 'ready_for_sage_posting_preview'
      WHEN q.document_lane = 'shipper_ap'
        AND v_shipper_ap_ledger_ready IS DISTINCT FROM true
        THEN 'blocked_sage_mapping_required'
      ELSE q.readiness_status
    END AS readiness_status,
    CASE
      WHEN q.sage_status = 'posted' AND q.sage_invoice_id IS NULL AND q.sage_posted_at IS NULL
        THEN 'legacy_internal_posted_status_without_sage_confirmation'
      WHEN q.document_lane = 'customer_sales'
        AND q.sage_status = 'draft'
        AND (v_customer_tax_ready IS DISTINCT FROM true OR v_customer_sales_ledger_ready IS DISTINCT FROM true)
        THEN concat_ws(', ',
          CASE WHEN v_customer_tax_ready IS DISTINCT FROM true THEN 'missing_zero_rated_export_tax_rate' END,
          CASE WHEN v_customer_sales_ledger_ready IS DISTINCT FROM true THEN 'missing_export_sales_income_ledger' END
        )
      WHEN q.document_lane = 'shipper_ap'
        AND v_shipper_ap_ledger_ready IS DISTINCT FROM true
        THEN 'missing_shipper_freight_cost_ledger'
      ELSE q.blocker
    END AS blocker,
    q.reference_text,
    q.notes_text,
    CASE
      WHEN q.document_lane = 'customer_sales'
        AND NULLIF(q.source_payload #>> '{draft_control,shipment_batch_id}', '') IS NOT NULL
        THEN '/internal/shipping-control/customer-invoice/' || (q.source_payload #>> '{draft_control,shipment_batch_id}')
      ELSE q.detail_href
    END AS detail_href,
    q.source_payload
  FROM public.internal_ready_for_sage_queue_v1() q;
END;
$$;

REVOKE ALL ON FUNCTION public.internal_sage_mapping_control_v1() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_upsert_sage_mapping_v1(text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_sage_mapping_configured_v1(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.internal_ready_for_sage_queue_v2() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.internal_sage_mapping_control_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_upsert_sage_mapping_v1(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_sage_mapping_configured_v1(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.internal_ready_for_sage_queue_v2() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
