# Invoice Line Reconciliation Action Contract (Day 3 / OCR)

Status: contract only (v1).

This document defines the importer-facing invoice-line reconciliation action boundary for Day 3 evidence/OCR flow.

Do not treat this document as implementation approval for schema changes, SQL edits, RPC creation, UI redesign, or OCR pipeline changes.

---

## Governing pack checked first

Primary governing sources reviewed before drafting:

- `docs/governing-pack/role-matrices/importer_role_stage_matrix_v7.md`
- `docs/governing-pack/ui/Multi_Tenant_UI_Wiring_Control_Document_v1.md`
- `docs/governing-pack/backend/goodcashback-complete.v4.sql`
- `docs/governing-pack/backend/closure_v2_functions_final_day6_8_clarified.sql`
- `docs/governing-pack/backend/day2_to_day9_final_regression_v5.sql`
- Existing `supplier_invoices` / `supplier_invoice_lines` definitions in the locked SQL baseline

---

## 1) Ownership: who owns invoice line reconciliation?

**Owner in normal path: importer/operator (not staff-only).**

Rationale in governing docs:

- Importer role matrix identifies importer as the primary OCR reconciliation workspace actor.
- UI wiring document actor boundaries say importer/operator edits OCR commercial fields, adds/deletes manual lines, and marks clean lines progressed.
- Staff may review via internal evidence queue, but staff review does not replace importer ownership of day-to-day line reconciliation.

**Contract decision:**

- Reconciliation action ownership = importer/operator lane (OCR invoice line reconciliation owner).
- Staff lane = supervision/review/escalation, plus queue visibility and exception/funding/accounting controls outside this action.

---

## 2) How OCR-extracted lines are created

In v1 contract terms, OCR lines are represented in `supplier_invoice_lines` with:

- `line_source = 'ocr_extracted'`
- invoice linkage through `supplier_invoice_id -> supplier_invoices.id`

Creation source is OCR extraction output attached to an existing uploaded supplier invoice (`supplier_invoices`).

**Important boundary:** this contract does **not** add OCR automation code, OCR jobs, or RPC wiring. It only defines action behavior once OCR lines exist.

---

## 3) How manual lines are added

Manual lines are created into `supplier_invoice_lines` as user-entered reconciliation rows using:

- `line_source = 'manually_added'`
- normal commercial fields (`description`, `qty`, `amount_inc_vat_gbp`, optional SKU/size)
- default non-progressed posture until explicitly confirmed/progressed (`eligible_for_invoice_yn` remains controlled by reconciliation outcome)

Use cases:

- missing item absent from OCR output
- correction/split representation for unresolved child exception structures / dispute_lines where applicable
- operator-captured commercial detail needed to reconcile to the parent baseline

Manual lines are reconciliation constructs grounded in importer evidence, not unsupported new commercial truth.

---

## 4) Which fields importer may edit

Importer/operator may edit **commercial reconciliation fields** on existing lines (especially OCR-source lines), including:

- `description`
- `qty`
- `size`
- `amount_inc_vat_gbp`
- `retailer_sku` (when needed for reconciliation quality)
- confirmation/progression values used by reconciliation outcome (`qty_confirmed`, `amount_confirmed`, `eligible_for_invoice_yn`) via controlled reconciliation action flow

Importer/operator may **not** edit line provenance in v1:

- cannot mutate `line_source` from OCR to manual or vice versa
- cannot rewrite immutable identity/audit linkage (`id`, `supplier_invoice_id`, timestamps) outside normal platform write rules

---

## 5) Why OCR source lines are editable but not deletable

OCR lines represent source-derived evidence from uploaded retailer invoice content.

They are editable because OCR extraction can be imperfect and commercial corrections are expected.

They are non-deletable because:

- source-provenance/audit trail must remain intact,
- reconciliation history needs visibility of what OCR produced,
- regression contract explicitly enforces delete-block behavior for OCR lines,
- backend trigger enforces this rule centrally to prevent UI bypass.

---

## 6) Why only manual lines can be deleted

Manual lines are operator-entered reconciliation constructs (not source extraction artifacts). They may become obsolete during correction/splitting.

Allowing deletion only for `manually_added` lines keeps workspace flexible while preserving source integrity of OCR-extracted evidence.

**Rule:**

- delete allowed: `line_source = 'manually_added'`
- delete blocked: `line_source = 'ocr_extracted'`

---

## 7) How correct lines are marked/progressed

A line is treated as progressed when reconciliation confirms it into invoiceable subset using confirmed fields and eligibility marker.

Canonical representation in current contract:

- set confirmed commercial values (`qty_confirmed`, `amount_confirmed`)
- set `eligible_for_invoice_yn` to the schema-approved progressed value for progressed invoiceable lines

The progressed subset rolls into `order_reconciliation_vw`:

- contributes to `qty_progressed_invoiceable`
- contributes to `amount_progressed_invoiceable_gbp`
- allows partial progression while unresolved remainder remains outside progressed subset

---

## 8) How unresolved lines are handled in v1

Unresolved remainder is not forced to block clean lines in v1. Instead:

1. Clean/correct lines are progressed into the invoiceable subset using the schema-approved progressed eligibility value.
2. Unresolved/missing/problem lines remain non-progressed and visible as unresolved remainder.
3. Parent remains partially progressed while unresolved remainder is still open.

Child exception creation/splitting is later-stage behavior (or a separate controlled contract) unless already proven by locked backend functions. Where such later-stage handling exists, use child exception structures / dispute_lines where applicable.

---

## 9) What must not happen before funding is matched

Funding-pending state must **not** block operational reconciliation work.

Allowed before funding match:

- invoice evidence present
- OCR workspace usage
- line edits/manual line management
- progressed subset marking
- unresolved remainder visibility and handling within reconciliation scope

Still blocked until funding/control gates are satisfied:

- final platform-funded confirmation outcomes
- final whole-order financial closure/settlement controls
- accounting/VAT release actions

---

## 10) Side effects forbidden in v1

Invoice line reconciliation action v1 must **not**:

- perform DVA/funding reconciliation,
- apply/importer credit,
- approve refund path,
- create replacement child orders automatically,
- confirm shipping quote/handoff,
- release customer sales invoice/accounting/VAT,
- enqueue/direct-post to Sage,
- mutate unrelated order controls outside reconciliation scope,
- auto-close financial controls.

This is a reconciliation-scope action only.

---

## 11) Proposed RPC/action names (proposed only)

The following names are **proposed only** and not approved/implemented by this contract:

- `operator_update_invoice_line_reconciliation_fields(...)`
- `operator_add_manual_supplier_invoice_line(...)`
- `operator_delete_manual_supplier_invoice_line(...)`
- `operator_mark_invoice_line_progressed(...)`
- `operator_bulk_mark_invoice_lines_progressed(...)`
- `operator_split_unresolved_lines_to_child_exceptions(...)` **(later-stage / proposed only, not v1)**

Implementation naming can change, but must preserve the rules in this contract and the locked backend controls.

---

## 12) Required test scenarios

### A. Clean OCR line progresses

Given an order with supplier invoice and OCR line:

- OCR line exists as `line_source='ocr_extracted'`
- operator corrects commercial fields if needed
- operator confirms/progresses line (schema-approved progressed eligibility value set, confirmed qty/value set)

Expected:

- line contributes to progressed subset in reconciliation view
- order can become/remain partially progressed if unresolved remainder exists
- no accounting/VAT or funding side effects occur

### B. Manual missing line added/deleted

Given OCR misses one item:

- operator adds manual line (`line_source='manually_added'`)
- operator later deletes that manual line after correction

Expected:

- add succeeds
- delete succeeds
- no OCR-source line affected

### C. OCR source line delete blocked

Given existing OCR line:

- operator attempts delete

Expected:

- delete blocked by backend control
- clear error returned indicating OCR-extracted lines are not deletable

### D. Partial progress leaves unresolved remainder visible

Given a parent order where only part of lines are clean:

- clean lines progressed using the schema-approved progressed eligibility value
- unresolved lines left non-progressed and visible as unresolved remainder

Expected:

- order reflects partial progression (not false full clearance)
- unresolved qty/value remains visible as remainder for later-stage handling (including child exception structures / dispute_lines where applicable)

### E. Funding pending does not block reconciliation

Given order funding not yet matched by staff, but invoice evidence exists:

- operator opens reconciliation workspace
- performs line edits, manual line operations, partial progression

Expected:

- reconciliation actions allowed
- no forced freeze caused solely by funding pending
- final financial closure controls remain gated outside this action

### F. No accounting/VAT release from this action

Given any successful reconciliation action in this contract scope:

Expected:

- no sales invoice release,
- no VAT workings post,
- no Sage posting queue action,
- no accounting release state mutation.

---

## Explicit non-scope reminders

This contract does **not** authorize:

- schema changes,
- SQL function/trigger/view changes,
- UI component redesign,
- new RPC creation by itself,
- OCR extraction implementation code.

It is a control-and-behavior contract to guide future implementation and testing.
