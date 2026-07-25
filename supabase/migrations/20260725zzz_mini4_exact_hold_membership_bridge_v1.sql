BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Mini-build 4: bind each customer hold to the exact immutable review
-- membership it targeted. This migration does not create customer documents,
-- credit requirements, cash rows, Sage snapshots or posting adapters.

DO $prerequisites$
DECLARE
  v_definition text;
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN
    RAISE EXCEPTION
      'Mini 4 prerequisite missing: customer_review_cycle_memberships';
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    RAISE EXCEPTION
      'Mini 4 prerequisite missing: customer_pre_shipment_hold_requests';
  END IF;
  IF to_regprocedure('public.customer_hold_refund_target_lines_v1(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'Mini 4 prerequisite missing: customer_hold_refund_target_lines_v1(uuid)';
  END IF;
  IF to_regprocedure('public.customer_hold_create_refund_exception_v2()') IS NULL THEN
    RAISE EXCEPTION
      'Mini 4 prerequisite missing: customer_hold_create_refund_exception_v2()';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_hold_refund_target_lines_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF position('requested_scope IN (''line'', ''tracking'')' IN v_definition) = 0
     OR position('order_tracking_line_allocations' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'Current refund-target resolver no longer matches the audited pre-Mini-4 implementation.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_pre_shipment_hold_requests'::regclass
      AND trigger_row.tgname = 'trg_customer_hold_create_refund_exception_v2'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION
      'Existing customer hold refund-conversion trigger is missing or disabled.';
  END IF;
END
$prerequisites$;

CREATE TABLE public.customer_hold_review_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hold_request_id uuid NOT NULL
    REFERENCES public.customer_pre_shipment_hold_requests(id) ON DELETE RESTRICT,
  review_membership_id uuid NOT NULL
    REFERENCES public.customer_review_cycle_memberships(id) ON DELETE RESTRICT,
  affected_qty numeric(12,3) NOT NULL CHECK (affected_qty > 0),
  affected_goods_amount_gbp numeric(14,2) NOT NULL
    CHECK (affected_goods_amount_gbp >= 0),
  affected_delivery_share_gbp numeric(14,2) NOT NULL DEFAULT 0
    CHECK (affected_delivery_share_gbp >= 0),
  affected_discount_share_gbp numeric(14,2) NOT NULL DEFAULT 0
    CHECK (affected_discount_share_gbp >= 0),
  membership_status text NOT NULL DEFAULT 'active'
    CHECK (membership_status IN ('active','closed')),
  membership_fingerprint text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  status_updated_at timestamptz,
  CONSTRAINT customer_hold_review_memberships_target_uq
    UNIQUE (hold_request_id, review_membership_id)
);

COMMENT ON TABLE public.customer_hold_review_memberships IS
'Exact immutable Mini 4 provenance from the existing customer hold to the exact review membership and affected quantity/value components. It does not replace the hold row or refund route.';

CREATE INDEX idx_customer_hold_review_memberships_hold
  ON public.customer_hold_review_memberships(
    hold_request_id,
    membership_status
  );
CREATE INDEX idx_customer_hold_review_memberships_review
  ON public.customer_hold_review_memberships(review_membership_id);

ALTER TABLE public.customer_hold_review_memberships ENABLE ROW LEVEL SECURITY;

CREATE POLICY customer_hold_review_memberships_staff_read_v1
ON public.customer_hold_review_memberships
FOR SELECT TO authenticated
USING (public.is_active_staff());

REVOKE ALL ON public.customer_hold_review_memberships
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.customer_hold_review_memberships TO authenticated;
GRANT ALL ON public.customer_hold_review_memberships TO service_role;

CREATE OR REPLACE FUNCTION public.customer_hold_review_membership_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.hold_request_id IS DISTINCT FROM OLD.hold_request_id
     OR NEW.review_membership_id IS DISTINCT FROM OLD.review_membership_id
     OR NEW.affected_qty IS DISTINCT FROM OLD.affected_qty
     OR NEW.affected_goods_amount_gbp IS DISTINCT FROM OLD.affected_goods_amount_gbp
     OR NEW.affected_delivery_share_gbp IS DISTINCT FROM OLD.affected_delivery_share_gbp
     OR NEW.affected_discount_share_gbp IS DISTINCT FROM OLD.affected_discount_share_gbp
     OR NEW.membership_fingerprint IS DISTINCT FROM OLD.membership_fingerprint
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION
      'Customer hold review provenance is immutable.';
  END IF;

  IF OLD.membership_status = 'closed'
     AND NEW.membership_status IS DISTINCT FROM OLD.membership_status
  THEN
    RAISE EXCEPTION
      'Closed customer hold review provenance cannot be reopened.';
  END IF;

  IF NEW.membership_status IS DISTINCT FROM OLD.membership_status THEN
    IF NEW.membership_status <> 'closed' THEN
      RAISE EXCEPTION
        'Customer hold review provenance may only transition to closed.';
    END IF;
    NEW.status_updated_at := COALESCE(NEW.status_updated_at, now());
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_hold_review_membership_guard_v1
BEFORE UPDATE ON public.customer_hold_review_memberships
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_review_membership_guard_v1();

CREATE OR REPLACE FUNCTION public.customer_materialize_hold_review_memberships_v1(
  p_hold_request_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hold public.customer_pre_shipment_hold_requests%ROWTYPE;
  v_link_expires_at timestamptz;
  v_inserted integer := 0;
BEGIN
  SELECT hold_row.*
  INTO v_hold
  FROM public.customer_pre_shipment_hold_requests hold_row
  WHERE hold_row.id = p_hold_request_id
  FOR UPDATE;

  IF v_hold.id IS NULL OR v_hold.review_link_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT link_row.expires_at
  INTO v_link_expires_at
  FROM public.customer_order_review_links link_row
  WHERE link_row.id = v_hold.review_link_id
    AND link_row.order_id = v_hold.order_id;

  -- Legacy untimed links keep their established dynamic resolver.
  IF v_link_expires_at IS NULL THEN
    RETURN 0;
  END IF;

  INSERT INTO public.customer_hold_review_memberships (
    hold_request_id,
    review_membership_id,
    affected_qty,
    affected_goods_amount_gbp,
    affected_delivery_share_gbp,
    affected_discount_share_gbp,
    membership_status,
    membership_fingerprint
  )
  SELECT
    v_hold.id,
    membership.id,
    membership.review_qty,
    membership.goods_amount_gbp,
    membership.delivery_share_gbp,
    membership.discount_share_gbp,
    CASE
      WHEN v_hold.status IN ('rejected','resolved','superseded')
        THEN 'closed'
      ELSE 'active'
    END,
    md5(concat_ws(
      '|',
      'customer_hold_review_membership_v1',
      v_hold.id,
      membership.id,
      membership.review_qty,
      membership.goods_amount_gbp,
      membership.delivery_share_gbp,
      membership.discount_share_gbp
    ))
  FROM public.customer_review_cycle_memberships membership
  WHERE membership.review_link_id = v_hold.review_link_id
    AND (
      v_hold.requested_scope = 'order'
      OR (
        v_hold.requested_scope = 'tracking'
        AND membership.tracking_submission_id = v_hold.tracking_submission_id
      )
      OR (
        v_hold.requested_scope = 'line'
        AND membership.supplier_invoice_line_id =
              v_hold.supplier_invoice_line_id
        AND (
          v_hold.tracking_submission_id IS NULL
          OR membership.tracking_submission_id =
                v_hold.tracking_submission_id
        )
      )
    )
  ON CONFLICT (hold_request_id, review_membership_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  UPDATE public.customer_hold_review_memberships hold_membership
  SET membership_status = 'closed',
      status_updated_at = COALESCE(hold_membership.status_updated_at, now())
  WHERE hold_membership.hold_request_id = v_hold.id
    AND hold_membership.membership_status = 'active'
    AND v_hold.status IN ('rejected','resolved','superseded');

  IF v_hold.status IN ('requested','supervisor_approved')
     AND NOT EXISTS (
       SELECT 1
       FROM public.customer_hold_review_memberships hold_membership
       WHERE hold_membership.hold_request_id = v_hold.id
     )
  THEN
    RAISE EXCEPTION
      'Exact timed review membership could not be materialised for hold %.',
      v_hold.id;
  END IF;

  RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION
  public.customer_materialize_hold_review_memberships_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.customer_materialize_hold_review_memberships_v1(uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.customer_hold_review_membership_sync_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.customer_materialize_hold_review_memberships_v1(NEW.id);
  RETURN NEW;
END;
$$;

-- PostgreSQL fires same-event triggers in name order. This trigger deliberately
-- sorts before trg_customer_hold_create_refund_exception_v2 so an approved hold
-- inserted by an existing narrowing RPC has exact membership before the
-- unchanged refund-conversion trigger resolves its target lines.
CREATE TRIGGER trg_customer_hold_00_review_membership_sync_v1
AFTER INSERT OR UPDATE OF
  status,
  requested_scope,
  tracking_submission_id,
  supplier_invoice_line_id,
  review_link_id
ON public.customer_pre_shipment_hold_requests
FOR EACH ROW
EXECUTE FUNCTION public.customer_hold_review_membership_sync_v1();

CREATE OR REPLACE FUNCTION public.customer_hold_refund_target_lines_v1(
  p_hold_request_id uuid
)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  qty_impact numeric,
  amount_impact_gbp numeric,
  source_line_qty numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hold public.customer_pre_shipment_hold_requests%ROWTYPE;
  v_link_expires_at timestamptz;
BEGIN
  SELECT hold_row.*
  INTO v_hold
  FROM public.customer_pre_shipment_hold_requests hold_row
  WHERE hold_row.id = p_hold_request_id
    AND hold_row.status = 'supervisor_approved'
    AND hold_row.requested_scope IN ('line','tracking');

  IF v_hold.id IS NULL THEN
    RETURN;
  END IF;

  SELECT link_row.expires_at
  INTO v_link_expires_at
  FROM public.customer_order_review_links link_row
  WHERE link_row.id = v_hold.review_link_id
    AND link_row.order_id = v_hold.order_id;

  IF v_link_expires_at IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.customer_hold_review_memberships hold_membership
      WHERE hold_membership.hold_request_id = v_hold.id
    ) THEN
      RAISE EXCEPTION
        'Timed hold % has no exact review membership.',
        v_hold.id;
    END IF;

    RETURN QUERY
    WITH exact_qty AS (
      SELECT
        review_membership.supplier_invoice_line_id,
        SUM(hold_membership.affected_qty)::numeric AS affected_qty
      FROM public.customer_hold_review_memberships hold_membership
      JOIN public.customer_review_cycle_memberships review_membership
        ON review_membership.id = hold_membership.review_membership_id
      WHERE hold_membership.hold_request_id = v_hold.id
      GROUP BY review_membership.supplier_invoice_line_id
    )
    SELECT
      supplier_line.id,
      exact_qty.affected_qty,
      ROUND(
        CASE
          WHEN COALESCE(
            supplier_line.qty_confirmed,
            supplier_line.qty,
            0
          ) > 0
          THEN COALESCE(
            supplier_line.amount_confirmed,
            supplier_line.amount_inc_vat_gbp,
            0
          )::numeric
          * exact_qty.affected_qty
          / COALESCE(
              supplier_line.qty_confirmed,
              supplier_line.qty,
              0
            )::numeric
          ELSE 0
        END,
        2
      )::numeric,
      COALESCE(
        supplier_line.qty_confirmed,
        supplier_line.qty,
        0
      )::numeric
    FROM exact_qty
    JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = exact_qty.supplier_invoice_line_id
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
     AND supplier_invoice.order_id = v_hold.order_id
    WHERE exact_qty.affected_qty > 0
      AND COALESCE(supplier_invoice.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      );

    RETURN;
  END IF;

  -- Exact legacy implementation retained for untimed links only.
  RETURN QUERY
  WITH direct_line AS (
    SELECT
      supplier_line.id AS supplier_invoice_line_id,
      COALESCE(
        supplier_line.qty_confirmed,
        supplier_line.qty,
        0
      )::numeric AS qty_impact,
      COALESCE(
        supplier_line.amount_confirmed,
        supplier_line.amount_inc_vat_gbp,
        0
      )::numeric AS amount_impact_gbp,
      COALESCE(
        supplier_line.qty_confirmed,
        supplier_line.qty,
        0
      )::numeric AS source_line_qty
    FROM public.supplier_invoice_lines supplier_line
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
     AND supplier_invoice.order_id = v_hold.order_id
    WHERE v_hold.requested_scope = 'line'
      AND supplier_line.id = v_hold.supplier_invoice_line_id
      AND COALESCE(supplier_invoice.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  ),
  package_allocated AS (
    SELECT
      allocation.supplier_invoice_line_id,
      SUM(COALESCE(allocation.qty_allocated, 0))::numeric AS allocated_qty
    FROM public.order_tracking_line_allocations allocation
    WHERE v_hold.requested_scope = 'tracking'
      AND allocation.order_id = v_hold.order_id
      AND allocation.tracking_submission_id =
            v_hold.tracking_submission_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
    GROUP BY allocation.supplier_invoice_line_id
  ),
  package_line AS (
    SELECT
      supplier_line.id AS supplier_invoice_line_id,
      package_allocated.allocated_qty AS qty_impact,
      CASE
        WHEN COALESCE(
          supplier_line.qty_confirmed,
          supplier_line.qty,
          0
        ) > 0
        THEN ROUND(
          COALESCE(
            supplier_line.amount_confirmed,
            supplier_line.amount_inc_vat_gbp,
            0
          )::numeric
          * package_allocated.allocated_qty
          / COALESCE(
              supplier_line.qty_confirmed,
              supplier_line.qty,
              0
            )::numeric,
          2
        )
        ELSE 0::numeric
      END AS amount_impact_gbp,
      COALESCE(
        supplier_line.qty_confirmed,
        supplier_line.qty,
        0
      )::numeric AS source_line_qty
    FROM package_allocated
    JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = package_allocated.supplier_invoice_line_id
    JOIN public.supplier_invoices supplier_invoice
      ON supplier_invoice.id = supplier_line.supplier_invoice_id
     AND supplier_invoice.order_id = v_hold.order_id
    WHERE v_hold.requested_scope = 'tracking'
      AND COALESCE(supplier_invoice.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  )
  SELECT * FROM direct_line
  UNION ALL
  SELECT * FROM package_line;
END;
$$;

REVOKE ALL ON FUNCTION
  public.customer_hold_refund_target_lines_v1(uuid)
  FROM PUBLIC;

-- The existing customer_hold_create_refund_exception_v2 function and its
-- trigger remain installed and unchanged. It now receives exact quantities
-- through the preserved resolver signature above.

DO $trigger_proof$
DECLARE
  v_refund_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
      'public.customer_pre_shipment_hold_requests'::regclass
      AND trigger_row.tgname = 'trg_customer_hold_create_refund_exception_v2'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION
      'Existing customer refund-conversion trigger changed during hold-bridge installation.';
  END IF;

  SELECT pg_get_functiondef(
    'public.customer_hold_create_refund_exception_v2()'::regprocedure
  ) INTO v_refund_definition;

  IF position('customer_hold_refund_target_lines_v1' IN v_refund_definition) = 0 THEN
    RAISE EXCEPTION
      'Existing refund-conversion function no longer consumes the canonical target resolver.';
  END IF;
END
$trigger_proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
