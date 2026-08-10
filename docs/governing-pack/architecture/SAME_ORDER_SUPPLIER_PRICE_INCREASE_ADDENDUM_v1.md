# Same-Order Supplier Price Increase Addendum v1

Status: governing corrective addendum

## Purpose

Allow a supervisor/admin to increase the accepted GBP value of an existing **original** order when the platform's existing `order_bundle_limit_breach` control proves that active supplier invoice totals exceed the accepted order value.

Example:

```text
accepted order value                 £720.00
customer funding                     £720.00
supplier purchases already made      £600.00
active supplier invoice bundle       £740.00
extra customer funding required       £20.00
```

Controlled result:

```text
order value £720.00 -> £740.00
customer becomes genuinely £20.00 underfunded
ordinary DVA top-up supplies £20.00
existing supplier-payment proof then permits the remaining £140.00
```

## Authority stack and preservation rule

This addendum is subordinate to the locked platform architecture, schema, orchestration, technical-resource, Sage and UI-wiring controls except where it explicitly adds this narrow same-order amendment.

The build must preserve all established working paths unless this addendum expressly says otherwise.

In particular, **do not modify**:

```text
public.staff_save_supplier_invoice_header_review(...)
public.staff_approve_supplier_invoice_current(...)
public.order_funding_total_gbp(...)
public.order_funding_gap_gbp(...)
public.recompute_order_platform_funded(...)
public.sync_order_overfunding_credit(...)
public.internal_supplier_payment_readiness_v1(...)
public.internal_supplier_payment_bundle_source_v1(...)
public.staff_reconcile_dva_line_to_order(...)
public.staff_progress_supplier_invoice_lines(...)
```

Do not modify Build 4 reconciliation views, DVA, supplier-payment allocation, Sage, VAT, shipping, tracking, replacement-child or customer-review architecture.

## Existing breach flag remains authoritative

The existing control remains the entitlement to this new action:

```text
supplier_invoice_review_flags.flag_type = 'order_bundle_limit_breach'
status IN ('open','under_review')
```

A raw numerical condition `supplier bundle > order value` is **not enough on its own** to expose or execute the price-increase action. This prevents historical/raw anomalies and replacement-child economics from becoming new amendment entitlements.

The existing bundle arithmetic remains authoritative for this control:

```text
SUM(supplier_invoice_financial_summary.invoice_total_gbp)
```

for supplier invoices on the same order whose `review_status` is not:

```text
rejected_resubmit_required
duplicate_blocked
superseded
```

The new feature must not substitute `accepted_invoice_gross_gbp`, OCR totals, accounting coding totals or any new commercial-total hierarchy for this existing bundle authority.

## Supplier Invoice Review queue behaviour

`/internal/invoice-review` remains an exceptions queue.

No new queue-retention model is authorised.

The existing open `order_bundle_limit_breach` flag already makes the invoice a serious review exception through the existing `supplier_invoice_match_decision_vw`. Therefore the invoice naturally remains on Supplier Invoice Review while that flag remains open.

The existing three-variable routing remains unchanged:

```text
retailer match + invoice-reference match + total match + existing blockers
```

No custom order-level anchor or new live-price routing authority is required.

## Save correction remains untouched

The existing header-save RPC must remain byte-for-byte unchanged.

It may continue to attempt its established broad review-flag resolution.

However, `order_bundle_limit_breach` is a persistent financial control and must not be allowed to disappear while its underlying existing bundle arithmetic still exceeds the order value.

Add one narrow **BEFORE UPDATE** protection on `supplier_invoice_review_flags`:

1. It acts only when the existing row is `flag_type = 'order_bundle_limit_breach'` and an update attempts to move an open/under-review flag to `resolved`.
2. It recalculates the same existing active supplier-summary bundle for that flag's order.
3. If the bundle is still above `orders.order_total_gbp_declared + £0.01`, the trigger preserves the flag's existing open/under-review state and existing resolution fields.
4. It does nothing to any other flag type.
5. If the bundle no longer exceeds the order value, normal resolution is allowed.
6. It does not take the bundle advisory lock. This avoids inverting the established summary-row -> advisory-lock order. A concurrent summary change that creates/recreates a breach is governed by the INSERT/UPDATE breach triggers below.

Consequences:

- Save correction continues to save header/OCR corrections normally.
- Unrelated review flags continue to resolve exactly as the existing RPC intends.
- The bundle breach alone survives while the financial breach still exists.
- The existing match-decision view therefore continues to keep the invoice in the exceptions queue and block normal supplier approval.
- The header-save RPC itself is not narrowed, replaced or rewritten.

## Financial-summary update hole

The existing `flag_order_bundle_limit_after_summary_v1()` trigger runs after an operator financial-summary **insert**.

A later established workflow can change the existing `supplier_invoice_financial_summary.invoice_total_gbp` row. The same bundle breach must not be bypassed merely because the row was updated rather than inserted.

Add one narrow **AFTER UPDATE OF invoice_total_gbp** trigger on `supplier_invoice_financial_summary` that:

1. recalculates the same existing active bundle;
2. acts only for an `original` order;
3. if the bundle exceeds the current order value by more than £0.01, ensures an open `order_bundle_limit_breach` exists for the changed supplier invoice;
4. uses genuine existing operator provenance only: first the updated/previous summary's `entered_by_operator_id`, then an existing review flag's real `raised_by_operator_id` for that same supplier invoice;
5. never invents or substitutes a staff user as the operator raiser;
6. if a new breach must be created but no genuine operator provenance exists, fails closed and rolls the summary total update back with an explicit error rather than violating the review-flag audit contract;
7. does not alter other review flags;
8. does not change invoice values, order values, funding, progression or approval state.

The normal operator-upload path already creates the financial-summary row with `entered_by_operator_id`; the established supervisor adjustment upsert updates that same unique row. Therefore ordinary current workflow retains real operator provenance. The fail-closed branch exists only for anomalous/historical rows that lack it.

The existing insert trigger remains unchanged.

## Dedicated price-increase action

The price-increase control belongs on the Supplier Invoice Review card that already has the genuine open `order_bundle_limit_breach`.

Show only:

```text
Current order value
Current active supplier bundle
Additional funding required
[Approve order price increase]
```

The UI may calculate/display the active bundle from the same existing financial-summary rows, but the browser never supplies the new order amount to the write RPC.

Do not modify Save, Reject, Exclude, OCR, reconciliation or invoice-evidence actions.

## Dedicated price-increase RPC

Add one new RPC:

```text
public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_review_notes text default null
)
```

It must:

1. require an authenticated active `admin` or `supervisor`;
2. take the supplier invoice id only as the genuine breach provenance / review-card anchor, never as a monetary authority;
3. use the following lock order to avoid deadlock with the existing adjustment upsert and supplier-invoice review paths: lock existing financial-summary rows for the order deterministically, then active supplier-invoice rows deterministically, then acquire the existing `order_bundle_limit:<order_id>` advisory lock, then lock the order row, then lock the exact open breach flag;
4. require `orders.order_type = 'original'`;
5. require `orders.content_locked_at IS NULL` and never bypass `public.enforce_order_locks()`;
6. fail after established terminal boundaries: completed/terminal order, accounting release ready, or VAT release/reporting already approved;
7. require an open/under-review `order_bundle_limit_breach` for exactly `p_supplier_invoice_id` and `p_order_id`;
8. recalculate the current active bundle server-side from `supplier_invoice_financial_summary.invoice_total_gbp` using the existing retired-status exclusions;
9. require the recalculated bundle to exceed the current order value by more than £0.01;
10. set the new GBP order value to that exact recalculated bundle; never decrease and never no-op;
11. accept **no browser-supplied new amount**;
12. fail closed for non-zero `markup_applied_gbp` in v1 because the established funding authorities use different markup thresholds;
13. fail closed if the target order's event-ledger funding and `order_funding_position_vw` materially disagree before amendment; do not repair historical drift;
14. fail closed if the order has any `funding_reversed` history;
15. fail closed if existing order-sourced overfunding credit or active pending/confirmed funding-surplus state could be invalidated;
16. preserve quote economics: when old GBP total and `quote_total_ghs` are positive, calculate `new quote_total_ghs = round((old quote_total_ghs / old GBP total) * new GBP total, 2)`;
17. fetch no new FX rate and leave locked FX/card-markup fields untouched;
18. update only `orders.order_total_gbp_declared`, the proportionately derived `quote_total_ghs`, and normal update timestamp/audit effects;
19. create no funding event;
20. call the existing `recompute_order_platform_funded(order_id)` so the genuine new funding gap and `funded_at` become truthful;
21. call the existing `sync_order_overfunding_credit(order_id)` only after the fail-closed reversal/overfunding/surplus preconditions prove it is safe; with the new order value higher than the old value and no order-sourced overfunding credit, this is expected to be a no-op but keeps the established synchronisation authority intact;
22. verify the amendment did not create/remove a funding event and that the resulting funding position matches the expected new gap;
23. resolve only open/under-review `order_bundle_limit_breach` flags for that order **after** the order value has been increased; the self-protection trigger will then allow resolution because the breach no longer exists;
24. return old total, new total, increase, funding total, resulting funding gap, funded_at and derived `quote_total_ghs`.

