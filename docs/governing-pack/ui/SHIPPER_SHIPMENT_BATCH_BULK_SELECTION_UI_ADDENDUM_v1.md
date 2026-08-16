# Shipper Shipment Batch Bulk Selection UI Addendum v1

Status: locked governing authority for the `/shipper/shipments/new` bulk-selection UI patch.

## Purpose

Add a narrow UI convenience to the existing shipper shipment-batch creation page so a shipper can select or clear all currently eligible packages for the chosen importer while preserving individual checkbox control.

This addendum changes presentation and client-side selection handling only. It does not change shipment eligibility, shipment creation, package membership, line membership, holds, receipt truth, quantities, downstream shipment facts, accounting, Sage or VAT.

## Parent authorities

This addendum is subordinate to and must preserve:

1. `docs/governing-pack/architecture/LINE_LEVEL_SHIPMENT_MEMBERSHIP_ADDENDUM_v1.md`.
2. The live `shipper_shipment_batch_candidates_v2()` authority.
3. The live `shipper_create_shipment_batch_v2(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)` authority.
4. The existing server action `app/shipper/shipments/new/exact-actions.ts`.
5. The existing source regression `docs/testing/20260805_exact_shipment_ui_wiring_source_regression_v1.mjs`.

Where this UI addendum conflicts with existing shipment eligibility, membership, hold, receipt, creation or downstream authorities, the existing backend/architecture authority wins. This addendum grants no authority to alter those behaviours.

## Existing platform patterns to reuse

The patch should reuse the established selection-control patterns already present in the platform rather than introduce a new selection architecture:

- `app/importer/reconciliation/[order_id]/BulkLineSelectionControls.tsx` for Select all / Clear selection / selected-count behaviour.
- `app/internal/shipping-control/customer-invoice-release/SelectionControls.tsx` for form-scoped/data-attribute targeting.
- `app/shipper/groupage-movements/GroupageSelectionControls.tsx` for the simple shipper-side bulk-selection interaction.

The Groupage implementation must not be copied verbatim because `/shipper/shipments/new` renders mobile and desktop copies of each logical tracking-package checkbox. The shipment patch must prevent both responsive copies from entering one form submission.

## Required behaviour

On `/shipper/shipments/new`, for the currently chosen importer:

1. Show `Select all`.
2. Show `Clear selection`.
3. Show `X of Y selected`.
4. Preserve normal individual checkbox selection and deselection.
5. Do not preselect packages on initial page load.
6. Do not preselect packages when the importer changes.
7. `Select all` must select exactly the currently rendered eligible package IDs for the chosen importer.
8. `Clear selection` must clear all logical package selections.
9. The selection count must represent unique tracking-package IDs, not DOM checkbox count.
10. Mobile and desktop are two presentations of the same logical selection state.
11. When the responsive presentation changes, the same logical tracking-package IDs must remain selected.
12. Exactly one checkbox per tracking-package ID may be enabled/submittable at any time.
13. Hidden responsive duplicate checkboxes must be disabled and cleared so they cannot enter `FormData`.
14. Responsive synchronisation must run again immediately before form submission.
15. The client control must not prevent, replace or rewrite the existing server form submission.
16. If client JavaScript fails to hydrate, the pre-existing manual single-checkbox behaviour must remain available.

## Permitted runtime scope

Exactly two runtime files may change for this patch:

1. New file: `app/shipper/shipments/new/ShipmentSelectionControls.tsx`.
2. Existing file: `app/shipper/shipments/new/page.tsx`.

The existing page may only be changed to:

- import the new client component;
- give the existing shipment-creation form a stable ID;
- render the new selection control;
- add a dedicated `data-shipment-batch-select="true"` hook to the existing mobile and desktop tracking-package checkboxes.

The existing checkbox `name`, `value`, package data, eligibility data, responsive layout, labels and form action must remain unchanged.

## Explicitly prohibited changes

This patch must not change:

- `app/shipper/shipments/new/exact-actions.ts`;
- `shipper_create_shipment_batch_v2`;
- `shipper_shipment_batch_candidates_v2`;
- any SQL or migration;
- database schema;
- receipt/review rules;
- hold logic;
- exact shipment quantities;
- package or line membership/snapshot logic;
- importer validation;
- the duplicate-selection database guard;
- booking creation semantics;
- COS/BOL/POD;
- accounting or Sage;
- VAT;
- shipment downstream pages;
- `PackageContentsPreview`;
- importer selection behaviour;
- any existing shipment label or navigation contract.

No server-side deduplication may be added. Duplicate tracking IDs must continue to be rejected by the existing database authority.

## Backend invariants to preserve

The live preflight for this patch established the following invariants, which must remain true after the UI change:

- candidate v2 exists;
- create v2 exists;
- both functions remain `SECURITY DEFINER` with `search_path=public, pg_temp`;
- authenticated may execute create v2 and anon may not;
- duplicate tracking/package IDs are rejected;
- selected importer is revalidated;
- existing active batch membership is revalidated;
- exact shipment-ready quantity is revalidated;
- the active-tracking unique index is valid;
- the shipment line-membership unique constraint is present;
- there are zero duplicate active tracking IDs.

## Example

If one importer has eight eligible packages, the control initially shows:

`Select all | Clear selection | 0 of 8 selected`

After `Select all`, all eight unique package IDs are selected. If the user unticks one, the control shows `7 of 8 selected`.

If the page changes from desktop table presentation to mobile card presentation, those same seven package IDs remain selected. The hidden responsive copies remain disabled and cannot be submitted.

Submitting the form with seven logical selections must produce exactly seven unique `tracking_submission_ids` values for the unchanged server action.

## Regression and acceptance gate

The patch is not complete until all of the following are satisfied:

1. `docs/testing/20260805_exact_shipment_ui_wiring_source_regression_v1.mjs` remains passing.
2. A new source regression locks the bulk-selection wiring and no-scope-creep boundaries.
3. TypeScript typecheck passes.
4. Targeted lint/build validation passes where available.
5. Desktop Select all / Clear selection / individual untick works.
6. Mobile Select all / Clear selection / individual untick works.
7. Desktop-to-mobile and mobile-to-desktop presentation changes retain the same logical selected IDs.
8. `N` selected logical packages yield exactly `N` unique submitted tracking IDs.
9. Existing manual single-package selection still works.
10. The read-only live DB preflight is rerun after the patch and all protected backend invariants remain unchanged.

## Rollback

Runtime rollback is limited to removing `ShipmentSelectionControls.tsx` and reverting the small `page.tsx` hooks. There is no database or data rollback because this patch has no backend or schema changes.

## Scope lock

Anything outside the permitted runtime scope and regression/test documentation described above is scope creep and requires a separate governing authority before implementation.
