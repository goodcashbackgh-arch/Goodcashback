-- Synthetic rollback-only end-to-end regression.
-- Uses existing authorities to create the temporary physical-receipt/dispute journey.
-- No writes survive.

BEGIN;
SET LOCAL statement_timeout='0';
SET LOCAL lock_timeout='15s';

DO $preflight$
BEGIN
  IF to_regprocedure('public.shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)') IS NULL
     OR to_regprocedure('public.operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)') IS NULL
     OR to_regprocedure('public.staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)') IS NULL
     OR to_regprocedure('public.operator_update_dispute_retailer_update(uuid,text,text)') IS NULL
     OR to_regprocedure('public.staff_accept_same_order_free_replacement_v1(uuid,uuid,text,text)') IS NULL
     OR to_regprocedure('public.operator_allocate_same_order_replacement_tracking_v1(uuid,uuid,uuid[],text)') IS NULL
  THEN
    RAISE EXCEPTION 'Required existing or same-order authorities are missing.';
  END IF;
END
$preflight$;

-- Select one safe immutable parent context. The test creates all journey rows anew.
CREATE TEMP TABLE fixture_parent ON COMMIT DROP AS
SELECT
  o.id AS order_id,
  o.importer_id,
  o.shipper_id,
  o.sop_version,
  op.id AS operator_id,
  op.auth_user_id AS operator_auth_user_id,
  s.id AS staff_id,
  s.auth_user_id AS staff_auth_user_id,
  su.id AS shipper_user_id,
  su.auth_user_id AS shipper_auth_user_id,
  src.supplier_invoice_line_id,
  src.id AS template_allocation_id,
  src.qty_allocated AS template_qty,
  src.base_value_gbp AS template_base,
  src.discount_share_gbp AS template_discount,
  src.retailer_delivery_share_gbp AS template_delivery,
  src.adjusted_net_value_gbp AS template_adjusted,
  ots.courier_id
FROM public.orders o
JOIN public.operator_importers oi
  ON oi.importer_id=o.importer_id
 AND oi.revoked_at IS NULL
JOIN public.operators op
  ON op.id=oi.operator_id
 AND COALESCE(op.active,true)
JOIN public.staff s
  ON COALESCE(s.active,true)
 AND s.role_type IN ('admin','supervisor')
JOIN public.shipper_users su
  ON su.shipper_id=o.shipper_id
 AND su.active=true
JOIN public.order_tracking_line_allocations src
  ON src.order_id=o.id
 AND src.qty_allocated>=1
 AND src.adjusted_net_value_gbp>0
JOIN public.order_tracking_submissions ots
  ON ots.id=src.tracking_submission_id
WHERE o.shipper_id IS NOT NULL
  AND src.tracking_submission_id IS NOT NULL
  AND ots.courier_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.dispute_lines dl
    WHERE dl.supplier_invoice_line_id=src.supplier_invoice_line_id
      AND dl.resolved_at IS NULL
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.physical_exception_remedy_allocations r
    WHERE r.tracking_line_allocation_id=src.id
      AND r.status NOT IN ('cancelled','closed_no_action','rerouted')
  )
ORDER BY o.id, src.id, op.id, s.id, su.id
LIMIT 1;

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM fixture_parent)<>1 THEN
    RAISE EXCEPTION 'No safe immutable parent context found for the synthetic rollback fixture.';
  END IF;
END $$;

CREATE TEMP TABLE protection_before ON COMMIT DROP AS
SELECT
  md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure)) remedy_guard,
  md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure)) sequence_guard,
  md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure)) review_guard,
  (SELECT COUNT(*) FROM public.orders WHERE order_type='replacement_child') legacy_child_count;

-- Create failed-source and successor tracking refs on the same original order.
CREATE TEMP TABLE fixture_tracking ON COMMIT DROP AS
WITH source_tracking AS (
  INSERT INTO public.order_tracking_submissions (
    order_id,courier_id,tracking_ref,tracking_date,note,submitted_by_operator_id,is_final_delivery_yn
  )
  SELECT order_id,courier_id,
         'ROLLBACK-SOURCE-'||substr(gen_random_uuid()::text,1,8),
         current_date,'Synthetic rollback source tracking',operator_id,false
  FROM fixture_parent
  RETURNING id,order_id
), successor_tracking AS (
  INSERT INTO public.order_tracking_submissions (
    order_id,courier_id,tracking_ref,tracking_date,note,submitted_by_operator_id,is_final_delivery_yn
  )
  SELECT order_id,courier_id,
         'ROLLBACK-SUCCESSOR-'||substr(gen_random_uuid()::text,1,8),
         current_date,'Synthetic rollback successor tracking',operator_id,false
  FROM fixture_parent
  RETURNING id,order_id
)
SELECT s.id AS source_tracking_submission_id,
       x.id AS successor_tracking_submission_id
