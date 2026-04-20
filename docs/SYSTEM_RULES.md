# SYSTEM RULES

## Core invariants
- Only released, reconciled, invoiceable subset can be billed.
- Parent order stays open until unresolved qty and amount are nil.
- Same economic item must never be billed twice.
- One bank line = one reconciliation outcome.
- OCR is draft only.
- Tax point for VAT reporting in this model is driven by funded consideration and recorded on the sales invoice.
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
- Invalid transitions blocked.
- One live main invoice per order.
- Sage posting idempotency key uniqueness.
- Audit triggers.
- Order lock trigger.
- Invoice gate trigger.
- Active status-transition uniqueness.

## Backend-enforced for MVP
- funded_at completion logic.
- Payout/reusable-credit guard.

---

## Funding Threshold Rule (Day 2)

**Formula:**
purchase_funding_threshold_gbp = order_total_gbp_declared + markup_applied_gbp

**Excluded from threshold:**
estimated_shipping_gbp — shipping is provisional until Day 4 quote confirmation
and apportionment. It is never counted toward Day 2 funding threshold.

**Consequence:**
When funded_gbp >= purchase_funding_threshold_gbp:
- Write one order_funding_events row with event_type = 'threshold_reached'
- Stamp orders.funded_at
- Transition order status: pending_dva_funding -> funded
- The unique partial index on order_funding_events enforces exactly one
  threshold_reached event per order at DB level. Application code must treat
  a unique violation as already-funded, not as an error.

**Fields kept separate — never blended:**
- order_total_gbp_declared
- markup_applied_gbp
- estimated_shipping_gbp (Day 2 — provisional)
- actual_shipping_gbp (Day 4 — confirmed)
- bundled_quote_gbp / bundled_final_gbp (Day 4/6 billing)

---

## Importer Credit Ledger Direction Convention

direction = 'credit' increases importer available credit.
direction = 'debit' decreases importer available credit.

Required pairings (app-enforced convention, not DB constraint):
- retailer_refund -> credit
- shipper_refund -> credit
- manual_credit -> credit
- applied_to_order -> debit
- payout_sent -> debit
- reversal -> mirror original entry direction
- admin_adjustment -> explicit direction required, with notes

For Day 2 funding calculations, only ledger rows with:
- entry_type = 'applied_to_order'
- direction = 'debit'
- linked_order_id = target order
count as credit applied toward that order's funding threshold.