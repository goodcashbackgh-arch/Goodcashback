BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Hybrid physical receipt foundation: additive schema and access boundary only.
-- Integrity triggers and the quantity-position model are installed by the next
-- two ordered migrations. No existing workflow function or view is replaced.

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
  IF to_regclass('public.importers') IS NULL THEN
    v_missing := array_append(v_missing, 'importers');
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
    RAISE EXCEPTION
      'Hybrid receipt foundation prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;

  SELECT md5(pg_get_functiondef(
    'public.shipper_record_package_receipt_v1(uuid,text,text,text)'::regprocedure
  ))
  INTO v_receipt_v1_fingerprint;

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
        'receipt_state',
        'receipt_submission_id',
        'payload_fingerprint',
        'finalised_at',
        'correction_of_receipt_id',
        'correction_reason'
      )
  ) THEN
    RAISE EXCEPTION
      'Hybrid receipt foundation columns already exist; inspect the target before applying this migration.';
  END IF;

  IF to_regclass('public.shipper_package_receipt_line_dispositions') IS NOT NULL
     OR to_regclass('public.shipper_package_receipt_evidence') IS NOT NULL
     OR to_regclass('public.physical_receipt_reviews') IS NOT NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NOT NULL
  THEN
    RAISE EXCEPTION
      'One or more hybrid receipt foundation tables already exist; inspect the target rather than guessing.';
  END IF;
END
$preflight$;

ALTER TABLE public.shipper_package_receipts
  ADD COLUMN receipt_model_version smallint NOT NULL DEFAULT 1,
  ADD COLUMN receipt_state text NOT NULL DEFAULT 'finalised',
  ADD COLUMN receipt_submission_id uuid,
  ADD COLUMN payload_fingerprint text,
  ADD COLUMN finalised_at timestamptz,
  ADD COLUMN correction_of_receipt_id uuid,
  ADD COLUMN correction_reason text;

ALTER TABLE public.shipper_package_receipts
  ADD CONSTRAINT shipper_package_receipts_model_version_chk
    CHECK (receipt_model_version IN (1, 2)),
  ADD CONSTRAINT shipper_package_receipts_state_chk
    CHECK (receipt_state IN ('pending','finalised')),
  ADD CONSTRAINT shipper_package_receipts_model_shape_chk
    CHECK (
      (
        receipt_model_version = 1
        AND receipt_state = 'finalised'
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
          (receipt_state = 'pending' AND finalised_at IS NULL)
          OR
          (receipt_state = 'finalised' AND finalised_at IS NOT NULL)
        )
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
    AND receipt_state = 'finalised';

COMMENT ON COLUMN public.shipper_package_receipts.receipt_model_version IS
'1 = legacy package-header receipt; 2 = exact line-disposition receipt. Existing and v1-created rows remain version 1.';
COMMENT ON COLUMN public.shipper_package_receipts.receipt_state IS
'V2 assembly state. A pending v2 row must be finalised in the same transaction and can never be committed.';
COMMENT ON COLUMN public.shipper_package_receipts.receipt_submission_id IS
'Idempotency identity for one v2 receipt submission.';
COMMENT ON COLUMN public.shipper_package_receipts.payload_fingerprint IS
'Canonical v2 payload fingerprint used to reject changed retries.';
COMMENT ON COLUMN public.shipper_package_receipts.finalised_at IS
'V2 finalisation timestamp set only after every positive allocation balances and downstream quantity invariants pass.';
COMMENT ON COLUMN public.shipper_package_receipts.correction_of_receipt_id IS
'Immediate previous finalised receipt for the same package when a later complete snapshot corrects it.';

CREATE TABLE public.shipper_package_receipt_line_dispositions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL
    REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  tracking_submission_id uuid NOT NULL
    REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL
    REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  disposition_type text NOT NULL
    CHECK (disposition_type IN ('clean','damaged','missing','wrong','held')),
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
'Immutable exact physical quantity dispositions inside one complete v2 receipt snapshot. The original supplier line and tracking allocation remain the source identity.';

CREATE INDEX idx_shipper_receipt_dispositions_receipt
  ON public.shipper_package_receipt_line_dispositions(receipt_id, created_at);
CREATE INDEX idx_shipper_receipt_dispositions_allocation
  ON public.shipper_package_receipt_line_dispositions(
    tracking_line_allocation_id,
    receipt_id
  );
CREATE INDEX idx_shipper_receipt_dispositions_affected
  ON public.shipper_package_receipt_line_dispositions(
    receipt_id,
    disposition_type
  )
  WHERE disposition_type <> 'clean';

CREATE TABLE public.shipper_package_receipt_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL
    REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  line_disposition_id uuid
    REFERENCES public.shipper_package_receipt_line_dispositions(id)
    ON DELETE RESTRICT,
  storage_object_path text NOT NULL
    CHECK (NULLIF(BTRIM(storage_object_path), '') IS NOT NULL),
  original_filename text,
  content_type text,
  display_order integer NOT NULL DEFAULT 0 CHECK (display_order >= 0),
  uploaded_by_shipper_user_id uuid NOT NULL
    REFERENCES public.shipper_users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT shipper_receipt_evidence_path_uq UNIQUE (
    receipt_id,
    storage_object_path
  )
);

