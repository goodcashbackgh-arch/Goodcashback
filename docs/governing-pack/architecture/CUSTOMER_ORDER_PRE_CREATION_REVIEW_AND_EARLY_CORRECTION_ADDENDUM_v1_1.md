# Customer Order Pre-Creation Review and Early Correction Addendum v1.1

Status: governing corrective amendment to v1

## Authority

This file amends only the points below in `CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1.md`.

The v1 addendum remains governing in every other respect. Where this v1.1 amendment conflicts with v1, v1.1 governs.

No other feature, workflow, table, status, trigger, RLS policy, financial control or downstream subsystem is authorised to change.

## 1. Authorised correction metadata

In addition to the business fields already authorised by v1, a successful quantity and/or declared GBP amount correction may update:

```text
orders.updated_at
```

This is ordinary last-modified metadata only. It is not customer-entered business data and does not authorise mutation of any other order field.

The directly editable customer fields remain exactly:

```text
quantity
declared GBP amount
original order screenshots
```

## 2. Active operator authority

The correction RPC must use the same explicit active-operator rule as the existing customer order-creation flow:

```sql
op.active = true
```

It must not use a null-tolerant fallback such as:

```sql
COALESCE(op.active, true) = true
```

A correction is therefore authorised only for an operator explicitly marked active.

## 3. Categories remain out of scope

`order_category_lines` is not part of this correction feature and must not be added to its eligibility gate, UI, mutation logic or regression dependency list.

Live read-only verification on 13 August 2026 established that the database contains exactly one historical category row, on order `BROWSER-DVA-d30fae36` created 26 April 2026. That order is already rejected by the existing correction gate because it has `funded_at`, a funding event and DVA reconciliation activity.

Therefore no category-specific correction control is required, and introducing one would be unnecessary scope expansion.

## 4. Storage verification remains unchanged

The existing v1 implementation already verifies replacement screenshot URLs against actual `storage.objects` entries in the existing `order-screenshots` bucket under the authenticated importer/order correction namespace.

This control remains required and unchanged. No new Storage behaviour is authorised.

## 5. Build delta authorised by v1.1

After this amendment is committed, the only runtime/source changes authorised are:

1. in `supabase/migrations/20260813124500_customer_order_early_correction_v1.sql`, change the operator predicate from `COALESCE(op.active, true) = true` to `op.active = true`;
2. in `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs`, assert the explicit active predicate, assert that the null-tolerant predicate is absent, assert `orders.updated_at` is authorised by this amendment, and assert `order_category_lines` is not introduced into the migration gate.

No UI file, existing customer create action, funding/tracking/invoice/reconciliation/shipping/Sage/VAT logic, existing function, trigger, RLS policy or schema table is authorised to change under this amendment.

## Acceptance

The correction feature remains:

```text
Review before create
→ Correct quantity / declared GBP amount / original screenshots only while genuinely untouched
→ Permanently reject correction once existing downstream processing starts
```

The two v1.1 corrections must not alter any already-working upstream or downstream behaviour.