# DVA Voided Import Workbench Visibility Addendum v1

**Status:** GOVERNING ADDENDUM — final build scope locked; implementation not authorised by this document alone  
**Scope:** DVA/card statement import voiding and downstream active-workbench visibility only  
**Principle:** preserve immutable statement evidence; remove only safely voided imported lines from active operational use

## 1. Objective

Extend the existing DVA statement-import void action seamlessly so that a committed statement line from a voided import no longer appears as an active line in the DVA reconciliation/workbench surfaces.

The existing Void action remains the single operator action and the existing import-link provenance remains the source of truth.

No second void workflow, deletion mechanism, replacement status system, parallel suppression table, or page-specific cleanup action may be introduced.

## 2. Confirmed current behaviour

`public.staff_void_dva_statement_import_batch(uuid,text)` already:

- requires an authenticated active admin/supervisor;
- requires a void reason;
- locks the target import batch;
- currently blocks void when a linked line has a `confirmed` or `held` DVA statement-line allocation;
- sets `public.dva_statement_line_import_links.active_yn = false` for active links belonging to the batch;
- marks the staged import rows `parse_status = 'voided'`;
- marks the batch `status = 'voided'` with staff/time/reason provenance;
- preserves the committed `dva_statement_lines` rows and audit history;
- permits a valid later re-import through active-link-only fingerprint uniqueness.

The defect is downstream DVA visibility: committed `dva_statement_lines` can remain visible to active DVA allocation/matching workbench paths even after their import provenance has been inactivated.

## 3. Governing active-workbench visibility rule

A committed DVA statement line is excluded from the active DVA allocation/matching workbench when:

1. it has at least one inactive import link; and
2. it has no active import link.

Equivalent predicate:

```sql
NOT EXISTS (
  SELECT 1
  FROM public.dva_statement_line_import_links voided_link
  WHERE voided_link.dva_statement_line_id = <statement_line_id>
    AND voided_link.active_yn = false
    AND NOT EXISTS (
      SELECT 1
      FROM public.dva_statement_line_import_links active_link
      WHERE active_link.dva_statement_line_id = <statement_line_id>
        AND active_link.active_yn = true
    )
)
```

This rule intentionally preserves lines that:

- have an active import link; or
- were never created through the import-link mechanism.

A missing import link must **not** by itself make a line invisible.

## 4. Required seamless implementation

### 4.1 Existing Void action remains the only action

The operator continues to use the existing statement-import **Void** action.

There must be no additional workbench action, no follow-up cleanup button, and no manual statement-line suppression step.

### 4.2 Strengthen the void guard using the existing central usage control

Before inactivating any import link, the void RPC must fail closed if any linked statement line has active economic consumption or reservation according to the existing canonical statement-line control position.

The implementation must use the existing `public.statement_line_control_position_v1` control rather than independently recreating the full list of funding/allocation/loyalty/shipper-AP usage families.

A linked line is blocking where the canonical control position shows either:

- `active_consumed_gbp > 0`; or
- `active_reserved_gbp > 0`.

The existing confirmed/held allocation protection must not be weakened. It may be subsumed by the stronger canonical control-position guard only if regression proves equivalent-or-stronger protection.

The void must fail before any import link, import row, or batch status is changed.

This guard is deliberately upstream of all visibility changes: a line that is already economically used/reserved must remain active and unchanged until its existing economic usage is properly reversed/resolved through the governing workflow.

### 4.3 Active DVA workbench views must honour void provenance

Apply the governing visibility rule to these existing canonical views only:

- `public.dva_statement_line_allocation_status_vw`
- `public.dva_statement_line_allocation_summary_vw`

Existing columns, calculations, allocation buckets, amounts, loyalty logic and output shape must remain unchanged for retained lines.

For `dva_statement_line_allocation_status_vw`, the import-row descriptive join must use an active import link where an active link exists. An inactive-only link must not provide active workbench description/reference data.

### 4.4 Existing downstream consumers inherit the result

No direct behavioural rewrite is required in downstream consumers that already read the canonical views.

Confirmed application consumers of `dva_statement_line_allocation_summary_vw` include:

- the main DVA reconciliation page;
- the unmatched OUT page;
- the matching workspace;
- the accounting/review-pack page;
- DVA allocation actions that read the summary row before allowing residual FX/card/fee allocation;
- `public.staff_generate_supplier_invoice_match_suggestions(...)`.

Confirmed application use of `dva_statement_line_allocation_status_vw` includes the active allocation review/readout path.

Therefore the intended inherited effects are:

- a safely voided OUT no longer appears in main DVA reconciliation;
- it no longer appears in unmatched OUT;
- it no longer appears in the matching workspace;
- it no longer participates in the active review-pack statement population;
- it can no longer become a new supplier-invoice suggestion candidate;
- it can no longer pass a summary-view guard for a new residual allocation;
- active allocation review remains unchanged for legitimate used lines because the stronger void guard prevents those lines being voided in the first place.

Do not add separate page-specific void filters unless regression proves the canonical view is insufficient.

## 5. Funding boundary — proven already safe; do not modify

The funding page does **not** use the two allocation workbench views as its inbound working population. It reads `public.day2_dva_review_worklist_vw`.

A live controlled database check proved:

| Statement line | Role | Import provenance | `day2_dva_review_worklist_vw` |
|---|---|---|---|
| `c39ff2fb-2e68-4c57-beae-229f5981cb62` | voided old IN £841.70 | inactive-only | **ABSENT** |
| `c488e84a-0e98-446a-9c5c-1def5f7f419f` | valid replacement IN £896.81 | active | **PRESENT** |

The valid replacement IN was present with its live reconciliation evidence, while the voided old IN was already excluded.

Therefore:

- `day2_dva_review_worklist_vw` is **out of scope**;
- the Funding page is **out of scope**;
- funding RPCs and funding calculations are **out of scope**;
- no funding filter is to be added as part of this build.

This is a locked scope decision: do not alter a working funding path to solve the DVA OUT/workbench visibility defect.

## 6. Required post-patch behaviour

### Valid committed import

```text
Import statement
→ commit
→ active import link
→ statement line visible in normal active workbench paths
→ existing matching/allocation/funding behaviour continues
```

### Safely voidable committed import

```text
Import statement
→ commit
→ line appears in active DVA workbench
→ staff chooses existing Void action
→ canonical active-usage guard runs first
→ no active consumed/reserved economic usage exists
→ existing import link becomes inactive
→ batch/rows become voided
→ committed statement evidence remains stored
→ inactive-only line disappears from active DVA allocation/matching views
→ inherited main / unmatched / workspace / review / suggestion paths stop seeing it
→ existing funding worklist continues its already-correct behaviour unchanged
```

### Import that is already economically used/reserved

```text
Void requested
→ canonical active-usage guard finds active consumed/reserved usage
→ STOP
→ no import link is inactivated
→ no staged row is voided
→ batch is not marked voided
→ all existing downstream economic records and working flows remain unchanged
```

### Re-import after a safe void

```text
Previous imported copy remains historical/inactive
→ replacement import commits with its own active provenance
→ replacement line appears normally
```

## 7. Explicit non-goals / frozen scope

This addendum does **not** authorise changes to:

- physical deletion of `dva_statement_lines`;
- statement amounts, dates, direction, references, FX or card markup;
- `dva_reconciliation` economics or rows;
- `day2_dva_review_worklist_vw`;
- Funding page queries;
- order-funding calculations, reconciliation RPCs or assignment workflow;
- supplier payment allocation amounts or allocation semantics;
- allocation creation/reversal business rules;
- supplier-invoice approval or invoice economics;
- order progression/status logic;
- Sage readiness, Sage mappings, posting snapshots or posting payloads;
- cash-posting logic;
- customer-sales logic;
- shipper-AP economics;
- completion-loyalty economics;
- OCR/parser behaviour;
- statement-import staging/commit behaviour other than the existing void guard described here;
- fingerprint construction;
- UI labels, permissions, navigation or page layout;
- creation of a new statement-line status column;
- creation of a new suppression/archive table.

No unrelated cleanup or refactor is permitted.

## 8. Proven controlled visibility case

The governing active-workbench visibility predicate has been tested against the real replacement/voided import pair for 30 July 2026.

Expected and observed result before implementation:

| Statement line | Amount | Provenance state | Required active-workbench result |
|---|---:|---|---|
| `4dc1fe60-86dc-40f1-92ad-519ca3199443` | £896.57 OUT | inactive-only import link | EXCLUDE |
| `c39ff2fb-2e68-4c57-beae-229f5981cb62` | £841.70 IN | inactive-only import link | EXCLUDE |
| `c488e84a-0e98-446a-9c5c-1def5f7f419f` | £896.81 IN | active import link | KEEP |
| `c62a750c-aa8d-4261-b594-dc9a315f4f4d` | £896.57 OUT | active import link | KEEP |

The predicate regression returned PASS for all four lines and an overall PASS.

The separate funding-worklist regression also returned PASS: the voided IN is already absent and the valid replacement IN remains present.

## 9. Confirmed blast radius

### 9.1 Direct production objects to change

Only these production objects are authorised to change:

1. `public.staff_void_dva_statement_import_batch(uuid,text)` — guard only;
2. `public.dva_statement_line_allocation_status_vw` — inactive-only visibility rule and active-link descriptive join;
3. `public.dva_statement_line_allocation_summary_vw` — inactive-only visibility rule.

A focused regression SQL file may also be added.

### 9.2 Database dependency audit

A live dependency audit established:

- `dva_statement_line_allocation_status_vw` has no separate downstream database dependent identified by the audit;
- `dva_statement_line_allocation_summary_vw` is consumed by `staff_generate_supplier_invoice_match_suggestions(...)`;
- the desired inherited effect is that voided imported OUT lines no longer generate fresh supplier-invoice suggestions.

### 9.3 Application consumers confirmed by repository review

Repository review confirmed that the summary/status views also feed working application surfaces directly, including main reconciliation, unmatched OUT, matching workspace, review pack, allocation readout and residual-allocation guards.

Those surfaces must not be edited directly. Their only intended behavioural difference is the absence/non-actionability of safely voided inactive-only imported lines.

For every retained active or legacy/non-import line, behaviour and displayed economics must remain unchanged.

## 10. Required regression gates

Implementation is not complete unless all of the following pass.

### 10.1 Visibility regression

For the controlled four statement lines above:

- both inactive-only lines are absent from both canonical DVA allocation/matching views;
- both active replacement lines remain present exactly once in both canonical views.

### 10.2 Retained-line invariance

For representative active and legacy/non-import statement lines, compare pre/post values and prove no change to:

- statement amount;
- confirmed allocated amount;
- confirmed unallocated amount;
- allocation-status bucket;
- selectable-for-new-allocation flag;
- supervisor-review readiness;
- loyalty-derived allocation values;
- control-match reason.

Only row visibility for inactive-only imported lines may change.

### 10.3 Void fail-closed regression

Prove that a committed imported line with canonical active consumption or reservation cannot be voided.

The failure must occur before:

- `active_yn` changes;
- staged rows become voided; or
- the batch becomes voided.

Also prove the existing confirmed/held allocation protection remains equivalent or stronger after the guard change.

### 10.4 Supplier suggestion regression

Prove:

- an active eligible OUT line remains eligible for the existing suggestion route;
- an inactive-only/voided imported OUT line is absent from the summary view and cannot become a new suggestion candidate.

Do not require creation of a production suggestion merely to prove this; a read-only candidate-set regression is sufficient.

### 10.5 Funding non-regression

Do not modify funding. Re-run the controlled funding check and prove:

- `c39ff2fb-2e68-4c57-beae-229f5981cb62` remains absent from `day2_dva_review_worklist_vw`;
- `c488e84a-0e98-446a-9c5c-1def5f7f419f` remains present;
- its existing reconciliation evidence remains unchanged.

### 10.6 Historical evidence regression

Prove voiding does not delete:

- the committed `dva_statement_lines` rows;
- the import-link rows;
- import rows/batch provenance;
- historical allocation/reconciliation evidence.

The historical line must remain queryable directly by ID even though it is no longer an active DVA allocation/matching workbench row.

### 10.7 Application-path smoke regression

After the database patch, smoke the existing working pages without changing them and prove:

- main DVA reconciliation no longer shows the controlled voided OUT;
- unmatched OUT no longer shows it;
- matching workspace no longer shows it;
- review pack no longer treats it as an active statement line;
- valid replacement rows continue to display normally;
- Funding continues to show the valid replacement IN and not the voided old IN.

## 11. Final implementation boundary

The final production patch is limited to:

1. the existing `staff_void_dva_statement_import_batch(uuid,text)` guard, using the existing canonical statement-line control position;
2. `dva_statement_line_allocation_status_vw` visibility predicate / active-link descriptive join;
3. `dva_statement_line_allocation_summary_vw` visibility predicate;
4. one focused regression file proving the requirements in this addendum.

**Do not change `day2_dva_review_worklist_vw` or the Funding page.** Their controlled behaviour has already been proven correct for the voided/active IN pair.

No other production object should be changed without separately identified live evidence that it is strictly required to make the above behaviour work.

## 12. Acceptance statement

The patch is accepted only when the existing single **Void** action produces this result atomically and predictably:

> if an imported statement has no active economic consumption or reservation, voiding preserves its immutable historical evidence but removes its inactive-only committed lines from active DVA allocation/matching workbench participation and inherited suggestion/action paths; if the statement is already economically used or reserved, void fails before anything changes; existing Funding behaviour, valid active lines, legacy/non-import lines, and all underlying economics remain exactly as before.
