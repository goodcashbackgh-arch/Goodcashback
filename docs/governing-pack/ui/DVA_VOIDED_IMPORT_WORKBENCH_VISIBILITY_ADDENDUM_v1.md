# DVA Voided Import Workbench Visibility Addendum v1

**Status:** GOVERNING ADDENDUM — final build scope locked; implementation not authorised by this document alone  
**Scope:** DVA/card statement import voiding and downstream active-workbench visibility only  
**Principle:** preserve immutable statement evidence; remove only safely voided imported lines from active operational use; prove every retained path is unchanged

## 1. Objective

Extend the existing DVA statement-import **Void** action seamlessly so that a committed statement line from a voided import no longer appears as an active line in DVA allocation/matching workbench surfaces.

The existing Void action remains the single operator action and the existing import-link provenance remains the source of truth.

No second void workflow, deletion mechanism, replacement status system, parallel suppression table, page-specific cleanup action, funding rewrite, or downstream business-rule rewrite may be introduced.

## 2. Confirmed current behaviour

`public.staff_void_dva_statement_import_batch(uuid,text)` already:

- requires an authenticated active admin/supervisor;
- requires a void reason;
- locks the target import batch;
- blocks void when a linked line has a `confirmed` or `held` DVA statement-line allocation;
- sets active `public.dva_statement_line_import_links.active_yn = false` for the batch;
- marks staged import rows `parse_status = 'voided'`;
- marks the batch `status = 'voided'` with staff/time/reason provenance;
- preserves committed `dva_statement_lines` and audit history;
- permits valid later re-import through active-link-only fingerprint uniqueness.

The defect is downstream DVA visibility: committed physical statement lines can remain visible to active allocation/matching paths after their import provenance has been inactivated.

## 3. Governing active-workbench visibility rule

A committed DVA statement line is excluded from active DVA allocation/matching workbench visibility only when:

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

This deliberately preserves:

- lines with an active import link even if they also have historical inactive links; and
- lines that were never created through the import-link mechanism.

A missing import link must **not** make a line invisible.

## 4. Required seamless implementation

### 4.1 Existing Void action remains the only action

The operator continues to use the existing statement-import **Void** action. There must be no follow-up cleanup button or manual statement-line suppression step.

### 4.2 Strengthen the void guard using the existing central usage control

Before inactivating any import link, the void RPC must fail closed if any linked statement line has active economic consumption or reservation according to `public.statement_line_control_position_v1`.

A linked line blocks void where either:

- `active_consumed_gbp > 0`; or
- `active_reserved_gbp > 0`.

The existing confirmed/held allocation protection must remain intact and execute before the new cross-lane guard. The void must fail before any import link, import row, or batch status changes.

The central position must be used rather than rebuilding separate funding/allocation/loyalty/shipper-AP rules inside the void RPC.

### 4.3 Void RPC baseline lock — mandatory

The production migration must **not blindly replace** the whole Void RPC from a copied implementation.

Before changing it, the migration must verify that the live `staff_void_dva_statement_import_batch(uuid,text)` implementation matches the reviewed baseline represented by `docs/governing-pack/backend/dva_import_void_guard_v1.sql` for the complete stored PL/pgSQL body and governing attributes.

The lock may normalise insignificant whitespace/case. If the live function has drifted from that reviewed baseline, the migration must raise and roll back before changing the function or either view.

Once the baseline is proven, the migration must patch the **live definition surgically** so that the only semantic addition is the canonical active-consumed/active-reserved guard. Existing authentication, role, reason, locking, confirmed/held guard, inactivation, row/batch voiding, provenance and return behaviour must remain sourced from the current live definition.

### 4.4 Active DVA workbench views must honour void provenance

Apply the governing visibility rule only to:

- `public.dva_statement_line_allocation_status_vw`;
- `public.dva_statement_line_allocation_summary_vw`.

Both must be patched from their exact live `pg_get_viewdef()` definitions. Do not reconstruct their economics from an older migration.

Existing columns, output shape, allocation buckets, amounts, loyalty logic and control logic must remain unchanged for retained rows.

For `dva_statement_line_allocation_status_vw`, imported display metadata may come only from an active import link where one exists. Inactive-only provenance must not supply active workbench description/reference data.

