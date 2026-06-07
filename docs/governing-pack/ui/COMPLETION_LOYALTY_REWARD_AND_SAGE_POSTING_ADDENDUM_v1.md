# Completion Loyalty Reward and Sage Posting Addendum v1

Status: locked for the next build sequence after the final settlement, partial-coverage, and non-physical line-resolution review.

This addendum governs the commercial completion loyalty reward, its basis calculation, approval control, Sage journal posting, and credit unlock. It extends the Final Sale Value and Balance Due Addendum and must not change the original accepted-estimate funding threshold.

## 1. Scope

This addendum covers:

- completion loyalty reward proposal;
- qualifying net spend calculation;
- supervisor/admin approval;
- locked credit creation in `importer_credit_ledger`;
- Sage-ready queue handoff;
- Sage journal posting;
- unlock of approved account credit after Sage success;
- later Sage journal when the credit is used against a future order.

It does not redesign checkout, accepted-estimate funding, customer sale documents, supplier evidence, shipment/export/POD evidence, VAT returns, or existing future-order credit application.

## 2. Required upstream contracts

This addendum depends on the following locked rules:

```text
Platform Operational Status Engine Contract
- partial_posted blocks full completion;
- partial shipment/export/POD coverage blocks full completion;
- full-order completion requires the active physical scope to be fully closed or formally closed.

Non-physical Supplier Invoice Line Resolution Contract
- default-N is unresolved unless explicitly resolved or exception-linked;
- delivery, discount, fee, and other non-physical financial lines must be explicitly classified/resolved before they can affect the qualifying net spend basis.

Final Sale Value and Balance Due Addendum
- final sale settlement read model is the canonical settlement source;
- final balance payment is settled before any potential credit;
- available account credit requires supervisor/admin-approved ledger credit;
- recompute_order_platform_funded(...) must not be changed to use final sale value.
```

No loyalty reward proposal may bypass these upstream controls.

## 3. Customer and operational wording

Use these terms:

- Completion loyalty reward
- Qualifying net spend
- Reward rate
- Suggested reward
- Approved reward
- Account credit
- Available account credit
- Loyalty reward expense
- Customer credit liability

Do not use these terms in customer/importer UI, ledger notes, Sage references, Sage descriptions, export evidence, final sale documents, or posting workbench labels:

- VAT cashback
- VAT refund
- VAT share
- VAT recovered
- supplier VAT share
- tax arbitrage
- tax refund
- HMRC refund share

Internal code may still refer to existing tax-rate fields where they already exist in accounting-coded source tables. Those technical field names must not drive user-facing, Sage-reference, or ledger-note wording.

## 4. Reward basis

The default completion loyalty reward is:

```text
suggested_reward_gbp = qualifying_net_spend_gbp * 10%
```

The default reward rate is configurable, but the initial build default is:

```text
default_reward_rate_pct = 10
```

`qualifying_net_spend_gbp` is calculated from signed qualifying gross basis:

```text
qualifying_net_spend_gbp = qualifying_signed_gross_basis_gbp / 1.20
```

The signed qualifying gross basis must include qualifying standard-rate components with their commercial signs:

```text
+ qualifying physical goods gross
+ qualifying delivery/charge gross where classified as qualifying
- qualifying discount gross where linked/apportioned to qualifying spend
- qualifying credit/refund/return gross where linked to qualifying spend
```

Example:

```text
Goods/customer spend incl. standard-rate amount:  £120
Discount incl. standard-rate amount:             -£12
Delivery incl. standard-rate amount:             +£12
Signed qualifying gross basis:                    £120
Qualifying net spend:                             £100
10% completion loyalty reward:                    £10
```

Delivery and discounts do not automatically cancel unless both are confirmed as qualifying standard-rate components and both are included in the signed basis.

## 5. Inclusion and exclusion rules

Include only components that are all of the following:

```text
- linked to the completed order;
- current/accepted source evidence;
- classified as physical goods, qualifying delivery/charge, qualifying discount, or linked credit/refund/return;
- standard-rate at 20%;
- resolved/coded sufficiently to support the signed gross basis;
- not open-disputed, active-held, superseded, duplicate-blocked, or unresolved.
```

Exclude or block as follows:

```text
Exclude from basis:
- zero-value informational rows;
- non-qualifying charges;
- rows formally closed as not part of qualifying spend;
- rows linked to cancelled/superseded evidence.

Block proposal until resolved:
- unresolved default-N supplier invoice lines;
- unclassified delivery/discount/fee rows;
- unknown-rate rows;
- non-20% rows where allocation against qualifying spend cannot be isolated;
- order-level discounts that cannot be apportioned safely;
- open disputes;
- active holds;
- partial shipment/export/POD/customer sale coverage;
- final balance still due;
- existing completion loyalty reward credit for the same order.
```

If a discount applies across mixed qualifying and non-qualifying rows, the platform must apportion it only where the allocation is reliable. If it cannot allocate safely, the proposal is blocked for supervisor/admin review.

## 6. Final settlement dependency

A completion loyalty reward can be proposed only after the canonical final sale settlement read model confirms:

```text
final_sale_value_exists = true
customer_sales_state != partial_posted
final_balance_due_gbp = 0
potential_credit_pending_review_gbp is either 0 or separately governed by settlement credit controls
shipping/export/delivery charge is included, posted as final sale adjustment, or formally closed
no open disputes
no active holds
```

The loyalty reward must not create, reduce, or reclassify final sale value, final balance due, or potential credit pending final review.

## 7. Proposal read model

Create a read model/RPC:

```text
internal_completion_loyalty_reward_proposals_v1()
```

