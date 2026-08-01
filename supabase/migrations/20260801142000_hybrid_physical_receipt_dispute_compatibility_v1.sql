BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $preflight$
BEGIN
  IF to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.disputes') IS NULL
     OR to_regclass('public.dispute_lines') IS NULL
  THEN
    RAISE EXCEPTION 'Hybrid physical dispute compatibility prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL THEN
    RAISE EXCEPTION 'Expected physical_remedy_allocation_guard_v1() is missing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'dispute_lines'
      AND column_name = 'physical_remedy_allocation_id'
  ) OR to_regclass('public.physical_receipt_review_dispute_links') IS NOT NULL THEN
    RAISE EXCEPTION 'Physical dispute compatibility objects already exist; inspect the target rather than guessing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'dispute_lines'
      AND indexname = 'uq_dispute_lines_open'
      AND indexdef ILIKE '%(supplier_invoice_line_id)%'
      AND indexdef ILIKE '%resolved_at IS NULL%'
  ) THEN
    RAISE EXCEPTION 'Expected legacy open dispute-line uniqueness index is missing or changed.';
  END IF;
END
$preflight$;

ALTER TABLE public.dispute_lines
  ADD COLUMN physical_remedy_allocation_id uuid
  REFERENCES public.physical_exception_remedy_allocations(id)
  ON DELETE RESTRICT;

COMMENT ON COLUMN public.dispute_lines.physical_remedy_allocation_id IS
'Exact approved physical remedy allocation that created this dispute line. NULL preserves the legacy exception identity.';

CREATE UNIQUE INDEX uq_dispute_lines_physical_remedy
  ON public.dispute_lines(physical_remedy_allocation_id)
  WHERE physical_remedy_allocation_id IS NOT NULL;

DROP INDEX public.uq_dispute_lines_open;

CREATE UNIQUE INDEX uq_dispute_lines_open_legacy
  ON public.dispute_lines(supplier_invoice_line_id)
  WHERE resolved_at IS NULL
    AND physical_remedy_allocation_id IS NULL;

CREATE UNIQUE INDEX uq_dispute_lines_open_physical
  ON public.dispute_lines(physical_remedy_allocation_id)
  WHERE resolved_at IS NULL
    AND physical_remedy_allocation_id IS NOT NULL;

