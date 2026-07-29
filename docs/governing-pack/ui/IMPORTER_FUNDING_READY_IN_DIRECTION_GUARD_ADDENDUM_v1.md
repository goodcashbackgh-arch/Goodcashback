# IMPORTER FUNDING READY IN DIRECTION GUARD ADDENDUM v1

## Status
Build contract for the Importer Funding Control page only.

## Proven defect
`day2_dva_review_worklist_vw` intentionally contains both IN and OUT statement lines. The funding page preserves `direction`, but the existing automatic ready-funding eligibility can mark an OUT line actionable when its bank/auth text contains an order payment-auth reference strongly enough to meet the current match threshold.

The live database funding RPCs already fail closed and require `direction = 'in'`; the defect is therefore presentation/candidate eligibility on `app/internal/funding/page.tsx`.

## Objective
Prevent any OUT statement line from becoming an automatic `Ready: customer/importer IN → order funding` candidate.

## Smallest permitted change
In the existing `fundingCandidates` mapping, require the already-read candidate direction to be `in` as part of `canReconcile`.

Do not change matching scores, thresholds, inference inputs, worklist/view definitions, server actions, RPCs, statement parsing, supplier OUT handling, credit handling, order totals/status rules, Sage, VAT, permissions, navigation, wording or styling.

## Required behaviour
- IN rows continue through the existing matching and funding logic unchanged.
- OUT rows can never have `canReconcile = true`, regardless of reference text, amount, importer, order match or score.
- Existing unmatched-IN supervisor fallback remains unchanged.
- Existing database direction guards remain untouched.

## Regression case
An OUT row with auth/reference text such as `AUTH-1785274708774-NINJA` must not become ready funding for an order whose payment auth is `AUTH-1785274708774`, even though the existing substring matcher can score it above the automatic threshold.

## Explicit non-impact
No database migration. No database object change. No RPC change. No parser/Mindee change. No supplier payment allocation change. No customer credit change. No funding totals change. No Sage/VAT impact. No styling or wording change.
