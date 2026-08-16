# Shipper Shipment Batch Bulk Selection Style Alignment Amendment v1

Status: locked governing amendment for the `/shipper/shipments/new` bulk-selection visual correction.

## Parent authority

This amendment is subordinate to and must preserve:

- `docs/governing-pack/ui/SHIPPER_SHIPMENT_BATCH_BULK_SELECTION_UI_ADDENDUM_v1.md`
- `docs/testing/20260816_shipper_shipment_bulk_selection_source_regression_v1.mjs`
- `docs/testing/20260805_exact_shipment_ui_wiring_source_regression_v1.mjs`

## Purpose

Correct the visual treatment of the existing `Select all` helper button on `/shipper/shipments/new` so that it follows the established neutral slate shipper-side selection-control pattern rather than the current green/emerald treatment.

This is a presentation-only correction. It grants no authority to change selection behaviour, form behaviour, shipment eligibility, shipment creation, responsive synchronisation, backend authorities, database state, Groupage, Shipment Undo, accounting, Sage or VAT.

## Established platform pattern

The shipper-side Groupage selection control at:

`app/shipper/groupage-movements/GroupageSelectionControls.tsx`

uses the following neutral helper-control treatment for `Select all`:

`rounded-xl border border-slate-300 bg-white px-3 py-2 text-xs font-semibold text-slate-800 hover:bg-slate-100`

The shipment bulk-selection control already uses the same neutral slate treatment for `Clear selection`.

Therefore `Select all` on `/shipper/shipments/new` must use the same neutral slate color treatment while preserving its existing shipment-specific sizing (`text-sm`) and all other existing classes.

## Permitted runtime scope

Exactly one runtime file may change:

`app/shipper/shipments/new/ShipmentSelectionControls.tsx`

Within that file, the only permitted runtime change is the `className` string on the existing `Select all` button.

### Current class

`rounded-xl border border-emerald-300 bg-white px-3 py-2 text-sm font-semibold text-emerald-900 hover:bg-emerald-50`

### Required class

`rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-100`

No other class, text, event handler, state, hook, selector, form reference or component structure may change.

## Explicitly protected working behaviour

The following must remain byte-for-byte functionally unchanged by this amendment:

- `setSelection(true)` behaviour;
- `setSelection(false)` behaviour;
- `selectedIdsRef` logical selection state;
- selected-count behaviour;
- `syncResponsiveCopies` behaviour;
- rendered/hidden responsive-copy detection;
- disabling of hidden responsive checkbox copies;
- mobile/desktop selection synchronisation;
- resize/orientation synchronisation;
- pre-submit synchronisation;
- checkbox `name`, `value` and `data-shipment-batch-select` hooks;
- importer selection behaviour;
- existing form action and submission path;
- individual checkbox selection/deselection;
- shipment candidate eligibility and exact quantities;
- duplicate-selection database protection.

## Explicitly prohibited changes

Do not change:

- `app/shipper/shipments/new/page.tsx`;
- `app/shipper/shipments/new/exact-actions.ts`;
- `PackageContentsPreview`;
- any shipment candidate/create RPC;
- any SQL or migration;
- database schema or permissions;
- Groupage code, functions, UI, status or permissions;
- Shipment Batch Undo code, migration, permissions or UI;
- shipment labels, navigation, totals or page copy;
- any other runtime file.

No refactor, cleanup, abstraction, formatting sweep or neighbouring style change is authorised.

## Regression gate

After the one-class visual correction:

1. `docs/testing/20260816_shipper_shipment_bulk_selection_source_regression_v1.mjs` must remain passing.
2. `docs/testing/20260805_exact_shipment_ui_wiring_source_regression_v1.mjs` must remain passing.
3. TypeScript/typecheck should remain passing where the existing project command is available.
4. Repository diff must show exactly one runtime file changed under this amendment.
5. Within that runtime file, the only source change must be the `Select all` `className` string described above.
6. No SQL/migration/database action is required or authorised.

## Acceptance condition

Accepted only if `Select all` changes visually from emerald/green to the established neutral slate helper-control treatment and every existing working selection and shipment behaviour remains unchanged.

Anything beyond this exact visual correction is scope creep and requires separate governing authority.
