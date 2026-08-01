# VAT Return Integrity, Final Evidence and Atomic Sage Posting Addendum v1

Status: governing implementation contract and non-regression authority

Effective repository baseline: `main` at `7c9ca34badee38e92c86c546e6f53a93af8da0b9`

Baseline date: 1 August 2026

Live-database preflight date: 1 August 2026

Implementation branch: `agent/vat-integrity-evidence-atomic-sage-posting-v1`

## 1. Purpose

This addendum governs one narrow production build for the existing VAT return workbench and Sage journal route.

The build closes four verified integrity gaps without replacing the working VAT engine, changing established Sage payload semantics, redesigning the VAT workbench, rewriting historical locked returns or introducing a parallel accounting workflow.

The required outcome is:

```text
qualifying order funding that has no non-void sales invoice is represented in Box 6 exactly once;
a late export-evidence reinstatement reverses one exact previously filed breach line;
final Sage VAT submission evidence is stored permanently in a private bucket before a new return can lock;
only one concurrent caller can claim and send an approved VAT adjustment journal to Sage;
existing correct VAT calculations and working operational routes remain unchanged.
```

This is a surgical integrity extension. It is not permission to redesign working VAT, Sage, storage, journal, invoice, funding or user-interface areas.

A future builder must be able to implement and review the complete build from this addendum without relying on informal chat history. Where the repository, deployed database or current function fingerprint differs from this authority, the builder must stop and inspect the current state. The builder must not guess.

## 2. Authority and precedence

This addendum must be read with the current governing pack and the deployed VAT migrations, particularly:

1. `docs/governing-pack/ui/VAT_RETURN_WORKBENCH_PARTIAL_PREPAYMENT_ADDENDUM_v1.md`;
2. the current VAT return workbench and Sage journal contract files;
3. `supabase/migrations/20260531_vat_submission_evidence_match_lock_v1.sql`;
4. `supabase/migrations/20260615_fix_vat_box6_partial_prepayment_no_group_by_v2.sql`;
5. `supabase/migrations/20260616_vat_box6_supersede_base_candidate_guard_v1.sql`;
6. the current Sage OAuth, request-log, response-log and journal-posting controls;
7. the current admin role matrix and tenant/security controls.

This later addendum controls only the four gaps expressly listed in section 5.

It does not override:

- the existing invoice-backed Box 6 allocation and anti-duplication engine;
- existing Box 1 breach amount calculation;
- VAT return review, approval, journal proposal, dry-run or ledger-account controls;
- Sage journal payload line construction;
- Sage OAuth or business-selection logic;
- current invoice, funding, customer-sales, supplier-AP, settlement or treasury truth;
- locked historical VAT return immutability;
- current tenant isolation and admin-only operational access.

Historical deployed migrations remain immutable. Corrections must be additive migrations or exact guarded replacements of live wrapper functions. Never edit an already-deployed migration to make production appear correct.

## 3. Verified live baseline

The contract is based on repository `main` at the commit above and on the live PostgreSQL 17.6 extraction supplied on 1 August 2026.

### 3.1 Verified live function fingerprints

```text
enforce_vat_return_run_sequence_v1
b9c58dc96096999f0066a63dc5fc796e

guard_vat_adjustment_journal_posted_close_v1
b83ad10c63544536b4160eccf9269d48

staff_apply_vat_timing_source_lines_v1(uuid)
9fa97f7d1a09710e10e40ce8629c87c2

staff_record_vat_sage_submission_and_lock_v1(...)
8a5f7590500abc1b16a8717e9075da45

staff_refresh_vat_return_source_snapshot_v1(uuid)
ccfcc4c3787da4b0963e751cc698915b

staff_refresh_vat_return_source_snapshot_v1_base_20260615(uuid)
afb10cbf7c0c0bee6924b17a667eb2b2
```

Before replacing any existing live function, the migration must compare the deployed definition hash to the reviewed hash. A mismatch must abort the migration rather than overwrite newer work.

### 3.2 Verified live schema facts

