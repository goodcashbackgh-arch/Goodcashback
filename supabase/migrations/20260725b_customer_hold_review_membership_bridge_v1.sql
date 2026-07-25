BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.customer_review_cycle_memberships') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_review_cycle_memberships');
  END IF;
  IF to_regclass('public.customer_sales_release_lines') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_sales_release_lines');
  END IF;
  IF to_regprocedure('public.customer_hold_create_refund_exception_v2()') IS NULL THEN
    v_missing := array_append(v_missing, 'public.customer_hold_create_refund_exception_v2()');
  END IF;
  IF to_regprocedure('public.refresh_completed_refund_issue_status_v1(uuid,uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'public.refresh_completed_refund_issue_status_v1(uuid,uuid)');
  END IF;
  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'Mini 4 hold bridge prerequisites missing: %',
      array_to_string(v_missing, ', ');
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.customer_hold_review_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hold_request_id uuid NOT NULL
    REFERENCES public.customer_pre_shipment_hold_requests(id) ON DELETE RESTRICT,
  review_membership_id uuid NOT NULL
    REFERENCES public.customer_review_cycle_memberships(id) ON DELETE RESTRICT,
  affected_qty numeric(12,3) NOT NULL CHECK (affected_qty > 0),
  affected_review_value_gbp numeric(14,2) NOT NULL
    CHECK (affected_review_value_gbp >= 0),
  membership_status text NOT NULL DEFAULT 'active'
    CHECK (membership_status IN ('active','superseded','closed')),
  membership_fingerprint text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  status_updated_at timestamptz NULL,
  CONSTRAINT customer_hold_review_memberships_target_unique
    UNIQUE (hold_request_id, review_membership_id),
  CONSTRAINT customer_hold_review_memberships_fingerprint_unique
    UNIQUE (membership_fingerprint)
);

COMMENT ON TABLE public.customer_hold_review_memberships IS
'Exact quantity/value materialisation from an existing customer hold request to immutable Mini 4 review membership. It does not replace customer_pre_shipment_hold_requests.';

CREATE INDEX IF NOT EXISTS idx_customer_hold_review_memberships_hold
  ON public.customer_hold_review_memberships(hold_request_id, membership_status);

CREATE INDEX IF NOT EXISTS idx_customer_hold_review_memberships_review
  ON public.customer_hold_review_memberships(review_membership_id);

CREATE TABLE IF NOT EXISTS public.customer_hold_released_credit_requirements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hold_request_id uuid NOT NULL
    REFERENCES public.customer_pre_shipment_hold_requests(id) ON DELETE RESTRICT,
  hold_review_membership_id uuid NOT NULL
    REFERENCES public.customer_hold_review_memberships(id) ON DELETE RESTRICT,
  customer_sales_release_line_id uuid NOT NULL
    REFERENCES public.customer_sales_release_lines(id) ON DELETE RESTRICT,
  original_sales_invoice_id uuid NOT NULL
    REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  affected_qty numeric(12,3) NOT NULL CHECK (affected_qty > 0),
  affected_customer_value_gbp numeric(14,2) NOT NULL
    CHECK (affected_customer_value_gbp > 0),
  requirement_status text NOT NULL DEFAULT 'pending_refund_completion'
    CHECK (requirement_status IN (
      'pending_refund_completion',
      'ready_for_customer_credit_note',
      'customer_credit_note_created',
      'customer_credit_note_posted',
      'cancelled'
    )),
  customer_credit_note_id uuid NULL
    REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  requirement_fingerprint text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  status_updated_at timestamptz NULL,
  CONSTRAINT customer_hold_released_credit_requirement_source_unique
    UNIQUE (hold_request_id, customer_sales_release_line_id),
  CONSTRAINT customer_hold_released_credit_requirement_fingerprint_unique
    UNIQUE (requirement_fingerprint)
);

COMMENT ON TABLE public.customer_hold_released_credit_requirements IS
'Exact Mini 4 requirement for already customer-released hold value. Rows retain the original main/supplementary sales invoice separately and become credit-note-ready only after canonical refund completion.';

CREATE INDEX IF NOT EXISTS idx_customer_hold_credit_requirements_invoice
  ON public.customer_hold_released_credit_requirements(
    original_sales_invoice_id,
    requirement_status
  );

CREATE TABLE IF NOT EXISTS public.customer_hold_credit_note_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hold_request_id uuid NOT NULL
    REFERENCES public.customer_pre_shipment_hold_requests(id) ON DELETE RESTRICT,
  original_sales_invoice_id uuid NOT NULL
    REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  customer_credit_note_id uuid NOT NULL
    REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  document_status text NOT NULL DEFAULT 'draft'
    CHECK (document_status IN ('draft','posted','void')),
  created_by_staff_id uuid NULL REFERENCES public.staff(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  status_updated_at timestamptz NULL
);

COMMENT ON TABLE public.customer_hold_credit_note_documents IS
'Idempotent Mini 4 bridge from one exact hold/original customer sales document to the existing sales_invoices credit_note and Sage lane.';

CREATE UNIQUE INDEX IF NOT EXISTS
  uq_customer_hold_credit_note_active_document_v1
ON public.customer_hold_credit_note_documents(
  hold_request_id,
  original_sales_invoice_id
)
WHERE document_status <> 'void';

CREATE UNIQUE INDEX IF NOT EXISTS
  uq_customer_hold_credit_note_sales_invoice_v1
ON public.customer_hold_credit_note_documents(customer_credit_note_id);

CREATE INDEX IF NOT EXISTS
  idx_customer_hold_credit_note_original_v1
ON public.customer_hold_credit_note_documents(
  original_sales_invoice_id,
  document_status
);

ALTER TABLE public.customer_hold_review_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_hold_released_credit_requirements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_hold_credit_note_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_hold_review_memberships_staff_read_v1
  ON public.customer_hold_review_memberships;
CREATE POLICY customer_hold_review_memberships_staff_read_v1
  ON public.customer_hold_review_memberships
  FOR SELECT
  TO authenticated
  USING (public.is_active_staff());

DROP POLICY IF EXISTS customer_hold_credit_requirements_staff_read_v1
  ON public.customer_hold_released_credit_requirements;
