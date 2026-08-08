# Completion Loyalty Final-Sale Settlement v2 Integration Addendum v1

Status: governing implementation addendum for the completion-loyalty settlement integration correction.

Parent governing contract: `COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`.

This addendum does not supersede or alter the accounting treatment in the parent contract. It fixes one integration boundary: completion loyalty must consume the existing final-balance-aware final-sale settlement projection when deciding whether an order is financially complete.

## 1. Objective

Correct the completion-loyalty workflow so that it uses the existing `public.internal_order_final_sale_settlement_v2(uuid)` projection wherever loyalty needs final-sale settlement truth.

The correction is integration-only:

```text
No new payment logic.
No settlement arithmetic changes.
No accounting mutations.
No historical data changes.
No customer-credit changes.
```

## 2. Proven root cause

The live database dependency before correction is:

```text
internal_order_final_sale_settlement_v1
        |
        +-- internal_order_final_sale_settlement_v2
        |       |
        |       +-- staff_allocate_statement_line_to_final_balance_payment_v1
        |
        +-- internal_order_qualifying_net_spend_v1
                |
                +-- completion loyalty proposal/workbench chain
```

`internal_order_final_sale_settlement_v1` is the base settlement model. Its `amount_received_gbp` comes from the platform funding-stage amount and therefore excludes later confirmed `final_balance_payment` allocations.

`internal_order_final_sale_settlement_v2` deliberately wraps v1. It:

```text
1. calls internal_order_final_sale_settlement_v1(...);
2. sums confirmed dva_statement_line_allocations where:
   allocation_type = 'final_balance_payment'
   allocation_status = 'confirmed';
3. adds that amount to v1 amount_received_gbp;
4. recalculates the settlement fields that depend on total amount received;
5. preserves the same public return signature as v1.
```

The defect is therefore not incorrect payment data and not missing settlement logic. The defect is that the completion-loyalty qualifying-spend path remained connected to v1 after v2 was introduced for confirmed final-balance payments.

## 3. Live contract proof

The current live v1 and v2 function definitions were inspected directly with `pg_get_functiondef(...)`.

An estate-wide read-only comparison then proved all of the following:

```text
row_population_mismatch_count           = 0
unexpected_contract_difference_count    = 0
received_math_mismatch_count            = 0
zero_final_balance_state_drift_count     = 0
```

Meaning:

```text
- v1 and v2 return the same order population;
- fields outside the explicitly settlement-derived v2 fields do not drift;
- v2 amount_received_gbp equals v1 amount_received_gbp plus confirmed final-balance payments exactly;
- orders with no confirmed final-balance payment have no settlement/completion state drift between v1 and v2.
```

The only live behavioural differences found were three orders with confirmed final-balance payments:

```text
ORD-1777736251155
v1 received: £199.99
confirmed final balance: £12.00
v2 received: £211.99
v1 due: £12.00
v2 due: £0.00
v1 settlement: balance_due
v2 settlement: credit_added_to_account
v1 completion: not_complete
v2 completion: complete

ORD-1781443253680
v1 received: £100.00
confirmed final balance: £20.00
v2 received: £120.00
v1 due: £20.00
v2 due: £0.00
v1 settlement: balance_due
v2 settlement: settled_nil
v1 completion: not_complete
v2 completion: complete

ORD-1786093662671
v1 received: £600.00
confirmed final balance: £20.00
v2 received: £620.00
v1 due: £20.00
v2 due: £0.00
v1 settlement: balance_due
v2 settlement: credit_added_to_account
v1 completion: not_complete
v2 completion: complete
```

For `ORD-1786093662671`, the separate approved £0.79 customer settlement credit remains separate from payment receipts and must not be added to `amount_received_gbp`.

## 4. Settlement ownership contract

Completion loyalty does not own payment-receipt reconstruction.

The required ownership boundary is:

```text
final-sale settlement v1
        ->
final-sale settlement v2
        ->
qualifying net spend
        ->
completion loyalty proposal
        ->
approval / funding workbench
```

The loyalty layer must not independently reconstruct:

```text
initial funding
+ final-balance payments
+ settlement/overfunding credits
```

Confirmed final-balance receipt ownership remains inside the existing settlement v2 projection.

Customer settlement credit / overfunding remains a distinct credit family and is not settlement cash received.

## 5. Required database integration change

Create a new forward migration that redefines:

```text
public.internal_order_qualifying_net_spend_v1(uuid)
```

The public function name, parameters, return columns, return types, security characteristics and business rules remain unchanged.

The semantic dependency change is only:

```sql
-- BEFORE
FROM public.internal_order_final_sale_settlement_v1(p_order_id) s

-- AFTER
FROM public.internal_order_final_sale_settlement_v2(p_order_id) s
```

The prerequisite check in the migration must likewise require:

```text
public.internal_order_final_sale_settlement_v2(uuid)
```

