# Multi-Supplier-Invoice Order Control Addendum v1.2

**Status:** governing corrective authority to `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`, specifically its Section 30 supervisor clean-line takeover correction

**Effective date:** 14 August 2026

**Repository baseline inspected:** `main` at `1f72a5f22f0a684c0eb67842752e1f7a6e32bd5b`

**Frozen production baselines inspected:**

```text
app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx
blob sha: 5e933a16aed9fc21d811dfbcfd4be823f7bbd068

app/internal/reconciliation/[order_id]/actions.ts
blob sha: 4e8eb348f7da7263bb86f3e971ba68b3010edef6

app/importer/reconciliation/[order_id]/page.tsx
blob sha: c628f3740b335a1e55a9cfe0d3bb2674fde59791

app/importer/reconciliation/[order_id]/actions.ts
blob sha: 0e01ed8b98a594c5757ef595085ff0cd343381a2

supabase/migrations/202608141438_supervisor_clean_line_takeover_compatibility.sql
blob sha: b011d3d9c6fa8be505f87baa9db2897024113dd8
```

This amendment is deliberately narrow. It corrects only the supervisor exact-invoice clean-line takeover incompatibility proven after the Section 30 routing repair. It does not reopen or redesign Mini-builds 1–4.

Where this document is more specific for supervisor exact clean-line takeover, it controls over Section 30 of `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`. Every other rule in the existing multi-supplier-invoice contract remains unchanged. `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_1.md` is unaffected because it governs the separate reconciliation-replacement identity correction.

## 1. Proven live defect after the Section 30 routing repair

The Section 30 routing correction is working: an order with multiple active supplier invoices routes through the existing invoice bundle, and the supervisor can open the exact selected supplier invoice.

The remaining incompatibility is inside the exact-invoice clean-line candidate calculation and the existing staff progression RPC.

### 1.1 Exact page candidate defect

The current exact page defines an unprogressed physical candidate only as:

```text
not progressed
and
not already covered by an active non_physical_financial resolution
```

That is insufficient for a newly OCR-extracted invoice because genuine financial rows may still be unresolved. A delivery, discount or fee row can therefore be displayed as if it were physical stock merely because it has not yet been Parked.

The already-working importer reconciliation page has the required classification seam. It excludes obvious non-physical rows from physical selection using the existing description vocabulary and source amount:

```text
discount|promotion|promotional|promo|voucher|coupon|saving|savings

delivery|shipping|postage|freight|carriage

fee|charge|surcharge

or a negative source amount
```

This existing importer behaviour is the reference implementation. The importer code itself must not be changed by this correction.

### 1.2 Staff progression baseline defect

The current live function:

```text
public.staff_progress_supplier_invoice_lines(uuid,uuid,uuid[],text)
```

correctly proves the selected lines belong to the exact `p_supplier_invoice_id`, but its order-value guard still compares raw progressed/selected physical amounts with `orders.order_total_gbp_declared` without the signed per-invoice delivery/discount treatment already established by importer reconciliation.

On an adjustment-bearing multi-invoice order, raw physical goods can legitimately exceed the final declared order value because the declared value already includes invoice discounts and delivery.

The guard therefore falsely blocks the second exact supplier invoice even though the complete commercial bundle is exactly within the original order baseline.

## 2. Controlled live evidence

The live read-only parity probe on 14 August 2026 proved the following order state:

```text
Order: ORD-1786712731703
Order ID: 6f41a088-8e4a-44e3-80f3-f4631b3d0002
Original quantity baseline: 4
Original value baseline: £752.99
```

Exact active invoices:

```text
NIN-140826-001
physical qty:        3
physical goods:      £570.01
retailer discount:   -£57.00
retailer delivery:   +£14.99
commercial invoice:  £528.00

NIN-140826-002
physical qty:        1
physical goods:      £249.99
retailer discount:   -£25.00
commercial invoice:  £224.99
```

Order bundle:

```text
physical qty:        4
physical goods:      £820.00
discount:            -£82.00
delivery:            +£14.99
commercial bundle:   £752.99
```

