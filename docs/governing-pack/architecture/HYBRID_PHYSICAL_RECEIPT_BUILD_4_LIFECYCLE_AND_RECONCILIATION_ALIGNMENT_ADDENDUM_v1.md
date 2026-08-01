# Hybrid Physical Receipt Build 4 — Lifecycle and Reconciliation Alignment Addendum v1

Status: governing implementation alignment and non-regression authority

Effective repository baseline: `main` at `800eb34d9a89aeb6fe40139d42fde887464e0874`

Live-database preflight date: 1 August 2026

This document is subordinate to:

- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`.

It does not change the agreed architecture, commercial treatment, role permissions or release sequence. It records the final implementation facts required to complete Build 4 without guessing.

## 1. Frozen Build 4 scope

Build 4 is limited to:

1. hardening replacement-child creation so the application and database preserve approved physical-remedy provenance;
2. making final replacement acceptance one atomic database transaction;
3. preserving the existing legacy multi-line manual replacement path without inventing physical provenance;
4. strengthening `order_has_open_child_exceptions` so unresolved remedies and unfinished or improperly cancelled replacement children block the parent;
5. replacing `order_reconciliation_vw` while preserving its exact public columns;
6. adding `order_reconciliation_anomalies_v1` to expose non-authoritative evidence and over-progression;
7. verifying VAT approval, accounting release and `recompute_order_status` continue to consume the strengthened authorities;
8. preserving all existing physical-remedy guards, transition authorities, grants, labels and unrelated workflows.

No other UI, route, VAT, Sage, shipment, refund, customer-sales, payout, supplier-AP or shipping-AP behaviour is authorised.

## 2. Confirmed live implementation constraints

- Order status changes must use existing active rows in `status_transitions`.
- `enforce_order_locks` prevents rewriting locked parent declared quantity or value.
- Build 4 must not repair reconciliation by changing parent order totals.
- The legacy `ready_for_invoicing` gate is not part of the current Build 4 lifecycle.
- Replacement of a replacement remains prohibited.
- Existing physical-remedy proposal, sequence, quantity, linkage and terminal-immutability guards must remain unchanged.
- The supervisor application must not retain a parallel direct child-order insertion path.

## 3. Reviewed live fingerprints

The first Build 4 migration must stop if any reviewed live authority has drifted.

```text
create_replacement_child_order(uuid,uuid,uuid,text)
fdf1c2e955a34b81fbfc75c6a34a21b4

order_has_open_child_exceptions(uuid)
8dbf93826e18a04b61d8fbc1d5b1922c

order_reconciliation_vw
89cc95922a2b8ec1fa040ba79f12907a

approve_vat_release(uuid,uuid,jsonb)
13491a2d250a480ebb1ac607ce7acce5

mark_order_accounting_release_ready(uuid,uuid)
dacaf00c6470a626cfc2d7e7aac2ccb8

recompute_order_status(uuid)
110d55541d4f729ff9331e23515fb563

physical_remedy_allocation_guard_v1()
32e1d3eb9161cdc3e09114edb8c0d3c0

physical_remedy_sequence_guard_v1()
3c5067f31d4f2112207e02d1f307e233

physical_remedy_terminal_immutability_guard_v1()
a7aa361f066b454a6f9c4f9b81734834

enforce_status_transition()
5fc40897ac22a4adae838ecc6a3e1cb9

