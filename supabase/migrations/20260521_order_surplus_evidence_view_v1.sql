BEGIN;

DROP VIEW IF EXISTS public.order_surplus_evidence_position_v1;

CREATE VIEW public.order_surplus_evidence_position_v1 AS
WITH funding AS (
  SELECT
    order_id,
    round(coalesce(sum(CASE WHEN event_type IN ('funding_contribution','credit_applied','manual_adjustment') THEN amount_gbp WHEN event_type = 'funding_reversed' THEN -abs(amount_gbp) ELSE 0 END),0)::numeric,2) AS funding_total_gbp
  FROM public.order_funding_events
  GROUP BY order_id
), supplier_out AS (
  SELECT
    coalesce(si.order_id, a.order_id) AS order_id,
    round(coalesce(sum(a.allocated_gbp_amount) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type = 'supplier_invoice'),0)::numeric,2) AS supplier_out_gbp,
    count(*) FILTER (WHERE a.allocation_status = 'confirmed' AND a.allocation_type = 'supplier_invoice') AS supplier_out_count
  FROM public.dva_statement_line_allocations a
  LEFT JOIN public.supplier_invoices si ON si.id = a.supplier_invoice_id
  WHERE coalesce(si.order_id, a.order_id) IS NOT NULL
  GROUP BY coalesce(si.order_id, a.order_id)
), customer_invoice AS (
  SELECT
    order_id,
    round(coalesce(sum(amount_gbp) FILTER (WHERE invoice_type IN ('main','supplementary') AND sage_status = 'posted'),0)::numeric,2) AS posted_invoice_gbp,
    count(*) FILTER (WHERE invoice_type IN ('main','supplementary') AND sage_status = 'posted') AS posted_invoice_count,
    round(coalesce(sum(amount_gbp) FILTER (WHERE invoice_type IN ('main','supplementary') AND sage_status = 'draft'),0)::numeric,2) AS draft_invoice_gbp,
    count(*) FILTER (WHERE invoice_type IN ('main','supplementary') AND sage_status = 'draft') AS draft_invoice_count
  FROM public.sales_invoices
  GROUP BY order_id
), credit AS (
  SELECT
    source_entity_id AS order_id,
    round(coalesce(sum(CASE WHEN direction='credit' THEN abs(amount_gbp) ELSE -abs(amount_gbp) END),0)::numeric,2) AS credit_created_gbp
  FROM public.importer_credit_ledger
  WHERE source_type = 'settlement_credit'
    AND source_entity_type = 'order'
    AND source_entity_id IS NOT NULL
  GROUP BY source_entity_id
), blockers AS (
  SELECT
    o.id AS order_id,
    (SELECT count(*) FROM public.disputes d WHERE d.order_id=o.id AND d.resolved_at IS NULL AND coalesce(d.status,'') NOT IN ('closed','resolved','closed_no_action')) AS open_dispute_count,
    (SELECT count(*) FROM public.customer_pre_shipment_hold_requests h WHERE h.order_id=o.id AND h.status IN ('requested','supervisor_approved')) AS active_hold_count
  FROM public.orders o
)
SELECT
  o.id AS order_id,
  o.order_ref,
  o.importer_id,
  o.payment_auth_id,
  round(coalesce(o.order_total_gbp_declared,0)::numeric,2) AS declared_order_gbp,
  coalesce(f.funding_total_gbp,0)::numeric AS funding_total_gbp,
  coalesce(so.supplier_out_gbp,0)::numeric AS supplier_out_gbp,
  coalesce(so.supplier_out_count,0)::integer AS supplier_out_count,
  coalesce(ci.posted_invoice_gbp,0)::numeric AS posted_invoice_gbp,
  coalesce(ci.posted_invoice_count,0)::integer AS posted_invoice_count,
  coalesce(ci.draft_invoice_gbp,0)::numeric AS draft_invoice_gbp,
  coalesce(ci.draft_invoice_count,0)::integer AS draft_invoice_count,
  coalesce(c.credit_created_gbp,0)::numeric AS credit_created_gbp,
  coalesce(b.open_dispute_count,0)::integer AS open_dispute_count,
  coalesce(b.active_hold_count,0)::integer AS active_hold_count,
  CASE
    WHEN coalesce(ci.posted_invoice_count,0) > 0 THEN coalesce(ci.posted_invoice_gbp,0)
    WHEN coalesce(ci.draft_invoice_count,0) > 0 THEN coalesce(ci.draft_invoice_gbp,0)
    WHEN coalesce(so.supplier_out_count,0) > 0 THEN coalesce(so.supplier_out_gbp,0)
    ELSE 0::numeric
  END AS evidence_value_gbp,
  round((coalesce(f.funding_total_gbp,0) - CASE
    WHEN coalesce(ci.posted_invoice_count,0) > 0 THEN coalesce(ci.posted_invoice_gbp,0)
    WHEN coalesce(ci.draft_invoice_count,0) > 0 THEN coalesce(ci.draft_invoice_gbp,0)
    WHEN coalesce(so.supplier_out_count,0) > 0 THEN coalesce(so.supplier_out_gbp,0)
    ELSE 0::numeric
  END)::numeric,2) AS evidence_surplus_gbp,
  CASE
    WHEN coalesce(c.credit_created_gbp,0) > 0 THEN 'credit_created'
    WHEN coalesce(b.open_dispute_count,0) > 0 OR coalesce(b.active_hold_count,0) > 0 THEN 'blocked_by_open_issue'
    WHEN coalesce(f.funding_total_gbp,0) <= 0 THEN 'no_confirmed_funding'
    WHEN coalesce(ci.posted_invoice_count,0) > 0 AND round((coalesce(f.funding_total_gbp,0)-coalesce(ci.posted_invoice_gbp,0))::numeric,2) > 0 THEN 'ready_posted_invoice_surplus'
    WHEN coalesce(ci.draft_invoice_count,0) > 0 AND round((coalesce(f.funding_total_gbp,0)-coalesce(ci.draft_invoice_gbp,0))::numeric,2) > 0 THEN 'ready_draft_invoice_surplus'
    WHEN coalesce(so.supplier_out_count,0) > 0 AND round((coalesce(f.funding_total_gbp,0)-coalesce(so.supplier_out_gbp,0))::numeric,2) > 0 THEN 'ready_strong_in_out_surplus'
    WHEN coalesce(so.supplier_out_count,0) > 0 THEN 'in_out_no_surplus'
    ELSE 'pending_insufficient_evidence'
  END AS evidence_status,
  CASE
    WHEN coalesce(ci.posted_invoice_count,0) > 0 THEN 'posted_customer_invoice'
    WHEN coalesce(ci.draft_invoice_count,0) > 0 THEN 'draft_customer_invoice'
    WHEN coalesce(so.supplier_out_count,0) > 0 THEN 'matched_supplier_out'
    ELSE 'none'
  END AS evidence_basis
FROM public.orders o
LEFT JOIN funding f ON f.order_id=o.id
LEFT JOIN supplier_out so ON so.order_id=o.id
LEFT JOIN customer_invoice ci ON ci.order_id=o.id
LEFT JOIN credit c ON c.order_id=o.id
LEFT JOIN blockers b ON b.order_id=o.id;

GRANT SELECT ON public.order_surplus_evidence_position_v1 TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
