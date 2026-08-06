BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- One-off incident restoration.
--
-- Purpose:
--   * preserve the exact-clean mixed-package compatibility installed by
--     20260806131500 and 20260806133500;
--   * void only the later unposted J040826v1 £20 test draft;
--   * reverse only that draft's two durable release memberships;
--   * restore the pre-incident parent-wide active-draft, creator, queue-count
--     and uniqueness rules.
--
-- This script is intentionally not a migration. It performs audited
-- operational-row changes and must be run once, manually, after review.

CREATE TEMP TABLE _incident_restore_protected (
  identity text PRIMARY KEY,
  row_hash text NOT NULL
) ON COMMIT DROP;

DO $preflight_and_cleanup$
DECLARE
  v_parent uuid := '1b4a2a43-5ddd-41ef-aef5-45e621eb5819';
  v_keep_invoice uuid := 'a3c939e4-0abb-4047-b828-cdc137130fd4';
  v_keep_batch uuid := '1d8ed4af-4d35-4b2d-9913-9bae1a20a717';
  v_test_invoice uuid := '1a2e9e5d-6a10-42b8-8d52-c9253959f07b';
  v_test_batch uuid := '47029c7e-e2db-47fa-8c79-fec09b751542';
  v_main_invoice uuid := '3c73bd58-3802-4433-9b93-9e68d4d527db';
  v_staff uuid;
  v_count integer;
  v_total numeric;
  v_collision_groups integer;
