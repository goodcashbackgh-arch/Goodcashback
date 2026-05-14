-- =============================================================================
-- 20260514_supplier_invoice_line_non_physical_resolution_v1.sql
-- Multi Tenant Platform Build — non-physical supplier invoice line resolution
--
-- Governing contract:
--   docs/governing-pack/ui/NON_PHYSICAL_SUPPLIER_INVOICE_LINE_RESOLUTION_CONTRACT_v1.md
--
-- Purpose:
--   Add an additive closure state for supplier invoice OCR/manual lines that are
--   real invoice rows but not physical goods, e.g. delivery, discount, fee,
--   rounding, or zero-value informational rows.
--
-- Safety:
--   - Does not alter supplier_invoice_lines.
--   - Does not alter eligible_for_invoice_yn or line_source constraints.
--   - Does not use dispute_lines for normal non-physical financial rows.
--   - Does not touch shipper/tracking allocation tables.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.supplier_invoice_line_resolutions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE CASCADE,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  resolution_type varchar NOT NULL DEFAULT 'non_physical_financial'
    CHECK (resolution_type IN ('non_physical_financial')),
  financial_type varchar NOT NULL
    CHECK (financial_type IN ('delivery','discount','fee','zero_value_delivery','rounding','other_non_physical')),
  qty_reported numeric(12,3) NOT NULL DEFAULT 0,
  amount_gbp numeric(14,2) NOT NULL DEFAULT 0,
  shipper_required_yn boolean NOT NULL DEFAULT false,
  active boolean NOT NULL DEFAULT true,
  resolved_by_operator_id uuid REFERENCES public.operators(id),
  resolved_by_staff_id uuid REFERENCES public.staff(id),
  resolved_at timestamptz NOT NULL DEFAULT now(),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT supplier_invoice_line_resolutions_actor_check CHECK (
    resolved_by_operator_id IS NOT NULL OR resolved_by_staff_id IS NOT NULL
  ),
  CONSTRAINT supplier_invoice_line_resolutions_not_shipper_required CHECK (
    shipper_required_yn = false
  )
);

COMMENT ON TABLE public.supplier_invoice_line_resolutions IS
'Additive closure state for supplier invoice lines that are not physical goods. Active rows close operator/supplier readiness without progressing the line into tracking or shipper allocation.';

