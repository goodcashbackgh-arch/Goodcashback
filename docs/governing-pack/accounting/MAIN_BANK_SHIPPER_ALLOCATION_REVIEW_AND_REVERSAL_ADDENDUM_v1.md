# Main-Bank Shipper Allocation Review and Reversal Addendum v1

Status: locked implementation addendum. This document defines the required build and safety boundaries. It does not itself alter live database state, Sage objects, cash-posting artefacts, or existing allocation records.

Date: 31 July 2026

## 1. Purpose

This addendum closes a specific control gap in the main-company-bank shipper AP matching lane.

The current system can create and consume `main_bank_shipper_ap_allocations`, and those allocations are correctly included in the amount-aware statement-control model and cash-posting workbench. However:

- the existing Allocation Review page is driven by the legacy DVA allocation detail/status views and therefore does not present main-bank shipper AP allocations as reviewable matching records;
- there is no dedicated main-bank shipper allocation reversal action equivalent to the existing DVA allocation reversal path;
- the current main-bank shipper allocation RPC calculates remaining statement amount using only confirmed shipper allocations, while other live main-bank controls also subtract residual/FX/fee/hold and completion-loyalty consumption;
- once a shipper allocation has been frozen into `cash_posting_snapshots`, reversing the source match without first resolving the frozen accounting artefact would break the accounting chain;
- a reversal-side `NOT EXISTS` check alone is not a sufficient concurrency boundary: cash freeze and reversal must serialize on the same shipper allocation row so a snapshot cannot be created from a row that is concurrently being reversed.

This addendum defines one coordinated, additive solution:

1. extend the existing Allocation Review surface to include main-bank shipper AP allocations;
2. add a dedicated guarded shipper-allocation reversal RPC and server action;
3. block reversal once an active cash-posting snapshot exists for that allocation;
4. enforce a database-level freeze/reversal concurrency invariant by locking and revalidating the source shipper allocation before an active shipper-payment cash snapshot may be inserted;
5. correct the shipper allocation RPC so statement availability is calculated across all active main-bank consumption families;
6. preserve every existing DVA, loyalty, Sage, cash-posting and statement-control contract.

The goal is one coherent review experience without merging economically distinct write paths.

## 2. Authority and relationship to existing controls

This addendum extends and must be read with the existing treasury, DVA/card, cash-posting, Sage-posting, completion-loyalty and statement-control contracts.

It does not replace:

- `staff_reverse_dva_statement_line_allocation(...)`;
- `staff_allocate_main_bank_line_to_shipper_ap_v1(...)` as the main-bank shipper allocation entry point;
- `statement_line_control_position_v1` and its underlying amount-aware usage model;
- `internal_cash_posting_workbench_rows_v1(...)`;
- `internal_freeze_cash_posting_rows_v2(...)`;
- `internal_create_cash_batch_v2(...)`;
- Sage posting/freeze/batch controls;
- main-bank completion-loyalty pairing controls.

Where a previous implementation assumes that a main-bank shipper allocation can be reviewed only in the main-bank matching workspace, this addendum controls: confirmed and historical shipper allocations must be visible in the unified allocation-review surface.

Where a previous implementation assumes that the remaining amount on a main-bank statement line is statement amount minus shipper allocations only, this addendum controls: all active economic consumption on the main-bank line must be respected.

Where a previous implementation assumes that checking `cash_posting_snapshots` immediately before reversal is sufficient, this addendum controls: freeze and reversal must also share a row-level serialization boundary on `main_bank_shipper_ap_allocations`.

## 3. Confirmed evidence

### 3.1 Allocation storage and review visibility

Live evidence confirmed the following rows for the same description family, `Jobyco shipment batch A`:

```text
2026-07-25  GBP 24.00
  MAIN_BANK_SHIPPER_AP  GBP 24.00 confirmed

2026-07-30  GBP 26.00
  MAIN_BANK_SHIPPER_AP  GBP 18.00 confirmed

2026-08-03  GBP 27.60
  DVA_ALLOCATION       GBP  7.60 confirmed / fx_card_difference
  MAIN_BANK_SHIPPER_AP GBP 20.00 confirmed
```

The Allocation Review page presents the `GBP 7.60` `fx_card_difference` row because that row is in `dva_statement_line_allocations` and is exposed by `dva_statement_line_allocation_detail_vw`.

The same page does not present the `GBP 20.00` shipper AP match on the exact same statement line because main-bank shipper rows live in `main_bank_shipper_ap_allocations` and are not part of the legacy DVA allocation-detail read model.

Therefore the current Allocation Review surface is incomplete for main-bank shipper matching records.

### 3.2 Canonical amount-aware statement position

For statement line:

```text
cc11ec42-e6fc-4f6f-83fc-a3ad3e54a9e9
Jobyco shipment batch A
GBP 26.00
```

live control evidence confirmed:

```text
source amount       GBP 26.00
active consumed     GBP 18.00
active reserved     GBP  0.00
remaining           GBP  8.00
active family       main_bank_shipper_ap
```