- `order_funding_events.order_id` is `NOT NULL` and references `orders(id)`.
- Qualifying event types already exist: `funding_contribution`, `credit_applied` and `funding_reversed`.
- `sales_invoices` supports `main`, `supplementary` and `credit_note`; non-void posted invoices require Sage confirmation.
- `vat_return_run_lines` already contains `prior_vat_return_line_id` referencing another VAT return line.
- `vat_return_blockers` already provides the required blocker route.
- `vat_return_sage_match_evidence` already stores `evidence_url` and `evidence_json`.
- `vat_return_adjustment_journals.idempotency_key` is already unique.
- Existing journal statuses include `admin_approved`, `posting_to_sage`, `posted_to_sage`, `failed_retryable` and `failed_terminal`.
- Existing storage buckets `invoice-evidence` and `order-screenshots` are public. They must not be reused for final VAT evidence.

### 3.3 Verified live data facts

- No export reinstatement lines existed at preflight. Export linkage work is therefore preventive, not a historical rewrite.
- One historical locked Sage evidence record exists with no URL and no SHA-256. It is grandfathered and must not be mutated.
- Three VAT adjustment journals were posted, all with idempotency keys, payload hashes and Sage journal IDs.
- No duplicate logged Sage journal requests were found at preflight.
- The compact diagnostic total of `£6,196.58` is not an implementation amount. It included superseded and test runs and did not resolve all existing invoice-backed Box 6 lines. The implementation must never use that total as a migration adjustment or repair figure.

## 4. Non-regression rules

### 4.1 Preserve the existing VAT engine

`staff_refresh_vat_return_source_snapshot_v1_base_20260615` and the deployed invoice-backed timing calculations remain authoritative.

The build must not rewrite or simplify the existing:

- invoice ordering;
- partial-prepayment allocation;
- invoice cap;
- current-period natural Sage Box 6 line;
- Box 6 anti-duplicate decrease;
- existing Box 1 breach amount;
- expected-box calculation semantics outside this addendum.

The new finaliser runs after the existing refresh and timing functions. It owns only its own new Box 6 line kind, export-link validation and its own blocker codes.

### 4.2 Preserve already-correct returns

For an editable return with no qualifying uninvoiced funding and no invalid export reinstatement, running the new wrapper must have zero financial effect.

Repeated runs must be idempotent. The second run must produce the same active lines, links, blockers and expected totals as the first run.

### 4.3 Preserve frozen and historical returns

The finaliser must reject mutation of locked, submitted, approved, journal-posting, journal-posted, mismatch-review or superseded returns.

This build does not backfill or rewrite the existing historical evidence record, historical locked VAT lines or historical Sage journals.

Corrections to historical VAT returns continue through the existing reopen/correction process.

### 4.4 Preserve the existing UI and routes

The current VAT workbench, Sage upload page and journal posting action remain the user journeys.

Only the internal RPC names and evidence persistence behind those routes change. No new VAT page, journal page, duplicate upload workflow or alternate Sage posting action is permitted.

### 4.5 Preserve Sage payload semantics

The journal date, reference, description, ledger lines, debit/credit values, tax-return flags and endpoint remain unchanged.

This addendum does not assert that Sage honours an HTTP idempotency header. The existing deterministic journal reference and internal idempotency key remain reconciliation evidence. No unsupported Sage idempotency claim may be added.

## 5. Locked implementation scope

The build contains exactly these five work items:

1. an integrity finaliser for qualifying Box 6 funding with no non-void sales invoice;
2. exact linkage and double-reversal protection for late export-evidence reinstatements;
3. permanent private storage and a guarded v2 lock route for final Sage evidence;
4. an atomic database claim before a VAT adjustment journal is sent to Sage;
5. shared regression coverage for those four changes and non-regression of existing calculations.

Anything not required to deliver those five work items is out of scope.

## 6. Explicit exclusions

The build must not include:

- a VAT workbench redesign;
- a replacement VAT engine;
- a new VAT evidence table;
- a new export table or export workflow;
- a new journal table or new journal status;
- multi-line or multi-source journal allocation changes;
- Sage journal payload changes;
- changes to invoice-generation, funding-generation, customer-sales or supplier-AP flows;
- broad storage-bucket cleanup;
- public-bucket conversion;
- historical return repair;
- automatic retry after an unknown Sage network outcome;
- unrelated RLS, role-matrix or function-grant cleanup;
- generic refactoring of the large VAT timing function;
- feature work discovered while implementing this addendum.

A newly discovered issue outside this list must be documented separately and left unchanged.

## 7. Box 6 uninvoiced-funding finaliser

### 7.1 Governing rule

The existing invoice-backed engine remains the sole authority wherever a non-void positive main or supplementary sales invoice exists for an order.

The new finaliser covers only qualifying funding events whose order has no non-void positive main or supplementary sales invoice at finalisation time.

Qualifying signed events are:

```text
funding_contribution  -> Box 6 increase
credit_applied        -> Box 6 increase
funding_reversed      -> Box 6 decrease using the absolute event amount
```

Events are included only when `created_at::date` is inside the VAT return period.

`manual_adjustment` and `overfunding_credit_created` remain excluded.

### 7.2 New line ownership

The finaliser creates the dedicated line kind:

```text
box6_uninvoiced_order_funding
```

Each active line must retain exact event provenance:

```text
source_table = 'order_funding_events'
source_id = exact order_funding_events.id
source_ref = existing source_ref where present, otherwise a deterministic event reference
source_json = event type, order id, raw amount, signed treatment and finaliser version
source_lineage_json = exact order and funding-event lineage
box_number = 6
vat_amount_gbp = 0
natural_sage_covered = false
adjustment_required = true
```

The finaliser may supersede and rebuild only active lines of this new line kind for the target editable run.

It must not update, supersede or reinterpret invoice-backed Box 6 line kinds.

### 7.3 Invoice arrival behaviour

When a non-void positive main or supplementary invoice later exists for the order:

- the finaliser stops creating its uninvoiced event lines for the current editable run;
- its own active lines for that run are superseded on refresh;
- the existing invoice-backed timing engine remains responsible for the invoice-period natural and anti-duplicate treatment;
- no competing `funding minus current Box 6` residual is calculated.

### 7.4 Fail-closed funding integrity

If qualifying event data would produce an impossible negative cumulative consideration balance for an order, the finaliser must not invent a positive or negative repair amount.

It must create an owned open blocker with exact order/event provenance and exclude that order from new uninvoiced Box 6 lines until the source data is corrected.

The blocker route is the existing `vat_return_blockers` table. No new exception table is permitted.

### 7.5 Expected-box refresh

After new Box 6 lines and export-link validation are complete, the target editable run’s expected boxes must be recalculated from all active run lines using the existing direction semantics.

Boxes 8 and 9 remain preserved exactly as the existing function preserves them.

## 8. Exact export-reinstatement linkage

### 8.1 Existing line generation remains

The existing timing function continues to create:

```text
box1_export_evidence_breach
box1_export_evidence_reinstatement
```

The finaliser does not replace the existing amount calculation or evidence-date selection.

### 8.2 Exact original breach requirements

Every active reinstatement in the target run must link through `prior_vat_return_line_id` to exactly one earlier breach line satisfying all of the following:

- line kind is `box1_export_evidence_breach`;
- breach line status is active;
- source table and source ID match the reinstatement exactly;
- Box 1 amount matches within `£0.01`;
- the breach belongs to a return with `status = 'matched_to_sage_locked'`;
- the breach return has `locked_at` populated;
- the breach return period ends before the reinstatement tax-point date.

### 8.3 Missing, ambiguous and already-reversed cases

If there is no candidate, more than one candidate or the only candidate already has another active reinstatement:

- the current reinstatement line is superseded;
- no Box 1 decrease from that line remains active;
- the finaliser creates an owned open blocker with the precise reason and candidate identifiers;
- the return cannot progress to lock while the blocker remains open.

