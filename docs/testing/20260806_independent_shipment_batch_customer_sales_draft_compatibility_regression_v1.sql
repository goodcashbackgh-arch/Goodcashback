BEGIN;

SET LOCAL lock_timeout = '15s';
SET LOCAL statement_timeout = '0';

-- Governing authority:
-- INDEPENDENT_SHIPMENT_BATCH_CUSTOMER_SALES_DRAFT_COMPATIBILITY_CORRECTION_ADDENDUM_v1
--
-- Uses validated J040826/J040826v1 live facts, creates rollback-scoped test rows,
-- and finishes with ROLLBACK.

DO $preflight$
BEGIN
  IF to_regprocedure('public.internal_customer_invoice_release_create_drafts_v1(uuid[])') IS NULL
     OR to_regprocedure('public.internal_customer_sales_release_sources_v1(uuid)') IS NULL
     OR to_regprocedure('public.internal_customer_invoice_release_queue_v1()') IS NULL
     OR to_regclass('public.uq_sales_invoices_nonvoid_main_v1') IS NULL
     OR to_regclass('public.uq_csrl_active_membership_fingerprint_v1') IS NULL
     OR to_regclass('public.idx_sales_invoices_active_release_draft_v2') IS NULL
     OR to_regclass('public.uq_sales_invoices_active_release_draft_v1') IS NOT NULL
  THEN
    RAISE EXCEPTION 'Independent shipment-batch correction is not installed.';
  END IF;
END
$preflight$;

CREATE TEMP TABLE _ctx ON COMMIT DROP AS
WITH batches AS (
  SELECT
    (ARRAY_AGG(id ORDER BY id) FILTER (WHERE booking_ref = 'J040826'))[1] AS j_batch,
    (ARRAY_AGG(id ORDER BY id) FILTER (WHERE booking_ref = 'J040826v1'))[1] AS v1_batch,
    COUNT(*) FILTER (WHERE booking_ref = 'J040826') AS j_count,
    COUNT(*) FILTER (WHERE booking_ref = 'J040826v1') AS v1_count
  FROM public.shipper_shipment_batches
  WHERE booking_ref IN ('J040826', 'J040826v1')
), j_invoice AS (
  SELECT
    invoice.id AS invoice_id,
    invoice.order_id,
    invoice.amount_gbp,
    invoice.invoice_type::text AS invoice_type,
    invoice.linked_invoice_id,
    md5(invoice.line_items_json::text) AS payload_md5,
    COUNT(release_line.id)::integer AS active_line_count,
    (ARRAY_AGG(release_line.id ORDER BY release_line.id))[1] AS release_line_id,
    MIN(release_line.membership_fingerprint) AS membership_fingerprint,
    SUM(release_line.released_qty)::numeric AS released_qty,
    SUM(release_line.goods_amount_gbp)::numeric AS goods_amount_gbp,
    SUM(release_line.shipping_amount_gbp)::numeric AS shipping_amount_gbp
  FROM batches
  JOIN public.customer_sales_release_lines release_line
    ON release_line.source_shipment_batch_id = batches.j_batch
   AND release_line.release_status = 'active'
  JOIN public.sales_invoices invoice
    ON invoice.id = release_line.sales_invoice_id
   AND invoice.sage_status = 'draft'
   AND invoice.invoice_type IN ('main', 'supplementary')
  GROUP BY
    invoice.id,
    invoice.order_id,
    invoice.amount_gbp,
    invoice.invoice_type,
    invoice.linked_invoice_id,
    invoice.line_items_json
)
SELECT
  batches.j_batch,
  batches.v1_batch,
  batches.j_count,
  batches.v1_count,
  j_invoice.*
FROM batches
CROSS JOIN j_invoice;

DO $fixture_assert$
DECLARE
  c _ctx%ROWTYPE;
BEGIN
  SELECT * INTO c FROM _ctx;

  IF c.j_count <> 1 OR c.v1_count <> 1
     OR c.j_batch IS NULL OR c.v1_batch IS NULL
  THEN
    RAISE EXCEPTION 'Expected exactly one J040826 and one J040826v1 batch.';
  END IF;

  IF c.invoice_id IS NULL
     OR ABS(c.amount_gbp - 10.00) > 0.01
     OR c.invoice_type <> 'supplementary'
     OR c.active_line_count <> 1
     OR c.release_line_id IS NULL
     OR c.membership_fingerprint IS NULL
  THEN
    RAISE EXCEPTION 'Protected J040826 £10 draft or release membership differs from the validated state.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.source_shipment_batch_id = c.v1_batch
      AND l.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'J040826v1 unexpectedly already has active release membership.';
  END IF;

  IF EXISTS (
    SELECT membership_fingerprint
    FROM public.customer_sales_release_lines
    WHERE release_status = 'active'
    GROUP BY membership_fingerprint
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Active membership fingerprint collision exists before regression.';
  END IF;
END
$fixture_assert$;

CREATE TEMP TABLE _protected_defs ON COMMIT DROP AS
SELECT *
FROM (VALUES
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
    'public.customer_sales_release_financial_guard_v1()'::regprocedure)))
) AS protected(identity, definition_md5);