instead of settlement v1.

No other qualifying-net-spend logic is to change.

Specifically preserve unchanged:

```text
- supplier-line eligibility rules;
- physical/non-physical classification;
- active resolution handling;
- dispute handling;
- customer hold handling;
- accounting-code requirements;
- standard-rate / 20% VAT basis rules;
- admin-review blockers;
- existing completion-loyalty reward detection;
- qualifying signed gross basis calculation;
- qualifying net spend calculation;
- blocker precedence except where the corrected settlement inputs naturally clear final_balance_due;
- SECURITY DEFINER and staff-auth controls;
- return contract.
```

## 6. Required application integration changes

Two completion-loyalty pages directly call settlement v1 as a supplemental/fallback settlement source and must be aligned to v2 so the UI cannot mix v1 and v2 truth.

### Main reward workbench

File:

```text
app/internal/completion-loyalty-rewards/page.tsx
```

Change only:

```text
internal_order_final_sale_settlement_v1
->
internal_order_final_sale_settlement_v2
```

No blocker/UI business logic is to be rewritten as part of this correction.

### Loyalty rejection page

File:

```text
app/internal/completion-loyalty-rewards/rejections/page.tsx
```

Change only:

```text
internal_order_final_sale_settlement_v1
->
internal_order_final_sale_settlement_v2
```

No rejection logic is to change.

## 7. Exact intended change set

The implementation build should contain only:

```text
1. one forward migration redefining internal_order_qualifying_net_spend_v1 to consume settlement v2;
2. one assertion-driven rollback/read-only regression SQL file;
3. one RPC-name substitution in the main completion-loyalty workbench page;
4. one RPC-name substitution in the completion-loyalty rejection page;
5. this governing addendum.
```

If implementation requires materially more than this scope, stop and re-establish the dependency proof before proceeding.

## 8. Explicitly forbidden changes

This correction must not modify:

```text
public.internal_order_final_sale_settlement_v1
public.internal_order_final_sale_settlement_v2
public.internal_platform_order_status_v1
public.order_funding_position_vw
public.dva_statement_line_allocations
public.sales_invoices
public.importer_credit_ledger
canonical settlement/resolution functions
supplier settlement / FX logic
Sage records
customer invoices
historical accounting records
previous receipt-residual / £0.79 settlement-credit provenance logic
```

Do not:

```text
- add final_balance_payment arithmetic into settlement v1;
- duplicate settlement v2 logic inside qualifying net spend;
- add approved customer credit to amount_received_gbp;
- reinterpret the £0.79 credit as payment against the £20 final balance;
- rewrite upstream platform funding semantics;
- mutate confirmed final-balance allocation history;
- migrate or backfill historical accounting data.
```

## 9. Fields v2 is allowed to differ from v1

Because v2 adds confirmed final-balance receipt amounts, the estate assurance permits differences only in settlement-derived outputs:

```text
amount_received_gbp
final_balance_due_gbp
raw_potential_credit_gbp
potential_credit_pending_review_gbp
final_settlement_state
completion_state
completion_blocker
show_balance_due_yn
show_potential_credit_yn
```

All inherited/non-settlement fields must remain equivalent between v1 and v2.

## 10. Target-order expected behaviour

For `ORD-1786093662671`:

```text
initial funding                    £600.00
confirmed final-balance payment    £20.00
settlement amount received         £620.00
final sale                         £620.00
final balance due                    £0.00
approved account credit              £0.79
```

Expected corrected settlement projection:

```text
final_settlement_state = credit_added_to_account
completion_state       = complete
completion_blocker     = NULL
final_balance_due_gbp  = 0.00
```

The approved £0.79 account credit remains £0.79 and remains separate from settlement receipts.

Expected completion-loyalty consequence, subject to all existing non-settlement loyalty gates:

```text
- no final_balance_due completion blocker;
- no final_balance_due basis blocker;
- no final_balance_due approval blocker;
- qualifying net spend may be calculated normally from the existing coded/resolved qualifying basis;
- suggested reward may be calculated normally under the parent loyalty contract.
```

## 11. Existing affected-estate acceptance criteria

### ORD-1777736251155

Required after integration:

```text
final balance due: £12.00 -> £0.00
completion: not_complete -> complete
completion blocker: final_balance_due -> NULL
settlement: balance_due -> credit_added_to_account
```

Its separate existing-reward condition must remain intact:

```text
completion_loyalty_reward_already_exists
```

No duplicate reward may be created.

### ORD-1781443253680

Required after integration:

```text
amount received: £100.00 -> £120.00
final balance due: £20.00 -> £0.00
settlement: balance_due -> settled_nil
completion: not_complete -> complete
completion blocker: final_balance_due -> NULL
```

### ORD-1786093662671

Required after integration:

```text
amount received: £600.00 -> £620.00
final balance due: £20.00 -> £0.00
settlement: balance_due -> credit_added_to_account
completion: not_complete -> complete
completion blocker: final_balance_due -> NULL
approved account credit remains £0.79
```

## 12. Regression requirements

Add an assertion-driven regression that is rollback-safe and creates no permanent business data.

Where internal staff functions require authentication in SQL Editor, the regression may use a transaction-local diagnostic JWT claim for an existing active admin/supervisor only for the duration of the read-only/rollback test.

The regression must prove all of the following.

### A. v1/v2 estate contract remains clean

```text
row_population_mismatch_count           = 0
unexpected_contract_difference_count    = 0
received_math_mismatch_count            = 0
zero_final_balance_state_drift_count     = 0
```

### B. Corrected loyalty settlement dependency

For orders where:

```text
v2.final_balance_due_gbp = 0
and
v2.completion_state = complete
```

loyalty must not retain:

```text
basis_blocker      = final_balance_due
completion_blocker = final_balance_due
approval_blocker   = final_balance_due
```

unless a separately proven downstream function intentionally preserves a historical decision record rather than current readiness; such a case must be explicitly asserted and documented rather than silently changed.

### C. Known affected orders

The three known orders must lose the false final-balance blocker according to the expectations in section 11.

### D. Existing reward protection

`ORD-1777736251155` must continue to identify its existing completion-loyalty reward and must not become eligible for a duplicate reward.

### E. Negative controls

Orders with no confirmed `final_balance_payment` must retain the same settlement/completion behaviour between v1 and v2.

### F. No accounting mutation

The correction is read-model/integration only. Regression must not create, update or delete:

```text
final-balance allocations
sales invoices
customer credits
supplier settlement entries
Sage records
completion-loyalty credits
```

## 13. Application verification gates

Before release:

```text
- TypeScript/type-check passes;
- normal repository lint gate passes if applicable;
- production application build passes;
- both completion-loyalty pages resolve settlement v2 successfully;
- no type weakening or broad casts are introduced merely to make the v2 RPC compile.
```

Because v1 and v2 expose the same SQL return signature, no application settlement-row schema change is expected.

If the substitution causes a schema/type incompatibility, stop and investigate rather than expanding scope.

## 14. Deployment sequence

Required sequence:

```text
1. separate branch from current main;
2. add this governing addendum;
3. add forward migration;
4. add assertion-driven rollback/read-only regression;
5. switch the two loyalty UI RPC calls from v1 to v2;
6. review diff for strict scope;
7. run application compile/type-check/build gates;
8. execute the migration only in the explicitly intended environment;
9. run the regression;
10. verify the three known affected orders;
11. perform completion-loyalty UAT on ORD-1786093662671;
12. PR review;
13. merge only with explicit approval.
```

Important operational control:

If the function migration is manually executed against a shared production Supabase database before the application deployment, the database read-model behaviour changes immediately. Migration and application release must therefore be coordinated deliberately.

## 15. Rollback

Rollback is integration-only.

Database rollback:

```text
restore internal_order_qualifying_net_spend_v1
from settlement v2 dependency
back to settlement v1 dependency
```

Application rollback:

```text
main completion-loyalty page: v2 -> v1
loyalty rejection page:       v2 -> v1
```

No business-data rollback is required because this correction must create or mutate no settlement, accounting, credit, invoice or allocation data.

## 16. Risk and blast-radius contract

```text
Data mutation risk:
none by design.

Accounting mutation risk:
none by design, provided v1/v2 are untouched.

Database behavioural scope:
internal_order_qualifying_net_spend_v1 and its completion-loyalty downstream consumers.

Application behavioural scope:
completion-loyalty main workbench and rejection page settlement fallbacks.

Current live estate behavioural population proven to differ v1 -> v2:
3 orders, each explained exactly by confirmed final-balance allocations.
```

No claim is made that future affected population remains three; future orders using a separate confirmed final-balance payment are precisely why loyalty must consume v2.

## 17. Implementation stop conditions

Stop the build and re-investigate if any of the following occurs:

```text
- settlement v1 must be modified;
- settlement v2 must be modified;
- final-balance allocations must be rewritten;
- customer credit must be reclassified as payment;
- qualifying-net-spend return schema must change;
- unrelated orders without final-balance payments drift;
- estate contract assurance produces a non-zero unexpected-difference counter;
- more than the narrow database dependency + two UI integrations require behavioural change;
- accounting or Sage history appears to require mutation.
```

## 18. Governing implementation statement

The required correction is:

```text
Completion loyalty was connected to pre-final-balance settlement v1.

Final-balance-aware settlement v2 already exists, already wraps v1,
already has the same return contract, and is proven on the current live estate.

Connect completion loyalty to settlement v2.

Do not rewrite settlement logic.
Do not mutate accounting data.
Do not alter customer credit.
Nothing else.
```
