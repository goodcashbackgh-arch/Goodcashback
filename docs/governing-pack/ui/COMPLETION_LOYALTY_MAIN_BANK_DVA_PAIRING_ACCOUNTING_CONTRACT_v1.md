# Completion Loyalty Main-Bank/DVA Pairing and Accounting Contract v1

## 0. Contract status

This is the locked build contract for completion loyalty reward control, customer credit presentation, main-bank/DVA or virtual-card transfer pairing, VAT timing, and Accounting Command Centre treatment.

This contract is deliberately narrow. It does not rebuild the existing loyalty, DVA, main-bank, VAT, supplier, Sage, shipper AP, or shipment flows. It defines the missing control/accounting layer needed to integrate completion loyalty safely.

Where current code releases completion loyalty from a main-bank OUT line alone, this contract supersedes that behaviour for new loyalty activations. New activations must not be treated as complete until the destination DVA/card or virtual-card IN line is paired or otherwise expressly confirmed under this contract.

## 1. Existing repo contracts this contract depends on

This contract must be read with, and must not silently override, the following existing repo contracts/migrations:

1. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
2. `docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_LOYALTY_AWARE_SUMMARY_ADDENDUM_v1.md`
3. `docs/governing-pack/ui/VAT_RETURN_WORKBENCH_PARTIAL_PREPAYMENT_ADDENDUM_v1.md`
4. `docs/governing-pack/ui/FUNDING_ACTION_CONTRACT.md`
5. `supabase/migrations/20260524_statement_account_context_v1.sql`
6. `supabase/migrations/20260608_main_bank_loyalty_funding_integration_v1.sql`
7. `supabase/migrations/20260621_dva_statement_summary_loyalty_aware_v1.sql`
8. `supabase/migrations/20260523_cash_posting_workbench_read_model_v1.sql`
9. `supabase/migrations/20260523_cash_out_shared_freeze_batch_v1.sql`
10. `supabase/migrations/20260615_vat_box6_partial_prepayment_from_order_funding_events_v1.sql`

This contract is additive. If a later implementation contract changes this behaviour, it must explicitly name this contract and explain the replacement rule.

## 2. Non-negotiable boundaries

Do not change the core flows below as part of this loyalty integration:

1. Do not change DVA reconciliation core.
2. Do not change main-bank shipper AP allocation logic.
3. Do not change supplier invoice/OCR.
4. Do not change shipper AP.
5. Do not change Sage sales invoice posting.
6. Do not change VAT sales invoice natural logic.
7. Do not change shipment/export/POD flow.
8. Do not create fake DVA/card allocations.
9. Do not create fake customer funding.
10. Do not make completion loyalty self-service.
11. Do not reuse shipper AP allocation tables for loyalty.
12. Do not reuse existing cash posting lanes by relabelling them.
13. Do not treat a main-bank OUT line alone as customer funding.
14. Do not treat a DVA/card/virtual-card IN top-up as customer cash.
15. Do not let internal transfer matching create VAT timing.

## 3. Existing loyalty gate remains

Keep the existing clean-order loyalty gate.

Completion loyalty remains blocked where the completed order is not clean, including:

1. final balance due;
2. active customer/importer hold;
3. open dispute, repair issue, claim, or exception;
4. incomplete completion state;
5. missing accounting coding;
6. unresolved treatment;
7. VAT-rate issue;
8. admin review required;
9. no qualifying physical-line basis;
10. existing active reward/credit for the same completed order.

No new loyalty flow may bypass this gate.

## 4. Loyalty decision layer

Add a supervisor/admin decision layer with two decisions:

```text
Approve in principle
Reject in principle
```

Rejected rewards must be stored separately from approvals.

Create:

```text
completion_loyalty_reward_rejections
```

Minimum columns:

```text
id
order_id
importer_id
rejection_reason_code
notes
proposal_snapshot_json
rejected_by_staff_id
rejected_at
active
reversed_at
reversed_by_staff_id
reversal_reason
created_at
updated_at
```

Rejected loyalty must not appear on the customer dashboard.

Rejected loyalty must not create importer credit, order funding, VAT timing, accounting rows, or Sage posting rows.

## 5. Customer credit model

Normal account credit and completion loyalty credit must remain separate.

Normal account credit remains customer self-service.

Completion loyalty remains staff-assisted.

The customer dashboard must show one simple card only:

```text
Your credit
Available account credit: £X
Loyalty reward: £Y pending activation
```

or:

```text
Your credit
Available account credit: £X
Loyalty reward: £Y ready to use
```

Backend mapping:

```text
approved_pending_funding = pending activation
released_available_dashboard_credit = ready to use
```

Do not show separate customer-facing cards for pending loyalty and released loyalty.

Do not blend completion loyalty into the normal available account credit figure.

Local currency guidance may appear as helper text inside the card, not as a separate card.

## 6. Customer auto-apply guard

Customer self-service and new-order auto-apply must exclude credit lots where:

```text
source_type = completion_loyalty_reward
```

Normal self-service credit may continue for:

```text
settlement_credit
overfunding
refund_resolution
liability_settlement
payout_reversal
manual
```

Do not change the customer order creation structure except the source-lot filter used by customer auto-apply.

## 7. Staff-only loyalty application to order

Add staff-only action:

```text
Apply loyalty to order
```

This action is separate from loyalty activation.

It must:

1. consume only available `completion_loyalty_reward` lots;
2. debit `importer_credit_ledger`;
3. insert `order_funding_events` with `event_type = credit_applied`;
4. link the event to the loyalty debit ledger row;
5. close the order/customer balance gap.

Example:

```text
Sales invoice/order value: £100
Customer cash funding: £80
Loyalty applied: £20
Customer balance due: £0
```

This is the point at which loyalty affects the order balance.

## 8. Activation routes

Use only two activation routes:

```text
DVA/account top-up
Virtual card top-up
```

Do not create “purchase on behalf” as a separate route.

“Card used by customer” or “card used by staff/supervisor” is a usage field only.

For MVP, virtual-card statements should use the existing importer DVA/card account context unless the live schema is separately extended. Do not introduce a new statement account context unless expressly agreed.

## 9. Corrected main-bank loyalty activation model

The existing table should be extended, not replaced:

```text
main_bank_completion_loyalty_funding_matches
```

Add nullable columns:

```text
destination_in_statement_line_id
activation_route
card_used_by
transfer_pair_status
paired_at
paired_by_staff_id
variance_gbp
variance_reason
```

The existing active-order uniqueness protection must remain.

Existing historical rows may remain valid as legacy OUT-only records. New rows must follow the paired model.

## 10. Two-step activation control

New activations must follow a two-step control.

### 10.1 Step 1: stage main-bank OUT

Create a v2 RPC, for example:

```text
staff_stage_main_bank_line_to_completion_loyalty_v2
```

It must:

1. require active supervisor/admin;
2. validate selected line is from `main_company_bank_account`;
3. validate selected line direction is `out`;
4. validate remaining unconsumed amount is sufficient;
5. approve reward in principle if needed;
6. insert/update `main_bank_completion_loyalty_funding_matches`;
7. set `match_status = confirmed`;
8. set `transfer_pair_status = source_out_reserved`;
9. not call `staff_confirm_completion_loyalty_reward_funding_v1`;
10. not create `importer_credit_ledger`;
11. not release dashboard credit;
12. not create `order_funding_events`;
13. not affect VAT.

The main-bank OUT amount is reserved and cannot be reused for shipper AP, FX, fee, hold, or another loyalty reward.

### 10.2 Step 2: pair destination IN and release

Create a second RPC, for example:

```text
staff_pair_loyalty_destination_in_and_release_v1
```

It must:

1. require active supervisor/admin;
2. lock the staged loyalty match row;
3. validate destination line direction is `in`;
4. validate destination line belongs to the same importer;
5. validate destination amount is sufficient;
6. validate destination line is not already consumed;
7. set `destination_in_statement_line_id`;
8. set `transfer_pair_status = paired_ready_to_release`;
9. call `staff_confirm_completion_loyalty_reward_funding_v1` using the destination IN statement line;
10. store `funding_confirmation_id`;
11. store `credit_ledger_id`;
12. set `match_status = released_available_dashboard_credit`;
13. set `paired_at` and `paired_by_staff_id`.

Only after this step does the loyalty become visible as “ready to use”.

## 11. One-action UI behaviour

The UI may feel like one workflow.

On the activation form:

```text
Select main OUT
Select DVA/virtual IN if already uploaded
Activate loyalty credit
```

If both sides exist, the action may stage and release in one call chain.

If only main OUT exists:

```text
Status: Main OUT reserved — waiting for DVA/virtual IN
```

If only DVA/virtual IN exists:

```text
Status: DVA/virtual IN available — waiting for Main OUT
```

Do not create a separate loyalty bank workspace.

## 12. Main-bank workbench protection

Keep `/internal/dva-reconciliation/main-bank` as the shared workspace.

Default target mode remains:

```text
shipper_ap
```

Add or preserve target mode:

```text
completion_loyalty
```

Shipper AP must remain untouched:

1. do not change `staff_allocate_main_bank_line_to_shipper_ap_v1`;
2. do not reuse `main_bank_shipper_ap_allocations` for loyalty;
3. do not change shipper AP posting behaviour;
4. do not make loyalty look like shipper AP.

The shared remaining-balance calculation must subtract:

```text
confirmed shipper AP allocations
confirmed/staged loyalty source OUT reservations
confirmed FX/card residuals
confirmed bank fees
confirmed holds
```

This protects the main-bank workbench from double consumption.

## 13. DVA/card statement workbench protection

The DVA/card statement-line summary must recognise both sides of the loyalty transfer.

For the source OUT line:

```text
control_match_reason = loyalty_internal_transfer_out
confirmed_allocated_gbp includes matched amount
confirmed_unallocated_gbp = 0 when fully matched
confirmed_balanced_yn = true when fully matched
```

For the destination IN line:

```text
control_match_reason = loyalty_internal_transfer_in
confirmed_allocated_gbp includes matched amount
confirmed_unallocated_gbp = 0 when fully matched
confirmed_balanced_yn = true when fully matched
```

This must be read-model only.

Do not create fake `dva_statement_line_allocations`.

## 14. Accounting treatment

There are four separate accounting meanings:

```text
customer cash receipt
internal bank transfer
non-cash loyalty settlement
supplier/card payment
```

They must never be mixed.

### 14.1 Customer cash receipt

```text
Dr DVA/card/bank
Cr customer account / payment on account
```

### 14.2 Internal transfer

```text
Dr DVA/card/virtual-card bank
Cr main bank
```

This is not customer funding.

### 14.3 Loyalty applied to order

```text
Dr loyalty cost / reward expense / loyalty liability
Cr customer account / receivable
```

This is non-cash settlement of the customer balance.

### 14.4 Supplier/card spend

```text
Dr supplier payable / purchase-payment flow
Cr DVA/card/virtual-card bank
```

## 15. Accrual accounting rule for MVP

For the minimum build:

```text
pending loyalty = no posting
staged main OUT = no P&L posting
released but unused loyalty = control balance only
applied loyalty = accounting event
```

Do not automatically post an accrual at release in this MVP.

However, the system must expose released unused loyalty in a read-only month-end report so an accounting decision can be made later if material.

This avoids overbuilding accrual automation before the accounting policy and mappings are locked.

## 16. Accounting Command Centre

Do not relabel existing cash lanes.

Existing lanes remain:

```text
customer_receipt_on_account
supplier_invoice_payment
shipper_invoice_payment
retailer_refund_received
bank_fee
fx_card_difference
unmatched_hold
```

Add read-only accounting-control lanes first:

```text
bank_internal_transfer
non_cash_loyalty_customer_balance_settlement
released_unused_loyalty_control_balance
```

These new rows must not be selectable in the existing cash freeze/batch/post flow.

No posting button is allowed until the Sage account mapping and journal/payment endpoint are confirmed.

## 17. VAT return rule

Do not rebuild the VAT return engine.

The existing VAT timing engine already uses `order_funding_events`.

VAT effect:

```text
pending loyalty = no VAT effect
staged main OUT = no VAT effect
paired/released unused loyalty = no VAT effect
applied loyalty to order = credit_applied
reversed applied loyalty = funding_reversed
```

Keep `credit_applied` in VAT timing.

Do not exclude loyalty-sourced `credit_applied`.

Do not create VAT timing from the internal bank transfer.

The event date determines whether the applied loyalty is pre-invoice Box 6 timing or naturally covered by the Sage sales invoice period.

## 18. VAT examples

### Example A: loyalty applied before invoice period

```text
Sales invoice/order value: £100
Customer cash before invoice period: £80
Loyalty applied before invoice period: £20

VAT Box 6 prepayment timing = £100
```

### Example B: loyalty applied in invoice period