BEGIN
  IF to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.sage_posting_snapshots') IS NULL
     OR to_regclass('public.staff') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)') IS NULL
  THEN
    RAISE EXCEPTION 'Incident restoration prerequisites are missing.';
  END IF;

  IF to_regclass('public.uq_sales_invoices_active_release_draft_v1') IS NOT NULL
     OR to_regclass('public.idx_sales_invoices_active_release_draft_v2') IS NULL
     OR to_regclass('public.uq_csrl_active_membership_fingerprint_v1') IS NULL
  THEN
    RAISE EXCEPTION 'Draft index state is not the expected incident shape.';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtext('customer_sales_release|' || v_parent::text)
  );

  PERFORM 1
  FROM public.sales_invoices invoice_row
  WHERE invoice_row.id IN (v_keep_invoice, v_test_invoice)
  ORDER BY invoice_row.id
  FOR UPDATE;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.id = v_keep_invoice
      AND invoice_row.order_id = v_parent
      AND invoice_row.invoice_type = 'supplementary'
      AND invoice_row.linked_invoice_id = v_main_invoice
      AND invoice_row.sage_status = 'draft'
      AND invoice_row.amount_gbp = 10.00
      AND invoice_row.sage_invoice_id IS NULL
      AND invoice_row.sage_posted_at IS NULL
      AND invoice_row.sage_reference IS NULL
      AND invoice_row.line_items_json #>> '{draft_control,shipment_batch_id}'
          = v_keep_batch::text
      AND invoice_row.line_items_json #>> '{sage_header,notes}'
          = 'Booking J040826'
  ) THEN
    RAISE EXCEPTION 'Protected J040826 £10 draft does not match the accepted live record.';
  END IF;

  SELECT COUNT(*)::integer,
         COALESCE(SUM(release_line.customer_charge_amount_gbp), 0)
  INTO v_count, v_total
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.sales_invoice_id = v_keep_invoice
    AND release_line.release_status = 'active'
    AND release_line.source_shipment_batch_id = v_keep_batch
    AND release_line.membership_fingerprint
        = 'f9f4041d776bd6f5dc632323a0eff373';

  IF v_count IS DISTINCT FROM 1 OR v_total IS DISTINCT FROM 10.00 THEN
    RAISE EXCEPTION
      'Protected J040826 membership mismatch: count %, total %.',
      v_count, v_total;
  END IF;

  INSERT INTO _incident_restore_protected(identity, row_hash)
  SELECT 'keep_invoice', md5(to_jsonb(invoice_row)::text)
  FROM public.sales_invoices invoice_row
  WHERE invoice_row.id = v_keep_invoice;

  INSERT INTO _incident_restore_protected(identity, row_hash)
  SELECT 'keep_membership', md5(to_jsonb(release_line)::text)
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.sales_invoice_id = v_keep_invoice
    AND release_line.release_status = 'active';

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.id = v_test_invoice
      AND invoice_row.order_id = v_parent
      AND invoice_row.invoice_type = 'supplementary'
      AND invoice_row.linked_invoice_id = v_main_invoice
      AND invoice_row.sage_status = 'draft'
      AND invoice_row.amount_gbp = 20.00
      AND invoice_row.sage_invoice_id IS NULL
      AND invoice_row.sage_posted_at IS NULL
      AND invoice_row.sage_reference IS NULL
      AND invoice_row.reversal_posted_at IS NULL
      AND invoice_row.line_items_json #>> '{draft_control,shipment_batch_id}'
          = v_test_batch::text
      AND invoice_row.line_items_json #>> '{sage_header,notes}'
          = 'Booking J040826v1'
  ) THEN
    RAISE EXCEPTION 'J040826v1 £20 test draft does not match the removable incident record.';
  END IF;

  SELECT
    COUNT(*)::integer,
    COALESCE(SUM(release_line.customer_charge_amount_gbp), 0),
    (ARRAY_AGG(DISTINCT release_line.created_by_staff_id)
      FILTER (WHERE release_line.created_by_staff_id IS NOT NULL))[1]
  INTO v_count, v_total, v_staff
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.sales_invoice_id = v_test_invoice
    AND release_line.release_status = 'active'
    AND release_line.source_shipment_batch_id = v_test_batch
    AND release_line.membership_fingerprint IN (
      '5851c986ea95a8cf516da2cfddf1c5a7',
      'ba7693af884b3a295fb1a0f36c45e4fe'
    );

  IF v_count IS DISTINCT FROM 2 OR v_total IS DISTINCT FROM 20.00 THEN
    RAISE EXCEPTION
      'J040826v1 active membership mismatch: count %, total %.',
      v_count, v_total;
  END IF;

  IF (
    SELECT COUNT(DISTINCT release_line.created_by_staff_id)
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = v_test_invoice
      AND release_line.release_status = 'active'
  ) IS DISTINCT FROM 1
     OR v_staff IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM public.staff staff_row
       WHERE staff_row.id = v_staff
         AND staff_row.active = true
     )
  THEN
    RAISE EXCEPTION 'J040826v1 test memberships do not resolve to one active creating staff member.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = v_test_invoice
      AND (
        release_line.release_status <> 'active'
        OR release_line.source_shipment_batch_id IS DISTINCT FROM v_test_batch
        OR release_line.membership_fingerprint NOT IN (
          '5851c986ea95a8cf516da2cfddf1c5a7',
          'ba7693af884b3a295fb1a0f36c45e4fe'
        )
      )
  ) THEN
    RAISE EXCEPTION 'J040826v1 test invoice contains unexpected release membership.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sage_posting_snapshots snapshot_row
    WHERE snapshot_row.source_table = 'sales_invoices'
      AND snapshot_row.source_id = v_test_invoice
      AND COALESCE(snapshot_row.active, true) = true
      AND COALESCE(snapshot_row.sage_posting_status, 'not_posted') <> 'voided'
  ) THEN
    RAISE EXCEPTION 'J040826v1 test draft has an active Sage posting snapshot.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_collision_groups
  FROM (
    SELECT invoice_row.order_id
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.invoice_type IN ('main', 'supplementary')
      AND invoice_row.sage_status = 'draft'
    GROUP BY invoice_row.order_id
    HAVING COUNT(*) > 1
  ) collision;

  IF v_collision_groups IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Expected exactly one parent with multiple active drafts; found %.',
      v_collision_groups;
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.sales_invoices invoice_row
  WHERE invoice_row.order_id = v_parent
    AND invoice_row.invoice_type IN ('main', 'supplementary')
    AND invoice_row.sage_status = 'draft'
    AND invoice_row.id IN (v_keep_invoice, v_test_invoice);

  IF v_count IS DISTINCT FROM 2 OR EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.order_id = v_parent
      AND invoice_row.invoice_type IN ('main', 'supplementary')
      AND invoice_row.sage_status = 'draft'
      AND invoice_row.id NOT IN (v_keep_invoice, v_test_invoice)
  ) THEN
    RAISE EXCEPTION 'The parent draft collision is not exactly the two known incident invoices.';
  END IF;

  UPDATE public.sales_invoices invoice_row
  SET sage_status = 'void'
  WHERE invoice_row.id = v_test_invoice
    AND invoice_row.sage_status = 'draft';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'J040826v1 test invoice was not voided.';
  END IF;

  UPDATE public.customer_sales_release_lines release_line
  SET release_status = 'reversed',
      reversed_at = clock_timestamp(),
      reversed_by_staff_id = v_staff,
      reversal_reason =
        'Incident restoration: later J040826v1 test draft withdrawn while restoring pre-incident parent-wide draft rules.'
  WHERE release_line.sales_invoice_id = v_test_invoice
    AND release_line.release_status = 'active';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Expected to reverse two J040826v1 memberships; reversed %.', v_count;
  END IF;
