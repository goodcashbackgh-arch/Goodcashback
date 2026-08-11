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

However, the shared `dva_statement_line_allocation_summary_vw` originally derived its allocation totals only from `dva_statement_line_allocations`. It did not count `main_bank_completion_loyalty_funding_matches`. Therefore a real main-bank OUT line already consumed by loyalty funding could still appear in the DVA/card control hub, matching workspace, unmatched OUT triage, review pack, and pre-Sage readiness views as unmatched/open.

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

`dva_statement_line_allocation_summary_vw` remains the established compatibility statement-line summary. It is not the canonical monetary authority for economic availability; that authority is the later amount-aware statement-line control chain governed elsewhere.

The existing column order and types must be preserved. Any later compatibility correction must preserve the existing loyalty source and destination fields and must not remove or rename them.

The loyalty-aware compatibility fields are:

```text
statement_account_context
statement_account_label
source_bank
loyalty_credit_funding_allocated_gbp
main_bank_loyalty_match_count
control_match_reason
loyalty_internal_transfer_out_gbp
loyalty_internal_transfer_in_gbp
loyalty_internal_transfer_in_count
```

## Confirmed amount calculation

For statement-line compatibility display, confirmed consumed amount includes both normal allocation rows and confirmed/released completion-loyalty funding matches.

Use this loyalty control calculation:

```text
normal_confirmed_allocated_gbp =
  sum(dva_statement_line_allocations.allocated_gbp_amount)
  where allocation_status = 'confirmed'

loyalty_credit_funding_allocated_gbp =
  sum(main_bank_completion_loyalty_funding_matches.matched_gbp_amount)
  where match_status in ('confirmed', 'released_available_dashboard_credit')
```

The summary may also include other independently governed consumption families in its aggregate compatibility fields, provided that:

- loyalty amounts are counted exactly once;
- loyalty-specific breakdown fields retain their narrow meanings;
- source-OUT and destination-IN completion-loyalty handling remains present;
- no loyalty amount is reclassified as supplier, refund, FX/fee, exception/hold or final-balance allocation;
- the existing column order and row filtering remain preserved.

Existing breakdown columns retain their narrow meanings:

```text
supplier_invoice_allocated_gbp = supplier invoice allocations only
retailer_refund_allocated_gbp = retailer refund allocations only
fx_card_or_fee_allocated_gbp = FX/card difference and bank fee allocations only
exception_or_hold_allocated_gbp = exception/hold/not-charged/unmatched hold allocations only
final_balance_payment_allocated_gbp = final balance allocations only
```

## Compatibility-preservation rule for later statement-consumption corrections

Any later change to `dva_statement_line_allocation_summary_vw`, including the 11 August 2026 order-funding compatibility correction, must start from the exact deployed view definition and preserve all loyalty-aware behaviour established by this addendum.

Specifically, a later migration must not:

- replace the deployed loyalty source/destination logic with an older source-only definition;
- remove `loyalty_internal_transfer_out_gbp`;
- remove `loyalty_internal_transfer_in_gbp`;
- remove `loyalty_internal_transfer_in_count`;
- change the existing loyalty branch precedence in `control_match_reason` except where explicitly governed;
- remove the deployed voided-import exclusion wrapper;
- append unrelated replacement columns that alter the established view contract.

A later aggregate-consumption fix may change only the exact aggregate fields authorised by its own governing addendum. All loyalty-specific columns and semantics are frozen unless a separate loyalty change is approved.

## UI display rule

When loyalty funding is the control explanation, statement-line cards must make the reason explicit.

Display label:

```text
Matched to loyalty credit funding
```

or, where space is tight:

```text
Loyalty credit funding
```

The line may still be shown as balanced/green where the compatibility aggregate says balanced, but the UI must not imply that the line was matched to a supplier invoice, refund, final-balance payment, FX/card difference, bank fee, or generic hold.

The UI should also expose the account context where possible:

```text
Main company bank
Importer DVA/card
Other statement account context
```

Do not remove main-company-bank lines from the DVA/card control hub.

## Expected effect on existing pages

### `/internal/dva-reconciliation`

A main-bank loyalty-funded OUT line should remain visible, but it must no longer appear as an unmatched line requiring supplier/refund/fee/hold matching.

### `/internal/dva-reconciliation/workspace`

A fully loyalty-consumed main-bank OUT line should not be treated as an unmatched allocation candidate. If selected from an all/balanced filter, its remaining amount should be zero.

### `/internal/dva-reconciliation/unmatched`

A fully loyalty-consumed main-bank OUT line should not appear in unmatched OUT triage because it no longer has an unallocated balance.

### `/internal/dva-reconciliation/review-pack`

The review pack should not show a false open balance for a loyalty-consumed line.

### `/internal/status-control/pre-sage-financial-readiness`

Importer-level open/unallocated statement warnings must not include amounts already consumed by confirmed/released main-bank loyalty funding matches.

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

The compatibility summary must continue to recognise the existing loyalty consumption with no synthetic allocation rows and without changing loyalty funding, credit-ledger, shipper, supplier, funding or Sage data.

Any later migration touching the summary view must regression-test preservation of this loyalty source/destination behaviour in addition to its own new scope.