DO $staff_context$
DECLARE
  v_auth_user_id uuid;
BEGIN
  SELECT auth_user_id
  INTO v_auth_user_id
  FROM public.staff
  WHERE active = true
    AND auth_user_id IS NOT NULL
  ORDER BY id
  LIMIT 1;

  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'No active staff auth identity is available for rollback-only RPC acceptance.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_auth_user_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
END
$staff_context$;

CREATE TEMP TABLE _queue_before ON COMMIT DROP AS
SELECT q.*
FROM public.internal_customer_invoice_release_queue_v1() q
JOIN _ctx c
  ON q.shipment_batch_id IN (c.j_batch, c.v1_batch);

DO $queue_before_assert$
DECLARE
  c _ctx%ROWTYPE;
BEGIN
  SELECT * INTO c FROM _ctx;

  IF NOT EXISTS (
    SELECT 1
    FROM _queue_before
    WHERE shipment_batch_id = c.j_batch
      AND created_draft_count = 1
      AND readiness_status = 'draft_exists'
  ) THEN
    RAISE EXCEPTION 'J040826 queue row does not retain its exact draft classification.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM _queue_before
    WHERE shipment_batch_id = c.v1_batch
      AND created_draft_count = 0
  ) THEN
    RAISE EXCEPTION 'J040826v1 queue row does not retain zero exact draft count.';
  END IF;
END
$queue_before_assert$;

CREATE TEMP TABLE _v1_sources ON COMMIT DROP AS
SELECT *
FROM public.internal_customer_sales_release_sources_v1(
  (SELECT v1_batch FROM _ctx)
);

DO $v1_source_assert$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM _v1_sources
    WHERE blocker = 'customer_sales_release_draft_already_exists'
  ) THEN
    RAISE EXCEPTION 'Sibling J040826 draft still imposes the withdrawn parent-wide blocker.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM _v1_sources
    WHERE blocker IS NULL
  ) THEN
    RAISE EXCEPTION 'J040826v1 has no ready source after removing the sibling-only blocker.';
  END IF;
END
$v1_source_assert$;

CREATE TEMP TABLE _j_retry ON COMMIT DROP AS
SELECT *
FROM public.internal_customer_invoice_release_create_drafts_v1(
  ARRAY[(SELECT j_batch FROM _ctx)]::uuid[]
);

DROP TABLE IF EXISTS pg_temp._release_src;

DO $j_retry_assert$
DECLARE
  c _ctx%ROWTYPE;
BEGIN
  SELECT * INTO c FROM _ctx;

  IF (SELECT COUNT(*) FROM _j_retry) <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM _j_retry
       WHERE shipment_batch_id = c.j_batch
         AND result_status = 'skipped_draft_already_exists'
         AND sales_invoice_id = c.invoice_id
     )
  THEN
    RAISE EXCEPTION 'J040826 retry did not return its exact existing draft.';
  END IF;

  IF (SELECT COUNT(*)
      FROM public.customer_sales_release_lines
      WHERE sales_invoice_id = c.invoice_id
        AND release_status = 'active') <> c.active_line_count
  THEN
    RAISE EXCEPTION 'J040826 retry changed its active membership count.';
  END IF;
END
$j_retry_assert$;

CREATE TEMP TABLE _v1_create ON COMMIT DROP AS
SELECT *
FROM public.internal_customer_invoice_release_create_drafts_v1(
  ARRAY[(SELECT v1_batch FROM _ctx)]::uuid[]
);

DROP TABLE IF EXISTS pg_temp._release_src;

CREATE TEMP TABLE _v1_created_invoice ON COMMIT DROP AS
SELECT
  result.sales_invoice_id,
  result.shipment_batch_id,
  result.order_id,
  result.invoice_type,
  result.amount_gbp
FROM _v1_create result
WHERE result.result_status = 'draft_created';

DO $v1_create_assert$
DECLARE
  c _ctx%ROWTYPE;
  v_new_invoice uuid;
