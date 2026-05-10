-- =============================================================================
-- 20260510_order_tracking_line_allocations.sql
-- Multi Tenant Platform Build — delivery allocation foundation
--
-- Governing source:
--   docs/governing-pack/backend/Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md
--
-- Purpose:
--   Add the minimal controlled layer linking progressed supplier invoice lines
--   to order tracking refs/packages. This supports later shipper receipt,
--   shipment batch selection, COS/BOL/export evidence allocation, and adjusted
--   net value tracing without rewriting original supplier invoice lines.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
BEGIN
  IF to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.orders';
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.supplier_invoice_lines';
  END IF;
  IF to_regclass('public.order_tracking_submissions') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.order_tracking_submissions';
  END IF;
  IF to_regclass('public.operators') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.operators';
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    RAISE EXCEPTION 'Prerequisite missing: public.staff';
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.order_tracking_line_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE CASCADE,
  tracking_submission_id uuid REFERENCES public.order_tracking_submissions(id) ON DELETE CASCADE,
  qty_allocated numeric(12,3) NOT NULL CHECK (qty_allocated > 0),
  base_value_gbp numeric(12,2) NOT NULL DEFAULT 0,
  discount_share_gbp numeric(12,2) NOT NULL DEFAULT 0 CHECK (discount_share_gbp >= 0),
  retailer_delivery_share_gbp numeric(12,2) NOT NULL DEFAULT 0 CHECK (retailer_delivery_share_gbp >= 0),
  adjusted_net_value_gbp numeric(12,2) NOT NULL DEFAULT 0,
  allocation_status varchar NOT NULL DEFAULT 'allocated'
    CHECK (allocation_status IN (
      'allocated',
      'partially_allocated',
      'unknown_contents',
      'needs_operator_evidence',
      'supervisor_accepted_estimate',
      'locked_for_export_pack'
    )),
  allocation_basis varchar NOT NULL DEFAULT 'operator_declaration'
    CHECK (allocation_basis IN (
      'operator_declaration',
      'retailer_dispatch_email',
      'retailer_app',
      'packing_slip',
      'retailer_delivery_note',
      'supervisor_estimate',
      'unknown'
    )),
  evidence_url text,
  notes text,
  allocated_by_operator_id uuid REFERENCES public.operators(id),
  allocated_by_staff_id uuid REFERENCES public.staff(id),
  supervisor_accepted_by_staff_id uuid REFERENCES public.staff(id),
  supervisor_accepted_at timestamptz,
  locked_for_export_pack_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_tracking_line_allocations_tracking_required_for_allocated CHECK (
    allocation_status IN ('unknown_contents','needs_operator_evidence')
    OR tracking_submission_id IS NOT NULL
  ),
  CONSTRAINT order_tracking_line_allocations_has_actor CHECK (
    allocated_by_operator_id IS NOT NULL OR allocated_by_staff_id IS NOT NULL
  ),
  CONSTRAINT order_tracking_line_allocations_supervisor_acceptance CHECK (
    allocation_status <> 'supervisor_accepted_estimate'
    OR (supervisor_accepted_by_staff_id IS NOT NULL AND supervisor_accepted_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.order_tracking_line_allocations IS
'Allocation layer linking progressed supplier invoice lines/quantities/adjusted net values to tracking refs/packages. Does not rewrite original supplier invoice lines.';

COMMENT ON COLUMN public.order_tracking_line_allocations.adjusted_net_value_gbp IS
'Value used downstream for shipment/COS/export allocation preview: base less discount share plus retailer delivery share.';

CREATE INDEX IF NOT EXISTS idx_otla_order
  ON public.order_tracking_line_allocations(order_id, created_at);

CREATE INDEX IF NOT EXISTS idx_otla_line
  ON public.order_tracking_line_allocations(supplier_invoice_line_id);

CREATE INDEX IF NOT EXISTS idx_otla_tracking
  ON public.order_tracking_line_allocations(tracking_submission_id)
  WHERE tracking_submission_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_otla_status
  ON public.order_tracking_line_allocations(allocation_status);

CREATE INDEX IF NOT EXISTS idx_otla_unlocked
  ON public.order_tracking_line_allocations(order_id, supplier_invoice_line_id)
  WHERE locked_for_export_pack_at IS NULL;

ALTER TABLE public.order_tracking_line_allocations ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_tracking_line_allocations'
      AND policyname = 'otla_operator_select'
  ) THEN
    CREATE POLICY otla_operator_select
    ON public.order_tracking_line_allocations
    FOR SELECT
    TO authenticated
    USING (
      EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = order_tracking_line_allocations.order_id
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
      AND tablename = 'order_tracking_line_allocations'
      AND policyname = 'otla_operator_insert'
  ) THEN
    CREATE POLICY otla_operator_insert
    ON public.order_tracking_line_allocations
    FOR INSERT
    TO authenticated
    WITH CHECK (
      locked_for_export_pack_at IS NULL
      AND allocated_by_staff_id IS NULL
      AND supervisor_accepted_by_staff_id IS NULL
      AND supervisor_accepted_at IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = order_tracking_line_allocations.order_id
          AND oi.revoked_at IS NULL
          AND op.auth_user_id = auth.uid()
          AND COALESCE(op.active, true) = true
          AND order_tracking_line_allocations.allocated_by_operator_id = op.id
      )
    );
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'order_tracking_line_allocations'
      AND policyname = 'otla_operator_delete_unlocked'
  ) THEN
    CREATE POLICY otla_operator_delete_unlocked
    ON public.order_tracking_line_allocations
    FOR DELETE
    TO authenticated
    USING (
      locked_for_export_pack_at IS NULL
      AND EXISTS (
        SELECT 1
        FROM public.orders o
        JOIN public.operator_importers oi ON oi.importer_id = o.importer_id
        JOIN public.operators op ON op.id = oi.operator_id
        WHERE o.id = order_tracking_line_allocations.order_id
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
      AND tablename = 'order_tracking_line_allocations'
      AND policyname = 'otla_staff_all'
  ) THEN
    CREATE POLICY otla_staff_all
    ON public.order_tracking_line_allocations
    FOR ALL
    TO authenticated
    USING (is_active_staff())
    WITH CHECK (is_active_staff());
  END IF;
END $$;

COMMIT;
