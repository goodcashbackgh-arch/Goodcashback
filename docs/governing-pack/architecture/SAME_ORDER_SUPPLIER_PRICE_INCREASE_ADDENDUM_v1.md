# Same-Order Supplier Price Increase Addendum v1

Status: governing corrective addendum

## Purpose

Allow a supervisor/admin to increase the accepted GBP value of an existing **original** order when the live accepted supplier-invoice bundle has genuinely risen above the order value, without creating a new order or changing the established supplier-invoice header correction, funding, supplier-payment, reconciliation, VAT, Sage, replacement or shipment workflows.

Example:

```text
accepted order value                         £720.00
already funded                               £720.00
already purchased / supplier OUT             £600.00
live accepted supplier invoice bundle        £740.00
additional customer funding required          £20.00
```

The controlled result is:

```text
order value £720.00 -> £740.00
customer becomes genuinely £20.00 underfunded
ordinary DVA top-up supplies the £20.00
existing supplier-payment proof then permits the remaining £140.00
```

## Non-negotiable preservation rule

This build must **not modify** the existing supplier invoice header-review RPC:

```text
public.staff_save_supplier_invoice_header_review(...)
```

Its current behaviour, including its existing review-flag resolution behaviour, remains untouched.

This build must also **not rewrite or narrow** the existing supplier-invoice approval RPC:

```text
public.staff_approve_supplier_invoice_current(...)
```

Existing approval/finalisation callers remain unchanged. A new additive database guard protects their final approval state transition instead.

## Governing authority: live accepted numbers, not review flags

`order_bundle_limit_breach` remains useful review/routing evidence, but it is **not** the financial authority for this build.

The authoritative question is always recalculated from live accepted supplier invoice values:

```text
live accepted supplier bundle > orders.order_total_gbp_declared + £0.01
```

A cleared, missing or stale review flag must never make a real over-limit position approvable.

Likewise, a historical flag must not force a price increase after the live accepted bundle no longer exceeds the order value.

## Accepted supplier gross source

Do not invent a second supplier-total hierarchy.

Reuse the existing accepted gross authority already exposed by:

```text
public.supplier_invoice_accounting_coding_totals_vw.accepted_invoice_gross_gbp
```

That existing hierarchy is:

```text
supplier_invoices.ocr_invoice_total_gbp
-> raw OCR total_amount
-> supplier_invoice_financial_summary.invoice_total_gbp
```

Therefore a legitimate supervisor header correction automatically changes the live order price position without changing the operator-entered financial-summary row.

Only live supplier invoices participate. Exclude existing retired statuses:

```text
rejected_resubmit_required
duplicate_blocked
superseded
```

## New read-only order price position

Add one read-only order-level position source that exposes at least:

```text
order_id
order_type
current_order_value_gbp
accepted_supplier_bundle_gbp
price_increase_required_gbp
over_limit_yn
active_invoice_count
missing_accepted_total_count
review_anchor_supplier_invoice_id
```

Rules:

1. `over_limit_yn` is true only when the accepted live bundle is more than the order value by greater than £0.01.
2. Null/missing accepted totals must be counted explicitly; they must not be silently treated as proven zero for the write action.
3. The review anchor is the newest live `pending_review` supplier invoice for that order, using deterministic `uploaded_at DESC, id DESC` ordering.
4. Replacement-child orders may appear read-only for diagnostics, but cannot use the price-increase write action.

## Supplier Invoice Review queue behaviour

`/internal/invoice-review` remains an exceptions queue.

Its established normal behaviour remains:

```text
retailer match + reference match + total match + usable OCR lines + no blocker
-> invoice routes away from Supplier Invoice Review
```

The only new exception is:

```text
original order has a live over-limit price position
AND this invoice is that order's review anchor
-> keep that invoice visible in Supplier Invoice Review
```

This is required even if ordinary header review has resolved every review flag and the normal three-variable matching has become clean.

Do not keep every sibling invoice visible. Keep one deterministic anchor so the queue is not duplicated or cluttered.

On the anchor card show a dedicated section:

```text
Current order value:             £720.00
Current accepted supplier bundle £740.00
Additional funding required:      £20.00
[Approve order price increase]
```