### 4.5 Existing downstream consumers inherit the result

No page or downstream function should be rewritten merely to add another void filter.

Confirmed consumers include main DVA reconciliation, unmatched OUT, matching workspace, review pack, allocation readout/residual-allocation guards and `staff_generate_supplier_invoice_match_suggestions(...)`.

The intended inherited change is only that safely voided inactive-only lines disappear or become non-actionable. Retained rows must behave exactly as before.

## 5. Funding boundary — proven already safe; do not modify

Funding uses `public.day2_dva_review_worklist_vw`, not the two allocation workbench views.

A live controlled DB check proved:

| Statement line | Role | Import provenance | Funding worklist |
|---|---|---|---|
| `c39ff2fb-2e68-4c57-beae-229f5981cb62` | voided old IN £841.70 | inactive-only | **ABSENT** |
| `c488e84a-0e98-446a-9c5c-1def5f7f419f` | valid replacement IN £896.81 | active | **PRESENT** |

Therefore `day2_dva_review_worklist_vw`, Funding page queries, funding RPCs and funding calculations are **out of scope**.

## 6. Required post-patch flow

```text
Import + commit
→ active import link
→ line appears normally

Void requested
→ existing confirmed/held guard
→ canonical consumed/reserved guard

if any active economic use/reservation
→ STOP before mutation

if safe
→ existing active import link becomes inactive
→ import rows/batch become voided
→ physical statement evidence remains
→ inactive-only line disappears from active DVA status/summary views
→ main / unmatched / workspace / review / suggestion paths inherit absence
→ Funding continues its already-correct behaviour unchanged

Valid re-import
→ new active provenance
→ replacement line appears normally
```

## 7. Explicit frozen scope

This addendum does **not** authorise changes to:

- physical deletion of `dva_statement_lines`;
- statement amounts, dates, direction, references, FX or card markup;
- `dva_reconciliation` economics/rows;
- `day2_dva_review_worklist_vw` or Funding;
- order-funding calculations or assignment workflow;
- supplier allocation amounts/semantics or allocation reversal logic;
- supplier-invoice approval/economics;
- order progression/status;
- Sage readiness/mappings/posting snapshots/payloads;
- cash posting;
- customer sales;
- shipper AP economics;
- completion-loyalty economics;
- OCR/parser behaviour;
- statement import staging/commit other than the existing void guard;
- fingerprint construction;
- UI labels, permissions, navigation or layout;
- new statement-line status columns or suppression/archive tables.

No unrelated cleanup/refactor is permitted.

## 8. Proven controlled case

| Statement line | Amount | Provenance | Required active DVA result |
|---|---:|---|---|
| `4dc1fe60-86dc-40f1-92ad-519ca3199443` | £896.57 OUT | inactive-only | EXCLUDE |
| `c39ff2fb-2e68-4c57-beae-229f5981cb62` | £841.70 IN | inactive-only | EXCLUDE |
| `c488e84a-0e98-446a-9c5c-1def5f7f419f` | £896.81 IN | active | KEEP |
| `c62a750c-aa8d-4261-b594-dc9a315f4f4d` | £896.57 OUT | active | KEEP |

The governing predicate previously returned PASS for all four. Funding separately proved the voided IN absent and valid replacement IN present.

## 9. Confirmed blast radius

Only these production objects may change:

1. `public.staff_void_dva_statement_import_batch(uuid,text)` — guard addition only, baseline locked;
2. `public.dva_statement_line_allocation_status_vw` — active-link display provenance + inactive-only visibility;
3. `public.dva_statement_line_allocation_summary_vw` — inactive-only visibility.

A focused regression file may be changed/added. No application file should change.

The summary/status views feed multiple application surfaces directly, so their **read blast radius is intentionally shared**. The only permitted downstream difference is removal/non-actionability of inactive-only imported rows.

## 10. Mandatory regression and migration gates

### 10.1 Controlled visibility

For the four controlled lines:

- both inactive-only rows absent from status and summary;
- both active replacements present exactly once;
- physical statement rows and import provenance retained.

### 10.2 Retained-line invariance — exact inactive-only boundary

The migration must snapshot the retained population of both live views **before** patching and compare it with the retained population **after** patching in the same transaction.

