# Completion Loyalty Main-Bank Handoff Corrective Addendum v1

Status: governing corrective integration addendum.

This addendum corrects one stale application handoff in the completion-loyalty workbench. It does not create a new loyalty workflow, funding route, release route, accounting treatment, customer state, or database function.

It must be read with:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
2. `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
3. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
4. `docs/governing-pack/ui/COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md`
5. `supabase/migrations/20260722a_completion_loyalty_manual_release_lockdown_v1.sql`

This addendum is additive. It does not rewrite or supersede the working main-bank/DVA pairing implementation. It supersedes only any remaining application behaviour that exposes the disabled direct/manual completion-loyalty funding confirmation path.

## 1. Proven defect

The current completion-loyalty workbench still renders a legacy manual funding form for a clean reward in:

```text
approved_pending_funding
```

That form submits to the application action:

```text
confirmCompletionLoyaltyRewardFundingAction
```

which calls:

```text
staff_confirm_completion_loyalty_reward_funding_v1(...)
```

The July 22 lockdown migration deliberately retained that RPC name only for dependency stability and changed it to fail closed.

Its required behaviour is:

```text
Direct completion-loyalty funding confirmation is disabled.
Use the paired main-bank OUT and same-importer destination-IN release workflow.
```

Therefore the defect is not missing funding logic. The defect is a stale UI/application caller that was not removed when the correct paired route became authoritative.

## 2. Correct integration boundary

Do not create a new workflow.

Do not create a new loyalty state.

Do not create a new RPC.

Do not create a new funding or release action on the completion-loyalty page.

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

This addendum changes only the application handoff into that existing route.

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

### 3.3 Main-bank loyalty funding

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
```

The existing completion-loyalty target mode remains:

```text
target=completion_loyalty
```

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

Only the existing paired OUT/IN release may make the reward available.

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
2. Remove the legacy `FundingForm` that submits manual funded/released amounts and manual DVA/evidence fields.
3. At the existing clean `approved_pending_funding` render point, hand staff into the already-built Main Bank completion-loyalty workspace.
4. Reuse the existing route:

```text
/internal/dva-reconciliation/main-bank?target=completion_loyalty
```

5. Where practical, pass the existing order reference through the existing `q` search parameter:

```text
/internal/dva-reconciliation/main-bank?target=completion_loyalty&q=<order_ref>
```

6. Update only stale explanatory copy that says the completion-loyalty workbench itself confirms DVA/account funding proof.

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

No migration is required.

Do not alter any database object as part of this correction.

In particular, retain:

```text
staff_confirm_completion_loyalty_reward_funding_v1
```

as the fail-closed legacy/dependency-stability barrier installed by the July 22 lockdown migration.

Do not drop it.

Do not re-enable it.

Do not grant it back to authenticated users.

Do not change its exception behaviour.

The existing paired functions remain authoritative and unchanged.

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

### 6.2 Customer requests use operationally

The customer request may be handled outside the platform, including by WhatsApp. This addendum does not create a customer request button or request table.

The staff funding action begins in the already-built Main Bank completion-loyalty workspace.

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
- manually release the target reward for testing.
```

## 8. Validation and regression gates

The correction is acceptable only if all of the following pass.

### 8.1 Static application proof

Prove:

```text
- no active application code calls staff_confirm_completion_loyalty_reward_funding_v1;
- no active application code references confirmCompletionLoyaltyRewardFundingAction;
- no active application code contains data-funding-proof-form;
- completion-loyalty pending-funding handoff points to the existing Main Bank completion-loyalty route;
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

Confirm the July 22 fail-closed guard remains installed in repository SQL:

```text
staff_confirm_completion_loyalty_reward_funding_v1
→ direct call disabled
→ paired OUT + same-importer destination IN required
```

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
- obsolete blue manual funding form is absent;
- approved amount remains visible;
- pending-funding status remains visible;
- staff can open the existing Main Bank completion-loyalty workspace;
- target mode is completion_loyalty;
- supplied order-reference query narrows/facilitates the existing workspace where supported;
- no financial mutation occurs merely by opening the workspace.
```

Do not manufacture a new bank/DVA transaction solely to validate this UI correction.

The next genuine customer-requested loyalty activation should use the existing Main Bank/DVA route as normal operational proof.

## 9. Rollback

Rollback is application-only.

If this UI handoff must be reverted before merge/deployment, revert the three application-file changes.

No business-data rollback exists because this correction must not mutate business data or database objects.

Do not re-enable the disabled manual RPC as a rollback mechanism.

## 10. Final implementation principle

This is not a loyalty rebuild.

This is not a new activation workflow.

This is not a new funding route.

This is not a database change.

The correction is:

```text
remove the stale manual application caller
        ↓
hand approved_pending_funding into the already-built
Main Bank completion-loyalty workflow
        ↓
leave every working upstream and downstream control unchanged
```

The existing working functions and controls remain the system of record.