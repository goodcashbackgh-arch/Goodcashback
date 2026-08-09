# Completion Loyalty Main-Bank Handoff Corrective Addendum v1

Status: governing corrective integration addendum.

This addendum corrects one stale application release path in the completion-loyalty workbench. It does not create a new loyalty workflow, funding route, release route, accounting treatment, customer state, search behaviour, or database function.

It must be read with:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
2. `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
3. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
4. `docs/governing-pack/ui/COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md`
5. `supabase/migrations/20260722a_completion_loyalty_manual_release_lockdown_v1.sql`

This addendum is additive. It does not rewrite or supersede the working main-bank/DVA pairing implementation. It supersedes only remaining application behaviour that exposes the direct/manual completion-loyalty funding confirmation path.

## 1. Proven defect

The completion-loyalty workbench still renders a manual funding/release form for a clean reward in:

```text
approved_pending_funding
```

That form submits to the application action:

```text
confirmCompletionLoyaltyRewardFundingAction
```

which directly calls:

```text
staff_confirm_completion_loyalty_reward_funding_v1(...)
```

Production history proves that, after the paired Main Bank workflow was established, normal surviving releases use:

```text
main-bank OUT reserved
→ same-importer DVA/card IN paired
→ funding confirmation created
→ completion-loyalty credit released
```

Historical pre-pairing/manual and legacy OUT-only evidence may remain in business history and must not be rewritten.

The July 22 lockdown migration is the repository authority for preventing direct/manual release while preserving the established paired workflow. Production deployment alignment of that existing migration is a separate operational step and is not implemented by changing or adding migration SQL in this corrective application PR.

Therefore the application defect is narrow:

```text
the workbench still exposes a direct/manual funding/release caller
that bypasses the established Main Bank paired operational route
```

No other working navigation, search, funding, pairing, release, accounting, or customer behaviour is defective under this addendum.

## 2. Correct integration boundary

Do not create a new workflow.

Do not create a new loyalty state.

Do not create a new RPC.

Do not create a new funding or release action on the completion-loyalty page.

Do not alter the established Main Bank handoff URL behaviour.

The existing authoritative route is:

```text
Supervisor approves reward
        ↓
approved_pending_funding
        ↓
customer sees loyalty reward as pending activation
        ↓
staff uses existing Main Bank completion-loyalty workspace
        ↓
internal_main_bank_completion_loyalty_targets_v1
        ↓
staff_stage_main_bank_line_to_completion_loyalty_v2
        ↓
main-bank OUT reserved against approved reward
        ↓
existing same-importer DVA/card IN reconciliation
        ↓
staff_pair_loyalty_destination_in_and_release_v1
        ↓
existing funding confirmation + completion-loyalty credit
        ↓
released_available_dashboard_credit
        ↓
customer sees loyalty reward ready to use
```

This addendum changes only removal of the direct/manual application caller. The existing handoff into the Main Bank workspace must be preserved exactly.

## 3. Existing working parts that must remain unchanged

The correction must not modify any of the following.

### 3.1 Upstream loyalty decision and eligibility

Do not modify:

```text
internal_order_final_sale_settlement_v1
internal_order_final_sale_settlement_v2
internal_order_qualifying_net_spend_v1
internal_completion_loyalty_reward_proposals_v1
internal_completion_loyalty_reward_funding_workbench_v1
staff_approve_completion_loyalty_reward_v1
completion-loyalty rejection logic
completion blocker logic
basis blocker logic
approval blocker logic
approved_pending_funding state semantics
```

Approval in principle must continue to create no available loyalty credit.

### 3.2 Customer presentation

Do not modify the customer dashboard/read model as part of this correction.

Existing mapping remains:

```text
approved_pending_funding
→ Loyalty reward: £Y pending activation

