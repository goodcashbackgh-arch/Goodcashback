# Completion Loyalty Sage Batch Posting Addendum v1

Status: locked implementation addendum to:

- `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md`
- `COMPLETION_LOYALTY_APPLIED_ACCOUNTING_PREVIEW_ADDENDUM_v1.md`
- `COMPLETION_LOYALTY_SAGE_ACCOUNTING_POSTING_ADDENDUM_v1.md`
- `COMPLETION_LOYALTY_SAGE_POSTING_LIFECYCLE_CONTROLS_ADDENDUM_v1.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v1.md`
- `CASH_POSTING_WORKBENCH_CONTRACT_v2_ADDENDUM.md`

This addendum locks the missing batch layer for completion-loyalty Sage posting.

It does not change the existing staff apply-loyalty-to-order action, customer dashboard credit display, main-bank/DVA pairing, VAT return logic, cash posting workbench, customer sales posting, supplier/AP posting, shipper/AP posting, or shipment/export/POD workflows.

---

## 1. Core conclusion

The current completion-loyalty Sage lifecycle group proves the correct local accounting facts for one applied loyalty event, but the production workflow must not require one-by-one manual approval and posting.

The completion-loyalty Sage lane must now adopt the same operating pattern as the existing Accounting Command Centre cash posting workbench:

```text
source rows
-> freeze / materialise
-> validate
-> create batch from selected validated rows
-> approve batch
-> post batch to Sage under feature flag
-> store request/response and per-step Sage object ids
-> retry failed steps only
```

The loyalty lane remains separate from the generic cash posting grid.

---

## 2. Upstream trigger remains staff apply-loyalty-to-order

Supervisor/admin staff apply the released loyalty credit to an order before the Sage posting lane begins.

The upstream action remains:

```text
Apply loyalty to order
```

It must continue to:

```text
1. consume only available completion_loyalty_reward credit lots;
2. debit importer_credit_ledger;
3. insert order_funding_events with event_type = 'credit_applied';
4. link the event to the loyalty debit ledger row;
5. close the order/customer balance gap in the platform.
```

The completion-loyalty Sage posting lane starts only after this `credit_applied` event exists.

It must not post pending loyalty, staged main-bank OUT, paired/released but unused loyalty, DVA/card transfer lines, or main-bank OUT lines as applied-loyalty settlement.

---

## 3. Distinct accounting lanes that must not be mixed

The implementation must keep these four meanings separate:

```text
customer cash receipt
internal bank transfer
non-cash loyalty customer settlement
supplier/card payment
```

### 3.1 Customer real cash receipt

Source examples:

```text
customer/importer payment into DVA/card/bank
final_balance_payment DVA/card IN bridge where confirmed
```

Accounting:

```text
Dr DVA/card/bank
Cr customer account / payment-on-account
```

Actioned through:

```text
/internal/accounting-command-centre/cash-posting
```

This may create a Sage customer payment-on-account before the final customer sales invoice exists, provided the cash receipt row is legitimately classified as customer cash by the upstream reconciliation/allocation workbench.

### 3.2 Loyalty main-bank OUT and DVA/card/virtual-card IN top-up

Source:

```text
main_bank_completion_loyalty_funding_matches
```

Accounting:

```text
Dr DVA/card/virtual-card bank or clearing asset
Cr main bank
```

Actioned first through:

```text
/internal/dva-reconciliation/main-bank
DVA/card statement workbench loyalty-aware pairing/release control
```

This is an internal transfer. It is not customer cash, not customer funding, not supplier/card spend, and not the applied-loyalty customer-settlement event.

Live Sage posting for this lane is a later internal-transfer journal phase. It must not be bundled into the applied-loyalty customer settlement batch.

### 3.3 Applied loyalty customer settlement

Source:

```text
order_funding_events.event_type = 'credit_applied'
linked to importer_credit_ledger.source_type = 'completion_loyalty_reward'
```

