# Customer Operations Hold History Carry-Forward Addendum v1

Status: governing compatibility and control addendum

Controlling parent authority:

```text
docs/governing-pack/ui/CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1.md
```

This addendum governs only the customer operations-page carry-forward of already-existing customer hold history. It does not create a new hold workflow, state model, exception route, shipment control, accounting treatment, or customer review mechanism.

## 1. Objective

A genuinely approved line hold must remain visible on the normal customer order operations page after the pre-shipment Review page is no longer the primary customer view.

The presentation must reuse the existing Customer Review **Hold request history** semantics already implemented for historical line identity.

## 2. Runtime boundary

Runtime implementation is authorised only in:

```text
app/customer/orders/[order_id]/operations/page.tsx
```

No database migration, schema change, RPC creation/replacement, trigger, RLS, grant, shared-component refactor, or Customer Review runtime change is authorised.

The existing authentication and operator/importer/order access gate must remain unchanged. Any administrative read used for this history must occur only after that gate and must be explicitly filtered to the current `orderId`.

## 3. Qualifying history

Only exact line-scoped holds may qualify:

```text
requested_scope = 'line'
supplier_invoice_line_id IS NOT NULL
```

A mere `requested` hold must not appear. A `rejected` hold must not appear. `resolved` by itself is not sufficient evidence that an approved hold was actually actioned.

A line qualifies only when either:

```text
status = 'supervisor_approved'
```

or:

```text
converted_dispute_id IS NOT NULL
```

The second condition preserves closed historical visibility after an approved hold has moved beyond the active approval state through the existing exception route.

This predicate is presentation-only. It must not update, reinterpret, or backfill any hold row.

## 4. Identity and customer-safe fields

Identity must reuse the existing authoritative relationship:

```text
customer_pre_shipment_hold_requests.supplier_invoice_line_id
→ supplier_invoice_lines.id
```

Customer-visible fields are limited to:

- hold scope label;
- existing hold status;
- supplier-line description;
- supplier-line quantity;
- supplier-line gross amount inclusive of VAT in GBP;
- customer hold reason;
- existing supervisor review note where present.

Missing amount must be omitted rather than fabricated as `£0.00`. Missing item identity must not be invented.

Do not expose hold UUIDs, dispute IDs, supplier invoice IDs or references, tracking IDs or references, VAT breakdown, OCR data, DVA data, Sage data, staff IDs, or other internal operational/accounting state.

## 5. UI reuse and placement

Reuse the existing Customer Review **Hold request history** presentation semantics. Do not introduce a separate “Held items” presentation or new interaction model.

Use the existing native collapsed `<details>/<summary>` pattern already present on the operations page.

The existing bottom-page sequence must remain unchanged:

```text
Credit and payment details
Payment details
Order evidence
```

The only authorised UI addition is one fourth collapsed section appended after `Order evidence`:

```text
Hold request history
```

When there are zero qualifying holds, the section must not render at all. No empty-state dropdown or placeholder is authorised.

No existing section may be moved, renamed, restyled, restructured, or have its data logic changed.

## 6. Explicit non-change boundary

This patch must not alter:

- `customer_review_cycle_memberships`;
- `customer_review_ready_line_ids_v1()`;
- review-link creation, membership, scope, expiry, or `last_used_at` behaviour;
- hold creation, narrowing, approval, rejection, resolution, supersession, or conversion;
- hold triggers or exception/dispute lifecycle;
- shipment membership, shipment blocking, shipment dates, or delivery status;
- customer sales release, sales invoices, customer credit notes, or document ordering;
- accepted estimate, final order value, funding, payment, or credit calculations;
- supplier AP, DVA, Sage, VAT, accounting readiness, or loyalty calculations;
- RLS, grants, permissions, authentication, navigation, or existing UI labels.

No application-state writes are authorised.

## 7. Regression requirements

The implementation must prove:

1. only `app/customer/orders/[order_id]/operations/page.tsx` changes at runtime;
2. no migration, RPC, trigger, schema, RLS, grant, or Customer Review runtime file changes;
3. the existing access gate remains unchanged and precedes the hold-history read;
4. the read is explicitly restricted to the current `orderId`;
5. `requested` and `rejected` holds do not qualify;
6. plain `resolved` without durable approval/action evidence does not qualify;
7. `supervisor_approved` qualifies;
8. closed history with non-null `converted_dispute_id` qualifies;
9. only authorised customer-safe fields render;
10. missing amount is not rendered as `£0.00`;
11. zero qualifying holds render no section;
12. the section is collapsed by default and appears after `Order evidence`;
13. `Credit and payment details`, `Payment details`, and `Order evidence` remain functionally and visually unchanged;
14. membership, hold lifecycle, dispute, shipment, customer-sales, payment, credit, DVA, Sage, VAT, RLS, grants, permissions, navigation, and existing labels remain unchanged.

This file is the governing authority for the customer operations-page hold-history carry-forward. Implementation must not exceed this scope.
