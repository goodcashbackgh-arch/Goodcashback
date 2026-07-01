# Completion Loyalty Accounting Controls Page UX Addendum v1

Status: locked UX/layout addendum after repo review of `/internal/accounting-command-centre/loyalty-controls` and the existing completion-loyalty Sage lifecycle panels.

This addendum governs presentation and workflow layout only. It does not change accounting treatment, source tables, Sage endpoints, mapping codes, posting group types, batch semantics, feature flags, or any upstream/downstream reconciliation logic.

Applies to:

- `COMPLETION_LOYALTY_APPLIED_ACCOUNTING_PREVIEW_ADDENDUM_v1.md`
- `COMPLETION_LOYALTY_SAGE_BATCH_POSTING_ADDENDUM_v1.md`
- `COMPLETION_LOYALTY_INTERNAL_TRANSFER_RESOLVER_ADDENDUM_v1.md`
- `/internal/accounting-command-centre/loyalty-controls`

---

## 1. Repo-confirmed current issue

The current page mounts these large sections in one vertical flow:

```text
Header / intro
Page map
Shared filters
Step 1 accounting evidence
Step 2 applied-loyalty eligibility preview
Step 3 applied-loyalty lifecycle actions
Step 3 internal-transfer journal lane
Control boundary note
```

This is functionally correct but too busy for daily operations. The main problem is that Step 3 now contains two full action lanes stacked vertically:

```text
completion_loyalty_applied_settlement
completion_loyalty_internal_transfer_journal
```

They must remain separate internally, but the UI must not present them as two always-expanded workbenches by default.

---

## 2. Locked UX principle

The page must behave as an operational accounting queue first, and an audit/evidence page second.

Default view should prioritise rows requiring staff action:

```text
needs action
ready to materialise / freeze
ready to batch
ready to post
blocked by mapping/source validation
failed or retryable batch/step
```

Read-only evidence and historical batch detail must remain available but should not dominate the first viewport.

---

## 3. Required filter model

Keep the existing global search parameter:

```text
q
```

Add or preserve filters that can drive the busy Step 3 surface:

```text
lane
status
```

Recommended values:

```text
lane = all | action_queue | applied_settlement | internal_transfer | evidence
status = needs_action | ready_to_materialise | ready_to_batch | ready_to_post | blocked | batched_or_posted | all
```

`ready_to_post` is a distinct operational state. It must not be hidden under `batched_or_posted` because approved, postable batches are the immediate next action.

Existing filters may remain for compatibility:

```text
control_category
preview_status
```

But they should not be the primary operational filters because they only affect Step 1 and Step 2.

---

## 4. Required page layout

Use a single page and single route:

```text
/internal/accounting-command-centre/loyalty-controls
```

The default layout should be:

```text
1. Compact header
2. Summary chips
3. Sticky/near-top filter bar
4. Action Queue
5. Applied Settlement lane
6. Internal Transfer lane
7. Read-only Evidence
8. Batch History / audit links
```

The first viewport should show the filter bar and Action Queue, not explanatory cards.

---

## 5. Summary chips

The page should show compact counts rather than large explanatory cards:

```text
Evidence rows
Applied settlement ready / blocked
Internal transfer ready / blocked
Batches ready to post
Batches needing review
Failed / retryable steps
```

These chips are navigation/status aids only. They must not trigger posting directly.

---

## 6. Action Queue

The default Action Queue must combine actionable rows from both completion-loyalty Sage lanes while preserving lane labels:

```text
Applied loyalty settlement
Internal bank transfer
```

Rows may include:

```text
candidate ready to materialise/freeze
materialised group ready to batch
approved batch ready to post
blocked mapping/source row
batch needing approval
failed retryable step/batch
partial post needing review
```

Each row must clearly show:

```text
lane
amount
importer/order or transfer reference
current status
next safe action
link/expand target for details
```

The queue may call existing actions only. It must not introduce new posting semantics.

---