Accounting:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / receivable
```

Actioned through:

```text
/internal/accounting-command-centre/loyalty-controls
```

This is the lane governed by this addendum.

---

## 4. Invoice existence rule

Applied-loyalty Sage settlement must not be live-posted before the target Sage customer sales invoice exists.

The system must not assume that Sage will automatically allocate a non-cash payment-on-account to a future customer invoice.

The loyalty Sage settlement must allocate by exact frozen Sage artefact id(s):

```text
target_sage_invoice_snapshot_ids
target_sage_invoice_ids
allocation_amounts
same order_id
same Sage contact id
```

If no posted customer_sales Sage invoice snapshot exists for the same order and same Sage contact, the candidate/group must block.

Allowed state before customer sales posting:

```text
credit_applied exists in platform
Step 2 preview row is visible
Step 3 candidate may show blocked_target_not_ready
no live Sage settlement posting
```

Allowed state after customer sales posting:

```text
posted customer_sales snapshot exists
same order_id
same Sage contact id
positive open receivable amount
loyalty settlement may materialise/freeze and validate
```

---

## 5. Batch model

Create dedicated loyalty Sage batch records. Recommended tables:

```text
completion_loyalty_sage_posting_batches
completion_loyalty_sage_posting_batch_items
```

The batch table must store at minimum:

```text
id
batch_ref
batch_type = 'completion_loyalty_applied_settlement'
status
validation_status
approval_status
approved_by_staff_id
approved_at
approved_payload_hash
posting_attempt_count
last_posting_error
row_count
total_amount_gbp
created_by_staff_id
created_at
updated_at
active
```

Required batch statuses:

```text
draft
validated
blocked
approved
posting_to_sage
partially_posted_needs_review
posted_to_sage
failed_retryable
failed_terminal
cancelled
superseded
```

The batch item table must store at minimum:

```text
id
batch_id
posting_group_id
order_funding_event_id
amount_gbp
item_status
validation_status
posting_status
created_at
updated_at
active
```

A posting group may belong to only one active non-cancelled/non-superseded batch at a time.

---

## 6. Batch creation rule

Batch creation must use selected active materialised groups.

Eligible group criteria:

```text
posting_group_type = 'completion_loyalty_applied_settlement'
active = true
status in ('locally_validated', 'admin_approved')
validation_status in ('ok_to_post', 'warning_only')
blocker is null
posted_at is null
no step has posted_to_sage
no step has sage_object_id is not null
not already in an active batch
```

The MVP batch workflow must not require one-by-one group approval before batching.

Batch approval is the production approval control. Existing group approval may remain for audit/backward compatibility, but the efficient workbench path is:

```text
locally_validated groups
-> create batch
-> approve batch
-> post batch
```

---

## 7. Batch detail page

Add a dedicated batch detail page under the Accounting Command Centre loyalty controls, recommended route:

```text
/internal/accounting-command-centre/loyalty-controls/batches/[batch_id]
```

The page must show:

```text
batch_ref
batch_status
approval_status
row count
total amount
postable count
blocked count
posted count
failed count
partial success count
feature flag status
per-group target invoice allocation list
per-group Sage contact
per-group step statuses
payload previews
Sage response payloads
Sage object ids
retry/needs-review indicators
```

The batch detail page is the correct place for the eventual live Sage post button.

The main loyalty-controls page must remain a source/control page, not the final live posting surface.

---

## 8. Approval rule

Batch approval must require accounting admin/supervisor authority.

Approval may be granted only when:

```text
batch is active
batch is not posted
batch is not cancelled/superseded
all active items still reference active groups
all active groups remain validation_status ok_to_post or warning_only
all active groups remain unposted
payload fingerprints have not changed materially since batch creation or revalidation
```

Approval must store:

```text
approved_by_staff_id
approved_at
approval_status = 'approved'
approved_payload_hash
```

If a grouped item becomes stale before posting, the batch must require revalidation/reapproval or removal/supersede. It must not silently mutate the frozen group payload.

---

## 9. Live post rule

Live posting remains disabled until the loyalty Sage posting adapter is built and a feature flag is enabled.

Recommended feature flag:

```text
SAGE_LIVE_COMPLETION_LOYALTY_POSTING_ENABLED=true
```

The post button must be disabled unless:

```text
batch approval_status = 'approved'
batch status in ('approved', 'failed_retryable', 'partially_posted_needs_review')
feature flag enabled
at least one item has a retryable/unposted step
no item has a terminal blocker requiring accounting intervention
```

---

## 10. Live posting execution order

For each posting group in the batch, live posting must execute the frozen steps in this order:

```text
1. POST /contact_payments
   step_type = loyalty_customer_receipt