The amount-aware usage layer already models `main_bank_shipper_ap_allocations` as a principal economic lane and treats `allocation_status = 'reversed'` as historical evidence with zero active consumption.

This is the authoritative statement-position behavior required after reversal.

### 3.3 Existing DVA reversal contract

The live `staff_reverse_dva_statement_line_allocation(p_allocation_id uuid, p_reversal_reason text)` function establishes the current reversal governance pattern:

- `SECURITY DEFINER`;
- `search_path = public, pg_temp`;
- requires `auth.uid()`;
- resolves active staff;
- permits only `admin` or `supervisor`;
- requires a reversal reason of at least eight characters;
- locks the allocation row using `FOR UPDATE`;
- rejects a missing allocation;
- rejects an already-reversed allocation;
- changes status to `reversed` rather than deleting the row;
- stamps staff/time/reason audit fields;
- returns a JSON result containing the reversed amount and post-reversal position.

The main-bank shipper reversal must replicate this governance pattern, while retaining its own table-specific command.

### 3.4 Main-bank shipper allocation lifecycle

`main_bank_shipper_ap_allocations` already contains the fields needed for a governed reversal lifecycle:

```text
allocation_status           confirmed | reversed
reversed_by_staff_id
reversed_by_auth_user_id
reversed_at
reversal_reason
```

The table has a partial unique index on `(dva_statement_line_id, shipping_document_id)` for active confirmed pairs, so changing a row to `reversed` naturally releases that active-pair constraint without destroying history.

### 3.5 Downstream cash-posting freeze boundary

The live cash-posting flow proves the exact irreversible boundary for this review action.

`internal_cash_posting_workbench_rows_v1(...)` exposes confirmed shipper allocations as:

```text
source_type       main_bank_shipper_ap_allocation
source_id         <main_bank_shipper_ap_allocations.id>
category          shipper_invoice_payment
```

`internal_freeze_cash_posting_rows_v2(...)` then freezes that workbench row into `cash_posting_snapshots` with:

```text
source_type       main_bank_shipper_ap_allocation
source_id         <allocation id>
posting_category  shipper_invoice_payment
active            true
freeze_status     frozen
validation_status validated
```

Subsequent batching and Sage posting operate from the frozen snapshot.

Therefore an active cash-posting snapshot is the correct irreversible boundary: once such a snapshot exists, the allocation cannot be reversed from Allocation Review. The accounting artefact must first be resolved through its governed cash-posting/accounting path.

### 3.6 Existing main-bank allocation inconsistency

The live `staff_allocate_main_bank_line_to_shipper_ap_v1(...)` currently calculates statement remaining as:

```text
statement amount
- confirmed main-bank shipper allocations
```

It does not subtract other active main-bank uses.

Other live controls correctly account for:

```text
confirmed main-bank shipper AP
+ confirmed residual allocations
    fx_card_difference
    bank_fee
    unmatched_hold
+ active completion-loyalty source consumption
```

The main-bank workspace itself also uses all of those families to determine `remaining_gbp` and `match_status`.

This inconsistency must be corrected in the same release as reversal so that a reversed amount cannot later be reallocated using a narrower, stale definition of statement availability.

### 3.7 Freeze/reversal concurrency defect

The live freeze flow reads the cash-posting workbench and inserts a snapshot, while the new reversal flow locks and updates `main_bank_shipper_ap_allocations`.

If reversal only checks `NOT EXISTS (active cash snapshot)` without making the freeze path participate in the same source-allocation lock, this race is possible:

```text
freeze transaction                  reversal transaction
------------------                  --------------------
reads allocation as confirmed
                                    locks allocation
                                    sees no active snapshot
                                    marks allocation reversed
inserts active cash snapshot
```

The resulting state is invalid:

```text
source shipper allocation = reversed
active cash snapshot       = frozen/validated
```

Therefore the safety contract is two-sided:

- reversal must lock the shipper allocation and reject an existing active shipper-payment snapshot;
- creation of an active shipper-payment cash snapshot must lock that same shipper allocation and re-check that it is still `confirmed` before the snapshot is accepted.

This must be enforced at the database boundary, not only in the page or server action.

## 4. Locked target operating model

```text
                     ALLOCATION REVIEW
                           |
          +----------------+----------------+
          |                                 |
   DVA allocation                   Main-bank shipper AP
          |                                 |
 existing DVA reversal          dedicated shipper reversal
          |                                 |
 dva_statement_line_            main_bank_shipper_ap_
 allocations                    allocations
          |                                 |
          +----------------+----------------+
                           |
              amount-aware statement control
                           |
                    current used/open

Main-bank shipper freeze/reversal invariant:

                confirmed shipper allocation
                         |
                 source-row lock
                    /          \
                   /            \
              CASH FREEZE      REVERSAL
                  |                |
        re-check confirmed   check no active snapshot
                  |                |
          insert snapshot    confirmed -> reversed
                  |                |
                  +------ mutually serialized ------+
```

## 5. Unified Allocation Review

### 5.1 One review surface

Do not create a second main-bank allocation-review page.

Extend the existing page:

```text
/internal/dva-reconciliation/allocations
```

so it becomes the review surface for both:

```text
dva_statement_line_allocations
main_bank_shipper_ap_allocations
```

The specialist main-bank matching workspace remains the place where shipper AP matches are created. Allocation Review is where active and historical matching records are reviewed and, where permitted, reversed.

### 5.2 Additive read model

Do not silently redefine `dva_statement_line_allocation_detail_vw` to mean two different storage families.

Add a new review read model/view or staff-safe RPC with a stable discriminator, for example:

```text
dva_active_matching_review_v1
```

The exact name may vary, but the output must include an explicit family discriminator such as:

```text
allocation_family = 'dva_allocation'
allocation_family = 'main_bank_shipper_ap'
```

Minimum common fields:

```text
allocation_family
allocation_id
dva_statement_line_id
transaction_date / statement_date
statement_reference
statement_description
statement_direction
statement_gbp_amount
allocation_type
allocation_status
allocated_gbp_amount
created_at
notes
```

Main-bank shipper rows must additionally expose sufficient target context for the card, including:

```text
shipping_document_id
shipper_invoice_ref
shipper_id / shipper name where available
sage_purchase_invoice_id
```

The review UI must not infer the storage family from `allocation_type` or from UUID lookup order. The family discriminator is authoritative.

The review read model must also follow the repository's staff-safe access pattern. If implemented as a `security_invoker` view, deployment evidence must prove that authenticated active staff can select every required underlying relation through existing grants/RLS and that non-staff access is not widened. If that cannot be proven, use a staff-guarded read RPC instead.

### 5.3 Source used/open totals

For review cards, `SOURCE USED NOW` and `SOURCE OPEN NOW` must come from the current amount-aware statement-position model, not from the legacy DVA-only allocation-status view.

This is required because one main-bank line can contain multiple active consumption families.

Example:

```text
statement line       GBP 27.60
shipper AP           GBP 20.00
FX/card residual     GBP  7.60
source used now      GBP 27.60
source open now      GBP  0.00
```

If the `GBP 20.00` shipper row is reversed before freeze:

```text
statement line       GBP 27.60
remaining FX/card    GBP  7.60
source used now      GBP  7.60
source open now      GBP 20.00
```

The UI must never report `GBP 27.60` open in that scenario.

### 5.4 Review filters

The existing status filters should remain. Add an optional allocation-family filter:

```text
All
DVA allocations
Main-bank shipper AP
```

This is a presentation filter only. It must not alter economic status calculations.

## 6. Dedicated main-bank shipper reversal RPC

Add a dedicated RPC, for example:

```text
staff_reverse_main_bank_shipper_ap_allocation_v1(
  p_allocation_id uuid,
  p_reversal_reason text
) returns jsonb
```

Do not route main-bank shipper reversals through `staff_reverse_dva_statement_line_allocation(...)`.

Do not create one generic RPC that guesses which table owns an allocation UUID.

Separate write commands preserve clear economic and audit boundaries.

### 6.1 Required security and validation

The RPC must:

1. be `SECURITY DEFINER`;
2. set `search_path = public, pg_temp`;
3. require `auth.uid()`;
4. resolve an active staff record;
5. allow only `admin` or `supervisor`;
6. require a trimmed reversal reason of at least eight characters;
7. reject a missing allocation;
8. reject an already-reversed allocation;
9. reject any status other than the expected active `confirmed` state;
10. never accept statement-line amount, shipping-document amount, Sage object ID or target ID as mutable input.

### 6.2 Locking order

Use one consistent concurrency order for main-bank statement consumption mutations.

The reversal path must resolve the allocation, then lock the associated physical statement line before performing the final locked allocation-state transition, or otherwise use a single deterministic lock order shared by the corrected shipper allocation path.

The implementation must avoid one path locking an allocation first while another locks the statement line first if both later require the other row.

The preferred contract for new/updated main-bank consumption writes is:

```text
statement line lock
then family-specific allocation/target lock as required
```

The exact SQL may first perform an unlocked lookup to obtain the statement-line ID, but the mutation must occur only after the deterministic lock set is held.

### 6.3 Frozen accounting guard and serialization

Before reversal, the RPC must reject the operation if the source allocation has any active frozen cash-posting snapshot:

```sql
exists (
  select 1
  from public.cash_posting_snapshots cps
  where cps.active = true
    and cps.source_type = 'main_bank_shipper_ap_allocation'
    and cps.source_id = p_allocation_id
    and cps.posting_category = 'shipper_invoice_payment'
)
```

This guard intentionally blocks all active snapshot states, including frozen/validated, batched, posting-failed, posted and posted-needs-review descendants.

In addition, the database must reject creation of an active `shipper_invoice_payment` snapshot for `source_type = 'main_bank_shipper_ap_allocation'` unless the referenced `main_bank_shipper_ap_allocations` row is locked and is still `confirmed` at snapshot-insert time.

The invariant must be enforced for every database insertion route, not only the current UI freeze RPC. A narrow `BEFORE INSERT`/relevant-update trigger on `cash_posting_snapshots`, or an equivalently comprehensive database constraint mechanism, is acceptable.

