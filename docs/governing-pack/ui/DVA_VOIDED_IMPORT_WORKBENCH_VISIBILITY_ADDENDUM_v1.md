# DVA Voided Import Workbench Visibility Addendum v1

**Status:** GOVERNING ADDENDUM — implementation not authorised by this document alone  
**Scope:** DVA/card statement import voiding and downstream active-workbench visibility only  
**Principle:** preserve immutable statement evidence; remove only voided-import lines from active operational use

## 1. Objective

Extend the existing DVA statement-import void action seamlessly so that a committed statement line from a voided import no longer appears as an active line in the DVA reconciliation/workbench surfaces.

The existing void action remains the single operator action and the existing import-link provenance remains the source of truth.

No second void workflow, deletion mechanism, replacement status system, or parallel suppression table may be introduced.

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

The defect is downstream visibility: committed `dva_statement_lines` remain visible to active DVA workbench paths even after their import provenance has been inactivated.

## 3. Governing rule

A committed DVA statement line is excluded from active DVA workbench visibility when:

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

### 4.1 Existing void action remains the only action

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

### 4.3 Active DVA workbench views must honour void provenance

Apply the governing visibility rule to these existing canonical views only:

- `public.dva_statement_line_allocation_status_vw`
- `public.dva_statement_line_allocation_summary_vw`

Existing columns, calculations, allocation buckets, amounts, loyalty logic and output shape must remain unchanged for retained lines.

For `dva_statement_line_allocation_status_vw`, the import-row descriptive join must use an active import link where an active link exists. An inactive-only link must not provide active workbench description/reference data.

### 4.4 Existing downstream consumers inherit the result

No direct behavioural rewrite is required in downstream consumers that already read the canonical views.

In particular, `public.staff_generate_supplier_invoice_match_suggestions(...)` currently reads `dva_statement_line_allocation_summary_vw`. Once the summary view excludes a voided-import OUT line, that line must automatically cease to be eligible for new supplier-invoice suggestions.

Do not add a separate void filter inside that function unless a regression proves the canonical view is insufficient.

## 5. Required post-patch behaviour

### Valid committed import

```text
Import statement
→ commit
→ active import link
→ statement line visible in DVA workbench
→ normal matching/allocation behaviour
```

### Voided committed import

```text
Import statement
→ commit
→ line appears in DVA workbench
→ staff chooses existing Void action
→ canonical active-usage guard passes
→ existing import link becomes inactive
→ batch/rows become voided
→ committed statement evidence remains stored
→ line disappears from active DVA workbench views
→ line cannot generate new supplier-match suggestions
```

### Re-import after void

```text
Previous imported copy remains historical/inactive
→ replacement import commits with its own active provenance
→ replacement line appears normally
```

## 6. Explicit non-goals / frozen scope

This addendum does **not** authorise changes to:

- physical deletion of `dva_statement_lines`;
- statement amounts, dates, direction, references, FX or card markup;
- `dva_reconciliation` economics or rows;
- order-funding calculations or assignment workflow;
- supplier payment allocation amounts or allocation semantics;
- allocation reversal workflow;
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

## 7. Proven controlled case

The governing visibility predicate has already been tested against the real replacement/voided import pair for 30 July 2026.

Expected and observed result before implementation:

| Statement line | Amount | Provenance state | Required active-workbench result |
|---|---:|---|---|
| `4dc1fe60-86dc-40f1-92ad-519ca3199443` | £896.57 OUT | inactive-only import link | EXCLUDE |
| `c39ff2fb-2e68-4c57-beae-229f5981cb62` | £841.70 IN | inactive-only import link | EXCLUDE |
| `c488e84a-0e98-446a-9c5c-1def5f7f419f` | £896.81 IN | active import link | KEEP |
| `c62a750c-aa8d-4261-b594-dc9a315f4f4d` | £896.57 OUT | active import link | KEEP |

The predicate regression returned PASS for all four lines and an overall PASS.

## 8. Known database blast radius

A live dependency audit established:

- `dva_statement_line_allocation_status_vw` has no separate downstream database dependent identified by the audit;
- `dva_statement_line_allocation_summary_vw` is consumed by `staff_generate_supplier_invoice_match_suggestions(...)`;
- the desired inherited effect is that voided imported OUT lines no longer generate fresh supplier-invoice suggestions.

Application pages can query database objects without appearing as PostgreSQL dependency records. Therefore implementation review must still confirm the relevant DVA reconciliation/workbench pages consume the canonical views as expected, without broadening the patch.

## 9. Required regression gates

Implementation is not complete unless all of the following pass.

### 9.1 Visibility regression

For the controlled four statement lines above:

- both inactive-only lines are absent from both canonical workbench views;
- both active replacement lines remain present exactly once in both canonical workbench views.

### 9.2 Retained-line invariance

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

### 9.3 Void fail-closed regression

Prove that a committed imported line with canonical active consumption or reservation cannot be voided.

The failure must occur before:

- `active_yn` changes;
- staged rows become voided; or
- the batch becomes voided.

### 9.4 Supplier suggestion regression

Prove:

- an active eligible OUT line remains eligible for the existing suggestion route;
- an inactive-only/voided imported OUT line is absent from the summary view and cannot become a new suggestion candidate.

Do not require creation of a production suggestion merely to prove this; a read-only candidate-set regression is sufficient.

### 9.5 Historical evidence regression

Prove voiding does not delete:

- the committed `dva_statement_lines` rows;
- the import-link rows;
- import rows/batch provenance;
- historical allocation/reconciliation evidence.

The historical line must remain queryable directly by ID even though it is no longer an active-workbench row.

## 10. Implementation boundary

The intended production patch is limited to:

1. the existing `staff_void_dva_statement_import_batch(uuid,text)` guard, using the existing canonical statement-line control position;
2. `dva_statement_line_allocation_status_vw` visibility predicate / active-link descriptive join;
3. `dva_statement_line_allocation_summary_vw` visibility predicate;
4. a focused regression file proving the requirements in this addendum.

No other production object should be changed without a separately identified, evidenced dependency that is strictly required to make the above behaviour work.

## 11. Acceptance statement

The patch is accepted only when the existing single **Void** action produces this result atomically and predictably:

> a safely voidable imported statement remains preserved as historical evidence, but its inactive-only committed lines cease to participate in the active DVA workbench and its inherited matching/suggestion paths; all valid, active and non-import statement lines behave exactly as before.
