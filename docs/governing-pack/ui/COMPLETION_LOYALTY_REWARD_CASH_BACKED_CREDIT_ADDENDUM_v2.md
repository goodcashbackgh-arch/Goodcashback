# Completion Loyalty Reward Cash-Backed Credit Addendum v2

Status: locked as the corrected governing treatment for completion loyalty rewards. This document supersedes `COMPLETION_LOYALTY_REWARD_AND_SAGE_POSTING_ADDENDUM_v1.md` for future build work.

This addendum governs the completion loyalty reward after the agreed correction: the reward is proposed after clean completion, but it does not become dashboard credit until the supervisor has funded or paid the customer DVA/customer account and that funding evidence is confirmed.

## 1. Accounting and control principle

The completion loyalty reward is not customer-owned overfunding and is not a sales discount at the original completed order stage.

It is a business-funded loyalty benefit that becomes spendable only after the business has funded the customer's DVA/customer account.

Required treatment:

```text
Clean completion:
- reward may be proposed;
- no available dashboard credit;
- no customer can spend it;
- no ordinary settlement/overfunding credit is created.

Supervisor funding/payment:
- supervisor/admin transfers or pays the approved reward amount to the customer DVA/customer account;
- funding evidence or matched DVA/card statement line is required;
- only after this proof may the platform approve/release dashboard credit.

Future use:
- once released, the credit may use the existing platform credit-application machinery against a later order.
```

Default customer funding flow for a future £100 order using £30 loyalty credit:

```text
Invoice/order value:       £100
Dashboard loyalty credit:   £30
Customer new cash/DVA:      £70
Order funding total:       £100
```

Sage/customer-account economic result on use:

```text
Invoice:
Dr Customer account        £100
Cr Sales                   £100

Reward/customer account funding, once funded/released:
Dr Loyalty reward expense   £30
Cr Customer account         £30

Customer payment:
Dr Bank / DVA clearing      £70
Cr Customer account         £70

Net customer account         £0
```

If the cash movement into the DVA/customer account is itself represented as a bank transfer in Sage, the build must preserve that bank/DVA reconciliation trail. The reward expense must not be posted merely because an order completed cleanly.

## 2. Relationship to existing credit families

Existing credit families remain separate:

```text
Settlement credit / overfunding:
- customer-owned value from prior funding or final-sale settlement;
- may become available customer credit through existing controls;
- no loyalty P&L cost is created merely by recognising customer-owned funds.

Completion loyalty reward:
- business-funded value;
- must remain proposal/pending funding until the supervisor funds or pays the customer DVA/customer account;
- may become available dashboard credit only after funding proof.
```

Do not merge loyalty reward accounting with settlement credit, overfunding, or final-balance correction logic.

## 3. Required upstream completion gates

A loyalty reward can be proposed only after all of the following are true:

```text
- final sale documents are posted;
- customer sale is not partial;
- final balance due is zero;
- shipment scope is fully allocated or formally closed;
- export evidence is accepted/current;
- POD/delivery evidence is accepted/current;
- no active customer hold;
- no open dispute/exception;
- all physical items are progressed;
- all non-physical, default-N, delivery, discount, fee, credit, refund, return, or excluded lines are explicitly parked, resolved, or exception-linked;
- no unresolved default-N supplier invoice lines remain;
- qualifying net spend is confirmed from coded/resolved standard-rate components.
```

No reward proposal may bypass the Platform Operational Status Engine, the Final Sale Value and Balance Due Addendum, or the Non-physical Supplier Invoice Line Resolution Contract.

## 4. Qualifying net spend basis

Default proposal:

```text
suggested_reward_gbp = qualifying_net_spend_gbp * 10%
qualifying_net_spend_gbp = qualifying_signed_gross_basis_gbp / 1.20
```

Include only signed, supported, standard-rate qualifying components:

```text
+ qualifying physical goods gross
+ qualifying delivery/charge gross where classified as qualifying
- qualifying discount gross where linked/apportioned to qualifying spend
- qualifying credit/refund/return gross where linked to qualifying spend
```

Block proposal until resolved:

