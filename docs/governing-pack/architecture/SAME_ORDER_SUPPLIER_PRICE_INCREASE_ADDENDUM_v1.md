# Same-Order Supplier Price Increase Addendum v1

Status: governing corrective addendum

## Purpose

Allow an active supervisor/admin to increase the accepted GBP value of an existing **original** order when the platform's existing `order_bundle_limit_breach` proves that active supplier invoice totals exceed the accepted order value.

Example:

```text
order value                         £720.00
customer funding                    £720.00
supplier purchases already made     £600.00
active supplier invoice bundle      £740.00
extra customer funding required      £20.00
```

Governed result:

```text
order value £720.00 -> £740.00
funding remains £720.00
funding gap becomes £20.00
funded_at clears through existing funding logic
ordinary DVA top-up adds £20.00
existing supplier-payment proof then supports the remaining £140.00
```

## Preservation rule

This addendum is subordinate to the locked architecture/schema/orchestration/UI controls except for this narrow same-order amendment.

Do **not** replace or rewrite these existing authorities:

```text
public.staff_save_supplier_invoice_header_review(...)
public.staff_approve_supplier_invoice_current(...)
public.flag_order_bundle_limit_after_summary_v1()
public.order_funding_total_gbp(...)
public.order_funding_gap_gbp(...)
public.recompute_order_platform_funded(...)
public.sync_order_overfunding_credit(...)
public.internal_supplier_payment_readiness_v1(...)
public.internal_supplier_payment_bundle_source_v1(...)
public.staff_reconcile_dva_line_to_order(...)
public.staff_progress_supplier_invoice_lines(...)
```

Do not change Build 4, DVA, supplier-payment allocation, Sage, VAT, shipping, tracking, replacement-child, customer-review or settlement architecture.

## Existing breach flag remains authoritative

Entitlement to the new action requires:

```text
supplier_invoice_review_flags.flag_type = 'order_bundle_limit_breach'
status IN ('open','under_review')
```

A raw numerical `supplier bundle > order value` condition alone is **not** an entitlement.

The existing bundle arithmetic remains:

```text
SUM(supplier_invoice_financial_summary.invoice_total_gbp)
```

for invoices on the order excluding:

```text
rejected_resubmit_required
duplicate_blocked
superseded
```

Do not substitute OCR gross, accounting accepted gross or a new commercial-total hierarchy.

## Supplier Invoice Review behaviour

`/internal/invoice-review` remains an exceptions queue.

The existing open bundle breach is already a serious flag in `supplier_invoice_match_decision_vw`; therefore it keeps the invoice in the existing review lane. No custom queue-retention model or order-level review anchor is authorised.

The existing retailer/ref/total routing remains unchanged.

## Save correction remains unchanged

`public.staff_save_supplier_invoice_header_review(...)` must remain unchanged.

It may continue its existing broad attempt to resolve open review flags. Add one narrow `BEFORE UPDATE` protection on `supplier_invoice_review_flags` for `order_bundle_limit_breach` only.

When an open/under-review bundle breach is being moved to `resolved`:

1. acquire the existing `order_bundle_limit:<order_id>` advisory lock;
2. recalculate the same active financial-summary bundle;
3. if the bundle no longer exceeds the order value, allow normal resolution;
4. if the bundle still exceeds the order value and the invoice remains pending/blocked, preserve this flag's previous open/under-review state and resolution fields while allowing the surrounding Save transaction to complete;
5. if the bundle still exceeds the order value and the invoice has already been moved to an approved/current or accounting-unblocked state in the same transaction, raise an exception so the entire supplier-approval transaction rolls back.

This gives two required behaviours without rewriting either existing RPC:

```text
Save correction + live breach -> Save succeeds, breach stays open
Supplier approval + live breach -> approval transaction fails/rolls back
```

The same advisory lock also serialises Save-vs-summary-total changes so the breach cannot disappear between concurrent transactions.

## Financial-summary UPDATE hole

The established bundle trigger covers operator financial-summary **INSERT**. The current supervisor adjustment workflow may later update that same unique summary row.

Add one narrow `AFTER UPDATE OF invoice_total_gbp` trigger that:

1. does nothing when the total did not change;
2. acts only for literal `orders.order_type = 'original'`;
3. ignores retired invoice versions using the same exclusions as the existing trigger;
4. acquires the existing bundle advisory lock;
5. recalculates the same financial-summary bundle;
6. if the bundle exceeds the current order value and no open bundle breach exists for the changed invoice, creates that same flag;
7. uses only genuine existing operator provenance from the current/previous unique summary row, with existing review-flag provenance as fallback;
8. never invents a staff/operator identity;
9. if a new breach must be created but genuine operator provenance is absent, fails closed rather than writing false audit provenance;
10. changes no invoice status, order value, funding, progression or accounting state.

No new companion INSERT trigger is authorised because the established operator-upload INSERT trigger remains the current creation path. This UPDATE companion closes only the proven later-upsert hole.

## Dedicated UI action

