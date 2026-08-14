# Customer Order Pre-Creation Review and Early Correction Addendum v1.4

Status: governing corrective amendment to v1, v1.1, v1.2 and v1.3

## Purpose

This amendment corrects the early-correction funding gate without changing the working customer-credit or funding machinery. An otherwise untouched `pending_dva_funding` order remains eligible when every existing funding event, if any, is `credit_applied`. This applies regardless of which legitimate existing credit writer produced the event and includes partially and fully credit-funded orders.

Credit itself stays frozen. Correction never applies, reverses, releases, reallocates or reapplies credit and never changes a credit or funding row. v1-v1.3 remain governing in every other respect.

This amendment is also the governing authority for the post-install access and UI integration correction described in sections 5-8. The already-installed v1.4 database behaviour proven by rollback simulation is frozen except for the narrowly authorised order-specific access-resolution correction. No financial rule may be reopened as part of that work.

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

## 5. Order-specific access resolution

The order being corrected is the authority for importer scope. Neither the UI nor the RPC may select an operator's latest importer assignment and treat that row as the active importer for every order.

The correction RPC must resolve access in this order:

1. resolve the active operator from `auth.uid()`;
2. lock and load the requested order by `p_order_id`;
3. require `order.operator_id = active operator.id`;
4. require a non-revoked `operator_importers` row for that exact `operator_id` and the loaded `order.importer_id`; and
5. only then continue into the existing correction gates and mutation logic.

An operator having additional active importer assignments, including a newer assignment, must not make an otherwise owned order inaccessible. A revoked assignment must not grant access. Wrong-operator ownership remains a blocker.

This is an access-resolution correction only. It must not change any funding, quote, screenshot, downstream-processing, postcondition or mutation rule.

## 6. Customer correction UI: one authoritative eligibility contract

The correction RPC is the single authoritative eligibility and mutation contract. The browser must not independently reproduce the complete backend blocker graph by directly querying internal funding, tracking, invoice, child-order or other downstream tables and then silently deciding whether the control exists.

The customer UI may load only the order fields needed to render the existing correction form and to make an eligibility probe. Eligibility is checked by calling the existing correction RPC with the order's current quantity, current goods value and `NULL` replacement screenshots. The existing RPC no-op path is authoritative: after authentication, ownership and every blocker check passes, it returns `changed = false` without changing the order.

The UI state contract is:

- `loading`: eligibility has not yet resolved;
- `eligible`: the no-op RPC succeeds, so the existing `Correct order` control is available;
- `blocked`: the RPC returns a recognised authoritative business blocker, so the UI shows a compact unavailable/disabled correction state with a customer-safe reason; and
- `check_failed`: authentication, transport, unexpected RPC error or other technical failure prevents a reliable eligibility decision, so the UI says correction availability could not be checked and offers refresh/retry behaviour.

A technical failure must never be presented as a business blocker, and no eligibility failure may disappear silently through a generic `return null` once the customer is already viewing an authorised order page.

The actual save path remains unchanged: the browser calls only `public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[])` for correction. The browser must not call credit application, credit reversal, funding recomputation, overfunding synchronisation, ledger mutation or funding-event mutation functions.

Client-side form validation may continue to provide immediate guidance for quantity, amount and attachment constraints, including the fully-funded upward-value rule, but it is advisory only. The RPC remains final authority for ownership, downstream state, funding consistency and all postconditions.

The existing sky/blue collapsed `Correct order` treatment remains the visual baseline. This amendment changes availability resolution and failure visibility, not the surrounding customer order journey, payment cards or lifecycle presentation.

## 7. Working-part non-regression lock

No definition or behaviour of any working credit/funding object is authorised to change, including credit-application RPCs, `internal_importer_available_account_credit_lots_v1`, `customer_importer_credit_balance_v1`, `importer_credit_ledger`, `order_funding_events`, `order_funding_position_vw`, `recompute_order_platform_funded`, credit/funding triggers, DVA reconciliation, or `sync_order_overfunding_credit`.

