# Supplier AP vs customer invoiceable contract v1

## Purpose

This contract prevents a critical accounting drift: treating OCR/supplier invoice line progression as if it automatically means the same line should appear on the customer final pro forma, customer sales invoice, or Sage sales invoice payload.

The rule is simple:

- Supplier/AP truth records what the retailer charged the platform.
- Customer invoiceable truth records what the importer/customer should finally be charged for.

These are related, but not the same.

## Governing sources checked

This contract is aligned with:

- `docs/governing-pack/ui/INVOICE_LINE_RECONCILIATION_ACTION_CONTRACT.md`
- `docs/governing-pack/ui/EXCEPTION_BRANCHING_MVP_CONTRACT.md`
- `docs/governing-pack/ui/EXCEPTION_REFUND_REPLACEMENT_ROUTE_CONTRACT.md`
- existing `supplier_invoices`, `supplier_invoice_lines`, `disputes`, `dispute_lines`, and replacement child order model.

## Core principle

A retailer/supplier invoice line may move forward for supplier invoice/AP control even if it must not appear on the customer final pro forma or customer sales invoice.

Do not use one flag to mean all of the following at once:

- retailer charged us;
- supplier invoice can be controlled/posted;
- item was received/accepted;
- item should appear on customer final pro forma;
- item should appear on customer sales invoice;
- item is ready for Sage sales payload.

These are separate accounting states.

## Definitions

### Supplier/AP recognised

The retailer charged the platform and the supplier invoice/OCR line is valid evidence of supplier-side cost/AP exposure.

Supplier/AP recognised lines may include:

- clean items;
- items charged but later missing/damaged/wrong;
- items being pursued for refund/credit note;
- items later corrected by supplier credit note;
- items later resolved by replacement/repurchase child order.

### Customer invoiceable

The item is valid to include on the importer/customer final pro forma, customer sales invoice, or Sage sales invoice payload.

Customer invoiceable lines should normally include only:

- clean/relevant items;
- accepted delivered items;
- resolved replacement/repurchase child-order goods where customer charging is appropriate;
- supervisor-approved adjusted items.

Customer invoiceable lines should exclude:

- item charged by retailer but missing/damaged/wrong and currently in exception;
- item awaiting refund/credit note;
- item awaiting replacement child order outcome;
- item not charged / no refund expected but not delivered;
- item selected by importer/shipper as disputed and not yet supervisor-cleared.

## Normal example

Order has five Zara items.
Retailer invoice/OCR shows all five items charged.
UK warehouse/final review finds one item missing.

Correct result:

- Supplier invoice/AP side: all five charged lines remain part of supplier invoice control.
- Customer final pro forma/sales side: only the four valid/relevant lines should be included.
- Exception side: the missing item goes through refund, replacement, not-charged, or credit-decision route.

If refund later succeeds:

- original supplier invoice remains as charged;
- supplier credit note/refund evidence corrects supplier/AP side;
- refund IN is matched in DVA/card reconciliation;
- customer side remains based on final pro forma/customer-relevant goods, or customer credit is handled separately if already charged.

If replacement later succeeds:

- original supplier invoice remains as charged;
- replacement/repurchase child order carries the new goods path;
- child order uses normal invoice/evidence/tracking/reconciliation flow;
- customer invoiceable treatment depends on resolved child order and final customer position.

## Contract rules

### 1. Supplier invoice control must preserve source evidence

OCR-extracted supplier invoice lines should not be deleted simply because the item later becomes an exception.

The supplier invoice records what the retailer charged. If it was charged, it remains part of supplier/AP control unless the original invoice itself is invalid or superseded.

### 2. Exception-linked supplier lines must not automatically feed customer sales drafts

If a supplier invoice line is linked to an open dispute/exception, it must not be treated as customer invoiceable merely because it exists on the retailer invoice or has AP recognition.

### 3. Customer pro forma/sales invoice must be derived from customer invoiceable state

The final pro forma/customer sales invoice should derive from clean/relevant/customer-chargeable goods, not blindly from all supplier invoice lines.