## Funding and supplier-payment result

For the clean example:

```text
before amendment
order value      £720
funding          £720
funding gap        £0
funded_at        populated

immediately after amendment
order value      £740
funding          £720
funding gap       £20
funded_at        NULL

ordinary DVA top-up
+£20

then
funding          £740
funding gap        £0
funded_at        restored by existing logic
```

No new funding mechanism is created.

Existing supplier-payment provenance naturally moves from:

```text
£720 funding - £600 previous supplier OUT = £120 available
```

to:

```text
£740 funding - £600 previous supplier OUT = £140 available
```

after the ordinary £20 top-up.

## Build 4 / VAT / downstream behaviour

Build 4 already targets `orders.order_total_gbp_declared`; it therefore naturally follows the amended £740 target. No Build 4 patch is authorised.

The order-value edit itself is not a VAT funding event or sales tax point. The later genuine £20 funding event follows existing VAT/funding treatment.

Existing downstream `funded_at` gates may block while the customer genuinely owes £20. That is truthful and must not be bypassed.

## Sequential later increase

After £720 -> £740, a later supplier-summary change that takes the active bundle to £750 must create/retain a fresh genuine `order_bundle_limit_breach`. The same governed action may then approve £740 -> £750.

## Regression requirements

At minimum prove:

1. existing header-save RPC fingerprint is unchanged;
2. existing supplier-approval RPC definition is unchanged;
3. existing bundle INSERT trigger/function is unchanged;
4. existing readiness helper behaviour is unchanged;
5. normal non-breach invoice routing/approval is unchanged;
6. £720 order / £740 active summary bundle creates or has an open breach flag;
7. Save correction may resolve other flags but cannot resolve that breach while £740 > £720;
8. because the breach remains open, existing match-decision routing keeps the invoice on Supplier Invoice Review and existing supplier approval remains blocked;
9. a financial-summary UPDATE that newly creates a breach raises the same flag using genuine operator provenance;
10. a breach-creating summary UPDATE with no genuine operator provenance fails closed rather than inserting a falsely attributed flag;
11. raw over-limit data without a genuine open breach flag cannot call the price RPC;
12. replacement-child order cannot call the price RPC;
13. browser cannot supply the new total;
14. price RPC lock order is summary rows -> supplier invoice rows -> bundle advisory lock -> order -> exact breach flag;
15. content-locked / terminal / accounting/VAT-released order fails without mutation;
16. funding-authority mismatch, non-zero markup, funding reversal, incompatible overfunding or active surplus fails without mutation;
17. clean £720 -> £740 update proportionately preserves `quote_total_ghs` economics and leaves locked FX/card fields untouched;
18. amendment creates no funding event;
19. existing recompute produces £20 gap and clears `funded_at`;
20. safe existing overfunding synchronisation does not create a credit in this increased-baseline case;
21. only bundle-breach flags resolve after the new £740 baseline is committed; unrelated flags remain;
22. ordinary £20 DVA top-up restores £740 funded state;
23. existing supplier-payment source permits £140 after the prior £600 allocation;
24. Build 4 target becomes £740 with no Build 4 code change;
25. later £750 summary update creates a fresh governed breach;
26. protected funding, DVA, supplier-payment, Build 4, Sage, VAT, shipping, tracking, replacement and Mini-build fingerprints remain unchanged.

## Scope lock

Authorised implementation is limited to:

- this corrected governing addendum;
- one self-protecting bundle-breach flag trigger/function;
- one financial-summary UPDATE breach trigger/function;
- one dedicated server-derived price-increase RPC;
- one small Supplier Invoice Review price card/action wired only from the existing open breach flag;
- focused regression coverage.

No new order-level commercial authority, no custom queue-retention model, no global supplier-approval transition trigger, no accepted-gross replacement hierarchy, and no shared approval-readiness rewrite are authorised.
