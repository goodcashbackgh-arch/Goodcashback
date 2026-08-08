# Deferred Pending Receipt Surplus Credit Resolution Addendum v1

**Status:** LOCKED corrective governing addendum for implementation.  
**Scope:** Platform-wide future behaviour for original customer receipt residuals that were left as `pending_evidence` at funding time and are only resolved after final-sale evidence is complete. No order-specific code. No backfill.  
**Relationship to existing contracts:** Additive only. Do not edit or reinterpret `docs/governing-pack/ui/CANONICAL_RECEIPT_RESIDUAL_SETTLEMENT_REPAIR_ADDENDUM_v1.md` or `docs/governing-pack/accounting/OUTBOUND_SUPPLIER_FX_SETTLEMENT_CLASSIFICATION_ADDENDUM_v1.md`.

## 1. Locked business rule

FX/card difference is a **funding-stage classification choice only** for an original customer receipt residual.

At initial funding:

- if staff explicitly chooses the existing FX route, the excess is classified there as FX;
- otherwise the excess is preserved as `pending_evidence`.

If the excess is left as `pending_evidence`, it **must not later become FX**.

Once final-sale evidence is complete, any proven positive remainder of that pending original receipt resolves **only as customer credit**.

No deferred/end-stage FX button, status, ledger type, accounting route or choice is introduced.

## 2. Correct pending-evidence calculation

Change only the **pending branch** of `public.order_surplus_evidence_position_v3`.

Current pending logic effectively uses:

```text
existing funding
+ pending original-receipt residual
- evidence value
```

Correct pending logic is:

```text
pending effective receipt
=
existing funding
+ pending original-receipt residual
+ confirmed final_balance_payment allocations
```

Then:

```text
pending evidence surplus
=
pending effective receipt
- evidence value
```

A final-balance payment contributes only where all of the following are true:

```text
allocation_type   = 'final_balance_payment'
allocation_status = 'confirmed'
order_id           = the order being evaluated
```

Nothing else is added to this pending-evidence equation.

In particular, do **not** add:

- inbound FX allocations;
- generic statement receipts;
- supplier-side FX;
- customer/importer credit;
- unconfirmed or reversed allocations.

Do not change order-funding totals.

### Controlled calculation

For the controlled state:

```text
GBP 600.00 existing funding
+ GBP 0.79 pending original-receipt residual
+ GBP 20.00 confirmed final-balance payment
= GBP 620.79 pending effective receipt

GBP 620.79
- GBP 620.00 final evidence value
= GBP 0.79 proven surplus
```

This calculation is locked.

### Compatibility requirement

For `pending_position_count = 0`, `order_surplus_evidence_position_v3` must remain observationally identical to current behaviour.

The existing evidence-status decision tree remains unchanged. Only the corrected pending effective-receipt and pending evidence-surplus values may feed that existing status logic.

Do not alter `order_surplus_evidence_position_v1` or `order_surplus_evidence_position_v2`.

The pre-implementation whole-database impact proof established:

- 90 evidence orders checked;
- 5 orders with pending positions;
- exactly 1 evidence amount changed;
- exactly 1 evidence status changed;
- 0 non-pending orders changed.

## 3. Existing credit-confirmation accounting remains unchanged

Do **not** alter the accounting logic inside:

`public.staff_confirm_surplus_from_evidence_min_v1(uuid,text,text)`

It remains authoritative for:

- deriving the credit amount from canonical evidence;
- creating the customer/importer credit;
- linking the resulting credit ledger row;
- transitioning the pending row to `credit_confirmed`;
- its existing validation and idempotence behaviour.

The existing RPC is not replaced.

## 4. New narrow orchestration wrapper

Add one new supervisor/admin RPC, conceptually:

`public.staff_confirm_pending_receipt_surplus_credit_v1(...)`

The wrapper must execute atomically and must:

1. authenticate and authorize through the established staff path;
2. locate and lock the relevant active pending-surplus row for the order;
3. return idempotently if a new-path provenance record already proves successful completion;
4. otherwise require the starting pending row status to be `pending_evidence`;
5. require corrected v3 evidence to be in an existing ready-surplus state;
6. call `staff_confirm_surplus_from_evidence_min_v1` unchanged;
7. re-read the pending row;
8. require `status = 'credit_confirmed'` and `confirmed_credit_ledger_id IS NOT NULL`;
9. write exactly one provenance row linking the original pending residual to the credit created by the existing RPC;
10. return success.

If any step fails, the transaction must roll back.

### Legacy guard