The reversal RPC must not attempt to deactivate, rewrite or reverse accounting artefacts.

Required user-facing error meaning:

```text
This match has already been frozen into cash posting and cannot be reversed here.
Resolve the accounting/cash-posting artefact first.
```

### 6.4 Mutation

A permitted reversal changes only the allocation lifecycle/audit fields.

Required transition:

```text
allocation_status        confirmed -> reversed
reversed_by_staff_id     current active staff id
reversed_by_auth_user_id auth.uid()
reversed_at              now()
reversal_reason          trimmed mandatory reason
```

The row must not be deleted.

The following must not be changed by this RPC:

```text
dva_statement_line_id
shipping_document_id
sage_posting_snapshot_id
sage_purchase_invoice_id
allocated_gbp_amount
created_by_staff_id
created_by_auth_user_id
created_at
```

Existing `notes` may be left unchanged. If implementation chooses to append a human-readable reversal note, the structured reversal fields remain authoritative and the original note content must be preserved.

### 6.5 Post-reversal response

The RPC should return a JSON result consistent with the existing DVA reversal experience, including at least:

```text
ok
allocation_id
dva_statement_line_id
shipping_document_id
reversed_allocation_type = main_bank_shipper_ap
reversed_amount_gbp
reversal_reason
```

It should also return current post-reversal statement-control figures if cheaply available from the amount-aware model, for example:

```text
active_consumed_after_gbp
active_reserved_after_gbp
remaining_unconsumed_after_gbp
```

Those values are a response/readback, not a validation authority and not stored back into the allocation row.

## 7. Server action and UI reversal behavior

Add a dedicated server action, for example:

```text
reverseMainBankShipperAllocationAction(formData)
```

It must mirror the established DVA action pattern:

- create server Supabase client;
- resolve return path;
- require signed-in user;
- read allocation ID and reversal reason;
- reject missing allocation ID;
- reject a reason shorter than eight characters before RPC call;
- call only the dedicated main-bank shipper reversal RPC;
- surface database errors without converting a blocked reversal into success;
- revalidate the affected reconciliation pages;
- redirect back with a success message containing the reversed amount where returned.

Recommended revalidation set:

```text
/internal/dva-reconciliation
/internal/dva-reconciliation/main-bank
/internal/dva-reconciliation/allocations
/internal/dva-reconciliation/control-summary
```

The review card must dispatch by `allocation_family`:

```text
dva_allocation
  -> reverseDvaStatementLineAllocationAction

main_bank_shipper_ap
  -> reverseMainBankShipperAllocationAction
```

The UI must not send a shipper allocation ID to the DVA reversal action.

## 8. Correct main-bank shipper allocation availability

The existing `staff_allocate_main_bank_line_to_shipper_ap_v1(...)` must be corrected in the same release.

### 8.1 Current defect

The current function calculates line availability from confirmed shipper allocations only.

That permits a narrower interpretation of availability than the rest of the main-bank system.

### 8.2 Required calculation

Before inserting a new shipper allocation, the function must determine the physical statement-line position using all active consumption that competes for that main-bank OUT amount.

At minimum this includes:

```text
confirmed main_bank_shipper_ap_allocations
confirmed dva_statement_line_allocations where allocation_type in:
  fx_card_difference
  bank_fee
  unmatched_hold
active main_bank_completion_loyalty_funding_matches where match_status in:
  confirmed
  released_available_dashboard_credit
```

The required equation is:

```text
line remaining = statement GBP amount
               - active shipper AP consumption
               - active residual/fee/hold consumption
               - active loyalty-source consumption
```

The implementation may use the amount-aware control resolver if doing so preserves correct locking and security semantics. Otherwise it may reproduce the same family arithmetic inside the locked RPC. What is not permitted is reverting to shipper-only availability.

### 8.3 Allocation insertion rules that remain unchanged

The corrected RPC must continue to require:

- authenticated accounting-admin access;
- main-company-bank account context;
- OUT direction;
- positive physical statement amount;
- a valid posted shipper AP target;
- a Sage purchase invoice ID for that target;
- positive allocation amount;
- amount not greater than true remaining statement amount;
- amount not greater than remaining shipper target amount;
- insertion into `main_bank_shipper_ap_allocations` with full creation audit fields.

No new allocation family is introduced.

## 9. Upstream and downstream safety boundaries

### 9.1 Upstream objects that must not be mutated by reversal

The reversal action must not alter:

- statement files;
- `dva_statements`;
- physical values in `dva_statement_lines`;
- `shipping_documents`;
- shippers;
- Sage posting snapshots for the purchase invoice;
- the posted Sage purchase invoice;
- statement interpretation corrections;
- loyalty matches;
- DVA allocation rows.

### 9.2 Downstream objects that must not be mutated by reversal

The reversal action must not alter:

- `cash_posting_snapshots`;
- `cash_posting_batches`;
- `cash_posting_batch_rows`;
- Sage contact/payment objects;
- Sage allocations/settlements;
- Sage purchase invoices;
- accounting closure rows.

If an active cash-posting snapshot exists, the reversal is blocked instead.

