# Shipping Cost Apportionment Bulk Category UI Amendment v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing amendment  
**Parent authority:** `docs/governing-pack/backend/Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md`  
**Scope:** Section 10 — Shipping cost apportionment  
**Date locked:** 2026-08-12

---

## 1. Governing effect

This amendment supplements Section 10 of the parent addendum. It does not replace, weaken, or reinterpret the existing shipment membership, shipping-document, approval, AP/recharge, customer-release, Sage, export-evidence, or VAT controls.

The sole purpose is to add a supervisor convenience for applying an already-existing category/weight selection to multiple existing apportionment rows before approval.

The implementation must remain a UI-only adapter over the existing per-row category controls and existing approval path.

---

## 2. Locked architecture

The existing architecture remains authoritative:

```text
effective shipment lines
→ shipping apportionment preview
→ existing row category_code / override_reason form controls
→ existing approveShippingApportionmentAction
→ existing internal_approve_shipping_apportionment_v1
→ existing shipping_cost_allocations / shipping_cost_allocation_lines
→ existing AP/recharge and customer-release consumers
```

Bulk category selection must not create a parallel write path, parallel calculation, parallel allocation table, new RPC, new server action, or new financial state.

---

## 3. Locked change boundary

Implementation is restricted to:

```text
app/internal/shipping-control/apportionment/LiveApportionmentPreview.tsx
```

No other implementation file may be changed for this feature.

Explicitly out of scope:

- `page.tsx`;
- `actions.ts`;
- SQL migrations;
- database tables or constraints;
- `internal_shipping_apportionment_preview_v1`;
- `internal_approve_shipping_apportionment_v1`;
- `shipper_shipment_batch_effective_lines_v1`;
- shipping-category rule data;
- shipment membership;
- tracking allocation;
- AP/recharge logic;
- customer-release logic;
- Sage logic;
- export-evidence logic;
- VAT logic.

If implementation appears to require any of the above, stop and review rather than broadening the build.

---

## 4. Existing working parts must remain authoritative

The following existing mechanisms must be reused unchanged:

1. `categoryCodes` remains the single client-side category state used by the live preview.
2. The existing `rules` prop remains the sole source of available category codes, labels, and factors.
3. Existing per-row `category_code` selects remain the only category inputs submitted to the server.
4. Existing per-row `tracking_submission_id` and `supplier_invoice_line_id` hidden inputs remain the exact row identity submitted to the server.
5. Existing per-row `override_reason` inputs remain the only override-reason inputs submitted to the server.
6. Existing weighted-basis, proportional-allocation, rounding-balancing, and preview-total calculation remains unchanged.
7. The existing `Approve apportionment basis` submit button remains the only approval/save action.

Bulk controls are convenience controls only.

---

## 5. Selection semantics

Bulk row selection is temporary UI state only.

A checked row means:

```text
Apply the next bulk category edit to this row.
```

A checked row does not mean:

- included in apportionment;
- excluded from apportionment;
- processed;
- approved;
- saved;
- locked;
- released downstream.

Unchecked rows remain fully part of the existing apportionment calculation where otherwise eligible.

After a successful `Apply to selected`, the selected checkboxes clear automatically only to prepare the UI for the next group. The rows remain visible, editable, re-selectable, and unapproved until the existing approval action is used.

---

## 6. Required bulk controls

The existing preview may add a compact toolbar containing:

- `Select all`;
- `Unselect all`;
- selected-row count;
- category/weight selector;
- bulk override reason;
- `Apply to selected`.

The category selector must be populated directly from the existing `rules` prop. No hard-coded duplicate category/factor list is permitted.

All new toolbar buttons inside the existing form must explicitly use `type="button"` so they cannot submit the approval form.

All new bulk controls must remain client-only and must not use any backend form field name.

In particular, new controls must not be named:

```text
tracking_submission_id
supplier_invoice_line_id
category_code
override_reason
shipping_document_id
approval_note
```

---

## 7. Apply-to-selected behaviour

`Apply to selected` may do only the following:

1. Confirm at least one selectable row is selected.
2. Confirm a category has been selected from the existing `rules` list.
3. For each selected row, update the existing `categoryCodes[index]` value to the chosen category.
4. Where the chosen category differs from that row's original `suggested_category_code` (falling back to `unclassified`), populate that row's existing `override_reason` input with the supplied bulk reason.
5. Where the chosen category equals that row's original suggested category, clear that row's existing override-reason input.
6. Clear temporary selected-row state after the edit is applied.
7. Reset the temporary bulk category/reason controls after application.

