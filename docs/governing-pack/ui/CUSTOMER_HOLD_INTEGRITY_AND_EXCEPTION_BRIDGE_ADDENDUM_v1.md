# Customer Hold Integrity and Existing Exception Bridge Addendum v1

Status: governing addendum.

Applies with:

- `CUSTOMER_EXTENSION_PRE_SHIPMENT_HOLD_CONTRACT_v1.md`
- `EXCEPTION_BRANCHING_MVP_CONTRACT.md`
- `SHIPPER_CUSTOMER_HOLD_HARD_BLOCK_LATER_CONTRACT_v1.md`

## 1. Purpose

Close two defects without creating a second workflow:

1. A customer can currently submit repeated active holds for the same order, package or item.
2. An approved customer package/item hold can remain only as a physical set-aside instead of entering the existing refund exception route.

This addendum reuses the existing hold table, tracking-line allocation table, `disputes`, `dispute_lines`, importer exception pages, supervisor exception pages and refund-document control lane.

## 2. Locked architecture

The approved route is:

```text
Customer hold request
→ supervisor approval
→ existing refund dispute/dispute_lines structure
→ /importer/exceptions/[dispute_id]
→ retailer response
→ supervisor final outcome acceptance
→ existing credit-note/refund-document control
→ existing refund-IN matching and closure
```

Do not add:

- a second refund case table;
- a second exception page;
- a package-refund workbench;
- a new retailer-conversation route;
- a new credit-note route;
- automatic Sage, VAT, DVA/card or refund-money posting from hold approval.

## 3. Active-hold invariant

For this contract, an active hold has status:

- `requested`; or
- `supervisor_approved`.

Rejected, resolved and superseded holds do not block a later legitimate request.

The database, not only the page, must enforce:

- one active order-level hold per order;
- one active package-level hold per tracking submission;
- one active item-level hold per supplier-invoice line;
- an active order hold covers every package and item in that order;
- an active package hold covers every allocated item in that package;
- a new broad hold must not overlap active narrower holds;
- narrowing is allowed only through the existing narrowing RPC and must supersede the broad source hold.

The customer page should remove the relevant request form once the target is already actively covered. Database enforcement remains authoritative for repeated clicks, stale pages and concurrent RPC calls.

## 4. Exact target mapping

### 4.1 Item hold

An approved `line` hold maps only its `supplier_invoice_line_id` into the existing refund exception route.

The supplier-invoice line may already be progressed. Hold approval is a supervisor-authorised post-progression exception source and must not unprogress or rewrite the supplier-invoice line.

### 4.2 Package hold

An approved `tracking` hold maps only the supplier-invoice lines linked to that exact tracking submission through `order_tracking_line_allocations`.

Therefore:

- if an order has six lines but the held package contains two, only those two enter the exception;
- lines allocated to other packages remain outside that exception;
- no line may be inferred merely because it belongs to the same order;
- no synthetic package line may be created.

Where only part of a multi-quantity supplier line is allocated to the held package:

- `qty_impact` is the allocated quantity for that package;
- `amount_impact_gbp` is the supplier line amount apportioned by allocated quantity over the supplier line quantity;
- the existing supplier line remains unchanged.

The current `dispute_lines.qty_impact` contract accepts whole units. A fractional physical allocation must fail closed rather than be rounded or truncated silently.

### 4.3 Order hold

An approved `order` hold remains a broad set-aside and billing/shipment blocker. It does not automatically create a refund dispute because no precise supplier-invoice target is known.

It must be narrowed through the existing order/package/line narrowing path once mapping truth exists.

## 5. Existing dispute shape

The bridge must use the same records and values as the current invoice-reconciliation refund exception route:

### `disputes`

- `desired_outcome = 'refund'`
- `status = 'raised'`
- `issue_type = 'missing'`
- `stage_detected = 'at_reconciliation'`
- `liable_party = 'unknown'`
- `refund_approved_by_staff_id` from the approving hold reviewer
- `refund_approved_at` from the hold review time

### `dispute_lines`

- `supplier_invoice_line_id` from the precise item/package allocation mapping
- `line_status = 'affected'`
- `intended_remedy = 'refund'`
- `conversation_status = 'refund_pending_approval'`
- quantity and amount determined by section 4

The bridge must reuse an existing open `raised` refund dispute for the same order where the current reconciliation route would do so.

It must be idempotent:

- repeated trigger execution must not duplicate dispute lines;
- dispute amount must be recalculated from the dispute's linked lines rather than incremented blindly;
- `customer_pre_shipment_hold_requests.converted_dispute_id` must point to the reused/created dispute.

## 6. Existing-exception conflict rule

A supplier-invoice line must not be silently added to a second open exception.

If all mapped lines are already linked to the same open refund dispute, the hold may link to that dispute and record the supervisor approval.

If the mapped lines are split across multiple open disputes, only partly linked, or linked to a replacement/non-refund case, approval must fail closed with a clear conflict message. The operator/supervisor must resolve or narrow the target rather than creating duplicate financial routes.

## 7. Role and action boundary

Hold approval counts as supervisor approval of the refund pursuit/push to operator. Do not require the supervisor to approve the initiation twice.

After conversion:

- the importer/operator sees the case automatically in `/importer/exceptions`;
- the importer/operator uses the existing exception detail page to contact the retailer and record the response;
- the supervisor uses `/internal/exceptions/[dispute_id]` for final outcome control;
- credit-note/refund evidence stays on the existing importer exception page and routes to `/internal/refund-document-control`;
- refund IN remains matched through the existing DVA/card refund route.

Hold approval does not equal retailer acceptance, refund receipt, credit-note approval, refund-IN matching or exception closure.

## 8. Hold lifecycle after conversion

The original approved package/item hold remains `supervisor_approved` after the dispute is created.

It continues to enforce physical set-aside and customer-invoice exclusion until an existing staff-controlled closure route resolves or supersedes it.

Do not mark the hold resolved merely because:

- the dispute was created;
- the importer contacted the retailer;
- the retailer accepted;
- a credit note was uploaded;
- the dispute moved to `awaiting_refund_credit`.

## 9. Upstream/downstream exclusions

This patch must not change:

- order creation or funding;
- supplier-invoice OCR, progression or approval;
- tracking creation or allocation records;
- shipper batching, COS, BOL, POD or export evidence;
- supplier AP coding or payment matching;
- customer sales values, VAT logic or Sage payloads;
- replacement-child creation;
- refund-document OCR/control;
- refund-IN allocation.

Existing hold blockers remain authoritative. The bridge only supplies the missing exception records needed by the already-built refund path.

## 10. Deployment and regression requirements

Before merge, prove:

1. repeated same-package submission is rejected;
2. repeated same-item submission is rejected while another item remains selectable;
3. an active package hold blocks new item holds inside that package;
4. narrowing can still replace a broad hold with precise line holds;
5. approving an item hold creates/reuses one refund dispute and one line;
6. approving a package with two of six order lines creates/reuses one refund dispute containing only those two lines;
7. rerunning the bridge creates no duplicate lines and does not inflate the dispute amount;
8. the created dispute appears through the unchanged importer and internal exception views;
9. progressed source lines remain progressed;
10. no Sage, VAT, DVA/card, supplier AP or sales-invoice records are created by the bridge.