The freeze-side concurrency guard is validation only: it may lock/read the source allocation and reject invalid snapshot creation, but it must not mutate the source allocation.

### 9.3 Expected automatic read-model effects after an allowed reversal

Because existing read models count only confirmed shipper allocations, an allowed reversal should automatically cause:

```text
main-bank statement source:
  shipper consumed amount decreases by reversed amount
  remaining amount increases by reversed amount, subject to other active families

shipper AP target:
  allocated amount decreases by reversed amount
  remaining/open amount increases by reversed amount

statement control:
  shipper evidence becomes historical
  active consumed amount decreases
  historical evidence remains visible

cash-posting workbench:
  the allocation no longer appears as a confirmed selectable shipper payment candidate
```

No compensating database write is required for these read-model effects.

## 10. Examples

### 10.1 Simple partial shipper allocation

Before reversal:

```text
statement amount       GBP 26.00
shipper allocation     GBP 18.00
other active use       GBP  0.00
remaining              GBP  8.00
```

Allowed reversal, assuming no active cash snapshot:

```text
statement amount       GBP 26.00
active shipper use     GBP  0.00
remaining              GBP 26.00
historical shipper row GBP 18.00 reversed
```

The associated shipper target also regains `GBP 18.00` of matching capacity.

### 10.2 Mixed shipper plus FX allocation

Before reversal:

```text
statement amount       GBP 27.60
shipper allocation     GBP 20.00
FX/card allocation     GBP  7.60
remaining              GBP  0.00
```

Allowed shipper reversal:

```text
statement amount       GBP 27.60
active shipper use     GBP  0.00
active FX/card use     GBP  7.60
remaining              GBP 20.00
```

The review card must not report `GBP 27.60` open.

### 10.3 Frozen shipper payment

If an active cash snapshot exists with:

```text
source_type       main_bank_shipper_ap_allocation
source_id         <allocation id>
posting_category  shipper_invoice_payment
```

then Allocation Review must reject reversal.

No source allocation status is changed.

The operator must resolve the frozen/posting/accounting artefact through the existing cash-posting/accounting workflow first.

### 10.4 Concurrent freeze versus reversal

If freeze and reversal start at the same time for one shipper allocation, exactly one may cross the boundary first:

- if freeze obtains the source-allocation lock first and confirms the row is still `confirmed`, it may insert the active snapshot; reversal then sees that active snapshot and must fail;
- if reversal obtains the source-allocation lock first and commits `reversed`, freeze then re-checks the source row and must fail without creating a snapshot.

The final database state must never contain both a reversed source allocation and a newly active shipper-payment snapshot created from that reversal race.

## 11. Database privileges

For the new reversal RPC:

```text
REVOKE ALL FROM PUBLIC
GRANT EXECUTE TO authenticated
```

The function itself must enforce active-staff and role checks, matching the existing DVA reversal governance pattern.

No direct UPDATE/INSERT/DELETE RLS policy should be added to allow browser writes to `main_bank_shipper_ap_allocations`.

Existing staff SELECT behavior may remain.

The unified review read model must not widen raw table visibility. Deployment tests must prove its authenticated staff access path and verify that unauthorised callers do not gain broader access through the new object.

## 12. Required regression tests

Implementation is incomplete without regression coverage for all of the following.

### 12.1 Review visibility

- confirmed DVA allocation appears once;
- confirmed main-bank shipper allocation appears once;
- a statement line containing both a shipper and FX allocation presents two distinct cards;
- each card shows the same canonical current source used/open totals;
- family filter does not change totals;
- the chosen view/RPC access pattern works for authenticated active staff without widening access for non-staff callers.

### 12.2 Allowed reversal

- admin can reverse an unfrozen confirmed shipper allocation;
- supervisor can reverse an unfrozen confirmed shipper allocation;
- allocation row remains present;
- status becomes `reversed`;
- staff/auth/time/reason audit fields are populated;
- amount and source/target IDs remain unchanged;
- statement-control evidence becomes historical;
- statement remaining increases by the reversed amount subject to other active consumption;
- shipper target remaining increases by the reversed amount;
- the row no longer appears as a selectable cash-posting candidate.

### 12.3 Reversal rejection

- unauthenticated caller rejected;
- inactive staff rejected;
- non-admin/non-supervisor rejected;
- reason shorter than eight characters rejected;
- missing allocation rejected;
- already-reversed allocation rejected;
- any active cash-posting snapshot for the allocation blocks reversal;
- blocked reversal leaves every allocation field unchanged.

### 12.4 Mixed-consumption correctness

Test at least:

```text
statement GBP 27.60
shipper GBP 20.00
FX GBP 7.60
```

After shipper reversal, assert:

```text
active consumed GBP 7.60
remaining GBP 20.00
```

Also test shipper + loyalty, shipper + bank fee, and shipper + unmatched hold combinations.

### 12.5 Allocation availability correction

For `staff_allocate_main_bank_line_to_shipper_ap_v1(...)`:

- residual/FX consumption reduces shipper allocatable amount;
- loyalty consumption reduces shipper allocatable amount;
- shipper consumption reduces shipper allocatable amount;
- combined consumption cannot exceed the physical statement amount;
- a proposed allocation above true cross-family remaining amount is rejected;
- target-side remaining validation remains enforced.

### 12.6 Freeze/reversal serialization

Regression must prove the database invariant, not just the UI flow:

- creating an active shipper-payment cash snapshot for a `reversed` main-bank shipper allocation is rejected;
- creating one for a missing shipper allocation is rejected;
- creating one for a `confirmed` shipper allocation remains allowed through the governed freeze path;
- the freeze-side validation takes a row lock on the referenced shipper allocation;
- reversal still blocks when an active snapshot already exists;
- a concurrency test or transactional harness demonstrates that simultaneous freeze/reversal cannot commit the invalid combination `reversed allocation + newly active snapshot`.

### 12.7 Downstream non-impact

For an allowed reversal, prove unchanged:

- `dva_statement_lines` physical values;
- `shipping_documents`;
- Sage purchase invoice snapshot/object identifiers;
- existing DVA allocation rows;
- loyalty rows;
- cash-posting snapshots and batches, because an allowed reversal by definition has none active for that source allocation.

For a blocked reversal with an active snapshot, prove no database mutation occurs.

## 13. Rollout order

Use this order:

1. add regression tests and live-read verification queries;
2. correct main-bank shipper allocation cross-family availability;
3. add the database freeze/source-allocation serialization guard;
4. add dedicated reversal RPC and privileges;
5. add unified review read model and prove its staff-safe privilege/RLS path;
6. add server action and UI routing by allocation family;
7. switch review used/open figures to amount-aware statement position;
8. run regression tests against mixed-consumption examples;
9. verify frozen-snapshot blocker and freeze/reversal race in a non-production transactional test;
10. deploy UI after database functions/read models/invariants are live;
11. perform post-deploy smoke checks on main-bank workspace, Allocation Review, control summary and cash-posting workbench.

The reversal UI must not be deployed before both the guarded reversal RPC and the freeze-side serialization invariant exist.

## 14. Rollback strategy

The change is additive and should be independently reversible.

If UI issues occur:

- revert Allocation Review to its previous read source;
- leave the database reversal function unused.

If reversal-function issues occur before any use:

- revoke execute on the new RPC;
- remove/disable its UI action.

If the freeze-side guard causes an unexpected compatibility problem, disable the new reversal action at the UI/RPC privilege boundary before altering the guard. Do not restore a state where reversal is enabled while freeze and reversal can race unsafely.

Do not roll back by deleting historical reversed allocation rows.

The main-bank cross-family availability correction should not be rolled back to shipper-only arithmetic unless a separately proven defect requires it; shipper-only arithmetic is inconsistent with the amount-aware main-bank control contract.

## 15. Completion criteria

This addendum is complete only when all of the following are true:

- main-bank shipper allocations are visible in the existing Allocation Review page;
- DVA and shipper allocation families remain distinct write domains;
- review cards use canonical amount-aware source used/open figures;
- the review read path is proven staff-safe and does not widen underlying data access;
- main-bank shipper allocation availability respects all active main-bank economic families;
- an unfrozen confirmed shipper allocation can be surgically reversed by an admin/supervisor with a mandatory reason;
- the reversal is historical, not destructive;
- an allocation with any active cash-posting snapshot cannot be reversed from Allocation Review;
- an active shipper-payment cash snapshot cannot be created unless the source shipper allocation is locked and still `confirmed`;
- simultaneous freeze/reversal cannot commit a reversed allocation plus a newly active snapshot;
- reversal does not alter Sage or cash-posting artefacts;
- statement and target positions reopen automatically through existing confirmed-only read logic;
- mixed shipper + residual/FX/fee/hold/loyalty cases pass regression tests;
- existing DVA reversal behavior remains unchanged;
- no upstream physical statement or shipping-document evidence is modified.

## 16. Final locked implementation decision

The approved pattern is:

```text
one unified Allocation Review page
+ separate family-specific reversal commands
+ active cash-snapshot reversal blocker
+ database-level freeze/reversal serialization on the shipper allocation row
+ canonical amount-aware source totals
+ corrected cross-family shipper allocation availability
+ proven staff-safe review read access
```

Do not create a second review page.

Do not reuse the DVA reversal RPC for shipper rows.

Do not create a generic reverse-by-UUID RPC.

Do not reverse or mutate Sage from the matching-review action.

Do not reverse a shipper allocation after it has entered the active cash-posting snapshot lifecycle.

Do not permit cash freeze to create a new active shipper-payment snapshot from a source allocation that is no longer confirmed.

Do not calculate main-bank shipper availability from shipper allocations alone.

This design preserves current economic boundaries while closing the review, reversal, concurrency and amount-availability gaps with the smallest controlled blast radius.

## 17. Migration diagnostics and concurrency sign-off

The migration is not production-ready merely because its SQL compiles. It must fail early with explicit prerequisite diagnostics and the freeze/reversal invariant must be exercised in the target PostgreSQL environment.

### 17.1 Required migration prerequisite checks

