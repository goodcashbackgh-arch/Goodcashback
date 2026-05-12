# Customer Extension Pre-Shipment Hold Contract v1

Status: MVP contract.

Purpose: add a lightweight customer-facing pre-shipment hold request layer without converting `/importer` into a customer portal and without creating a second exception/refund/shipping workflow.

## 1) Core rule

Customer can request a hold before shipment.
Supervisor approves or rejects.
Shipper only sees operational set-aside instructions.
Operator handles retailer refund, return, replacement, or no-charge closure through the existing exception/reconciliation flows.
Clean unheld lines continue through the existing build.

## 2) Route boundary

Do not use `/importer` for customer access.

Customer route:

- `/customer/orders/[secure_order_link]/review`

`/importer` remains the operator/importer business-side surface and may stay open for the specific operator/test user only.

The customer route must not expose:

- OCR editing
- supplier invoice controls
- DVA/card controls
- VAT controls
- Sage controls
- internal values unless deliberately approved later
- operator/supervisor controls

## 3) Existing architecture to reuse

This hold layer must plug into the existing spine:

- order as parent anchor
- order tracking submissions for packages/tracking refs
- supplier invoice lines for exact item-line selection once invoice/OCR/manual lines exist
- disputes / dispute_lines / dispute_messages for commercial exceptions after supervisor/operator conversion
- shipper package receipt and shipment controls for physical set-aside visibility
- pre-Sage / Ready-for-Sage blockers for accounting readiness

Do not build a new refund system, replacement system, shipper exception system, DVA system, or Sage workflow.

## 4) Hold scopes

The hold request can be one of three scopes:

1. `order` — no tracking and no invoice lines exist yet, so the customer can only request a temporary whole-order hold.
2. `tracking` — tracking/package exists but invoice lines are not yet available or not yet mapped, so the customer can request a package/tracking hold.
3. `line` — invoice/OCR/manual line exists, so the customer must select the exact line where possible.

Whole-order and tracking-level holds should be narrowed to line-level holds once invoice lines and/or allocation truth exists.

## 5) Scenario A — order exists, no invoice, no tracking

Customer says: “I do not want that item included.”

System behaviour:

- create order-level temporary hold request
- supervisor reviews
- if approved, block shipment/customer invoice/Sage readiness for the order
- operator can still upload invoice/tracking and reconcile
- once lines exist, supervisor/operator narrows the hold to exact line(s)
- clean unheld lines continue
- affected line goes through existing refund/replacement/no-charge exception route if needed

## 6) Scenario B — order and tracking exist, no invoice lines

Customer says: “Do not ship this package yet.”

System behaviour:

- create tracking/package-level hold request
- supervisor reviews
- if approved, shipper sees HOLD / SET ASIDE on the package/tracking ref
- operator still uploads invoice and reconciles lines
- once lines exist, hold is narrowed to exact affected line(s)
- clean unheld lines continue
- affected line follows existing commercial exception route where needed

## 7) Scenario C — order, tracking and invoice lines exist

Customer selects exact item/line to hold.

System behaviour:

- create line-level hold request
- supervisor reviews
- if approved, line is blocked from shipment/customer invoice/Sage readiness
- shipper sees operational set-aside where the line/package is already in shipper lane
- operator converts genuine commercial issue into existing refund/replacement/no-charge flow
- clean unheld lines continue

## 8) Readiness impact

Unresolved customer holds block:

- shipment release for the affected order/package/line
- customer final sales invoice release for affected line/order
- Ready-for-Sage / Sage posting preview for affected customer sales documents

Unresolved customer holds do not by themselves:

- post to Sage
- create VAT entries
- create DVA/card allocations
- create supplier AP postings
- create refund money entries

## 9) Shipper visibility

Shipper should only see:

- order ref
- tracking/package ref where applicable
- HOLD / SET ASIDE instruction
- operational status

Shipper should not see customer commercial reasoning, VAT, Sage, DVA/card, supplier invoice approval, or refund financial details.

## 10) Closure routes

A hold closes only when one of the following is true:

- supervisor rejects it
- customer/operator/supervisor resolves or supersedes it
- it is converted into an existing refund/replacement/no-charge exception path
- the commercial/physical/financial loops are closed through the existing architecture

Sage readiness must only clear after the hold is no longer active.

## 11) MVP non-scope

Do not build yet:

- customer login/account area
- customer payment controls
- customer invoice approval workflow
- automated refund posting
- automated Sage posting
- warehouse item-splitting beyond existing tracking-line allocation data
- direct customer editing of invoice/OCR lines