### 4. Refund/credit note corrects supplier side later

When a retailer issues a credit note or refund for a charged item:

- capture credit note evidence linked to original order, supplier invoice, dispute, and affected line(s);
- store negative quantity and negative amount;
- match refund IN through DVA/card workspace later;
- use structured supplier credit-note data before Sage automation.

### 5. Replacement/repurchase uses child order path

When new goods are coming in:

- supervisor approves replacement/repurchase route;
- create `replacement_child` order;
- child order follows normal invoice/evidence/tracking/reconciliation path;
- do not duplicate invoice/tracking UI inside exception page.

### 6. Not charged/no refund expected is a supervisor closure/credit decision

If the retailer did not charge for the item, no refund IN should be awaited.
Supervisor may:

- close as not charged/no refund expected;
- approve a credit decision;
- approve repurchase through replacement/repurchase child order if new goods are required.

## Required future implementation distinction

Current terminology such as `eligible_for_invoice_yn` or “progressed” must be interpreted carefully.

If existing implementation uses one field for both AP progression and customer invoiceability, future implementation must separate them logically before Sage sales payload generation.

Recommended conceptual split:

- `supplier_ap_recognised` / supplier invoice controlled;
- `customer_invoiceable` / allowed into final pro forma and customer sales invoice;
- `exception_blocked` / excluded until resolved;
- `replacement_child_pending` / excluded until child order resolves;
- `credit_note_expected` / supplier-side correction pending;
- `refund_in_matched` / DVA/card refund matched.

Do not add schema only because this contract names conceptual states. Verify live DB and existing views first. Add the smallest safe schema/view/RPC change only when a concrete page or Sage payload requires it.

## Page and payload implications

### Reconciliation page

Operator can continue to reconcile OCR lines and create exceptions.
Clean lines may progress operationally.
Exception lines may remain part of supplier invoice control but must be clearly marked as exception-linked.

### Final pro forma / customer review page

Must show only customer-relevant final item position.
Items in open exceptions should either be excluded or shown as excluded/pending, not silently billed.

### Supplier invoice approval

Supplier invoice approval can still recognise the retailer invoice as charged, subject to existing controls.
Exceptions should not falsely invalidate the whole supplier invoice where valid charged/progressed supplier lines exist.

### Sage supplier-side payload

Supplier invoice payload reflects supplier invoice truth.
Supplier credit-note payload later corrects supplier-side charges.

### Sage customer-side payload

Customer sales invoice payload must not include exception-blocked items unless they have become customer invoiceable through resolution.

## Hard controls

Do not allow:

- OCR/source supplier line deletion merely because an item is disputed;
- exception-linked lines to auto-flow into customer sales invoice payload;
- refund accepted to mean refund IN matched;
- replacement route accepted to mean child order complete;
- supplier invoice approval to mean customer invoiceability of every line;
- DVA/card refund IN to be treated as importer funding IN;
- customer final pro forma to be built blindly from all supplier invoice lines.

## Minimal test scenarios

### A. Charged item later missing

Given supplier invoice has five charged lines and one charged line becomes an exception:

Expected:

- supplier invoice still shows five charged lines;
- customer final pro forma excludes the exception line until resolved;
- exception line is visible in dispute trail;
- refund/replacement route controls downstream correction.

### B. Refund received

Given exception line receives retailer credit note and refund IN:

Expected:

- supplier credit note evidence has negative qty/amount;
- original supplier invoice remains linked;
- refund IN is matched to exception;
- customer side remains based on final customer-relevant item position.

### C. Replacement child order

Given exception line is resolved by replacement:

Expected:

- replacement child order is linked to parent dispute/order;
- child order follows normal invoice/tracking/reconciliation path;
- parent exception does not falsely mean child order is complete;
- customer invoiceability depends on resolved child order outcome.

### D. Not charged

Given an item was expected but never charged by retailer:

Expected:

- no refund IN is awaited;
- supervisor closes/credit-decides or approves repurchase;
- customer final pro forma does not bill the missing item unless later resolved/replaced.