Do not place this action on the separate delivery/discount adjustments page.

Do not disable or change `Save correction`, `Reject`, `Exclude`, OCR controls, invoice evidence links or reconciliation links.

If the live price-position query itself fails, the page must fail safe for visibility: do not offer the price-increase write action from an unknown position, and do not silently treat the order as within limit.

## Existing approval UI readiness

The existing shared supplier-invoice readiness helper may consume the new read-only position and return an additional blocker only when:

```text
order_type = original
AND live accepted supplier bundle > current order value + £0.01
```

Normal invoices at or below the accepted order value must return exactly their previous readiness result.

This keeps Supplier Draft Ready and reconciliation approval screens consistent before a user clicks an action.

## Database approval backstop

Add one additive database trigger/guard on the supplier-invoice transition into an approved/current unblocked state.

Do **not** edit the existing approval RPC.

When an original-order supplier invoice is being left in:

```text
review_status IN ('approved_current','ref_corrected_approved')
AND blocked_from_sage_yn = false
```

and that update creates or retains a live accepted supplier bundle above the current order value by more than £0.01, the transaction must fail closed.

The guard must calculate against the post-update accepted invoice value, so an approval call that supplies a corrected accepted total cannot approve using a stale pre-update bundle.

Replacement-child orders are excluded from this guard because their commercial/funding architecture is separate and their raw supplier bundle can legitimately exceed their own declared commercial value.

This backstop protects existing single-invoice approval, reconciliation approval and any order-level finaliser that uses the established approved/current transition, without changing those working functions.

## Dedicated price-increase RPC

Add one new RPC only, for example:

```text
public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
  p_review_notes text default null
)
```

It must:

1. Require an authenticated active `admin` or `supervisor`.
2. Lock the active supplier-invoice rows deterministically before locking the order row, so it does not invert the existing invoice-approval lock order.
3. Require `orders.order_type = 'original'`.
4. Require `orders.content_locked_at IS NULL`. Never bypass `public.enforce_order_locks()`.
5. Reject archived/cancelled/completed orders and any established hard terminal boundary already represented on the order.
6. Recalculate the live accepted supplier bundle server-side. The browser never supplies the new order value.
7. Require `missing_accepted_total_count = 0`.
8. Require the recalculated bundle to exceed the current order value by more than £0.01. Never decrease and never perform a no-op.
9. Fail closed if the target order's established funding-event position and live funding-position view materially disagree before amendment; do not repair historical drift in this build.
10. Fail closed if non-zero order markup would make the two established funding-threshold authorities diverge. This v1 does not redesign markup funding semantics.
11. Fail closed if existing order-sourced overfunding credit, consumed credit or pending-surplus state would be invalidated by the amendment. Do not invent credit reversal logic.
12. Set the new GBP order value to the exact server-recalculated accepted supplier bundle.
13. Preserve the stored quote economics. If both the old GBP order value and `quote_total_ghs` are positive, derive the new `quote_total_ghs` proportionately from the existing stored effective local quote rate:

```text
existing effective quote rate = old quote_total_ghs / old order_total_gbp_declared
new quote_total_ghs = round(new order total * existing effective quote rate, 2)
```

14. Do not fetch a new FX rate and do not change existing locked FX/card-markup fields.
15. Update `orders.order_total_gbp_declared` and the derived `quote_total_ghs` in the same transaction.
16. Do not create an order funding event merely because the accepted order value changed.
17. Call the existing `recompute_order_platform_funded(order_id)` so `funded_at` and the event-ledger gap become truthful immediately.
18. Call the existing overfunding synchronisation only when the preconditions prove that doing so cannot invalidate consumed credit history.
19. Resolve any still-open `order_bundle_limit_breach` flags for the order after the new baseline covers the current bundle. Do not resolve unrelated review flags.
20. Return old value, new value, increase amount, resulting funding gap and derived local quote total for UI confirmation.

## Expected funding behaviour

For the clean example:

```text
before amendment
order value                 £720.00
funding                     £720.00
funding gap                   £0.00
funded_at                    populated

immediately after amendment
order value                 £740.00
funding                     £720.00
funding gap                  £20.00
funded_at                    NULL

ordinary DVA top-up
+£20.00 funding contribution

then
funding                     £740.00
funding gap                   £0.00
funded_at                    restored by existing funding logic
```

