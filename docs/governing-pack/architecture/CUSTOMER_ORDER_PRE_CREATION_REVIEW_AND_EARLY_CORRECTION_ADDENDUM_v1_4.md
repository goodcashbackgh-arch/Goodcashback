# Customer Order Pre-Creation Review and Early Correction Addendum v1.4

Status: governing corrective amendment to v1, v1.1, v1.2 and v1.3

## Purpose

Correct one governance mistake in the existing early-correction gate without changing the working customer-credit or funding engines.

A customer order that has only automatically applied account credit may remain eligible for early correction while it is still genuinely pre-funding and otherwise untouched.

This amendment also allows the collapsed `Correct order` disclosure to use the existing customer sky/blue palette so it is easy to find while remaining secondary to the primary order-status and payment content.

v1-v1.3 remain governing in every other respect.

## Live authority checked before this amendment

Read-only live verification on 13 August 2026 established:

- `public.customer_apply_available_credit_to_order_v1(uuid)` locks the order and the importer's unlocked credit ledger rows, writes `importer_credit_ledger` debit rows with `entry_type = 'applied_to_order'`, and writes matching `order_funding_events` rows with `event_type = 'credit_applied'`;
- `public.order_funding_position_vw` derives `applied_credit_gbp` from the existing `importer_credit_ledger` debit rows and derives `gap_remaining_gbp` and `threshold_met_yn` dynamically from the current order funding threshold;
- the canonical order status chain derives the accepted estimate directly from `orders.order_total_gbp_declared`, so a safe correction of that field is reflected by existing read models without mutating credit/funding rows;
- live data includes a `pending_dva_funding` order with only `credit_applied` funding activity, `funded_at IS NULL`, and a remaining cash gap; and
- live data also includes credit-only orders whose credit fully funded the order and whose `funded_at` is already stamped.

Therefore the safe seam is partial-credit-only correction. Fully funded/credit-funded orders remain outside this feature because changing their value would require funding-state recomputation and would cross into the existing funding engine.

## 1. Credit-only exception to the untouched-order gate

The v1 rule that every `order_funding_events` row blocks correction is amended narrowly.

The correction RPC may proceed when zero or more funding-event rows exist only if every row for the order has:

```text
event_type = 'credit_applied'
```

Any other funding event still blocks correction, including but not limited to:

```text
funding_contribution
manual_adjustment
overfunding_credit_created
```

Every other existing v1-v1.3 blocker remains unchanged, including status, locks, `funded_at`, tracking, invoice, reconciliation, evidence, holds, shipment, sales-invoice/accounting/VAT activity and replacement children.

`orders.funded_at IS NOT NULL` remains an absolute blocker.

## 2. Existing account credit is frozen during correction

The correction feature must not mutate, reverse, consume, release, replace or reapply account credit.

It must not call:

```text
public.customer_apply_available_credit_to_order_v1(uuid)
```

It must not insert, update or delete rows in:

```text
public.importer_credit_ledger
public.order_funding_events
public.dva_reconciliation
```

The already-applied credit remains exactly as it was before correction.

Example:

```text
order goods value     £100
already-applied credit £30
remaining due          £70

customer corrects goods value to £200
already-applied credit remains £30
remaining due becomes £170 through the existing read model
```

No additional available account credit is automatically consumed by the correction.

## 3. Fail closed before correction would require funding-state recomputation

Because the correction RPC deliberately does not mutate funding rows and does not invoke the funding engine, an amount correction must not turn a currently part-funded order into a fully funded order.

After the order row is locked, the correction RPC must read the canonical current funding position and, when the declared GBP amount changes and applied account credit is greater than zero, compute the proposed funding threshold using:

```text
proposed funding threshold = corrected order_total_gbp_declared + existing markup_applied_gbp
```

The correction must fail without mutation if the proposed remaining funding gap after existing applied credit would be `<= £0.01`.

This guard also fail-closes any inconsistent legacy row that is not stamped `funded_at` but would already be effectively fully covered by applied credit after the proposed correction.

The correction must not stamp, clear or recompute `funded_at` itself.

## 4. Quote economics remain unchanged

v1 quote economics remain governing.

Correction still:

- never fetches a new FX rate;
- never changes `quote_fx_rate`, `quote_card_markup_pct` or their locked fields; and
- recalculates only `quote_total_ghs` proportionately from the order's existing stored GBP/GHS ratio when the declared GBP amount changes.

The credit exception does not alter FX or quote authority.

## 5. Customer correction UI

The authenticated correction control remains advisory; the RPC remains final authority.

The client may treat `credit_applied` rows as non-blocking while continuing to hide itself for any other customer-readable funding activity.

When account credit is already applied, the expanded correction panel should tell the customer that the existing credit stays unchanged and that correcting the goods value changes only the remaining amount due.

The client may pre-check the same partial-credit boundary for immediate feedback, but the server-side RPC must independently enforce it.

### Discoverability

The collapsed `Correct order` disclosure remains a compact secondary action, but v1.3's neutral-only styling is superseded. It may use the existing sky/blue customer palette with white text so the control is visibly actionable without becoming a dominant full-width primary banner.

## 6. Working-part non-regression lock

This amendment does not authorise modification of any working credit/funding object, including:

```text
public.customer_apply_available_credit_to_order_v1(uuid)
public.internal_importer_available_account_credit_lots_v1(uuid)
public.customer_importer_credit_balance_v1()
public.order_funding_position_vw
public.recompute_order_platform_funded(...)
public.trg_recompute_order_platform_funded_from_event()
public.trg_sync_order_funding_event_from_importer_credit_ledger()
credit-ledger triggers
funding triggers
DVA reconciliation functions/triggers
```

It also does not authorise changes to customer/importer create-order actions, funding pages, tracking, invoice, reconciliation, shipment, Sage, VAT or accounting logic.

## 7. Migration boundary

The v1 migration and the already-applied v1.3 corrective migration remain historical and must not be edited or rerun.

Exactly one new v1.4 corrective migration is authorised. It may only:

- require the existing feature-owned `public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])` function and `public.order_funding_position_vw` to exist;
- `CREATE OR REPLACE` that feature-owned correction RPC;
- change its funding-event gate so only `credit_applied` rows are permitted;
- read the existing funding view to enforce the partial-credit boundary;
- preserve every v1.3 ownership, status/lock, downstream, quote-economics, Storage, screenshot-row and postcondition control;
- preserve existing security/search-path/execute privileges; and
- notify PostgREST schema reload.

It must not alter a table, trigger, RLS policy, credit/funding function, funding view or any adjacent workflow object.

## 8. Authorised source delta

Only these files are authorised by v1.4:

1. this governing v1.4 amendment;
2. `app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx`;
3. `supabase/migrations/20260813201500_customer_order_early_correction_v1_4.sql`;
4. `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs`.

No other runtime file is authorised to change.

## 9. Required regression additions

Before merge, prove at minimum:

1. an otherwise untouched `pending_dva_funding` order with only partial `credit_applied` funding remains correctable;
2. £100 goods value with £30 already-applied credit may be corrected to £200 without changing the £30 credit rows;
3. the existing funding read model then reports the increased remaining gap rather than auto-consuming more credit;
4. the correction RPC does not call the auto-credit RPC or mutate credit/funding/DVA rows;
5. any non-`credit_applied` funding event still blocks correction;
6. `funded_at IS NOT NULL` still blocks correction;
7. an amount correction that would leave a funding gap of `<= £0.01` after existing applied credit fails atomically;
8. quantity-only and screenshot-only correction remain allowed for an otherwise eligible partial-credit order because they do not change the funding threshold;
9. all v1.3 Storage, screenshot replacement and postcondition controls remain unchanged;
10. stored quote economics remain proportional and no FX lookup is introduced;
11. the collapsed `Correct order` control uses a visible sky/blue secondary-action treatment; and
12. customer/importer create actions and every existing credit/funding function/view/trigger remain unchanged.

## Acceptance

The intended customer path is:

```text
Create order
→ existing account credit may auto-apply
→ if credit is only partial and no genuine processing has started, Correct order remains available
→ existing applied credit stays frozen
→ changing the goods value changes the remaining amount due through existing read models
→ no extra credit is consumed
→ any real funding/downstream activity, funded state, or correction requiring funding-state recomputation still blocks fail-closed
```
