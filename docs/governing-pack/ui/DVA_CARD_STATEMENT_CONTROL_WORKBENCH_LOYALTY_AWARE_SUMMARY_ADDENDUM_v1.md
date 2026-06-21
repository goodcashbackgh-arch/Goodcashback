# DVA/Card Statement Control Workbench Loyalty-Aware Summary Addendum v1

Status: governance addendum to `DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`. This addendum narrows one proven read-model/UI gap: main-bank completion loyalty funding matches must be recognised by the shared DVA/card statement-line control views. Do not add cash-posting, Sage posting, new write buttons, or new statement-line allocation writes from this addendum without explicit approval and test evidence.

## Problem proven in live control data

A main-company-bank OUT line can be used to release a completion loyalty reward through the main-bank loyalty funding lane:

```text
main bank OUT statement line
-> main_bank_completion_loyalty_funding_matches
-> completion_loyalty_reward_funding_confirmations
-> importer_credit_ledger
```

That route correctly releases the loyalty credit and records the main-bank funding match.

However, the shared `dva_statement_line_allocation_summary_vw` currently derives its allocation totals only from `dva_statement_line_allocations`. It does not count `main_bank_completion_loyalty_funding_matches`. Therefore a real main-bank OUT line that is already consumed by loyalty funding can still appear in the DVA/card control hub, matching workspace, unmatched OUT triage, review pack, and pre-Sage readiness views as:

```text
confirmed_allocated_gbp = 0
confirmed_unallocated_gbp = statement_gbp_amount
confirmed_balanced_yn = false
match_status = unmatched
```

That is a false control signal. The line is not unmatched; it is matched to loyalty credit funding.

## Non-negotiable boundary

This addendum is a read-model/UI correction only.

Do not:

- insert fake `dva_statement_line_allocations` rows for loyalty funding;
- add a new `completion_loyalty_reward` allocation type to `dva_statement_line_allocations` as part of this narrow fix;
- change source-lot credit priority;
- change `customer_apply_available_credit_to_order_v1`;
- change `staff_reconcile_dva_line_to_order(...)`;
- change main-bank loyalty release flow;
- change shipper AP matching;
- change supplier/refund/FX/fee/hold allocation rules;
- create Sage cash-posting rows;
- post internal transfers to Sage;
- hide main-company-bank statement lines from the DVA/card control hub.

Main-company-bank lines should remain visible in the shared control hub, but they must display their true control explanation.

## Correct read-model behaviour

`dva_statement_line_allocation_summary_vw` must remain the shared statement-line control summary, but it must become loyalty-aware for main-bank completion loyalty funding matches.

The existing column order and types must be preserved. Any new columns must be appended at the end of the view.

The view must append at least these fields:

```text
statement_account_context
statement_account_label
source_bank
loyalty_credit_funding_allocated_gbp
main_bank_loyalty_match_count
control_match_reason
```

The view may append further explanatory fields only if they do not break existing consumers.

## Confirmed amount calculation

For statement-line control display, the confirmed consumed amount must include both normal allocation rows and confirmed/released main-bank loyalty funding matches.

Use this control calculation:

```text
normal_confirmed_allocated_gbp =
  sum(dva_statement_line_allocations.allocated_gbp_amount)
  where allocation_status = 'confirmed'

loyalty_credit_funding_allocated_gbp =
  sum(main_bank_completion_loyalty_funding_matches.matched_gbp_amount)
  where match_status in ('confirmed', 'released_available_dashboard_credit')

confirmed_allocated_gbp =
  normal_confirmed_allocated_gbp
  + loyalty_credit_funding_allocated_gbp

confirmed_unallocated_gbp =
  statement_gbp_amount
  - normal_confirmed_allocated_gbp
  - loyalty_credit_funding_allocated_gbp

confirmed_balanced_yn =
  abs(statement_gbp_amount - normal_confirmed_allocated_gbp - loyalty_credit_funding_allocated_gbp) < 0.01
```

