# Completion Loyalty Sage Posting Lifecycle Controls Addendum v1

Status: locked companion addendum to `COMPLETION_LOYALTY_SAGE_ACCOUNTING_POSTING_ADDENDUM_v1.md`.

This addendum is required before running the two draft migration files created for the first build pass:

```text
supabase/migrations/20260624_completion_loyalty_sage_posting_phase1_v1.sql
supabase/migrations/20260624_completion_loyalty_open_targets_legacy_alloc_fix_v1.sql
```

Do not run those two draft migrations as the final implementation. They must either be replaced or merged into a revised migration set that implements the lifecycle controls in this addendum.

The reason is simple: the current draft build creates local posting groups and local Sage payload steps, but it does not yet fully mirror the mature Sage posting lifecycle already used elsewhere in the Accounting Command Centre.

---

## 1. Current UI state to preserve

The current `/internal/accounting-command-centre/loyalty-controls` page already has two useful review sections:

```text
Completion loyalty control rows
Applied completion-loyalty preview
```

These are intentionally review/control sections.

The current UI language says the page exposes completion-loyalty accounting-control rows without making them selectable for freeze, batch creation, Sage posting, or cash-lane posting. That principle remains correct for the existing control rows.

The applied completion-loyalty preview currently states that it is preview only and that no Sage posting, no cash freeze, no VAT source row, no credit unlock, and no queue posting is enabled there. That was correct before the contract was locked.

After this addendum, that preview must not simply become a direct post button. Instead, it must become the source for a controlled Sage lifecycle lane.

Approved UI evolution:

```text
Existing read-only control rows remain read-only evidence/control.
Existing applied-loyalty preview remains the eligibility preview.
A new dedicated Sage posting lifecycle section is added below/near the preview.
That lifecycle section controls materialise/freeze, validate, approve, post, retry, supersede, and history.
```

Do not convert the existing preview table itself into a live Sage posting grid.

Do not add loyalty posting rows to the generic cash freeze/post grid.

---

## 2. Required lifecycle pattern to replicate

The completion-loyalty Sage lane must replicate the control pattern already used by the other Sage posting builds:

```text
readiness / preview row
→ freeze or materialise immutable local posting record
→ validate/revalidate against current mappings and target availability
→ show detail page with payloads and blockers
→ require admin approval
→ live post only when feature flag is enabled
→ store request and response per step
→ handle partial success without hiding it
→ allow safe supersede/cancel before live posting
→ allow re-materialise/refreeze from the current resolver after supersede
```

This is not optional polish. It is required for a seamless integration with the existing Accounting Command Centre.

---

## 3. Naming and UX alignment

Use familiar control language from the existing Sage posting build, but adapt it to loyalty:

```text
Preview / Candidate
Materialised / Frozen
Locally validated
Blocked
Admin approved
Posting to Sage
Partially posted - needs review
Posted to Sage
Failed retryable
Failed terminal
Superseded / cancelled before Sage posting
Re-materialise from current resolver
```

The UI must show:

```text
candidate count
materialised group count
total value
status badge
blocker reason
target invoice allocation list
Sage contact mapping state
Sage mapping state
posting date
payload step count
posted step count
request/response detail links
supersede/refreeze controls where safe
```

On mobile, cards should be used for the lifecycle section rather than a cramped wide table.

---

## 4. Dedicated tables and additional required fields

The draft tables are directionally correct:

```text
completion_loyalty_sage_posting_groups
completion_loyalty_sage_posting_steps
completion_loyalty_sage_posting_step_logs
```

Before running the migration set, the group table must also support lifecycle controls equivalent to existing Sage posting snapshots/batches:

```text
validation_status
validated_at
validation_error_json
superseded_by_group_id
superseded_at
superseded_by_staff_id
supersede_reason
approval_status
approved_by_staff_id
approved_at
posting_attempt_count
last_posting_error
source_payload_fingerprint
mapping_fingerprint
payload_fingerprint
current_resolver_version
```

