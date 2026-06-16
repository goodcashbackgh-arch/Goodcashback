# Floating Action Bar Behaviour Contract v1

## Purpose

Floating action bars are allowed where they reduce scrolling on long operational pages, but they must never obstruct evidence, tables, forms, submitted document rows, review notes, or workflow controls.

This contract applies first to the shipment/export-evidence pages used by shipper users and internal supervisor/staff users. It should also govern any later floating action bars added elsewhere in the platform.

## Locked behaviour

1. A floating action bar may remain fixed near the bottom of the viewport while the user is mid-page.
2. The floating action bar must hide when an equivalent inline/bottom action area is visible.
3. Where there is no equivalent inline action area, the floating action bar must hide when the relevant evidence/document list or bottom review content is reached.
4. Pages using a floating action bar must include enough bottom spacing so the final visible content cannot sit underneath the fixed bar.
5. The floating action bar must be hidden in print output.
6. The same behaviour should be reused through a shared UI component rather than repeated page-specific hacks.

## Non-negotiables

- This is a UI-only rule.
- No upload, evidence, review, status, approval, posting, accounting, VAT, or shipment workflow logic may change.
- No database schema, RLS policy, RPC, storage, or server action changes are authorised by this contract.
- Do not fix overlap by increasing z-index or simply moving the bar higher; that only moves the obstruction.
- The floating bar is a convenience layer only. Inline page content remains the source of truth for the workflow.

## Current first use

- Shipper shipment batch layout action bar.
- Internal draft COS / export evidence review layout action bar.
- Shipper final evidence upload page, where the bar must not cover submitted evidence rows.
- Internal draft review page, where the bar must disappear once the duplicated bottom action area is reached.

## Acceptance test

- Mid-page: the floating action bar is visible and usable.
- On reaching inline duplicated actions or submitted evidence/review content: the floating action bar disappears.
- At the bottom of the page: no evidence row, table row, note, upload control, review button, or action link is covered.
- Reloading, navigating directly to the page, or using a short page must not break the action links.