released_available_dashboard_credit
→ Loyalty reward: £Y ready to use
```

Pending loyalty must remain non-spendable.

Released loyalty must remain separate from normal account credit presentation and customer self-service rules.

### 3.3 Main-bank loyalty funding and existing handoff/search behaviour

Do not modify:

```text
/internal/dva-reconciliation/main-bank
internal_main_bank_completion_loyalty_targets_v1
staff_stage_main_bank_line_to_completion_loyalty_v2
main_bank_completion_loyalty_funding_matches
shared main-bank remaining-balance controls
shipper AP allocation logic
FX/card residual logic
bank-fee residual logic
hold/residual logic
bulk loyalty funding-pot logic
Main Bank search/query semantics
```

The existing completion-loyalty target mode remains:

```text
target=completion_loyalty
```

The existing workbench-to-Main-Bank handoff may include the existing order-reference query exactly as already implemented:

```text
/internal/dva-reconciliation/main-bank?target=completion_loyalty&q=<order_ref>
```

This corrective work must not remove, reinterpret, replace, optimise, or otherwise change that `q=<order_ref>` behaviour.

The existing main-bank action remains responsible for validating the selected main-bank OUT, reward target, importer, available amount, and reservation.

### 3.4 DVA/card pairing and release

Do not modify:

```text
staff_pair_loyalty_destination_in_and_release_v1
internal_release_paired_loyalty_v2
completion_loyalty_reward_funding_confirmations
importer_credit_ledger release creation
same-importer destination-IN validation
destination-IN remaining-balance validation
source-OUT capacity validation
pair-status transitions
loyalty-specific reversal
```

Only the established paired OUT/IN release route is authoritative for new operational releases under the locked contract.

### 3.5 Loyalty usage

Do not modify:

```text
staff_apply_completion_loyalty_to_order_v1
order_funding_events.credit_applied
loyalty debit-ledger consumption
same-customer order application rules
```

Activation and application remain separate actions.

### 3.6 Accounting, VAT and Sage

Do not modify:

```text
cash-posting controls
Accounting Command Centre loyalty controls
bank-internal-transfer treatment
non-cash loyalty customer-balance settlement
VAT timing
Sage posting
customer invoices
supplier invoices
settlement credit
supplier FX
historical accounting rows
```

Main-bank OUT plus DVA/card IN remains an internal-transfer proof/release control.

Applied loyalty remains the separate non-cash customer-settlement event through `credit_applied`.

These meanings must not be combined.

## 4. Exact runtime correction

Runtime scope is limited to exactly these existing application files:

```text
app/internal/completion-loyalty-rewards/page.tsx
app/internal/completion-loyalty-rewards/actions.ts
app/internal/completion-loyalty-rewards/WorkbenchClientEnhancements.tsx
```

No other runtime file is required by this correction.

### 4.1 Completion-loyalty page

File:

```text
app/internal/completion-loyalty-rewards/page.tsx
```

Required changes only:

1. Remove the import of `confirmCompletionLoyaltyRewardFundingAction`.
2. Remove the manual `FundingForm` that submits funded/released amounts and manual DVA/evidence fields.
3. At the existing clean `approved_pending_funding` render point, preserve the existing navigation into the already-built Main Bank completion-loyalty workspace.
4. Preserve the established handoff URL exactly:

```text
/internal/dva-reconciliation/main-bank?target=completion_loyalty&q=<order_ref>
```

5. Do not remove or alter the existing `q=<order_ref>` parameter as part of this correction.
6. Update only explanatory copy that incorrectly instructs staff to confirm/release funding directly from the completion-loyalty workbench.

The handoff is navigation only. It must not perform a funding write, reserve a bank line, release credit, or change loyalty state.

Do not create a new state component, workflow abstraction, RPC wrapper, or duplicated Main Bank form.

Do not refactor unrelated page helpers merely for naming/style cleanup.

In particular, existing status/filter helpers may remain even if their names pre-date this correction, provided their semantics are unchanged.

### 4.2 Completion-loyalty server actions

File:

```text
app/internal/completion-loyalty-rewards/actions.ts
```

Required change only:

Remove:

```text
confirmCompletionLoyaltyRewardFundingAction
```

Do not replace it with a new funding server action.

Keep unchanged:

```text
approveCompletionLoyaltyRewardAction
applyCompletionLoyaltyToOrderAction
```

The completion-loyalty workbench must no longer directly call:

```text
staff_confirm_completion_loyalty_reward_funding_v1
```

### 4.3 Completion-loyalty client enhancement file

File:

```text
app/internal/completion-loyalty-rewards/WorkbenchClientEnhancements.tsx
```

Remove only browser behaviour that exists solely for the deleted manual funding form:

```text
clearFundingProofValidity(...)
validateFundingProof(...)
data-funding-proof-form input handling
data-funding-proof-form submit handling
```

Keep unchanged:

```text
approval amount/reward-rate synchronisation
internal-dashboard shell enhancements
breadcrumb normalisation
existing navigation shortcuts
all unrelated client behaviour
```

## 5. Database scope

No new migration is authorised by this corrective PR.

Do not alter any database object in this branch.

Do not add, edit, replace, or re-version a migration file under this correction.

Repository authority remains:

```text
supabase/migrations/20260722a_completion_loyalty_manual_release_lockdown_v1.sql
```

That existing migration is the separate deployment-alignment control for making direct manual release fail closed while preserving the established paired Main Bank OUT + same-importer destination-IN release workflow.

Applying that already-existing migration to a live environment, where required, is an operational deployment step outside this application diff. This addendum does not authorise inventing replacement SQL.

Historical business rows created under earlier logic remain immutable.

## 6. Required user journey after correction

### 6.1 Approval

```text
reward proposal ready
→ supervisor approves in principle
→ approved_pending_funding
```

Expected result:

```text
no available loyalty credit
no importer_credit_ledger release
no order_funding_events entry
no VAT effect
no Sage posting
customer sees pending activation
```

### 6.2 Existing handoff

For a clean approved reward, retain the already-established navigation:

```text
/internal/dva-reconciliation/main-bank?target=completion_loyalty&q=<order_ref>
```

Opening that route is navigation only and must not itself mutate financial state.

### 6.3 Reserve main-bank OUT

Existing flow only:

```text
Main Bank → completion_loyalty
→ select eligible reward target
→ select main-bank OUT
→ staff_stage_main_bank_line_to_completion_loyalty_v2
```

Expected result:

```text
source OUT reserved
reward not yet released
customer still sees pending activation
no available loyalty credit
```

### 6.4 Pair destination IN and release

Existing flow only:

```text
same-importer DVA/card IN available
→ pair to staged loyalty match
→ staff_pair_loyalty_destination_in_and_release_v1
```

Expected result:

```text
paired release validation passes
funding confirmation created
completion-loyalty importer credit created
approval/match status becomes released_available_dashboard_credit
customer sees ready to use
```

### 6.5 Apply released loyalty

Existing flow only:

```text
staff_apply_completion_loyalty_to_order_v1
→ loyalty credit consumed
→ order_funding_events.credit_applied
```

No change under this addendum.

## 7. Forbidden scope expansion

Do not:

```text
- change or remove q=<order_ref> from the existing Main Bank handoff;
- change Main Bank query/search semantics;
- add a new loyalty activation state;
- add a new loyalty funding RPC;
- add a new paired-release RPC;
- add a new Main Bank action;
- duplicate Main Bank forms on the completion-loyalty page;
- move Main Bank validation into the completion-loyalty page;
- change approved_pending_funding semantics;
- change customer pending/ready projection logic;
- change the Main Bank page or its actions;
- change DVA/card reconciliation;
- change pairing suggestions;
- change bulk funding-pot behaviour;
- change shipper AP;
- change FX/fee/hold residual allocation;
- change loyalty application to order;
- change VAT;
- change Sage;
- change settlement;
- change accounting classifications;
- change historical data;
- backfill anything;
- add or modify migration SQL in this PR;
- manually release the target reward for testing.
```

## 8. Validation and regression gates

The correction is acceptable only if all of the following pass.

### 8.1 Static application proof

Prove:

```text
- no active completion-loyalty application code calls staff_confirm_completion_loyalty_reward_funding_v1;
- no active completion-loyalty application code references confirmCompletionLoyaltyRewardFundingAction;
- no active completion-loyalty application code contains data-funding-proof-form;
- completion-loyalty pending-funding handoff retains target=completion_loyalty&q=<order_ref>;
- no new funding/release RPC call is introduced on the completion-loyalty page.
```

Historical migrations/governing documents are allowed and expected to retain the legacy RPC name.

### 8.2 Scope proof

The runtime diff must be limited to exactly:

```text
app/internal/completion-loyalty-rewards/page.tsx
app/internal/completion-loyalty-rewards/actions.ts
app/internal/completion-loyalty-rewards/WorkbenchClientEnhancements.tsx
```

Additional changed files may only be this governing addendum and one dedicated regression/static-assurance file.

No migration file may be added or changed.

No Main Bank, DVA, accounting, customer, settlement, or Sage runtime file may be changed.

### 8.3 Upstream read-only proof

For a clean approved reward, prove without financial mutation:

```text
workbench_status = approved_pending_funding
approved amount unchanged
funded amount remains zero until existing funding route is used
released amount remains zero until existing paired release is used
available dashboard credit remains zero until existing paired release is used
customer pending-activation presentation remains available
```

### 8.4 Existing-route proof

Read-only/static proof must confirm the existing Main Bank implementation still uses:

```text
internal_main_bank_completion_loyalty_targets_v1
staff_stage_main_bank_line_to_completion_loyalty_v2
staff_pair_loyalty_destination_in_and_release_v1
```

This correction must not modify those implementations.

### 8.5 Legacy safety proof

Repository SQL must continue to contain the July 22 direct-manual-release lockdown authority:

```text
staff_confirm_completion_loyalty_reward_funding_v1
→ direct call disabled by the existing July lockdown migration
→ paired OUT + same-importer destination IN required for new operational release
```

Live deployment status of that existing migration must be verified separately before relying on the database barrier.

### 8.6 Build proof

Before merge:

```text
TypeScript/type validation passes
production build passes
no type weakening is introduced
exact changed-file scope is reviewed
```

### 8.7 UI UAT

For an existing `approved_pending_funding` reward:

```text
- obsolete blue manual funding/release form is absent;
- approved amount remains visible;
- pending-funding status remains visible;
- existing Main Bank handoff remains target=completion_loyalty&q=<order_ref>;
- no financial mutation occurs merely by opening the workspace;
- existing Main Bank reserve/pair/release behaviour is otherwise unchanged.
```

Do not manufacture a new bank/DVA transaction solely to validate this UI correction.

The next genuine customer-requested loyalty activation should use the existing Main Bank/DVA route as normal operational proof.

## 9. Rollback

Rollback is application-only for this PR.

If this UI correction must be reverted before merge/deployment, revert the three application-file changes.

No business-data rollback exists because this correction must not mutate business data or database objects.

Do not use direct/manual release as a rollback mechanism.

## 10. Final implementation principle

This is not a loyalty rebuild.

This is not a new activation workflow.

This is not a new funding route.

This is not a Main Bank search change.

This is not new database SQL.

The correction is exactly:

```text
preserve the existing target=completion_loyalty&q=<order_ref> handoff
        ↓
