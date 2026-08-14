# Multi-Supplier-Invoice Order Control Addendum v1.4

**Status:** governing additive authority to `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_3.md` for supervisor exact-invoice complete-line review parity only

**Effective date:** 14 August 2026

**Repository baseline inspected:** `main` at `7c5f2fa1c175b07a8a562564f4d591481c3bc196`

**Corrective UI baseline inspected:** `main` at `69227f58d4febd6837c6f987450a9c6373635976`

## 1. Purpose

This amendment ports only the relevant, already-working importer reconciliation line-review behaviour into the existing supervisor exact-invoice route.

The importer implementation is the functional reference for:

- complete selected-invoice line visibility;
- progressed / parked non-physical / exception-linked / unresolved display state;
- existing `obviousNonPhysical` description/sign vocabulary;
- existing `suggestedFinancialType` vocabulary;
- disabled/enabled progression-checkbox presentation;
- `BulkLineSelectionControls` select-all / clear-selection behaviour;
- explicit non-physical financial classification through the existing six-value financial-type allow-list.

The supervisor keeps its existing staff-specific authorities and exact-invoice route. This amendment does not redesign importer reconciliation and does not create a new line-state model.

## 2. Relationship to v1.3

`MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_3.md` froze application production files while correcting the staff progression baseline undercount.

This v1.4 amendment overrides that application-file freeze **only** for the two production files expressly authorised in section 4 below. Every other v1.3 invariant, function contract, upstream/downstream control and non-impact boundary remains governing and unchanged.

## 3. Required line-state model

The supervisor exact-invoice page must use the existing line-state contract:

```text
eligible_for_invoice_yn = Y
= progressed physical

N + active non_physical_financial resolution
= parked non-physical

N + active unresolved dispute
= exception-linked

N + neither
= unresolved
```

Non-physical financial classification must not change `eligible_for_invoice_yn` to `Y`. Delivery, discount, fee and other parked financial rows remain outside normal tracking/shipment progression.

## 4. Authorised production scope

Exactly these production files may change for the v1.4 importer-parity build:

```text
app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx
app/internal/reconciliation/[order_id]/actions.ts
```

One existing importer component may be imported and reused but must remain byte-for-byte unchanged:

```text
app/importer/reconciliation/[order_id]/BulkLineSelectionControls.tsx
```

No other production file is authorised to change.

A focused regression file may be added under `docs/testing/`.

No SQL migration is authorised.

For the corrective Park-UI-gate build on baseline `69227f58d4febd6837c6f987450a9c6373635976`, the only authorised production change is:

```text
app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx
```

The existing `app/internal/reconciliation/[order_id]/actions.ts` implementation is frozen for this correction and must not change.

## 5. Importer-parity mapping

The implementation must use this mapping and must not independently redesign the behaviour:

| Working importer behaviour | Supervisor v1.4 equivalent |
|---|---|
| exact selected invoice line list | existing exact `supplier_invoice_id` route |
| `progressed(line)` | same semantics |
| active resolution map | same resolution table/state |
| active dispute map | same unresolved dispute state |
| `obviousNonPhysical()` | same description/sign vocabulary |
| `suggestedFinancialType()` | same vocabulary |
| `locked = dispute || resolution` | same |
| selectable physical rows | existing supervisor physical eligibility plus dispute/resolution exclusion |
| disabled progression checkbox for non-progressable row | same presentation pattern |
| `BulkLineSelectionControls` | import/reuse unchanged |
| importer Park form | port relevant Park/classification pattern |
| operator non-physical authority | substitute existing staff non-physical authority |
| importer physical progression | keep existing supervisor progression authority |

The following importer features are expressly **not** ported:

- manual invoice-line creation/editing/deletion;
- individual importer `Mark progressed` action;
- importer exception-creation controls;
- importer order-wide variance UI;
- invoice selection cookies;
- importer access model;
- importer financial-check panel;
- importer navigation.

## 6. Exact supervisor page — data and state