Customer/importer create actions, FX, tracking, supplier invoices, reconciliation, shipping, Sage, VAT/accounting, schema and lifecycle/status definitions also remain frozen.

RLS policies are not authorised to change merely to make the correction UI work. The integration must use the already-authorised customer order read surface plus the `SECURITY DEFINER` correction RPC as the authoritative eligibility/mutation boundary.

The already-installed v1.4 funding behaviour is frozen. The successful rollback simulations are the non-regression baseline:

- fully credit-funded decrease requiring credit release is rejected;
- fully credit-funded quantity-only correction succeeds with funding and `funded_at` preserved;
- fully credit-funded upward-value correction succeeds with credit/funding unchanged, proportional quote economics, `funded_at` cleared and the expected new gap; and
- partial-credit upward-value correction succeeds with existing credit/funding unchanged and the expected new gap.

Any implementation that changes those outcomes is outside this authority.

## 8. Forward migration and authorised source boundary

The v1 migration and already-applied v1.3 migration remain historical and must not be edited or rerun. The already-applied `20260813201500_customer_order_early_correction_v1_4.sql` is also historical and must not be edited, deleted, rerun or treated as an unapplied migration.

Any database correction required by section 5 must be delivered as one new forward migration. That migration may only:

- require the existing correction RPC and its v1.4 security boundary to exist;
- replace only `public.customer_correct_unprocessed_order_v1(uuid, integer, numeric, text[])`;
- change only the operator/importer access-resolution ordering described in section 5;
- preserve the installed v1.4 three correction paths, downstream gates, quote logic, Storage validation, screenshot replacement, funding assertions, recomputation call, grants and `search_path` security boundary exactly in behaviour; and
- notify PostgREST to reload its schema if required.

It must not add or alter tables, views, triggers, RLS policies, credit/funding functions or adjacent workflow objects.

The authorised implementation delta for this follow-up is limited to:

1. this governing v1.4 amendment;
2. `app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx`;
3. one new forward migration dedicated to the section 5 access-resolution correction; and
4. `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs`.

The installed `supabase/migrations/20260813201500_customer_order_early_correction_v1_4.sql` remains unchanged and is not part of the editable delta. No additional runtime file is authorised unless a concrete build failure proves it unavoidable and this governing amendment is updated first.

## 9. Required acceptance evidence before merge

The follow-up is not merge-ready until all of the following are true:

1. the existing rollback SQL simulation suite still passes the four installed v1.4 financial cases without changed funding or credit semantics;
2. a multi-importer authenticated SQL simulation proves an operator can correct an eligible owned order whose importer is not the operator's newest active assignment;
3. revoked importer assignment and wrong-operator ownership simulations fail closed;
4. the customer UI on an authorised clean order resolves to `eligible` and exposes `Correct order` without requiring direct browser reads of the internal blocker tables;
5. a recognised downstream/business blocker produces a visible customer-safe `blocked` state rather than silently hiding the component;
6. an injected or reproducible technical eligibility failure produces `check_failed`, not a false business blocker;
7. the existing static correction regression passes and proves that the browser performs no credit/funding mutation and only the correction RPC performs the correction write; and
8. repository/build deployment checks remain green.

## Acceptance

Existing credit remains immutable. Ordinary partial-credit corrections let the canonical view derive the changed gap. Fully credit-funded quantity/screenshot-only corrections preserve funding state. Only a fully/effectively funded upward-value correction that creates both the required goods-value and canonical gaps may call the existing recomputation function to clear `funded_at`. Reductions or other corrections requiring credit release fail closed, while every non-credit funding event and existing downstream gate continues to block correction.

Order access is resolved against the importer belonging to the requested order, not an arbitrary latest assignment. The RPC is the single eligibility and mutation authority. The customer UI must make eligible correction usable, make genuine blockers understandable, make technical failures distinguishable, and must not duplicate or weaken the backend's financial and lifecycle protections.
