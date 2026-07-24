WITH params AS (
  SELECT
    '18bb852a-7983-4ea1-82e1-70fb668241d9'::uuid AS importer_id,
    '2bebe8a7-ff61-4efe-b450-e297e2388e42'::uuid AS new_overfunding_credit_id,
    'a2330936-f92e-4973-b7a3-f2ae4e4179d4'::uuid AS legacy_aggregate_order_id
), normal_lots AS (
  SELECT l.*
  FROM params p
  CROSS JOIN LATERAL public.internal_importer_available_account_credit_lots_v1(p.importer_id) l
), normal_summary AS (
  SELECT
    ROUND(COALESCE(SUM(n.available_amount_gbp), 0)::numeric, 2) AS normal_available_gbp,
    ROUND(COALESCE(SUM(n.available_amount_gbp) FILTER (
      WHERE n.credit_ledger_id = p.new_overfunding_credit_id
    ), 0)::numeric, 2) AS new_overfunding_available_gbp
  FROM params p
  LEFT JOIN normal_lots n ON true
  GROUP BY p.new_overfunding_credit_id
), loyalty_summary AS (
  SELECT ROUND(COALESCE(SUM(l.available_amount_gbp), 0)::numeric, 2) AS loyalty_available_gbp
  FROM params p
  LEFT JOIN LATERAL public.internal_importer_available_completion_loyalty_lots_v1(p.importer_id) l ON true
), legacy_readiness AS (
  SELECT
    r.supplier_payment_ready_yn,
    r.blocker,
    r.broken_credit_event_count
  FROM params p
  LEFT JOIN LATERAL public.internal_supplier_payment_readiness_v1(p.legacy_aggregate_order_id) r ON true
)
SELECT jsonb_build_object(
  'normal_available_gbp', ns.normal_available_gbp,
  'new_overfunding_available_gbp', ns.new_overfunding_available_gbp,
  'new_overfunding_visible_yn', ns.new_overfunding_available_gbp = 15.04,
  'loyalty_available_gbp', ls.loyalty_available_gbp,
  'legacy_order_supplier_payment_ready_yn', lr.supplier_payment_ready_yn,
  'legacy_order_blocker', lr.blocker,
  'legacy_order_broken_credit_event_count', lr.broken_credit_event_count,
  'legacy_order_still_fail_closed_yn', COALESCE(lr.supplier_payment_ready_yn, false) = false
) AS chronology_fence_regression
FROM normal_summary ns
CROSS JOIN loyalty_summary ls
CROSS JOIN legacy_readiness lr;