The existing exact route must continue to prove the selected supplier invoice belongs to the selected order and must continue to load lines only from the exact `supplier_invoice_id`.

For those exact invoice line IDs, the page may additionally load:

1. active `supplier_invoice_line_resolutions` where `resolution_type = 'non_physical_financial'`, including `financial_type` and `notes` for display; and
2. unresolved `dispute_lines` with joined parent dispute state, using the same importer pattern: the line association is unresolved and the joined parent dispute is also unresolved before the line is placed in the active dispute map.

No new exception model is authorised.

## 7. Existing classification vocabulary

The exact supervisor page must preserve/reuse the already-present helper vocabulary:

```text
normalisedDescription
isDiscountDescription
isDeliveryDescription
isFeeDescription
obviousNonPhysical
```

It may add the importer-equivalent `suggestedFinancialType` helper using exactly the existing mapping:

```text
discount terminology -> discount
delivery terminology -> delivery
fee terminology      -> fee
otherwise             -> other_non_physical
```

`obviousNonPhysical` must continue to treat a negative source amount as non-physical and use the already-governed description terms. No new heuristic words are authorised.

## 8. Complete exact-invoice line visibility

The supervisor exact-invoice review must render **all lines belonging to the selected exact supplier invoice**, in invoice line order.

For each line derive the importer-parity display state:

```text
done = progressed(line)
resolution = active non-physical resolution for line
dispute = active unresolved dispute for line
locked = Boolean(dispute || resolution)
classificationOnly = obviousNonPhysical(line)
suggestedType = suggestedFinancialType(line)
```

Display status priority must remain equivalent to importer:

```text
done               -> Progressed
resolution         -> Parked: {financial_type}
dispute            -> Exception: {desired_outcome}
classificationOnly -> Non-physical classification required
otherwise          -> Unresolved
```

**The all-line review list must render independently of `physicalCandidates.length`. `physicalCandidates` controls physical-action availability only and must never control whether invoice lines are visible.**

## 9. Physical progression eligibility

Do not port the importer page's order-baseline arithmetic into the supervisor page.

The supervisor keeps the separately governed `public.staff_progress_supplier_invoice_lines(uuid,uuid,uuid[],text)` as final authority for:

- original order quantity/value ceilings;
- active multi-invoice participation;
- resolved signed financial value;
- proved unresolved signed financial offsets;
- exact selected-invoice writes;
- stale/crafted selected-line protection.

The page-level physical candidate rule remains the current supervisor rule:

```text
not progressed
and not actively parked non-physical
and not obviousNonPhysical
```

with the importer-equivalent addition:

```text
and not active dispute-linked
```

No duplicated page-side order-baseline engine is authorised.

## 10. Checkbox and bulk-selection behaviour

All lines may occupy the same checkbox/status position, but only `canProgress` rows are enabled for physical progression.

Physical checkboxes must use:

```text
name="line_ids"
form="bulk-progress-form"
disabled={!canProgress}
```

The existing importer `BulkLineSelectionControls` must be imported and reused unchanged.

The supervisor physical form must use:

```text
id="bulk-progress-form"
```

The component therefore continues to target only:

```text
input[name="line_ids"][form="bulk-progress-form"]:not(:disabled)
```

For the controlled NIN-140826-001 fixture, five invoice rows are visible but `Select all` must select exactly the three progressable physical rows.

## 11. Form structure

Do not nest Park forms inside the physical progression form.

The physical form may be an external form carrying the existing hidden `order_id` and `supplier_invoice_id`. Physical line checkboxes, `progress_notes` and the `Progress selected lines` button may associate with it using `form="bulk-progress-form"`.

Each line Park control remains its own independent form.

## 12. Existing supervisor physical action — frozen behaviour

The existing action:

```text
supervisorProgressSupplierInvoiceLinesAction
```

must retain its business behaviour and continue to call only:

```text
staff_progress_supplier_invoice_lines
```

Its RPC arguments, server-side baseline authority, revalidation and successful accounting redirect must remain unchanged.

