# CUSTOMER_IMPORTER_PRESENTATION_TERMINOLOGY_PURGE_ADDENDUM_v1

## 1. Purpose

This addendum governs a presentation-only terminology purge for the **customer** and **importer** audiences.

The sole objective is to prevent the user-visible terms **OCR**, **Mindee**, and **Sage** from appearing on customer/importer surfaces while preserving all existing application behaviour, data contracts, integrations, workflow state, permissions, calculations, and backend processing.

This is **not** a backend terminology migration and **not** a schema or integration refactor.

## 2. Governing baseline

The implementation branch is based on repository commit:

`1f2a30f14e362dc42426afefdfda4c83e70c5bce`

The read-only database preflight confirmed stored rows contain OCR/Mindee/Sage terminology in both internal and potentially user-visible narrative fields. The preflight also confirmed **232 internal identifier columns** containing these technical terms. Those identifiers and stored database values are explicitly excluded from this patch.

## 3. Audience scope

In scope:

- Customer-visible presentation text.
- Importer-visible presentation text.
- Customer/importer-visible success, error, helper, status, review, note, message, and label strings where those strings are already rendered by the application.
- Shared UI components only where the same rendered string is exposed to the customer or importer audience.

Out of scope:

- Staff, supervisor, admin, accounting-command-centre, or other internal-only wording unless the same literal is shared with a customer/importer presentation path and the customer/importer wording can be changed without altering internal behaviour.

## 4. June 2026 terminology authority

The following previously agreed presentation terminology is authoritative:

| Existing user-visible wording | Approved replacement |
|---|---|
| Sage | Accounting system |
| Sage posting | Accounting posting |
| Pre-Sage | Pre-accounting |
| Mindee | Document processor |
| OCR | Document extraction |
| Mindee OCR status | Document extraction status |
| Send to Mindee OCR | Start document extraction |
| Fetch/save Mindee result | Fetch/save extraction result |
| OCR control room | Document review control |
| OCR/header issues | Document/header issues |

Where a direct word-for-word replacement would create awkward grammar, the rendered sentence may be rephrased only enough to preserve the same meaning using the approved vocabulary. No workflow meaning may change.

Examples:

- `OCR pending` → `Document extraction pending`
- `OCR failed` → `Document extraction failed`
- `Awaiting OCR total` → `Awaiting extracted total`
- `Entered total matches OCR` → `Entered total matches extracted total`
- `Entered/OCR total variance` → `Entered/extracted total variance`
- `Sage readiness values` → `Accounting readiness values`
- `Unable to fetch Sage PDF` → `Unable to fetch invoice PDF`

## 5. Absolute no-change boundary

The implementation MUST NOT alter any of the following:

- Function names.
- Function signatures.
- Function control flow or business logic.
- RPC names or RPC behaviour.
- SQL functions, SQL views, migrations, triggers, policies, or grants.
- Database schemas, tables, columns, field names, or stored values.
- Status values or state-machine values, including values such as `pending_ocr`.
- Internal identifiers such as `ocr_status`, `ocr_extracted_at`, `mindee_*`, `sage_status`, `sage_invoice_id`, `blocked_from_sage_yn`, or equivalent.
- API routes or route structure.
- Query logic.
- Conditions or branching logic.
- Permissions or authentication behaviour.
- Calculations, totals, VAT logic, accounting logic, or reconciliation logic.
- Sage integration behaviour.
- Mindee/document-processing integration behaviour.
- Imports, environment variables, external API contracts, or payload structures solely to rename terminology.
- Existing production database content.

No database cleanup is authorised by this addendum.

## 6. Presentation-only implementation rule

The preferred implementation is the smallest possible edit to existing **user-visible string literals**.

If a customer/importer-visible message is assembled dynamically from stored/backend text, any protection added for that path must be presentation-only and must operate **after** the underlying value has been used for business logic.

A dynamic presentation guard, if required, may replace only the forbidden presentation terms OCR/Mindee/Sage using the June 2026 vocabulary. It must not mutate the underlying value or broaden into unrelated terminology replacement.

The existing broad `cleanUiText` helper MUST NOT be spread across new surfaces merely to satisfy this addendum because it also changes unrelated terminology. Any dynamic guard must be narrowly limited to this addendum's three forbidden terms.

## 7. Database preflight interpretation

The database preflight found stored occurrences in internal/accounting/test data and in some narrative fields that can potentially reach importer/customer pages.

Those stored values are evidence of why a final presentation boundary may be needed; they are **not authority to update the database**.

All internal accounting, API-log, Sage, Mindee, OCR, VAT-control, test-fixture, and technical records remain unchanged.

## 8. Required verification

Before this patch may be considered complete, a postflight must demonstrate:

1. The branch began from the governed baseline commit above.
2. Only files necessary for the addendum and customer/importer presentation terminology were changed.
3. No SQL, migration, schema, function, RPC, permission, integration, calculation, workflow, or route behaviour was changed.
4. Every code change outside this addendum is either:
   - a user-visible string literal replacement; or
   - a narrowly scoped presentation-only guard explicitly required to prevent a dynamic customer/importer leak.
5. Customer/importer rendered wording contains no unintended visible `OCR`, `Mindee`, or `Sage` terminology on the governed surfaces.
6. Internal identifiers and technical machinery remain intact.
7. Relevant existing tests/type checks/build checks pass, or any unavailable check is reported explicitly.

## 9. Scope-creep rule

If removing a visible term would require changing backend logic, database content, a status value, an API contract, an integration, or any working functional behaviour, that occurrence MUST be left unchanged and reported separately rather than changed under this addendum.

## 10. Governing authority

From the point this file is committed to the implementation branch, this addendum is the governing authority for the customer/importer OCR/Mindee/Sage presentation terminology purge.

Any implementation inconsistent with this document is out of scope and must not be applied.