COMMENT ON TABLE public.shipper_package_receipt_evidence IS
'Immutable multiple evidence references for one v2 receipt, optionally linked to one exact affected disposition.';

CREATE INDEX idx_shipper_receipt_evidence_receipt
  ON public.shipper_package_receipt_evidence(
    receipt_id,
    display_order,
    created_at
  );
CREATE INDEX idx_shipper_receipt_evidence_disposition
  ON public.shipper_package_receipt_evidence(line_disposition_id)
  WHERE line_disposition_id IS NOT NULL;

CREATE TABLE public.physical_receipt_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id uuid NOT NULL UNIQUE
    REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  importer_id uuid NOT NULL REFERENCES public.importers(id) ON DELETE RESTRICT,
  tracking_submission_id uuid NOT NULL
    REFERENCES public.order_tracking_submissions(id) ON DELETE RESTRICT,
  source_stage text NOT NULL DEFAULT 'at_shipper_receipt'
    CHECK (source_stage = 'at_shipper_receipt'),
  status text NOT NULL DEFAULT 'awaiting_importer_proposal'
    CHECK (status IN (
      'awaiting_importer_proposal',
      'awaiting_supervisor_review',
      'returned_for_information',
      'approved_to_existing_exception',
      'rejected',
      'closed_no_action',
      'superseded'
    )),
  importer_proposed_by_operator_id uuid
    REFERENCES public.operators(id) ON DELETE RESTRICT,
  importer_proposed_at timestamptz,
  supervisor_decided_by_staff_id uuid
    REFERENCES public.staff(id) ON DELETE RESTRICT,
  supervisor_decided_at timestamptz,
  approved_liable_party text
    CHECK (
      approved_liable_party IS NULL
      OR approved_liable_party IN ('retailer','shipper','unknown','no_liability')
    ),
  decision_note text,
  linked_dispute_id uuid
    REFERENCES public.disputes(id) ON DELETE RESTRICT,
  superseded_by_receipt_id uuid
    REFERENCES public.shipper_package_receipts(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT physical_receipt_review_importer_shape_chk CHECK (
    (importer_proposed_by_operator_id IS NULL AND importer_proposed_at IS NULL)
    OR
    (importer_proposed_by_operator_id IS NOT NULL AND importer_proposed_at IS NOT NULL)
  ),
  CONSTRAINT physical_receipt_review_supervisor_shape_chk CHECK (
    (supervisor_decided_by_staff_id IS NULL AND supervisor_decided_at IS NULL)
    OR
    (supervisor_decided_by_staff_id IS NOT NULL AND supervisor_decided_at IS NOT NULL)
  ),
  CONSTRAINT physical_receipt_review_link_shape_chk CHECK (
    (
      status = 'approved_to_existing_exception'
      AND linked_dispute_id IS NOT NULL
      AND approved_liable_party IS NOT NULL
    )
    OR
    (
      status <> 'approved_to_existing_exception'
      AND linked_dispute_id IS NULL
    )
  ),
  CONSTRAINT physical_receipt_review_superseded_shape_chk CHECK (
    (
      status = 'superseded'
      AND superseded_by_receipt_id IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(decision_note, '')), '') IS NOT NULL
    )
    OR
    (
      status <> 'superseded'
      AND superseded_by_receipt_id IS NULL
    )
  ),
  CONSTRAINT physical_receipt_review_decision_note_chk CHECK (
    status NOT IN ('returned_for_information','rejected','closed_no_action')
    OR NULLIF(BTRIM(COALESCE(decision_note, '')), '') IS NOT NULL
  )
);

