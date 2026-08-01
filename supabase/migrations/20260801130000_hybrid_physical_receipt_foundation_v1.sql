BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Hybrid physical receipt foundation only.
-- Additive objects and private read model; no existing workflow function/view is replaced.

DO $preflight$
DECLARE
  v_missing text[] := ARRAY[]::text[];
  v_receipt_v1_fingerprint text;
BEGIN
  IF to_regclass('public.shipper_package_receipts') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_package_receipts');
  END IF;
  IF to_regclass('public.order_tracking_line_allocations') IS NULL THEN
    v_missing := array_append(v_missing, 'order_tracking_line_allocations');
  END IF;
  IF to_regclass('public.order_tracking_submissions') IS NULL THEN
    v_missing := array_append(v_missing, 'order_tracking_submissions');
  END IF;
  IF to_regclass('public.supplier_invoice_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'supplier_invoice_lines');
  END IF;
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_review_cycle_memberships');
  END IF;
  IF to_regclass('public.customer_hold_review_memberships') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_hold_review_memberships');
  END IF;
  IF to_regclass('public.customer_pre_shipment_hold_requests') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_pre_shipment_hold_requests');
  END IF;
  IF to_regclass('public.shipper_shipment_batches') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_shipment_batches');
  END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'customer_sales_release_lines');
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    v_missing := array_append(v_missing, 'disputes');
  END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'dispute_lines');
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    v_missing := array_append(v_missing, 'orders');
  END IF;
  IF to_regclass('public.staff') IS NULL THEN
    v_missing := array_append(v_missing, 'staff');
  END IF;
  IF to_regclass('public.operators') IS NULL THEN
    v_missing := array_append(v_missing, 'operators');
  END IF;
  IF to_regclass('public.operator_importers') IS NULL THEN
    v_missing := array_append(v_missing, 'operator_importers');
  END IF;
  IF to_regclass('public.shipper_users') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_users');
  END IF;
  IF to_regprocedure('public.is_active_staff()') IS NULL THEN
    v_missing := array_append(v_missing, 'is_active_staff()');
  END IF;
  IF to_regprocedure('public.shipper_record_package_receipt_v1(uuid,text,text,text)') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_record_package_receipt_v1(uuid,text,text,text)');
  END IF;
  IF to_regprocedure('public.shipper_shipment_batch_effective_lines_v1(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'shipper_shipment_batch_effective_lines_v1(uuid)');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Hybrid receipt foundation prerequisites missing: %', array_to_string(v_missing, ', ');
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)'::regprocedure
  )) INTO v_receipt_v1_fingerprint;

  IF v_receipt_v1_fingerprint <> '27fb972b34258990cfa9d752cd2f927b' THEN
    RAISE EXCEPTION
      'shipper_record_package_receipt_v1 changed after preflight (current fingerprint %). Stop rather than overwrite an unaudited baseline.',
      v_receipt_v1_fingerprint;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'shipper_package_receipts'
      AND column_name IN (
        'receipt_model_version',
        'receipt_submission_id',
        'payload_fingerprint',
        'finalised_at',
        'correction_of_receipt_id',
        'correction_reason'
      )
  ) THEN
    RAISE EXCEPTION 'Hybrid receipt foundation columns already exist; inspect the target before applying this migration.';
  END IF;

  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NOT NULL
     OR to_regclass('public.shipper_package_receipt_evidence') IS NOT NULL
     OR to_regclass('public.physical_receipt_reviews') IS NOT NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NOT NULL
     OR to_regclass('public.tracking_allocation_fulfilment_position_v1') IS NOT NULL
  THEN
    RAISE EXCEPTION 'One or more hybrid receipt foundation objects already exist; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

ALTER TABLE public.shipper_package_receipts
  ADD COLUMN receipt_model_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN receipt_submission_id uuid,
  ADD COLUMN payload_fingerprint text,
  ADD COLUMN finalised_at timestamptz,
  ADD COLUMN correction_of_receipt_id uuid,
  ADD COLUMN correction_reason text;

ALTER TABLE public.shipper_package_receipts
  ADD CONSTRAINT shipper_package_receipts_model_version_chk
    CHECK (receipt_model_version IN (1, 2)),
  ADD CONSTRAINT shipper_package_receipts_v2_shape_chk
    CHECK (
      (
        receipt_model_version = 1
        AND receipt_submission_id IS NULL
        AND payload_fingerprint IS NULL
        AND finalised_at IS NULL
        AND correction_of_receipt_id IS NULL
        AND correction_reason IS NULL
      )
      OR
      (
        receipt_model_version = 2
        AND receipt_submission_id IS NOT NULL
        AND NULLIF(BTRIM(COALESCE(payload_fingerprint, '')), '') IS NOT NULL
        AND (
          (correction_of_receipt_id IS NULL AND correction_reason IS NULL)
          OR
          (
            correction_of_receipt_id IS NOT NULL
            AND NULLIF(BTRIM(COALESCE(correction_reason, '')), '') IS NOT NULL
          )
        )
      )
    ),
  ADD CONSTRAINT shipper_package_receipts_correction_fkey
    FOREIGN KEY (correction_of_receipt_id)
    REFERENCES public.shipper_package_receipts(id)
    ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_shipper_package_receipts_submission_v2
  ON public.shipper_package_receipts(receipt_submission_id)
  WHERE receipt_submission_id IS NOT NULL;

CREATE UNIQUE INDEX uq_shipper_package_receipts_finalised_correction_v2
  ON public.shipper_package_receipts(correction_of_receipt_id)
  WHERE correction_of_receipt_id IS NOT NULL
    AND finalised_at IS NOT NULL;

COMMENT ON COLUMN public.shipper_package_receipts.receipt_model_version IS
'1 = legacy package-header receipt; 2 = exact line-disposition receipt. Existing rows remain version 1.';
COMMENT ON COLUMN public.shipper_package_receipts.finalised_at IS
'Non-null only after every positive tracking allocation balances exactly in a v2 receipt snapshot.';
COMMENT ON COLUMN public.shipper_package_receipts.receipt_submission_id IS
'Idempotency identity for a v2 receipt submission.';
COMMENT ON COLUMN public.shipper_package_receipts.payload_fingerprint IS
'Canonical v2 submission fingerprint used to reject changed retries.';