No new physical progression authority is authorised.

## 13. Non-physical Park UI — corrective gate

The supervisor exact-invoice Park form must render only for a line already identified by the existing page-level `classificationOnly = obviousNonPhysical(line)` condition and only while that line is neither progressed nor locked.

The exact rendering authority is:

```text
classificationOnly && !done && !locked
```

An unresolved physical candidate with `classificationOnly = false` must not display the non-physical financial-type dropdown or `Park` button. This is a presentation gate only; it does not change physical progression eligibility, line-state semantics, the existing classifier, the existing Park action, or any backend authority.

Obvious financial rows continue to display the existing `Non-physical classification required` state/warning and remain disabled for physical progression.

The explicit financial-type allow-list remains exactly:

```text
delivery
discount
fee
zero_value_delivery
rounding
other_non_physical
```

No additional value is authorised. No automatic Park/classification is authorised. No new classifier or heuristic is authorised.

The existing `obviousNonPhysical` and `suggestedFinancialType` implementations must remain unchanged.

## 14. New supervisor Park server action

The existing v1.4 server action remains:

```text
app/internal/reconciliation/[order_id]/actions.ts
supervisorResolveSupplierInvoiceLineNonPhysicalAction
```

Its established contract remains unchanged:

1. reuse the existing `requireSupervisorOrAdmin()` guard;
2. validate `financial_type` against the exact six-value importer allow-list;
3. prove the submitted `supplier_invoice_id` belongs to the submitted `order_id`;
4. prove the submitted `line_id` belongs to the submitted exact `supplier_invoice_id`;
5. call only `public.staff_resolve_supplier_invoice_line_non_physical(uuid,uuid,text,text)`;
6. never write directly to `supplier_invoice_line_resolutions` or `supplier_invoice_lines`;
7. redirect success/error back to the same exact supervisor invoice route.

For the corrective Park-UI-gate build, this action file is frozen and no change to it is authorised.

## 15. Supervisor Park redirect/revalidation

After Park, the supervisor must remain on:

```text
/internal/reconciliation/{order_id}/invoice-bundle/{supplier_invoice_id}
```

with a simple `success` or `error` query message.

The exact page may accept/display these query values in the same simple pattern already used by importer reconciliation.

After a successful Park, revalidate only the relevant established read surfaces:

```text
/internal/reconciliation/{order_id}/invoice-bundle/{supplier_invoice_id}
/internal/reconciliation/{order_id}
/internal/supplier-draft-ready
```

No additional business RPC or workflow call is authorised.

## 16. Controlled expected result

For `ORD-1786712731703`, `NIN-140826-001` starts with five unresolved rows:

```text
Air Fryer        N
Food Processor   N
Blender          N
Order discount   N
Delivery         N
```

The page must show all five. Physical bulk selection must enable only the first three. The three physical rows must not display a non-physical Park control. The discount and delivery rows must retain their explicit financial classification/Park treatment.

Expected UI treatment:

```text
Air Fryer        -> physical checkbox only; no Park UI
Food Processor   -> physical checkbox only; no Park UI
Blender          -> physical checkbox only; no Park UI
Order discount   -> non-physical classification required; discount + Park
Delivery         -> non-physical classification required; delivery + Park
```

After explicit Park of the two financial rows:

```text
Air Fryer        N
Food Processor   N
Blender          N
Order discount   N + active non_physical_financial(discount)
Delivery         N + active non_physical_financial(delivery)
```

After existing supervisor physical progression of the three products:

```text
Air Fryer        Y
Food Processor   Y
Blender          Y
Order discount   N + parked discount
Delivery         N + parked delivery
```

Only the three physical rows may participate in normal tracking/shipment progression.

## 17. Existing accounting hand-off — unchanged

No accounting production file may change.

The existing accounting model already treats as codable:

```text
progressed physical line
OR
active non_physical_financial resolution
```

Therefore after the three physical rows are progressed and the two financial rows are parked, the existing accounting workspace must naturally expose five codable invoice rows through existing logic.