enforce_order_locks()
497230d0cf04001f37c5e805cdd8da25
```

Only the first three reviewed objects may be replaced by the lifecycle/reconciliation migration. The remaining definitions are protected verification authorities.

## 4. Single supplier-invoice authority rule

Canonical reconciliation and anomaly classification must use the identical supplier-invoice authority predicate:

```sql
si.is_current_for_order = true
and si.review_status in ('approved_current', 'ref_corrected_approved')
and si.blocked_from_sage_yn = false
and si.superseded_by_supplier_invoice_id is null
```

A supplier invoice line counts as canonical progressed evidence only when all four conditions are true and `eligible_for_invoice_yn = 'Y'`.

Any eligible line that fails one or more of those conditions must be excluded from canonical progression and exposed by `order_reconciliation_anomalies_v1` as non-authoritative evidence.

Pending-review, rejected, duplicate-blocked, superseded, blocked or non-current invoices must never progress canonical reconciliation merely because their lines are eligible.

## 5. Reconciliation contract

`order_reconciliation_vw` must preserve exactly these public columns and order:

```text
order_id
qty_target
qty_progressed_invoiceable
qty_resolved_noninvoiceable
qty_unresolved
amount_target_gbp
amount_progressed_invoiceable_gbp
amount_resolved_noninvoiceable_gbp
amount_unresolved_gbp
invoiceable_subset_released_yn
whole_order_cleared_yn
last_refreshed_at
```

A resolved dispute line must not be subtracted again as non-invoiceable where its exact authoritative supplier invoice line has already progressed.

The view must not clip anomalies merely to produce zero unresolved values. It must never report `whole_order_cleared_yn = true` where quantity or amount exceeds the declared baseline.

## 6. Anomaly authority

`order_reconciliation_anomalies_v1` is additive and read-only. It must expose at least:

- authoritative quantity over-progression;
- authoritative amount over-progression;
- eligible lines attached to invoices that fail the exact four-part authority predicate;
- raw quantity or amount exceeding the order baseline.

The known regression order `DAY3-TRACK-1d7cfa66` has declared quantity 1 and £100 but raw eligible evidence of quantity 3 and £155 on a pending-review, non-current invoice. Canonical reconciliation must exclude that evidence and the anomaly view must expose it.

## 7. Physical replacement path

A physical replacement final acceptance must:

- contain exactly one active dispute line;
- have one linked approved physical remedy allocation;
- verify the parent order, dispute, dispute line, physical receipt review, receipt-line disposition, tracking-line allocation, supplier invoice line, approved replacement quantity and supplier-cost mode;
- create the child through the hardened `create_replacement_child_order` authority;
- populate the child `replacement_source_dispute_line_id` with the exact physical source dispute line;
- populate the remedy `replacement_child_order_id`;
- move the remedy only through an already permitted guarded transition;
- reject mixed physical and legacy lines;
- reject replacement of a replacement.

## 8. Legacy multi-line replacement path

A legacy replacement may aggregate multiple unresolved manual missing-item dispute lines into one replacement child.

For that path:

- every active line must be manual and retailer-accepted;
- quantity and value must be the aggregate of all source lines;
- the child `replacement_source_dispute_line_id` must be null because no single line represents the full child;
- every contributing dispute line must link to the child;
- the complete ordered set of contributing dispute-line IDs must be preserved in audit or escalation metadata;
- no physical remedy provenance may be manufactured.

## 9. Atomic acceptance authority

Final replacement acceptance must be one call to `staff_accept_replacement_outcome_v1`.

Within one PostgreSQL transaction it must:

1. validate authenticated active staff authority;
2. lock and validate the dispute and parent order;
3. validate retailer reply and accepted active lines;
4. transition `raised -> under_review` where required;
5. transition `under_review -> approved_replacement`;
6. create and link the correct physical or legacy replacement child;
7. resolve and link the applicable dispute lines;
8. transition `approved_replacement -> replaced`;
9. return the child order ID.

Any failure after status progression must roll back all dispute status changes, child creation, line resolution, remedy linkage and audit writes together.

The application must not perform separate status mutations around the RPC.

## 10. Parent blocking authority

`order_has_open_child_exceptions` must return true for:

- any existing open legacy dispute-line conversation state;
- any physical remedy not in `completed`, `rerouted` or `closed_no_action`;
- any replacement child not in `completed`, `archived` or properly rerouted cancellation;
- any cancelled replacement child whose source remedy has not been rerouted or explicitly closed.

Marking a dispute line `resolved_replacement` at child creation must not release the parent while the child remains unfinished.

## 11. Migration structure

Build 4 must finish with exactly two migrations:

1. `20260801210000_hybrid_physical_receipt_build_4_lifecycle_reconciliation_v1.sql`
   - drift stops;
   - hardened child authority;
   - strengthened parent blocker;
   - canonical reconciliation;
   - anomaly view.

2. `20260801213000_hybrid_physical_receipt_build_4_atomic_replacement_acceptance_fix_v1.sql`
   - atomic final acceptance;
   - physical one-line path;
   - legacy multi-line path;
   - exact and aggregate provenance handling;
   - grants.

No third corrective migration is permitted before deployment. Corrections must be folded into those two files because none has yet been applied.

## 12. Required behavioural regression evidence

Before merge, controlled transaction-scoped regressions must prove:

1. approved but non-current eligible evidence contributes zero to canonical progression and appears as `NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE`;
2. one-line physical replacement succeeds with exact child and remedy provenance;
3. multi-line physical replacement is rejected with zero surviving writes;
4. legacy multi-line manual replacement succeeds with aggregate child quantity/value, null single-source ID and complete source-line-set evidence;
5. a deliberate failure after status progression rolls back dispute status, child creation, line resolution and remedy linkage;
6. unfinished and improperly cancelled replacement children block the parent;
7. the public reconciliation column contract is unchanged;
8. protected fingerprints and grants remain unchanged.

## 13. Protected non-regression surface

Build 4 must not modify:

- physical-remedy guards;
- `status_transitions` rows;
- parent declared quantity or amount;
- customer-review membership or deadlines;
- shipment membership or customer-sales release identity;
- VAT evidence rules;
- payout, shipper-liability, supplier-AP, shipping-AP, Sage or settlement controls;
- labels, navigation or unrelated role permissions.
