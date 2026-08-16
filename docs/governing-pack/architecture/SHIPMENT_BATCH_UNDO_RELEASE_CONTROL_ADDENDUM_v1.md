# Shipment Batch Undo & Release Control Addendum v1

## Purpose

This addendum governs the shipper-facing undo of a created Shipment Batch.

Its purpose is limited to reversing the current shipment-membership state of a Shipment Batch that has not crossed an active or irreversible downstream boundary, while preserving all historical and audit evidence.

This addendum does not authorise deletion of Shipment Batches, package memberships, exact line memberships, sales history, accounting history, shipping-document history, export-evidence history, Groupage history, invoice-adjustment history or any other downstream record.

## Governing principle

Shipment Batch Undo is blocked by states that are currently authoritative or genuinely irreversible.

Historical rows that the platform has already made inactive, superseded, voided, reversed or rejected do not block Undo unless this addendum expressly says otherwise.

Shipment Batch Undo is a logistics-membership reversal only. It is not a customer-sales reversal, accounting reversal, VAT reversal, shipping-charge reversal, export-evidence reversal or Groupage cancellation mechanism.

## Authoritative Shipment Batch mutation

When Undo is permitted, the platform must perform all of the following atomically:

1. The Shipment Batch changes from `status='created'` to `status='voided'`.
2. `voided_at` is populated.
3. `voided_by_shipper_user_id` is populated with the acting authenticated shipper user.
4. `void_reason` is populated from a mandatory non-empty Undo reason.
5. Every active `shipper_shipment_batch_packages` row for the Shipment Batch changes to `active=false`.
6. Each deactivated package membership records `removed_at`, `removed_by_shipper_user_id` and `remove_reason`.
7. Every active `shipper_shipment_batch_line_memberships` row for the Shipment Batch changes to `active=false`.
8. No Shipment Batch, package-membership or exact-line-membership row is deleted.
9. No immutable identity, quantity or value field on an exact line membership is changed.
10. An inactive exact line membership must never be reactivated.

The existing `shipper_block_shipment_line_membership_mutation_v1()` trigger remains authoritative and must not be changed by this build.

## Authentication and ownership

Undo is permitted only when all of the following are true:

1. `auth.uid()` is present.
2. The caller has an active `shipper_users` row.
3. The Shipment Batch belongs to that shipper.
4. The Shipment Batch currently has `status='created'`.
5. A non-empty reason is supplied.
6. The Shipment Batch has at least one active package membership.

A voided Shipment Batch cannot be undone again.

## Blocking states

Undo must reject when any of the following current or irreversible states exists for the Shipment Batch or its exact active shipment allocations.

### Active Groupage membership

Undo is blocked while the Shipment Batch has an active `shipper_groupage_movement_batches` membership.

Inactive historical Groupage membership does not block Undo.

The existing Groupage exclude/cancel controls remain the only mechanism for removing a Shipment Batch from an active Groupage Movement.

### Active shipping document

Undo is blocked while any `shipping_documents` row for the Shipment Batch has `active=true`.

Inactive or superseded shipping-document history does not block Undo.

`shipping_document_messages` history is not a separate Undo blocker.

### Active approved shipping-cost allocation

Undo is blocked while any `shipping_cost_allocations` row for the Shipment Batch has `active=true` and `allocation_status='approved'`.

Inactive, superseded or voided shipping-cost-allocation history does not block Undo.

### Export-locked exact allocation

Undo is blocked if any exact active shipment allocation is already locked for export through either:

- `order_tracking_line_allocations.locked_for_export_pack_at IS NOT NULL`; or
- `order_tracking_line_allocations.allocation_status='locked_for_export_pack'`.

This is a hard boundary. Shipment Batch Undo must not unlock an export-locked allocation.

### Active customer-sales release

Undo is blocked while any `customer_sales_release_lines` row sourced from the Shipment Batch has `release_status='active'`.