Existing breakdown columns must retain their narrow meanings:

```text
supplier_invoice_allocated_gbp = supplier invoice allocations only
retailer_refund_allocated_gbp = retailer refund allocations only
fx_card_or_fee_allocated_gbp = FX/card difference and bank fee allocations only
exception_or_hold_allocated_gbp = exception/hold/not-charged/unmatched hold allocations only
final_balance_payment_allocated_gbp = final balance allocations only, where already present
```

Do not hide loyalty funding inside supplier, refund, FX/fee, exception/hold, or final-balance columns.

## UI display rule

When `loyalty_credit_funding_allocated_gbp > 0`, statement-line cards must make the reason explicit.

Display label:

```text
Matched to loyalty credit funding
```

or, where space is tight:

```text
Loyalty credit funding
```

The line may still be shown as balanced/green where `confirmed_balanced_yn = true`, but the UI must not imply that the line was matched to a supplier invoice, refund, final-balance payment, FX/card difference, bank fee, or generic hold.

The UI should also expose the account context where possible:

```text
Main company bank
Importer DVA/card
Other statement account context
```

Do not remove main-company-bank lines from the DVA/card control hub. The goal is one consolidated staff control view with correct account context and explanation.

## Expected effect on existing pages

### `/internal/dva-reconciliation`

A main-bank loyalty-funded OUT line should remain visible, but it must no longer appear as an unmatched line requiring supplier/refund/fee/hold matching. It should show as consumed/balanced with reason `Matched to loyalty credit funding`.

### `/internal/dva-reconciliation/workspace`

A fully loyalty-consumed main-bank OUT line should not be treated as an unmatched allocation candidate. If selected from an all/balanced filter, its remaining amount should be zero.

### `/internal/dva-reconciliation/unmatched`

A fully loyalty-consumed main-bank OUT line should not appear in unmatched OUT triage because it no longer has an unallocated balance.

### `/internal/dva-reconciliation/review-pack`

The review pack should not show a false open balance for a loyalty-consumed line. It may show the line as balanced review unless/until the UI is explicitly updated to treat loyalty funding as a ready control explanation.

### `/internal/status-control/pre-sage-financial-readiness`

Importer-level open/unallocated statement warnings must not include amounts already consumed by confirmed/released main-bank loyalty funding matches.

## Defensive write-side guard for a later patch

The read-model correction is the immediate fix. A later defensive patch may update supplier allocation RPCs so that, for `statement_account_context = 'main_company_bank_account'`, they subtract existing main-bank loyalty and shipper AP consumption before allowing supplier allocation.

That later guard must be separately approved and tested. It must not be bundled with the narrow read-model/UI fix unless explicitly approved.

## Test case required before implementation is accepted

Use the known loyalty line from the June 2026 test evidence:

```text
order_ref: ORD-1777736251155
statement_line_id: 6b957851-f0cc-4247-af89-dff88a0ff87e
amount: £13.50 OUT
reference: TEST MAIN BANK LOYALTY MATCH 20260608175525290
auth/ref: JOINV2605v1
loyalty_match_status: released_available_dashboard_credit
```

Before patch, expected current defect:

```text
confirmed_allocated_gbp = 0
confirmed_unallocated_gbp = 13.50
confirmed_balanced_yn = false
match_status = unmatched
```

After patch, expected control result:

```text
loyalty_credit_funding_allocated_gbp = 13.50
confirmed_allocated_gbp = 13.50
confirmed_unallocated_gbp = 0.00
confirmed_balanced_yn = true
control_match_reason = loyalty_credit_funding
UI label = Matched to loyalty credit funding
```

No credit ledger rows, loyalty funding confirmation rows, Sage posting rows, supplier allocation rows, shipper AP allocation rows, or order-funding rows should be created, deleted, or changed by this read-model/UI patch.