If a row was already historically `credit_confirmed` without new-path provenance, the wrapper must **not** create provenance retrospectively.

There is no backfill.

## 5. New provenance table

Add one small internal table, conceptually:

`public.order_pending_surplus_credit_resolution_provenance_v1`

Minimum columns:

```text
id uuid primary key
order_id uuid not null
pending_surplus_id uuid not null
confirmed_credit_ledger_id uuid not null
created_by_staff_id uuid not null
created_at timestamptz not null
```

Required uniqueness:

```text
UNIQUE (pending_surplus_id)
UNIQUE (confirmed_credit_ledger_id)
```

Required foreign keys must link to the existing order, pending-surplus, credit-ledger and staff records.

The provenance row records one fact only:

> This specific customer credit was created through post-evidence resolution of this specific original pending customer receipt residual.

It does **not** mutate, reverse or reclassify FX.

No historic rows are inserted.

## 6. Supplier-OUT FX overlap handling

The existing locked supplier-OUT attribution rules remain authoritative for determining whether a confirmed supplier-payment `fx_card_difference` is attributable to exactly one order.

Do not change those attribution rules.

Do not alter the physical supplier FX allocation.

The only permitted adjustment is to how much of an already-attributed supplier-OUT FX candidate remains eligible to participate in settlement classification **when new-path provenance proves that part of the same positive settlement difference has subsequently become customer credit**.

Define:

```text
G = gross_positive_difference_gbp

S = raw supplier-OUT FX candidate under the existing locked supplier attribution rules

P = total confirmed customer credit linked through the NEW provenance table

C = total confirmed customer credit

E0 =
  MAX(C - P, 0)
  + inbound_fx_receipt_residual_gbp
  + active explicit settlement-action FX
```

Calculate the supplier FX that could participate before the new pending-residual credit:

```text
supplier_needed_before_pending_credit
=
MIN(
  S,
  MAX(G - E0, 0)
)
```

Calculate the supplier FX still needed after the new pending-residual credit:

```text
supplier_needed_after_pending_credit
=
MIN(
  S,
  MAX(G - (E0 + P), 0)
)
```

The supplier-FX participation displaced specifically by the new pending-residual credit is:

```text
supplier_fx_overlap
=
MAX(
  supplier_needed_before_pending_credit
  - supplier_needed_after_pending_credit,
  0
)
```

Therefore the supplier FX still eligible to enter settlement classification is:

```text
eligible_supplier_fx
=
MAX(
  S - supplier_fx_overlap,
  0
)
```

### Critical compatibility property

If there is no new-path provenance credit:

```text
P = 0
```

then:

```text
supplier_fx_overlap = 0
eligible_supplier_fx = S
```

Therefore every legacy order without new-path provenance retains current supplier-FX settlement behaviour.

## 7. Controlled 79p settlement result

Before customer credit:

```text
G = GBP 0.79
S = GBP 0.79
P = GBP 0.00
E0 = GBP 0.00
```

The existing supplier FX may participate as GBP 0.79.

After the existing credit RPC creates GBP 0.79 customer credit and the wrapper writes new-path provenance:

```text
G = GBP 0.79
S = GBP 0.79
P = GBP 0.79
E0 = GBP 0.00
```

Before-credit supplier requirement:

```text
MIN(0.79, MAX(0.79 - 0.00, 0)) = GBP 0.79
```

After-credit supplier requirement:

```text
MIN(0.79, MAX(0.79 - 0.79, 0)) = GBP 0.00
```

Therefore:

```text
supplier_fx_overlap = GBP 0.79
eligible_supplier_fx = GBP 0.00
```

Final settlement classification must therefore remain:

```text
customer credit       GBP 0.79
eligible supplier FX  GBP 0.00
--------------------------------
total classified      GBP 0.79

gross difference      GBP 0.79
remaining             GBP 0.00
over-resolved         GBP 0.00
```

## 8. Settlement arithmetic remains locked

Do **not** change the established formulas for:

- `order_attributed_receipt_gbp`;
- `gross_positive_difference_gbp`;
- `total_classified_gbp`;
- `remaining_unresolved_gbp`;
- `over_resolved_gbp`;
- `resolution_status`.

Do not change how confirmed customer credit, inbound FX or explicit settlement-action FX are calculated.

Only the supplier-OUT FX **input contribution** may be reduced by the exact new-path overlap calculation above.

The underlying supplier FX remains a confirmed historical FX/payment-variance fact.

## 9. Physical supplier FX and Sage history are immutable