Before creating/replacing any review, allocation, reversal or cash-freeze object, the migration must explicitly verify every relation/function it directly depends on. At minimum this includes:

```text
public.main_bank_shipper_ap_allocations
public.dva_statement_line_allocations
public.dva_statement_line_allocation_detail_vw
public.statement_line_control_position_v1
public.cash_posting_snapshots
public.shipping_documents
public.dva_statement_lines
public.dva_statements
public.shippers
public.internal_has_accounting_admin_access_v1()
public.internal_shipper_ap_posted_targets_for_main_bank_v1(text,text,integer,integer)
```

A missing prerequisite must raise a specific exception naming the missing object before any migration mutation occurs.

### 17.2 Explicit two-session freeze/reversal regression

The regression pack must contain executable two-session instructions using one eligible, unfrozen, confirmed test allocation. It must test both lock orderings under the target environment's normal transaction isolation level.

Ordering A — reversal wins:

```text
Session A: begin, lock/reverse the allocation, pause before commit.
Session B: attempt governed cash freeze for the same allocation and demonstrate that it waits.
Session A: commit reversed.
Session B: resume and fail because the source allocation is no longer confirmed.
Final assertion: reversed allocation exists and no new active shipper-payment snapshot exists.
```

Ordering B — freeze wins:

```text
Session A: begin governed freeze and hold the source-allocation lock before commit.
Session B: attempt reversal and demonstrate that it waits.
Session A: commit active snapshot.
Session B: resume and fail because an active cash-posting snapshot now exists.
Final assertion: allocation remains confirmed and the active shipper-payment snapshot exists.
```

The regression pack must also record the transaction isolation level used during the test. If the production execution path is changed away from the normal `READ COMMITTED` behavior, this concurrency contract must be re-reviewed rather than assumed.

### 17.3 Final PR sign-off gate

After prerequisite diagnostics and regression SQL are updated, perform one final full-PR review. Sign-off requires all of the following:

- no new database objects or write domains outside this addendum's scope;
- no change to the existing DVA reversal RPC;
- no loyalty write-path mutation;
- no Sage mutation from Allocation Review/reversal;
- no broad cash-posting behavior change outside the narrowly conditioned shipper snapshot guard;
- review access remains staff-gated;
- allocator availability remains canonical and cross-family;
- freeze/reversal concurrency tests are explicit and runnable;
- the PR remains draft until target-database migration and concurrency validation have been completed.

## 18. Final pre-build closure and execution procedure

This section records the final static review findings discovered after the first implementation pass. Where this section is more specific than earlier wording in this addendum, this section controls.

### 18.1 Review and reversal role boundary

The unified Allocation Review and dedicated shipper reversal are one review/remediation lane. Both are restricted to active staff whose `role_type` is `admin` or `supervisor`.

This does **not** broaden the higher-risk creation/freeze boundary:

```text
Allocation Review                         active admin/supervisor
Shipper allocation reversal              active admin/supervisor
Main-bank shipper allocation creation    existing accounting-admin helper
Cash-posting freeze                      existing accounting-admin helper
```

Any earlier reference in this addendum to generic authenticated active-staff review access must therefore be read as active admin/supervisor access for this Allocation Review surface. No new general-staff access is approved.

### 18.2 Canonical control totals must fail closed

`SOURCE USED NOW`, `SOURCE OPEN NOW`, and the displayed current source state are financial/control values and must be driven only by successfully loaded canonical `statement_line_control_position_v1` data.

The implementation must use one explicit success predicate for every displayed canonical value. If the control query errors, or a review row unexpectedly has no canonical control position, the page must:

```text
show control position unavailable / equivalent review-required state
withhold source used
withhold source open
withhold derived source state
```

It must not fall back to allocation-row arithmetic such as:

```text
used = this allocation amount
open = statement amount - this allocation amount
```

This is a fail-closed display rule, not a new accounting model. The expected normal case remains that every allocation-backed statement line has a canonical control row.

### 18.3 Migration prerequisites are direct dependencies only

Migration prerequisite diagnostics must cover every relation/function directly referenced by the migration-created objects, including `public.staff`.

The explicit relation/function set therefore includes at least:

```text
public.main_bank_shipper_ap_allocations
public.dva_statement_line_allocations
public.dva_statement_line_allocation_detail_vw
public.statement_line_control_position_v1
public.cash_posting_snapshots
public.shipping_documents
public.dva_statement_lines
public.dva_statements
public.shippers
public.staff
public.internal_has_accounting_admin_access_v1()
public.internal_shipper_ap_posted_targets_for_main_bank_v1(text,text,integer,integer)
```

`public.internal_freeze_cash_posting_rows_v2(text[],text)` is a required regression/deployment-test dependency for the real governed concurrency test, but it is **not** a direct dependency of the migration's database invariant. The migration must not refuse to install solely because that caller RPC is absent if all objects directly required by the migration itself are present.

The regression pack must separately fail/flag if the governed freeze RPC required for end-to-end testing is absent.

### 18.4 Existing invalid-state preflight

Before installing the forward-looking snapshot guard, the migration must prove that it is not being installed over an already-invalid state.