BEGIN
  SELECT * INTO c FROM _ctx;
  SELECT sales_invoice_id INTO v_new_invoice FROM _v1_created_invoice;

  IF (SELECT COUNT(*) FROM _v1_created_invoice) <> 1
     OR v_new_invoice IS NULL
     OR v_new_invoice = c.invoice_id
  THEN
    RAISE EXCEPTION 'J040826v1 did not create one independent draft.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices i
    WHERE i.id = v_new_invoice
      AND i.order_id = c.order_id
      AND i.invoice_type = 'supplementary'
      AND i.linked_invoice_id = c.linked_invoice_id
      AND i.sage_status = 'draft'
  ) THEN
    RAISE EXCEPTION 'J040826v1 draft did not retain parent/main supplementary routing.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id = v_new_invoice
      AND l.source_shipment_batch_id = c.v1_batch
      AND l.release_status = 'active'
  ) OR EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.sales_invoice_id = v_new_invoice
      AND l.source_shipment_batch_id IS DISTINCT FROM c.v1_batch
  ) THEN
    RAISE EXCEPTION 'J040826v1 draft membership is not isolated to its exact batch.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.sales_invoices i
    WHERE i.id = c.invoice_id
      AND ABS(i.amount_gbp - c.amount_gbp) <= 0.01
      AND md5(i.line_items_json::text) = c.payload_md5
  ) OR NOT EXISTS (
    SELECT 1
    FROM public.customer_sales_release_lines l
    WHERE l.id = c.release_line_id
      AND l.membership_fingerprint = c.membership_fingerprint
      AND l.release_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Creating J040826v1 changed the protected J040826 release.';
  END IF;
END
$v1_create_assert$;

CREATE TEMP TABLE _v1_retry ON COMMIT DROP AS
SELECT *
FROM public.internal_customer_invoice_release_create_drafts_v1(
  ARRAY[(SELECT v1_batch FROM _ctx)]::uuid[]
);

DROP TABLE IF EXISTS pg_temp._release_src;

DO $v1_retry_assert$
DECLARE
  v_new_invoice uuid;
BEGIN
  SELECT sales_invoice_id INTO v_new_invoice FROM _v1_created_invoice;

  IF (SELECT COUNT(*) FROM _v1_retry) <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM _v1_retry
       WHERE result_status = 'skipped_draft_already_exists'
         AND sales_invoice_id = v_new_invoice
     )
  THEN
    RAISE EXCEPTION 'J040826v1 retry did not return its own exact draft.';
  END IF;
END
$v1_retry_assert$;

CREATE TEMP TABLE _multi_select ON COMMIT DROP AS
SELECT *
FROM public.internal_customer_invoice_release_create_drafts_v1(
  ARRAY[
    (SELECT j_batch FROM _ctx),
    (SELECT v1_batch FROM _ctx)
  ]::uuid[]
);

DROP TABLE IF EXISTS pg_temp._release_src;

DO $multi_select_assert$
DECLARE
  c _ctx%ROWTYPE;
  v_new_invoice uuid;
BEGIN
  SELECT * INTO c FROM _ctx;
  SELECT sales_invoice_id INTO v_new_invoice FROM _v1_created_invoice;

  IF (SELECT COUNT(*) FROM _multi_select) <> 2
     OR NOT EXISTS (
       SELECT 1 FROM _multi_select
       WHERE shipment_batch_id = c.j_batch
         AND sales_invoice_id = c.invoice_id
         AND result_status = 'skipped_draft_already_exists'
     )
     OR NOT EXISTS (
       SELECT 1 FROM _multi_select
       WHERE shipment_batch_id = c.v1_batch
         AND sales_invoice_id = v_new_invoice
         AND result_status = 'skipped_draft_already_exists'
     )
     OR (SELECT COUNT(DISTINCT sales_invoice_id) FROM _multi_select) <> 2
  THEN
    RAISE EXCEPTION 'Multi-select recombined sibling batches or reused the wrong draft.';
  END IF;
END
$multi_select_assert$;

CREATE TEMP TABLE _queue_after ON COMMIT DROP AS
SELECT q.*
FROM public.internal_customer_invoice_release_queue_v1() q
JOIN _ctx c
  ON q.shipment_batch_id IN (c.j_batch, c.v1_batch);

DO $final_assert$
DECLARE
  c _ctx%ROWTYPE;
BEGIN
  SELECT * INTO c FROM _ctx;

  IF NOT EXISTS (
    SELECT 1 FROM _queue_after
    WHERE shipment_batch_id = c.j_batch
      AND created_draft_count = 1
  ) OR NOT EXISTS (
    SELECT 1 FROM _queue_after
    WHERE shipment_batch_id = c.v1_batch
      AND created_draft_count = 1
      AND readiness_status = 'draft_exists'
  ) THEN
    RAISE EXCEPTION 'Queue did not project exact membership after independent sibling creation.';
  END IF;

  IF EXISTS (
    SELECT membership_fingerprint
    FROM public.customer_sales_release_lines
    WHERE release_status = 'active'
    GROUP BY membership_fingerprint
    HAVING COUNT(*) > 1
  ) THEN
    RAISE EXCEPTION 'Regression created duplicate active membership fingerprints.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM _protected_defs p
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
$final_assert$;

SELECT jsonb_build_object(
  'regression', 'independent_shipment_batch_customer_sales_draft_compatibility_v1',
  'passed', true,
  'j040826', jsonb_build_object(
    'invoice_unchanged', true,
    'retry_reused_exact_draft', true
  ),
  'j040826v1', jsonb_build_object(
    'independent_draft_created', true,
    'retry_reused_exact_draft', true
  ),
  'multi_select_isolated', true,
  'active_membership_collisions', 0,
  'rolled_back', true
) AS result;

ROLLBACK;