The same probe proved that all three adjustment facts already exist against the correct exact `supplier_invoice_id` and are approved:

```text
NIN-140826-001 retailer_discount £57.00
NIN-140826-001 retailer_delivery £14.99
NIN-140826-002 retailer_discount £25.00
```

No data-model correction is required.

## 3. Governing business rule

Supervisor takeover must reuse the existing multi-invoice model:

```text
selected supplier invoice
→ show/select only clean physical lines from that exact invoice
→ progress only those exact selected line IDs on that exact invoice
→ leave every sibling invoice unchanged

order-wide control
→ preserve the original order quantity/value baseline
→ calculate the commercial contribution using the already-proven signed invoice-adjustment treatment
→ never manufacture capacity from an unrelated untouched sibling invoice
```

A supplier invoice remains a separate legal, evidence, VAT, accounting and AP source. This correction must not merge supplier invoices or create an order-wide artificial invoice.

## 4. Exact supervisor-page classification contract

The existing exact page remains the supervisor progression authority for one selected supplier invoice.

Its physical candidate calculation must be narrowed to:

```text
not progressed
and
no active non_physical_financial resolution
and
not obvious non-physical
```

For this correction, `obvious non-physical` reuses the existing importer reconciliation vocabulary exactly:

```text
negative source amount
or discount/promotion/promotional/promo/voucher/coupon/saving/savings description
or delivery/shipping/postage/freight/carriage description
or fee/charge/surcharge description
```

Description matching must use the same normalisation shape already used by importer reconciliation:

```text
lower-case
replace non-alphanumeric runs with spaces
trim
word-boundary-style vocabulary matching
```

This is a selection guard only.

It must not:

- mutate OCR source rows;
- mark a financial row progressed;
- silently create a non-physical resolution;
- silently create an exception;
- change the invoice header or total;
- change sibling supplier invoices.

The existing explicit non-physical resolution contract remains the authority for actually resolving/Parking financial rows.

## 5. Exact supplier-invoice isolation

Every supervisor progression request must continue carrying:

```text
p_order_id
p_supplier_invoice_id
p_line_ids
```

The staff RPC must continue proving:

1. `p_supplier_invoice_id` belongs to `p_order_id`;
2. the invoice is active and not `rejected_resubmit_required`, `superseded` or `duplicate_blocked`;
3. every selected `p_line_id` belongs to that exact `p_supplier_invoice_id`;
4. unresolved exception-linked selected rows are rejected.

The write must remain restricted to the exact selected invoice and exact selected line IDs.

Progressing Invoice A must change zero rows on Invoice B.

## 6. Server-side financial-row defence

The UI is not authoritative.

Before any progression update, the staff RPC must independently reject a selected row that is not eligible for physical takeover because it is:

- already covered by an active `non_physical_financial` resolution;
- an obvious non-physical row under Section 4;
- linked to an unresolved exception.

This server guard is mandatory so stale tabs or direct/manual submissions cannot progress a discount, delivery or fee as stock.

No new table, status, resolution type or progression RPC is authorised.

## 7. Quantity baseline contract

The original quantity baseline remains:

```text
orders.total_qty_declared
```

Projected physical quantity remains:

```text
already-progressed physical quantity across active supplier invoices
+
selected not-yet-progressed physical quantity
```

Active non-physical financial resolutions contribute zero physical quantity.

The existing ceiling remains:

```text
projected physical quantity <= orders.total_qty_declared
```

No quantity baseline is increased, rewritten or inferred from OCR.

## 8. Signed value-baseline parity contract

The original value baseline remains:

```text
orders.order_total_gbp_declared
```

The correction must reuse the already-built importer signed financial treatment rather than compare raw physical goods alone.

### 8.1 Already-accounted value

Already-accounted value is composed from:

- already-progressed physical lines on active supplier invoices;
- active `non_physical_financial` resolutions using the existing sign treatment.

Resolved financial sign treatment remains:

```text
discount              => -abs(source amount)
delivery              => +abs(source amount)
fee                   => +abs(source amount)
zero_value_delivery   => 0
rounding / other      => preserve source signed amount
```