A properly reversed release row with `release_status='reversed'` does not block Undo.

This build does not add, alter or complete the customer-sales reversal workflow.

### Active or posted accounting snapshot

Undo is blocked while any `sage_posting_snapshots` row for the Shipment Batch is currently active and has not been voided, or while any snapshot for the Shipment Batch has reached posted accounting.

For this addendum:

- an active snapshot with `sage_posting_status <> 'voided'` blocks Undo;
- any snapshot with `sage_posting_status='posted'` blocks Undo regardless of later snapshot activity flags;
- inactive superseded/voided, never-posted snapshot history does not block Undo.

Shipment Batch Undo must not mutate accounting snapshots.

### Final export evidence

Undo is blocked when final export evidence for the Shipment Batch is currently:

- `submitted_for_review`; or
- `accepted_current`.

Final export evidence whose only remaining state is `rejected_resubmit_required` does not block Undo.

This build must prevent new final export evidence from being submitted for a voided Shipment Batch and must prevent rejected evidence from being re-reviewed into an active/accepted state after the Shipment Batch has been voided.

## Non-blocking states

The following states do not block Shipment Batch Undo by themselves:

1. Inactive historical Groupage membership.
2. Inactive or superseded shipping-document history.
3. `shipping_document_messages` history.
4. Inactive, superseded or voided shipping-cost-allocation history.
5. Mutable `invoice_adjustment_consumption_ledger` rows with `outcome='progressed_allocated'`.
6. Properly reversed customer-sales release history.
7. Inactive superseded/voided, never-posted accounting snapshot history.
8. Final export evidence whose only remaining state is `rejected_resubmit_required`.
9. Saved export-evidence completion fields.
10. Booking reference edits.
11. Shipment cut-off edits.
12. Box/carton-count edits.
13. Notes edits.
14. A populated `dispatched_at` field by itself.

## Mutable invoice-adjustment housekeeping

`invoice_adjustment_consumption_ledger` rows with `outcome='progressed_allocated'` are recalculable platform state and are not an Undo blocker.

Shipment Batch Undo must not delete invoice-adjustment history and must not mutate terminal or immutable adjustment outcomes.

After shipment memberships are deactivated, any active mutable `progressed_allocated` adjustment rows that still carry the voided Shipment Batch ID must be superseded and rebuilt inside the Undo transaction using the same mutable criteria as the existing `recalculate_invoice_adjustment_consumption_v1` authority: only allocations that are not export-locked and have no active customer-sales release may be recalculated. The existing recalculation function, its permissions and its staff/operator authority must not be changed by this build.

If an affected allocation has crossed the existing immutable export/customer-release boundary, Undo must fail rather than bypass that boundary.

## Reselection after Undo

Undo does not force a package back into the shipment candidate list.

After the active Shipment Batch package and exact-line memberships are deactivated:

1. The package is no longer treated as actively shipped by the Shipment Batch authority.
2. The existing shipment-ready routing and candidate functions recalculate from current platform state.
3. The package may appear again only if it still satisfies the normal current shipment-candidate rules.
4. Any current hold, receipt, fulfilment, quantity, export lock or other existing eligibility rule remains authoritative.
5. Re-batching creates a new Shipment Batch membership and a new exact line snapshot. Historical inactive membership is not reactivated.

No shipment-candidate, receipt, hold, fulfilment or entitlement rule is changed by this build.

## Concurrency and lock contract

Undo must serialize against creation and downstream writers so that a writer cannot pass a stale `created`/active check while Undo is committing.

The Undo transaction must:

1. lock the target Shipment Batch row `FOR UPDATE`;
2. lock its active package memberships;
3. acquire the same order and tracking advisory transaction locks used by `shipper_create_shipment_batch_v2` for the active package memberships;
4. lock the exact `order_tracking_line_allocations` referenced by active exact line memberships before evaluating export-lock and customer-sales blockers;
5. evaluate all blockers only after the required locks are held.

