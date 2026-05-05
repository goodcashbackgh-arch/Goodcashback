# Status Spine Control Model v1

Status: governing UI/domain control model.

Purpose: define the status spine for orders, exceptions, shipper queries, export evidence, DVA/card financial control, delivery and accounting readiness.

This document exists because status drift can mislead importers/operators, supervisors, shippers and admins. No user-facing page should invent its own meaning from raw table fields without mapping to this model.

## Core principle

Use one derived headline status per order, supported by independent lane statuses.

Do not create or rely on one manually writable `overall_status` field. The headline status must be derived from lane truth.

A single order can have clean progressed lines, open refund/replacement exceptions, open shipper discrepancies, export evidence pending and DVA/card financial work still outstanding. Collapsing those facts into one writable status will create contradictions.

## Required status output shape

A status read model should output:

```ts
{
  order_id: string,
  order_ref: string,
  overall_status: string,
  headline_label: string,
  next_action_label: string,
  next_action_role: 'operator' | 'supervisor' | 'shipper' | 'importer' | 'admin' | 'system',
  blockers: string[],
  lanes: {
    funding: LaneStatus,
    invoice_reconciliation: LaneStatus,
    commercial_exception: LaneStatus,
    dva_card: LaneStatus,
    shipper_intake_discrepancy: LaneStatus,
    shipping_quote_shipment: LaneStatus,
    export_evidence: LaneStatus,
    destination_delivery: LaneStatus,
    accounting_vat: LaneStatus,
  },
  status_integrity_warnings: string[],
}
```

## Headline order statuses

These are derived display statuses, not necessarily physical DB enum values.

1. `order_created` — order exists.
2. `awaiting_funding` — importer/customer funding not complete.
3. `funded_ready_for_purchase` — funding threshold met.
4. `awaiting_invoice_or_tracking` — operator evidence missing.
5. `invoice_reconciliation` — invoice/OCR/manual reconciliation active.
6. `part_progressed_exception_open` — clean lines progress, commercial exception lane open.
7. `ready_for_shipper_handoff` — procurement side clean enough for shipper handoff.
8. `awaiting_shipper_receipt` — shipper must confirm goods received.
9. `shipper_query_open` — shipper raised missing/damaged/wrong/not-received issue.
10. `operator_exception_required` — supervisor pushed shipper query to operator for commercial exception creation.
11. `commercial_exception_open` — refund/replacement flow active.
12. `replacement_child_order_active` — replacement child order exists and follows normal order flow.
13. `awaiting_shipping_quote` — shipper quote required.
14. `awaiting_importer_quote_approval` — importer/customer quote approval/payment required.
15. `shipment_ready` — ready for shipment/export.
16. `in_transit` — shipment is moving.
17. `awaiting_export_docs` — draft/final export docs missing or not linked.
18. `export_docs_under_review` — supervisor reviewing export evidence.
19. `export_evidence_complete` — export/VAT evidence accepted for linked sales invoices/orders.
20. `awaiting_destination_delivery` — destination delivery/importer confirmation pending.
21. `delivery_exception_open` — delivery failed/missing/damaged at destination.
22. `accounting_review` — ready for Sage/VAT/accounting checks.
23. `closed` — operational, financial, export and delivery blockers complete.

## Lane 1: Funding

Truth source: order funding position, DVA/order funding reconciliation, importer credit ledger.

Statuses:

- `not_started`
- `part_funded`
- `funded`
- `overfunded_credit_created`
- `funding_exception`

Funding is separate from DVA/card supplier charge reconciliation.

## Lane 2: Invoice/OCR/reconciliation

Truth source: supplier invoices, invoice review status, OCR status, supplier invoice lines, progressed line gating.

Statuses:

- `invoice_missing`
- `ocr_pending`
- `ocr_review_needed`
- `reconciliation_needed`
- `part_progressed`
- `fully_progressed`
- `exception_split`
- `supplier_invoice_ready_for_review`

## Lane 3: Commercial exception

Truth source: disputes, dispute_lines, dispute_messages, replacement child order link, refund approval/final outcome fields.

Header statuses should be treated as stages, not merely labels:

- `raised` — exception created.
- `under_review` — supervisor reviewing.
- `approved_refund` — final refund outcome accepted internally, or legacy status requiring control review if line evidence is incomplete.
- `awaiting_refund_credit` — refund outcome accepted; waiting for money/credit/DVA IN-line match.
- `approved_replacement` — replacement outcome accepted internally.
- `replaced` — replacement child order created.
- `refunded` — refund processed.
- `closed` — exception closed.

Retailer conversation/outcome statuses:

- `not_contacted`
- `retailer_contacted`
- `still_waiting`
- `more_info_requested`
- `retailer_disputed_or_rejected`
- `retailer_accepted_refund`
- `retailer_accepted_replacement`
- `outcome_ready_for_supervisor`
- `resolved`

