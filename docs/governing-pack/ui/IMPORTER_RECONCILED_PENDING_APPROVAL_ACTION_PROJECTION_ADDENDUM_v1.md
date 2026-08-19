# Importer Reconciled Pending-Approval Action Projection Addendum v1

Status: governing corrective addendum

## Purpose

Correct one importer-facing projection defect only.

A supplier invoice may legitimately remain `pending_review` and `blocked_from_sage_yn = true` after importer reconciliation because accounting coding and supervisor approval are later controls. That internal pending-approval state must not, by itself, force the importer card to show `Resolve evidence issue` after the importer has completed all evidence/reconciliation work.

## Proven production case

For `ORD-1785414534454`, the database proved simultaneously:

- `supplier_state = review_needed`;
- `reconciliation_state = complete`;
- 9 live invoice lines;
- 4 progressed physical lines;
- 0 unresolved lines;
- 0 progressed lines missing confirmed quantity/value;
- 0 open supplier-invoice review flags;
- 0 open order evidence queries;
- 2 active tracking submissions;
- all 4 physical lines fully allocated to active tracking;
- 0 unassigned physical lines;
- importer status label `Tracking submitted`;
- importer next action incorrectly `Resolve evidence issue`.

The supplier invoices are intentionally still pending internal coding/supervisor approval. This addendum does not alter that state.

## Governing rule

`review_needed` is an internal supplier-approval state. It is not automatically an importer evidence defect.

The importer next-action projection must preserve existing behaviour whenever genuine importer-owned work remains, including:

- open order evidence query;
- genuine supplier-evidence resubmission requirement;
- unresolved invoice line;
- progressed physical line missing confirmed quantity or amount;
- open or under-review supplier-invoice review flag;
- open exception/hold;
- positive canonical balance that already governs importer action.

When none of those importer blockers exists and reconciliation is complete, pending internal coding/approval must not cause `Resolve evidence issue`.

## Importer next-action rule

For an importer-reconciled order with no genuine importer evidence blocker:

- no active tracking submission -> preserve the existing tracking-add action;
- active tracking exists and at least one progressed physical line is not fully allocated to active tracking -> `Assign tracking`;
- active tracking exists and all progressed physical lines are fully allocated -> `No importer action required`;
- accepted POD -> preserve `Order complete`.

This rule is presentation only. It does not approve an invoice and does not alter any operational fact.

## Explicit non-scope

This addendum must not change:

- `supplier_invoices.review_status`;
- `blocked_from_sage_yn`;
- `is_current_for_order`;
- accounting coding;
- supervisor invoice-review or approval flow;
- `staff_approve_supplier_invoice_current(...)`;
- `staff_finalize_order_supplier_invoices_v1(...)`;
- Sage/AP readiness or posting;
- funding status or balance logic;
- tracking submissions or tracking allocations;
- importer card button visibility;
- internal/supervisor status projection;
- customer projection;
- shipper projection.

## Important compatibility rule

`is_current_for_order` must not be used as the importer reconciliation-complete gate. Header review may legitimately set it false while the invoice is awaiting later supervisor approval, even though importer reconciliation is complete.

Likewise, `approved_current` must not be required before the importer can be recognised as having completed evidence reconciliation.

## Implementation boundary

Patch only `public.order_audience_status_v1(uuid)` importer next-action projection.

The existing importer status label, internal status fields, customer fields, shipper fields, balances, funding facts and database business rows must pass through unchanged.

The migration must fail closed if the live audience function contract or proven 30 July function shape has drifted.

## Regression requirements

The regression must prove:

1. Reconciled + pending internal approval + no open flags/queries + fully assigned tracking -> `No importer action required`.
2. Reconciled + pending internal approval + active tracking with unassigned physical quantity -> `Assign tracking`.
3. Open evidence query preserves the pre-existing importer action.
4. Open/under-review invoice flag preserves the pre-existing importer action.
5. Unresolved line preserves the pre-existing importer action.
6. Missing confirmed quantity/value on a progressed physical line preserves the pre-existing importer action.
7. Genuine resubmission requirement preserves the pre-existing importer action.
8. Exception/hold preserves the pre-existing importer action.
9. Customer, shipper, internal/supervisor, funding and balance outputs are unchanged by the patch.
10. No business-data writes occur.

## Acceptance invariant

```text
Pending internal coding/approval must never masquerade as unresolved importer evidence when importer reconciliation is already complete.
```