The finaliser resolves and rebuilds only its own export-link blockers on rerun.

### 8.4 Database uniqueness

Add a partial unique index ensuring that one prior breach line can be referenced by at most one active `box1_export_evidence_reinstatement` line.

The migration must abort if incompatible duplicate active links already exist. It must not silently select one or rewrite history.

## 9. Permanent final Sage evidence

### 9.1 Private bucket

Create one new private Supabase Storage bucket:

```text
vat-return-evidence
```

It must not be public.

The existing public buckets must remain unchanged and must not store final VAT evidence.

The bucket retains the existing application limit of 2 MB for this upload route. The application remains responsible for the current fail-closed CSV/XLSX/text parsing.

### 9.2 Object identity

The final evidence object path must be deterministic from:

```text
vat return run id
purpose = final-submission
SHA-256 of original bytes
safe extension derived from the original filename
```

The object is uploaded with `upsert = false` so final evidence is immutable.

The application records in `evidence_json` at minimum:

```text
upload_purpose = final_submission_evidence
storage_bucket
storage_object_path
original filename
content type
size bytes
sha256
parser
extracted boxes
manual overrides
final boxes
calculation warnings
admin confirmation
```

`evidence_url` must use the internal form:

```text
storage://vat-return-evidence/<object-path>
```

No public or signed URL is stored as permanent evidence identity.

### 9.3 Storage access

Storage RLS policies for this bucket are admin-only for authenticated users.

Allowed normal operations are:

- admin insert;
- admin select;
- admin delete only for best-effort cleanup when the database evidence action fails before recording evidence.

No authenticated update policy is created. Stored evidence is immutable.

### 9.4 Guarded v2 lock function

Add `staff_record_vat_sage_submission_and_lock_v2` with the same VAT box and submission inputs as v1.

Before calling the existing v1 calculation-and-lock function, v2 must verify:

- the caller is an active admin;
- an uploaded file is present for final evidence;
- upload purpose is `final_submission_evidence`;
- bucket is exactly `vat-return-evidence`;
- object path belongs to the target VAT run and contains the supplied SHA-256;
- `evidence_url` exactly matches the bucket and object path;
- a matching object exists in `storage.objects`;
- file name, size and SHA-256 metadata are non-empty.

V2 then calls the reviewed v1 function so expected-box comparison, tolerance, mismatch recording and locking semantics remain unchanged.

### 9.5 Historical evidence

The historical locked record with null URL and hash is grandfathered.

No backfill, unlock, mutation or guessed file reference is permitted.

### 9.6 Application failure handling

For final submission evidence:

1. parse and hash original bytes;
2. upload the immutable private object;
3. call lock v2;
4. retain the object when v2 records matched or mismatched evidence;
5. perform best-effort object cleanup only when the RPC fails before evidence is recorded and only when this request created the object;
6. never delete a pre-existing deterministic object during retry handling.

Manual-only final lock is no longer allowed. Manual box overrides may supplement an uploaded final file but cannot replace the file.

Draft-reconciliation imports remain unchanged and do not use the final evidence bucket.

## 10. Atomic Sage journal posting claim

### 10.1 Claim function

Add `staff_claim_vat_adjustment_journal_post_v1` as a service-role posting primitive.

The function must atomically update and return exactly one journal only when all claim conditions still hold:

- journal ID matches;
- journal status is `admin_approved`;
- no Sage journal ID is present;
- parent VAT run is unlocked and still `admin_approved`;
- no open severity-`blocker` exists for the run;
- supplied staff ID identifies an active admin.

The claim update sets:

```text
status = posting_to_sage
retry_count = retry_count + 1
last_error = null
updated_at = now()
```

If another caller claimed the journal first, the function returns no claimed row. The losing caller must not create a Sage request log and must not call Sage.

### 10.2 Application order

The posting application keeps its existing validation and payload construction.

The required order is:

```text
load journal, run and lines
validate existing journal invariants
check existing blockers
prepare Sage OAuth/business context
build the unchanged Sage payload
atomically claim the journal
insert the Sage request log
call Sage once
record the response and final state
```

The claim must occur immediately before request-log insertion and the external call.

### 10.3 Request-log failure

If request-log insertion fails before the Sage fetch starts:

- Sage has not been called;
- the application may safely release the journal from `posting_to_sage` back to `admin_approved`;
- it records a clear local error;
- no automatic external retry has occurred.

The release update must be conditional on the journal still being `posting_to_sage` and having no Sage journal ID.

### 10.4 Known HTTP response

Existing handling remains for an actual HTTP response:

- successful response with a journal ID -> `posted_to_sage`;
- retryable HTTP response -> `failed_retryable`;
- terminal HTTP response -> `failed_terminal`.

### 10.5 Unknown network outcome

When the fetch starts but no HTTP response is received:

- Sage may have accepted the journal;
- the journal remains `posting_to_sage` as an explicit unknown/blocked state;
- the deterministic journal reference, request log, payload hash and network error are retained for reconciliation;
- the action returns an error explaining that the outcome is unknown;
- the system must not automatically retry.

No new status or new UI is introduced for this case.

## 11. Function exposure and grants

Grant changes are limited to the affected VAT entrypoints.

### 11.1 Additive migration

- New user-facing v2 RPCs: execute for `authenticated` and `service_role`, with internal active-admin checks.
- New internal finaliser: execute only for `postgres` and `service_role`.
- New posting claim: execute only for `postgres` and `service_role`.
- Revoke `PUBLIC` and `anon` execute from affected staff VAT functions.
- Revoke direct `authenticated` execute from `staff_apply_vat_timing_source_lines_v1`; it remains callable internally by the owner wrapper.
- Preserve the existing v1 final-lock authenticated grant during the database-first/application-second deployment window.

### 11.2 Post-application activation

After the application is confirmed to call lock v2, revoke authenticated execute from `staff_record_vat_sage_submission_and_lock_v1`.

That post-application hardening SQL must not be placed where an automated database-first deployment could run it before the application switch.

Service-role and postgres access remain for controlled maintenance.

## 12. Refresh process and normal flow

Add `staff_refresh_vat_return_source_snapshot_v2`.

Its sequence is fixed:

```text
verify active admin and editable return
call existing staff_refresh_vat_return_source_snapshot_v1
call staff_finalize_vat_return_integrity_v1
return the existing base result plus finaliser diagnostics
```

The current server action changes only its RPC name from v1 to v2.

No duplicated refresh button, feature flag or alternate user journey is introduced.

The existing v1 wrapper remains available during deployment compatibility. It must not be rewritten beyond a narrow active-admin guard unless a later separate addendum authorises further change.

## 13. Deployment process

This is one governed production build with safe technical ordering.

### Phase A — governing contract

Commit this addendum before implementation code.

No implementation file may contradict it. Any required deviation must update and review the addendum first.

### Phase B — additive database release

Deploy:

- finaliser;
- refresh v2;
- export partial unique index;
- private storage bucket and policies;
- evidence lock v2;
- atomic posting claim;
- narrow safe grants;
- comments and schema reload notification.

The old application must continue working during this phase.

### Phase C — diagnostics

Against editable test/open returns, verify:

- no financial change for an already-correct return;
- new Box 6 lines arise only for qualifying no-invoice events;
- export links are exact;
- bucket is private;
- v2 rejects missing evidence;
- one journal claim succeeds and a second claim fails.

Do not mutate locked or superseded returns during diagnostics.

### Phase D — application release

Deploy the narrow application changes:

- refresh action calls v2;
- final evidence bytes upload to the private bucket;
- final lock action calls v2;
- journal posting requires the atomic claim;
- unknown network outcomes remain blocked.

### Phase E — post-application hardening

After production verification, run the separately stored activation SQL revoking authenticated access to lock v1.

### Rollback

Application rollback may restore the previous RPC names while Phase E has not run.