```text
- unresolved default-N supplier invoice lines;
- unclassified delivery/discount/fee rows;
- unknown-rate rows;
- non-20% rows where allocation against qualifying spend cannot be isolated;
- order-level discounts that cannot be apportioned safely;
- open disputes;
- active holds;
- partial shipment/export/POD/customer sale coverage;
- final balance still due;
- existing funded/released completion loyalty credit for the same completed order.
```

## 5. Reward states

The loyalty reward lifecycle is:

```text
not_eligible
eligible_for_proposal
proposed_pending_supervisor_review
approved_pending_funding
funding_submitted_pending_match
funding_confirmed_ready_to_release
released_available_dashboard_credit
applied_to_future_order
voided_or_rejected
```

Minimum state meanings:

```text
approved_pending_funding:
- supervisor/admin has approved the amount in principle;
- no dashboard credit is available;
- no customer spendable credit exists.

funding_submitted_pending_match:
- supervisor/admin has recorded payment/top-up evidence;
- DVA/card/bank evidence is not yet confirmed.

funding_confirmed_ready_to_release:
- payment/top-up evidence or DVA/card statement line has been matched;
- platform may now create/release available customer credit.

released_available_dashboard_credit:
- available credit exists in platform credit ledger;
- dashboard may show it as available account credit.

applied_to_future_order:
- existing credit-application machinery has applied the credit to a later order.
```

## 6. Proposal read model

Use or extend:

```text
internal_completion_loyalty_reward_proposals_v1()
```

The read model remains read-only. It must not:

```text
- create customer credit;
- alter order funding;
- alter sales invoices;
- post to Sage;
- alter supplier invoice line states;
- show credit as dashboard-available.
```

Minimum fields should include:

```text
order_id
order_ref
importer_id
completion_state
completion_blocker
basis_status
basis_blocker
qualifying_signed_gross_basis_gbp
qualifying_net_spend_gbp
default_reward_rate_pct
suggested_reward_gbp
existing_reward_credit_id
existing_reward_credit_status
proposal_status
funding_status
release_status
```

## 7. Supervisor approval and funding proof

The old v1 flow is superseded:

```text
Old v1 flow, do not continue:
approval -> locked importer_credit_ledger credit -> Sage-ready reward journal -> unlock
```

Correct v2 flow:

```text
proposal -> supervisor approval in principle -> supervisor funds/pays customer DVA/customer account -> proof/match -> release available dashboard credit
```

Supervisor/admin approval must:

```text
1. require authenticated active staff;
2. require supervisor/admin authority;
3. re-read proposal/readiness state at approval time;
4. block incomplete/partial/unresolved/open-hold/open-dispute/final-balance states;
5. require positive approved amount;
6. create an audit record for approved_pending_funding;
7. not create available dashboard credit;
8. not create ordinary settlement/overfunding credit;
9. not post to Sage merely because the reward is approved in principle.
```

Funding confirmation must:

```text
1. require supervisor/admin authority;
2. link to the approved loyalty reward decision;
3. require payment/top-up evidence or a matched DVA/card/bank statement line;
4. verify the funded amount equals or exceeds the approved reward amount, or require explicit supervisor exception for a lower released amount;
5. prevent duplicate funded releases for the same completed order;
6. then create or unlock available platform credit.
```

## 8. Platform credit ledger treatment after funding proof

Only after funding proof is confirmed may the platform create/release dashboard credit.

Ledger entry after funding proof:

```text
source_type = 'completion_loyalty_reward'
source_entity_type = 'order'
source_entity_id = completed_order_id
entry_type = 'manual_credit'
direction = 'credit'
amount_gbp = funded/released reward amount
lock_reason = NULL
notes = 'Completion loyalty reward funded and released after supervisor-confirmed DVA/customer account top-up.'
```

Before funding proof, the reward must not be included in available customer/importer credit balance.

## 9. Future order application

Once released, the credit may use the existing platform credit application pattern:

```text
importer_credit_ledger debit
source_type = 'credit_application'
applied_to_order_id = future_order_id

order_funding_events
event_type = 'credit_applied'
source_entity_type = 'importer_credit_ledger'
source_entity_id = credit application debit id
```

The future order funding total may include:

```text
cash/DVA/card funding + applied loyalty credit = order funding requirement
```