The commercial NIN-140826-001 result remains:

```text
physical goods       £570.01
discount             -£57.00
delivery             +£14.99
invoice gross         £528.00
physical quantity           3
```

No new accounting-adjustment, Sage or VAT rule is authorised by this amendment.

## 18. Exact sibling isolation

Actions on one exact supplier invoice must not mutate sibling invoice lines or create sibling invoice resolutions.

The supervisor Park wrapper must prove exact order -> invoice -> line membership before delegating to the existing staff RPC.

The existing staff physical RPC remains the only physical write authority and continues to restrict final progression writes to the selected exact supplier invoice.

## 19. Explicit frozen boundary

This amendment must not modify:

```text
app/importer/**
```

including the importer page, importer actions, importer non-physical action and reusable bulk-selection component.

For the corrective Park-UI-gate build it must also not modify:

```text
app/internal/reconciliation/[order_id]/actions.ts
```

It must not modify:

```text
public.staff_progress_supplier_invoice_lines
public.staff_resolve_supplier_invoice_line_non_physical
public.staff_bulk_save_supplier_invoice_line_accounting_codes_v2
```

It must not modify or add:

- SQL migrations;
- tables, views, triggers, RLS or grants;
- OCR;
- supplier invoice identity/current semantics;
- order-value adjustment rules;
- exception/refund/replacement workflows;
- customer holds;
- accounting coding/totals;
- supplier invoice approval logic;
- tracking/allocation/package/shipment;
- supplier AP/payment;
- funding/credit;
- customer sales release;
- Sage;
- VAT;
- loyalty/final settlement/completion;
- unrelated display defects, including the existing SKU `[object Object]` display issue.

## 20. Mandatory focused regression

Before merge, the focused regression must prove at minimum:

1. this v1.4 authority exists and documents the corrective Park-UI gate;
2. for the corrective build, only the exact supervisor invoice page changes in production;
3. the all-line exact invoice review is not gated by `physicalCandidates.length`;
4. resolution-state handling remains unchanged;
5. dispute-state handling remains unchanged;
6. `obviousNonPhysical` vocabulary remains aligned with importer and unchanged;
7. `suggestedFinancialType` vocabulary remains aligned with importer and unchanged;
8. checkboxes retain `name="line_ids"`, `form="bulk-progress-form"` and disabled state from `canProgress`;
9. the existing importer `BulkLineSelectionControls` remains byte-for-byte unchanged;
10. the Park form rendering condition is exactly `classificationOnly && !done && !locked`;
11. a bare `!done && !locked` condition is not the standalone Park-form rendering authority;
12. unresolved physical rows remain physical candidates and do not expose the Park form;
13. obvious non-physical rows remain excluded from physical progression and retain the Park form;
14. the financial allow-list is unchanged;
15. `app/internal/reconciliation/[order_id]/actions.ts` is unchanged;
16. the existing supervisor Park action remains unchanged;
17. the existing supervisor progression action/RPC wiring remains unchanged;
18. no SQL migration is added;
19. importer files are byte-for-byte unchanged;
20. accounting and other frozen production files remain unchanged.

## 21. Build stop rule

If this corrective work appears to require modifying anything other than:

```text
docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_4.md
app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx
docs/testing/20260814_supervisor_exact_invoice_importer_parity_regression_v1.mjs
```

then:

```text
STOP
record separately
do not expand v1.4
```

## 22. Acceptance rule

The corrective build is complete only when every exact-invoice line remains visible; physical progression and bulk selection remain unchanged; unresolved physical rows no longer expose the non-physical dropdown/Park control; obvious non-physical financial rows still expose the existing classification/Park control through the exact rendering condition `classificationOnly && !done && !locked`; the existing supervisor Park and physical progression authorities remain unchanged; exact sibling isolation is preserved; and importer, database, accounting and downstream working behaviour remain unchanged.

This v1.4 amendment is the governing authority for the implementation.