remove the direct/manual funding/release UI caller
        ↓
leave every working Main Bank, DVA, release, customer and accounting control unchanged
```

The existing working functions and controls remain the system of record.

## 11. Follow-on customer pending-and-ready presentation correction

This section is a narrow follow-on correction under this same addendum. It does not reopen the completed Main Bank handoff correction above.

For this section only, it supersedes the earlier prohibition in section 3.2 against changing customer-dashboard presentation and the section 8.2 prohibition against changing a customer runtime file. It does not supersede the prohibition on changing customer pending/ready projection logic, because this correction changes presentation only and leaves the projection logic unchanged.

### 11.1 Proven customer-display defect

The existing customer dashboard already calls:

```text
customer_completion_loyalty_reward_balance_v1()
```

and already receives two independent balances:

```text
pending_activation_gbp
ready_to_use_gbp
```

The page already reduces those values independently into:

```text
pendingLoyaltyGbp
readyLoyaltyGbp
```

The defect is only that the current display is mutually exclusive: any positive `readyLoyaltyGbp` is shown first and suppresses a simultaneously positive `pendingLoyaltyGbp`.

Live read-only proof established:

```text
pending_activation_gbp = £852.77
ready_to_use_gbp = £9,572.69
```

The target order `ORD-1786093662671` contributes £50.00 to pending activation through `approved_pending_funding` with no active rejection.

The traced £9,572.69 ready balance is the remaining available total of released `completion_loyalty_reward` ledger lots. The traced released lots use the established:

```text
Main Bank OUT
→ same-importer DVA/card IN
→ paired_released
→ released_available_dashboard_credit
→ completion-loyalty ledger lot
```

flow.

No backend defect is authorised for correction here.

### 11.2 Governing customer presentation

Keep the existing single customer credit card and existing single loyalty line.

Required rendering is:

```text
ready > 0 AND pending > 0
→ Loyalty reward: £X ready to use · £Y pending activation