Minimum fields:

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
proposal_status
```

This view is read-only. It must not write credit, alter order funding, alter sales invoices, alter supplier invoice lines, or post to Sage.

## 8. Approval RPC

Create a supervisor/admin-only RPC:

```text
staff_approve_completion_loyalty_reward_v1(
  p_order_id uuid,
  p_approved_amount_gbp numeric,
  p_reward_rate_pct numeric default 10,
  p_reason text default 'completion_loyalty_reward',
  p_notes text default null
)
```

The RPC must:

```text
1. require authenticated active staff;
2. require supervisor/admin authority;
3. re-read the proposal/readiness state at approval time;
4. block partial_posted and incomplete coverage;
5. block unresolved default-N, unclassified basis rows, open disputes, active holds, final balance due, and duplicate rewards;
6. require positive approved amount;
7. write one locked importer_credit_ledger credit;
8. create an audit trail containing the proposal snapshot and approval decision;
9. not make the credit available until Sage journal posting succeeds.
```

Ledger entry:

```text
source_type = 'completion_loyalty_reward'
source_entity_type = 'order'
source_entity_id = order_id
entry_type = 'manual_credit'
direction = 'credit'
amount_gbp = approved amount
lock_reason = 'awaiting_sage_loyalty_journal'
notes = 'Completion loyalty reward approved for clean completed order.'
```

## 9. Sage-ready queue integration

Approved but locked loyalty rewards must appear in the existing Sage-ready queue as:

```text
document_lane = 'customer_credit'
document_type = 'completion_loyalty_reward_journal'
source_table = 'importer_credit_ledger'
source_id = importer_credit_ledger.id
readiness_status = 'ready_for_sage_posting_preview'
```

The queue row must include a neutral reference and posting payload preview. Do not hard-code `GCB` or any current business name in the reference.

Reference format:

```text
LOY-[order_ref]-[short_id]
```

or, if tenant/accounting configuration supplies a neutral prefix:

```text
[configured_document_prefix]-LOY-[order_ref]-[short_id]
```

## 10. Sage journal posting

The Sage posting must use the existing token-refresh, active-business resolution, request/response logging, idempotency, and retry pattern already used by journal posting adapters.

Posting entry:

```text
Dr Loyalty reward expense / Sales promotion expense
Cr Customer credit liability / Customer account credit
```

Required Sage mapping codes:

```text
LOYALTY_REWARD_EXPENSE_LEDGER
CUSTOMER_CREDIT_LIABILITY_LEDGER
```

Journal description:

```text
Completion loyalty reward approved for clean completed order
```

No tax return inclusion should be requested for either journal line.

After Sage success:

```text
save sage_journal_id
save sage_journal_ref
save posted_at
clear importer_credit_ledger.lock_reason
mark posting status = posted_to_sage
```

Only after the lock is cleared may the credit be included in available account credit.

## 11. Later credit application journal

When a customer/importer later uses this approved credit against a new order, the existing credit application flow may continue to create:

```text
importer_credit_ledger debit
order_funding_events event_type = 'credit_applied'
```

A second Sage-ready row must then be created for the liability release:

```text
document_lane = 'customer_credit'
document_type = 'customer_credit_application_journal'
source_table = 'order_funding_events'
source_id = credit_applied event id
```

Posting entry:

```text
Dr Customer credit liability / Customer account credit
Cr Customer receivable / customer clearing
```

This prevents the customer credit liability from remaining in Sage after the credit is consumed.

## 12. UI placement

Create or extend:

```text
/internal/funding/credit-approvals
```

Tabs:

```text
Settlement surplus credits
Completion loyalty rewards
Posted / failed / audit
```

Completion loyalty reward rows should show:

```text
Order ref
Importer
Completion state
Qualifying net spend
Default reward rate
Suggested reward
Approved reward input
Reason / notes
Approval status
Sage posting status
Sage journal ref, when posted
```

Customer/importer UI may show only approved/unlocked credit as account credit. It must not show proposed, locked, failed-posting, or blocked rewards as available credit.

## 13. Non-goals

Do not:

```text
- change recompute_order_platform_funded(...);
- change the accepted estimate threshold;
- create available credit before Sage posting succeeds;
- post to VAT/tax control accounts;
- use fixed business-name prefixes in Sage references;
- create customer-facing reward text from internal calculation field names;
- turn loyalty rewards into sale credits/credit notes unless a later accounting contract explicitly changes that treatment;
- change VAT return source snapshots or VAT return logic;
- bypass existing future-order credit application controls.
```

## 14. Acceptance tests

### Scenario A — clean completed order

```text
Goods/customer spend incl. standard-rate amount:  £120
Discount incl. standard-rate amount:             -£12
Delivery incl. standard-rate amount:             +£12
Signed qualifying gross basis:                    £120
Qualifying net spend:                             £100
Suggested reward at 10%:                          £10
```

Expected:

```text
proposal appears
approval creates locked credit
Sage journal posts Dr reward expense / Cr customer credit liability
credit unlocks only after Sage success
```

### Scenario B — partial customer sale

```text
customer_sales_state = partial_posted
```

Expected:

```text
no proposal
blocker = partial_customer_sale_or_partial_coverage
```

### Scenario C — unresolved default-N line

```text
eligible_for_invoice_yn = N
no active non-physical resolution
no active dispute/refund/replacement link
```

Expected:

```text
no proposal
blocker = unresolved_default_n_line
```

### Scenario D — mixed or unknown basis

```text
order-level discount exists
some rows are non-qualifying or unknown-rate
allocation cannot be proven
```

Expected:

```text
no auto proposal
blocker = qualifying_basis_review_required
```

### Scenario E — Sage posting failure

```text
reward approved
Sage journal fails
```

Expected:

```text
credit remains locked
customer available credit unchanged
retry from Sage-ready queue
```

### Scenario F — credit used on later order

```text
reward credit unlocked
customer applies credit to new order
```

Expected:

```text
existing credit application creates ledger debit and credit_applied funding event
second Sage-ready journal releases customer credit liability
```