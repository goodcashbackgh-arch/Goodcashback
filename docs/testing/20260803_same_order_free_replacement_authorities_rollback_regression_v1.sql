-- Rollback-only live regression. No writes survive.
-- Requires one real retailer-accepted, unconsumed physical replacement dispute and
-- one different active tracking submission on the same original order.

BEGIN;
SET LOCAL statement_timeout='0';
SET LOCAL lock_timeout='15s';

CREATE TEMP TABLE test_ctx ON COMMIT DROP AS
SELECT
  d.id dispute_id,
  d.order_id,
  dl.id dispute_line_id,
  r.id remedy_id,
  r.tracking_line_allocation_id source_allocation_id,
  src.tracking_submission_id source_tracking_submission_id,
  replacement_tracking.id replacement_tracking_submission_id,
  s.id staff_id,
  s.auth_user_id staff_auth_user_id,
  op.id operator_id,
  op.auth_user_id operator_auth_user_id
FROM public.disputes d
JOIN public.dispute_lines dl
  ON dl.dispute_id=d.id
 AND dl.resolved_at IS NULL
 AND dl.conversation_status='retailer_response_received'
JOIN public.physical_exception_remedy_allocations r
  ON r.id=dl.physical_remedy_allocation_id
 AND r.approved_remedy_type='replacement'
 AND r.status IN ('approved','linked_to_exception')
 AND r.replacement_child_order_id IS NULL
 AND r.replacement_child_tracking_allocation_id IS NULL
JOIN public.order_tracking_line_allocations src
  ON src.id=r.tracking_line_allocation_id
JOIN public.orders o ON o.id=d.order_id
JOIN public.staff s
  ON COALESCE(s.active,true)
 AND s.role_type IN ('admin','supervisor')
JOIN public.operator_importers oi
  ON oi.importer_id=o.importer_id
 AND oi.revoked_at IS NULL
JOIN public.operators op
  ON op.id=oi.operator_id
 AND COALESCE(op.active,true)
JOIN LATERAL (
  SELECT ots.id
  FROM public.order_tracking_submissions ots
  WHERE ots.order_id=d.order_id
    AND ots.superseded_at IS NULL
    AND ots.id IS DISTINCT FROM src.tracking_submission_id
  ORDER BY ots.submitted_at DESC NULLS LAST, ots.id
  LIMIT 1
) replacement_tracking ON true
WHERE d.desired_outcome='replacement'
  AND d.status IN ('raised','under_review')
  AND d.resolved_at IS NULL
  AND d.replacement_child_order_id IS NULL
  AND (SELECT COUNT(*) FROM public.dispute_lines x WHERE x.dispute_id=d.id AND x.resolved_at IS NULL)=1
  AND EXISTS (
    SELECT 1 FROM public.dispute_messages dm
    WHERE dm.dispute_id=d.id AND dm.message_type='retailer_reply' AND dm.counterparty='retailer'
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.physical_replacement_same_order_routes sr
    WHERE sr.physical_remedy_allocation_id=r.id OR sr.dispute_line_id=dl.id
  )
ORDER BY d.id
LIMIT 1;

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM test_ctx)<>1 THEN
    RAISE EXCEPTION 'No exact rollback-regression candidate found. Do not fabricate one; prepare a controlled retailer-accepted physical replacement fixture.';
  END IF;
END $$;

CREATE TEMP TABLE before_position ON COMMIT DROP AS
SELECT e.supplier_invoice_line_id,
       SUM(e.raw_qty_allocated) raw_qty,
       SUM(e.effective_qty_allocated) effective_qty,
       SUM(e.raw_adjusted_net_value_gbp) raw_value,
       SUM(e.effective_adjusted_net_value_gbp) effective_value
FROM test_ctx c
JOIN public.tracking_allocation_effective_entitlement_v1(c.order_id,NULL) e ON true
GROUP BY e.supplier_invoice_line_id;

CREATE TEMP TABLE before_protection ON COMMIT DROP AS
SELECT
  md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) remedy_guard,
  md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) sequence_guard,
  md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) review_guard,
  (SELECT COUNT(*) FROM public.orders WHERE order_type='replacement_child') legacy_child_count;

SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claim.sub',(SELECT staff_auth_user_id::text FROM test_ctx),true);

