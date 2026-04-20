# SYSTEM RULES

## Core invariants
- Only released, reconciled, invoiceable subset can be billed.
- Parent order stays open until unresolved qty and amount are nil.
- Same economic item must never be billed twice.
- One bank line = one reconciliation outcome.
- OCR is draft only.
- Tax point is funded consideration.
- No payout/reusable credit after invoicing without linked customer credit note.

## Funding
- One auth ID per order.
- Multiple inbound lines allowed only under same auth ID.
- Exception-held lines do not count toward funding threshold.

## Billing
- Main invoice only for released subset.
- `sales_invoices.line_items_json` is strict accounting snapshot.
- Replacement flow cannot rebill already billed value.

## Refunds
- Post-invoice refund path requires linked customer credit note first.

## DB-enforced now
- invalid transitions blocked
- one live main invoice per order
- Sage posting idempotency key uniqueness
- audit triggers
- reconciliation views

## Backend-enforced for MVP
- funded_at completion logic
- payout/reusable-credit guard
