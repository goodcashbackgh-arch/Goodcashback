# Multi-Supplier-Invoice Order Control Addendum v1.3

**Status:** governing corrective authority to `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_2.md` for the supervisor staff progression baseline undercount edge case only

**Effective date:** 14 August 2026

**Repository baseline inspected:** `main` at `b155c18e2d3795cb6dddea90ff8cd99dddd4a03d`

## 1. Purpose

This amendment corrects one server-side accounting defect in:

```text
public.staff_progress_supplier_invoice_lines(uuid,uuid,uuid[],text)
```

The normal supervisor UI already excludes progressed lines from clean-line selection. This correction exists solely so the RPC remains fail-closed when a stale or crafted request contains both an already-progressed line and a newly unprogressed line.

No importer defect is being corrected. No workflow, UI, routing, accounting, tracking, shipment, Sage, VAT, funding, hold, refund, replacement, AP/payment or customer-release change is authorised.

## 2. Proven defect

The v1.2 staff RPC calculates the current progressed physical position across active supplier invoices but excludes every selected line ID using:

```sql
and not (sil.id = any(p_line_ids))
```

The later selected-line calculation adds back only selected lines that are not already progressed:

```sql
and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1')
```

Therefore, if a request contains both an already-progressed selected line and a newly unprogressed selected line, the already-progressed selected line can disappear from the projected order position.

Example with quantity baseline 4:

```text
already progressed before request = 4
request contains:
  already-progressed selected qty = 2
  newly-unprogressed selected qty = 2

old projection:
4 - 2 + 2 = 4 -> can pass

true resulting progressed quantity:
4 + 2 = 6 -> must fail
```

This defect is server-side only. The normal exact supervisor page does not offer progressed lines for selection.

## 3. Governing correction

The current progressed physical position must include **all** already-progressed physical lines across active supplier invoices, regardless of whether one of those line IDs is also present in `p_line_ids`.

The selected proposal must continue to include **only** selected lines that are not already progressed.

Therefore the authoritative projection is:

```text
projected physical quantity
=
all already-progressed physical quantity
+ selected not-yet-progressed physical quantity
```

and:

```text
projected commercial value
=
all already-progressed physical value
+ active resolved signed financial value
+ selected not-yet-progressed physical value
+ proved unresolved signed financial offset for participating invoices
```

The exact implementation correction is to remove only this predicate from the current-progressed aggregate query:

```sql
and not (sil.id = any(p_line_ids))
```

No compensating replacement predicate is required.

There is no double counting because the selected proposal query already excludes progressed lines.

## 4. Authorised production scope

Exactly one new forward migration may be added. It may `CREATE OR REPLACE` only:

```text
public.staff_progress_supplier_invoice_lines(uuid,uuid,uuid[],text)
```

No existing migration may be edited.

No application production file is authorised to change.

A focused regression file may be added under `docs/testing/`.

## 5. Frozen invariants

The replacement function must otherwise preserve the v1.2 implementation unchanged, including:

- function name and argument identity;
- integer return type;
- `SECURITY DEFINER`;
- existing `search_path`;
- active admin/supervisor authority check;
- exact order/invoice ownership proof;
- rejected/superseded/duplicate-blocked invoice rejection;
- exact selected-line membership proof;
- unresolved exception rejection;
- server-side non-physical/financial-line rejection;
- active non-physical resolution treatment;
- signed discount/delivery/fee/zero-value treatment;
- participating-invoice boundary;
- same-invoice `order_value_adjustments` proof;
- rejected-adjustment exclusion;
- £0.01 value tolerance;
- original `orders.total_qty_declared` ceiling;
- original `orders.order_total_gbp_declared` ceiling;
- exact selected-invoice write restriction;
- `eligible_for_invoice_yn = 'Y'` semantics;
- `qty_confirmed = coalesce(qty_confirmed, qty)` semantics;
- `amount_confirmed = coalesce(amount_confirmed, amount_inc_vat_gbp)` semantics;
- row-count return semantics;
- existing execute grant.

## 6. Explicit non-impact boundary

This correction must not modify:

```text
app/importer/**
app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx
app/internal/reconciliation/[order_id]/actions.ts
```

It must not modify operator progression RPCs, non-physical resolution RPCs, OCR, supplier invoice identity/versioning, `is_current_for_order`, order estimates, exceptions, customer review, holds, tracking, delivery allocation, package/shipment membership, physical receipt, accounting coding/totals, supplier approval/rejection, supplier AP/payment, DVA/card/funding, customer sales release, Sage, VAT, loyalty, settlement credit, order-status functions/triggers, RLS, roles or permissions.

Existing downstream triggers continue to fire naturally only when the same existing progression columns are legitimately updated. This amendment introduces no new downstream call or side effect.

## 7. Mandatory regression

Before merge, the build must prove:

1. the old current-progressed exclusion `not (sil.id = any(p_line_ids))` is absent from the replacement function;
2. the selected proposal still includes only unprogressed selected rows;
3. 4 already progressed + 2 newly selected against quantity baseline 4 is blocked;
4. 2 already progressed + 2 newly selected against quantity baseline 4 is permitted by quantity arithmetic;
5. a genuine fifth unit remains blocked;
6. a genuine value excess above the existing £0.01 tolerance remains blocked;
7. a request containing only already-progressed selected lines does not reduce the current progressed position;
8. signed same-invoice discount/delivery treatment remains present and unchanged;
9. exact supplier-invoice and selected-line write restriction remains unchanged;
10. importer page/actions and supervisor application action wiring remain byte-for-byte unchanged;
11. no production file other than the new forward migration changes.

## 8. Stop rule

If this correction appears to require any application production file, another RPC, table, trigger, view, permission, workflow or downstream/upstream change:

```text
STOP
record separately
do not expand this patch
```

## 9. Acceptance rule

The correction is complete when an already-progressed selected line can never disappear from the staff RPC baseline calculation, while the normal supervisor UI and every importer/upstream/downstream working path remain unchanged.

This v1.3 amendment is the governing authority for the build.