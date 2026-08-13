# Customer Order Pre-Creation Review and Early Correction Addendum v1.4

Status: governing corrective amendment to v1, v1.1, v1.2 and v1.3

## Purpose

This amendment corrects the early-correction funding gate without changing the working customer-credit or funding machinery. An otherwise untouched `pending_dva_funding` order remains eligible when every existing funding event, if any, is `credit_applied`. This applies regardless of which legitimate existing credit writer produced the event and includes partially and fully credit-funded orders.

Credit itself stays frozen. Correction never applies, reverses, releases, reallocates or reapplies credit and never changes a credit or funding row. v1-v1.3 remain governing in every other respect.

## 1. Funding-event eligibility and unchanged downstream gates

After retaining the `orders` row `FOR UPDATE` lock, the correction RPC permits zero, one or multiple funding events only when every event has:

```text
event_type = 'credit_applied'
```

Any other event, including `funding_contribution`, `manual_adjustment`, `funding_reversed` or `overfunding_credit_created`, blocks correction. The RPC must not distinguish among legitimate existing writers of `credit_applied` events.

All v1-v1.3 ownership, `pending_dva_funding` status, content/tracking locks, invoice, reconciliation, evidence, hold, shipment, accounting/VAT, replacement-child, Storage and screenshot gates remain unchanged. Confirmed DVA funding or funded total beyond applied credit also remains a blocker.

`orders.funded_at IS NOT NULL`, `threshold_met_yn = true`, and a non-positive canonical gap are not blanket blockers until the RPC has determined whether the amount is changing and which correction path applies.

## 2. Three correction paths

The canonical funding position is `public.order_funding_position_vw`. The proposed position uses:

```text
proposed threshold = corrected order_total_gbp_declared + existing markup_applied_gbp
proposed gap       = greatest(proposed threshold - existing funded_total_gbp, 0)
```

### 2.1 Ordinary unfunded or partial-credit correction

When the order is not fully/effectively funded, quantity, screenshot and amount corrections remain allowed if an amount change leaves a genuine canonical gap greater than £0.01. The RPC does not invoke funding recomputation on this path; the funding view derives the new gap naturally.

For example, £100 with £30 existing credit may increase to £200, leaving the £30 unchanged and deriving £170 due. It may decrease to £50 because £20 remains due. A decrease that would be completely covered by existing funding is rejected.

### 2.2 Fully/effectively credit-funded correction without an amount change

An order is previously fully/effectively funded when `funded_at IS NOT NULL`, `threshold_met_yn = true`, or its canonical gap is `<= £0.01`. Provided only `credit_applied` funding exists and all other gates are clean:

- a quantity-only correction is allowed; and
- a screenshot-only correction is allowed.

These paths do not invoke recomputation and preserve applied credit, funded total, funding events and `funded_at` exactly. The partial-order postcondition that the threshold must be false and the gap positive does not apply to them.

### 2.3 Fully/effectively credit-funded upward-value correction

An amount change on a previously fully/effectively funded order is allowed only when it is an actual increase and creates a genuine new funding gap. The corrected goods value itself must exceed the effective `credit_applied` event sum by more than £0.01, because `public.recompute_order_platform_funded(uuid)` uses the goods value rather than the view's markup-inclusive threshold. The proposed canonical gap must also exceed £0.01.

Immediately before calling recomputation, the RPC must fail closed unless the rounded `credit_applied` event sum equals the rounded canonical `applied_credit_gbp` within £0.01. This event-versus-ledger check is confined to this fully/effectively funded upward-value path; it is not a global correction requirement.

The RPC then updates only `total_qty_declared`, `order_total_gbp_declared`, proportional `quote_total_ghs`, and `updated_at`, and may call the existing unchanged:

```text
public.recompute_order_platform_funded(uuid)
```

It may only call that function; it must never create, replace or modify it, and it must never update `funded_at` directly. Thus £100 fully funded by £100 credit may increase to £200, after which the existing function clears `funded_at` and the canonical view derives £100 due.

The RPC must atomically re-read the order and canonical funding position and require that applied credit and funded total are unchanged, the credit-event sum and count are unchanged, `funded_at IS NULL`, `threshold_met_yn = false`, and the gap equals the expected proposed canonical gap within £0.01. Any failure raises and rolls back the transaction.

## 3. Corrections requiring credit release fail closed

A value correction that existing applied credit/funding would still completely cover is rejected because it would require financial-state repair, credit release or reallocation. For example, £100 fully funded by £100 credit cannot be reduced to £70. Customer correction creates no reversal mechanism.

The correction RPC must never call `public.customer_apply_available_credit_to_order_v1(uuid)` or `public.sync_order_overfunding_credit(...)`, and must never insert, update or delete rows in `public.importer_credit_ledger`, `public.order_funding_events` or `public.dva_reconciliation`.

## 4. Quote economics remain proportional

The existing v1/v1.3 calculation remains governing:

```text
new quote_total_ghs =
  old quote_total_ghs
  / old order_total_gbp_declared
  * corrected order_total_gbp_declared
```

Correction never queries `fx_rates` and never modifies `quote_fx_rate`, `quote_card_markup_pct` or locked quote fields. Customer-order markup is not inferred from separate quote-card economics.

## 5. Customer correction UI

The authenticated correction control remains advisory; the RPC remains final authority. The client may treat `credit_applied` events as non-blocking, but an existing advisory blocker for fully funded orders would now conflict with this governing rule and requires its own separately scoped UI correction. No UI file is authorised to change in this task.

The existing sky/blue collapsed `Correct order` treatment remains governed by v1.4's authorised source boundary.

## 6. Working-part non-regression lock

No definition or behaviour of any working credit/funding object is authorised to change, including credit-application RPCs, `internal_importer_available_account_credit_lots_v1`, `customer_importer_credit_balance_v1`, `importer_credit_ledger`, `order_funding_events`, `order_funding_position_vw`, `recompute_order_platform_funded`, credit/funding triggers, DVA reconciliation, or `sync_order_overfunding_credit`.

Customer/importer create actions, FX, tracking, supplier invoices, reconciliation, shipping, Sage, VAT/accounting, RLS, schema and lifecycle/status definitions also remain frozen.

## 7. Migration boundary

The v1 migration and already-applied v1.3 migration remain historical and must not be edited or rerun. The editable, unapplied v1.4 migration may only:

- require the existing correction RPC, `order_funding_position_vw`, and `recompute_order_platform_funded(uuid)` to exist;
- verify the v1.3 Storage/postcondition/security boundary;
- replace only the feature-owned correction RPC;
- implement the three correction paths and their atomic assertions;
- preserve all v1.3 ownership, downstream, quote, Storage, variable whole-set screenshot replacement and security controls; and
- notify PostgREST to reload its schema.

It must not add or alter tables, views, triggers, policies, credit/funding functions or adjacent workflow objects.

## 8. Authorised source delta

The four-file v1.4 authorised source boundary remains unchanged:

1. this governing v1.4 amendment;
2. `app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx`;
3. `supabase/migrations/20260813201500_customer_order_early_correction_v1_4.sql`;
4. `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs`.

This task changes only items 1, 3 and 4. No additional runtime file is authorised.

## Acceptance

Existing credit remains immutable. Ordinary partial-credit corrections let the canonical view derive the changed gap. Fully credit-funded quantity/screenshot-only corrections preserve funding state. Only a fully/effectively funded upward-value correction that creates both the required goods-value and canonical gaps may call the existing recomputation function to clear `funded_at`. Reductions or other corrections requiring credit release fail closed, while every non-credit funding event and existing downstream gate continues to block correction.
