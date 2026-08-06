BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- docs/governing-pack/architecture/
-- INDEPENDENT_SHIPMENT_BATCH_CUSTOMER_SALES_DRAFT_COMPATIBILITY_CORRECTION_ADDENDUM_v1.md
--
-- DDL/function-definition correction only. No operational-row DML.

DO $preflight$
DECLARE
  v_definition text;
  v_index_key text;
  v_index_predicate text;
  v_index_unique boolean;
  v_index_key_count integer;
  v_duplicate_count integer;
BEGIN
  IF to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)') IS NULL
     OR to_regclass('public.sales_invoices') IS NULL
     OR to_regclass('public.customer_sales_release_lines') IS NULL
     OR to_regclass('public.orders') IS NULL
  THEN
    RAISE EXCEPTION 'Independent shipment-batch draft prerequisites are missing.';
  END IF;

  IF to_regclass('public.uq_sales_invoices_nonvoid_main_v1') IS NULL
     OR to_regclass('public.uq_sales_invoices_active_release_draft_v1') IS NULL
  THEN
    RAISE EXCEPTION 'Required customer-sales invoice indexes are missing.';
  END IF;

  SELECT
    index_row.indisunique,
    index_row.indnkeyatts,
    pg_get_indexdef(index_row.indexrelid, 1, true),
    lower(regexp_replace(pg_get_expr(index_row.indpred, index_row.indrelid), '\s+', '', 'g'))
  INTO
    v_index_unique,
    v_index_key_count,
    v_index_key,
    v_index_predicate
  FROM pg_index index_row
  WHERE index_row.indexrelid = 'public.uq_sales_invoices_nonvoid_main_v1'::regclass
    AND index_row.indrelid = 'public.sales_invoices'::regclass;

  IF v_index_unique IS DISTINCT FROM true
     OR v_index_key_count IS DISTINCT FROM 1
     OR v_index_key IS DISTINCT FROM 'order_id'
     OR v_index_predicate NOT LIKE '%invoice_type%'
     OR v_index_predicate NOT LIKE '%''main''%'
     OR v_index_predicate NOT LIKE '%sage_status%'
     OR v_index_predicate NOT LIKE '%''void''%'
     OR (v_index_predicate NOT LIKE '%<>%' AND v_index_predicate NOT LIKE '%!=%')
  THEN
    RAISE EXCEPTION
      'One-non-void-main index is not the governed starting shape. key=%, predicate=%',
      v_index_key,
      v_index_predicate;
  END IF;

  SELECT
    index_row.indisunique,
    index_row.indnkeyatts,
    pg_get_indexdef(index_row.indexrelid, 1, true),
    lower(regexp_replace(pg_get_expr(index_row.indpred, index_row.indrelid), '\s+', '', 'g'))
  INTO
    v_index_unique,
    v_index_key_count,
    v_index_key,
    v_index_predicate
  FROM pg_index index_row
  WHERE index_row.indexrelid = 'public.uq_sales_invoices_active_release_draft_v1'::regclass
    AND index_row.indrelid = 'public.sales_invoices'::regclass;

  IF v_index_unique IS DISTINCT FROM true
     OR v_index_key_count IS DISTINCT FROM 1
     OR v_index_key IS DISTINCT FROM 'order_id'
     OR v_index_predicate NOT LIKE '%invoice_type%'
     OR v_index_predicate NOT LIKE '%''main''%'
     OR v_index_predicate NOT LIKE '%''supplementary''%'
     OR v_index_predicate NOT LIKE '%sage_status%'
     OR v_index_predicate NOT LIKE '%''draft''%'
  THEN
    RAISE EXCEPTION
      'Parent-wide active-draft index is not the governed starting shape. key=%, predicate=%',
      v_index_key,
      v_index_predicate;
  END IF;

  IF md5(pg_get_functiondef(
       'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
     )) IS DISTINCT FROM '2e75a619e3cc3cc2fc364d3cb5a85cc3'
  THEN
    RAISE EXCEPTION 'Draft creator fingerprint mismatch.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  IF strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'released_shipping_exceeds_current_approved_allocation') = 0
     OR strpos(v_definition, 'shipping_only_main_not_permitted') = 0
  THEN
    RAISE EXCEPTION 'Resolver is missing protected exact-clean or delta logic.';
  END IF;

  SELECT COUNT(*) INTO v_duplicate_count
  FROM (
    SELECT membership_fingerprint
    FROM public.customer_sales_release_lines
    WHERE release_status = 'active'
    GROUP BY membership_fingerprint
    HAVING COUNT(*) > 1
  ) collisions;

  IF v_duplicate_count <> 0 THEN
    RAISE EXCEPTION 'Active membership fingerprint collisions exist: %', v_duplicate_count;
  END IF;