FROM source_tracking s
JOIN successor_tracking x ON x.order_id=s.order_id;

-- One exact quantity/value source allocation. Values are proportional to one unit.
CREATE TEMP TABLE fixture_source_allocation ON COMMIT DROP AS
INSERT INTO public.order_tracking_line_allocations (
  order_id,supplier_invoice_line_id,tracking_submission_id,qty_allocated,
  base_value_gbp,discount_share_gbp,retailer_delivery_share_gbp,adjusted_net_value_gbp,
  allocation_status,allocation_basis,notes,allocated_by_operator_id
)
SELECT
  p.order_id,p.supplier_invoice_line_id,t.source_tracking_submission_id,1,
  round(p.template_base/p.template_qty,2),
  round(p.template_discount/p.template_qty,2),
  round(p.template_delivery/p.template_qty,2),
  round(p.template_adjusted/p.template_qty,2),
  'allocated','operator_declaration','Synthetic rollback source allocation',p.operator_id
FROM fixture_parent p CROSS JOIN fixture_tracking t
RETURNING id,order_id,supplier_invoice_line_id,tracking_submission_id,qty_allocated,
          base_value_gbp,discount_share_gbp,retailer_delivery_share_gbp,adjusted_net_value_gbp;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM fixture_source_allocation WHERE adjusted_net_value_gbp<=0) THEN
    RAISE EXCEPTION 'Selected parent cannot produce a positive one-unit synthetic allocation.';
  END IF;
END $$;

-- Baseline is after fixture creation; successor allocation must preserve this effective position.
CREATE TEMP TABLE effective_before ON COMMIT DROP AS
SELECT e.supplier_invoice_line_id,
       SUM(e.raw_qty_allocated) AS raw_qty,
       SUM(e.effective_qty_allocated) AS effective_qty,
       SUM(e.raw_adjusted_net_value_gbp) AS raw_value,
       SUM(e.effective_adjusted_net_value_gbp) AS effective_value
FROM fixture_parent p
JOIN public.tracking_allocation_effective_entitlement_v1(p.order_id,NULL) e ON true
GROUP BY e.supplier_invoice_line_id;

-- Shipper records a complete damaged receipt through the existing v2 authority.
SELECT set_config('request.jwt.claim.role','authenticated',true);
SELECT set_config('request.jwt.claim.sub',(SELECT shipper_auth_user_id::text FROM fixture_parent),true);

CREATE TEMP TABLE receipt_result ON COMMIT DROP AS
SELECT public.shipper_record_package_receipt_v2(
  t.source_tracking_submission_id,
  gen_random_uuid(),
  jsonb_build_array(jsonb_build_object(
    'tracking_line_allocation_id',a.id,
    'supplier_invoice_line_id',a.supplier_invoice_line_id,
    'disposition_type','damaged',
    'quantity',1,
    'condition_note','Synthetic rollback damaged receipt'
  )),
  jsonb_build_array(jsonb_build_object(
    'storage_object_path','shipper-receipts/'||p.shipper_id::text||'/'||t.source_tracking_submission_id::text||'/synthetic-'||gen_random_uuid()::text||'.jpg',
    'original_filename','synthetic.jpg',
    'content_type','image/jpeg',
    'display_order',0,
    'tracking_line_allocation_id',a.id,
    'disposition_type','damaged'
  )),
  NULL,NULL
) AS result
FROM fixture_parent p
CROSS JOIN fixture_tracking t
CROSS JOIN fixture_source_allocation a;

CREATE TEMP TABLE fixture_review ON COMMIT DROP AS
SELECT pr.id AS review_id,d.id AS disposition_id
FROM fixture_tracking t
JOIN public.physical_receipt_reviews pr
  ON pr.tracking_submission_id=t.source_tracking_submission_id
JOIN public.shipper_package_receipt_line_dispositions d
  ON d.receipt_id=pr.receipt_id
JOIN fixture_source_allocation a
  ON a.id=d.tracking_line_allocation_id