The existing `status` column may remain, but it must not be the only control field.

Required group-level status values:

```text
draft
blocked
locally_validated
admin_approved
posting_to_sage
partially_posted_needs_review
posted_to_sage
failed_retryable
failed_terminal
cancelled
superseded
reversal_required
reversed
```

Required validation status values:

```text
not_validated
ok_to_post
warning_only
stale_reapproval_required
blocked_source_not_ready
blocked_mapping_missing
blocked_target_not_ready
```

The step table must store:

```text
endpoint_path
method
idempotency_key
request_payload
request_payload_hash
response_payload
sage_object_type
sage_object_id
sage_reference
status
retry_count
last_error
posted_at
```

Each posted Sage object id must live on its own step. Do not rely only on the group status.

---

## 5. Materialise / freeze rule

The first selectable action is not live posting. It is materialise/freeze.

Materialisation turns a `credit_applied` completion-loyalty source event into an immutable local posting group and local step payloads.

It must freeze:

```text
order_funding_event_id
order_id
order_ref
importer_id
source_credit_ledger_id
debit_ledger_id
applied loyalty amount
posting date = order_funding_events.created_at::date
Sage contact id at freeze time
loyalty clearing bank/account mapping at freeze time
loyalty reward expense ledger mapping at freeze time
loyalty clearing offset mapping at freeze time
selected target customer_sales invoice snapshot ids
selected target Sage invoice ids
allocation amounts per invoice
payload fingerprints
mapping fingerprints
```

Materialisation must be idempotent:

```text
one active non-cancelled/non-superseded posting group per order_funding_event_id
```

Duplicate materialise attempts must return the existing active group unless that group has been safely superseded/cancelled before posting.

---

## 6. Validation / revalidation rule

Validation is a separate control step from materialisation.

Validation must check:

```text
source event still exists
source event is still credit_applied
linked source credit is still completion_loyalty_reward
order still exists and is not cancelled/archived
importer/customer Sage contact still exists
required loyalty mappings exist
posting date is resolved
open posted customer_sales target snapshot list is still safe
frozen target Sage invoice ids still exist
combined open receivable is enough for the loyalty amount
no Sage object id already exists for a duplicate active group
```

If source or mapping changes after materialisation, validation must mark the group:

```text
stale_reapproval_required
```

The UI must then offer supersede/re-materialise from the current resolver, not silent mutation of the frozen group.

---

## 7. Admin approval gate

Live posting is not allowed directly after materialisation.

Required order:

```text
materialised/frozen
→ validated/revalidated ok_to_post or warning_only
→ admin approval
→ live post
```

Approval must store:

```text
approved_by_staff_id
approved_at
approval_status
approved_payload_hash
```

If validation changes after approval, approval must be invalidated and the group must return to:

```text
stale_reapproval_required
```

---

## 8. Safe supersede / cancel rule

The loyalty lane must have a safe supersede/cancel control equivalent to the existing local Sage batch supersede control.

Supersede is allowed only if no step has posted to Sage.

Block supersede if any step has:

```text
status = posted_to_sage
sage_object_id is not null
posted_at is not null
```

When superseding a local unposted group:

```text
set group status = superseded or cancelled
set active = false
set superseded_at
set superseded_by_staff_id
store supersede_reason
set non-posted steps to cancelled/superseded
keep all records for audit
make the source credit_applied event available for re-materialisation from current resolver
```

Never delete the old group.

Never edit an already posted Sage object.

---

## 9. Re-materialise / refreeze rule

After a safe supersede/cancel, staff may re-materialise the same source event from the current resolver.

The new group must get a new id and new frozen payload/fingerprints.

It must still be linked to the same:

```text
order_funding_event_id
order_id
source_credit_ledger_id
debit_ledger_id
```

The old superseded group remains audit evidence.

---

## 10. Live posting rule