CREATE TEMP TABLE accepted_route ON COMMIT DROP AS
SELECT public.staff_accept_same_order_free_replacement_v1(
  c.dispute_id,c.staff_id,'free_replacement','rollback regression'
) route_id
FROM test_ctx c;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM test_ctx c
    JOIN public.disputes d ON d.id=c.dispute_id
    JOIN public.dispute_lines dl ON dl.id=c.dispute_line_id
    JOIN public.physical_exception_remedy_allocations r ON r.id=c.remedy_id
    WHERE d.replacement_child_order_id IS NOT NULL
       OR dl.resolved_via_child_order_id IS NOT NULL
       OR r.replacement_child_order_id IS NOT NULL
       OR r.replacement_child_tracking_allocation_id IS NOT NULL
       OR r.status<>'in_progress'
  ) THEN RAISE EXCEPTION 'Acceptance created child linkage or failed to set exact in-progress remedy state.'; END IF;
END $$;

SELECT set_config('request.jwt.claim.sub',(SELECT operator_auth_user_id::text FROM test_ctx),true);

CREATE TEMP TABLE allocation_result ON COMMIT DROP AS
SELECT public.operator_allocate_same_order_replacement_tracking_v1(
  c.order_id,c.replacement_tracking_submission_id,ARRAY[a.route_id],'rollback regression'
) result
FROM test_ctx c CROSS JOIN accepted_route a;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1
    FROM accepted_route ar
    JOIN public.physical_replacement_same_order_routes sr ON sr.id=ar.route_id
    JOIN test_ctx c ON true
    JOIN public.order_tracking_line_allocations successor ON successor.id=sr.successor_tracking_line_allocation_id
    WHERE sr.route_status<>'tracking_allocated'
       OR sr.successor_tracking_submission_id IS DISTINCT FROM c.replacement_tracking_submission_id
       OR successor.tracking_submission_id IS DISTINCT FROM c.replacement_tracking_submission_id
       OR successor.tracking_submission_id IS NOT DISTINCT FROM c.source_tracking_submission_id
       OR successor.order_id IS DISTINCT FROM c.order_id
       OR successor.supplier_invoice_line_id IS DISTINCT FROM sr.supplier_invoice_line_id
       OR successor.qty_allocated IS DISTINCT FROM sr.replacement_qty
       OR successor.adjusted_net_value_gbp IS DISTINCT FROM sr.transferred_adjusted_net_value_gbp
  ) THEN RAISE EXCEPTION 'Successor allocation identity/value mismatch.'; END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1
    FROM before_position b
    FULL JOIN (
      SELECT e.supplier_invoice_line_id,
             SUM(e.raw_qty_allocated) raw_qty,
             SUM(e.effective_qty_allocated) effective_qty,
             SUM(e.raw_adjusted_net_value_gbp) raw_value,
             SUM(e.effective_adjusted_net_value_gbp) effective_value
      FROM test_ctx c
      JOIN public.tracking_allocation_effective_entitlement_v1(c.order_id,NULL) e ON true
      GROUP BY e.supplier_invoice_line_id
    ) a USING (supplier_invoice_line_id)
    WHERE abs(COALESCE(a.effective_qty,0)-COALESCE(b.effective_qty,0))>0.0005
       OR abs(COALESCE(a.effective_value,0)-COALESCE(b.effective_value,0))>0.005
       OR COALESCE(a.raw_qty,0)<COALESCE(b.raw_qty,0)
       OR COALESCE(a.raw_value,0)<COALESCE(b.raw_value,0)
  ) THEN RAISE EXCEPTION 'Raw history/effective entitlement invariant failed.'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.tracking_allocation_effective_entitlement_v1((SELECT order_id FROM test_ctx),NULL) e
    WHERE e.effective_qty_allocated< -0.0005 OR e.effective_adjusted_net_value_gbp< -0.005
  ) THEN RAISE EXCEPTION 'Negative effective entitlement detected.'; END IF;
END $$;

DO $$
DECLARE b before_protection%ROWTYPE;
BEGIN
  SELECT * INTO b FROM before_protection;
  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure))<>b.remedy_guard
     OR md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure))<>b.sequence_guard
     OR md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))<>b.review_guard
     OR (SELECT COUNT(*) FROM public.orders WHERE order_type='replacement_child')<>b.legacy_child_count
  THEN RAISE EXCEPTION 'Protected Mini Build authority or legacy child population changed.'; END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','acceptance and successor allocation completed atomically; no child link was created; raw attempt history increased; effective quantity/value stayed unchanged; no negative entitlement; Mini Build fingerprints and legacy children stayed unchanged; all writes now roll back',
  'route_id',(SELECT route_id FROM accepted_route),
  'allocation_result',(SELECT result FROM allocation_result)
) AS regression_result;

ROLLBACK;
