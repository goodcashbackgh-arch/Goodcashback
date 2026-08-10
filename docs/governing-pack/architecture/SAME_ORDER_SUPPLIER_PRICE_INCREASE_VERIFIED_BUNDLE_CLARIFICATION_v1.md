# Same-Order Supplier Price Increase — Verified Bundle Clarification v1

Status: governing clarification to `SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md`

This clarification was frozen before implementation. It closes two dependency edges found during the pre-build audit and is authoritative wherever the parent addendum is ambiguous.

## 1. An over-limit number is not enough; the supplier bundle must be verified

The existing bundle warning can be raised from the operator-entered financial summary before OCR/header review is complete. Therefore an over-limit position alone must never expose an executable price-increase approval.

The order-level read position may show the live known bundle immediately, but the dedicated price-increase write is allowed only when every live supplier invoice contributing to the bundle is trustworthy for this purpose.

An already approved/current live supplier invoice is treated as verified by its established approval state.

A live `pending_review` supplier invoice is price-verified only when all of the following established document facts are true:

```text
retailer_match_yn = true
invoice_ref_match_yn = true
total_match_yn = true
ocr_line_count > 0
pending_adjustment_yn = false
```

and it has no open/under-review review flag other than:

```text
order_bundle_limit_breach
```

This deliberately does **not** require supplier-line progression, accounting coding or supplier-payment readiness. Price approval is a pre-purchase commercial control, not final supplier-invoice approval.

The read position should expose an `unverified_invoice_count` (or equivalent). The price-increase RPC must require it to be zero.

Consequences:

- a bad OCR total cannot inflate the order value;
- an unresolved wrong-invoice/header issue cannot inflate the order value;
- a pending delivery/discount decision cannot be bypassed by amending the order first;
- after ordinary header correction makes the document facts match, the same invoice can become price-verified without changing the header-review RPC;
- `order_bundle_limit_breach` itself is ignored for verification because this new action exists specifically to resolve the live commercial over-limit position.

## 2. Funding-reversal history fails closed in v1

The established canonical funding helper treats `funding_reversed` as a negative amount using `-ABS(amount)`, while the existing overfunding synchroniser has different historical summation semantics.

This build must not change either established function.

Therefore the dedicated price-increase RPC must fail closed if the target order has any existing:

```text
order_funding_events.event_type = 'funding_reversed'
```

This is in addition to the parent addendum's event-ledger/funding-view consistency check and its overfunding/consumed-credit/pending-surplus preconditions.

A future separately governed build can support reversal-history orders if needed after the funding authorities are deliberately reconciled.

## 3. `bundled_quote_gbp` remains untouched

The core system rules explicitly keep these fields separate:

```text
order_total_gbp_declared
markup_applied_gbp
estimated_shipping_gbp
actual_shipping_gbp
bundled_quote_gbp / bundled_final_gbp
```

Therefore this price-amendment build must **not** mirror the new order value into `bundled_quote_gbp` or `bundled_final_gbp`.

The only quote-side amount changed is `quote_total_ghs`, proportionately, for the specific stored-effective-rate dependency governed by the parent addendum.

## Additional regression requirements

1. Operator summary alone creates an over-limit read position before OCR, but executable price approval remains unavailable while the pending invoice is unverified.
2. Wrong retailer/ref/total, zero OCR lines, a non-bundle open review flag, or a pending delivery/discount adjustment keeps `unverified_invoice_count > 0` and the price RPC fails without mutation.
3. Resolving the ordinary header mismatch can make the pending invoice verified even if the bundle-limit flag was cleared by the untouched header-review RPC.
4. A clean verified bundle above the order value exposes the price action and can be amended.
5. Any `funding_reversed` history causes the price RPC to fail without mutation.
6. `bundled_quote_gbp` and `bundled_final_gbp` remain unchanged.