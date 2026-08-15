# Temporary Pre-Pilot Exact Customer Review Window Amendment v1

Status: temporary controlled-testing amendment

Effective date: 15 August 2026

Amends only:

- `MINI_BUILD_4_FIXED_DEADLINE_REVIEW_CYCLE_LIFECYCLE_AMENDMENT_v1`
- the exact/mixed receipt customer-review path implemented by `internal_customer_review_cycle_candidates_v2(uuid)` and `internal_bridge_exact_customer_review_candidates_v1(uuid,uuid)`.

## 1. Purpose

The canonical customer pre-shipment review window remains **24 hours** for pilot and production use.

During the current controlled pre-pilot testing period only, the exact/mixed receipt review path is temporarily shortened to **2 minutes** so repeated end-to-end workflow tests can be completed without waiting 24 hours between receipt, customer review expiry and shipment eligibility.

This is a test-duration override only. It is not a change to the commercial, customer-service or production review policy.

## 2. Temporary test rule

For new exact/mixed review cycles created during this controlled testing period:

```text
review_expires_at = exact eligible receipt recorded_at + 2 minutes
```

The corresponding fixed-cycle containment interval used by the exact review bridge is also **2 minutes** during this testing period.

The candidate expiry and its source fingerprint must use the same interval so provenance remains internally consistent.

## 3. Canonical pilot and production rule

Before the platform is used for the external pilot, production launch, or any production customer workflow, the temporary 2-minute override must be removed through a reviewed additive migration and both exact/mixed review intervals must be restored to:

```text
24 hours
```

The production restoration is a release gate, not an optional cleanup item.

No pilot or production release is authorised while the exact/mixed review path remains configured to 2 minutes.

## 4. Fixed-deadline integrity remains unchanged

This temporary duration override does **not** relax or bypass fixed-deadline integrity.

In particular:

- `customer_order_review_links.expires_at` remains the authoritative stored deadline;
- an already-created timed review deadline remains immutable;
- no existing stored deadline may be shortened, extended or recalculated to apply this testing override;
- later eligible membership must not extend an existing cycle;
- expired review history must remain preserved;
- existing membership provenance and fingerprints remain authoritative.

The temporary 2-minute rule applies only when a new exact/mixed review cycle is created after the test override is active.

## 5. Existing test order

The already-created review cycle for controlled test order `ORD-1786712731703` was created under the earlier 24-hour rule and its stored deadline must remain unchanged because review deadlines are immutable.

Any controlled test-state transition performed for that existing order is specific test-data handling and must not be generalised into reusable production logic or used to bypass the deadline guard.

## 6. Frozen scope

This amendment authorises no other change.

The following remain unchanged:

- receipt evidence and receipt dispositions;
- exact clean and exception quantities;
- customer hold logic and supervisor hold handling;
- review membership quantities, identities and provenance;
- routing-position calculations;
- shipment candidate calculations and shipment creation;
- existing customer and shipper countdown consumers;
- supplier invoices, reconciliation and progression;
- customer sales and release ledgers;
- accounting, Sage, VAT, refund and payment controls;
- permissions, RLS, tenant boundaries, UI wording, styling and navigation;
- legacy and unrelated review routes.

No table schema change, new timer architecture, new review route or new shipment route is authorised.

## 7. Implementation discipline

The repository implementation must be additive and surgical:

1. do not rewrite historical migration files;
2. add one migration that changes only the exact/mixed candidate review interval and exact bridge containment interval from 24 hours to 2 minutes;
3. preserve function signatures, grants, ownership, return shapes and all non-duration logic;
4. perform no order-data updates in that reusable migration;
5. fail closed if the target function definitions do not match the expected 24-hour or already-applied 2-minute state;
6. verify after migration that the exact candidate contains exactly two 2-minute interval literals, the exact bridge contains exactly one, and neither target function retains an operational 24-hour interval literal;
7. before pilot/production, add a separate reviewed restoration migration returning those same three operational literals to 24 hours.

Everything outside this temporary interval override remains governed by the existing locked review-cycle and hybrid physical-receipt authorities.