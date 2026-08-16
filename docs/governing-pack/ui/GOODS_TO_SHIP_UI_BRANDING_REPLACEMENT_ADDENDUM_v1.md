# Goods To Ship UI Branding Replacement Addendum v1

## Purpose

This addendum authorises one narrowly controlled presentation-layer branding change: replace user-visible references to `Goodcashback` with `Goods To Ship` without changing any working business logic, data model, accounting logic, integration behaviour, routing, permissions, or technical identifiers.

## Authorised change

Only user-visible presentation copy may change:

- `Goodcashback` -> `Goods To Ship`
- `Goodcashback Customer` -> `Goods To Ship Customer`
- `Goodcashback Importer` -> `Goods To Ship Importer`
- `Goodcashback Shipper` -> `Goods To Ship Shipper`
- `Goodcashback Internal` -> `Goods To Ship Internal`
- browser/page metadata that presents the old brand to a user may be updated on the same literal basis.

User-visible presentation copy includes page text, navigation labels, headings, banners, alerts, modal/confirmation copy, toast/success/error copy, empty/loading states, browser metadata, and notification/message text only where the code occurrence is demonstrably rendered or returned for presentation to a user.

## Explicit exclusions

The following are outside scope and MUST NOT be changed under this addendum:

- database schema, data, migrations, SQL, views, triggers, policies, functions or RPCs;
- API contracts, route paths, URL paths, endpoint names or request/response structure;
- server/business logic other than an exact presentation-string substitution proven to be user-visible;
- function names, variable names, type names, component names, table/column names or other technical identifiers;
- Sage/accounting identifiers, references, posting logic, journals or integration behaviour;
- Supabase configuration or authentication/authorisation behaviour;
- package names, repository names, deployment/project names or environment-variable names;
- filenames or directory names;
- historical documentation, regression fixtures, test descriptions or archived technical material merely because they contain the old brand;
- the ignored/stale `src/app` application tree while the root `app/` tree is the active application tree.

## Protected behaviour

All currently working behaviour is protected. This change MUST NOT alter:

- calculations, totals or financial values;
- permissions or role boundaries;
- navigation destinations or redirects;
- workflow state transitions;
- notification triggering conditions;
- database reads or writes;
- accounting/posting behaviour;
- invoice, credit-note, shipment, refund, replacement, evidence or reconciliation logic;
- component structure, styling behaviour or layout except for natural text-width differences caused by the longer brand name.

No refactoring, formatting cleanup, dependency changes, opportunistic fixes, renaming, restructuring or unrelated edits are authorised.

## Ambiguity rule

If an occurrence of `Goodcashback` is not clearly presentation copy, it MUST be left unchanged and reported for separate review. No assumption may be made merely from the file extension or directory location.

A string inside a `.ts`, route, action or service file may be changed only when inspection proves that the exact string is user-facing presentation copy and the substitution cannot alter logic or an external/technical identifier.

## Implementation control

The implementation must be performed on an isolated branch. Each modified application file must preserve its original contents byte-for-byte in substance except for the authorised branding text substitutions. No unrelated code changes are permitted.

## Acceptance criteria

The change passes only when all applicable checks below are satisfied:

1. The final diff contains only this addendum plus authorised presentation-string replacements.
2. No DB, SQL, migration, RPC, API contract, route, technical identifier, Sage/accounting logic, package/repository name or ignored `src/app` file is changed.
3. A residual source search is reviewed so remaining `Goodcashback` occurrences are either non-user-facing/out of scope or explicitly reported.
4. A reverse search confirms `Goods To Ship` appears in the intended active UI locations.
5. Available typecheck/build/lint validation is run where tooling permits, and any failure is reported rather than worked around through scope-expanding code changes.
6. No functional or structural code change is present in the final diff.

## Fail-closed rule

Any proposed edit that cannot be proven to be presentation-only is rejected from this change. Protecting existing working behaviour takes priority over completing every possible old-brand occurrence.
