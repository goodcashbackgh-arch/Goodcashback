BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Surgical correction of the deployed Mini 4 materialiser.
--
-- Proven defects:
-- 1. membership_fingerprint was candidate-scoped rather than cycle-scoped;
-- 2. the new-cycle path inserted a timed link before re-reading candidates.
--    customer_review_cycle_candidates_v1 deliberately suppresses candidates
--    behind a timed link with no proven membership, so the materialiser blocked
--    its own insert, deleted the link and returned zero.
--
-- The corrected path creates the new link with expires_at NULL inside the same
-- transaction, inserts immutable memberships, then publishes the already-fixed
-- deadline only after at least one membership exists. No other transaction can
-- observe the temporary untimed state.
DO $patch$
DECLARE
  v_proc regprocedure :=
    'public.internal_materialize_customer_review_cycles_v1(uuid,uuid)'::regprocedure;
  v_definition text;
  v_patched text;
  v_raw_fingerprint_count integer;
  v_timed_insert_count integer;
  v_publish_marker_count integer;
BEGIN
  SELECT pg_get_functiondef(v_proc)
    INTO v_definition;

  IF position(
       'md5(v_link_id::text || ''|'' || candidate.source_fingerprint)'
       IN v_definition
     ) > 0
     AND position(
       'SET expires_at = v_deadline'
       IN v_definition
     ) > 0
     AND position(
       E'VALUES (\n    p_order_id,\n    true,\n    NULL,\n    p_created_by_staff_id'
       IN replace(v_definition, chr(13), '')
     ) > 0 THEN
    RETURN;
  END IF;

  SELECT count(*)::integer
    INTO v_raw_fingerprint_count
  FROM regexp_matches(
    v_definition,
    E'(^|\\n)[[:space:]]*candidate\\.source_fingerprint,',
    'g'
  );

  IF v_raw_fingerprint_count <> 2 THEN
    RAISE EXCEPTION
      'Expected exactly two raw candidate fingerprint writes, found %; no replacement applied.',
      v_raw_fingerprint_count;
  END IF;

  SELECT count(*)::integer
    INTO v_timed_insert_count
  FROM regexp_matches(
    replace(v_definition, chr(13), ''),
    E'VALUES \\(\\n[[:space:]]*p_order_id,\\n[[:space:]]*true,\\n[[:space:]]*v_deadline,\\n[[:space:]]*p_created_by_staff_id\\n[[:space:]]*\\)',
    'g'
  );

  IF v_timed_insert_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one new-cycle timed-link insert, found %; no replacement applied.',
      v_timed_insert_count;
  END IF;

  SELECT count(*)::integer
    INTO v_publish_marker_count
  FROM regexp_matches(
    replace(v_definition, chr(13), ''),
    E'IF v_total_inserted = 0 THEN[\\s\\S]*?END IF;\\n\\n[[:space:]]*RETURN v_total_inserted;',
    'g'
  );

  IF v_publish_marker_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one new-cycle success return block, found %; no replacement applied.',
      v_publish_marker_count;
  END IF;

  v_patched := regexp_replace(
    replace(v_definition, chr(13), ''),
    E'(^|\\n)([[:space:]]*)candidate\\.source_fingerprint,',
    E'\\1\\2md5(v_link_id::text || ''|'' || candidate.source_fingerprint),',
    'g'
  );

  v_patched := regexp_replace(
    v_patched,
    E'(VALUES \\(\\n[[:space:]]*p_order_id,\\n[[:space:]]*true,\\n)[[:space:]]*v_deadline,(\\n[[:space:]]*p_created_by_staff_id\\n[[:space:]]*\\))',
    E'\\1    NULL,\\2'
  );

  v_patched := regexp_replace(
    v_patched,
    E'(IF v_total_inserted = 0 THEN[\\s\\S]*?END IF;\\n\\n)([[:space:]]*)RETURN v_total_inserted;',
    E'\\1\\2UPDATE public.customer_order_review_links\\n\\2SET expires_at = v_deadline\\n\\2WHERE id = v_link_id;\\n\\n\\2RETURN v_total_inserted;'
  );

  IF position(
       'md5(v_link_id::text || ''|'' || candidate.source_fingerprint)'
       IN v_patched
     ) = 0
     OR position('SET expires_at = v_deadline' IN v_patched) = 0
     OR position(
       E'VALUES (\n    p_order_id,\n    true,\n    NULL,\n    p_created_by_staff_id'
       IN v_patched
     ) = 0 THEN
    RAISE EXCEPTION
      'Mini 4 materialiser patch did not produce the required cycle-scoped and self-suppression-safe definition.';
  END IF;

  EXECUTE v_patched;
END
$patch$;

REVOKE ALL ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.internal_materialize_customer_review_cycles_v1(uuid, uuid)
TO service_role;

-- Re-run the same idempotent materialiser whenever facts that can make an
-- already-received package reviewable are created or changed after receipt.
CREATE OR REPLACE FUNCTION public.customer_review_candidate_change_materialize_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'order_tracking_line_allocations' THEN
    v_order_id := NEW.order_id;

  ELSIF TG_TABLE_NAME = 'supplier_invoice_lines' THEN
    FOR v_order_id IN
      SELECT DISTINCT allocation.order_id
      FROM public.order_tracking_line_allocations allocation
      WHERE allocation.supplier_invoice_line_id = NEW.id
    LOOP
      PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
    END LOOP;
    RETURN NEW;

  ELSIF TG_TABLE_NAME = 'supplier_invoices' THEN
    v_order_id := NEW.order_id;
  END IF;

  IF v_order_id IS NOT NULL THEN
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_review_candidate_change_materialize_v1()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_review_candidate_change_materialize_v1()
TO service_role;

