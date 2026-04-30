-- =============================================================================
-- order_value_adjustments_policy_v1.sql
-- Multi Tenant Platform Build — additive delivery/discount adjustment foundation
--
-- Purpose:
--   Add the minimal financial adjustment layer needed for retailer delivery
--   charges and retailer discounts discovered during invoice intake/reconciliation.
--
-- Principles:
--   - Do not alter supplier_invoice_lines.
--   - Do not alter reconciliation/progression logic.
--   - Do not overwrite orders.order_total_gbp_declared.
--   - Delivery/discount adjustments are financial finalisation inputs, not
--     shipper-visible physical goods lines.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- =============================================================================
-- 0. PREREQUISITE ASSERTIONS
-- =============================================================================

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;

  IF to_regclass('public.supplier_invoices') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoices';
  END IF;

  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;

  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;

  IF to_regclass('public.shippers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.shippers';
  END IF;

  IF to_regclass('public.operator_importers') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operator_importers';
  END IF;
END $$;

-- =============================================================================
-- 1. CONFIGURATION TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.order_adjustment_policy (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shipper_id uuid REFERENCES public.shippers(id),
  delivery_auto_approve_limit_gbp decimal(12,2) NOT NULL DEFAULT 10.00
    CHECK (delivery_auto_approve_limit_gbp >= 0),
  discount_requires_approval boolean NOT NULL DEFAULT true,
  active boolean NOT NULL DEFAULT true,
  updated_by_staff_id uuid REFERENCES public.staff(id),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.order_adjustment_policy IS
'Configures financial adjustment approval policy. Global active row applies by default; shipper-specific active row can override it.';

COMMENT ON COLUMN public.order_adjustment_policy.delivery_auto_approve_limit_gbp IS
'Max retailer delivery charge that may be auto-approved. Delivery above this requires supervisor approval.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_order_adjustment_policy_active_global
  ON public.order_adjustment_policy ((1))
  WHERE active = true AND shipper_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_order_adjustment_policy_active_shipper
  ON public.order_adjustment_policy (shipper_id)
  WHERE active = true AND shipper_id IS NOT NULL;

INSERT INTO public.order_adjustment_policy (
  shipper_id,
  delivery_auto_approve_limit_gbp,
  discount_requires_approval,
  active,
  notes
)
SELECT
  NULL,
  10.00,
  true,
  true,
  'Default global adjustment policy: retailer delivery up to GBP 10 auto-approvable; discounts require supervisor approval.'
WHERE NOT EXISTS (
  SELECT 1
  FROM public.order_adjustment_policy
  WHERE active = true
    AND shipper_id IS NULL
);

-- =============================================================================
-- 2. ORDER VALUE ADJUSTMENTS TABLE
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.order_value_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  supplier_invoice_id uuid REFERENCES public.supplier_invoices(id),
  adjustment_type varchar NOT NULL CHECK (adjustment_type IN ('retailer_delivery','retailer_discount')),
  amount_gbp decimal(12,2) NOT NULL CHECK (amount_gbp >= 0),
  approval_status varchar NOT NULL DEFAULT 'pending_supervisor'
    CHECK (approval_status IN ('auto_approved','pending_supervisor','approved','rejected')),
  requires_supervisor_approval boolean NOT NULL DEFAULT true,
  submitted_by_operator_id uuid NOT NULL REFERENCES public.operators(id),
  approved_by_staff_id uuid REFERENCES public.staff(id),
  approved_at timestamptz,
  apportionment_method varchar NOT NULL DEFAULT 'pro_rata_by_line_value'
    CHECK (apportionment_method IN ('pro_rata_by_line_value','full_order_level')),
  customer_treatment varchar NOT NULL DEFAULT 'pass_to_importer'
    CHECK (customer_treatment IN ('pass_to_importer','retain_platform_benefit','internal_only')),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_value_adjustments_approved_requires_staff CHECK (
    approval_status <> 'approved'
    OR (approved_by_staff_id IS NOT NULL AND approved_at IS NOT NULL)
  ),
  CONSTRAINT order_value_adjustments_auto_not_supervisor_required CHECK (
    approval_status <> 'auto_approved'
    OR requires_supervisor_approval = false
  ),
  CONSTRAINT order_value_adjustments_discount_requires_supervisor CHECK (
    adjustment_type <> 'retailer_discount'
    OR requires_supervisor_approval = true
  ),
  CONSTRAINT order_value_adjustments_discount_not_auto CHECK (
    adjustment_type <> 'retailer_discount'
    OR approval_status <> 'auto_approved'
  )
);

COMMENT ON TABLE public.order_value_adjustments IS
'Financial delivery/discount adjustments discovered during invoice intake/reconciliation. These are not physical goods lines and must not be shown to shippers as progressed goods.';

COMMENT ON COLUMN public.order_value_adjustments.amount_gbp IS
'Always stored as a positive amount. adjustment_type determines whether it adds to or reduces final financial value.';

CREATE INDEX IF NOT EXISTS idx_order_value_adjustments_order
  ON public.order_value_adjustments(order_id);

CREATE INDEX IF NOT EXISTS idx_order_value_adjustments_supplier_invoice
  ON public.order_value_adjustments(supplier_invoice_id)
  WHERE supplier_invoice_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_order_value_adjustments_approval_status
  ON public.order_value_adjustments(approval_status);

CREATE INDEX IF NOT EXISTS idx_order_value_adjustments_type_status
  ON public.order_value_adjustments(adjustment_type, approval_status);

-- =============================================================================
-- 3. RLS
-- =============================================================================

ALTER TABLE public.order_adjustment_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_value_adjustments ENABLE ROW LEVEL SECURITY;

-- ---- order_adjustment_policy policies

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_adjustment_policy'
      AND policyname = 'order_adjustment_policy_authenticated_select'
  ) THEN
    CREATE POLICY order_adjustment_policy_authenticated_select
    ON public.order_adjustment_policy
    FOR SELECT
    TO authenticated
    USING (active = true);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_adjustment_policy'
      AND policyname = 'order_adjustment_policy_staff_all'
  ) THEN
    CREATE POLICY order_adjustment_policy_staff_all
    ON public.order_adjustment_policy
    FOR ALL
    TO authenticated
    USING (is_active_staff())
    WITH CHECK (is_active_staff());
  END IF;
END $$;

-- ---- order_value_adjustments policies

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_value_adjustments'
      AND policyname = 'order_value_adjustments_operator_select'
  ) THEN
    CREATE POLICY order_value_adjustments_operator_select
    ON public.order_value_adjustments
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = order_value_adjustments.order_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_value_adjustments'
      AND policyname = 'order_value_adjustments_operator_insert'
  ) THEN
    CREATE POLICY order_value_adjustments_operator_insert
    ON public.order_value_adjustments
    FOR INSERT
    TO authenticated
    WITH CHECK (
      approval_status IN ('auto_approved','pending_supervisor')
      AND EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = order_value_adjustments.order_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
          AND order_value_adjustments.submitted_by_operator_id = op.id
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_value_adjustments'
      AND policyname = 'order_value_adjustments_staff_all'
  ) THEN
    CREATE POLICY order_value_adjustments_staff_all
    ON public.order_value_adjustments
    FOR ALL
    TO authenticated
    USING (is_active_staff())
    WITH CHECK (is_active_staff());
  END IF;
END $$;

COMMIT;