ready > 0 AND pending = 0
→ Loyalty reward: £X ready to use

ready = 0 AND pending > 0
→ Loyalty reward: £Y pending activation

ready = 0 AND pending = 0
→ Loyalty reward: No loyalty reward active yet
```

For the proven live state, the expected display is:

```text
Loyalty reward: £9,572.69 ready to use · £852.77 pending activation
```

Pending loyalty remains non-spendable. Ready loyalty remains the remaining available balance of released completion-loyalty lots. Normal available account credit remains separate.

### 11.3 Existing lifecycle remains unchanged

The existing lifecycle remains exactly:

```text
approved_pending_funding
→ contributes to pending_activation_gbp

Main Bank OUT staged/reserved
→ remains pending
→ no available loyalty credit

same-importer destination DVA/card IN paired
→ existing paired release
→ approval_status = released_available_dashboard_credit
→ released completion-loyalty ledger lot created
→ amount leaves pending projection
→ remaining available amount joins ready_to_use_gbp
```

For the current £50 target, assuming no simultaneous loyalty use or other balance change:

```text
before release:
pending = £852.77
ready   = £9,572.69

after paired release of £50:
pending = £802.77
ready   = £9,622.69
```

The customer page must only reflect those existing balances.

### 11.4 Exact runtime scope

The follow-on runtime scope is exactly:

```text
app/customer/page.tsx
```

No other runtime file is authorised by this section.

Keep unchanged:

```text
customer_completion_loyalty_reward_balance_v1
pendingLoyaltyGbp reduction
readyLoyaltyGbp reduction
customer card layout
customer card styling
surrounding customer copy
normal account-credit calculation
order rendering
navigation
authentication
all unrelated helpers
```

Only the mutually exclusive `loyaltyStatusText` construction may change.

Required implementation shape:

```ts
const loyaltyStatusParts: string[] = [];