CREATE POLICY customer_hold_credit_requirements_staff_read_v1
  ON public.customer_hold_released_credit_requirements
  FOR SELECT
  TO authenticated
  USING (public.is_active_staff());

DROP POLICY IF EXISTS customer_hold_credit_note_documents_staff_read_v1
  ON public.customer_hold_credit_note_documents;
CREATE POLICY customer_hold_credit_note_documents_staff_read_v1
  ON public.customer_hold_credit_note_documents
  FOR SELECT
  TO authenticated
  USING (public.is_active_staff());

REVOKE ALL ON TABLE public.customer_hold_review_memberships
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.customer_hold_released_credit_requirements
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.customer_hold_credit_note_documents
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.customer_hold_review_memberships TO authenticated;
GRANT SELECT ON TABLE public.customer_hold_released_credit_requirements TO authenticated;
GRANT SELECT ON TABLE public.customer_hold_credit_note_documents TO authenticated;
GRANT ALL ON TABLE public.customer_hold_review_memberships TO service_role;
GRANT ALL ON TABLE public.customer_hold_released_credit_requirements TO service_role;
GRANT ALL ON TABLE public.customer_hold_credit_note_documents TO service_role;

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
  v_count integer := 0;
BEGIN
  SELECT *
  INTO v_hold
  FROM public.customer_pre_shipment_hold_requests h
  WHERE h.id = p_hold_request_id
  FOR UPDATE;

  IF v_hold.id IS NULL OR v_hold.review_link_id IS NULL THEN
    RETURN 0;
  END IF;

  INSERT INTO public.customer_hold_review_memberships (
    hold_request_id,
    review_membership_id,
    affected_qty,
    affected_review_value_gbp,
    membership_status,
    membership_fingerprint
  )
  SELECT
    v_hold.id,
    m.id,
    m.review_qty,
    m.review_value_gbp,
    CASE
      WHEN v_hold.status IN ('resolved','rejected','superseded')
        THEN 'closed'
      ELSE 'active'
    END,
    md5(concat_ws(
      '|',
      'customer_hold_review_membership_v1',
      v_hold.id,
      m.id,
      m.review_qty,
      m.review_value_gbp
    ))
  FROM public.customer_review_cycle_memberships m
  WHERE m.review_link_id = v_hold.review_link_id
    AND m.membership_status IN ('active','held','released','expired','closed')
    AND (
      v_hold.requested_scope = 'order'
      OR (
        v_hold.requested_scope = 'tracking'
        AND m.tracking_submission_id = v_hold.tracking_submission_id
      )
      OR (
        v_hold.requested_scope = 'line'
        AND m.supplier_invoice_line_id = v_hold.supplier_invoice_line_id
        AND (
          v_hold.tracking_submission_id IS NULL
          OR m.tracking_submission_id = v_hold.tracking_submission_id
        )
      )
    )
  ON CONFLICT (hold_request_id, review_membership_id) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  UPDATE public.customer_hold_review_memberships hm
  SET membership_status = CASE
        WHEN v_hold.status IN ('resolved','rejected','superseded')
          THEN 'closed'
        ELSE hm.membership_status
      END,
      status_updated_at = CASE
        WHEN v_hold.status IN ('resolved','rejected','superseded')
             AND hm.membership_status <> 'closed'
          THEN now()
        ELSE hm.status_updated_at
      END
  WHERE hm.hold_request_id = v_hold.id
    AND v_hold.status IN ('resolved','rejected','superseded')
    AND hm.membership_status <> 'closed';

  IF v_hold.status IN ('requested','supervisor_approved')
     AND NOT EXISTS (
       SELECT 1
       FROM public.customer_hold_review_memberships hm
       WHERE hm.hold_request_id = v_hold.id
     )
     AND EXISTS (
       SELECT 1
       FROM public.customer_order_review_links l
       WHERE l.id = v_hold.review_link_id
         AND l.expires_at IS NOT NULL
     )
  THEN
    RAISE EXCEPTION
      'Exact timed review membership could not be materialised for hold %.',
      v_hold.id;
  END IF;

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_materialize_hold_credit_requirements_v1(
  p_hold_request_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count integer := 0;
BEGIN
  PERFORM public.customer_materialize_hold_review_memberships_v1(
    p_hold_request_id
  );

  /*
   * Review and release memberships are both quantity tranches on the same
   * tracking allocation. Attribute only the mathematical overlap between each
   * immutable review range and each active release range; do not assign every
   * later review to the earliest customer invoice.
   */
  WITH review_ranked AS (
    SELECT
      m.id AS review_membership_id,
      m.tracking_line_allocation_id,
      m.supplier_invoice_line_id,
      m.review_qty,
      COALESCE(
        SUM(m.review_qty) OVER (
          PARTITION BY m.tracking_line_allocation_id
          ORDER BY m.created_at, m.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ),
        0
      )::numeric AS review_start_qty
    FROM public.customer_review_cycle_memberships m
  ),
  release_ranked AS (
    SELECT
      l.id AS release_line_id,
      l.tracking_line_allocation_id,
      l.supplier_invoice_line_id,
      l.sales_invoice_id,
      l.released_qty,
      l.customer_charge_amount_gbp,
      COALESCE(
        SUM(l.released_qty) OVER (
          PARTITION BY l.tracking_line_allocation_id
          ORDER BY l.created_at, l.id
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ),
        0
      )::numeric AS release_start_qty
    FROM public.customer_sales_release_lines l
    WHERE l.release_status = 'active'
      AND l.released_qty > 0
  ),
  overlap AS (
    SELECT
      hm.id AS hold_review_membership_id,
      hm.hold_request_id,
      release_row.release_line_id,
      release_row.sales_invoice_id,
      release_row.released_qty,
      release_row.customer_charge_amount_gbp,
      GREATEST(
        LEAST(
          review_row.review_start_qty + hm.affected_qty,
          release_row.release_start_qty + release_row.released_qty
        )
        - GREATEST(
          review_row.review_start_qty,
          release_row.release_start_qty
        ),
        0
      )::numeric AS affected_released_qty
    FROM public.customer_hold_review_memberships hm
    JOIN public.customer_pre_shipment_hold_requests hold_row
      ON hold_row.id = hm.hold_request_id
    LEFT JOIN public.disputes hold_dispute
      ON hold_dispute.id = hold_row.converted_dispute_id
    JOIN review_ranked review_row
      ON review_row.review_membership_id = hm.review_membership_id
    JOIN release_ranked release_row
      ON release_row.tracking_line_allocation_id =
           review_row.tracking_line_allocation_id
     AND release_row.supplier_invoice_line_id =
           review_row.supplier_invoice_line_id
    WHERE hm.hold_request_id = p_hold_request_id
      AND (
        (
          hold_row.status = 'supervisor_approved'
          AND hm.membership_status = 'active'
        )
        OR (
          hold_row.status IN ('converted_to_exception','resolved')
          AND hm.membership_status IN ('active','closed')
          AND hold_dispute.desired_outcome = 'refund'
        )
      )
  )
  INSERT INTO public.customer_hold_released_credit_requirements (
    hold_request_id,
    hold_review_membership_id,
    customer_sales_release_line_id,
    original_sales_invoice_id,
    affected_qty,
    affected_customer_value_gbp,
    requirement_status,
    requirement_fingerprint
  )
  SELECT
    overlap_row.hold_request_id,
    overlap_row.hold_review_membership_id,
    overlap_row.release_line_id,
    overlap_row.sales_invoice_id,
    ROUND(overlap_row.affected_released_qty, 3),
    ROUND(
      overlap_row.customer_charge_amount_gbp
      * overlap_row.affected_released_qty
      / NULLIF(overlap_row.released_qty, 0),
      2
    ),
    CASE
      WHEN EXISTS (
        SELECT 1
        FROM public.customer_pre_shipment_hold_requests hold_row
        JOIN public.disputes dispute_row
          ON dispute_row.id = hold_row.converted_dispute_id
        WHERE hold_row.id = overlap_row.hold_request_id
          AND dispute_row.desired_outcome = 'refund'
          AND dispute_row.status = 'refunded'
          AND dispute_row.resolved_at IS NOT NULL
      ) THEN 'ready_for_customer_credit_note'
      ELSE 'pending_refund_completion'
    END,
    md5(concat_ws(
      '|',
      'customer_hold_released_credit_requirement_v1',
      overlap_row.hold_request_id,
      overlap_row.hold_review_membership_id,
      overlap_row.release_line_id,
      ROUND(overlap_row.affected_released_qty, 3),
      ROUND(
        overlap_row.customer_charge_amount_gbp
        * overlap_row.affected_released_qty
        / NULLIF(overlap_row.released_qty, 0),
        2
      )
    ))
  FROM overlap overlap_row
  WHERE overlap_row.affected_released_qty > 0
    AND ROUND(
      overlap_row.customer_charge_amount_gbp
      * overlap_row.affected_released_qty
      / NULLIF(overlap_row.released_qty, 0),
      2
    ) > 0
  ON CONFLICT (hold_request_id, customer_sales_release_line_id)
  DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_credit_requirement_release_sync_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF OLD.release_status = 'active'
     AND NEW.release_status <> 'active'
  THEN
    IF EXISTS (
      SELECT 1
      FROM public.customer_hold_released_credit_requirements requirement
      WHERE requirement.customer_sales_release_line_id = OLD.id
        AND requirement.requirement_status IN (
          'customer_credit_note_created',
          'customer_credit_note_posted'
        )
    ) THEN
      RAISE EXCEPTION
        'Cannot reverse customer release membership after its customer credit note has been created. Void the credit note through the existing document route first.';
    END IF;

    UPDATE public.customer_hold_released_credit_requirements requirement
    SET requirement_status = 'cancelled',
        status_updated_at = now()
    WHERE requirement.customer_sales_release_line_id = OLD.id
      AND requirement.requirement_status IN (
        'pending_refund_completion',
        'ready_for_customer_credit_note'
      );
  ELSIF OLD.release_status <> 'active'
        AND NEW.release_status = 'active'
  THEN
    UPDATE public.customer_hold_released_credit_requirements requirement
    SET requirement_status = CASE
          WHEN EXISTS (
            SELECT 1
            FROM public.customer_pre_shipment_hold_requests hold_row
            JOIN public.disputes dispute_row
              ON dispute_row.id = hold_row.converted_dispute_id
            WHERE hold_row.id = requirement.hold_request_id
              AND dispute_row.desired_outcome = 'refund'
              AND dispute_row.status = 'refunded'
              AND dispute_row.resolved_at IS NOT NULL
          ) THEN 'ready_for_customer_credit_note'
          ELSE 'pending_refund_completion'
        END,
        status_updated_at = now()
    WHERE requirement.customer_sales_release_line_id = NEW.id
      AND requirement.requirement_status = 'cancelled';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_credit_requirement_release_sync_v1
  ON public.customer_sales_release_lines;
CREATE TRIGGER trg_customer_credit_requirement_release_sync_v1
BEFORE UPDATE OF release_status
ON public.customer_sales_release_lines
FOR EACH ROW
EXECUTE FUNCTION public.customer_credit_requirement_release_sync_v1();

CREATE OR REPLACE FUNCTION public.trg_customer_materialize_hold_membership_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.customer_materialize_hold_review_memberships_v1(NEW.id);

  IF NEW.status = 'supervisor_approved' THEN
    PERFORM public.customer_materialize_hold_credit_requirements_v1(NEW.id);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_materialize_hold_membership_v1
  ON public.customer_pre_shipment_hold_requests;
CREATE TRIGGER trg_customer_materialize_hold_membership_v1
AFTER INSERT OR UPDATE OF
  status,
  requested_scope,
  review_link_id,
  tracking_submission_id,
  supplier_invoice_line_id
ON public.customer_pre_shipment_hold_requests
FOR EACH ROW
WHEN (NEW.review_link_id IS NOT NULL)
EXECUTE FUNCTION public.trg_customer_materialize_hold_membership_v1();

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT h.id
    FROM public.customer_pre_shipment_hold_requests h
    WHERE h.review_link_id IS NOT NULL
  LOOP
    BEGIN
      PERFORM public.customer_materialize_hold_review_memberships_v1(r.id);
      PERFORM public.customer_materialize_hold_credit_requirements_v1(r.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE
        'Mini 4 conservative hold backfill skipped hold %: %',
        r.id,
        SQLERRM;
    END;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.customer_hold_refund_target_lines_v1(
  p_hold_request_id uuid
)
RETURNS TABLE (
  supplier_invoice_line_id uuid,
  qty_impact numeric,
  amount_impact_gbp numeric,
  source_line_qty numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH exact_target AS (
    SELECT
      m.supplier_invoice_line_id,
      ROUND(SUM(hm.affected_qty), 3)::numeric AS qty_impact,
      ROUND(SUM(
        CASE
          WHEN COALESCE(sil.qty_confirmed, sil.qty, 0) > 0
            THEN COALESCE(
              sil.amount_confirmed,
              sil.amount_inc_vat_gbp,
              0
            )::numeric
            * hm.affected_qty
            / COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric
          ELSE 0
        END
      ), 2)::numeric AS amount_impact_gbp,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS source_line_qty
    FROM public.customer_hold_review_memberships hm
    JOIN public.customer_review_cycle_memberships m
      ON m.id = hm.review_membership_id
    JOIN public.supplier_invoice_lines sil
      ON sil.id = m.supplier_invoice_line_id
    JOIN public.customer_pre_shipment_hold_requests h
      ON h.id = hm.hold_request_id
    WHERE hm.hold_request_id = p_hold_request_id
      AND hm.membership_status = 'active'
      AND h.status = 'supervisor_approved'
      AND h.requested_scope IN ('line','tracking')
    GROUP BY
      m.supplier_invoice_line_id,
      sil.qty_confirmed,
      sil.qty
  ),
  legacy_hold AS (
    SELECT h.*
    FROM public.customer_pre_shipment_hold_requests h
    JOIN public.customer_order_review_links l
      ON l.id = h.review_link_id
     AND l.expires_at IS NULL
    WHERE h.id = p_hold_request_id
      AND h.status = 'supervisor_approved'
      AND h.requested_scope IN ('line','tracking')
      AND NOT EXISTS (SELECT 1 FROM exact_target)
  ),
  legacy_direct_line AS (
    SELECT
      sil.id AS supplier_invoice_line_id,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS qty_impact,
      COALESCE(
        sil.amount_confirmed,
        sil.amount_inc_vat_gbp,
        0
      )::numeric AS amount_impact_gbp,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS source_line_qty
    FROM legacy_hold h
    JOIN public.supplier_invoice_lines sil
      ON h.requested_scope = 'line'
     AND sil.id = h.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = h.order_id
    WHERE COALESCE(si.review_status, '') NOT IN (
      'rejected_resubmit_required',
      'duplicate_blocked',
      'superseded'
    )
  ),
  legacy_package_allocated AS (
    SELECT
      otla.supplier_invoice_line_id,
      SUM(COALESCE(otla.qty_allocated, 0))::numeric AS allocated_qty
    FROM legacy_hold h
    JOIN public.order_tracking_line_allocations otla
      ON h.requested_scope = 'tracking'
     AND otla.order_id = h.order_id
     AND otla.tracking_submission_id = h.tracking_submission_id
     AND COALESCE(otla.qty_allocated, 0) > 0
    GROUP BY otla.supplier_invoice_line_id
  ),
  legacy_package_line AS (
    SELECT
      sil.id AS supplier_invoice_line_id,
      pa.allocated_qty AS qty_impact,
      CASE
        WHEN COALESCE(sil.qty_confirmed, sil.qty, 0) > 0
          THEN ROUND(
            COALESCE(
              sil.amount_confirmed,
              sil.amount_inc_vat_gbp,
              0
            )::numeric
            * pa.allocated_qty
            / COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric,
            2
          )
        ELSE 0::numeric
      END AS amount_impact_gbp,
      COALESCE(sil.qty_confirmed, sil.qty, 0)::numeric AS source_line_qty
    FROM legacy_hold h
    JOIN legacy_package_allocated pa ON true
    JOIN public.supplier_invoice_lines sil
      ON sil.id = pa.supplier_invoice_line_id
    JOIN public.supplier_invoices si
      ON si.id = sil.supplier_invoice_id
     AND si.order_id = h.order_id
    WHERE h.requested_scope = 'tracking'
      AND COALESCE(si.review_status, '') NOT IN (
        'rejected_resubmit_required',
        'duplicate_blocked',
        'superseded'
      )
  )
  SELECT * FROM exact_target
  UNION ALL
  SELECT * FROM legacy_direct_line
  UNION ALL
  SELECT * FROM legacy_package_line;
$$;

CREATE OR REPLACE FUNCTION public.customer_hold_create_refund_exception_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_line_ids uuid[];
  v_target_count integer := 0;
  v_linked_count integer := 0;
  v_dispute_count integer := 0;
  v_incompatible_count integer := 0;
  v_dispute_id uuid;
  v_operator_id uuid;
  v_sop_version text;
BEGIN
  IF NEW.status <> 'supervisor_approved'
     OR NEW.requested_scope NOT IN ('line', 'tracking')
  THEN
    RETURN NEW;
  END IF;

  PERFORM public.customer_materialize_hold_review_memberships_v1(NEW.id);
  PERFORM public.customer_materialize_hold_credit_requirements_v1(NEW.id);

  IF NEW.converted_dispute_id IS NOT NULL THEN
    UPDATE public.disputes d
    SET refund_approved_by_staff_id =
          COALESCE(d.refund_approved_by_staff_id, NEW.reviewed_by_staff_id),
        refund_approved_at =
          COALESCE(d.refund_approved_at, NEW.reviewed_at, now())
    WHERE d.id = NEW.converted_dispute_id
      AND d.desired_outcome = 'refund';
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(NEW.order_id::text));

  SELECT
    array_agg(t.supplier_invoice_line_id ORDER BY t.supplier_invoice_line_id),
    COUNT(*)::integer
  INTO v_target_line_ids, v_target_count
  FROM public.customer_hold_refund_target_lines_v1(NEW.id) t;

  IF COALESCE(v_target_count, 0) = 0 THEN
    RAISE EXCEPTION
      'Approved hold cannot be converted because exact immutable review membership is missing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_hold_refund_target_lines_v1(NEW.id) t
    WHERE t.source_line_qty <= 0
       OR t.qty_impact <= 0
       OR t.qty_impact > t.source_line_qty
       OR ABS(t.qty_impact - ROUND(t.qty_impact)) > 0.000001
  ) THEN
    RAISE EXCEPTION
      'Approved hold cannot be converted because its exact affected quantity is invalid or fractional.';
  END IF;

  WITH open_links AS (
    SELECT DISTINCT
      dl.supplier_invoice_line_id,
      d.id AS dispute_id,
      d.desired_outcome,
      d.status
    FROM public.dispute_lines dl
    JOIN public.disputes d
      ON d.id = dl.dispute_id
     AND d.resolved_at IS NULL
    WHERE dl.supplier_invoice_line_id = ANY(v_target_line_ids)
      AND dl.resolved_at IS NULL
  )
  SELECT
    COUNT(DISTINCT supplier_invoice_line_id)::integer,
    COUNT(DISTINCT dispute_id)::integer,
    COUNT(*) FILTER (
      WHERE desired_outcome <> 'refund' OR status <> 'raised'
    )::integer
  INTO v_linked_count, v_dispute_count, v_incompatible_count
  FROM open_links;

  IF v_linked_count > 0 THEN
    IF v_linked_count = v_target_count
       AND v_dispute_count = 1
       AND v_incompatible_count = 0
    THEN
      SELECT MIN(d.id::text)::uuid
      INTO v_dispute_id
      FROM public.dispute_lines dl
      JOIN public.disputes d
        ON d.id = dl.dispute_id
       AND d.resolved_at IS NULL
       AND d.desired_outcome = 'refund'
       AND d.status = 'raised'
      WHERE dl.supplier_invoice_line_id = ANY(v_target_line_ids)
        AND dl.resolved_at IS NULL;
    ELSE
      RAISE EXCEPTION
        'Approved hold overlaps an incompatible or partial open exception. Resolve or narrow it first.';
    END IF;
  END IF;

  SELECT o.operator_id, o.sop_version
  INTO v_operator_id, v_sop_version
  FROM public.orders o
  WHERE o.id = NEW.order_id;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION
      'Order operator could not be resolved for hold exception conversion.';
  END IF;

  IF v_dispute_id IS NULL THEN
    SELECT d.id
    INTO v_dispute_id
    FROM public.disputes d
    WHERE d.order_id = NEW.order_id
      AND d.desired_outcome = 'refund'
      AND d.status = 'raised'
      AND d.resolved_at IS NULL
    ORDER BY d.raised_at DESC NULLS LAST, d.id DESC
    LIMIT 1;
  END IF;

  IF v_dispute_id IS NULL THEN
    INSERT INTO public.disputes (
      order_id,
      raised_by_operator_id,
      issue_type,
      desired_outcome,
      liable_party,
      stage_detected,
      amount_impact_gbp,
      comments_initial,
      status,
      sop_version,
      refund_approved_by_staff_id,
      refund_approved_at
    )
    VALUES (
      NEW.order_id,
      v_operator_id,
      'missing',
      'refund',
      'unknown',
      'at_reconciliation',
      0,
      'Created from approved customer '
        || NEW.requested_scope || ' hold ' || NEW.id::text || '.',
      'raised',
      v_sop_version,
      NEW.reviewed_by_staff_id,
      COALESCE(NEW.reviewed_at, now())
    )
    RETURNING id INTO v_dispute_id;
  ELSE
    UPDATE public.disputes d
    SET refund_approved_by_staff_id =
          COALESCE(d.refund_approved_by_staff_id, NEW.reviewed_by_staff_id),
        refund_approved_at =
          COALESCE(d.refund_approved_at, NEW.reviewed_at, now())
    WHERE d.id = v_dispute_id;
  END IF;

  IF v_linked_count = 0 THEN
    INSERT INTO public.dispute_lines (
      dispute_id,
      supplier_invoice_line_id,
      qty_impact,
      amount_impact_gbp,
      line_status,
      intended_remedy,
      conversation_status
    )
    SELECT
      v_dispute_id,
      t.supplier_invoice_line_id,
      ROUND(t.qty_impact)::integer,
      ROUND(t.amount_impact_gbp, 2),
      'affected',
      'refund',
      'refund_pending_approval'
    FROM public.customer_hold_refund_target_lines_v1(NEW.id) t;
  END IF;

  UPDATE public.disputes d
  SET amount_impact_gbp = COALESCE((
    SELECT SUM(dl.amount_impact_gbp)
    FROM public.dispute_lines dl
    WHERE dl.dispute_id = d.id
      AND dl.resolved_at IS NULL
  ), 0)
  WHERE d.id = v_dispute_id;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET converted_dispute_id = v_dispute_id,
      updated_at = now()
  WHERE h.id = NEW.id
    AND h.converted_dispute_id IS NULL;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_create_customer_credit_note_drafts_v1(
  p_dispute_id uuid DEFAULT NULL,
  p_original_sales_invoice_id uuid DEFAULT NULL
)
RETURNS TABLE (
  hold_request_id uuid,
  original_sales_invoice_id uuid,
  customer_credit_note_id uuid,
  amount_gbp numeric,
  result_status text,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff_id uuid;
  v_group record;
  v_existing_credit_note_id uuid;
  v_credit_note_id uuid;
  v_amount numeric;
  v_payload jsonb;
  v_reference text;
  v_clean_order_ref text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_active_staff() THEN
    RAISE EXCEPTION
      'Active staff required for customer credit-note draft creation.';
  END IF;

  IF auth.uid() IS NOT NULL THEN
    SELECT s.id
    INTO v_staff_id
    FROM public.staff s
    WHERE s.auth_user_id = auth.uid()
      AND COALESCE(s.active, true) = true
    LIMIT 1;
  END IF;

  FOR v_group IN
    SELECT
      hold_row.id AS hold_request_id,
      dispute_row.id AS dispute_id,
      original_invoice.id AS original_sales_invoice_id,
      original_invoice.order_id,
      original_invoice.invoice_type::text AS original_invoice_type,
      original_invoice.vat_code,
      original_invoice.export_evidence_complete_date,
      original_invoice.zero_rating_deadline_date,
      original_invoice.zero_rating_status,
      order_row.order_ref::text AS order_ref
    FROM public.customer_hold_released_credit_requirements requirement
    JOIN public.customer_pre_shipment_hold_requests hold_row
      ON hold_row.id = requirement.hold_request_id
    JOIN public.disputes dispute_row
      ON dispute_row.id = hold_row.converted_dispute_id
    JOIN public.sales_invoices original_invoice
      ON original_invoice.id = requirement.original_sales_invoice_id
    JOIN public.orders order_row
      ON order_row.id = original_invoice.order_id
    WHERE requirement.requirement_status = 'ready_for_customer_credit_note'
      AND dispute_row.desired_outcome = 'refund'
      AND dispute_row.status = 'refunded'
      AND dispute_row.resolved_at IS NOT NULL
      AND original_invoice.invoice_type IN ('main','supplementary')
      AND original_invoice.sage_status = 'posted'
      AND NULLIF(BTRIM(COALESCE(original_invoice.sage_invoice_id, '')), '')
        IS NOT NULL
      AND original_invoice.sage_posted_at IS NOT NULL
      AND (p_dispute_id IS NULL OR dispute_row.id = p_dispute_id)
      AND (
        p_original_sales_invoice_id IS NULL
        OR original_invoice.id = p_original_sales_invoice_id
      )
    GROUP BY
      hold_row.id,
      dispute_row.id,
      original_invoice.id,
      original_invoice.order_id,
      original_invoice.invoice_type,
      original_invoice.vat_code,
      original_invoice.export_evidence_complete_date,
      original_invoice.zero_rating_deadline_date,
      original_invoice.zero_rating_status,
      order_row.order_ref
    ORDER BY hold_row.id, original_invoice.id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext(
      'customer_credit_note|'
      || v_group.hold_request_id::text
      || '|'
      || v_group.original_sales_invoice_id::text
    ));

    SELECT document.customer_credit_note_id
    INTO v_existing_credit_note_id
    FROM public.customer_hold_credit_note_documents document
    WHERE document.hold_request_id = v_group.hold_request_id
      AND document.original_sales_invoice_id =
            v_group.original_sales_invoice_id
      AND document.document_status <> 'void'
    ORDER BY document.created_at DESC, document.id DESC
    LIMIT 1;

    IF v_existing_credit_note_id IS NULL THEN
      SELECT credit_invoice.id
      INTO v_existing_credit_note_id
      FROM public.sales_invoices credit_invoice
      WHERE credit_invoice.invoice_type = 'credit_note'
        AND credit_invoice.linked_invoice_id =
              v_group.original_sales_invoice_id
        AND credit_invoice.sage_status <> 'void'
        AND credit_invoice.line_items_json
              #>> '{credit_note_control,hold_request_id}'
              = v_group.hold_request_id::text
      ORDER BY credit_invoice.created_at DESC, credit_invoice.id DESC
      LIMIT 1;

      IF v_existing_credit_note_id IS NOT NULL THEN
        INSERT INTO public.customer_hold_credit_note_documents (
          hold_request_id,
          original_sales_invoice_id,
          customer_credit_note_id,
          document_status,
          created_by_staff_id
        )
        SELECT
          v_group.hold_request_id,
          v_group.original_sales_invoice_id,
          v_existing_credit_note_id,
          CASE
            WHEN existing_invoice.sage_status = 'posted' THEN 'posted'
            ELSE 'draft'
          END,
          v_staff_id
        FROM public.sales_invoices existing_invoice
        WHERE existing_invoice.id = v_existing_credit_note_id
        ON CONFLICT DO NOTHING;
      END IF;
    END IF;

    IF v_existing_credit_note_id IS NOT NULL THEN
      UPDATE public.customer_hold_released_credit_requirements requirement
      SET customer_credit_note_id = v_existing_credit_note_id,
          requirement_status = CASE
            WHEN existing_invoice.sage_status = 'posted'
              THEN 'customer_credit_note_posted'
            ELSE 'customer_credit_note_created'
          END,
          status_updated_at = now()
      FROM public.sales_invoices existing_invoice
      WHERE requirement.hold_request_id = v_group.hold_request_id
        AND requirement.original_sales_invoice_id =
              v_group.original_sales_invoice_id
        AND existing_invoice.id = v_existing_credit_note_id
        AND requirement.requirement_status IN (
          'ready_for_customer_credit_note',
          'customer_credit_note_created'
        );

      RETURN QUERY
      SELECT
        v_group.hold_request_id,
        v_group.original_sales_invoice_id,
        v_existing_credit_note_id,
        (
          SELECT ROUND(SUM(requirement.affected_customer_value_gbp), 2)
          FROM public.customer_hold_released_credit_requirements requirement
          WHERE requirement.hold_request_id = v_group.hold_request_id
            AND requirement.original_sales_invoice_id =
                  v_group.original_sales_invoice_id
        )::numeric,
        'existing_credit_note_reused'::text,
        'Existing exact customer credit note reused; no duplicate document created.'::text;
      CONTINUE;
    END IF;

    v_clean_order_ref := NULLIF(
      regexp_replace(
        COALESCE(v_group.order_ref, ''),
        '[^A-Za-z0-9]',
        '',
        'g'
      ),
      ''
    );
    v_reference :=
      LEFT('CN-' || COALESCE(v_clean_order_ref, 'ORDER'), 23)
      || '-'
      || UPPER(SUBSTR(md5(
        v_group.hold_request_id::text
        || '|'
        || v_group.original_sales_invoice_id::text
      ), 1, 8));

    SELECT
      ROUND(SUM(requirement.affected_customer_value_gbp), 2)::numeric,
      jsonb_build_object(
        'sage_header', jsonb_build_object(
          'reference', v_reference,
          'notes',
            'Customer credit for order '
            || COALESCE(v_group.order_ref, v_group.order_id::text)
            || '; original '
            || v_group.original_invoice_type
            || ' invoice '
            || v_group.original_sales_invoice_id::text,
          'currency_code', 'GBP'
        ),
        'tax_resolution', jsonb_build_object(
          'tax_treatment', 'zero_rated_export',
          'display_vat_code', 'zero-rated export'
        ),
        'lines', jsonb_agg(
          jsonb_build_object(
            'line_kind', 'customer_credit_from_mini4_hold',
            'source', 'customer_hold_released_credit_requirements',
            'source_requirement_id', requirement.id,
            'source_hold_request_id', requirement.hold_request_id,
            'source_dispute_id', v_group.dispute_id,
            'source_original_sales_invoice_id',
              requirement.original_sales_invoice_id,
            'source_customer_sales_release_line_id',
              requirement.customer_sales_release_line_id,
            'source_order_id', release_line.order_id,
            'source_commercial_parent_order_id',
              release_line.commercial_parent_order_id,
            'source_shipment_batch_id',
              release_line.source_shipment_batch_id,
            'source_supplier_invoice_id',
              release_line.supplier_invoice_id,
            'source_supplier_invoice_line_id',
              release_line.supplier_invoice_line_id,
            'source_tracking_submission_id',
              release_line.tracking_submission_id,
            'source_tracking_line_allocation_id',
              release_line.tracking_line_allocation_id,
            'affected_qty', requirement.affected_qty,
            'affected_customer_value_gbp',
              requirement.affected_customer_value_gbp,
            'description',
              'Credit: '
              || COALESCE(NULLIF(supplier_line.description, ''), 'Goods'),
            'quantity', requirement.affected_qty,
            'unit_price_gbp', ROUND(
              requirement.affected_customer_value_gbp
              / NULLIF(requirement.affected_qty, 0),
              2
            ),
            'total_line_amount_gbp',
              requirement.affected_customer_value_gbp,
            'ledger_account_role', 'export_sale_income'
          )
          ORDER BY requirement.created_at, requirement.id
        ),
        'credit_note_control', jsonb_build_object(
          'source', 'mini4_exact_released_hold_value',
          'hold_request_id', v_group.hold_request_id,
          'dispute_id', v_group.dispute_id,
          'original_sales_invoice_id',
            v_group.original_sales_invoice_id,
          'original_invoice_type', v_group.original_invoice_type,
          'reference_max_length', 32,
          'status', 'internal_draft_only_not_posted_to_sage'
        )
      )
    INTO v_amount, v_payload
    FROM public.customer_hold_released_credit_requirements requirement
    JOIN public.customer_sales_release_lines release_line
      ON release_line.id = requirement.customer_sales_release_line_id
    LEFT JOIN public.supplier_invoice_lines supplier_line
      ON supplier_line.id = release_line.supplier_invoice_line_id
    WHERE requirement.hold_request_id = v_group.hold_request_id
      AND requirement.original_sales_invoice_id =
            v_group.original_sales_invoice_id
      AND requirement.requirement_status =
            'ready_for_customer_credit_note';

    IF COALESCE(v_amount, 0) <= 0 THEN
      CONTINUE;
    END IF;

    INSERT INTO public.sales_invoices (
      order_id,
      invoice_type,
      linked_invoice_id,
      consideration_received_date,
      sage_invoice_date,
      tax_point_period,
      sage_invoice_period,
      vat_box6_reported_period,
      amount_gbp,
      vat_code,
      line_items_json,
      sage_invoice_id,
      sage_posted_at,
      sage_status,
      export_evidence_complete_date,
      zero_rating_deadline_date,
      zero_rating_status,
      vat_adjustment_posted_at,
      reversal_posted_at,
      raised_by_trigger
    )
    VALUES (
      v_group.order_id,
      'credit_note',
      v_group.original_sales_invoice_id,
      CURRENT_DATE,
      CURRENT_DATE,
      to_char(CURRENT_DATE, 'YYYY-MM'),
      to_char(CURRENT_DATE, 'YYYY-MM'),
      NULL,
      v_amount,
      COALESCE(v_group.vat_code, 'ZERO_RATED_EXPORT_INTENT'),
      v_payload,
      NULL,
      NULL,
      'draft',
      v_group.export_evidence_complete_date,
      COALESCE(
        v_group.zero_rating_deadline_date,
        (CURRENT_DATE + interval '90 days')::date
      ),
      COALESCE(v_group.zero_rating_status, 'on_track'),
      NULL,
      NULL,
      true
    )
    RETURNING id INTO v_credit_note_id;

    INSERT INTO public.customer_hold_credit_note_documents (
      hold_request_id,
      original_sales_invoice_id,
      customer_credit_note_id,
      document_status,
      created_by_staff_id
    )
    VALUES (
      v_group.hold_request_id,
      v_group.original_sales_invoice_id,
      v_credit_note_id,
      'draft',
      v_staff_id
    );

    UPDATE public.customer_hold_released_credit_requirements requirement
    SET customer_credit_note_id = v_credit_note_id,
        requirement_status = 'customer_credit_note_created',
        status_updated_at = now()
    WHERE requirement.hold_request_id = v_group.hold_request_id
      AND requirement.original_sales_invoice_id =
            v_group.original_sales_invoice_id
      AND requirement.requirement_status =
            'ready_for_customer_credit_note';

    RETURN QUERY
    SELECT
      v_group.hold_request_id,
      v_group.original_sales_invoice_id,
      v_credit_note_id,
      v_amount,
      'credit_note_draft_created'::text,
      'Exact customer credit note draft created in the existing sales_invoices/Sage lane. Not posted to Sage.'::text;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_customer_credit_note_document_sync_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.invoice_type IN ('main','supplementary')
     AND NEW.sage_status = 'posted'
     AND NULLIF(BTRIM(COALESCE(NEW.sage_invoice_id, '')), '') IS NOT NULL
     AND NEW.sage_posted_at IS NOT NULL
  THEN
    PERFORM 1
    FROM public.internal_create_customer_credit_note_drafts_v1(
      NULL,
      NEW.id
    );
    RETURN NEW;
  END IF;

  IF NEW.invoice_type = 'credit_note' THEN
    UPDATE public.customer_hold_credit_note_documents document
    SET document_status = CASE
          WHEN NEW.sage_status = 'posted' THEN 'posted'
          WHEN NEW.sage_status = 'void' THEN 'void'
          ELSE 'draft'
        END,
        status_updated_at = now()
    WHERE document.customer_credit_note_id = NEW.id;

    UPDATE public.customer_hold_released_credit_requirements requirement
    SET requirement_status = CASE
          WHEN NEW.sage_status = 'posted'
            THEN 'customer_credit_note_posted'
          WHEN NEW.sage_status = 'void'
            THEN 'ready_for_customer_credit_note'
          ELSE 'customer_credit_note_created'
        END,
        customer_credit_note_id = CASE
          WHEN NEW.sage_status = 'void' THEN NULL
          ELSE NEW.id
        END,
        status_updated_at = now()
    WHERE requirement.customer_credit_note_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_credit_note_document_sync_v1
  ON public.sales_invoices;
CREATE TRIGGER trg_customer_credit_note_document_sync_v1
AFTER INSERT OR UPDATE OF
  invoice_type,
  sage_status,
  sage_invoice_id,
  sage_posted_at
ON public.sales_invoices
FOR EACH ROW
EXECUTE FUNCTION public.trg_customer_credit_note_document_sync_v1();

REVOKE ALL ON FUNCTION
  public.internal_create_customer_credit_note_drafts_v1(uuid,uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.internal_create_customer_credit_note_drafts_v1(uuid,uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.refresh_completed_refund_issue_status_v1(
  p_order_id uuid DEFAULT NULL,
  p_dispute_id uuid DEFAULT NULL
)
RETURNS TABLE (
  disputes_closed integer,
  holds_closed integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_disputes integer := 0;
  v_holds integer := 0;
BEGIN
  WITH completed_refunds AS (
    SELECT d.id AS dispute_id
    FROM public.disputes d
    WHERE d.desired_outcome = 'refund'
      AND d.resolved_at IS NULL
      AND COALESCE(d.status, '') NOT IN (
        'closed',
        'resolved',
        'refunded',
        'replaced',
        'closed_no_action'
      )
      AND (p_order_id IS NULL OR d.order_id = p_order_id)
      AND (p_dispute_id IS NULL OR d.id = p_dispute_id)
      AND EXISTS (
        SELECT 1
        FROM public.dispute_refund_evidence_submissions s
        WHERE s.dispute_id = d.id
          AND s.supplier_approval_status = 'approved_current'
          AND s.supplier_control_status = 'approved_current'
      )
      AND EXISTS (
        SELECT 1
        FROM public.dva_statement_line_allocations a
        WHERE a.dispute_id = d.id
          AND a.allocation_type = 'retailer_refund'
          AND a.allocation_status = 'confirmed'
      )
  )
  UPDATE public.disputes d
  SET status = 'refunded',
      resolved_at = COALESCE(d.resolved_at, now())
  FROM completed_refunds c
  WHERE d.id = c.dispute_id
    AND d.resolved_at IS NULL;

  GET DIAGNOSTICS v_disputes = ROW_COUNT;

  UPDATE public.customer_pre_shipment_hold_requests h
  SET status = 'resolved',
      resolved_at = COALESCE(h.resolved_at, d.resolved_at, now()),
      updated_at = now()
  FROM public.disputes d
  WHERE h.converted_dispute_id = d.id
    AND d.desired_outcome = 'refund'
    AND d.status = 'refunded'
    AND d.resolved_at IS NOT NULL
    AND h.resolved_at IS NULL
    AND h.status IN (
      'requested',
      'supervisor_approved',
      'converted_to_exception'
    )
    AND (p_order_id IS NULL OR h.order_id = p_order_id)
    AND (p_dispute_id IS NULL OR d.id = p_dispute_id);

  GET DIAGNOSTICS v_holds = ROW_COUNT;

  UPDATE public.customer_hold_released_credit_requirements cr
  SET requirement_status = 'ready_for_customer_credit_note',
      status_updated_at = now()
  FROM public.customer_pre_shipment_hold_requests h
  JOIN public.disputes d
    ON d.id = h.converted_dispute_id
  WHERE cr.hold_request_id = h.id
    AND d.desired_outcome = 'refund'
    AND d.status = 'refunded'
    AND d.resolved_at IS NOT NULL
    AND cr.requirement_status = 'pending_refund_completion'
    AND (p_order_id IS NULL OR h.order_id = p_order_id)
    AND (p_dispute_id IS NULL OR d.id = p_dispute_id);

  PERFORM 1
  FROM public.internal_create_customer_credit_note_drafts_v1(
    p_dispute_id,
    NULL
  );

  RETURN QUERY
  SELECT v_disputes, v_holds;
END;
$$;

CREATE OR REPLACE FUNCTION public.internal_customer_credit_note_requirements_v1(
  p_dispute_id uuid DEFAULT NULL
)
RETURNS TABLE (
  dispute_id uuid,
  hold_request_id uuid,
  original_sales_invoice_id uuid,
  original_invoice_type text,
  requirement_count integer,
  affected_qty numeric,
  credit_amount_gbp numeric,
  requirement_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_active_staff() THEN
    RAISE EXCEPTION
      'Active staff required for customer credit-note requirements.';
  END IF;

  RETURN QUERY
  SELECT
    d.id,
    h.id,
    cr.original_sales_invoice_id,
    si.invoice_type::text,
    COUNT(*)::integer,
    ROUND(SUM(cr.affected_qty), 3)::numeric,
    ROUND(SUM(cr.affected_customer_value_gbp), 2)::numeric,
    CASE
      WHEN COUNT(DISTINCT cr.requirement_status) = 1
        THEN MIN(cr.requirement_status)
      ELSE 'mixed'
    END::text
  FROM public.customer_hold_released_credit_requirements cr
  JOIN public.customer_pre_shipment_hold_requests h
    ON h.id = cr.hold_request_id
  JOIN public.disputes d
    ON d.id = h.converted_dispute_id
  JOIN public.sales_invoices si
    ON si.id = cr.original_sales_invoice_id
  WHERE p_dispute_id IS NULL OR d.id = p_dispute_id
  GROUP BY
    d.id,
    h.id,
    cr.original_sales_invoice_id,
    si.invoice_type
  ORDER BY d.id, h.id, cr.original_sales_invoice_id;
END;
$$;

DO $$
BEGIN
  PERFORM 1
  FROM public.internal_create_customer_credit_note_drafts_v1(NULL, NULL);
END;
$$;

REVOKE ALL ON FUNCTION
  public.customer_materialize_hold_review_memberships_v1(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION
  public.customer_materialize_hold_credit_requirements_v1(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.customer_materialize_hold_review_memberships_v1(uuid)
  TO service_role;
GRANT EXECUTE ON FUNCTION
  public.customer_materialize_hold_credit_requirements_v1(uuid)
  TO service_role;

REVOKE ALL ON FUNCTION
  public.internal_customer_credit_note_requirements_v1(uuid)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  public.internal_customer_credit_note_requirements_v1(uuid)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
