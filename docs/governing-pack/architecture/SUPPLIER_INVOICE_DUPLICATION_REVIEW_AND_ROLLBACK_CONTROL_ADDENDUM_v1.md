# Supplier Invoice Duplication Review and Rollback Control Addendum v1

**Status:** Corrective governing addendum  
**Scope:** Remove only the unintended supplier-invoice duplicate guard introduced during the 16 August 2026 duplication review.

## 1. Governing purpose

This addendum does **not** change supplier-invoice identity, approval, OCR matching, Sage readiness, order semantics, or multi-supplier behaviour.

It exists only to restore the platform to the previously governed supplier-invoice behaviour by removing the unintended cross-order reference guard added during the duplication review.

## 2. Existing controls remain authoritative

The existing supplier-invoice controls remain unchanged, including:

- order-scoped/current invoice controls;
- post-document-read duplicate detection using supplier/retailer identity, extracted invoice reference and gross total;
- `duplicate_blocked` / Sage blocking behaviour;
- supervisor approval/rejection controls;
- existing unique indexes and downstream accounting controls.

`MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_4.md` remains governing for supplier-invoice semantics.

## 3. Exact rollback scope

Only these objects introduced by the unintended review SQL may be removed:

1. trigger `trg_supplier_invoice_cross_order_duplicate_guard_v1` on `public.supplier_invoices`;
2. function `public.supplier_invoice_cross_order_duplicate_guard_v1()`;
3. function `public.supplier_invoice_reference_identity_v1(text)`.

No `CASCADE` is authorised.

## 4. Mandatory preflight

Before rollback, a read-only preflight must prove:

- the three rollback objects exist;
- their definitions are the unintended review objects;
- no unrelated object depends on them;
- the original supplier-invoice post-read duplicate trigger/function remains present;
- existing supplier-invoice uniqueness/current controls remain present;
- no data mutation is required.

If any check fails, stop. Do not alter the database.

## 5. Rollback rules

The rollback must:

- remove only the three named objects;
- alter no rows;
- alter no existing indexes, constraints, grants, RLS, statuses or functions;
- make no treasury, bank-statement, tracking, shipper-document, credit-note, Sage, VAT or accounting change.

## 6. Duplication-review conclusions frozen by this addendum

No change is authorised from this review for:

- tracking submissions;
- shipper invoice/receipt references;
- supplier credit-note references;
- bank statements or treasury;
- Sage grouped payment identifiers;
- main-bank to shipper-AP allocation concurrency.

The current main-bank shipper-AP allocator already contains the later target-row locking control and is out of scope.

Order-creation retry atomicity, if ever reviewed, must be a separate governed investigation and is not authorised here.

## 7. Postflight

After rollback, postflight must prove:

- all three unintended objects are absent;
- the original supplier duplicate-control trigger/function is still present;
- existing supplier-invoice current/approved uniqueness controls are still present;
- no supplier-invoice rows were changed by the rollback.

## 8. Final locked sentence

> This corrective addendum authorises only the surgical removal of the unintended cross-order supplier-reference duplicate guard introduced during the duplication review. It authorises no other platform change.
