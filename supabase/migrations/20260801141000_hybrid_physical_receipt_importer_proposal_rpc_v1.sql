BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Build 2 importer authority: replace the active exact proposal without
-- deleting provenance or writing supervisor, dispute, supplier or child facts.

DO $preflight$
BEGIN
  IF to_regclass('public.physical_receipt_reviews') IS NULL
     OR to_regclass('public.physical_exception_remedy_allocations') IS NULL
     OR to_regclass('public.shipper_package_receipt_line_dispositions') IS NULL
     OR to_regclass('public.operators') IS NULL
     OR to_regclass('public.operator_importers') IS NULL
  THEN
    RAISE EXCEPTION 'Importer physical receipt proposal prerequisites are missing.';
  END IF;

  IF to_regprocedure('public.physical_receipt_review_guard_v1()') IS NULL
     OR to_regprocedure('public.physical_remedy_allocation_guard_v1()') IS NULL
  THEN
    RAISE EXCEPTION 'Importer proposal integrity authorities are missing.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'physical_receipt_reviews'
      AND column_name = 'importer_proposal_note'
  ) THEN
    RAISE EXCEPTION 'Importer proposal note column already exists; inspect before replacing.';
  END IF;

  IF to_regprocedure(
    'public.operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'Importer physical receipt proposal RPC already exists; inspect before replacing.';
  END IF;
END
$preflight$;

ALTER TABLE public.physical_receipt_reviews
  ADD COLUMN importer_proposal_note text,
  ADD CONSTRAINT physical_receipt_review_importer_note_chk
    CHECK (
      importer_proposal_note IS NULL
      OR NULLIF(BTRIM(importer_proposal_note), '') IS NOT NULL
    );

COMMENT ON COLUMN public.physical_receipt_reviews.importer_proposal_note IS
'Latest importer factual proposal note. Supervisor decision_note remains a separate decision fact.';

CREATE FUNCTION public.operator_submit_physical_receipt_proposal_v1(
  p_physical_receipt_review_id uuid,
  p_proposals jsonb,
  p_proposal_note text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_review public.physical_receipt_reviews%ROWTYPE;
  v_proposals jsonb;
  v_proposal_count integer := 0;
  v_cancelled_count integer := 0;
  v_inserted_count integer := 0;
  v_proposed_qty numeric := 0;
  v_event_at timestamptz := clock_timestamp();
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: importer proposal requires auth.uid()';
  END IF;

  IF p_physical_receipt_review_id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review identity is required.';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_proposal_note, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Importer factual proposal note is required.';
  END IF;

  IF jsonb_typeof(COALESCE(p_proposals, 'null'::jsonb)) <> 'array'
     OR jsonb_array_length(p_proposals) = 0 THEN
    RAISE EXCEPTION 'A non-empty importer proposal array is required.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_proposals) proposal_row
    WHERE jsonb_typeof(proposal_row) <> 'object'
       OR EXISTS (
         SELECT 1
         FROM jsonb_object_keys(proposal_row) key_name
         WHERE key_name NOT IN (
           'receipt_line_disposition_id',
           'proposed_remedy_type',
           'proposed_remedy_qty'
         )
       )
  ) THEN
    RAISE EXCEPTION
      'Importer proposal rows may contain only source disposition, remedy type and exact proposed quantity.';
  END IF;

  SELECT operator_row.id
  INTO v_operator_id
  FROM public.operators operator_row
  WHERE operator_row.auth_user_id = v_auth_uid
    AND COALESCE(operator_row.active, true) = true
  ORDER BY operator_row.id
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active importer operator account not found.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_physical_receipt_review_id::text));

  SELECT review_row.*
  INTO v_review
  FROM public.physical_receipt_reviews review_row
  WHERE review_row.id = p_physical_receipt_review_id
  FOR UPDATE;

  IF v_review.id IS NULL THEN
    RAISE EXCEPTION 'Physical receipt review not found.';
  END IF;

  IF v_review.status NOT IN (
    'awaiting_importer_proposal',
    'returned_for_information'
  ) THEN
    RAISE EXCEPTION
      'Importer proposal is allowed only while awaiting importer proposal or returned for information.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers access_row
    WHERE access_row.operator_id = v_operator_id
      AND access_row.importer_id = v_review.importer_id
      AND access_row.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator is not authorised for this review importer.';
  END IF;

  PERFORM 1
  FROM public.shipper_package_receipt_line_dispositions disposition
  WHERE disposition.receipt_id = v_review.receipt_id
    AND disposition.disposition_type <> 'clean'
  ORDER BY disposition.id
  FOR UPDATE;

  PERFORM 1
  FROM public.physical_exception_remedy_allocations remedy_row
  WHERE remedy_row.physical_receipt_review_id = v_review.id
  ORDER BY remedy_row.id
  FOR UPDATE;

  IF EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations remedy_row
    WHERE remedy_row.physical_receipt_review_id = v_review.id
      AND remedy_row.status NOT IN ('proposed','cancelled','rerouted')
  ) THEN
    RAISE EXCEPTION
      'Importer proposal cannot replace a review containing supervisor-approved or progressed remedy facts.';
  END IF;

  SELECT jsonb_agg(
    jsonb_build_object(
      'receipt_line_disposition_id', proposal_row.receipt_line_disposition_id,
      'proposed_remedy_type', proposal_row.proposed_remedy_type,
      'proposed_remedy_qty', proposal_row.proposed_remedy_qty
    ) ORDER BY
      proposal_row.receipt_line_disposition_id,
      proposal_row.proposed_remedy_type
  ), COUNT(*)::integer, COALESCE(SUM(proposal_row.proposed_remedy_qty), 0)::numeric
  INTO v_proposals, v_proposal_count, v_proposed_qty
  FROM jsonb_to_recordset(p_proposals) AS proposal_row(
    receipt_line_disposition_id uuid,
    proposed_remedy_type text,
    proposed_remedy_qty numeric
  );

  IF v_proposal_count = 0 OR v_proposals IS NULL THEN
    RAISE EXCEPTION 'A non-empty importer proposal array is required.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_proposals) AS proposal_row(
      receipt_line_disposition_id uuid,
      proposed_remedy_type text,
      proposed_remedy_qty numeric
    )
    WHERE proposal_row.receipt_line_disposition_id IS NULL
       OR proposal_row.proposed_remedy_type NOT IN (
         'refund','replacement','hold_investigate','no_action'
       )
       OR proposal_row.proposed_remedy_qty IS NULL
       OR proposal_row.proposed_remedy_qty <= 0
  ) THEN
    RAISE EXCEPTION 'One or more importer proposal rows are invalid.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_proposals) AS proposal_row(
      receipt_line_disposition_id uuid,
      proposed_remedy_type text,
      proposed_remedy_qty numeric
    )
    GROUP BY
      proposal_row.receipt_line_disposition_id,
      proposal_row.proposed_remedy_type
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate source-disposition/remedy proposal rows are not allowed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_proposals) AS proposal_row(
      receipt_line_disposition_id uuid,
      proposed_remedy_type text,
      proposed_remedy_qty numeric
    )
    LEFT JOIN public.shipper_package_receipt_line_dispositions disposition
      ON disposition.id = proposal_row.receipt_line_disposition_id
     AND disposition.receipt_id = v_review.receipt_id
     AND disposition.disposition_type <> 'clean'
    WHERE disposition.id IS NULL
  ) THEN
    RAISE EXCEPTION
      'Importer proposal references a source disposition outside this affected receipt.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_to_recordset(v_proposals) AS proposal_row(
      receipt_line_disposition_id uuid,
      proposed_remedy_type text,
      proposed_remedy_qty numeric
    )
    JOIN public.shipper_package_receipt_line_dispositions disposition
      ON disposition.id = proposal_row.receipt_line_disposition_id
    GROUP BY disposition.id, disposition.quantity
    HAVING SUM(proposal_row.proposed_remedy_qty)
      > disposition.quantity + 0.0005
  ) THEN
    RAISE EXCEPTION
      'Importer proposed remedy quantity exceeds an affected receipt disposition.';
  END IF;

  UPDATE public.physical_exception_remedy_allocations remedy_row
  SET status = 'cancelled',
      updated_at = v_event_at
  WHERE remedy_row.physical_receipt_review_id = v_review.id
    AND remedy_row.status = 'proposed';

  GET DIAGNOSTICS v_cancelled_count = ROW_COUNT;

  INSERT INTO public.physical_exception_remedy_allocations (
    physical_receipt_review_id,
    receipt_line_disposition_id,
    tracking_line_allocation_id,
    supplier_invoice_line_id,
    proposed_remedy_type,
    proposed_remedy_qty,
    proposed_by_operator_id,
    proposed_at,
    status
  )
  SELECT
    v_review.id,
    disposition.id,
    disposition.tracking_line_allocation_id,
    disposition.supplier_invoice_line_id,
    proposal_row.proposed_remedy_type,
    proposal_row.proposed_remedy_qty,
    v_operator_id,
    v_event_at,
    'proposed'
  FROM jsonb_to_recordset(v_proposals) AS proposal_row(
    receipt_line_disposition_id uuid,
    proposed_remedy_type text,
    proposed_remedy_qty numeric
  )
  JOIN public.shipper_package_receipt_line_dispositions disposition
    ON disposition.id = proposal_row.receipt_line_disposition_id;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  IF v_inserted_count <> v_proposal_count THEN
    RAISE EXCEPTION 'Importer proposal rows could not be inserted exactly.';
  END IF;

  UPDATE public.physical_receipt_reviews review_row
  SET status = 'awaiting_supervisor_review',
      importer_proposed_by_operator_id = v_operator_id,
      importer_proposed_at = v_event_at,
      importer_proposal_note = BTRIM(p_proposal_note),
      updated_at = v_event_at
  WHERE review_row.id = v_review.id
    AND review_row.status IN (
      'awaiting_importer_proposal',
      'returned_for_information'
    );

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Physical receipt review changed before proposal submission completed.';
  END IF;

  RETURN jsonb_build_object(
    'physical_receipt_review_id', v_review.id,
    'status', 'awaiting_supervisor_review',
    'proposal_count', v_inserted_count,
    'proposed_quantity', v_proposed_qty,
    'cancelled_prior_proposal_count', v_cancelled_count
  );
END;
$function$;

COMMENT ON FUNCTION public.operator_submit_physical_receipt_proposal_v1(
  uuid,jsonb,text
) IS
'Importer-scoped atomic exact proposal replacement authority. Cancels prior open proposal rows without deletion, inserts only importer proposal facts and advances the physical review to supervisor review.';

REVOKE ALL ON FUNCTION public.operator_submit_physical_receipt_proposal_v1(
  uuid,jsonb,text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.operator_submit_physical_receipt_proposal_v1(
  uuid,jsonb,text
) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