Absolutely no update, reversal, deletion or reclassification of confirmed supplier-side `fx_card_difference` allocations.

Do not change:

- the supplier-payment statement line;
- supplier-invoice allocations;
- FX amount;
- FX allocation status;
- source-line consumption;
- supplier-payment accounting;
- cash-posting eligibility;
- Sage mappings;
- existing Sage journal/posting state.

The overlap rule changes settlement interpretation only.

## 10. Funding-time FX remains unchanged

Do not alter:

`public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)`

Existing funding behaviour remains:

- receipt does not exceed funding gap -> established normal funding route;
- receipt exceeds funding gap and staff explicitly chooses FX -> established funding-time FX route;
- receipt exceeds funding gap and staff does not choose FX -> established pending-surplus route.

There is no second FX decision later.

## 11. UI scope

No visual redesign and no new FX action.

The existing pending-surplus action remains:

`Confirm customer credit`

For that pending-residual action only, the server action must call the new narrow orchestration wrapper instead of calling `staff_confirm_surplus_from_evidence_min_v1` directly.

The wrapper then invokes the existing confirmation RPC internally.

The generic incremental Settlement Resolution flow remains unchanged.

## 12. Explicitly untouched

This implementation must not change:

- order funding totals;
- funding threshold/gap logic;
- funding-time FX behaviour;
- final-balance-due formula;
- confirmed final-balance allocations;
- customer collectible formula;
- v1/v2 surplus-evidence models;
- accounting logic inside `staff_confirm_surplus_from_evidence_min_v1`;
- accounting logic inside `staff_resolve_order_settlement_v1`;
- established settlement arithmetic;
- physical DVA statement lines;
- supplier allocations;
- supplier invoices;
- customer sales invoices;
- Sage posting logic or posted documents;
- VAT;
- shipment;
- tracking;
- holds;
- disputes;
- retailer refunds;
- existing historical `credit_confirmed` rows;
- unrelated workbench behaviour;
- shipper behaviour.

No new financial ledger type, no new end-stage FX concept and no order-specific exception is permitted.

## 13. Migration requirements

Implementation must use a **new forward migration only**.

Do not edit already-applied historical migrations.

The migration must fail closed if required prerequisite objects or expected column/contracts have drifted.

Preserve:

- `order_surplus_evidence_position_v3` column names/order;
- existing grants;
- existing RPC signatures;
- `order_settlement_resolution_position_v1` column contract;
- downstream reader contracts.

Do not use bank narration/reference text as accounting classification authority.

## 14. Mandatory regression requirements

Implementation is not complete unless regression proves all of the following:

1. GBP 600 funding + GBP 0.79 pending + GBP 20 confirmed final balance against GBP 620 final evidence produces exactly GBP 0.79 pending evidence surplus.
2. The controlled evidence state becomes the existing ready-surplus status.
3. The existing confirmation RPC creates exactly GBP 0.79 customer credit.
4. The pending row becomes `credit_confirmed`.
5. New provenance links that exact pending row to that exact credit-ledger row.
6. The physical supplier FX remains GBP 0.79 confirmed.
7. Supplier-payment source-line consumption remains unchanged.
8. Existing Sage/FX posting fingerprints remain unchanged.
9. Eligible supplier settlement FX becomes GBP 0.00 only after new-path provenance exists.
10. Total classified remains GBP 0.79.
11. Remaining unresolved remains GBP 0.00.
12. Over-resolved remains GBP 0.00.
13. Pending orders with no confirmed final-balance payment remain unchanged.
14. Non-pending v3 rows remain unchanged.
15. Genuine final-balance shortfalls remain shortfalls.
16. Funding-time FX behaviour remains unchanged.
17. Existing historical `credit_confirmed` rows receive no provenance.
18. Where `P = 0`, supplier-FX settlement output remains observationally equivalent to current behaviour.
19. Re-running the new wrapper is idempotent.
20. Protected funding, supplier, customer-sales, Sage, VAT, shipment and tracking fingerprints remain unchanged.

## Locked implementation rule

> **Count confirmed final-balance payments when proving an original pending customer receipt surplus. Resolve that proven residual through the existing customer-credit accounting RPC. Record new-path provenance, and use that provenance only to remove the exact supplier-FX settlement participation displaced by that credit. Do not change established settlement arithmetic, historical FX evidence, existing accounting RPC logic, or legacy orders.**

Any implementation requiring broader funding, settlement arithmetic, historical-data, Sage, supplier, invoice, VAT, shipment, tracking, ledger or end-stage FX changes is outside this addendum and must stop for review before proceeding.