CREATE TABLE public.physical_receipt_review_dispute_links (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physical_receipt_review_id uuid NOT NULL
    REFERENCES public.physical_receipt_reviews(id) ON DELETE RESTRICT,
  dispute_id uuid NOT NULL
    REFERENCES public.disputes(id) ON DELETE RESTRICT,
  desired_outcome text NOT NULL
    CHECK (desired_outcome IN ('refund','replacement')),
  created_by_staff_id uuid NOT NULL
    REFERENCES public.staff(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT physical_review_dispute_link_pair_uq UNIQUE (
    physical_receipt_review_id,
    dispute_id
  )
);

COMMENT ON TABLE public.physical_receipt_review_dispute_links IS
'Immutable complete linkage from one physical receipt review to its outcome-specific existing disputes. physical_receipt_reviews.linked_dispute_id remains only the deterministic compatibility primary link.';

CREATE INDEX idx_physical_review_dispute_links_review
  ON public.physical_receipt_review_dispute_links(
    physical_receipt_review_id,
    desired_outcome,
    dispute_id
  );

ALTER TABLE public.physical_receipt_review_dispute_links ENABLE ROW LEVEL SECURITY;

CREATE POLICY physical_review_dispute_links_read_v1
ON public.physical_receipt_review_dispute_links
FOR SELECT TO authenticated
USING (
  public.is_active_staff()
  OR EXISTS (
    SELECT 1
    FROM public.physical_receipt_reviews review_row
    JOIN public.operator_importers access_row
      ON access_row.importer_id = review_row.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row
      ON operator_row.id = access_row.operator_id
    WHERE review_row.id = physical_receipt_review_dispute_links.physical_receipt_review_id
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
);

REVOKE INSERT, UPDATE, DELETE
ON public.physical_receipt_review_dispute_links
FROM authenticated;

GRANT SELECT
ON public.physical_receipt_review_dispute_links
TO authenticated;

CREATE FUNCTION public.physical_review_dispute_link_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_review_order_id uuid;
  v_dispute_order_id uuid;
  v_dispute_outcome text;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'Physical review/dispute links are immutable.';
  END IF;

  SELECT review_row.order_id
  INTO v_review_order_id
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = NEW.physical_receipt_review_id
  FOR SHARE;

  SELECT dispute_row.order_id, dispute_row.desired_outcome::text
  INTO v_dispute_order_id, v_dispute_outcome
  FROM public.disputes dispute_row
  WHERE dispute_row.id = NEW.dispute_id
  FOR SHARE;

  IF v_review_order_id IS NULL
     OR v_dispute_order_id IS DISTINCT FROM v_review_order_id
     OR v_dispute_outcome IS DISTINCT FROM NEW.desired_outcome
  THEN
    RAISE EXCEPTION 'Physical review/dispute link does not match the review order and dispute outcome.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.staff staff_row
    WHERE staff_row.id = NEW.created_by_staff_id
      AND COALESCE(staff_row.active, true) = true
  ) THEN
    RAISE EXCEPTION 'Physical review/dispute link requires an active staff actor.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_review_dispute_link_guard_v1
BEFORE INSERT OR UPDATE OR DELETE
ON public.physical_receipt_review_dispute_links
FOR EACH ROW
EXECUTE FUNCTION public.physical_review_dispute_link_guard_v1();

CREATE FUNCTION public.physical_dispute_line_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_remedy record;
  v_review_order_id uuid;
  v_dispute_order_id uuid;
  v_dispute_outcome text;
BEGIN
  IF NEW.physical_remedy_allocation_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.physical_remedy_allocation_id IS DISTINCT FROM OLD.physical_remedy_allocation_id
  THEN
    RAISE EXCEPTION 'Physical dispute-line source identity is immutable.';
  END IF;

  SELECT
    remedy_row.physical_receipt_review_id,
    remedy_row.supplier_invoice_line_id,
    remedy_row.approved_remedy_type,
    remedy_row.approved_remedy_qty,
    remedy_row.status
  INTO v_remedy
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.id = NEW.physical_remedy_allocation_id
  FOR SHARE;

  SELECT review_row.order_id
  INTO v_review_order_id
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = v_remedy.physical_receipt_review_id;

  SELECT dispute_row.order_id, dispute_row.desired_outcome::text
  INTO v_dispute_order_id, v_dispute_outcome
  FROM public.disputes dispute_row
  WHERE dispute_row.id = NEW.dispute_id;

  IF v_remedy.physical_receipt_review_id IS NULL
     OR v_remedy.status NOT IN ('approved','linked_to_exception','in_progress','completed')
     OR v_remedy.approved_remedy_type NOT IN ('refund','replacement')
     OR v_remedy.approved_remedy_qty IS NULL
     OR ABS(v_remedy.approved_remedy_qty - ROUND(v_remedy.approved_remedy_qty)) > 0.0005
     OR NEW.qty_impact IS DISTINCT FROM ROUND(v_remedy.approved_remedy_qty)::integer
     OR NEW.supplier_invoice_line_id IS DISTINCT FROM v_remedy.supplier_invoice_line_id
     OR v_dispute_order_id IS DISTINCT FROM v_review_order_id
     OR v_dispute_outcome IS DISTINCT FROM v_remedy.approved_remedy_type
     OR NEW.intended_remedy::text IS DISTINCT FROM v_remedy.approved_remedy_type
  THEN
    RAISE EXCEPTION 'Physical dispute line does not exactly match its approved whole-unit remedy, source line, order and outcome.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_dispute_line_guard_v1
BEFORE INSERT OR UPDATE OF
  dispute_id,
  supplier_invoice_line_id,
  qty_impact,
  intended_remedy,
  physical_remedy_allocation_id
ON public.dispute_lines
FOR EACH ROW
EXECUTE FUNCTION public.physical_dispute_line_guard_v1();

-- The foundation guard assumed one review could link to only one dispute.
-- Retain every existing rule while accepting any dispute proven in the immutable
-- review/dispute link set.
CREATE OR REPLACE FUNCTION public.physical_remedy_allocation_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_disposition public.shipper_package_receipt_line_dispositions%ROWTYPE;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_dispute_line_supplier_id uuid;
  v_dispute_order_id uuid;
  v_dispute_id uuid;
  v_child_order public.orders%ROWTYPE;
  v_child_allocation_order_id uuid;
  v_existing_qty numeric := 0;
  v_new_qty numeric := 0;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical remedy provenance cannot be deleted; cancel or reroute it through an audited transition.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'proposed'
       OR NEW.approved_remedy_type IS NOT NULL
       OR NEW.approved_remedy_qty IS NOT NULL
       OR NEW.approved_by_staff_id IS NOT NULL
       OR NEW.approved_at IS NOT NULL
       OR NEW.dispute_line_id IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
       OR NEW.rerouted_to_remedy_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION 'A remedy allocation must start as the importer proposal only.';
    END IF;
  ELSE
    IF NEW.physical_receipt_review_id IS DISTINCT FROM OLD.physical_receipt_review_id
       OR NEW.receipt_line_disposition_id IS DISTINCT FROM OLD.receipt_line_disposition_id
       OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
       OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
       OR NEW.proposed_remedy_type IS DISTINCT FROM OLD.proposed_remedy_type
       OR NEW.proposed_remedy_qty IS DISTINCT FROM OLD.proposed_remedy_qty
       OR NEW.proposed_by_operator_id IS DISTINCT FROM OLD.proposed_by_operator_id
       OR NEW.proposed_at IS DISTINCT FROM OLD.proposed_at
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
      RAISE EXCEPTION 'Importer remedy proposal and exact source identity are immutable; reroute with a new allocation.';
    END IF;

    IF OLD.approved_at IS NOT NULL
       AND (
         NEW.approved_remedy_type IS DISTINCT FROM OLD.approved_remedy_type
         OR NEW.approved_remedy_qty IS DISTINCT FROM OLD.approved_remedy_qty
         OR NEW.approved_by_staff_id IS DISTINCT FROM OLD.approved_by_staff_id
         OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       )
    THEN
      RAISE EXCEPTION 'Supervisor-approved remedy route and quantity are immutable; reroute with a new allocation.';
    END IF;

    IF OLD.status IN ('completed','closed_no_action','rerouted')
       AND NEW.status IS DISTINCT FROM OLD.status
    THEN
      RAISE EXCEPTION 'Completed, no-action or rerouted remedy state cannot be reopened.';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       AND NOT (
         (OLD.status = 'proposed' AND NEW.status IN ('approved','cancelled','rerouted'))
         OR (OLD.status = 'approved' AND NEW.status IN ('linked_to_exception','in_progress','completed','closed_no_action','cancelled','rerouted'))
         OR (OLD.status = 'linked_to_exception' AND NEW.status IN ('in_progress','completed','cancelled','rerouted'))
         OR (OLD.status = 'in_progress' AND NEW.status IN ('completed','cancelled','rerouted'))
         OR (OLD.status = 'cancelled' AND NEW.status = 'rerouted')
       )
    THEN
      RAISE EXCEPTION 'Invalid physical remedy state transition: % -> %', OLD.status, NEW.status;
    END IF;
  END IF;

  SELECT disposition.*
  INTO v_disposition
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.id = NEW.receipt_line_disposition_id
  FOR UPDATE;

  SELECT review_row.*
  INTO v_review
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = NEW.physical_receipt_review_id
  FOR SHARE;

  IF v_disposition.id IS NULL
     OR v_disposition.disposition_type = 'clean'
     OR v_review.id IS NULL
     OR v_review.receipt_id IS DISTINCT FROM v_disposition.receipt_id
     OR v_disposition.tracking_line_allocation_id IS DISTINCT FROM NEW.tracking_line_allocation_id
     OR v_disposition.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
  THEN
    RAISE EXCEPTION 'Physical remedy does not match one affected receipt disposition and review.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operators operator_row
    JOIN public.operator_importers access_row
      ON access_row.operator_id = operator_row.id
     AND access_row.importer_id = v_review.importer_id
     AND access_row.revoked_at IS NULL
    WHERE operator_row.id = NEW.proposed_by_operator_id
      AND COALESCE(operator_row.active, true) = true
  ) THEN
    RAISE EXCEPTION 'Remedy proposal actor is not an active operator for the review importer.';
  END IF;

  IF NEW.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action') THEN
    IF NEW.approved_remedy_type IS NULL
       OR NEW.approved_remedy_qty IS NULL
       OR NEW.approved_by_staff_id IS NULL
       OR NEW.approved_at IS NULL
       OR NOT EXISTS (
         SELECT 1 FROM public.staff staff_row
         WHERE staff_row.id = NEW.approved_by_staff_id
           AND COALESCE(staff_row.active, true) = true
       )
    THEN
      RAISE EXCEPTION 'Approved remedy state requires the exact supervisor-approved route, quantity, actor and timestamp.';
    END IF;
  END IF;

  IF NEW.approved_remedy_type = 'replacement' THEN
    IF NEW.supplier_cost_mode NOT IN ('free_replacement','charged_repurchase','pending_supplier_evidence') THEN
      RAISE EXCEPTION 'Approved replacement requires an explicit supplier cost mode.';
    END IF;
  ELSIF NEW.approved_remedy_type IS NOT NULL THEN
    IF COALESCE(NEW.supplier_cost_mode, 'not_applicable') <> 'not_applicable'
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION 'Non-replacement remedy cannot carry replacement supplier cost or child provenance.';
    END IF;
  ELSE
    IF NEW.supplier_cost_mode IS NOT NULL
       OR NEW.replacement_child_order_id IS NOT NULL
       OR NEW.replacement_child_tracking_allocation_id IS NOT NULL
    THEN
      RAISE EXCEPTION 'Unapproved proposal cannot carry replacement cost or child provenance.';
    END IF;
  END IF;

  IF NEW.status IN ('linked_to_exception','in_progress','completed')
     AND NEW.approved_remedy_type IN ('refund','replacement')
     AND NEW.dispute_line_id IS NULL
  THEN
    RAISE EXCEPTION 'Progressed refund/replacement remedy requires its exact existing dispute line.';
  END IF;

  IF NEW.dispute_line_id IS NOT NULL THEN
    SELECT dispute_line.supplier_invoice_line_id, dispute_row.order_id, dispute_row.id
    INTO v_dispute_line_supplier_id, v_dispute_order_id, v_dispute_id
    FROM public.dispute_lines dispute_line
    JOIN public.disputes dispute_row ON dispute_row.id = dispute_line.dispute_id
    WHERE dispute_line.id = NEW.dispute_line_id;

    IF v_dispute_line_supplier_id IS DISTINCT FROM NEW.supplier_invoice_line_id
       OR v_dispute_order_id IS DISTINCT FROM v_review.order_id
       OR NOT EXISTS (
         SELECT 1
         FROM public.physical_receipt_review_dispute_links link_row
         WHERE link_row.physical_receipt_review_id = v_review.id
           AND link_row.dispute_id = v_dispute_id
           AND link_row.desired_outcome = NEW.approved_remedy_type
       )
    THEN
      RAISE EXCEPTION 'Physical remedy dispute line does not match the exact source line, order and linked outcome-specific dispute.';
    END IF;
  END IF;

  IF NEW.approved_remedy_type = 'replacement' AND NEW.status IN ('in_progress','completed') THEN
    IF NEW.replacement_child_order_id IS NULL THEN
      RAISE EXCEPTION 'Replacement in progress or completed requires its exact replacement child order.';
    END IF;

    SELECT child.* INTO v_child_order
    FROM public.orders child
    WHERE child.id = NEW.replacement_child_order_id;

    IF v_child_order.id IS NULL
       OR v_child_order.order_type IS DISTINCT FROM 'replacement_child'
       OR v_child_order.parent_order_id IS DISTINCT FROM v_review.order_id
       OR (v_child_order.replacement_source_dispute_line_id IS NOT NULL
           AND v_child_order.replacement_source_dispute_line_id IS DISTINCT FROM NEW.dispute_line_id)
    THEN
      RAISE EXCEPTION 'Replacement child does not match the parent order and source dispute line.';
    END IF;
  END IF;

  IF NEW.status = 'completed' AND NEW.approved_remedy_type = 'replacement' THEN
    IF NEW.replacement_child_tracking_allocation_id IS NULL THEN
      RAISE EXCEPTION 'Completed replacement requires exact replacement-child tracking allocation provenance.';
    END IF;

    SELECT allocation.order_id INTO v_child_allocation_order_id
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.id = NEW.replacement_child_tracking_allocation_id;

    IF v_child_allocation_order_id IS DISTINCT FROM NEW.replacement_child_order_id THEN
      RAISE EXCEPTION 'Replacement-child tracking allocation does not belong to the replacement child order.';
    END IF;
  END IF;

  IF NEW.status = 'closed_no_action' AND NEW.approved_remedy_type IS DISTINCT FROM 'no_action' THEN
    RAISE EXCEPTION 'Closed-no-action status requires an approved no-action route.';
  END IF;

  IF NEW.status = 'rerouted' THEN
    IF NEW.rerouted_to_remedy_allocation_id IS NULL
       OR NEW.rerouted_to_remedy_allocation_id = NEW.id
       OR NOT EXISTS (
         SELECT 1
         FROM public.physical_exception_remedy_allocations target
         WHERE target.id = NEW.rerouted_to_remedy_allocation_id
           AND target.physical_receipt_review_id = NEW.physical_receipt_review_id
           AND target.receipt_line_disposition_id = NEW.receipt_line_disposition_id
       )
    THEN
      RAISE EXCEPTION 'Rerouted remedy must identify a different allocation for the same review and affected disposition.';
    END IF;
  ELSIF NEW.rerouted_to_remedy_allocation_id IS NOT NULL THEN
    RAISE EXCEPTION 'Only a rerouted remedy may carry a reroute target.';
  END IF;

  SELECT COALESCE(SUM(
    CASE
      WHEN remedy_row.status = 'proposed' THEN remedy_row.proposed_remedy_qty
      WHEN remedy_row.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action')
        THEN remedy_row.approved_remedy_qty
      ELSE 0
    END
  ), 0)::numeric
  INTO v_existing_qty
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.receipt_line_disposition_id = NEW.receipt_line_disposition_id
    AND (TG_OP = 'INSERT' OR remedy_row.id <> NEW.id);

  v_new_qty := CASE
    WHEN NEW.status = 'proposed' THEN NEW.proposed_remedy_qty
    WHEN NEW.status IN ('approved','linked_to_exception','in_progress','completed','closed_no_action')
      THEN NEW.approved_remedy_qty
    ELSE 0
  END;

  IF v_existing_qty + COALESCE(v_new_qty, 0) > v_disposition.quantity + 0.0005 THEN
    RAISE EXCEPTION 'Proposed/approved remedy quantity exceeds the affected receipt quantity.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

NOTIFY pgrst, 'reload schema';

COMMIT;