No automatic submit or database write is permitted.

A bulk override reason is required only if at least one selected row would differ from its original suggested category.

---

## 8. Existing per-row editing remains intact

The existing individual row category dropdown remains available and must continue to work exactly as before.

Bulk editing must be equivalent to making the same category choices manually on those row dropdowns. There must not be two independent category truths.

The existing row override-reason input remains the submitted input. Bulk Apply may populate that existing input, but must not create a second submitted override field.

---

## 9. Calculation and total invariants

Bulk selection itself must never change calculation results.

Only the resulting existing row category choices may alter weighted basis and allocation, using the existing calculation already present in `LiveApportionmentPreview.tsx`.

Locked invariants:

```text
same effective shipment-line scope
same adjusted_net_value_gbp values
same source shipping total
same category rule table
same weighting formula
same balancing formula
sum(allocated shipping) = source shipping total
```

The existing calculation implementation must not be rewritten for this feature.

---

## 10. Live database proof recorded before build

A read-only live database probe was run on 2026-08-12 against shipping document:

```text
82ccda1f-4fe6-4bfa-8c73-62dd348b95e7
```

Shipment batch:

```text
029402b5-100e-4c77-bdfd-aa2433eac65f
```

Observed live facts:

- source shipping charge: GBP 20.00;
- effective shipment lines: 4;
- preview rows: 4;
- preview total: GBP 20.00;
- effective lines missing from preview: 0;
- preview lines outside effective scope: 0;
- effective shipment source mode: immutable snapshot;
- preview uses `shipper_shipment_batch_effective_lines_v1`;
- approval uses `shipper_shipment_batch_effective_lines_v1`;
- approval already accepts category overrides;
- approval uses exact tracking-submission + supplier-invoice-line identity;
- approval uses the existing `shipping_category_weight_rules` table;
- approval writes the existing shipping allocation lines;
- downstream AP/recharge reads the existing allocation lines.

The probe returned:

```text
PASS — LIVE DB SUPPORTS THE ONE-FILE CLIENT-ONLY BULK CATEGORY FIX
```

No approval function or persistent database write was executed by that probe.

---

## 11. Regression acceptance criteria

Before this feature is accepted, all of the following must hold:

1. Only `LiveApportionmentPreview.tsx` changes for implementation.
2. Selecting/unselecting rows alone changes no category, factor, weighted basis, allocated shipping, or source total.
3. `Select all` selects only rows available for editing.
4. `Unselect all` changes selection only.
5. `Apply to selected` changes categories only for selected rows.
6. Apply automatically clears temporary selection after applying.
7. Applied rows remain editable and may be re-selected.
8. Individual row category editing still works.
9. Existing row identity inputs and submitted field ordering remain intact.
10. No new submitted fields use the existing backend names.
11. A real override requires an override reason.
12. Returning a selected row to its original suggested category clears the bulk-populated reason for that row.
13. Existing preview recalculates immediately through the current `categoryCodes` calculation path.
14. Preview total remains exactly equal to source shipping total after edits.
15. Existing `Approve apportionment basis` remains the only save/approval action.
16. Typecheck, lint, and production build must pass before merge/deployment.

Reference regression for the known GBP 20.00 case:

```text
Initial live preview:
Kettle             × 1.0
Air Fryer          × 1.0
Blender            × 3.0
Food Processor     × 3.0
Total              £20.00

Bulk edit:
select Kettle + Air Fryer
→ choose Appliances × 3.0
→ enter override reason
→ Apply to selected

Expected UI result:
Kettle             × 3.0
Air Fryer          × 3.0
Blender            × 3.0
Food Processor     × 3.0
selection count    0
Total              £20.00

No database write occurs until the existing approval button is submitted.
```

---

## 12. Final locked sentence

```text
Bulk category selection is a client-only multi-edit convenience over the existing shipping-apportionment row controls. It does not create new shipment scope, calculation, submission, approval, database, AP/recharge, customer-release, Sage, export-evidence, or VAT behaviour. The existing row controls and existing approval path remain authoritative, and the implementation is restricted to LiveApportionmentPreview.tsx.
```
