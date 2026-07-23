# Line-Level Shipment Membership Addendum v1

## Purpose

This addendum clarifies shipment composition where a received tracking package contains both held and unheld allocation lines.

## Governing principles

1. `received_clean` remains physical receipt truth for the tracking package.
2. Customer holds, disputes and refund controls remain commercial line/order/package controls.
3. A line-scoped hold must not convert automatically into a package-scoped hold.
4. An order-scoped or tracking-scoped hold blocks the whole package from shipment selection.
5. A line-scoped hold excludes only the matching supplier invoice allocation line.
6. A package may enter a shipment batch when at least one positive allocated line remains eligible after active holds are applied.
7. New shipment batches must persist immutable exact line membership at creation time.
8. Held lines must not reappear in an existing shipment when the hold is later resolved.
9. Shipment contents, freight apportionment, AP/recharge readiness, export evidence and customer release must consume the durable shipment-line membership for new batches.
10. Legacy batches created before this control may use package-allocation fallback where no shipment-line snapshot exists.
11. After shipment creation, every shipment-facing package, line, quantity and value summary used by shipper, importer, supervisor, admin, document review, freight, AP/recharge, export evidence, COS, groupage, POD or Sage-readiness views must derive from durable shipment-line membership.
12. Original tracking allocation may be shown only when explicitly labelled as original allocation, delivery allocation or receipt history.
13. Shipment-facing read models must not reconstruct current shipment contents directly from `order_tracking_line_allocations` or tracking-submission totals.
14. Shared shipment package/batch facts projections are the authoritative read boundary for shipment-facing quantities and values.
15. Canonical status, readiness, permission, lock, workflow-transition and `next_action` rules remain independent of shipment facts projections and must not be altered by this implementation alignment.

## Compatibility with customer sales mini-builds 1-4

This addendum does not alter the customer sales release ledger, release quantity/value guards, Sage posting snapshots, supplier invoice approval, receipt status or hold/dispute records.

The shipment-line snapshot is an earlier logistics membership boundary. The existing customer sales release ledger remains the authoritative durable record of commercial customer release. A line excluded from shipment membership cannot enter customer release through that shipment batch. Existing release guards remain authoritative and independent.

## Canonical read boundary

For shipment-facing views and documents:

```text
shipper_shipment_batch_effective_lines_v1(batch_id)
        ↓
shipper_shipment_batch_package_facts_v1(batch_id)
        ↓
shipper_shipment_batch_summary_v1(batch_id)
```

Existing status/readiness functions may wrap or join this facts boundary to replace only shipment quantity/value columns. Their status, readiness and `next_action` outputs remain inherited from the existing canonical workflow implementation.

## Example

Tracking package `evri180726` contains:

- Ninja Detect Power Blender Pro — active line hold and refund exception.
- One unrelated eligible item.

After the 24-hour customer review gate:

- the tracking package remains `received_clean`;
- the Ninja line remains in the hold/refund workflow;
- the unrelated line remains selectable for shipment;
- a created shipment snapshots only the unrelated line;
- later resolution of the Ninja hold does not add it retroactively to that shipment;
- original allocation/receipt history may show two units;
- every shipment-facing summary, document, freight, AP/recharge and Sage-readiness view shows one shipment unit.

## Non-goals

This addendum does not change OCR, credit-note matching, supplier control, Sage posting, treasury, FX, VAT, tracking evidence, receipt evidence, original tracking allocation truth, canonical status, canonical next action, permissions, approval transitions or dashboard action routing.