This build may harden only the existing Shipment Batch writers required to serialize with this Undo boundary:

- Shipment Batch header update;
- export-evidence completion-fields save;
- shipping-document submission;
- final export-evidence submission;
- final export-evidence review;
- Groupage creation.

Hardening is limited to obtaining the target Shipment Batch row lock and preserving the existing created/non-void ownership/status rule. Final export-evidence submission/review must additionally reject a voided Shipment Batch because the current implementation does not fully enforce that boundary.

No other writer, permission, role, status, read model or workflow transition may be changed by this build.

## Shipper UI

The Shipment Batch detail page may expose an `Undo Shipment Batch` action only for a Shipment Batch currently shown as `created`.

The action must:

1. require a non-empty reason;
2. call the backend Undo authority;
3. display the backend blocker/error without attempting to bypass it;
4. explain that packages are released from the batch and become selectable again only if they remain eligible;
5. not promise that a released package will necessarily reappear in candidates.

A voided Shipment Batch is read-only for the mutation controls governed by this addendum.

The backend remains authoritative even if a stale browser page still renders a control.

## Explicit non-goals

This build does not:

- add or alter customer-sales reversal;
- add or alter customer credit-note creation;
- reverse a posted customer sale;
- reverse, delete or edit accounting snapshots;
- reverse or delete shipping documents;
- reverse or delete shipping-cost allocations;
- cancel or edit Groupage Movements automatically;
- unlock export-locked allocations;
- alter VAT treatment;
- alter supplier invoice approval/rejection controls;
- alter receipt history;
- alter customer holds or disputes;
- alter shipment candidate eligibility rules;
- alter shipment creation rules;
- repair legacy Shipment Batch anomalies;
- backfill historical audit fields;
- add new global constraints;
- change unrelated UI labels, navigation, totals, permissions, statuses or styling.

## Required regression proof

The implementation is complete only when tests prove all of the following without changing protected authorities outside this addendum:

1. A clean exact-line Shipment Batch can be undone.
2. A clean legacy Shipment Batch with active packages and no downstream blocker can be undone.
3. The parent Shipment Batch is voided with actor/time/reason audit.
4. Active package memberships are deactivated with removal audit.
5. Active exact line memberships are deactivated while identity, quantity and value remain unchanged.
6. No Shipment Batch, package membership or exact line membership is deleted.
7. Shipment-effective lines disappear from the voided batch.
8. Shipment-ready/candidate state recalculates through existing authorities.
9. Active Groupage blocks; inactive historical Groupage does not.
10. Active shipping document blocks; superseded/inactive history does not.
11. Active approved shipping-cost allocation blocks; superseded/voided/inactive history does not.
12. Export-locked exact allocation blocks.
13. Active customer-sales release blocks; properly reversed release history does not.
14. Active/frozen accounting snapshot blocks.
15. Posted accounting snapshot hard-blocks.
16. Inactive superseded/voided never-posted snapshot history does not block.
17. Final evidence `submitted_for_review` blocks.
18. Final evidence `accepted_current` blocks.
19. Rejected-only final evidence does not block after writer hardening.
20. Completion fields alone do not block.
21. `dispatched_at` alone does not block.
22. Mutable `progressed_allocated` adjustment state is superseded/recalculated without deleting history or altering terminal outcomes.
23. Wrong shipper, unauthenticated caller and repeated Undo are rejected.
24. A stale direct final-evidence submit/review cannot mutate a voided Shipment Batch.
25. Concurrent Shipment Batch creation/re-batching is serialized by the existing order/tracking advisory-lock convention.
26. Concurrent customer-sales release cannot cross the Undo boundary through the same exact allocation while Undo holds the allocation lock.
27. Concurrent header, completion-field, shipping-document, final-evidence and Groupage writers cannot commit against a stale created Shipment Batch state.
