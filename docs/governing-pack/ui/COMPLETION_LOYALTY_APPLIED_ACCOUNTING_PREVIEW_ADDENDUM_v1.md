# Completion Loyalty Applied Accounting Preview Addendum v1

Status: locked clarification addendum to `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md` dated 23 June 2026.

This addendum does not replace the main 23 June 2026 completion-loyalty contract. It clarifies the next Sage/accounting integration step so the implementation does not accidentally revive the older 7 June 2026 approval-stage loyalty Sage queue.

## 1. Reason for this addendum

The earlier loyalty Sage addendum and migration created an approval-stage Sage-ready lane for `completion_loyalty_reward_journal` based on locked/released loyalty credit.

The 23 June 2026 contract supersedes that approach for the current MVP accounting flow:

```text
pending loyalty = no posting
staged main OUT = no P&L posting
released but unused loyalty = control balance only
applied loyalty = accounting event
```

Therefore, the next build must not restore the old approval-stage Sage-ready queue. The next build must create a read-only applied-loyalty accounting/Sage mapping preview only.

## 2. Boundaries

Do not:

```text
- restore the old approval-stage `completion_loyalty_reward_journal` queue;
- post released-unused loyalty to Sage;
- unlock credit from this preview;
- create a Sage posting button;
- create a cash freeze/batch/post selectable row;
- create fake customer funding;
- create fake DVA/card allocations;
- treat main-bank OUT or DVA/card IN transfer matching as customer cash;
- create new VAT timing outside the existing `order_funding_events` logic;
- change Sage sales invoice posting;
- change VAT return logic;
- change main-bank shipper AP logic;
- change DVA/card reconciliation core.
```

## 3. Source event for the applied-loyalty accounting preview

The only source for the preview is an actual staff-applied loyalty event:

```text
order_funding_events.event_type = 'credit_applied'
```

where the linked source credit is:

```text
importer_credit_ledger.source_type = 'completion_loyalty_reward'
```

The source chain must be:

```text
completion loyalty credit ledger row
  -> loyalty debit ledger row applied to order
  -> order_funding_events.credit_applied
```

Do not build the preview from pending approval, staged main-bank OUT, paired/released unused credit, or DVA/card transfer lines.

## 4. Read-only RPC/view

Create an additive read-only RPC or view, recommended name:

```text
internal_completion_loyalty_applied_accounting_preview_v1()
```

or, if the implementation uses a view:

```text
completion_loyalty_applied_accounting_preview_vw
```

Minimum output fields:

```text
preview_row_id
source_table = 'order_funding_events'
source_id = order_funding_events.id
order_id
order_ref
importer_id
importer_name
amount_gbp
source_credit_ledger_id
debit_ledger_id
order_funding_event_id
accounting_event_type = 'non_cash_loyalty_customer_balance_settlement'
readiness_status
blocker
selectable = false
posting_enabled = false
reference_text
notes_text
posting_preview_json
mapping_status_json
created_at
```

## 5. Accounting treatment

For applied completion loyalty, the preview must show the 23 June 2026 accounting treatment:

```text
Dr loyalty cost / reward expense / loyalty liability
Cr customer account / receivable
```

This is non-cash settlement of the customer balance.

The preview must not use the old approval-stage treatment as the active posting basis:

```text
Dr loyalty reward expense
Cr customer credit liability
```

unless a later, separately locked Sage posting contract explicitly reintroduces a liability model and explains how it coexists with applied-loyalty settlement.

## 6. Mapping status

The preview may inspect Sage mapping readiness, but missing mappings must not hide the row.

Rows should remain visible with a blocker such as:

```text
blocked_sage_mapping_required
```

or:

```text
preview_only_mapping_not_confirmed
```

The preview must not become postable merely because mappings appear present. Posting remains disabled until a later explicit posting contract confirms:

```text
- exact debit mapping code;
- exact credit mapping code;
- whether the credit side is receivable, clearing, customer account, or liability release;
- Sage endpoint;
- request payload;
- idempotency key;
- response logging table/columns;
- reversal behaviour;
- UI action authority;
- production feature flag.
```

## 7. UI placement

Place the preview in Accounting Command Centre loyalty controls, not the generic Sage-ready posting queue.

Recommended placement:

```text
/internal/accounting-command-centre/loyalty-controls
```

Add a section or tab:

```text
Applied loyalty accounting / Sage mapping preview
```

The UI must clearly show:

```text
Read-only preview
Not selectable
No Sage posting enabled
Mappings required before posting
```

## 8. VAT rule

The preview must create no VAT lines and no VAT return source rows.

VAT timing remains governed by the existing `order_funding_events` engine:

```text
pending loyalty = no VAT effect
staged main OUT = no VAT effect
paired/released unused loyalty = no VAT effect
applied loyalty to order = credit_applied
reversed applied loyalty = funding_reversed
```

The preview is accounting visibility only.

## 9. Relationship to the old 7 June 2026 loyalty Sage queue

The old approval-stage queue row type must remain suppressed from the current Sage-ready queue:

```text
completion_loyalty_reward_journal
```

Do not re-enable it as part of this preview build.

If a future contract decides to post at approval/release, that future contract must explicitly name this addendum and explain why the 23 June 2026 applied-event rule is being replaced or extended.

## 10. Required tests before implementation is accepted

The implementation must prove:

```text
1. old approval-stage `completion_loyalty_reward_journal` remains suppressed;
2. pending loyalty does not appear in the preview;
3. staged main-bank OUT does not appear in the preview;
4. released unused loyalty does not appear as postable;
5. applied loyalty `credit_applied` events appear in the preview;
6. preview amount equals the completion-loyalty-sourced applied amount;
7. rows are non-selectable;
8. posting is disabled;
9. missing mappings produce a blocker but do not hide rows;
10. no VAT source rows are created;
11. no Sage posting records are written;
12. existing Sage-ready queues for customer sales, supplier/AP, shipper/AP, cash receipts, and VAT journals are unchanged.
```

## 11. Final implementation principle

The seamless integration is:

```text
keep approval/release out of Sage posting for this MVP
show released unused loyalty as control balance only
use staff-applied loyalty as the accounting event
show applied loyalty in a read-only ACC/Sage mapping preview
keep rows non-selectable and non-postable
only add live posting after mappings, endpoint, idempotency, logging, and reversal rules are separately locked
```