Resolved financial rows contribute zero physical quantity.

### 8.2 Selected physical proposal

For selected, not-yet-progressed physical rows, preserve the existing confirmed-value fallback:

```text
qty_confirmed ?? qty
amount_confirmed ?? amount_inc_vat_gbp
```

### 8.3 Proved unresolved invoice financial offset

A still-unresolved OCR discount or delivery row may affect the progression value guard only when the existing importer proof conditions are satisfied:

1. it is on an active supplier invoice;
2. it is not already progressed, resolved as non-physical or exception-linked;
3. discount recognition requires a negative source amount plus the existing discount vocabulary;
4. delivery recognition requires a positive source amount plus the existing delivery vocabulary;
5. the aggregate extracted amount for that kind and invoice agrees with the existing same-invoice `order_value_adjustments` fact within £0.01;
6. the adjustment fact is not rejected;
7. an already-accounted financial row must not be counted again.

For supervisor multi-invoice progression, the proved unresolved offset may be considered only for an invoice that is commercially participating in the projected position because:

```text
it contains at least one already-progressed physical line
or
it is the exact invoice containing a currently selected physical line
```

An untouched sibling invoice with no progressed physical line and no currently selected physical line must not create baseline capacity.

This is the narrow multi-invoice continuation of the existing importer same-invoice proof rule. It allows the signed contribution of Invoice A to remain represented when the supervisor later progresses clean lines from Invoice B, without allowing an unrelated untouched sibling invoice to manufacture capacity.

### 8.4 Projected order-value check

The authoritative staff pre-write guard becomes:

```text
projected_value
=
already_accounted_value
+ selected_unaccounted_physical_value
+ proved_unresolved_financial_offset_for_participating_invoices
```

Then preserve the existing tolerance:

```text
projected_value <= orders.order_total_gbp_declared + £0.01
```

The order baseline is not expanded.

## 9. Sequence independence

The supervisor result must be stable whether a proved discount/delivery row is explicitly Parked before or after clean physical progression.

An already-resolved financial row must never also enter the unresolved provisional offset.

For the controlled order, progressing the clean physical lines invoice-by-invoice must permit:

```text
NIN-140826-001 → 3 physical lines only
NIN-140826-002 → 1 physical line only
```

with final projected truth:

```text
physical quantity = 4
commercial value  = £752.99
```

and with zero sibling-line writes from either exact-invoice action.

## 10. Authorised production scope

Production code may change only:

```text
app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx
```

and one new forward migration that `CREATE OR REPLACE`s only:

```text
public.staff_progress_supplier_invoice_lines(uuid,uuid,uuid[],text)
```

A focused regression file may be added under:

```text
docs/testing/
```

This governing amendment is the documentation change.

No other production file is authorised.

In particular, this correction must not modify:

```text
app/importer/reconciliation/[order_id]/page.tsx
app/importer/reconciliation/[order_id]/actions.ts
app/importer/reconciliation/[order_id]/nonPhysicalActions.ts
app/internal/reconciliation/[order_id]/actions.ts
```

The importer implementation is reference evidence only and must remain byte-for-byte unchanged.

## 11. Staff RPC invariants that must remain unchanged

The replacement function must preserve the existing:

- function name and identity arguments;
- integer return type;
- `SECURITY DEFINER` mode;
- search path;
- active admin/supervisor authority;
- exact order/invoice ownership proof;
- retired-invoice rejection;
- exact selected-line membership proof;
- unresolved exception rejection;
- original order quantity ceiling;
- original order value ceiling and £0.01 tolerance;
- update of only currently unprogressed selected rows;
- `eligible_for_invoice_yn = 'Y'` progression semantics;
- `qty_confirmed = COALESCE(qty_confirmed, qty)` semantics;
- `amount_confirmed = COALESCE(amount_confirmed, amount_inc_vat_gbp)` semantics;
- row-count return semantics;
- existing execute grants.

No historical migration may be edited. The correction must be additive through one new forward migration.