END
$preflight_and_cleanup$;

DO $restore_resolver$
DECLARE
  v_definition text;
  v_pattern text :=
    $pattern$EXISTS[[:space:]]*\([[:space:]]*SELECT[[:space:]]+1[[:space:]]+FROM[[:space:]]+public\.customer_sales_release_lines[[:space:]]+active_membership[[:space:]]+JOIN[[:space:]]+public\.sales_invoices[[:space:]]+existing_draft.*?existing_draft\.sage_status[[:space:]]*=[[:space:]]*'draft'[[:space:]]*\)[[:space:]]+AS[[:space:]]+has_active_draft$pattern$;
  v_replacement text := $replacement$EXISTS (
        SELECT 1
        FROM public.sales_invoices existing_draft
        WHERE existing_draft.order_id = CASE
          WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
            THEN order_row.parent_order_id
          ELSE order_row.id
        END
          AND existing_draft.invoice_type IN ('main', 'supplementary')
          AND existing_draft.sage_status = 'draft'
      ) AS has_active_draft$replacement$;
  v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM regexp_matches(v_definition, v_pattern, 'gis');

  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Exact-batch resolver expression count was %, expected 1.',
      COALESCE(v_count, 0);
  END IF;

  v_definition := regexp_replace(
    v_definition,
    v_pattern,
    v_replacement,
    'gis'
  );

  IF md5(v_definition) IS DISTINCT FROM '4011a399f02cda16b5d962b8101f91e1' THEN
    RAISE EXCEPTION
      'Resolver reverse-substitution did not reproduce the governed mixed-package definition: %.',
      md5(v_definition);
  END IF;

  EXECUTE v_definition;
END
$restore_resolver$;

DO $restore_creator$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
  v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
  ) INTO v_definition;

  v_old := $old$  v_booking text;
  v_parent_count integer;
BEGIN$old$;
  v_new := $new$  v_booking text;
