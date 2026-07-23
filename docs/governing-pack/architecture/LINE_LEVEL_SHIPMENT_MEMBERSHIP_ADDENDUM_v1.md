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

## Compatibility with customer sales mini-builds 1-4

This addendum does not alter the customer sales release ledger, release quantity/value guards, Sage posting snapshots, supplier invoice approval, receipt status or hold/dispute records.

The shipment-line snapshot is an earlier logistics membership boundary. The existing customer sales release ledger remains the authoritative durable record of commercial customer release. A line excluded from shipment membership cannot enter customer release through that shipment batch. Existing release guards remain authoritative and independent.

## Example

Tracking package `evri180726` contains:

- Ninja Detect Power Blender Pro — active line hold and refund exception.
- One unrelated eligible item.

After the 24-hour customer review gate:

- the tracking package remains `received_clean`;
- the Ninja line remains in the hold/refund workflow;
- the unrelated line remains selectable for shipment;
- a created shipment snapshots only the unrelated line;
- later resolution of the Ninja hold does not add it retroactively to that shipment.

## Non-goals

This addendum does not change OCR, credit-note matching, supplier control, Sage posting, treasury, FX, VAT, tracking evidence, receipt evidence or original tracking allocation truth.