## 12. Explicit upstream/downstream non-impact boundary

This correction must not alter, replace or redesign:

- importer/operator reconciliation behaviour;
- operator progression RPCs;
- OCR fetch, parsing, save or materialisation;
- supplier invoice upload, identity, reference-family or duplicate rules;
- `is_current_for_order` storage or other consumers;
- order estimates or accepted commercial baseline fields;
- non-physical resolution schema/RPC semantics;
- exception creation, refund or replacement routes;
- customer review or customer holds;
- tracking or delivery allocation;
- package or shipment membership;
- physical receipt;
- supplier accounting coding or accounting totals views;
- supplier invoice approval/rejection;
- supplier AP or supplier-payment allocation;
- DVA/card/funding/treasury;
- customer sales release;
- Sage payloads, posting, snapshots or confirmations;
- VAT;
- loyalty or settlement credit;
- order-status functions or triggers;
- tenant isolation, RLS, roles or permissions.

The existing `supplier_invoice_lines` audit, customer-review materialisation and order-status triggers must remain installed and unchanged. A legitimate progression continues to fire those existing downstream consumers naturally because the same progression columns are updated; this patch does not call, replace or suppress those downstream authorities.

## 13. Mandatory regression before release

The implementation must prove at minimum:

1. the exact supervisor page still authenticates only active admin/supervisor staff;
2. exact `supplier_invoice_id` routing remains unchanged;
3. NIN-140826-001 offers only its three physical product rows for progression;
4. its discount and delivery rows are not physical candidates;
5. NIN-140826-002 offers only its one physical product row;
6. its discount row is not a physical candidate;
7. a crafted request containing an obvious financial row is rejected server-side before update;
8. a crafted request containing an active resolved non-physical row is rejected server-side before update;
9. unresolved exception-linked rows remain blocked;
10. progressing one exact invoice cannot update a sibling invoice;
11. progressing NIN-140826-001 then NIN-140826-002 projects exactly quantity 4 and value £752.99;
12. the same result remains valid when proved financial rows are Parked first;
13. already-resolved financial value is not counted again as unresolved offset;
14. an untouched sibling invoice cannot manufacture capacity;
15. an unmatched OCR description cannot manufacture capacity;
16. an adjustment from another supplier invoice cannot manufacture capacity;
17. a rejected adjustment cannot manufacture capacity;
18. a genuine fifth physical unit remains blocked;
19. a genuine value excess above the existing £0.01 tolerance remains blocked;
20. retired invoices remain excluded from the active order position;
21. the staff function identity, return type, security mode, search path and grants are unchanged;
22. `app/importer/reconciliation/[order_id]/page.tsx` has zero diff;
23. `app/importer/reconciliation/[order_id]/actions.ts` has zero diff;
24. `app/internal/reconciliation/[order_id]/actions.ts` has zero diff;
25. no tracking, shipment, accounting, Sage, VAT, funding, hold, refund, replacement or customer-release production file changes.

## 14. Build procedure and stop rule

Implementation must follow this order:

1. commit this governing amendment before production code changes;
2. re-fetch the frozen production sources from the build branch;
3. stop and review if an unexpected source blob changed;
4. modify only the exact supervisor page;
5. add one forward migration replacing only the staff progression function;
6. add/run the focused source regression;
7. inspect the final diff and prove the importer and downstream/upstream files have zero diff;
8. do not merge if any production file outside the authorised two-file scope changed.

If implementation appears to require another production file, table, RPC, trigger, view, status, permission or workflow:

```text
STOP
record the separate defect
do not expand this patch
```

## 15. Acceptance rule

This correction is complete only when the supervisor can use the existing multi-invoice exact lane to progress the clean physical subset of each supplier invoice independently, while the original order quantity/value baseline remains enforced using the existing signed invoice-adjustment truth, and every importer, accounting, tracking, shipment, Sage, VAT, funding, hold, refund, replacement and customer-release path remains unchanged.

No new lane. No new reconciliation model. No importer rewrite. No sibling writes. No upstream/downstream redesign.