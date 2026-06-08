# Main Bank Loyalty Reward Funding Integration Addendum v1

Status: locked implementation addendum for integrating completion loyalty reward funding into the existing main-bank allocation workspace without changing the shipper AP flow.

This addendum extends:

- `COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
- the existing main-bank shipper AP allocation workspace and cash posting workbench flow

It does not supersede the shipper AP flow. Shipper AP remains the default and must continue to work exactly as already built.

## 1. Core decision

Use the same main-bank statement-line workspace.

Do not create a separate loyalty bank workspace.

The main-bank line itself does not need to know whether it is for shipper AP, completion loyalty, FX/card difference, or bank fee. The selected target mode and selected right-pane target determine the allocation/release action.

```text
Main-bank OUT line
→ target mode selected by supervisor
→ right-pane target selected
→ action runs only for that target type
```

Required target modes:

```text
shipper_ap
completion_loyalty
```

Optional residual classifications remain:

```text
fx_card_difference
bank_fee
unmatched_hold, if still deliberately supported by the existing residual flow
```

## 2. Shipper AP mode must remain untouched

Default mode:

```text
target = shipper_ap
```

Left pane:

```text
main-bank OUT statement lines
```

Right pane:

```text
posted/open shipper AP invoices
```

Confirm action:

```text
staff_allocate_main_bank_line_to_shipper_ap_v1(...)
```

Non-negotiables:

```text
- do not change staff_allocate_main_bank_line_to_shipper_ap_v1;
- do not change main_bank_shipper_ap_allocations for loyalty;
- do not change shipper AP target read model for loyalty;
- do not change shipper AP Sage posting downstream;
- do not change shipper_invoice_payment cash-posting category;
- do not make loyalty records look like shipper AP allocations.
```

The shipper build integrates only through the shared remaining-balance calculation on the selected main-bank statement line.

## 3. Completion loyalty mode

Mode:

```text
target = completion_loyalty
```

Left pane:

```text
main-bank OUT statement lines
```

Right pane:

```text
clean completed reward-eligible customer/importer orders
```

Minimum right-pane target eligibility:

```text
- original order;
- clean completion gates satisfied;
- final sale documents posted;
- final balance due is zero;
- export/POD evidence accepted/current;
- no active hold;
- no open dispute/exception;
- qualifying net spend basis is resolved;
- reward proposal is ready or can be approved in principle;
- no active existing completion loyalty reward approval/release for the same completed order;
- no unlocked completion_loyalty_reward credit already exists for the same completed order.
```

Confirm action must:

```text
1. require authenticated active supervisor/admin;
2. lock/re-read the selected main-bank statement line;
3. lock/re-read the selected reward-eligible completed order/proposal;
4. verify the selected main-bank line is OUT and belongs to the main company bank account;
5. verify the selected unreused amount on the main-bank line is enough for the released reward amount;
6. approve the reward in principle when no active approval already exists;
7. create/link funding evidence using the selected main-bank line;
8. confirm funding and release dashboard credit;
9. create importer_credit_ledger credit with source_type = completion_loyalty_reward and lock_reason = NULL;
10. record a loyalty-main-bank match row so the same bank-line amount cannot be reused by shipper, loyalty, FX, or fee flows.
```

This is a funded release control, not a clean-completion posting trigger.

## 4. Dashboard release behaviour

A completion loyalty amount becomes visible/spendable on the customer/importer dashboard only after funding proof is matched or confirmed.

Required released credit ledger treatment:

```text
importer_credit_ledger:
  entry_type = manual_credit
  direction = credit
  source_type = completion_loyalty_reward
  source_entity_type = order
  source_entity_id = completed_order_id
  source_table = completion_loyalty_reward_funding_confirmations, or the successor funding-match table
  source_id = funding_confirmation_id, or successor funding-match id
  lock_reason = NULL