The £20 top-up remains ordinary DVA order funding. No new funding lane is introduced.

## Supplier payment and reconciliation

Do not modify supplier-payment source resolution or allocation logic.

Existing provenance should naturally move from:

```text
£720 funding - £600 prior supplier OUT = £120 available
```

to:

```text
£740 funding - £600 prior supplier OUT = £140 available
```

after the customer's ordinary £20 top-up.

Do not modify Build 4 reconciliation. Its target already follows `orders.order_total_gbp_declared`, so the target naturally becomes £740 after the governed amendment.

## VAT, Sage, shipping, tracking and replacement boundaries

The order-value amendment itself is not a VAT funding event or sales tax point.

Do not change:

- VAT timing/source generation
- Sage supplier or customer posting primitives
- supplier payment allocation
- DVA reconciliation
- customer/importer funding machinery
- Build 4 reconciliation
- Mini-builds 1-4
- shipping
- tracking
- physical receipt/remedy controls
- replacement-child funding architecture
- customer review/hold architecture
- final-sale settlement governance

Existing downstream guards that depend on genuine `funded_at` may block while the customer owes the extra amount. That is truthful and must not be bypassed.

## Sequential increases

A later supplier total increase must work naturally.

Example:

```text
order amended £720 -> £740
later accepted supplier bundle becomes £750
```

The live position becomes over-limit again, the newest pending review anchor remains visible, approval is blocked again, and a fresh governed £740 -> £750 amendment can be approved.

## Required regression checks

1. Original order £720, accepted supplier bundle £740 -> live position shows £20 increase required.
2. Same raw position on `replacement_child` -> no price-increase write action and no new approval guard block.
3. Header Save remains byte-for-byte/function-definition unchanged by this build.
4. Existing supplier approval RPC remains byte-for-byte/function-definition unchanged by this build.
5. Normal clean invoice at/below order value has identical routing/readiness/approval behaviour.
6. Three normal match variables becoming clean does **not** remove the review anchor while the live order remains over-limit.
7. Saving a header correction may resolve flags, but the live over-limit anchor remains visible.
8. A corrected accepted invoice gross immediately changes the live order price position through the existing accepted-gross hierarchy.
9. Supplier Draft Ready and reconciliation approval show the live over-limit blocker before action.
10. Direct/canonical transition to approved/current while over-limit is rejected by the database backstop.
11. Automatic/order-level finalisation cannot bypass the backstop.
12. Price-increase RPC ignores browser-supplied amounts because no amount parameter exists.
13. Content-locked order fails without mutation.
14. Non-original order fails without mutation.
15. Missing accepted supplier total fails without mutation.
16. No-op/decrease fails without mutation.
17. Funding-authority mismatch fails without mutation.
18. Non-zero markup fails closed in v1.
19. Incompatible overfunding/consumed-credit/pending-surplus state fails without mutation.
20. £720 -> £740 proportionately updates `quote_total_ghs` while leaving locked FX/card-markup fields unchanged.
21. Amendment creates no funding event.
22. Existing recompute changes funded state to genuine £20 underfunding.
23. Ordinary £20 DVA funding restores the established funding state.
24. Existing supplier-payment provenance then permits £140 after prior £600 supplier payment.
25. Build 4 target follows £740 without a Build 4 code change.
26. A later £750 accepted bundle creates a fresh live breach and can be governed sequentially.
27. Existing Mini-build/Build 4 protected function/view fingerprints remain unchanged.

## Scope lock

Implementation is limited to:

- this governing addendum;
- one additive read-only live order supplier-price position;
- one additive supplier-approval transition backstop;
- one new dedicated price-increase RPC;
- the smallest invoice-review UI/action wiring required to retain the anchor and expose the dedicated approval;
- the smallest shared readiness addition required to present the same live blocker before existing approval actions;
- focused regression coverage.

No other existing RPC, view, trigger, workflow or page is authorised to change unless a failing regression proves an unavoidable dependency and the governing addendum is updated first.