COMMENT ON TABLE public.physical_receipt_reviews IS
'Importer proposal and supervisor route-approval header before linkage to the existing dispute/retailer-conversation workflow. It is not a second retailer-remedy state machine.';

CREATE INDEX idx_physical_receipt_reviews_status
  ON public.physical_receipt_reviews(status, created_at);
CREATE INDEX idx_physical_receipt_reviews_order
  ON public.physical_receipt_reviews(order_id, created_at);
CREATE INDEX idx_physical_receipt_reviews_importer
  ON public.physical_receipt_reviews(importer_id, status, created_at);
CREATE INDEX idx_physical_receipt_reviews_dispute
  ON public.physical_receipt_reviews(linked_dispute_id)
  WHERE linked_dispute_id IS NOT NULL;

CREATE TABLE public.physical_exception_remedy_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  physical_receipt_review_id uuid NOT NULL
    REFERENCES public.physical_receipt_reviews(id) ON DELETE RESTRICT,
  receipt_line_disposition_id uuid NOT NULL
    REFERENCES public.shipper_package_receipt_line_dispositions(id)
    ON DELETE RESTRICT,
  tracking_line_allocation_id uuid NOT NULL
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  supplier_invoice_line_id uuid NOT NULL
    REFERENCES public.supplier_invoice_lines(id) ON DELETE RESTRICT,
  proposed_remedy_type text NOT NULL
    CHECK (proposed_remedy_type IN (
      'refund','replacement','hold_investigate','no_action'
    )),
  proposed_remedy_qty numeric(12,3) NOT NULL
    CHECK (proposed_remedy_qty > 0),
  proposed_by_operator_id uuid NOT NULL
    REFERENCES public.operators(id) ON DELETE RESTRICT,
  proposed_at timestamptz NOT NULL DEFAULT now(),
  approved_remedy_type text
    CHECK (
      approved_remedy_type IS NULL
      OR approved_remedy_type IN (
        'refund','replacement','hold_investigate','no_action'
      )
    ),
  approved_remedy_qty numeric(12,3)
    CHECK (approved_remedy_qty IS NULL OR approved_remedy_qty > 0),
  approved_by_staff_id uuid
    REFERENCES public.staff(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  dispute_line_id uuid
    REFERENCES public.dispute_lines(id) ON DELETE RESTRICT,
  supplier_claim_amount_gbp numeric(14,2)
    CHECK (supplier_claim_amount_gbp IS NULL OR supplier_claim_amount_gbp >= 0),
  customer_commercial_value_gbp numeric(14,2)
    CHECK (
      customer_commercial_value_gbp IS NULL
      OR customer_commercial_value_gbp >= 0
    ),
  supplier_cost_mode text
    CHECK (
      supplier_cost_mode IS NULL
      OR supplier_cost_mode IN (
        'free_replacement',
        'charged_repurchase',
        'pending_supplier_evidence',
        'not_applicable'
      )
    ),
  replacement_child_order_id uuid
    REFERENCES public.orders(id) ON DELETE RESTRICT,
  replacement_child_tracking_allocation_id uuid
    REFERENCES public.order_tracking_line_allocations(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'proposed'
    CHECK (status IN (
      'proposed',
      'approved',
      'linked_to_exception',
      'in_progress',
      'completed',
      'cancelled',
      'rerouted',
      'closed_no_action'
    )),
  rerouted_to_remedy_allocation_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT physical_remedy_approval_shape_chk CHECK (
    (
      approved_by_staff_id IS NULL
      AND approved_at IS NULL
      AND approved_remedy_type IS NULL
      AND approved_remedy_qty IS NULL
    )
    OR
    (
      approved_by_staff_id IS NOT NULL
      AND approved_at IS NOT NULL
      AND approved_remedy_type IS NOT NULL
      AND approved_remedy_qty IS NOT NULL
    )
  ),
  CONSTRAINT physical_remedy_child_tracking_shape_chk CHECK (
    replacement_child_tracking_allocation_id IS NULL
    OR replacement_child_order_id IS NOT NULL
  )
);

ALTER TABLE public.physical_exception_remedy_allocations
  ADD CONSTRAINT physical_remedy_reroute_fkey
  FOREIGN KEY (rerouted_to_remedy_allocation_id)
  REFERENCES public.physical_exception_remedy_allocations(id)
  ON DELETE RESTRICT;

COMMENT ON TABLE public.physical_exception_remedy_allocations IS
'Exact affected-quantity proposal and separately recorded supervisor-approved route. Existing disputes, refunds and replacement-child operations remain authoritative after linkage.';

CREATE INDEX idx_physical_remedy_review_status
  ON public.physical_exception_remedy_allocations(
    physical_receipt_review_id,
    status
  );
CREATE INDEX idx_physical_remedy_source_status
  ON public.physical_exception_remedy_allocations(
    receipt_line_disposition_id,
    status
  );
CREATE INDEX idx_physical_remedy_allocation_status
  ON public.physical_exception_remedy_allocations(
    tracking_line_allocation_id,
    status
  );
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
    JOIN public.shipper_users shipper_user
      ON shipper_user.shipper_id = receipt.shipper_id
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
    JOIN public.operators operator_row
      ON operator_row.id = access_row.operator_id
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
    JOIN public.shipper_users shipper_user
      ON shipper_user.shipper_id = receipt.shipper_id
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
    JOIN public.operators operator_row
      ON operator_row.id = access_row.operator_id
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
    FROM public.operator_importers access_row
    JOIN public.operators operator_row
      ON operator_row.id = access_row.operator_id
    WHERE access_row.importer_id = physical_receipt_reviews.importer_id
      AND access_row.revoked_at IS NULL
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
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
    JOIN public.operator_importers access_row
      ON access_row.importer_id = review_row.importer_id
     AND access_row.revoked_at IS NULL
    JOIN public.operators operator_row
      ON operator_row.id = access_row.operator_id
    WHERE review_row.id =
          physical_exception_remedy_allocations.physical_receipt_review_id
      AND operator_row.auth_user_id = auth.uid()
      AND COALESCE(operator_row.active, true) = true
  )
);

REVOKE ALL ON public.shipper_package_receipt_line_dispositions
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.shipper_package_receipt_evidence
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.physical_receipt_reviews
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.physical_exception_remedy_allocations
  FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.shipper_package_receipt_line_dispositions TO authenticated;
GRANT SELECT ON public.shipper_package_receipt_evidence TO authenticated;
GRANT SELECT ON public.physical_receipt_reviews TO authenticated;
GRANT SELECT ON public.physical_exception_remedy_allocations TO authenticated;

GRANT ALL ON public.shipper_package_receipt_line_dispositions TO service_role;
GRANT ALL ON public.shipper_package_receipt_evidence TO service_role;
GRANT ALL ON public.physical_receipt_reviews TO service_role;
GRANT ALL ON public.physical_exception_remedy_allocations TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;