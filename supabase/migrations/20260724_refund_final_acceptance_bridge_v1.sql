BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Remove the duplicate supervisor step for refund evidence entry.
-- The original supervisor refund-pursuit approval remains mandatory.
-- Once the retailer outcome is marked accepted, the existing operator update RPC
-- advances the dispute to awaiting_refund_credit atomically and records an audit
-- message. Refund evidence review/approval remains unchanged.

DO $$
BEGIN
  IF to_regclass('public.disputes') IS NULL THEN RAISE EXCEPTION 'Missing public.disputes'; END IF;
  IF to_regclass('public.dispute_lines') IS NULL THEN RAISE EXCEPTION 'Missing public.dispute_lines'; END IF;
  IF to_regclass('public.dispute_messages') IS NULL THEN RAISE EXCEPTION 'Missing public.dispute_messages'; END IF;
  IF to_regclass('public.dispute_refund_evidence_submissions') IS NULL THEN RAISE EXCEPTION 'Missing public.dispute_refund_evidence_submissions'; END IF;
  IF to_regclass('public.operators') IS NULL THEN RAISE EXCEPTION 'Missing public.operators'; END IF;
  IF to_regclass('public.operator_importers') IS NULL THEN RAISE EXCEPTION 'Missing public.operator_importers'; END IF;
  IF to_regprocedure('public.operator_update_dispute_retailer_update(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'Missing public.operator_update_dispute_retailer_update(uuid,text,text)';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.operator_update_dispute_retailer_update(
  p_dispute_id uuid,
  p_retailer_response text,
  p_retailer_outcome text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid uuid := auth.uid();
  v_operator_id uuid;
  v_importer_id uuid;
  v_status text;
  v_response text := btrim(coalesce(p_retailer_response, ''));
  v_message_id uuid;
  v_updated_lines integer := 0;
  v_desired_outcome text;
  v_dispute_status text;
  v_refund_approved_at timestamptz;
  v_advanced_to_refund_evidence boolean := false;
BEGIN
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'Unauthenticated user: retailer update requires auth.uid()';
  END IF;

  SELECT o.id
    INTO v_operator_id
  FROM public.operators o
  WHERE o.auth_user_id = v_auth_uid
    AND o.active = true
  LIMIT 1;

  IF v_operator_id IS NULL THEN
    RAISE EXCEPTION 'Active operator account not found for auth user %', v_auth_uid;
  END IF;

  IF p_retailer_outcome NOT IN ('still_waiting', 'retailer_accepted', 'retailer_disputed', 'more_info_requested') THEN
    RAISE EXCEPTION 'Invalid retailer outcome: %', p_retailer_outcome;
  END IF;

  IF p_retailer_outcome IN ('retailer_accepted', 'retailer_disputed') AND v_response = '' THEN
    RAISE EXCEPTION 'Retailer response is required when outcome is %', p_retailer_outcome;
  END IF;

  SELECT
    ord.importer_id,
    d.desired_outcome::text,
    d.status::text,
    d.refund_approved_at
  INTO
    v_importer_id,
    v_desired_outcome,
    v_dispute_status,
    v_refund_approved_at
  FROM public.disputes d
  JOIN public.orders ord ON ord.id = d.order_id
  WHERE d.id = p_dispute_id
  FOR UPDATE OF d;

  IF v_importer_id IS NULL THEN
    RAISE EXCEPTION 'Dispute % not found or parent order importer missing', p_dispute_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.operator_importers oi
    WHERE oi.operator_id = v_operator_id
      AND oi.importer_id = v_importer_id
      AND oi.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Operator % is not linked to dispute importer %', v_operator_id, v_importer_id;
  END IF;

  v_status := CASE p_retailer_outcome
    WHEN 'still_waiting' THEN 'retailer_contacted'
    WHEN 'retailer_accepted' THEN 'retailer_response_received'
    WHEN 'retailer_disputed' THEN 'awaiting_retailer_resolution'
    WHEN 'more_info_requested' THEN 'retailer_draft_ready'
  END;

  IF v_response <> '' THEN
    INSERT INTO public.dispute_messages (
      dispute_id,
      message_type,
      counterparty,
      generated_by,
      body
    )
    VALUES (
      p_dispute_id,
      'retailer_reply',
      'retailer',
      'retailer_paste',
      v_response
    )
    RETURNING id INTO v_message_id;
  END IF;

  UPDATE public.dispute_lines
  SET conversation_status = v_status
  WHERE dispute_id = p_dispute_id
    AND resolved_at IS NULL;

  GET DIAGNOSTICS v_updated_lines = ROW_COUNT;

  IF v_updated_lines = 0 THEN
    RAISE EXCEPTION 'No unresolved dispute lines found for dispute %', p_dispute_id;
  END IF;

  IF p_retailer_outcome = 'retailer_accepted'
     AND v_desired_outcome = 'refund'
     AND v_refund_approved_at IS NOT NULL
     AND v_dispute_status IN ('raised', 'under_review', 'approved_refund') THEN
    UPDATE public.disputes
    SET status = 'awaiting_refund_credit'
    WHERE id = p_dispute_id
      AND status::text IN ('raised', 'under_review', 'approved_refund');

    v_advanced_to_refund_evidence := FOUND;

    IF v_advanced_to_refund_evidence THEN
      INSERT INTO public.dispute_messages (
        dispute_id,
        message_type,
        counterparty,
        generated_by,
        body
      )
      VALUES (
        p_dispute_id,
        'supervisor_note',
        'internal',
        'manual',
        concat(
          '[REFUND_FINAL_ACCEPTANCE_BRIDGE_V1]', E'\n',
          'Refund pursuit was already approved at ',
          v_refund_approved_at,
          '. Retailer outcome was then marked accepted by operator ',
          v_operator_id,
          '. Dispute advanced to awaiting_refund_credit without a duplicate supervisor acceptance step.'
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'dispute_id', p_dispute_id,
    'retailer_outcome', p_retailer_outcome,
    'conversation_status', v_status,
    'retailer_response_saved', (v_response <> ''),
    'dispute_message_id', v_message_id,
    'updated_lines', v_updated_lines,
    'advanced_to_refund_evidence', v_advanced_to_refund_evidence
  );
END;
$$;

COMMENT ON FUNCTION public.operator_update_dispute_retailer_update(uuid, text, text) IS
'Operator-only atomic retailer update. For refund disputes, an already supervisor-approved refund pursuit plus an operator-recorded retailer acceptance advances to awaiting_refund_credit without a second supervisor acceptance; audit evidence is retained.';

REVOKE ALL ON FUNCTION public.operator_update_dispute_retailer_update(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.operator_update_dispute_retailer_update(uuid, text, text) TO authenticated;

-- Repair existing disputes that already satisfy the same proven conditions.
-- Approved-current refund evidence is also accepted as stronger terminal proof,
-- covering legacy records where the line was resolved before this bridge existed.
WITH eligible AS (
  SELECT d.id, d.refund_approved_at
  FROM public.disputes d
  WHERE d.desired_outcome::text = 'refund'
    AND d.refund_approved_at IS NOT NULL
    AND d.status::text IN ('raised', 'under_review', 'approved_refund')
    AND EXISTS (
      SELECT 1
      FROM public.dispute_messages dm
      WHERE dm.dispute_id = d.id
        AND dm.message_type = 'retailer_reply'
    )
    AND (
      (
        EXISTS (
          SELECT 1
          FROM public.dispute_lines dl
          WHERE dl.dispute_id = d.id
            AND dl.resolved_at IS NULL
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.dispute_lines dl
          WHERE dl.dispute_id = d.id
            AND dl.resolved_at IS NULL
            AND COALESCE(dl.conversation_status::text, '') <> 'retailer_response_received'
        )
      )
      OR EXISTS (
        SELECT 1
        FROM public.dispute_refund_evidence_submissions s
        WHERE s.dispute_id = d.id
          AND (
            s.supplier_approval_status::text IN ('approved_current', 'ref_corrected_approved')
            OR s.supplier_control_status::text IN ('approved_current', 'ref_corrected_approved')
          )
      )
    )
), advanced AS (
  UPDATE public.disputes d
  SET status = 'awaiting_refund_credit'
  FROM eligible e
  WHERE d.id = e.id
  RETURNING d.id, e.refund_approved_at
)
INSERT INTO public.dispute_messages (
  dispute_id,
  message_type,
  counterparty,
  generated_by,
  body
)
SELECT
  a.id,
  'supervisor_note',
  'internal',
  'manual',
  concat(
    '[REFUND_FINAL_ACCEPTANCE_BRIDGE_V1]', E'\n',
    'Existing refund dispute aligned to awaiting_refund_credit. Refund pursuit was approved at ',
    a.refund_approved_at,
    ' and retailer acceptance or approved-current refund evidence already existed.'
  )
FROM advanced a
WHERE NOT EXISTS (
  SELECT 1
  FROM public.dispute_messages dm
  WHERE dm.dispute_id = a.id
    AND dm.body LIKE '[REFUND_FINAL_ACCEPTANCE_BRIDGE_V1]%'
);

-- Guard the known live dispute when its proven prerequisites exist.
DO $$
DECLARE
  v_status text;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.disputes d
    WHERE d.id = '904d1bd3-86e9-47ad-bbf9-96859d900d22'::uuid
      AND d.desired_outcome::text = 'refund'
      AND d.refund_approved_at IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public.dispute_refund_evidence_submissions s
        WHERE s.dispute_id = d.id
          AND (
            s.supplier_approval_status::text IN ('approved_current', 'ref_corrected_approved')
            OR s.supplier_control_status::text IN ('approved_current', 'ref_corrected_approved')
          )
      )
  ) THEN
    SELECT status::text INTO v_status
    FROM public.disputes
    WHERE id = '904d1bd3-86e9-47ad-bbf9-96859d900d22'::uuid;

    IF v_status NOT IN ('awaiting_refund_credit', 'refunded', 'closed') THEN
      RAISE EXCEPTION 'Known approved refund dispute did not enter the refund evidence lane: %', v_status;
    END IF;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