COMMENT ON COLUMN public.supplier_invoice_line_resolutions.amount_gbp IS
'Preserved absolute/source gross amount for the non-physical supplier invoice line. Financial sign treatment is determined by financial_type/accounting coding, not by mutating OCR evidence.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_supplier_invoice_line_resolutions_active_line
  ON public.supplier_invoice_line_resolutions (supplier_invoice_line_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_line_resolutions_invoice_active
  ON public.supplier_invoice_line_resolutions (supplier_invoice_id, active);

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_line_resolutions_order_active
  ON public.supplier_invoice_line_resolutions (order_id, active);

ALTER TABLE public.supplier_invoice_line_resolutions ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_line_resolutions'
      AND policyname = 'supplier_invoice_line_resolutions_operator_select'
  ) THEN
    CREATE POLICY supplier_invoice_line_resolutions_operator_select
    ON public.supplier_invoice_line_resolutions
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = supplier_invoice_line_resolutions.order_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
      )
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'supplier_invoice_line_resolutions'
      AND policyname = 'supplier_invoice_line_resolutions_staff_all'
  ) THEN
    CREATE POLICY supplier_invoice_line_resolutions_staff_all
    ON public.supplier_invoice_line_resolutions
    FOR ALL
    TO authenticated
    USING (public.is_active_staff())
    WITH CHECK (public.is_active_staff());
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_resolve_supplier_invoice_line_non_physical(
  p_order_id uuid,
  p_supplier_invoice_line_id uuid,
  p_financial_type text,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_operator_id uuid;
  v_line record;
  v_resolution_id uuid;
  v_financial_type text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user';
  END IF;

  SELECT op.id
  INTO v_operator_id
  FROM public.operators op
  WHERE op.auth_user_id = auth.uid()
    AND op.active = true
  ORDER BY op.created_at DESC
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account required.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.orders o
    JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
    WHERE o.id = p_order_id
      AND oi.operator_id = v_operator_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised for this order.';
  END IF;

  v_financial_type := lower(btrim(coalesce(p_financial_type, '')));
  IF v_financial_type NOT IN ('delivery','discount','fee','zero_value_delivery','rounding','other_non_physical') THEN
    RAISE EXCEPTION 'Invalid non-physical financial type: %', p_financial_type;
  END IF;

  SELECT
    sil.id,
    sil.supplier_invoice_id,
    si.order_id,
    sil.qty,
    sil.amount_inc_vat_gbp,
    sil.eligible_for_invoice_yn
  INTO v_line
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_supplier_invoice_line_id
    AND si.order_id = p_order_id;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to this order.';
  END IF;

  IF lower(btrim(coalesce(v_line.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1') THEN
    RAISE EXCEPTION 'Progressed physical lines cannot be resolved as non-physical.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.disputes d ON d.id = dl.dispute_id
    WHERE dl.supplier_invoice_line_id = p_supplier_invoice_line_id
      AND dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Exception-linked lines cannot be resolved as non-physical.';
  END IF;

  UPDATE public.supplier_invoice_line_resolutions r
     SET active = false,
         updated_at = now()
   WHERE r.supplier_invoice_line_id = p_supplier_invoice_line_id
     AND r.active = true;

  INSERT INTO public.supplier_invoice_line_resolutions (
    supplier_invoice_line_id,
    supplier_invoice_id,
    order_id,
    resolution_type,
    financial_type,
    qty_reported,
    amount_gbp,
    shipper_required_yn,
    active,
    resolved_by_operator_id,
    notes
  ) VALUES (
    p_supplier_invoice_line_id,
    v_line.supplier_invoice_id,
    p_order_id,
    'non_physical_financial',
    v_financial_type,
    COALESCE(v_line.qty, 0),
    COALESCE(v_line.amount_inc_vat_gbp, 0),
    false,
    true,
    v_operator_id,
    NULLIF(btrim(COALESCE(p_notes, '')), '')
  ) RETURNING id INTO v_resolution_id;

  RETURN v_resolution_id;
END;
$$;

REVOKE ALL ON FUNCTION public.operator_resolve_supplier_invoice_line_non_physical(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_resolve_supplier_invoice_line_non_physical(uuid, uuid, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.staff_resolve_supplier_invoice_line_non_physical(
  p_order_id uuid,
  p_supplier_invoice_line_id uuid,
  p_financial_type text,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_line record;
  v_resolution_id uuid;
  v_financial_type text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user';
  END IF;

  SELECT s.id
  INTO v_staff_id
  FROM public.staff s
  WHERE s.auth_user_id = auth.uid()
    AND s.active = true
    AND s.role_type IN ('admin','supervisor')
  ORDER BY s.created_at DESC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'Active supervisor/admin staff account required.';
  END IF;

  v_financial_type := lower(btrim(coalesce(p_financial_type, '')));
  IF v_financial_type NOT IN ('delivery','discount','fee','zero_value_delivery','rounding','other_non_physical') THEN
    RAISE EXCEPTION 'Invalid non-physical financial type: %', p_financial_type;
  END IF;

  SELECT
    sil.id,
    sil.supplier_invoice_id,
    si.order_id,
    sil.qty,
    sil.amount_inc_vat_gbp,
    sil.eligible_for_invoice_yn
  INTO v_line
  FROM public.supplier_invoice_lines sil
  JOIN public.supplier_invoices si ON si.id = sil.supplier_invoice_id
  WHERE sil.id = p_supplier_invoice_line_id
    AND si.order_id = p_order_id;

  IF v_line.id IS NULL THEN
    RAISE EXCEPTION 'Supplier invoice line does not belong to this order.';
  END IF;

  IF lower(btrim(coalesce(v_line.eligible_for_invoice_yn, ''))) IN ('y','yes','true','1') THEN
    RAISE EXCEPTION 'Progressed physical lines cannot be resolved as non-physical.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    JOIN public.disputes d ON d.id = dl.dispute_id
    WHERE dl.supplier_invoice_line_id = p_supplier_invoice_line_id
      AND dl.resolved_at IS NULL
      AND d.resolved_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Exception-linked lines cannot be resolved as non-physical.';
  END IF;

  UPDATE public.supplier_invoice_line_resolutions r
     SET active = false,
         updated_at = now()
   WHERE r.supplier_invoice_line_id = p_supplier_invoice_line_id
     AND r.active = true;

  INSERT INTO public.supplier_invoice_line_resolutions (
    supplier_invoice_line_id,
    supplier_invoice_id,
    order_id,
    resolution_type,
    financial_type,
    qty_reported,
    amount_gbp,
    shipper_required_yn,
    active,
    resolved_by_staff_id,
    notes
  ) VALUES (
    p_supplier_invoice_line_id,
    v_line.supplier_invoice_id,
    p_order_id,
    'non_physical_financial',
    v_financial_type,
    COALESCE(v_line.qty, 0),
    COALESCE(v_line.amount_inc_vat_gbp, 0),
    false,
    true,
    v_staff_id,
    NULLIF(btrim(COALESCE(p_notes, '')), '')
  ) RETURNING id INTO v_resolution_id;

  RETURN v_resolution_id;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_resolve_supplier_invoice_line_non_physical(uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_resolve_supplier_invoice_line_non_physical(uuid, uuid, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