It must abort before migration mutation if any row satisfies all of:

```text
main_bank_shipper_ap_allocations.allocation_status = reversed
cash_posting_snapshots.active = true
cash_posting_snapshots.source_type = main_bank_shipper_ap_allocation
cash_posting_snapshots.source_id = allocation id
cash_posting_snapshots.posting_category = shipper_invoice_payment
```

The diagnostic must report at least the count of invalid rows and make clear that deliberate remediation is required. The migration must not automatically reactivate an allocation, deactivate a cash snapshot, rewrite accounting history, or otherwise repair the state silently.

### 18.5 Governed concurrency harness must use production queue identity

The end-to-end concurrency test must use the actual governed queue identity returned by `internal_cash_posting_workbench_rows_v1(...)` for the selected eligible shipper allocation. It must not invent or manually reconstruct a queue ID when the workbench can supply the production value.

The live freeze RPC parses queue identifiers as:

```text
segment 1 = cash
segment 2 = category
segment 3 = source UUID
```

For the current shipper lane the expected shape is therefore:

```text
cash:shipper_invoice_payment:<allocation_uuid>
```

A four-part value containing `main_bank_shipper_ap_allocation` as a separate segment is invalid for `internal_freeze_cash_posting_rows_v2(text[],text)` and would fail before exercising the race.

The regression setup must resolve one candidate through the actual workbench and assert:

```text
source_type = main_bank_shipper_ap_allocation
category = shipper_invoice_payment
posting_status = ready_to_freeze
selectable = true
no active snapshot already exists for the allocation
```

The returned `queue_row_id` is then passed verbatim to `internal_freeze_cash_posting_rows_v2(text[],text)`.

The two-session end-to-end test must invoke the actual governed functions:

```text
internal_freeze_cash_posting_rows_v2(text[],text)
staff_reverse_main_bank_shipper_ap_allocation_v1(uuid,text)
```

The lower-level trigger/row-lock harness may remain as diagnostic coverage, but it does not substitute for this actual-function test.

### 18.6 Canonical-control access proof before redesign

The page currently reads canonical totals from `statement_line_control_position_v1` using the authenticated server-side Supabase session. The repository evidence reviewed so far does not prove an explicit authenticated SELECT grant for that view.

This is a deployment-proof requirement, not permission to redesign the architecture pre-emptively.

Regression/deployment validation must therefore:

1. inspect `has_table_privilege('authenticated', 'public.statement_line_control_position_v1', 'SELECT')`;
2. execute the exact canonical-control query used by Allocation Review under an authenticated active admin session;
3. execute the same query under an authenticated active supervisor session;
4. require the expected statement-control row(s) to be returned.

If both governed role sessions can read the required canonical rows, the direct read remains unchanged.

If the target database proves that the direct read is not available, that failed evidence is the trigger for a separate minimal permission/read-surface correction. Do not add a new SECURITY DEFINER control RPC merely as speculation before the access test fails.

Because the UI is fail-closed, a permission failure must never degrade into estimated financial totals.

### 18.7 Locked build procedure

After this addendum is committed, implementation must proceed in this order:

1. **Regression identity correction** — change the real freeze/reversal harness to select the eligible allocation's actual `queue_row_id` from `internal_cash_posting_workbench_rows_v1(...)` and pass it verbatim to `internal_freeze_cash_posting_rows_v2(text[],text)`.
2. **UI fail-closed predicate correction** — ensure the same `hasCanonicalControl` success predicate controls source-used, source-open, overconsumption and derived source-state display; no financial value may be rendered from a returned row when the canonical query itself is in error.
3. **Migration dependency correction** — retain `public.staff` as a prerequisite; retain the existing invalid-state preflight; remove `internal_freeze_cash_posting_rows_v2(text[],text)` from the migration prerequisite block because it is not a direct migration dependency.
4. **Regression access verification** — add structural privilege inspection plus explicit target-environment admin/supervisor execution instructions for the exact canonical-control read used by Allocation Review. Do not create a replacement RPC unless that target-environment proof actually fails.
5. **Static scope review** — verify the resulting PR still changes only the intended five files and introduces no DVA reversal modification, loyalty write, Sage mutation, generic reversal command, second review page or broad cash-posting rewrite.
6. **Target database validation** — apply the migration in the intended test/target PostgreSQL environment; record transaction isolation; execute structural regression SQL; execute both orderings of the low-level and actual-function two-session concurrency tests; execute admin/supervisor review/control-read checks.
7. **Sign-off** — keep the PR draft until the target-database migration and concurrency/access checks have actually passed. Do not describe unexecuted tests as passed.

### 18.8 Closed static patch list

The static patch list is closed to the following items:

```text
A. Correct governed concurrency test queue identity.
B. Make the Allocation Review canonical-control success predicate truly fail closed.
C. Remove the non-direct freeze RPC from migration prerequisites while retaining public.staff and invalid-state preflight.
D. Add canonical-control admin/supervisor access verification and align governing wording.
```

No additional database object or permission expansion is approved by this closure. Any further architectural change requires new evidence from target-environment validation rather than another speculative defensive addition.