```

Customer/dashboard result:

```text
released loyalty credit amount increases available account credit
future order may apply it through existing credit-application machinery
```

Do not release dashboard credit from proposal alone or approval-in-principle alone.

## 5. Residual treatment for bank fee and FX/card difference

If the selected main-bank line is not fully explained by the loyalty release or shipper AP allocation, residuals remain classified through the existing residual path.

### Bank fee example

```text
Main-bank OUT line: £27.00
Completion loyalty release: £25.00
Bank/provider fee: £2.00
```

Required result:

```text
£25.00 → completion loyalty funding match → dashboard credit released
£2.00  → bank_fee residual → cash posting workbench
```

Cash posting downstream:

```text
bank_fee
→ freeze
→ batch
→ batch detail
→ Sage /other_payments posting
```

### FX/card difference example

```text
Main-bank OUT line: £25.40
Completion loyalty release: £25.00
FX/card difference: £0.40
```

Required result:

```text
£25.00 → completion loyalty funding match → dashboard credit released
£0.40  → fx_card_difference residual → cash posting workbench
```

Cash posting downstream:

```text
fx_card_difference
→ freeze
→ batch
→ batch detail
→ Sage /journals posting
```

The integration must not create a new FX/fee posting flow. It must reuse the already-built residual-to-cash-posting-workbench path.

## 6. Shared main-bank remaining balance

The main-bank statement-line available balance must be calculated from all active confirmed allocations/matches that consume that bank line.

Minimum calculation:

```text
main_bank_line_remaining_gbp = statement_line_amount_gbp
  - confirmed shipper AP allocations
  - confirmed completion loyalty funding matches/releases
  - confirmed FX/card residual allocations
  - confirmed bank fee residual allocations
  - confirmed unmatched/hold allocations, if active
```

Consequences:

```text
- a line used for shipper AP is not available for loyalty;
- a line used for loyalty is not available for shipper AP;
- residual allocation reduces what remains available;
- over-selection is blocked;
- partial allocation remains possible only up to available remaining amount.
```

This is the integration point that protects the shipper build while adding loyalty mode.

## 7. Example flows

### A. Shipper AP plus residual

```text
Main-bank OUT line: £500.00
Selected shipper AP target: £495.00
Residual: £5.00 bank_fee
```

Expected outcome:

```text
£495.00 → main_bank_shipper_ap_allocations → cash posting workbench as shipper_invoice_payment
£5.00   → dva_statement_line_allocations as bank_fee → cash posting workbench as bank_fee
Remaining: £0.00
```

### B. Loyalty only

```text
Main-bank OUT line: £25.00
Selected completion loyalty target: completed order ORD-1001 reward £25.00
```

Expected outcome:

```text
£25.00 → completion loyalty funding match/confirmation
£25.00 → importer_credit_ledger available credit
Customer dashboard available credit increases by £25.00
Remaining: £0.00
```

### C. Loyalty plus FX/card residual

```text
Main-bank OUT line: £25.40
Selected completion loyalty target: completed order ORD-1001 reward £25.00
Residual: £0.40 fx_card_difference
```

Expected outcome:

```text
£25.00 → completion loyalty funding match/confirmation → dashboard credit released
£0.40  → fx_card_difference residual → cash posting workbench → Sage /journals downstream
Remaining: £0.00
```

### D. Loyalty plus bank fee residual

```text
Main-bank OUT line: £27.00
Selected completion loyalty target: completed order ORD-1001 reward £25.00
Residual: £2.00 bank_fee
```

Expected outcome:

```text
£25.00 → completion loyalty funding match/confirmation → dashboard credit released
£2.00  → bank_fee residual → cash posting workbench → Sage /other_payments downstream
Remaining: £0.00
```

## 8. Required build shape

Preferred smallest implementation:

```text
1. Add target-mode filter to existing /internal/dva-reconciliation/main-bank page.
2. Keep target=shipper_ap as default.
3. In shipper_ap mode, preserve current page behaviour and current action.
4. In completion_loyalty mode, use a new loyalty target read model for clean completed reward-eligible orders.
5. Add a new loyalty-main-bank match/release RPC; do not overload shipper allocation RPC.
6. Update main-bank statement-line remaining calculation to subtract loyalty funding matches.
7. Reuse existing FX/fee residual action for differences.
8. Revalidate both main-bank and completion-loyalty pages after loyalty match/release.
```

## 9. Forbidden shortcuts

Do not:

```text
- treat completion loyalty as shipper AP;
- reuse main_bank_shipper_ap_allocations for loyalty;
- bypass funding proof;
- release customer dashboard credit before matching/confirming the main-bank payment/top-up;
- create a separate loyalty bank workspace;
- create a new FX/fee posting engine;
- change shipper AP posting behaviour;
- change accepted-estimate funding threshold logic;
- change VAT return logic;
- merge loyalty with settlement/overfunding credit.
```

## 10. Acceptance checks

A build is acceptable only if:

```text
- shipper_ap mode still shows and allocates posted shipper AP invoices as before;
- completion_loyalty mode shows eligible completed reward targets separately;
- a loyalty match releases available dashboard credit only after main-bank/funding proof;
- the same main-bank amount cannot be consumed twice;
- bank_fee residuals appear in cash posting workbench and use the existing bank-fee downstream posting path;
- fx_card_difference residuals appear in cash posting workbench and use the existing FX journal downstream posting path;
- no shipper SQL/RPC/action is modified except, if necessary, shared remaining-balance read-model calculation that subtracts loyalty matches.
```