ORDER BY pr.id,d.id
LIMIT 1;

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM fixture_review)<>1 THEN
    RAISE EXCEPTION 'Existing shipper v2 authority did not create exactly one synthetic review/disposition.';
  END IF;
END $$;

-- Importer proposes replacement using the existing gateway.
SELECT set_config('request.jwt.claim.sub',(SELECT operator_auth_user_id::text FROM fixture_parent),true);
SELECT public.operator_submit_physical_receipt_proposal_v2(
  r.review_id,
  jsonb_build_array(jsonb_build_object(
    'receipt_line_disposition_id',r.disposition_id,
    'proposed_remedy_type','replacement',
    'proposed_remedy_qty',1
  )),
  'Synthetic rollback replacement proposal'
)
FROM fixture_review r;

CREATE TEMP TABLE fixture_remedy ON COMMIT DROP AS
SELECT ra.id AS remedy_id
FROM fixture_review r
JOIN public.physical_exception_remedy_allocations ra
  ON ra.physical_receipt_review_id=r.review_id
 AND ra.receipt_line_disposition_id=r.disposition_id
WHERE ra.proposed_remedy_type='replacement'
ORDER BY ra.id
LIMIT 1;

-- Supervisor approves free replacement through the existing bridge authority.
SELECT set_config('request.jwt.claim.sub',(SELECT staff_auth_user_id::text FROM fixture_parent),true);
SELECT public.staff_decide_physical_receipt_review_v2(
  r.review_id,
  'approve_existing_exception',
  jsonb_build_array(jsonb_build_object(
    'remedy_allocation_id',m.remedy_id,
    'approved_remedy_type','replacement',
    'approved_remedy_qty',1,
    'supplier_cost_mode','free_replacement'
  )),
  'retailer',
  'Synthetic rollback supervisor approval'
)
FROM fixture_review r CROSS JOIN fixture_remedy m;

CREATE TEMP TABLE fixture_dispute ON COMMIT DROP AS
SELECT d.id AS dispute_id,dl.id AS dispute_line_id
FROM fixture_remedy m
JOIN public.physical_exception_remedy_allocations ra ON ra.id=m.remedy_id
JOIN public.dispute_lines dl ON dl.id=ra.dispute_line_id
JOIN public.disputes d ON d.id=dl.dispute_id
WHERE d.desired_outcome='replacement'
ORDER BY d.id
LIMIT 1;

DO $$ BEGIN
  IF (SELECT COUNT(*) FROM fixture_dispute)<>1 THEN
    RAISE EXCEPTION 'Existing supervisor bridge did not create exactly one replacement dispute.';
  END IF;
END $$;

-- Operator records retailer acceptance through the existing conversation authority.
SELECT set_config('request.jwt.claim.sub',(SELECT operator_auth_user_id::text FROM fixture_parent),true);
SELECT public.operator_update_dispute_retailer_update(
  d.dispute_id,
  'Retailer confirms one free replacement for synthetic rollback regression.',
  'retailer_accepted'
)
FROM fixture_dispute d;

-- New same-order acceptance.
SELECT set_config('request.jwt.claim.sub',(SELECT staff_auth_user_id::text FROM fixture_parent),true);
CREATE TEMP TABLE accepted_route ON COMMIT DROP AS
SELECT public.staff_accept_same_order_free_replacement_v1(
  d.dispute_id,p.staff_id,'free_replacement','Synthetic rollback acceptance'
) AS route_id
FROM fixture_dispute d CROSS JOIN fixture_parent p;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1
    FROM fixture_dispute f
    JOIN public.disputes d ON d.id=f.dispute_id
    JOIN public.dispute_lines dl ON dl.id=f.dispute_line_id
    JOIN fixture_remedy m ON true
    JOIN public.physical_exception_remedy_allocations r ON r.id=m.remedy_id
    WHERE d.replacement_child_order_id IS NOT NULL
       OR dl.resolved_via_child_order_id IS NOT NULL
       OR r.replacement_child_order_id IS NOT NULL
       OR r.replacement_child_tracking_allocation_id IS NOT NULL
       OR r.status<>'in_progress'
  ) THEN
    RAISE EXCEPTION 'Same-order acceptance created child linkage or wrong remedy state.';
  END IF;
END $$;