CREATE TABLE public.shipper_package_receipt_line_dispositions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  tracking_submission_id uuid NOT NULL REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  disposition_type text NOT NULL CHECK (disposition_type IN ('clean','damaged','missing','wrong','held')),
  quantity numeric(12,3) NOT NULL CHECK (quantity > 0),
  condition_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shipper_receipt_line_disposition_uq UNIQUE (
    receipt_id,
    tracking_line_allocation_id,
    disposition_type
  )
);

COMMENT ON TABLE public.shipper_package_receipt_line_dispositions IS
'Immutable exact physical quantity dispositions within one finalisable shipper receipt snapshot. This extends shipper_package_receipts and does not duplicate supplier or order lines.';

CREATE INDEX idx_shipper_receipt_dispositions_receipt
  ON public.shipper_package_receipt_line_dispositions(receipt_id, created_at);
CREATE INDEX idx_shipper_receipt_dispositions_allocation
  ON public.shipper_package_receipt_line_dispositions(tracking_line_allocation_id, receipt_id);
CREATE INDEX idx_shipper_receipt_dispositions_affected
  ON public.shipper_package_receipt_line_dispositions(receipt_id, disposition_type)
  WHERE disposition_type <> 'clean';

CREATE TABLE public.shipper_package_receipt_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  line_disposition_id uuid REFERENCES public.shipper_package_receipt_line_dispositions(id) ON DELETE RESTRICT,
  storage_object_path text NOT NULL CHECK (NULLIF(BTRIM(storage_object_path), '') IS NOT NULL),
  original_filename text,
  content_type text,
  display_order integer NOT NULL DEFAULT 0 CHECK (display_order >= 0),
  uploaded_by_shipper_user_id uuid NOT NULL REFERENCES public.shipper_users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shipper_receipt_evidence_path_uq UNIQUE (receipt_id, storage_object_path)
);

COMMENT ON TABLE public.shipper_package_receipt_evidence IS
'Immutable multiple evidence references for a shipper receipt, optionally linked to one exact affected disposition.';

CREATE INDEX idx_shipper_receipt_evidence_receipt
  ON public.shipper_package_receipt_evidence(receipt_id, display_order, created_at);
CREATE INDEX idx_shipper_receipt_evidence_disposition
  ON public.shipper_package_receipt_evidence(line_disposition_id)
  WHERE line_disposition_id IS NOT NULL;

CREATE TABLE public.physical_receipt_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL UNIQUE REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  tracking_submission_id uuid NOT NULL REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'awaiting_importer_proposal'
    CHECK (status IN (
      'awaiting_importer_proposal',
      'awaiting_supervisor_review',
      'returned_for_information',
      'approved_to_existing_exception',
      'rejected',
      'closed_no_action'
    )),
  importer_proposed_by_operator_id uuid REFERENCES public.operators(id) ON DELETE RESTRICT,
  importer_proposed_at timestamptz,
  supervisor_decided_by_staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT,
  supervisor_decided_at timestamptz,
  decision_note text,
  linked_dispute_id uuid REFERENCES public.disputes(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT physical_receipt_review_importer_shape_chk CHECK (
    (importer_proposed_by_operator_id IS NULL AND importer_proposed_at IS NULL)
    OR (importer_proposed_by_operator_id IS NOT NULL AND importer_proposed_at IS NOT NULL)
  ),
  CONSTRAINT physical_receipt_review_supervisor_shape_chk CHECK (
    (supervisor_decided_by_staff_id IS NULL AND supervisor_decided_at IS NULL)
    OR (supervisor_decided_by_staff_id IS NOT NULL AND supervisor_decided_at IS NOT NULL)
  ),
  CONSTRAINT physical_receipt_review_proposal_required_chk CHECK (
    status = 'awaiting_importer_proposal'
    OR (importer_proposed_by_operator_id IS NOT NULL AND importer_proposed_at IS NOT NULL)
  ),
  CONSTRAINT physical_receipt_review_decision_required_chk CHECK (
    status NOT IN (
      'returned_for_information',
      'approved_to_existing_exception',
      'rejected',
      'closed_no_action'
    )
    OR (supervisor_decided_by_staff_id IS NOT NULL AND supervisor_decided_at IS NOT NULL)
  ),
  CONSTRAINT physical_receipt_review_note_required_chk CHECK (
    status NOT IN ('returned_for_information','rejected','closed_no_action')
    OR NULLIF(BTRIM(COALESCE(decision_note, '')), '') IS NOT NULL
  ),
  CONSTRAINT physical_receipt_review_link_shape_chk CHECK (
    status <> 'approved_to_existing_exception'
    OR linked_dispute_id IS NOT NULL
  )
);

COMMENT ON TABLE public.physical_receipt_reviews IS
'Physical-receipt triage and route-approval header only. Existing disputes and retailer conversations remain authoritative after linkage.';

CREATE INDEX idx_physical_receipt_reviews_status
  ON public.physical_receipt_reviews(status, created_at);
CREATE INDEX idx_physical_receipt_reviews_order
  ON public.physical_receipt_reviews(order_id, created_at);
CREATE INDEX idx_physical_receipt_reviews_dispute
  ON public.physical_receipt_reviews(linked_dispute_id)
  WHERE linked_dispute_id IS NOT NULL;