Do not change `recompute_order_platform_funded(...)` or accepted-estimate funding threshold rules.

## 10. Sage/accounting posting rules

There is no Sage posting merely on clean completion or proposal.

There is no Sage posting merely because a supervisor approves a reward in principle.

The accounting recognition occurs when the business funds/pays/releases the reward to the customer DVA/customer account.

Do not use:

```text
Sales Discounts
VAT cashback
VAT refund
VAT share
tax refund
HMRC refund share
generic customer credit liability as the customer-facing posting target where customer-account netting is required
```

Permitted posting patterns depend on the Sage account design, but the build must preserve customer-account netting and cash/DVA evidence:

```text
If Sage can post the reward directly to the customer account/contact:
Dr Loyalty reward expense
Cr Customer account/contact

If the actual cash movement to a customer-controlled DVA/account is posted as the source transaction:
Dr Loyalty reward expense
Cr Bank / DVA funding source

If the DVA is a company-controlled funding account and the customer account must also show credit:
Record the bank/DVA transfer separately, and post the customer-account credit so the later invoice nets correctly.
```

The posting must not reduce sales revenue unless a separate future contract deliberately changes the reward into a sales discount/credit-note model.

## 11. UI placement

Internal supervisor/admin UI should show tabs or sections for:

```text
Completion reward proposals
Approved pending funding
Funding submitted / evidence pending
Funding confirmed ready to release
Released dashboard credit
Applied / audit
```

Customer/importer UI may show:

```text
Earned reward pending funding/release
Available account credit
Applied account credit
```

Customer/importer UI must not show proposed, blocked, rejected, or unconfirmed-funded rewards as spendable credit.

## 12. Non-goals

Do not:

```text
- change accepted-estimate funding threshold;
- change recompute_order_platform_funded(...);
- create available loyalty credit before supervisor funding proof;
- post reward expense at clean completion only;
- post reward expense at approval-in-principle only;
- use Sales Discounts as the default treatment;
- merge loyalty reward with settlement credit or overfunding credit;
- bypass DVA/card/bank evidence where the agreed control requires customer DVA/account funding first;
- bypass existing future-order credit application controls;
- change VAT return source snapshots or VAT return logic.
```

## 13. Acceptance tests

### Scenario A — clean completed order, no funding yet

```text
Final sale posted: yes
Export evidence accepted: yes
POD accepted: yes
No dispute/hold: yes
All physical lines progressed: yes
All non-physical/default-N lines parked/resolved/exception-linked: yes
Qualifying net spend: £250
Suggested reward at 10%: £25
```

Expected:

```text
proposal appears
status = proposed_pending_supervisor_review or approved_pending_funding after supervisor approval
available dashboard credit = £0
no Sage posting from proposal alone
```

### Scenario B — supervisor has not funded customer DVA/account

Expected:

```text
release blocked
customer cannot spend reward
no importer_credit_ledger unlocked completion_loyalty_reward credit
```

### Scenario C — supervisor funds customer DVA/account and evidence is matched

```text
Approved reward: £25
Matched funding evidence: £25
```

Expected:

```text
funding_confirmed_ready_to_release
available platform credit may be created with source_type = completion_loyalty_reward
lock_reason = NULL
customer/importer dashboard may show £25 available account credit
```

### Scenario D — future order uses released reward

```text
Future order value: £100
Applied loyalty credit: £25
Customer new DVA/card payment: £75
```

Expected:

```text
order_funding_events includes credit_applied £25
customer pays/funds £75
order funding total = £100
customer account nets to nil after invoice, reward credit, and payment
```

### Scenario E — unresolved default-N line

```text
eligible_for_invoice_yn = N
no active non-physical resolution
no active dispute/refund/replacement link
```

Expected:

```text
no reward proposal
blocker = unresolved_default_n
```

## 14. Build consequence from v1

Any code already built from v1 that queues the reward approval itself for Sage posting must be treated as superseded.

Required correction:

```text
- stop using approval as the Sage-ready trigger;
- introduce funding-proof / DVA-payment confirmation before dashboard credit release;
- use existing platform credit application machinery only after the funded credit is released;
- keep settlement/overfunding credit flows unchanged.
```
