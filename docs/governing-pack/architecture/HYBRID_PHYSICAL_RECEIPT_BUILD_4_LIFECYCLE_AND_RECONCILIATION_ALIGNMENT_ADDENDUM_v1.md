# Hybrid Physical Receipt Build 4 — Lifecycle and Reconciliation Alignment Addendum v1

Status: governing implementation alignment and non-regression authority

Effective repository baseline: `main` at `800eb34d9a89aeb6fe40139d42fde887464e0874`

Live-database preflight date: 1 August 2026

This document must be read with, and is subordinate to, `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md` and `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`.

It does not change the agreed architecture, commercial treatment, role permissions or release sequence. It records the final live-database facts required to implement Build 4 without guessing.

## 1. Frozen Build 4 scope

Build 4 is limited to lifecycle and reconciliation:

1. harden the replacement-child creation path so the application and database preserve approved physical-remedy provenance;
2. expand `order_has_open_child_exceptions` so an unfinished replacement child, unresolved physical remedy, or cancelled replacement not rerouted or explicitly closed blocks the parent;
3. replace `order_reconciliation_vw` using authoritative supplier-invoice identity while preserving its exact public columns;
4. add `order_reconciliation_anomalies_v1` so over-progression and non-authoritative progressed evidence are exposed rather than hidden;
5. verify `approve_vat_release`, `mark_order_accounting_release_ready` and `recompute_order_status` continue to consume the strengthened authorities;
6. preserve all existing physical-remedy guards, status-transition authorities, grants, labels and unrelated workflows.

No other UI, route, accounting, VAT, Sage, shipment, refund, customer-sales or supplier-payment behaviour is authorised by this build.

## 2. Confirmed live implementation facts

The final preflight confirms:

- order status changes are governed by the existing `status_transitions` table through trigger function `enforce_status_transition`;
- `enforce_order_locks` prevents changes to `order_total_gbp_declared` and `total_qty_declared` after `content_locked_at` is set;
- Build 4 must not repair reconciliation by rewriting parent declared quantity or amount;
- the legacy `ready_for_invoicing` trigger gate does not define the current Build 4 lifecycle and must not be repurposed;
- the current supervisor application action creates replacement children directly instead of calling `create_replacement_child_order`;
- that direct path does not populate the full governed physical-remedy provenance and therefore must be aligned to the hardened database authority;
- the installed physical-remedy guards already enforce immutable source identity, approved route and quantity, replacement supplier-cost mode, exact child linkage, exact child tracking linkage, terminal immutability and audited rerouting;
- those guards are preserved and must be used in their allowed sequence, not weakened or bypassed.

## 3. Live fingerprints and drift stop

Before replacing a reviewed object, the additive migration must stop if its live definition differs from the reviewed definition.

Reviewed live fingerprints:

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

The migration may replace only the first three objects. The remaining definitions are protected verification authorities and must remain byte-for-byte unchanged unless a later expressly approved addendum says otherwise.

## 4. Replacement-child lifecycle authority

A final-approved physical replacement must create its child through the hardened `create_replacement_child_order` authority.

For a dispute line linked to `physical_exception_remedy_allocations`, the function must verify and preserve:

- parent order;
- source dispute and source dispute line;
- physical receipt review;
- source receipt line disposition;
- source tracking line allocation;
- source supplier invoice line;
- approved remedy allocation;
- approved replacement quantity;
- explicit supplier cost mode;
- replacement child order.

The child must carry `replacement_source_dispute_line_id`. The physical remedy allocation must carry `replacement_child_order_id` and move only through an already permitted guarded transition.

Legacy replacement creation with no physical-remedy allocation remains compatible, but may not manufacture physical provenance.

Replacement of a replacement remains prohibited.

The application must not continue a parallel direct-insert authority after the hardened RPC is deployed.

## 5. Parent blocking authority

`order_has_open_child_exceptions` remains the single reusable parent blocker consumed by VAT release, accounting release and status recomputation.

It must return true for any applicable condition including:

- an existing open dispute-line conversation state;
- a physical remedy allocation that is not completed, rerouted or explicitly closed with no action;
- a cancelled physical replacement that has not been rerouted;
- a linked replacement child that is not completed or archived;
- a cancelled replacement child unless its source physical remedy has been rerouted or explicitly closed.

A dispute line being marked `resolved_replacement` at child creation must not release the parent while the child remains unfinished.

## 6. Reconciliation source authority

`order_reconciliation_vw` must retain exactly these public columns and order:

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

Supplier invoice lines count as progressed only when their invoice is authoritative:

- `review_status` is `approved_current` or `ref_corrected_approved`;
- `blocked_from_sage_yn = false`;
- the invoice is not superseded.

Rejected, duplicate-blocked, superseded and pending-review evidence must not progress the canonical order reconciliation merely because a line contains `eligible_for_invoice_yn = 'Y'`.

A resolved dispute line must not also be subtracted as non-invoiceable where its exact supplier invoice line is already included as progressed invoiceable. Post-progression remedy must not be represented as though the original supplier line never progressed.

The canonical view must never report `whole_order_cleared_yn = true` where quantity or amount exceeds the declared baseline.

## 7. Anomaly read model

`order_reconciliation_anomalies_v1` is additive and read-only.

It must identify at least:

- authoritative quantity over-progression;
- authoritative amount over-progression;
- eligible progressed lines attached to non-authoritative invoices;
- raw progressed evidence exceeding the order baseline even when canonical reconciliation correctly excludes it.

The known regression order `DAY3-TRACK-1d7cfa66` has declared quantity 1 and £100, but raw eligible evidence on a pending-review, non-current invoice totals quantity 3 and £155. Canonical reconciliation must not treat that evidence as authoritative, and the anomaly read model must expose it.

Anomalies must not be hidden only by clipping arithmetic to zero.

## 8. Protected non-regression authorities

Build 4 must not modify:

- physical-remedy proposal, sequence, quantity, approval, terminal-immutability or reroute guards;
- `status_transitions` rows;
- order declared quantity or amount;
- customer-review membership or deadlines;
- shipment membership or customer-sales release identity;
- VAT evidence rules;
- payout, shipper-liability, supplier-AP, shipping-AP, Sage or settlement controls;
- current grants, role boundaries, labels or navigation.

## 9. Acceptance

Build 4 is acceptable only when regression evidence proves:

1. a physical replacement child cannot be created without its approved exact remedy provenance;
2. the application uses the hardened replacement authority;
3. unfinished and improperly cancelled replacement paths block parent VAT/accounting/completion;
4. completed or correctly rerouted paths cease blocking at the correct boundary;
5. canonical reconciliation excludes non-authoritative evidence;
6. over-progression is visible through `order_reconciliation_anomalies_v1`;
7. the public reconciliation column contract is unchanged;
8. protected function fingerprints, grants and unrelated behaviour remain unchanged.