BEGIN$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Exact-batch creator declaration anchor is missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$  CREATE INDEX ON _release_src (
    shipment_batch_id,
    commercial_parent_order_id,
    proposed_invoice_type
  );$old$;
  v_new := $new$  CREATE INDEX ON _release_src (commercial_parent_order_id, proposed_invoice_type);$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Exact-batch creator temporary-index anchor is missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$  FOR v_batch IN
    SELECT rs.shipment_batch_id
    FROM _release_src rs
    GROUP BY rs.shipment_batch_id
    ORDER BY MIN(rs.commercial_parent_order_id::text), rs.shipment_batch_id
  LOOP
    SELECT
      (ARRAY_AGG(DISTINCT rs.commercial_parent_order_id
                 ORDER BY rs.commercial_parent_order_id))[1],
      COUNT(DISTINCT rs.commercial_parent_order_id)::integer,
      MIN(rs.order_ref),
      string_agg(DISTINCT rs.booking_ref, ', ' ORDER BY rs.booking_ref)
    INTO v_parent, v_parent_count, v_ref, v_booking
    FROM _release_src rs
    WHERE rs.shipment_batch_id = v_batch;

    IF v_parent_count IS DISTINCT FROM 1 OR v_parent IS NULL THEN
      RAISE EXCEPTION
        'Selected shipment batch % must resolve to exactly one commercial parent; found %',
        v_batch, COALESCE(v_parent_count, 0);
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('customer_sales_release|' || v_parent::text));$old$;
  v_new := $new$  FOR v_parent IN
    SELECT DISTINCT rs.commercial_parent_order_id
    FROM _release_src rs
    ORDER BY rs.commercial_parent_order_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('customer_sales_release|' || v_parent::text));$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Exact-batch creator loop anchor is missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    SELECT
      existing_invoice.id,
      existing_invoice.amount_gbp,
      existing_invoice.invoice_type::text
    INTO v_invoice, v_amount, v_type
    FROM public.customer_sales_release_lines active_membership
    JOIN public.sales_invoices existing_invoice
      ON existing_invoice.id = active_membership.sales_invoice_id
    WHERE active_membership.source_shipment_batch_id = v_batch
      AND active_membership.release_status = 'active'
      AND existing_invoice.order_id = v_parent
      AND existing_invoice.invoice_type IN ('main', 'supplementary')
      AND existing_invoice.sage_status = 'draft'
    ORDER BY existing_invoice.created_at DESC, existing_invoice.id
    LIMIT 1;$old$;
  v_new := $new$    SELECT
      si.id,
      si.amount_gbp,
      si.invoice_type::text
    INTO
      v_invoice,
      v_amount,
      v_type
    FROM public.sales_invoices si
    WHERE si.order_id = v_parent
      AND si.invoice_type IN ('main', 'supplementary')
      AND si.sage_status = 'draft'
    ORDER BY si.created_at DESC
    LIMIT 1;$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Exact-batch creator draft-lookup anchor is missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    IF v_invoice IS NOT NULL THEN$old$;
  v_new := $new$    SELECT
      (ARRAY_AGG(DISTINCT rs.shipment_batch_id ORDER BY rs.shipment_batch_id))[1],
      MIN(rs.order_ref),
      string_agg(DISTINCT rs.booking_ref, ', ' ORDER BY rs.booking_ref)
    INTO
      v_batch,
      v_ref,
      v_booking
    FROM _release_src rs
    WHERE rs.commercial_parent_order_id = v_parent;

    IF v_invoice IS NOT NULL THEN$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Creator existing-draft result anchor is missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_count := (
    length(v_definition)
      - length(replace(
          v_definition,
          'WHERE rs.shipment_batch_id = v_batch',
          ''
        ))
  ) / length('WHERE rs.shipment_batch_id = v_batch');

  IF v_count IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION
      'Exact-batch creator aggregation predicate count was %, expected 3.',
      v_count;
  END IF;

  v_definition := replace(
    v_definition,
    'WHERE rs.shipment_batch_id = v_batch',
    'WHERE rs.commercial_parent_order_id = v_parent'
  );

  IF md5(v_definition) IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3' THEN
    RAISE EXCEPTION
      'Creator reverse-substitution did not reproduce the governed baseline: %.',
      md5(v_definition);
  END IF;

  EXECUTE v_definition;
END
$restore_creator$;

DO $restore_queue_counts$
DECLARE
  v_definition text;
  v_old_draft text :=
    $old$COUNT(DISTINCT invoice.id) FILTER (
        WHERE invoice.sage_status = 'draft'
          AND EXISTS (
            SELECT 1
            FROM public.customer_sales_release_lines release_line
            WHERE release_line.sales_invoice_id = invoice.id
              AND release_line.source_shipment_batch_id
                  = preview.shipment_batch_id
              AND release_line.release_status = 'active'
          )
      )::integer AS draft_count$old$;
  v_old_posted text :=
    $old$COUNT(DISTINCT invoice.id) FILTER (
        WHERE invoice.sage_status = 'posted'
          AND EXISTS (
            SELECT 1
            FROM public.customer_sales_release_lines release_line
            WHERE release_line.sales_invoice_id = invoice.id
              AND release_line.source_shipment_batch_id
                  = preview.shipment_batch_id
              AND release_line.release_status = 'active'
          )
      )::integer AS posted_count$old$;
  v_new_draft text :=
    $new$COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'draft')::integer AS draft_count$new$;
  v_new_posted text :=
    $new$COUNT(DISTINCT invoice.id) FILTER (WHERE invoice.sage_status = 'posted')::integer AS posted_count$new$;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure
  ) INTO v_definition;

  IF (
    length(v_definition) - length(replace(v_definition, v_old_draft, ''))
  ) / length(v_old_draft) IS DISTINCT FROM 1
     OR (
       length(v_definition) - length(replace(v_definition, v_old_posted, ''))
     ) / length(v_old_posted) IS DISTINCT FROM 1
  THEN
    RAISE EXCEPTION 'Exact shipment-batch queue count expressions are not installed exactly once.';
  END IF;

  v_definition := replace(v_definition, v_old_draft, v_new_draft);
  v_definition := replace(v_definition, v_old_posted, v_new_posted);

  IF md5(v_definition) IS DISTINCT FROM '823d4488e24c335596d55351c3e752c3' THEN
    RAISE EXCEPTION
      'Queue reverse-substitution did not reproduce the governed mixed-package definition: %.',
      md5(v_definition);
  END IF;

  EXECUTE v_definition;