## 6A. Action Queue direct-action boundary

The Action Queue must not imply that a row has been posted, batched, or materialised merely because staff clicked it.

Unless a proper queue-level form submits the same required identifiers to the existing server action, queue rows are navigation/deep-link rows only.

Current safe interpretation:

```text
Action Queue row click
-> opens the correct lane/filter/detail target
-> staff reviews the exact candidate or group inside that lane
-> staff then performs the real action from the lane form or batch detail page
```

Labels must therefore be unambiguous:

```text
Use: Open transfer lane
Use: Open applied settlement lane
Use: Open batch to post
Use: Open batch review
Avoid: Materialise / freeze
Avoid: Create batch
Avoid: Approve
Avoid: Post
```

The avoided labels may only be used in the Action Queue if the row itself contains a real form that submits to the existing approved action with the exact required source identifiers.

For internal-transfer materialisation, a direct queue action must submit the same data currently required by the lane action:

```text
source_out_statement_line_id
destination_in_statement_line_id
```

For applied-settlement materialisation, a direct queue action must submit the same applied-loyalty event/source identifiers required by the existing applied-settlement lifecycle action.

If direct queue actions are added later, they must remain equivalent to existing lane actions and must not create a second posting path.

---

## 6B. Posting-workbench sequence boundary

The completion-loyalty controls page must preserve the existing posting-workbench sequence:

```text
candidate/source row
-> materialise/freeze local posting group and Sage payload steps
-> validate/revalidate local group
-> select materialised validated group(s)
-> create Sage batch
-> approve batch
-> post/retry from batch detail page only
```

The Action Queue is allowed to shorten navigation to the relevant step, but it must not skip any control step.

Bulk actions must follow the same sequence:

```text
bulk materialise/freeze selected candidates
-> produce local posting groups
-> select validated groups
-> create batch from selected groups
```

Bulk materialise/freeze must not be faked by opening the lane with all rows visible. If bulk materialise is not yet implemented, the UI must say so through navigation wording rather than action wording.

---

## 7. Applied Settlement lane

Applied-loyalty settlement remains governed by:

```text
posting_group_type = 'completion_loyalty_applied_settlement'
```

and must keep its existing sequence:

```text
loyalty_customer_receipt
loyalty_customer_allocation
loyalty_clearing_offset
```

UI treatment:

```text
collapsed by default unless selected by filter or containing action rows
full lifecycle details available on expand or batch detail page
no merge with internal-transfer journals
```

---

## 8. Internal Transfer lane

Internal-transfer journal remains governed by:

```text
posting_group_type = 'completion_loyalty_internal_transfer_journal'
step_type = 'loyalty_internal_transfer_journal'
```

UI treatment:

```text
collapsed by default unless selected by filter or containing action rows
show paired transfer candidates only when lane/filter requires it
hide batch controls when there are zero ready groups
hide empty batch history by default
show compact empty state when no rows exist
```

The resolver remains:

```text
main_company_bank_account -> Main GBP bank ledger
importer_dva_card_account + GBP -> Virtual GBP wallet ledger
importer_dva_card_account + GHS -> DVA GHS wallet ledger, posted in GBP equivalent
```

---

## 8A. Internal-transfer candidate card layout

The internal-transfer candidate card is an action card, not an audit pack.

Main card surface should show only:

```text
selection checkbox
importer/customer name
amount
Debit wallet -> Credit main bank
released loyalty amount
wallet excess amount
current status
Materialise this row / Materialise freeze action
```

The following must be collapsed under `Audit details` by default:

```text
OUT date
IN date
OUT reference
IN reference
mapping codes
Sage long ledger ids
source/destination statement-line ids
loyalty match ids
completed order ids
credit ledger ids
```

The bulk materialise control must be visually separate from the single-row action:

```text
Materialise / freeze selected
Materialise this row
```

Do not use one label that makes staff think a row-level button acts on all selected checkboxes.

---

## 8B. Internal-transfer Sage journal batch detail layout