```text
Sales invoice/order value: £100
Customer cash before invoice period: £80
Loyalty applied in invoice period: £20

VAT Box 6 prepayment timing = £80
£20 naturally covered by sales invoice period
```

### Example C: loyalty released but unused

```text
Released loyalty: £20
No order application yet

VAT effect = £0
Customer balance effect = £0
```

## 19. Reversal rules

### 19.1 Rejection before approval

No accounting reversal.

### 19.2 Rejection after approval but before staging

No accounting reversal.

### 19.3 Staged main OUT reversed before destination IN pairing

Reverse or mark the match row as reversed.

No VAT reversal.

No customer balance reversal.

No credit ledger reversal.

### 19.4 Released loyalty reversed before application

Reverse or lock the released credit ledger.

No VAT reversal unless a `credit_applied` event already existed.

### 19.5 Applied loyalty reversed

Insert `order_funding_events.funding_reversed`.

Reverse the non-cash loyalty settlement accounting row.

Do not edit a locked historical VAT return directly. Use the VAT workbench source-line/current-period correction pattern.

## 20. Customer dashboard

Customer dashboard shows one card:

```text
Your credit
Available account credit: £X
Loyalty reward: £Y pending activation / ready to use
```

No technical labels.

No separate “pending credit” card.

No separate “released credit” card.

No fake available credit total.

## 21. Completion loyalty page UI

Group actions:

```text
Reward decision
- Approve
- Reject

Activation
- Activate loyalty credit

Usage
- Apply loyalty to order
```

Do not show four equal buttons in one flat row.

Internal loyalty card should show:

```text
reward amount
decision status
activation route
main OUT status
DVA/virtual IN status
transfer pair status
amount released
amount applied to orders
remaining loyalty balance
```

## 22. Required build order

Build in this order:

1. Add rejection table/RPC/read-model.
2. Patch customer credit source filters to exclude loyalty from self-service/auto-apply.
3. Add staff-only apply-loyalty-to-order action.
4. Extend `main_bank_completion_loyalty_funding_matches` with destination/pair fields.
5. Add v2 stage-main-OUT RPC.
6. Add pair-IN-and-release RPC.
7. Patch main-bank UI to call the v2 paired flow.
8. Patch statement summary read model to show both OUT and IN control reasons.
9. Add read-only Accounting Command Centre rows.
10. Add tests.
11. Only later add posting buttons if mappings are confirmed.

## 23. Required tests

Minimum tests:

1. Clean completed order becomes reward-ready.
2. Dirty order is blocked.
3. Supervisor approves reward.
4. Supervisor rejects reward.
5. Rejected reward does not show to customer.
6. Approved pending reward shows pending activation.
7. Main OUT can be staged without releasing loyalty.
8. Staged main OUT reduces remaining available amount.
9. Destination DVA/virtual IN can be paired later.
10. Paired IN releases loyalty.
11. Same main OUT cannot be reused for shipper AP.
12. Same main OUT cannot be reused for another loyalty reward.
13. Same destination IN cannot be reused.
14. Customer auto-apply ignores loyalty.
15. Staff applies loyalty to order.
16. £100 order / £80 cash / £20 loyalty produces £0 balance due.
17. Pending loyalty has no VAT effect.
18. Staged OUT has no VAT effect.
19. Released unused loyalty has no VAT effect.
20. Applied loyalty creates `credit_applied`.
21. VAT timing uses event date correctly.
22. Reversed applied loyalty creates `funding_reversed`.
23. Main OUT summary shows internally matched.
24. Destination IN summary shows internally matched.
25. No fake DVA allocation rows are created.
26. Existing shipper AP allocation still works.
27. Existing customer cash receipt lane still works.
28. Existing supplier/card payment lane still works.
29. Accounting Command Centre does not let new read-only lanes freeze/post.
30. No VAT return totals change until loyalty is applied to an order.

## 24. Final build principle

Do not rebuild the platform.

Do not rebuild VAT.

Do not rebuild main-bank or DVA workbenches.

Do not reuse current accounting lanes by changing descriptions.

Do not fake customer funding.

The seamless integration is:

```text
extend the existing main-bank loyalty match
stage OUT first
pair DVA/virtual IN before release
release loyalty only after both sides are matched
apply loyalty to orders only by staff
let VAT handle applied loyalty through existing credit_applied timing
keep internal transfer and non-cash settlement accounting separate
```