Live posting is a later build step. It must not be mixed into the first materialisation-only migration.

When live posting is built, it must follow this order:

```text
1. POST /contact_payments for the non-cash loyalty customer receipt/payment-on-account.
2. Capture Sage payment-on-account/contact payment id.
3. Replace the allocation payload placeholder with the actual payment-on-account id.
4. POST /contact_allocations to allocate against frozen target customer_sales invoice ids.
5. POST /journals for the loyalty clearing offset.
```

The allocation step must not post until the customer receipt step has a Sage payment-on-account id.

The clearing journal must not post until the customer receipt and allocation steps are successful, unless a later contract explicitly allows a controlled partial-post recovery route.

---

## 11. Partial success and retry rule

If the receipt posts but allocation fails:

```text
group status = partially_posted_needs_review
receipt step = posted_to_sage
allocation step = failed_retryable or failed_terminal
clearing offset step = blocked_until_allocation_posted
```

If receipt and allocation post but clearing offset fails:

```text
group status = partially_posted_needs_review
receipt step = posted_to_sage
allocation step = posted_to_sage
clearing offset step = failed_retryable or failed_terminal
```

Retry must use existing step idempotency keys and must not repost successful steps.

The UI must make partial success obvious.

---

## 12. Current draft migration instruction

The current two draft migrations are not approved to run as final:

```text
20260624_completion_loyalty_sage_posting_phase1_v1.sql
20260624_completion_loyalty_open_targets_legacy_alloc_fix_v1.sql
```

They may be used as source material, but the final migration set must include the lifecycle controls in this addendum.

The preferred next action is to replace them with a corrected migration set rather than running them and then patching around missing lifecycle controls.

---

## 13. Non-impact boundary

This lifecycle addendum does not change:

```text
completion loyalty approval/rejection
completion loyalty source OUT reservation
completion loyalty destination IN pairing/release
staff apply-loyalty-to-order logic
customer credit display
DVA/card reconciliation core
main-bank reconciliation core
customer sales invoice creation
customer sales Sage posting
supplier/AP posting
shipper/AP posting
cash posting workbench
final-balance customer receipt bridge
VAT return workbench
VAT adjustment journal posting
```

It only controls how the new dedicated completion-loyalty Sage posting lane matures from read-only preview into safe Sage posting.

---

## 14. UI acceptance before build proceeds

The current page shown in screenshots should evolve as follows:

```text
Top existing control cards remain.
Existing Completion loyalty control rows remain read-only evidence.
Existing Applied completion-loyalty preview remains eligibility/readiness preview.
New Applied loyalty Sage posting lifecycle panel appears below the preview.
Panel shows candidates not yet materialised.
Panel shows materialised groups.
Panel exposes only safe actions for the current state.
No live Sage post button appears until migration, validation, approval, and feature flag are in place.
```

State-driven action visibility:

```text
candidate / not materialised -> Materialise / Freeze
blocked -> View blocker, re-run validation after mappings/source fix
locally_validated -> Submit for admin approval / Supersede
admin_approved -> Post to Sage only if feature flag enabled
partially_posted_needs_review -> Retry failed step / review details
posted_to_sage -> View audit only
cancelled/superseded -> View audit, allow new materialise from source
```

This UI/UX must feel like the existing Sage posting build: controlled, auditable, reversible before posting, and impossible to accidentally post from a preview row.

---

## 15. Build conclusion

Do not run the current draft migration pair yet.

Update the migration set first so the first database touch gives the loyalty Sage lane the same lifecycle discipline as the existing Sage posting build.

The next build should be:

```text
Completion Loyalty Sage Posting Lifecycle Controls v1
```

Minimum scope:

```text
corrected tables with validation/supersede/approval fields
materialise/freeze RPC
validate/revalidate RPC
supersede/cancel RPC
re-materialise from source after supersede
read model for groups and steps
UI panel matching the current loyalty-controls page
no live Sage posting yet
```