The batch detail page for `completion_loyalty_internal_transfer_journal` must be an approval/posting workbench first and an audit page second.

Primary identity should be:

```text
Completion loyalty · Sage journal batch
Internal-transfer Sage journal batch
Endpoint: /journals
```

Primary action bar must be visible before detailed audit content:

```text
Approve batch
Post Sage journal batch
```

`Post Sage journal batch` must remain disabled until the batch is approved and the dedicated internal-transfer journal live flag is enabled.

The first screen must avoid a stack of large metric cards. Use one compact summary row or compact chips:

```text
status
approval status
rows
total
posted / failed
needs review / blocked
endpoint: /journals
live flag state
```

Batch rows should come next and should show operational detail only:

```text
transfer group reference
importer/customer
amount
Dr wallet
Cr main bank
step status
validation status
```

These sections must be collapsed by default below the row:

```text
request payload
Sage response
full group/audit metadata
step logs
retire/supersede control
```

The generic label `Post loyalty Sage batch` should not be used on the internal-transfer journal batch page because completion loyalty has multiple Sage posting lanes. Use:

```text
Post Sage journal batch
```

---

## 9. Read-only evidence

Step 1 and Step 2 must remain available for audit/review, but should be secondary by default.

Default treatment:

```text
collapsed summary sections
expandable read-only tables
visible when lane = evidence or when filters/search target evidence rows
```

Do not remove the evidence RPCs or audit views. Only reduce default visual dominance.

---

## 10. Remove or compress explanatory chrome

The following should not be always-large cards in the default operational view:

```text
Page map
long explanatory Step 1/2/3 copy
always-visible empty batch controls
always-visible empty history shells
large control-boundary note
```

They may be replaced with:

```text
small helper text
inline info text
collapsed details block
docs link
```

---

## 11. No accounting or posting change

This UX addendum must not change:

```text
main_bank_completion_loyalty_funding_matches
order_funding_events
importer_credit_ledger
completion_loyalty_sage_posting_groups
completion_loyalty_sage_posting_steps
completion_loyalty_sage_posting_batches
completion_loyalty_sage_posting_batch_items
sage_mapping_settings
Sage posting payloads
Sage long-id mapping rules
feature flags
VAT logic
cash posting workbench
DVA/card reconciliation
main-bank reconciliation
customer sales invoice posting
supplier/AP posting
shipper/AP posting
```

The allowed implementation scope is presentation, filtering, grouping, default expansion state, and navigation within the existing route and existing action model.

---

## 12. Acceptance checks

A compliant implementation must prove:

```text
1. existing applied-loyalty settlement groups still use `completion_loyalty_applied_settlement`;
2. existing internal-transfer groups still use `completion_loyalty_internal_transfer_journal`;
3. existing batch/post actions still route by batch/group type;
4. no existing Sage mapping code is renamed or overwritten;
5. `DVA_CASH_BANK_ACCOUNT` remains untouched;
6. Step 1 and Step 2 data remain reachable;
7. default view is less visually dense and prioritises actionable Step 3 work;
8. empty internal-transfer controls/history are hidden or compact;
9. ready-to-post approved batches are easy to find through the `ready_to_post` status filter;
10. failed/retryable/blocked rows are easy to find through filters;
11. no new live Sage posting path is created;
12. Action Queue labels do not claim direct materialisation/batching/approval/posting unless a real form submits to the existing approved action;
13. queue navigation to a lane preserves the posting-workbench sequence: candidate -> materialise/freeze -> validate -> batch -> approve -> post/retry;
14. bulk materialise/freeze, if added, uses existing action semantics and does not bypass validated group batching;
15. internal-transfer candidate cards hide OUT/IN references and mapping codes under collapsed Audit details by default;
16. internal-transfer batch detail page shows action bar and compact summary before payload/response/audit sections;
17. internal-transfer batch page labels the action as `Post Sage journal batch` and shows endpoint `/journals`.
```