-- New multi-route-capable allocation authority, exercised with one route here.
SELECT set_config('request.jwt.claim.sub',(SELECT operator_auth_user_id::text FROM fixture_parent),true);
CREATE TEMP TABLE allocation_result ON COMMIT DROP AS
SELECT public.operator_allocate_same_order_replacement_tracking_v1(
  p.order_id,t.successor_tracking_submission_id,ARRAY[a.route_id],'Synthetic rollback successor allocation'
) AS result
FROM fixture_parent p CROSS JOIN fixture_tracking t CROSS JOIN accepted_route a;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1
    FROM accepted_route a
    JOIN public.physical_replacement_same_order_routes r ON r.id=a.route_id
    JOIN fixture_tracking t ON true
    JOIN fixture_parent p ON true
    JOIN public.order_tracking_line_allocations s ON s.id=r.successor_tracking_line_allocation_id
    WHERE r.route_status<>'tracking_allocated'
       OR r.successor_tracking_submission_id IS DISTINCT FROM t.successor_tracking_submission_id
       OR s.tracking_submission_id IS DISTINCT FROM t.successor_tracking_submission_id
       OR s.tracking_submission_id IS NOT DISTINCT FROM t.source_tracking_submission_id
       OR s.order_id IS DISTINCT FROM p.order_id
       OR s.supplier_invoice_line_id IS DISTINCT FROM r.supplier_invoice_line_id
       OR s.qty_allocated IS DISTINCT FROM r.replacement_qty
       OR s.adjusted_net_value_gbp IS DISTINCT FROM r.transferred_adjusted_net_value_gbp
  ) THEN
    RAISE EXCEPTION 'Successor route/allocation identity or value mismatch.';
  END IF;
END $$;

DO $$ BEGIN
  IF EXISTS (
    SELECT 1
    FROM effective_before b
    FULL JOIN (
      SELECT e.supplier_invoice_line_id,
             SUM(e.raw_qty_allocated) AS raw_qty,
             SUM(e.effective_qty_allocated) AS effective_qty,
             SUM(e.raw_adjusted_net_value_gbp) AS raw_value,
             SUM(e.effective_adjusted_net_value_gbp) AS effective_value
      FROM fixture_parent p
      JOIN public.tracking_allocation_effective_entitlement_v1(p.order_id,NULL) e ON true
      GROUP BY e.supplier_invoice_line_id
    ) a USING (supplier_invoice_line_id)
    WHERE abs(COALESCE(a.effective_qty,0)-COALESCE(b.effective_qty,0))>0.0005
       OR abs(COALESCE(a.effective_value,0)-COALESCE(b.effective_value,0))>0.005
       OR COALESCE(a.raw_qty,0)<=COALESCE(b.raw_qty,0)
       OR COALESCE(a.raw_value,0)<=COALESCE(b.raw_value,0)
  ) THEN
    RAISE EXCEPTION 'Raw history did not increase or effective entitlement changed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM fixture_parent p
    JOIN public.tracking_allocation_effective_entitlement_v1(p.order_id,NULL) e ON true
    WHERE e.effective_qty_allocated< -0.0005
       OR e.effective_adjusted_net_value_gbp< -0.005
  ) THEN
    RAISE EXCEPTION 'Negative effective entitlement detected.';
  END IF;
END $$;

DO $$
DECLARE b protection_before%ROWTYPE;
BEGIN
  SELECT * INTO b FROM protection_before;
  IF md5(pg_get_functiondef('public.physical_remedy_allocation_guard_v2()'::regprocedure))<>b.remedy_guard
     OR md5(pg_get_functiondef('public.physical_remedy_sequence_guard_v1()'::regprocedure))<>b.sequence_guard
     OR md5(pg_get_functiondef('public.physical_receipt_review_guard_v1()'::regprocedure))<>b.review_guard
     OR (SELECT COUNT(*) FROM public.orders WHERE order_type='replacement_child')<>b.legacy_child_count
  THEN
    RAISE EXCEPTION 'Protected Mini Build authority or legacy child population changed.';
  END IF;
END $$;

SELECT jsonb_build_object(
  'regression_result','PASS',
  'proof','synthetic journey used existing shipper/importer/supervisor/retailer authorities; same-order acceptance and successor allocation passed; no child order/link; raw history increased while effective quantity/value stayed unchanged; no negative entitlement; Mini Build fingerprints and legacy child population unchanged; all writes now roll back',
  'order_id',(SELECT order_id FROM fixture_parent),
  'dispute_id',(SELECT dispute_id FROM fixture_dispute),
  'route_id',(SELECT route_id FROM accepted_route),
  'allocation_result',(SELECT result FROM allocation_result)
) AS regression_result;

ROLLBACK;