After Phase E, an application rollback must retain the v2 final-lock action or temporarily restore the exact v1 authenticated grant through a controlled database rollback.

Additive database objects may remain dormant. Never delete evidence objects or rewrite locked VAT facts as rollback.

## 14. Required regression coverage

### 14.1 Box 6

- one positive qualifying funding event with no invoice creates one active increase line;
- one qualifying reversal creates the correct decrease treatment;
- repeated finalisation does not duplicate lines;
- non-qualifying event types are excluded;
- an existing non-void main or supplementary invoice prevents new uninvoiced lines;
- later invoice arrival supersedes only the finaliser-owned current-run lines;
- invoice-backed existing timing lines are unchanged;
- impossible negative cumulative source facts create a blocker rather than a guessed amount;
- an already-correct return has unchanged expected boxes.

### 14.2 Export linkage

- one exact prior locked breach is linked;
- missing breach supersedes reinstatement and creates a blocker;
- ambiguous breaches supersede reinstatement and create a blocker;
- an already-reversed breach cannot receive another active reinstatement;
- rerun preserves one exact active link and no duplicate blocker;
- no current reinstatement rows produces no financial change.

### 14.3 Evidence

- final v2 rejects no file;
- final v2 rejects the wrong bucket, path, purpose or hash metadata;
- final v2 rejects a missing storage object;
- private object and metadata are retained for a matched lock;
- private object and metadata are retained for a recorded mismatch;
- historical null evidence remains unchanged;
- draft import remains unchanged;
- ordinary non-admin authenticated users cannot access the bucket.

### 14.4 Atomic posting

- two simultaneous claims yield exactly one claimed row;
- only the claimant creates a Sage request log and calls the mocked Sage endpoint;
- request-log failure before fetch releases the claim safely;
- successful posting retains existing payload and status behaviour;
- retryable and terminal HTTP responses retain existing classification;
- no-response network outcome remains `posting_to_sage` and is not retried automatically;
- deterministic journal reference remains unchanged.

## 15. Acceptance criteria

The build is acceptable only when all of the following are true:

1. the addendum is committed before implementation;
2. migrations fail closed on reviewed fingerprint mismatches;
3. no locked or superseded VAT return is changed;
4. no existing invoice-backed Box 6 line is changed by the new finaliser;
5. exact export reversal linkage is enforced at function and index level;
6. every new locked return has permanent private evidence URL, object path and SHA-256 metadata;
7. the historical evidence exception remains untouched;
8. concurrent journal posting produces one external request;
9. unknown network outcomes are not automatically retried;
10. existing Sage payload construction is unchanged;
11. relevant SQL and application checks pass;
12. the final diff contains no unrelated refactor or feature.

## 16. Governed implementation file boundary

The expected implementation boundary is limited to:

```text
docs/governing-pack/architecture/VAT_RETURN_INTEGRITY_EVIDENCE_AND_ATOMIC_SAGE_POSTING_ADDENDUM_v1.md
docs/governing-pack/README.md
one additive Supabase migration
one manual post-application hardening SQL file
app/internal/accounting-vat/returns/[return_run_id]/purchaseRefreshAction.ts
app/internal/accounting-vat/returns/[return_run_id]/sage-draft-import/actions.ts
src/lib/sage/vatAdjustmentJournalPosting.ts
focused SQL regression file(s)
focused TypeScript test file(s), only where the repository test harness supports them
```

A file outside this boundary may be changed only when directly required to compile or run the governed tests. The reason must be documented in the commit or pull request.

## 17. Stop conditions

Stop and do not continue automatically when:

- any reviewed function fingerprint differs;
- a required table, column, status, constraint or bucket contract differs;
- duplicate active export reversal links already exist;
- the implementation would require changing a locked return;
- the implementation would require a new journal status or Sage payload change;
- the final evidence route cannot store original bytes privately;
- regression results show a financial change to an already-correct return;
- a required fix falls outside section 5.

The correct response to a stop condition is a new targeted inspection and, if necessary, a separately approved addendum. It is not a guessed implementation.