Integrity rule: header status must not claim final approval if retailer outcome evidence is still waiting/missing. If it does, show a status-integrity warning and block further automated downstream readiness.

## Lane 4: DVA/card financial reconciliation

Truth source: DVA/card statement import, statement lines, statement allocations, allocation summary views.

Statuses:

- `statement_missing`
- `statement_imported`
- `unmatched`
- `part_allocated`
- `balanced`
- `refund_match_needed`
- `supplier_charge_match_needed`
- `fx_fee_classification_needed`
- `held`

This lane explains supplier charges, retailer refunds, fees, FX/card residuals and holds. It is not merely customer funding.

## Lane 5: Shipper intake / physical discrepancy

Truth source: future shipper goods receipt and discrepancy records.

Statuses:

- `not_handed_to_shipper`
- `awaiting_shipper_receipt`
- `shipper_received_clean`
- `shipper_received_partial`
- `shipper_discrepancy_raised`
- `supervisor_reviewing_shipper_query`
- `operator_query_required`
- `operator_exception_required`
- `commercial_exception_created`
- `shipper_query_resolved`
- `shipper_liability_review`

If a shipper raises missing/damaged/wrong/not-received goods, the supervisor triages. If it is a retailer/commercial issue, the supervisor pushes it to the relevant operator, who creates a refund/replacement exception. The replacement/refund exception then follows the commercial exception lane.

## Lane 6: Shipping quote / shipment

Truth source: future shipment quote, quote approval, shipment and tracking records.

Statuses:

- `not_ready`
- `awaiting_shipping_quote`
- `quote_issued`
- `awaiting_importer_quote_approval`
- `quote_approved`
- `shipment_ready`
- `in_transit`
- `arrived_destination`

## Lane 7: Export evidence / VAT documentation

Truth source: future export evidence pack, sales invoice links, shipment links, uploaded draft/final docs and supervisor review.

Export evidence may cover multiple sales invoices and multiple orders in one consolidated shipment. Do not model final export evidence as a single order-only attachment.

Statuses:

- `not_required_yet`
- `draft_export_doc_needed`
- `draft_export_doc_uploaded`
- `sent_to_shipper_for_finalisation`
- `final_export_doc_requested`
- `final_export_doc_uploaded`
- `export_doc_under_review`
- `export_doc_accepted`
- `export_doc_rejected_query_shipper`
- `export_evidence_complete`
- `export_evidence_overdue`

Required concept:

```text
export_evidence_pack
→ linked sales invoices
→ linked orders
→ linked shipment/shipper
→ draft documents
→ final documents
→ supervisor review status
→ VAT evidence status
```

## Lane 8: Destination delivery / importer receipt

Truth source: future destination delivery/POD/importer confirmation records.

Statuses:

- `awaiting_destination_delivery`
- `delivered_to_importer`
- `importer_confirmation_pending`
- `delivery_failed`
- `delivery_dispute_open`
- `delivery_resolved`

If delivery does not happen, the shipper raises a query to supervisor. The supervisor may push to the operator if retailer/commercial exception action is needed.

## Lane 9: Accounting/Sage/VAT readiness

Truth source: supplier invoice approval, sales invoice draft, DVA/card allocation, exception outcome status, export evidence, VAT timing.

Statuses:

- `not_ready`
- `supplier_invoice_ready`
- `sales_invoice_draft_ready`
- `sage_payload_ready`
- `posted_to_sage`
- `vat_evidence_pending`
- `vat_ready`
- `closed`

Do not post to Sage where lane contradictions exist.

## Mandatory integrity warnings

Status-control read models must flag at least:

1. Dispute header says `approved_refund` but retailer/conversation evidence is missing or still waiting.
2. Dispute header says `replaced` but no replacement child order exists.
3. Dispute has replacement child order but child order is not linked back to parent.
4. Refund outcome accepted but no DVA/card IN refund line allocated.
5. Supplier charge exists but no DVA/card OUT line allocation.
6. Statement line is balanced only through generic hold where final accounting readiness expects a real supplier/refund/fee classification.
7. Order appears ready for shipper but unresolved commercial exception exists.
8. Order appears ready for accounting but unresolved shipper discrepancy exists.
9. Export evidence marked complete but no final shipper export document exists.
10. Sales invoice/export evidence link missing for a shipment/export pack.

## Role views

Operator/importer should see: headline status, their next action, invoice/tracking uploads, reconciliation, retailer exception follow-up and delivery confirmation.

Supervisor should see: every lane, blockers, status contradictions, DVA/card financial control, exception gates, export docs and accounting readiness.

Shipper should see: goods expected, receipt, discrepancy raising, quote, shipment, export document upload/finalisation and delivery status.

Admin should see everything plus override/audit warnings.

## Immediate implementation priority

1. Add read-only `/internal/status-control`.
2. Patch exception button eligibility so already-approved/final statuses never show early-stage approval actions.
3. Add mismatch warnings before refund matching, shipper query build, export evidence build and Sage readiness.