DROP TRIGGER IF EXISTS trg_customer_review_allocation_materialize_v1
  ON public.order_tracking_line_allocations;
CREATE TRIGGER trg_customer_review_allocation_materialize_v1
AFTER INSERT OR UPDATE OF
  order_id,
  tracking_submission_id,
  supplier_invoice_line_id,
  qty_allocated,
  base_value_gbp,
  retailer_delivery_share_gbp,
  discount_share_gbp
ON public.order_tracking_line_allocations
FOR EACH ROW
WHEN (
  NEW.supplier_invoice_line_id IS NOT NULL
  AND COALESCE(NEW.qty_allocated, 0) > 0
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DROP TRIGGER IF EXISTS trg_customer_review_supplier_line_materialize_v1
  ON public.supplier_invoice_lines;
CREATE TRIGGER trg_customer_review_supplier_line_materialize_v1
AFTER UPDATE OF eligible_for_invoice_yn
ON public.supplier_invoice_lines
FOR EACH ROW
WHEN (
  NEW.eligible_for_invoice_yn IS DISTINCT FROM OLD.eligible_for_invoice_yn
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

DROP TRIGGER IF EXISTS trg_customer_review_supplier_invoice_materialize_v1
  ON public.supplier_invoices;
CREATE TRIGGER trg_customer_review_supplier_invoice_materialize_v1
AFTER UPDATE OF review_status
ON public.supplier_invoices
FOR EACH ROW
WHEN (
  NEW.review_status IS DISTINCT FROM OLD.review_status
)
EXECUTE FUNCTION public.customer_review_candidate_change_materialize_v1();

-- Recover only orders with at least one candidate whose own receipt window is
-- currently open. Expired cycles are never reconstructed.
DO $recover$
DECLARE
  v_order_id uuid;
BEGIN
  FOR v_order_id IN
    SELECT DISTINCT candidate.order_id
    FROM public.orders order_row
    CROSS JOIN LATERAL
      public.customer_review_cycle_candidates_v1(order_row.id) candidate
    WHERE candidate.receipt_recorded_at <= now()
      AND candidate.receipt_recorded_at + interval '24 hours' > now()
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_legacy_issues issue
        WHERE issue.order_id = candidate.order_id
          AND issue.resolved_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = candidate.order_id
          AND link_row.is_active = true
          AND link_row.expires_at IS NULL
      )
      AND (
        SELECT count(*)
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = candidate.order_id
          AND link_row.is_active = true
      ) <= 1
  LOOP
    PERFORM public.internal_materialize_customer_review_cycles_v1(v_order_id, NULL);
  END LOOP;
END
$recover$;

DO $verify$
DECLARE
  v_missing_cycle_count integer;
  v_unexplained_empty_cycle_count integer;
BEGIN
  SELECT count(*)::integer
    INTO v_missing_cycle_count
  FROM (
    SELECT DISTINCT candidate.order_id
    FROM public.orders order_row
    CROSS JOIN LATERAL
      public.customer_review_cycle_candidates_v1(order_row.id) candidate
    WHERE candidate.receipt_recorded_at <= now()
      AND candidate.receipt_recorded_at + interval '24 hours' > now()
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_review_cycle_legacy_issues issue
        WHERE issue.order_id = candidate.order_id
          AND issue.resolved_at IS NULL
      )
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links untimed_link
        WHERE untimed_link.order_id = candidate.order_id
          AND untimed_link.is_active = true
          AND untimed_link.expires_at IS NULL
      )
      AND (
        SELECT count(*)
        FROM public.customer_order_review_links active_link
        WHERE active_link.order_id = candidate.order_id
          AND active_link.is_active = true
      ) <= 1
      AND NOT EXISTS (
        SELECT 1
        FROM public.customer_order_review_links link_row
        WHERE link_row.order_id = candidate.order_id
          AND link_row.is_active = true
          AND link_row.expires_at IS NOT NULL
          AND link_row.expires_at > now()
      )
  ) missing_cycle;

  SELECT count(*)::integer
    INTO v_unexplained_empty_cycle_count
  FROM public.customer_order_review_links link_row
  WHERE link_row.is_active = true
    AND link_row.expires_at IS NOT NULL
    AND link_row.expires_at > now()
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_memberships membership
      WHERE membership.review_link_id = link_row.id
        AND membership.membership_status = 'active'
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.customer_review_cycle_legacy_issues issue
      WHERE issue.order_id = link_row.order_id
        AND issue.review_link_id = link_row.id
        AND issue.resolved_at IS NULL
    );

  IF v_missing_cycle_count <> 0 OR v_unexplained_empty_cycle_count <> 0 THEN
    RAISE EXCEPTION
      'Mini 4 platform verification failed: materialisable missing cycles %, unexplained empty open cycles %.',
      v_missing_cycle_count,
      v_unexplained_empty_cycle_count;
  END IF;
END
$verify$;

COMMIT;