The snapshot may exclude **only** statement lines satisfying the governing exclusion condition:

```text
inactive import link exists
AND
no active import link exists
```

A line that has both an inactive historical link **and** an active link is retained and must be included in exact invariance protection.

For every retained active, active-plus-historical, and legacy/non-import row, the comparison must preserve complete row values and multiplicity, not merely selected headline columns. Any unexpected changed, missing or additional retained row must raise and roll back the migration.

This proves no unintended change to statement amounts, allocation totals, unallocated amount, status bucket, selectable flag, supervisor readiness, loyalty values, control reason, display values, or duplicate/multiplicity behaviour.

Only inactive-only imported rows are allowed to leave the active views.

### 10.3 Void fail-closed proof

The regression must identify at least one existing active imported line/batch where `statement_line_control_position_v1` shows active consumption or reservation, where available, and prove that it satisfies the new blocking predicate.

The migration must also prove the deployed function body contains the exact reviewed baseline plus the surgical canonical guard addition.

A production economic transaction must **not** be mutated merely to test the guard. Where an authenticated controlled batch is available, application smoke must confirm the actual Void action refuses it and leaves link/row/batch state unchanged.

### 10.4 Supplier suggestion candidate-set non-regression

Use a read-only candidate-set test. Do not create production suggestions merely for testing.

The test must reproduce the existing candidate-selection logic used by `staff_generate_supplier_invoice_match_suggestions(...)`, including its existing direction, balance, supplier-invoice readiness, tolerance/date/reference/name matching and target-line filters as applicable. Merely proving that a row exists in `dva_statement_line_allocation_summary_vw` is insufficient.

Capture the candidate population before the view patch and compare it with the candidate population after the patch in the same transaction.

Required invariant:

```text
post-patch suggestion candidates
=
pre-patch suggestion candidates
minus candidates whose statement lines are inactive-only under the governing void predicate
```

Therefore:

- inactive-only/voided OUT must not remain a new suggestion candidate;
- every retained eligible OUT candidate must remain eligible with the same candidate identity/ranking inputs;
- no new candidate may appear merely because of this migration.

If the candidate-set comparison differs outside the deliberate inactive-only exclusions, the migration must raise and roll back.

### 10.5 Funding non-regression

No funding object changes. Re-prove:

- voided old IN remains absent from `day2_dva_review_worklist_vw`;
- valid replacement IN remains present;
- its existing reconciliation evidence is unchanged.

### 10.6 Historical evidence

Voiding must not delete the physical statement row, import-link rows, import batch/row provenance or historical allocation/reconciliation evidence.

### 10.7 Application smoke

Without editing pages, smoke existing paths after DB patch:

- main DVA reconciliation;
- unmatched OUT;
- matching workspace;
- review pack;
- valid replacement rows;
- Funding valid IN/voided IN behaviour.

### 10.8 Atomic migration safety

All preflight baseline checks, pre-patch retained-row snapshots, pre-patch suggestion-candidate snapshot, function/view patches, retained-row invariance and suggestion-candidate invariance must occur inside one transaction.

If the Void RPC baseline does not match, a view anchor cannot be safely identified, retained-row invariance fails, or suggestion-candidate invariance fails, the migration must roll back **all** changes.

## 11. Final implementation boundary

The final production build is limited to:

1. baseline-locked surgical augmentation of the existing Void RPC with the canonical consumed/reserved guard;
2. exact-live-definition patch of `dva_statement_line_allocation_status_vw`;
3. exact-live-definition patch of `dva_statement_line_allocation_summary_vw`;
4. atomic retained-row and supplier-suggestion candidate-set invariance gates;
5. focused regression SQL implementing the gates above.

**Do not change Funding/day2 or application files.**

## 12. Acceptance statement

The patch is accepted only when one existing **Void** action behaves atomically and predictably: safely voidable imports retain immutable evidence but cease active DVA allocation/matching participation; economically used/reserved imports fail before mutation; every retained active/active-plus-historical/legacy row is proven byte-for-byte equivalent at the view-row level; the existing supplier-suggestion candidate set changes only by removal of inactive-only rows; Funding remains unchanged; and the Void RPC is proven to be the reviewed existing baseline plus only the canonical usage guard addition.