CREATE TABLE public.physical_exception_remedy_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physical_receipt_review_id uuid NOT NULL REFERENCES public.physical_receipt_reviews(id) ON DELETE RESTRICT,
  receipt_line_disposition_id uuid NOT NULL REFERENCES public.shipper_package_receipt_line_dispositions(id) ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  dispute_line_id uuid REFERENCES public.dispute_lines(id) ON DELETE RESTRICT,
  remedy_type text NOT NULL CHECK (remedy_type IN ('refund','replacement','hold_investigate','no_action')),
  remedy_qty numeric(12,3) NOT NULL CHECK (remedy_qty > 0),
  supplier_claim_amount_gbp numeric(14,2)
    CHECK (supplier_claim_amount_gbp IS NULL OR supplier_claim_amount_gbp >= 0),
  customer_commercial_value_gbp numeric(14,2)
    CHECK (customer_commercial_value_gbp IS NULL OR customer_commercial_value_gbp >= 0),
  supplier_cost_mode text
    CHECK (supplier_cost_mode IS NULL OR supplier_cost_mode IN (
      'free_replacement',
      'charged_repurchase',
      'pending_supplier_evidence',
      'not_applicable'
    )),
  replacement_child_order_id uuid REFERENCES public.orders(id) ON DELETE RESTRICT,
  replacement_child_tracking_allocation_id uuid
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN (
      'proposed',
      'approved',
      'in_progress',
      'completed',
      'cancelled',
      'rerouted',
      'closed_no_action'
    )),
  approved_by_staff_id uuid REFERENCES public.staff(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT physical_remedy_approval_shape_chk CHECK (
    (approved_by_staff_id IS NULL AND approved_at IS NULL)
    OR (approved_by_staff_id IS NOT NULL AND approved_at IS NOT NULL)
  ),
  CONSTRAINT physical_remedy_replacement_shape_chk CHECK (
    (
      remedy_type = 'replacement'
      AND supplier_cost_mode IS NOT NULL
      AND supplier_cost_mode IN (
        'free_replacement',
        'charged_repurchase',
        'pending_supplier_evidence'
      )
    )
    OR
    (
      remedy_type <> 'replacement'
      AND COALESCE(supplier_cost_mode, 'not_applicable') = 'not_applicable'
      AND replacement_child_order_id IS NULL
      AND replacement_child_tracking_allocation_id IS NULL
    )
  ),
  CONSTRAINT physical_remedy_approved_status_chk CHECK (
    status NOT IN ('approved','in_progress','completed','closed_no_action')
    OR (approved_by_staff_id IS NOT NULL AND approved_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.physical_exception_remedy_allocations IS
'Exact proposed/approved split of physically affected quantity. This is provenance and quantity control, not a second dispute/refund/replacement state machine.';

CREATE INDEX idx_physical_remedy_review_status
  ON public.physical_exception_remedy_allocations(physical_receipt_review_id, status);
CREATE INDEX idx_physical_remedy_source_status
  ON public.physical_exception_remedy_allocations(receipt_line_disposition_id, status);
CREATE INDEX idx_physical_remedy_allocation_status
  ON public.physical_exception_remedy_allocations(tracking_line_allocation_id, status);
CREATE UNIQUE INDEX uq_physical_remedy_replacement_child
  ON public.physical_exception_remedy_allocations(replacement_child_order_id)
  WHERE replacement_child_order_id IS NOT NULL;

ALTER TABLE public.shipper_package_receipt_line_dispositions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipper_package_receipt_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_receipt_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.physical_exception_remedy_allocations ENABLE ROW LEVEL SECURITY;

CREATE POLICY shipper_receipt_dispositions_read_v1
ON public.shipper_package_receipt_line_dispositions
FOR SELECT TO authenticated
USING (
  public.is_active_staff()
  OR EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    JOIN public.shipper_users shipper_user ON shipper_user.shipper_id = receipt.shipper_id
    WHERE receipt.id = shipper_package_receipt_line_dispositions.receipt_id
      AND shipper_user.auth_user_id = auth.uid()
      AND shipper_user.active = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    JOIN public.orders order_row ON order_row.id = receipt.order_id
    JOIN public.operator_importers access_row
      ON access_row.importer_id = order_row.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row ON operator_row.id = access_row.operator_id
    WHERE receipt.id = shipper_package_receipt_line_dispositions.receipt_id
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
);

CREATE POLICY shipper_receipt_evidence_read_v1
ON public.shipper_package_receipt_evidence
FOR SELECT TO authenticated
USING (
  public.is_active_staff()
  OR EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    JOIN public.shipper_users shipper_user ON shipper_user.shipper_id = receipt.shipper_id
    WHERE receipt.id = shipper_package_receipt_evidence.receipt_id
      AND shipper_user.auth_user_id = auth.uid()
      AND shipper_user.active = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    JOIN public.orders order_row ON order_row.id = receipt.order_id
    JOIN public.operator_importers access_row
      ON access_row.importer_id = order_row.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row ON operator_row.id = access_row.operator_id
    WHERE receipt.id = shipper_package_receipt_evidence.receipt_id
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
);

CREATE POLICY physical_receipt_reviews_read_v1
ON public.physical_receipt_reviews
FOR SELECT TO authenticated
USING (
  public.is_active_staff()
  OR EXISTS (
    SELECT 1
    FROM public.orders order_row
    JOIN public.operator_importers access_row
      ON access_row.importer_id = order_row.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row ON operator_row.id = access_row.operator_id
    WHERE order_row.id = physical_receipt_reviews.order_id
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
  OR EXISTS (
    SELECT 1
    FROM public.shipper_package_receipts receipt
    JOIN public.shipper_users shipper_user ON shipper_user.shipper_id = receipt.shipper_id
    WHERE receipt.id = physical_receipt_reviews.receipt_id
      AND shipper_user.auth_user_id = auth.uid()
      AND shipper_user.active = true
  )
);

CREATE POLICY physical_remedy_allocations_read_v1
ON public.physical_exception_remedy_allocations
FOR SELECT TO authenticated
USING (
  public.is_active_staff()
  OR EXISTS (
    SELECT 1
    FROM public.physical_receipt_reviews review_row
    JOIN public.orders order_row ON order_row.id = review_row.order_id
    JOIN public.operator_importers access_row
      ON access_row.importer_id = order_row.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row ON operator_row.id = access_row.operator_id
    WHERE review_row.id = physical_exception_remedy_allocations.physical_receipt_review_id
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
);

REVOKE ALL ON public.shipper_package_receipt_line_dispositions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.shipper_package_receipt_evidence FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.physical_receipt_reviews FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.physical_exception_remedy_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.shipper_package_receipt_line_dispositions TO authenticated;
GRANT SELECT ON public.shipper_package_receipt_evidence TO authenticated;
GRANT SELECT ON public.physical_receipt_reviews TO authenticated;
GRANT SELECT ON public.physical_exception_remedy_allocations TO authenticated;
GRANT ALL ON public.shipper_package_receipt_line_dispositions TO service_role;
GRANT ALL ON public.shipper_package_receipt_evidence TO service_role;
GRANT ALL ON public.physical_receipt_reviews TO service_role;
GRANT ALL ON public.physical_exception_remedy_allocations TO service_role;

CREATE FUNCTION public.shipper_receipt_line_disposition_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_receipt public.shipper_package_receipts%ROWTYPE;
  v_allocation public.order_tracking_line_allocations%ROWTYPE;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'Physical receipt line dispositions are immutable; create a later corrected receipt snapshot.';
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.shipper_package_receipts receipt
  WHERE receipt.id = NEW.receipt_id
  FOR UPDATE;

  IF v_receipt.id IS NULL OR v_receipt.receipt_model_version <> 2 THEN
    RAISE EXCEPTION 'Line dispositions may be written only to a v2 receipt.';
  END IF;
  IF v_receipt.finalised_at IS NOT NULL THEN
    RAISE EXCEPTION 'Finalised physical receipt facts are immutable.';
  END IF;
  IF NEW.tracking_submission_id IS DISTINCT FROM v_receipt.tracking_submission_id THEN
    RAISE EXCEPTION 'Disposition tracking identity does not match its receipt.';
  END IF;

  SELECT allocation.* INTO v_allocation
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.id = NEW.tracking_line_allocation_id
  FOR SHARE;

  IF v_allocation.id IS NULL
     OR v_allocation.order_id IS DISTINCT FROM v_receipt.order_id
     OR v_allocation.tracking_submission_id IS DISTINCT FROM v_receipt.tracking_submission_id
     OR v_allocation.supplier_invoice_line_id IS DISTINCT FROM NEW.supplier_invoice_line_id
     OR COALESCE(v_allocation.qty_allocated, 0) <= 0
  THEN
    RAISE EXCEPTION 'Disposition does not match one positive exact tracking allocation.';
  END IF;

  IF NEW.quantity > v_allocation.qty_allocated + 0.0005 THEN
    RAISE EXCEPTION 'Disposition quantity exceeds the exact tracking allocation.';
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_receipt_line_disposition_guard_v1
BEFORE INSERT OR UPDATE OR DELETE ON public.shipper_package_receipt_line_dispositions
FOR EACH ROW EXECUTE FUNCTION public.shipper_receipt_line_disposition_guard_v1();

CREATE FUNCTION public.shipper_receipt_evidence_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_receipt public.shipper_package_receipts%ROWTYPE;
  v_line_receipt_id uuid;
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN
    RAISE EXCEPTION 'Physical receipt evidence metadata is immutable.';
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.shipper_package_receipts receipt
  WHERE receipt.id = NEW.receipt_id
  FOR UPDATE;

  IF v_receipt.id IS NULL
     OR v_receipt.receipt_model_version <> 2
     OR v_receipt.finalised_at IS NOT NULL
  THEN
    RAISE EXCEPTION 'Evidence may be attached only while a v2 receipt is being assembled.';
  END IF;

  IF NEW.uploaded_by_shipper_user_id IS DISTINCT FROM v_receipt.shipper_user_id THEN
    RAISE EXCEPTION 'Evidence uploader does not match the receipt shipper user.';
  END IF;

  IF NEW.line_disposition_id IS NOT NULL THEN
    SELECT disposition.receipt_id INTO v_line_receipt_id
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.id = NEW.line_disposition_id;

    IF v_line_receipt_id IS DISTINCT FROM NEW.receipt_id THEN
      RAISE EXCEPTION 'Evidence disposition does not belong to the same receipt.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_receipt_evidence_guard_v1
BEFORE INSERT OR UPDATE OR DELETE ON public.shipper_package_receipt_evidence
FOR EACH ROW EXECUTE FUNCTION public.shipper_receipt_evidence_guard_v1();

CREATE FUNCTION public.shipper_package_receipt_v2_integrity_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_missing_count integer;
  v_mismatch_count integer;
  v_clean_qty numeric := 0;
  v_affected_qty numeric := 0;
  v_downstream_conflict_count integer := 0;
  v_unproven_hold_count integer := 0;
  v_source public.shipper_package_receipts%ROWTYPE;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.receipt_model_version = 2 AND NEW.finalised_at IS NOT NULL THEN
      RAISE EXCEPTION 'A v2 receipt must be assembled before it is finalised.';
    END IF;
    IF NEW.receipt_model_version = 2 AND NEW.receipt_status = 'received_clean' THEN
      RAISE EXCEPTION 'A draft v2 receipt must use a non-clean assembly summary until exact lines are finalised.';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.receipt_model_version IS DISTINCT FROM NEW.receipt_model_version THEN
    RAISE EXCEPTION 'Receipt model version is immutable.';
  END IF;

  -- Existing v1 rows/callers retain their current behaviour.
  IF OLD.receipt_model_version = 1 THEN
    RETURN NEW;
  END IF;

  IF OLD.finalised_at IS NOT NULL THEN
    IF to_jsonb(NEW) IS DISTINCT FROM to_jsonb(OLD) THEN
      RAISE EXCEPTION 'Finalised v2 receipt headers are immutable.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.tracking_submission_id IS DISTINCT FROM OLD.tracking_submission_id
     OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.shipper_id IS DISTINCT FROM OLD.shipper_id
     OR NEW.shipper_user_id IS DISTINCT FROM OLD.shipper_user_id
     OR NEW.receipt_submission_id IS DISTINCT FROM OLD.receipt_submission_id
     OR NEW.payload_fingerprint IS DISTINCT FROM OLD.payload_fingerprint
     OR NEW.correction_of_receipt_id IS DISTINCT FROM OLD.correction_of_receipt_id
     OR NEW.correction_reason IS DISTINCT FROM OLD.correction_reason
     OR NEW.recorded_at IS DISTINCT FROM OLD.recorded_at
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
  THEN
    RAISE EXCEPTION 'V2 receipt source identity and idempotency fields are immutable.';
  END IF;

  IF NEW.finalised_at IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.correction_of_receipt_id IS NOT NULL THEN
    SELECT source_receipt.* INTO v_source
    FROM public.shipper_package_receipts source_receipt
    WHERE source_receipt.id = NEW.correction_of_receipt_id
    FOR SHARE;

    IF v_source.id IS NULL
       OR v_source.id = NEW.id
       OR v_source.tracking_submission_id IS DISTINCT FROM NEW.tracking_submission_id
       OR v_source.order_id IS DISTINCT FROM NEW.order_id
       OR v_source.shipper_id IS DISTINCT FROM NEW.shipper_id
    THEN
      RAISE EXCEPTION 'Correction source does not match the same package, order and shipper.';
    END IF;
  END IF;

  WITH expected AS (
    SELECT allocation.id, allocation.qty_allocated
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = NEW.order_id
      AND allocation.tracking_submission_id = NEW.tracking_submission_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
  ), actual AS (
    SELECT disposition.tracking_line_allocation_id AS id,
           SUM(disposition.quantity)::numeric AS disposition_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.id
    GROUP BY disposition.tracking_line_allocation_id
  )
  SELECT
    COUNT(*) FILTER (WHERE actual.id IS NULL)::integer,
    COUNT(*) FILTER (
      WHERE actual.id IS NOT NULL
        AND ABS(actual.disposition_qty - expected.qty_allocated) > 0.0005
    )::integer
  INTO v_missing_count, v_mismatch_count
  FROM expected
  LEFT JOIN actual ON actual.id = expected.id;

  IF NOT EXISTS (
    SELECT 1
    FROM public.order_tracking_line_allocations allocation
    WHERE allocation.order_id = NEW.order_id
      AND allocation.tracking_submission_id = NEW.tracking_submission_id
      AND COALESCE(allocation.qty_allocated, 0) > 0
  ) THEN
    RAISE EXCEPTION 'V2 receipt has no positive exact tracking allocations.';
  END IF;

  IF COALESCE(v_missing_count, 0) > 0 OR COALESCE(v_mismatch_count, 0) > 0 THEN
    RAISE EXCEPTION
      'V2 receipt is incomplete or unbalanced: % allocation(s) missing and % allocation(s) mismatched.',
      COALESCE(v_missing_count, 0), COALESCE(v_mismatch_count, 0);
  END IF;

  SELECT
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'clean'
    ), 0)::numeric,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type <> 'clean'
    ), 0)::numeric
  INTO v_clean_qty, v_affected_qty
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.receipt_id = NEW.id;

  IF v_affected_qty = 0 AND NEW.receipt_status IS DISTINCT FROM 'received_clean' THEN
    RAISE EXCEPTION 'An all-clean v2 receipt must retain the received_clean compatibility summary.';
  END IF;
  IF v_affected_qty > 0 AND NEW.receipt_status = 'received_clean' THEN
    RAISE EXCEPTION 'A v2 receipt containing affected quantity cannot use a received_clean summary.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.id
      AND disposition.disposition_type <> 'clean'
      AND NULLIF(BTRIM(COALESCE(disposition.condition_note, '')), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'Every affected disposition requires a factual condition note.';
  END IF;

  IF v_affected_qty > 0 AND NOT EXISTS (
    SELECT 1
    FROM public.shipper_package_receipt_evidence evidence
    WHERE evidence.receipt_id = NEW.id
  ) THEN
    RAISE EXCEPTION 'A v2 receipt containing affected quantity requires evidence.';
  END IF;

  -- A correction cannot invalidate already-used clean or affected quantity.
  WITH actual AS (
    SELECT
      disposition.tracking_line_allocation_id,
      COALESCE(SUM(disposition.quantity) FILTER (
        WHERE disposition.disposition_type = 'clean'
      ), 0)::numeric AS clean_qty,
      COALESCE(SUM(disposition.quantity) FILTER (
        WHERE disposition.disposition_type <> 'clean'
      ), 0)::numeric AS exception_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.id
    GROUP BY disposition.tracking_line_allocation_id
  ), reviewed AS (
    SELECT membership.tracking_line_allocation_id,
           COALESCE(SUM(membership.review_qty), 0)::numeric AS qty
    FROM public.customer_review_cycle_memberships membership
    GROUP BY membership.tracking_line_allocation_id
  ), exact_hold AS (
    SELECT review_membership.tracking_line_allocation_id,
           COALESCE(SUM(hold_membership.affected_qty), 0)::numeric AS qty
    FROM public.customer_hold_review_memberships hold_membership
    JOIN public.customer_review_cycle_memberships review_membership
      ON review_membership.id = hold_membership.review_membership_id
    JOIN public.customer_pre_shipment_hold_requests hold_row
      ON hold_row.id = hold_membership.hold_request_id
    WHERE hold_membership.membership_status = 'active'
      AND hold_row.status IN ('requested','supervisor_approved')
    GROUP BY review_membership.tracking_line_allocation_id
  ), shipped AS (
    SELECT effective_line.tracking_line_allocation_id,
           COALESCE(SUM(effective_line.qty_in_shipment), 0)::numeric AS qty
    FROM public.shipper_shipment_batches batch_row
    CROSS JOIN LATERAL
      public.shipper_shipment_batch_effective_lines_v1(batch_row.id) effective_line
    WHERE batch_row.status <> 'voided'
    GROUP BY effective_line.tracking_line_allocation_id
  ), released AS (
    SELECT release_line.tracking_line_allocation_id,
           COALESCE(SUM(release_line.released_qty), 0)::numeric AS qty
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.release_status = 'active'
    GROUP BY release_line.tracking_line_allocation_id
  ), remedy AS (
    SELECT remedy_row.tracking_line_allocation_id,
           COALESCE(SUM(remedy_row.remedy_qty), 0)::numeric AS qty
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.status IN (
      'proposed','approved','in_progress','completed','closed_no_action'
    )
    GROUP BY remedy_row.tracking_line_allocation_id
  )
  SELECT COUNT(*)::integer
  INTO v_downstream_conflict_count
  FROM actual
  LEFT JOIN reviewed ON reviewed.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN exact_hold ON exact_hold.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN shipped ON shipped.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN released ON released.tracking_line_allocation_id = actual.tracking_line_allocation_id
  LEFT JOIN remedy ON remedy.tracking_line_allocation_id = actual.tracking_line_allocation_id
  WHERE actual.clean_qty + 0.0005 < GREATEST(
          COALESCE(reviewed.qty, 0),
          COALESCE(shipped.qty, 0),
          COALESCE(released.qty, 0)
        )
     OR actual.clean_qty + 0.0005 < COALESCE(exact_hold.qty, 0) + COALESCE(shipped.qty, 0)
     OR actual.exception_qty + 0.0005 < COALESCE(remedy.qty, 0);

  SELECT COUNT(*)::integer
  INTO v_unproven_hold_count
  FROM public.order_tracking_line_allocations allocation
  WHERE allocation.order_id = NEW.order_id
    AND allocation.tracking_submission_id = NEW.tracking_submission_id
    AND COALESCE(allocation.qty_allocated, 0) > 0
    AND EXISTS (
      SELECT 1
      FROM public.customer_pre_shipment_hold_requests hold_row
      WHERE hold_row.order_id = allocation.order_id
        AND hold_row.status IN ('requested','supervisor_approved')
        AND (
          hold_row.requested_scope = 'order'
          OR (
            hold_row.requested_scope = 'tracking'
            AND hold_row.tracking_submission_id = allocation.tracking_submission_id
          )
          OR (
            hold_row.requested_scope = 'line'
            AND hold_row.supplier_invoice_line_id = allocation.supplier_invoice_line_id
            AND (
              hold_row.tracking_submission_id IS NULL
              OR hold_row.tracking_submission_id = allocation.tracking_submission_id
            )
          )
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.customer_hold_review_memberships hold_membership
          JOIN public.customer_review_cycle_memberships review_membership
            ON review_membership.id = hold_membership.review_membership_id
          WHERE hold_membership.hold_request_id = hold_row.id
            AND review_membership.tracking_line_allocation_id = allocation.id
        )
    );

  IF v_downstream_conflict_count > 0 THEN
    RAISE EXCEPTION 'V2 receipt would reduce quantity below existing review, hold, shipment, release or remedy provenance.';
  END IF;
  IF v_unproven_hold_count > 0 THEN
    RAISE EXCEPTION 'V2 receipt cannot supersede an active legacy hold whose exact quantity is unproven.';
  END IF;

  NEW.finalised_at := now();
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_shipper_package_receipt_v2_integrity_guard_v1
BEFORE INSERT OR UPDATE ON public.shipper_package_receipts
FOR EACH ROW EXECUTE FUNCTION public.shipper_package_receipt_v2_integrity_guard_v1();

CREATE FUNCTION public.physical_receipt_review_guard_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_receipt public.shipper_package_receipts%ROWTYPE;
  v_affected_qty numeric;
  v_dispute_order_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical receipt review provenance cannot be deleted.';
  END IF;

  IF TG_OP = 'INSERT' THEN
    SELECT receipt.* INTO v_receipt
    FROM public.shipper_package_receipts receipt
    WHERE receipt.id = NEW.receipt_id
    FOR SHARE;

    SELECT COALESCE(SUM(disposition.quantity), 0)::numeric INTO v_affected_qty
    FROM public.shipper_package_receipt_line_dispositions disposition
    WHERE disposition.receipt_id = NEW.receipt_id
      AND disposition.disposition_type <> 'clean';

    IF v_receipt.id IS NULL
       OR v_receipt.receipt_model_version <> 2
       OR v_receipt.finalised_at IS NULL
       OR v_receipt.order_id IS DISTINCT FROM NEW.order_id
       OR v_receipt.tracking_submission_id IS DISTINCT FROM NEW.tracking_submission_id
       OR v_affected_qty <= 0
    THEN
      RAISE EXCEPTION 'Physical review must reference one finalised affected v2 receipt with matching identities.';
    END IF;
  ELSE
    IF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id
       OR NEW.order_id IS DISTINCT FROM OLD.order_id
       OR NEW.tracking_submission_id IS DISTINCT FROM OLD.tracking_submission_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
      RAISE EXCEPTION 'Physical review source identity is immutable.';
    END IF;
  END IF;

  IF NEW.linked_dispute_id IS NOT NULL THEN
    SELECT dispute_row.order_id INTO v_dispute_order_id
    FROM public.disputes dispute_row
    WHERE dispute_row.id = NEW.linked_dispute_id;

    IF v_dispute_order_id IS DISTINCT FROM NEW.order_id THEN
      RAISE EXCEPTION 'Linked dispute does not belong to the physical review order.';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_receipt_review_guard_v1
BEFORE INSERT OR UPDATE OR DELETE ON public.physical_receipt_reviews
FOR EACH ROW EXECUTE FUNCTION public.physical_receipt_review_guard_v1();

CREATE FUNCTION public.physical_remedy_allocation_guard_v1()
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
  v_existing_qty numeric := 0;
  v_new_consumes boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Physical remedy provenance cannot be deleted; cancel or reroute it.';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.physical_receipt_review_id IS DISTINCT FROM OLD.physical_receipt_review_id
       OR NEW.receipt_line_disposition_id IS DISTINCT FROM OLD.receipt_line_disposition_id
       OR NEW.tracking_line_allocation_id IS DISTINCT FROM OLD.tracking_line_allocation_id
       OR NEW.supplier_invoice_line_id IS DISTINCT FROM OLD.supplier_invoice_line_id
       OR NEW.remedy_type IS DISTINCT FROM OLD.remedy_type
       OR NEW.remedy_qty IS DISTINCT FROM OLD.remedy_qty
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
    THEN
      RAISE EXCEPTION 'Physical remedy source, type and quantity are immutable; reroute with a new allocation.';
    END IF;
  END IF;

  SELECT disposition.* INTO v_disposition
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.id = NEW.receipt_line_disposition_id
  FOR UPDATE;

  SELECT review_row.* INTO v_review
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

  IF NEW.dispute_line_id IS NOT NULL THEN
    SELECT dispute_line.supplier_invoice_line_id, dispute_row.order_id
    INTO v_dispute_line_supplier_id, v_dispute_order_id
    FROM public.dispute_lines dispute_line
    JOIN public.disputes dispute_row ON dispute_row.id = dispute_line.dispute_id
    WHERE dispute_line.id = NEW.dispute_line_id;

    IF v_dispute_line_supplier_id IS DISTINCT FROM NEW.supplier_invoice_line_id
       OR v_dispute_order_id IS DISTINCT FROM v_review.order_id
    THEN
      RAISE EXCEPTION 'Physical remedy dispute line does not match the exact source line and order.';
    END IF;
  END IF;

  SELECT COALESCE(SUM(remedy.remedy_qty), 0)::numeric INTO v_existing_qty
  FROM public.physical_exception_remedy_allocations remedy
  WHERE remedy.receipt_line_disposition_id = NEW.receipt_line_disposition_id
    AND remedy.status IN ('proposed','approved','in_progress','completed','closed_no_action')
    AND (TG_OP = 'INSERT' OR remedy.id <> NEW.id);

  v_new_consumes := NEW.status IN (
    'proposed','approved','in_progress','completed','closed_no_action'
  );

  IF v_existing_qty + CASE WHEN v_new_consumes THEN NEW.remedy_qty ELSE 0 END
       > v_disposition.quantity + 0.0005
  THEN
    RAISE EXCEPTION 'Active/proposed remedy quantity exceeds the affected receipt quantity.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_physical_remedy_allocation_guard_v1
BEFORE INSERT OR UPDATE OR DELETE ON public.physical_exception_remedy_allocations
FOR EACH ROW EXECUTE FUNCTION public.physical_remedy_allocation_guard_v1();

REVOKE ALL ON FUNCTION public.shipper_receipt_line_disposition_guard_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_receipt_evidence_guard_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.shipper_package_receipt_v2_integrity_guard_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_receipt_review_guard_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.physical_remedy_allocation_guard_v1() FROM PUBLIC, anon, authenticated;

CREATE VIEW public.tracking_allocation_fulfilment_position_v1 AS
WITH latest_receipt AS (
  SELECT DISTINCT ON (receipt.tracking_submission_id)
    receipt.id AS receipt_id,
    receipt.tracking_submission_id,
    receipt.receipt_status::text AS receipt_status,
    receipt.receipt_model_version,
    receipt.finalised_at
  FROM public.shipper_package_receipts receipt
  ORDER BY receipt.tracking_submission_id, receipt.created_at DESC, receipt.id DESC
),
v2_disposition AS (
  SELECT
    disposition.receipt_id,
    disposition.tracking_line_allocation_id,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type = 'clean'
    ), 0)::numeric AS clean_qty,
    COALESCE(SUM(disposition.quantity) FILTER (
      WHERE disposition.disposition_type <> 'clean'
    ), 0)::numeric AS exception_qty
  FROM public.shipper_package_receipt_line_dispositions disposition
  GROUP BY disposition.receipt_id, disposition.tracking_line_allocation_id
),
reviewed AS (
  SELECT membership.tracking_line_allocation_id,
         COALESCE(SUM(membership.review_qty), 0)::numeric AS reviewed_qty
  FROM public.customer_review_cycle_memberships membership
  GROUP BY membership.tracking_line_allocation_id
),
exact_active_hold AS (
  SELECT review_membership.tracking_line_allocation_id,
         COALESCE(SUM(hold_membership.affected_qty), 0)::numeric AS active_hold_qty
  FROM public.customer_hold_review_memberships hold_membership
  JOIN public.customer_review_cycle_memberships review_membership
    ON review_membership.id = hold_membership.review_membership_id
  JOIN public.customer_pre_shipment_hold_requests hold_row
    ON hold_row.id = hold_membership.hold_request_id
  WHERE hold_membership.membership_status = 'active'
    AND hold_row.status IN ('requested','supervisor_approved')
  GROUP BY review_membership.tracking_line_allocation_id
),
legacy_unproven_hold AS (
  SELECT allocation.id AS tracking_line_allocation_id, true AS unproven_yn
  FROM public.order_tracking_line_allocations allocation
  WHERE EXISTS (
    SELECT 1
    FROM public.customer_pre_shipment_hold_requests hold_row
    WHERE hold_row.order_id = allocation.order_id
      AND hold_row.status IN ('requested','supervisor_approved')
      AND (
        hold_row.requested_scope = 'order'
        OR (
          hold_row.requested_scope = 'tracking'
          AND hold_row.tracking_submission_id = allocation.tracking_submission_id
        )
        OR (
          hold_row.requested_scope = 'line'
          AND hold_row.supplier_invoice_line_id = allocation.supplier_invoice_line_id
          AND (
            hold_row.tracking_submission_id IS NULL
            OR hold_row.tracking_submission_id = allocation.tracking_submission_id
          )
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_hold_review_memberships hold_membership
        JOIN public.customer_review_cycle_memberships review_membership
          ON review_membership.id = hold_membership.review_membership_id
        WHERE hold_membership.hold_request_id = hold_row.id
          AND review_membership.tracking_line_allocation_id = allocation.id
      )
  )
),
shipped AS (
  SELECT effective_line.tracking_line_allocation_id,
         COALESCE(SUM(effective_line.qty_in_shipment), 0)::numeric AS shipped_qty
  FROM public.shipper_shipment_batches batch_row
  CROSS JOIN LATERAL
    public.shipper_shipment_batch_effective_lines_v1(batch_row.id) effective_line
  WHERE batch_row.status <> 'voided'
  GROUP BY effective_line.tracking_line_allocation_id
),
released AS (
  SELECT release_line.tracking_line_allocation_id,
         COALESCE(SUM(release_line.released_qty), 0)::numeric AS released_qty
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.release_status = 'active'
  GROUP BY release_line.tracking_line_allocation_id
),
remedy AS (
  SELECT remedy_row.tracking_line_allocation_id,
         COALESCE(SUM(remedy_row.remedy_qty), 0)::numeric AS remedy_qty
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.status IN (
    'proposed','approved','in_progress','completed','closed_no_action'
  )
  GROUP BY remedy_row.tracking_line_allocation_id
),
position_source AS (
  SELECT
    allocation.order_id,
    allocation.tracking_submission_id,
    allocation.id AS tracking_line_allocation_id,
    allocation.supplier_invoice_line_id,
    COALESCE(allocation.qty_allocated, 0)::numeric AS allocated_qty,
    latest.receipt_id AS source_receipt_id,
    CASE
      WHEN latest.receipt_id IS NULL THEN 'none'
      WHEN latest.receipt_model_version = 2 THEN 'v2_exact'
      ELSE 'legacy_v1'
    END::text AS source_receipt_model,
    latest.receipt_status,
    latest.finalised_at,
    CASE
      WHEN latest.receipt_model_version = 2 THEN COALESCE(disposition.clean_qty, 0)
      WHEN latest.receipt_model_version = 1
       AND latest.receipt_status = 'received_clean' THEN COALESCE(allocation.qty_allocated, 0)
      ELSE 0
    END::numeric AS physical_clean_qty,
    CASE
      WHEN latest.receipt_model_version = 2 THEN COALESCE(disposition.exception_qty, 0)
      ELSE 0
    END::numeric AS physical_exception_qty,
    COALESCE(reviewed.reviewed_qty, 0)::numeric AS reviewed_qty,
    COALESCE(active_hold.active_hold_qty, 0)::numeric AS active_hold_qty,
    COALESCE(shipped.shipped_qty, 0)::numeric AS shipped_qty,
    COALESCE(released.released_qty, 0)::numeric AS customer_released_qty,
    COALESCE(remedy.remedy_qty, 0)::numeric AS remedy_assigned_qty,
    COALESCE(unproven_hold.unproven_yn, false) AS legacy_hold_unproven_yn
  FROM public.order_tracking_line_allocations allocation
  LEFT JOIN latest_receipt latest
    ON latest.tracking_submission_id = allocation.tracking_submission_id
  LEFT JOIN v2_disposition disposition
    ON disposition.receipt_id = latest.receipt_id
   AND disposition.tracking_line_allocation_id = allocation.id
  LEFT JOIN reviewed ON reviewed.tracking_line_allocation_id = allocation.id
  LEFT JOIN exact_active_hold active_hold
    ON active_hold.tracking_line_allocation_id = allocation.id
  LEFT JOIN legacy_unproven_hold unproven_hold
    ON unproven_hold.tracking_line_allocation_id = allocation.id
  LEFT JOIN shipped ON shipped.tracking_line_allocation_id = allocation.id
  LEFT JOIN released ON released.tracking_line_allocation_id = allocation.id
  LEFT JOIN remedy ON remedy.tracking_line_allocation_id = allocation.id
  WHERE COALESCE(allocation.qty_allocated, 0) > 0
),
validated AS (
  SELECT
    source.*,
    CASE
      WHEN source.source_receipt_model = 'v2_exact' AND source.finalised_at IS NULL THEN false
      WHEN source.source_receipt_model = 'legacy_v1'
       AND source.receipt_status IS DISTINCT FROM 'received_clean' THEN false
      WHEN source.source_receipt_model = 'v2_exact'
       AND ABS(source.physical_clean_qty + source.physical_exception_qty - source.allocated_qty) > 0.0005 THEN false
      WHEN source.legacy_hold_unproven_yn THEN false
      WHEN source.reviewed_qty > source.physical_clean_qty + 0.0005 THEN false
      WHEN source.active_hold_qty > source.physical_clean_qty + 0.0005 THEN false
      WHEN source.shipped_qty > source.physical_clean_qty + 0.0005 THEN false
      WHEN source.active_hold_qty + source.shipped_qty > source.physical_clean_qty + 0.0005 THEN false
      WHEN source.customer_released_qty > source.shipped_qty + 0.0005 THEN false
      WHEN source.remedy_assigned_qty > source.physical_exception_qty + 0.0005 THEN false
      ELSE true
    END AS position_valid_yn,
    CASE
      WHEN source.source_receipt_model = 'v2_exact' AND source.finalised_at IS NULL
        THEN 'v2_receipt_not_finalised'
      WHEN source.source_receipt_model = 'legacy_v1'
       AND source.receipt_status IS DISTINCT FROM 'received_clean'
        THEN 'legacy_nonclean_quantity_unproven'
      WHEN source.source_receipt_model = 'v2_exact'
       AND ABS(source.physical_clean_qty + source.physical_exception_qty - source.allocated_qty) > 0.0005
        THEN 'physical_quantity_balance_mismatch'
      WHEN source.legacy_hold_unproven_yn
        THEN 'legacy_hold_quantity_unproven'
      WHEN source.reviewed_qty > source.physical_clean_qty + 0.0005
        THEN 'reviewed_quantity_exceeds_clean_quantity'
      WHEN source.active_hold_qty > source.physical_clean_qty + 0.0005
        THEN 'active_hold_quantity_exceeds_clean_quantity'
      WHEN source.shipped_qty > source.physical_clean_qty + 0.0005
        THEN 'shipped_quantity_exceeds_clean_quantity'
      WHEN source.active_hold_qty + source.shipped_qty > source.physical_clean_qty + 0.0005
        THEN 'active_hold_and_shipped_exceed_clean_quantity'
      WHEN source.customer_released_qty > source.shipped_qty + 0.0005
        THEN 'customer_release_exceeds_shipped_quantity'
      WHEN source.remedy_assigned_qty > source.physical_exception_qty + 0.0005
        THEN 'remedy_quantity_exceeds_physical_exception'
      WHEN source.source_receipt_model = 'none'
        THEN 'receipt_not_recorded'
      ELSE NULL
    END::text AS position_blocker
  FROM position_source source
)
SELECT
  validated.order_id,
  validated.tracking_submission_id,
  validated.tracking_line_allocation_id,
  validated.supplier_invoice_line_id,
  validated.allocated_qty,
  validated.physical_clean_qty,
  validated.physical_exception_qty,
  validated.reviewed_qty,
  validated.active_hold_qty,
  validated.shipped_qty,
  validated.customer_released_qty,
  validated.remedy_assigned_qty,
  CASE
    WHEN validated.position_valid_yn THEN GREATEST(
      validated.physical_clean_qty
      - GREATEST(validated.reviewed_qty, validated.shipped_qty, validated.customer_released_qty),
      0
    )
    ELSE 0
  END::numeric AS review_available_qty,
  CASE
    WHEN validated.position_valid_yn THEN GREATEST(
      LEAST(validated.physical_clean_qty, validated.reviewed_qty)
      - validated.active_hold_qty
      - validated.shipped_qty,
      0
    )
    ELSE 0
  END::numeric AS shipment_available_qty,
  CASE
    WHEN validated.position_valid_yn THEN GREATEST(
      validated.physical_exception_qty - validated.remedy_assigned_qty,
      0
    )
    ELSE 0
  END::numeric AS remedy_available_qty,
  validated.position_valid_yn,
  validated.position_blocker,
  validated.source_receipt_id,
  validated.source_receipt_model
FROM validated;

COMMENT ON VIEW public.tracking_allocation_fulfilment_position_v1 IS
'Private exact quantity position per tracking allocation. Legacy clean remains fully clean; uncertain legacy non-clean and broken invariants fail closed without hiding the diagnostic blocker.';

REVOKE ALL ON public.tracking_allocation_fulfilment_position_v1 FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tracking_allocation_fulfilment_position_v1 TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
