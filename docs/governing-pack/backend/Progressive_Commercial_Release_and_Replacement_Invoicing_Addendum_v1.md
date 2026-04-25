# Progressive Commercial Release & Replacement Invoicing Addendum v1

**Multi Tenant Platform Build — commercial release and customer-invoice treatment for progressed subsets and late replacement items**

## 1. Purpose

This addendum corrects and clarifies the customer invoicing rule for the platform where a parent order may contain a stable progressed subset while one or more items remain unresolved as refund/replacement child exceptions.

It sits alongside the VAT Timing & Export Evidence Addendum v1 and overrides any earlier wording that implies the platform must wait for the entire parent order to resolve before any customer sales invoice can be raised.

## 2. Authority position

The existing authority pack already allows correct lines to progress while unresolved lines become child exceptions, and it keeps shipper handling limited to the progressed subset. This addendum applies that same principle to commercial release/customer invoicing.

The Sage Posting Matrix v1 says the outward customer sale should only post when the commercial value is stable enough for release. Under this addendum, “stable enough” may apply to a **released subset**, not only to the whole parent order.

## 3. Core rule

For Phase 1:

```text
Customer invoicing may be progressive by stable released subset.
```

That means:

```text
5 quoted items
4 items supplier-invoiced, reconciled, progressed, and received/confirmed into the shipper lane
1 item remains as a replacement exception

→ create a customer sales invoice for the 4 stable items
→ keep the 1 unresolved item open as a replacement child path
→ when the replacement item later passes the required checks, create a supplementary customer invoice for that remaining item
```

## 4. What does not change

This does **not** create a new commercial parent order.

This does **not** create a new customer funding event for a replacement child.

This does **not** allow unresolved child value to be smuggled into shipment scope.

This does **not** duplicate VAT Box 6 where the value has already been captured by the prepayment/deposit timing rule.

This does **not** allow a replacement child invoice/reference to attach back to the original order as supplier evidence. Supplier replacement evidence still attaches to the replacement child order.

## 5. Customer invoice model

The existing `sales_invoices.invoice_type` values are enough for Phase 1:

```text
main = first customer invoice release for the commercial parent order
supplementary = later customer invoice release for a remaining stable subset
credit_note = customer credit/correction path
```

The existing unique rule of one non-void `main` invoice per order should stay.

Later releases use `supplementary`, linked to the original `main` invoice where available.

## 6. Replacement child treatment

A replacement child order remains an operational fulfilment path.

If the replacement item was already included in a previous customer invoice, the replacement is a fulfilment correction and no new customer sales invoice is created by default.

If the replacement item was **not** included in a previous customer invoice because only the stable progressed subset had been invoiced, the replacement item can be customer-invoiced later as a supplementary release once stable.

So the controlling question is:

```text
Has this value already been customer-invoiced/released?
```

not merely:

```text
Is this a replacement child?
```

## 7. Release conditions

A supplier invoice line can enter customer invoice release only when:

1. It is linked to the original commercial parent order or to a replacement child of that parent.
2. It is marked eligible/progressed.
3. It has confirmed quantity and amount.
4. Its source order has reached UK shipper receipt or a later shipment state.
5. It has not already appeared in a non-void customer sales invoice release.
6. Original order funding control is satisfied.
7. Sage posting will be queue-driven and idempotent.

## 8. VAT interaction

VAT timing remains governed by the VAT Timing & Export Evidence Addendum v1.

For known quoted goods paid in advance, the prepayment/deposit timing rule can report the value in Box 6 before the later customer sales invoice date.

Therefore, later `main` or `supplementary` Sage/customer invoices must not duplicate Box 6. They transfer/customer-invoice the commercial release, while VAT workings remain period-controlled by prepayment timing and approved adjustments.

## 9. Schema implication

No immediate new table is required for Phase 1 because:

- `sales_invoices.invoice_type` already supports `main` and `supplementary`.
- `sales_invoices.linked_invoice_id` can link supplementary invoices to the first main invoice.
- `sales_invoices.line_items_json` can store the released supplier invoice line IDs.
- `sage_postings.idempotency_key` prevents duplicate posting attempts.

Future hardening may add a dedicated `customer_invoice_release_lines` table, but it is not required to prove the Phase 1 backend control.

## 10. Amended authority-stack interpretation

This addendum amends:

1. Architecture Completion Addendum v2
2. Canonical Schema Reference v1
3. SAGE Posting Matrix v1
4. Master End-to-End Orchestration v3
5. Technical Resource Map by Node v2
6. closure_v2_functions_v2.sql
7. Day 6 / Day 8 accounting and VAT smoke tests

Where older wording says or implies “one final outward customer sale only when the whole order is stable”, read it as:

```text
one or more customer invoice releases may occur for stable progressed subsets, provided each released value is stable, non-duplicated, idempotent, and tied back to the original commercial parent order.
```

## 11. Practical example

```text
Original order: 5 items / £500
Prepayment: £500
Initial supplier invoice/reconciliation: 4 items / £400 stable
Replacement exception: 1 item / £100 unresolved

Release 1:
main customer invoice = £400 for 4 stable items

Later:
replacement child receives supplier invoice for 1 replacement item
item is reconciled, shipper-received, and stable

Release 2:
supplementary customer invoice = £100 linked to the same original parent order

VAT:
Box 6 is not duplicated if the £500 was already captured under the prepayment/deposit timing rule.
```