2. Capture the Sage contact_payment/payment-on-account id
   store sage_object_id, response_payload, posted_at

3. Replace __PAYMENT_ON_ACCOUNT_ID__ in the allocation payload
   use the actual Sage id returned by step 1

4. POST /contact_allocations
   step_type = loyalty_customer_allocation

5. POST /journals
   step_type = loyalty_clearing_offset
```

The allocation step must not post until the receipt step has a Sage object id.

The clearing journal step must not post until both receipt and allocation are successful.

The journal must remain VAT-safe:

```text
include_on_tax_return = false
tax_rate_id = null
```

---

## 11. Partial success and retry rule

If receipt posts but allocation fails:

```text
batch status = partially_posted_needs_review
group status = partially_posted_needs_review
receipt step = posted_to_sage
allocation step = failed_retryable or failed_terminal
journal step = blocked_until_allocation_posted
```

If receipt and allocation post but journal fails:

```text
batch status = partially_posted_needs_review
group status = partially_posted_needs_review
receipt step = posted_to_sage
allocation step = posted_to_sage
journal step = failed_retryable or failed_terminal
```

Retry must:

```text
reuse the existing step idempotency key
not repost successful steps
only retry failed_retryable or unposted dependency-ready steps
show partial success clearly on the batch detail page
```

If any step is terminally failed after a Sage object has posted, do not supersede/delete the group. Mark it for accounting review and require a controlled correction/reversal contract.

---

## 12. Supersede/cancel rule

Supersede/cancel is allowed before live posting only.

Block batch or group supersede if any linked step has:

```text
status = posted_to_sage
sage_object_id is not null
posted_at is not null
```

When cancelling an unposted batch:

```text
set batch status = cancelled
set active = false
set non-posted batch items inactive/cancelled
leave underlying materialised posting groups intact unless separately superseded
```

When superseding an unposted group:

```text
set group status = superseded or cancelled
set active = false
set non-posted steps cancelled/superseded
keep all records for audit
make source credit_applied event available for re-materialise from current resolver
```

---

## 13. UI operating model

The Step 3 section should operate as follows:

```text
Candidates
- selected eligible preview rows
- Materialise / freeze selected

Materialised groups
- select locally_validated groups
- Create loyalty Sage batch
- Supersede unposted stale groups

Batch history
- open batch detail
- approve batch
- post batch when feature flag enabled
- retry failed steps only
```

Do not train users to approve/post individual £x rows as the standard operating process.

Single-row materialisation may remain useful for testing, but production posting is batch-led.

---

## 14. Non-impact boundary

This addendum does not change:

```text
customer order creation
customer self-service credit application
staff apply-loyalty-to-order logic
completion loyalty approval/rejection
main-bank loyalty source OUT reservation
DVA/card destination IN pairing and release
cash posting workbench customer receipt flow
final-balance customer receipt bridge
customer sales invoice posting
VAT return timing
supplier/AP posting
shipper/AP posting
DVA/card reconciliation core
main-bank reconciliation core
shipment/export/POD workflows
```

---

## 15. Acceptance tests

Before implementation is accepted, prove:

```text
1. locally_validated groups can be batched without one-by-one group approval;
2. blocked groups cannot be batched;
3. posted/superseded/cancelled groups cannot be batched;
4. one group cannot sit in two active batches;
5. batch total equals sum of active batch item amounts;
6. batch detail shows all frozen step payloads;
7. batch approval stores approval metadata;
8. live post button remains disabled until feature flag is enabled;
9. allocation payload still contains placeholder before receipt posts;
10. allocation payload uses the actual Sage receipt/payment-on-account id after receipt posts;
11. journal step remains blocked until allocation posts;
12. successful steps are not reposted on retry;
13. partial success is visible at batch and item level;
14. no VAT rows are created by loyalty Sage posting;
15. loyalty internal-transfer top-up remains outside this applied-loyalty settlement batch;
16. real customer cash receipts remain in the cash posting workbench, not the loyalty Sage batch.
```