if (readyLoyaltyGbp > 0.01) {
  loyaltyStatusParts.push(`${gbp(readyLoyaltyGbp)} ready to use`);
}

if (pendingLoyaltyGbp > 0.01) {
  loyaltyStatusParts.push(`${gbp(pendingLoyaltyGbp)} pending activation`);
}

const loyaltyStatusText =
  loyaltyStatusParts.length > 0
    ? loyaltyStatusParts.join(" · ")
    : "No loyalty reward active yet";
```

Do not introduce a helper extraction, component refactor, new state abstraction, styling change, RPC wrapper, data-model change or alternative display structure.

### 11.5 Forbidden follow-on scope

Do not change:

```text
customer_completion_loyalty_reward_balance_v1
internal_importer_available_completion_loyalty_lots_v1
completion_loyalty_reward_approvals
completion_loyalty_reward_funding_confirmations
importer_credit_ledger
staff_approve_completion_loyalty_reward_v1
staff_stage_main_bank_line_to_completion_loyalty_v2
staff_pair_loyalty_destination_in_and_release_v1
internal_release_paired_loyalty_v2
/internal/dva-reconciliation/main-bank
target=completion_loyalty&q=<order_ref>
DVA/card reconciliation
pairing suggestions
loyalty application to order
order_funding_events
accounting
VAT
Sage
settlement
historical data
```

Do not add or modify migration SQL. Do not backfill or mutate business data. Do not manually release the target £50 as part of this corrective build.

### 11.6 Regression requirement

Add exactly one dedicated static-assurance file for this follow-on correction.

It must prove the customer page retains the existing RPC and independent balance reductions, contains the authorized independent ready/pending rendering, and no longer contains the old mutually exclusive ready-over-pending `loyaltyStatusText` construction.

It must cover exactly these four rendering cases:

```text
ready = 0, pending = 0
→ No loyalty reward active yet

ready = 0, pending = 50
→ £50.00 pending activation

ready = 100, pending = 0
→ £100.00 ready to use

ready = 100, pending = 50
→ £100.00 ready to use · £50.00 pending activation
```

No regression may mutate financial data.

### 11.7 Acceptance and rollback

The follow-on correction is acceptable only when:

```text
- app/customer/page.tsx is the only runtime file changed;
- exactly one dedicated static-assurance file is added;
- this existing addendum is the only governing document changed;
- no migration is added or changed;
- both ready and pending are visible when both are positive;
- no Main Bank, DVA/card, approval, release, accounting, VAT, Sage, settlement or historical behaviour changes;
- no financial state changes merely by rendering or testing the customer page.
```

Rollback for this follow-on correction is application-only: revert the `app/customer/page.tsx` loyalty-status block and its dedicated static-assurance file. Do not use a financial mutation or manual loyalty release as rollback.

This section is the governing authority for the follow-on customer-display correction. Change nothing else.