On an invoice card with a genuine open bundle breach, and only for literal `order_type = 'original'`, show:

```text
Current order value
Current active supplier bundle
Additional funding required
[Approve order price increase]
```

The UI may display the same financial-summary bundle but cannot submit a monetary amount.

The server action sends only:

```text
order_id
supplier_invoice_id
optional review note
```

Do not modify existing Save, Reject, Exclude, OCR or reconciliation actions.

## Dedicated RPC

Add only:

```text
public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_review_notes text default null
)
```

It must:

1. require an authenticated active `admin` or `supervisor`;
2. require literal `orders.order_type = 'original'` — NULL or any other type fails closed;
3. require the exact open/under-review `order_bundle_limit_breach` for the supplied invoice/order;
4. require that invoice to remain an active invoice on that order;
5. use this lock order: existing summary rows for the order deterministically → supplier-invoice rows deterministically → exact open breach flag → existing `order_bundle_limit:<order_id>` advisory lock → order row. This matches the existing Save/summary-update paths and avoids the flag/advisory inversion deadlock;
6. derive the new amount server-side from the same active `supplier_invoice_financial_summary.invoice_total_gbp` bundle;
7. accept no browser-supplied amount;
8. only increase; no decrease or no-op;
9. respect `content_locked_at` and never bypass `public.enforce_order_locks()`;
10. fail after completed/terminal, accounting-release-ready or VAT-release/reporting boundaries;
11. fail closed for non-zero `markup_applied_gbp` in v1;
12. fail closed for funding-authority disagreement, funding-reversal history, existing order-sourced overfunding credit or active pending/confirmed funding-surplus state;
13. preserve stored quote economics by proportionately changing `quote_total_ghs` using the old stored effective GBP→GHS ratio; fetch no new FX rate and change no locked FX/card fields;
14. update only the order GBP total, proportionately derived `quote_total_ghs`, and normal `updated_at`/audit effects;
15. create no funding event;
16. call existing `recompute_order_platform_funded(order_id)`;
17. call existing `sync_order_overfunding_credit(order_id)` only after the fail-closed safety checks above;
18. do not lock funding rows merely for this amendment; if concurrent funding changes make before/after postconditions inconsistent, fail/rollback and allow retry rather than introducing a DVA lock-order dependency;
19. verify funding-event count is unchanged and resulting funding position matches the expected new gap;
20. resolve only open/under-review `order_bundle_limit_breach` flags for the order after the new baseline is committed;
21. leave unrelated review flags untouched.

## Existing downstream result

No new funding mechanism is created.

For the clean example:

```text
£720 order + £720 funding
-> approve price £740
-> £20 funding gap / funded_at NULL
-> normal £20 DVA top-up
-> £740 funded / funded_at restored
-> existing supplier-payment provenance sees £740 - £600 = £140 available
```

Build 4 already reads `orders.order_total_gbp_declared`; it follows £740 naturally. No Build 4 patch is authorised.

The order-value change itself is not a VAT funding/sales event. The later genuine £20 funding event follows existing VAT treatment.

## Sequential increase

A later genuine summary change taking the bundle from £740 to £750 must produce/retain a fresh open bundle breach. The same governed action may then approve £740 -> £750.

## Required regression

Before merge, prove at minimum:

1. existing header-save RPC unchanged;
2. existing supplier-approval RPC unchanged;
3. existing bundle INSERT trigger/function unchanged;
4. shared approval-readiness helper unchanged;
5. normal non-breach review routing unchanged;
6. Save correction can complete while a live bundle breach remains open;
7. direct supplier approval cannot commit while that live breach exists;
8. concurrent Save/summary-total paths serialize on the existing bundle lock so no live breach is silently lost;
9. summary total UPDATE can create the existing bundle breach with genuine operator provenance;
10. raw over-limit data without a genuine open flag cannot call the price RPC;
11. replacement/NULL/non-original order type cannot call the price RPC;
12. browser cannot supply the new total;
13. clean £720 -> £740 amendment preserves quote economics and creates no funding event;
14. recompute produces the £20 gap and clears `funded_at`;
15. only bundle-breach flags resolve after amendment;
16. normal £20 DVA top-up restores full funding;
17. existing supplier-payment source then supports £140 after prior £600;
18. Build 4 target becomes £740 without Build 4 code changes;
19. later £750 breach/amendment remains possible;
20. content lock, terminal boundaries, funding drift, reversal, markup, overfunding and surplus cases fail without mutation.

## Scope lock

Authorised changed-file/runtime scope is limited to:

- this addendum;
- one primary migration containing the two narrow trigger functions/triggers and one dedicated RPC;
- `app/internal/invoice-review/page.tsx` for the flag-gated card/read-only display;
- one dedicated `price-actions.ts` server action;
- focused regression files.

No new commercial read model, no global supplier-approval transition trigger, no shared readiness rewrite, no existing RPC replacement, no DVA/Build4/payment/VAT/Sage/replacement change, and no superseded/no-op migration files are authorised.