END
$preflight$;

CREATE TEMP TABLE _independent_batch_protected_fingerprints (
  identity text PRIMARY KEY,
  definition_md5 text NOT NULL
) ON COMMIT DROP;

INSERT INTO _independent_batch_protected_fingerprints(identity, definition_md5)
VALUES
  ('queue', md5(pg_get_functiondef(
    'public.internal_customer_invoice_release_queue_v1()'::regprocedure))),
  ('exact_clean', md5(pg_get_functiondef(
    'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure))),
  ('readiness', md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure))),
  ('remaining', md5(pg_get_functiondef(
    'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure))),
  ('release_guard', md5(pg_get_functiondef(
    'public.customer_sales_release_guard_v1()'::regprocedure))),
  ('financial_guard', md5(pg_get_functiondef(
    'public.customer_sales_release_financial_guard_v1()'::regprocedure)));

DO $replace_resolver$
DECLARE
  v_definition text;
  v_pattern text := $pattern$EXISTS[[:space:]]*\([[:space:]]*SELECT[[:space:]]+1[[:space:]]+FROM[[:space:]]+public\.sales_invoices[[:space:]]+existing_draft[[:space:]]+WHERE.*?existing_draft\.sage_status[[:space:]]*=[[:space:]]*'draft'[[:space:]]*\)[[:space:]]+AS[[:space:]]+has_active_draft$pattern$;
  v_replacement text := $replacement$EXISTS (
        SELECT 1
        FROM public.customer_sales_release_lines active_membership
        JOIN public.sales_invoices existing_draft
          ON existing_draft.id = active_membership.sales_invoice_id
        WHERE active_membership.source_shipment_batch_id = batch_row.id
          AND active_membership.release_status = 'active'
          AND existing_draft.order_id = CASE
            WHEN order_row.order_type = 'replacement_child' AND order_row.parent_order_id IS NOT NULL
              THEN order_row.parent_order_id
            ELSE order_row.id
          END
          AND existing_draft.invoice_type IN ('main', 'supplementary')
          AND existing_draft.sage_status = 'draft'
      ) AS has_active_draft$replacement$;
  v_match_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;

  SELECT COUNT(*)::integer
  INTO v_match_count
  FROM regexp_matches(v_definition, v_pattern, 'gis');

  IF v_match_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION
      'Parent-wide resolver draft expression match count was %, expected 1.',
      COALESCE(v_match_count, 0);
  END IF;

  v_definition := regexp_replace(
    v_definition,
    v_pattern,
    v_replacement,
    'gis'
  );

  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = batch_row.id') = 0
     OR strpos(v_definition, 'WHEN order_row.order_type = ''replacement_child''') = 0
     OR strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'AS has_active_draft') = 0
  THEN
    RAISE EXCEPTION 'Resolver exact-batch replacement failed closed.';
  END IF;

  EXECUTE v_definition;
END
$replace_resolver$;

DO $replace_creator$
DECLARE
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
  ) INTO v_definition;

  v_old := $old$  v_booking text;
BEGIN$old$;
  v_new := $new$  v_booking text;
  v_parent_count integer;
BEGIN$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Creator declaration anchor missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$  CREATE INDEX ON _release_src (commercial_parent_order_id, proposed_invoice_type);$old$;
  v_new := $new$  CREATE INDEX ON _release_src (
    shipment_batch_id,
    commercial_parent_order_id,
    proposed_invoice_type
  );$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Creator temporary index anchor missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$  FOR v_parent IN
    SELECT DISTINCT rs.commercial_parent_order_id
    FROM _release_src rs
    ORDER BY rs.commercial_parent_order_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('customer_sales_release|' || v_parent::text));$old$;
  v_new := $new$  FOR v_batch IN
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

    PERFORM pg_advisory_xact_lock(hashtext('customer_sales_release|' || v_parent::text));$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Creator parent-loop anchor missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    SELECT
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
    LIMIT 1;$old$;
  v_new := $new$    SELECT
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
    LIMIT 1;$new$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Creator parent-draft lookup anchor missing.';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := $old$    SELECT
      (ARRAY_AGG(DISTINCT rs.shipment_batch_id ORDER BY rs.shipment_batch_id))[1],
      MIN(rs.order_ref),
      string_agg(DISTINCT rs.booking_ref, ', ' ORDER BY rs.booking_ref)
    INTO
      v_batch,
      v_ref,
      v_booking
    FROM _release_src rs
    WHERE rs.commercial_parent_order_id = v_parent;

$old$;
  IF strpos(v_definition, v_old) = 0 THEN
    RAISE EXCEPTION 'Creator parent representative-batch anchor missing.';
  END IF;
  v_definition := replace(v_definition, v_old, '');

  IF (
    length(v_definition)
      - length(replace(
          v_definition,
          'WHERE rs.commercial_parent_order_id = v_parent',
          ''
        ))
  ) / length('WHERE rs.commercial_parent_order_id = v_parent') IS DISTINCT FROM 3
  THEN
    RAISE EXCEPTION 'Creator parent aggregation anchors were not found exactly three times.';
  END IF;

  v_definition := replace(
    v_definition,
    'WHERE rs.commercial_parent_order_id = v_parent',
    'WHERE rs.shipment_batch_id = v_batch'
  );

  IF strpos(v_definition, 'FOR v_batch IN') = 0
     OR strpos(v_definition, 'ORDER BY MIN(rs.commercial_parent_order_id::text), rs.shipment_batch_id') = 0
     OR strpos(v_definition, 'active_membership.source_shipment_batch_id = v_batch') = 0
     OR strpos(v_definition, 'WHERE rs.shipment_batch_id = v_batch') = 0
     OR strpos(v_definition, 'pg_advisory_xact_lock') = 0
  THEN
    RAISE EXCEPTION 'Creator exact-batch transformation failed closed.';
  END IF;

  EXECUTE v_definition;
END
$replace_creator$;

DROP INDEX public.uq_sales_invoices_active_release_draft_v1;

CREATE INDEX idx_sales_invoices_active_release_draft_v2
ON public.sales_invoices (order_id, created_at DESC, id)
WHERE invoice_type IN ('main', 'supplementary')
  AND sage_status = 'draft';

DO $collision_recheck$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines
    WHERE release_status = 'active'
    GROUP BY membership_fingerprint
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Active membership collision appeared before unique-index creation.';
  END IF;
END
$collision_recheck$;

CREATE UNIQUE INDEX uq_csrl_active_membership_fingerprint_v1
ON public.customer_sales_release_lines (membership_fingerprint)
WHERE release_status = 'active';

DO $postflight$
DECLARE
  v_definition text;
  v_index_predicate text;
  v_index_key text;
  v_index_unique boolean;
  v_index_key_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.internal_customer_sales_release_sources_v1(uuid)'::regprocedure
  ) INTO v_definition;
  IF strpos(v_definition, 'active_membership.source_shipment_batch_id = batch_row.id') = 0
     OR strpos(v_definition, 'WHEN order_row.order_type = ''replacement_child''') = 0
     OR strpos(v_definition, 'internal_customer_sales_release_exact_clean_proof_v1') = 0
     OR strpos(v_definition, 'released_shipping_exceeds_current_approved_allocation') = 0
     OR strpos(v_definition, 'shipping_only_main_not_permitted') = 0
  THEN
    RAISE EXCEPTION 'Resolver postflight failed or protected logic was lost.';
  END IF;

  SELECT pg_get_functiondef(
    'public.internal_customer_invoice_release_create_drafts_v1(uuid[])'::regprocedure
  ) INTO v_definition;
  IF strpos(v_definition, 'FOR v_batch IN') = 0
     OR strpos(v_definition, 'ORDER BY MIN(rs.commercial_parent_order_id::text), rs.shipment_batch_id') = 0
     OR strpos(v_definition, 'active_membership.source_shipment_batch_id = v_batch') = 0
     OR strpos(v_definition, 'WHERE rs.shipment_batch_id = v_batch') = 0
     OR strpos(v_definition, 'pg_advisory_xact_lock') = 0
  THEN
    RAISE EXCEPTION 'Creator exact-batch postflight failed.';
  END IF;

  IF to_regclass('public.uq_sales_invoices_active_release_draft_v1') IS NOT NULL
     OR to_regclass('public.idx_sales_invoices_active_release_draft_v2') IS NULL
     OR to_regclass('public.uq_csrl_active_membership_fingerprint_v1') IS NULL
     OR to_regclass('public.uq_sales_invoices_nonvoid_main_v1') IS NULL
  THEN
    RAISE EXCEPTION 'Index replacement postflight failed.';
  END IF;

  SELECT
    index_row.indisunique,
    index_row.indnkeyatts,
    pg_get_indexdef(index_row.indexrelid, 1, true),
    lower(regexp_replace(pg_get_expr(index_row.indpred, index_row.indrelid), '\s+', '', 'g'))
  INTO
    v_index_unique,
    v_index_key_count,
    v_index_key,
    v_index_predicate
  FROM pg_index index_row
  WHERE index_row.indexrelid = 'public.uq_sales_invoices_nonvoid_main_v1'::regclass
    AND index_row.indrelid = 'public.sales_invoices'::regclass;

  IF v_index_unique IS DISTINCT FROM true
     OR v_index_key_count IS DISTINCT FROM 1
     OR v_index_key IS DISTINCT FROM 'order_id'
     OR v_index_predicate NOT LIKE '%invoice_type%'
     OR v_index_predicate NOT LIKE '%''main''%'
     OR v_index_predicate NOT LIKE '%sage_status%'
     OR v_index_predicate NOT LIKE '%''void''%'
  THEN
    RAISE EXCEPTION 'One-non-void-main authority changed during migration.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _independent_batch_protected_fingerprints p
    WHERE CASE p.identity
      WHEN 'queue' THEN md5(pg_get_functiondef(
        'public.internal_customer_invoice_release_queue_v1()'::regprocedure))
      WHEN 'exact_clean' THEN md5(pg_get_functiondef(
        'public.internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)'::regprocedure))
      WHEN 'readiness' THEN md5(pg_get_functiondef(
        'public.internal_shipping_customer_invoice_readiness_preview_v1(uuid)'::regprocedure))
      WHEN 'remaining' THEN md5(pg_get_functiondef(
        'public.internal_shipping_customer_invoice_remaining_preview_v1(uuid)'::regprocedure))
      WHEN 'release_guard' THEN md5(pg_get_functiondef(
        'public.customer_sales_release_guard_v1()'::regprocedure))
      WHEN 'financial_guard' THEN md5(pg_get_functiondef(
        'public.customer_sales_release_financial_guard_v1()'::regprocedure))
      ELSE NULL
    END IS DISTINCT FROM p.definition_md5
  ) THEN
    RAISE EXCEPTION 'A protected queue, preview, exact-clean or guard definition changed.';
  END IF;
END
$postflight$;

NOTIFY pgrst, 'reload schema';

COMMIT;