END
$restore_queue_counts$;

DROP INDEX public.idx_sales_invoices_active_release_draft_v2;
DROP INDEX public.uq_csrl_active_membership_fingerprint_v1;

CREATE UNIQUE INDEX uq_sales_invoices_active_release_draft_v1
ON public.sales_invoices (order_id)
WHERE invoice_type IN ('main', 'supplementary')
  AND sage_status = 'draft';

DO $postflight$
DECLARE
  v_keep_invoice uuid := 'a3c939e4-0abb-4047-b828-cdc137130fd4';
  v_test_invoice uuid := '1a2e9e5d-6a10-42b8-8d52-c9253959f07b';
  v_count integer;
BEGIN
  IF md5(pg_get_functiondef(
       'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
     )) IS DISTINCT FROM '4011a399f02cda16b5d962b8101f91e1'
     OR md5(pg_get_functiondef(
       'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
     )) IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3'
     OR md5(pg_get_functiondef(
       'public.internal_customer_invoice_release_queue_v1()'::regprocedure
     )) IS DISTINCT FROM '823d4488e24c335596d55351c3e752c3'
     OR md5(pg_get_functiondef(
       'public.customer_sales_release_guard_v1()'::regprocedure
     )) IS DISTINCT FROM '2ed42ccd21ce8f0c9059ef7cddd90825'
     OR md5(pg_get_functiondef(
       'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure
     )) IS DISTINCT FROM '6209f9e26e8f7b57622b0c81374e6ef0'
  THEN
    RAISE EXCEPTION 'A restored or protected function fingerprint is unexpected.';
  END IF;

  IF to_regclass('public.uq_sales_invoices_active_release_draft_v1') IS NULL
     OR to_regclass('public.idx_sales_invoices_active_release_draft_v2') IS NOT NULL
     OR to_regclass('public.uq_csrl_active_membership_fingerprint_v1') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Draft indexes were not restored to the pre-incident shape.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.invoice_type IN ('main', 'supplementary')
      AND invoice_row.sage_status = 'draft'
    GROUP BY invoice_row.order_id
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Multiple active drafts remain for a commercial parent.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.id = v_test_invoice
      AND invoice_row.sage_status = 'void'
      AND invoice_row.sage_invoice_id IS NULL
      AND invoice_row.sage_posted_at IS NULL
      AND invoice_row.sage_reference IS NULL
  ) THEN
    RAISE EXCEPTION 'J040826v1 incident invoice is not safely void and unposted.';
  END IF;

  SELECT COUNT(*)::integer
  INTO v_count
  FROM public.customer_sales_release_lines release_line
  WHERE release_line.sales_invoice_id = v_test_invoice
    AND release_line.release_status = 'reversed'
    AND release_line.reversed_at IS NOT NULL
    AND release_line.reversed_by_staff_id IS NOT NULL
    AND release_line.reversal_reason =
      'Incident restoration: later J040826v1 test draft withdrawn while restoring pre-incident parent-wide draft rules.';

  IF v_count IS DISTINCT FROM 2 OR EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = v_test_invoice
      AND release_line.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'J040826v1 incident memberships were not reversed exactly.';
  END IF;

  IF (
    SELECT md5(to_jsonb(invoice_row)::text)
    FROM public.sales_invoices invoice_row
    WHERE invoice_row.id = v_keep_invoice
  ) IS DISTINCT FROM (
    SELECT protected.row_hash
    FROM _incident_restore_protected protected
    WHERE protected.identity = 'keep_invoice'
  ) THEN
    RAISE EXCEPTION 'Protected J040826 £10 invoice changed.';
  END IF;

  IF (
    SELECT md5(to_jsonb(release_line)::text)
    FROM public.customer_sales_release_lines release_line
    WHERE release_line.sales_invoice_id = v_keep_invoice
      AND release_line.release_status = 'active'
  ) IS DISTINCT FROM (
    SELECT protected.row_hash
    FROM _incident_restore_protected protected
    WHERE protected.identity = 'keep_membership'
  ) THEN
    RAISE EXCEPTION 'Protected J040826 release membership changed.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
