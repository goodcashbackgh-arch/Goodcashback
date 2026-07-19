# Multi-Supplier-Invoice Order Control — Live Evidence Appendix v1

Status: evidence appendix incorporated by reference into `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`

Evidence date: 19 July 2026

Inspected repository branch: `main`

Inspected repository commit: `d705c3ff9403fd40478caab6648e061d6a2101de`

## 1. Purpose

This appendix records the live pre-build evidence used to implement the four mini-builds governed by the Multi-Supplier-Invoice Order Control Addendum v1.

It does not change the governing architecture. It records where the live database and application currently conflict with that architecture, so implementation and regression can be assessed against specific source objects rather than assumptions.

## 2. Evidence inspected

The preflight comprised:

1. A full live PostgreSQL census covering relations, columns, constraints, indexes, triggers, RLS, grants, routines, views and dependencies.
2. Full definitions for the high-risk routines identified by that census.
3. An order-path snapshot for `ORD-1784054984002`.
4. The current repository migrations, RPCs and routes relevant to supplier invoice upload, approval, rejection, tracking, customer release, review, holds, refunds and Sage.

The live database reported PostgreSQL 17.6, 126 scoped relations and 341 scoped routines.

No live order containing several current supplier invoice references existed at inspection time because the current database and RPC guards prevented such a state.

## 3. Confirmed live conflicts

### 3.1 Supplier document identity

The live database enforced one current supplier invoice per order through:

```text
uq_supplier_invoices_one_current_per_order
```

It also enforced an all-history unique constraint on:

```text
retailer_id, invoice_ref, order_id
```

The operator upload RPC rejected any second active working invoice for the order, regardless of invoice reference, and mutated a rejected invoice reference to make corrected resubmission possible.

The supervisor approval RPC superseded any current sibling invoice on the order.

These controls conflict with the governing rule:

```text
one current version per order and normalised supplier invoice reference
```

### 3.2 Order bundle

The required order-wide read models did not exist:

```text
order_supplier_invoice_bundle_lines_v1
order_supplier_invoice_bundle_summary_v1
```

Existing operational consumers therefore remained exposed to latest/current-single-invoice assumptions.

### 3.3 Rejection safety

The live rejection RPC retired the selected invoice and cleared line progression fields without first proving that downstream use remained reversible.

The required fail-closed checks include tracking allocation, active customer review, active holds, unresolved exceptions, customer sales documents, supplier-payment allocations, supplier refund/credit evidence and frozen or posted supplier accounting artefacts.

### 3.4 Later mini-build conflicts

The census also confirmed the later work already governed by the addendum:

- no durable `customer_sales_release_lines` membership ledger;
- repeated supplementary customer invoices blocked by current draft creation logic;
- no immutable `customer_review_cycle_membership`;
- later review links blocked after a customer invoice exists;
- old review links dynamically re-read current eligible order lines;
- customer invoice hold compatibility reads only one JSON shape;
- package-to-refund membership is calculated live rather than frozen;
- shipper hold routines expose supplier financial values.

These are not added to Mini-build 1. They remain governed by Mini-builds 3 and 4.

## 4. Order-path evidence

`ORD-1784054984002` demonstrated that the existing progressed package hold can reuse the existing refund route:

```text
approved package hold
→ exact supplier invoice lines
→ one compatible refund dispute
→ retailer return instructions
→ shipper collection/proof
→ supervisor proof acceptance
→ supplier credit-note/refund evidence
```

The order had one supplier invoice. It therefore proves the existing hold/refund integration but is not evidence that the current platform supports multiple supplier invoices.

## 5. Mini-build 1 implementation boundary

Mini-build 1 must:

1. Replace order-wide current-invoice uniqueness with current reference-family uniqueness.
2. Preserve same-reference duplicate protection.
3. Preserve corrected rejected-family resubmission without altering the genuine reference.
4. Ensure approving one invoice does not supersede sibling references.
5. Fail closed when rejecting a document that has irreversible downstream use.
6. Add exact-line and order-summary bundle views.
7. Exclude retired invoice versions from the bundle.

Mini-build 1 must not:

- change the portal;
- change delivery-allocation actions;
- change supplier-payment allocation;
- create the customer release ledger;
- create immutable review membership;
- create a new refund, return, VAT or Sage path.

Those changes remain in their governed later mini-builds.

## 6. Release evidence required

Mini-build 1 is complete only when its additive migration and regression prove:

- the old order-wide unique index is absent;
- different live invoice references may coexist;
- one live current version per normalised reference remains enforced;
- a same-reference live duplicate is blocked;
- corrected rejected-family resubmission keeps the genuine reference;
- approval is sibling-safe;
- rejection fails closed after downstream use;
- the bundle views expose exact invoice and line provenance;
- retired versions are excluded;
- existing one-invoice orders remain compatible.

## 7. Evidence conclusion

The governing addendum remains materially complete.

The material gaps are implementation gaps in the live platform. This appendix freezes the pre-build state against which the four mini-builds are to be implemented and tested.
