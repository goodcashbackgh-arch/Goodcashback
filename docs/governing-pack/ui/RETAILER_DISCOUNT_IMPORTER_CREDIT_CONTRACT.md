# Retailer Discount → Importer Credit Contract

## Purpose

When an importer/customer funds an order based on the original quoted or declared goods value, but the final supplier invoice is lower because of a retailer discount, the platform must recognise the economic surplus without creating a fake bank receipt, fake refund, or supplier credit note.

The goal is simple:

1. Preserve the original customer funding receipt.
2. Explain the lower supplier invoice value.
3. Clear the order's commercial/value balance.
4. Create a controlled importer credit balance for the discount passed back to the importer.
5. Keep Sage/accounting treatment clean and auditable.

This contract covers retailer discounts where the customer treatment is `pass_to_importer`.

---

## Problem this solves

Example:

- Order declared/funded value: £199.99
- Customer/importer funding received: £199.99
- Final supplier invoice: £161.99
- Retailer discount: £38.00

The customer did not overpay at the time of funding, because the order funding gap was £199.99. The surplus only became known later when the supplier invoice proved that the actual goods cost was £161.99.

Therefore this is not DVA overfunding at funding-match time. It is a post-funding commercial adjustment.

---

## Non-negotiable accounting principle

Do not create another bank receipt.

The original customer receipt already exists economically and operationally:

- Bank/DVA/card receipt: £199.99
- Customer/importer control account credited: £199.99

The later £38 retailer discount is not new cash received. It is a reduction in the value needed for that order's goods cost, creating a credit balance owed/available to the importer.

The platform treatment should mirror the customer account position:

- Customer/importer funded £199.99.
- Supplier/order goods cost settled at £161.99.
- £38 remains as importer credit, refund due, or offset against future/shipping charges.

---

## Scope

In scope:

- Approved `order_value_adjustments` rows where:
  - `adjustment_type = 'retailer_discount'`
  - `customer_treatment = 'pass_to_importer'`
  - `approval_status in ('approved', 'auto_approved')`
  - `amount_gbp > 0`
  - linked to a current/accepted supplier invoice where possible
- Creation or synchronisation of importer credit ledger rows
- Order-level balance/readiness clearance
- Idempotent rebuild/update if the adjustment amount changes
- Deletion/reversal if the adjustment is rejected or superseded

Out of scope:

- Supplier credit notes
- Retailer refunds returning cash to the platform
- DVA/card statement refund-IN matching
- New bank receipt posting
- Sage posting itself

---

## Terminology

### Retailer discount

A reduction in the amount charged by the retailer/supplier compared with the original declared/quoted order value.

### Pass to importer

The platform does not keep the discount as margin. The benefit belongs to the importer/customer.

### Importer credit

A controlled credit balance on `importer_credit_ledger` that can later be:

- Applied to a future order,
- Offset against shipping or other customer charges if supported,
- Refunded manually/externally with evidence,
- Used in final customer account reconciliation.

---

## Correct platform flow

### 1. Supplier invoice proves lower goods cost

The supplier invoice is uploaded/OCR'd/reconciled/coded.

If the invoice total is below the original declared/funded order value, and all physical goods are progressed, the remaining difference should be treated as a financial adjustment, not a product exception.

### 2. Retailer discount adjustment is created

Create an `order_value_adjustments` row:

```text
adjustment_type = retailer_discount
amount_gbp = discount amount, stored positive
customer_treatment = pass_to_importer
approval_status = pending_supervisor or auto_approved depending rule
supplier_invoice_id = current supplier invoice id
order_id = order id
requires_supervisor_approval = true unless auto-rule explicitly allows approval
```

### 3. Supervisor approves discount

When supervisor approves, the platform must check:

- The supplier invoice is not rejected/superseded.
- The order belongs to the same importer as the supplier invoice.
- The discount amount is positive.
- The adjustment is not already converted into importer credit.
- The adjustment is not linked to an old rejected invoice.

### 4. Importer credit is created or synced

On approval, create/update one `importer_credit_ledger` credit row:

```text
importer_id = orders.importer_id
direction = credit
amount_gbp = order_value_adjustments.amount_gbp
amount_local_ccy = amount_gbp unless a later FX/local rule is explicitly added
local_ccy = GBP for v1 unless derived safely from importer currency/rate policy
entry_type = manual_credit or retailer_discount_credit
source_table = order_value_adjustments
source_id = order_value_adjustments.id
source_type = retailer_discount
source_entity_type = order_value_adjustment
source_entity_id = order_value_adjustments.id
linked_order_id = orders.id
linked_dispute_id = null
applied_to_order_id = null
lock_reason = null
notes = Approved retailer discount passed to importer
created_by_staff_id = approving staff id
effective_at = approved_at / now()
```

This must be idempotent. Re-approving or re-running the sync must not create duplicates.

### 5. Order balance is commercially cleared

The order should be considered commercially explained when:

```text
customer/importer funding received
minus accepted supplier goods invoice
minus approved pass-to-importer discount credit
minus other approved customer-facing adjustments
= 0 or within rounding tolerance
```

For the example:

```text
£199.99 funding - £161.99 supplier invoice - £38.00 importer credit = £0.00 commercial balance
```

This clears the value difference without inventing a refund or credit note.

---

## What must not happen

Do not:

- Create a second DVA/bank receipt.
- Treat the retailer discount as a supplier credit note.
- Treat it as a product shortage.
- Treat it as a shipper discrepancy.
- Post it directly to Sage from this action.
- Leave the customer surplus invisible.
- Allow the platform to retain the £38 unless `customer_treatment` explicitly says the platform keeps the benefit.

---

## Minimum robust data rule

There must be at most one active importer-credit row per approved pass-to-importer retailer discount adjustment.

Recommended uniqueness concept:

```text
importer_credit_ledger.source_type = retailer_discount
importer_credit_ledger.source_entity_type = order_value_adjustment
importer_credit_ledger.source_entity_id = order_value_adjustments.id
```

The implementation should use an upsert or guarded insert keyed on those source fields where the existing schema allows it.

---

## Status behaviour

### Pending adjustment

No importer credit is created yet.

The order remains commercially unresolved unless another control explains the difference.

### Approved adjustment

Importer credit is created/synced.

The commercial/value variance is cleared if the credit equals the remaining customer surplus.

### Rejected adjustment

Any generated importer credit for that adjustment must be removed or reversed.

The order returns to commercially unresolved if no other approved adjustment explains the difference.

### Superseded/rejected supplier invoice

If the linked supplier invoice is rejected/superseded, the adjustment should be rejected/retired and any linked importer credit removed/reversed.

This already happens for the adjustment retirement side; the new bridge must ensure generated importer credit is also not left orphaned.

---

## Simple v1 implementation proposal

Build one SECURITY DEFINER RPC:

```text
staff_sync_retailer_discount_importer_credit_v1(p_order_value_adjustment_id uuid)
```

Responsibilities:

1. Verify caller is active admin/supervisor.
2. Lock the adjustment row.
3. Verify adjustment is retailer discount, positive, pass to importer, approved/auto-approved.
4. Verify linked order exists.
5. Verify linked supplier invoice is not rejected/superseded if supplier_invoice_id is present.
6. Insert or update one importer credit ledger row for the adjustment.
7. Return order id, adjustment id, credit ledger id, amount, importer id.

Build one cleanup RPC or branch inside same RPC:

```text
staff_revoke_retailer_discount_importer_credit_v1(p_order_value_adjustment_id uuid, p_reason text)
```

or have the sync function delete/reverse the credit when adjustment is no longer approved.

For v1, prefer explicit supervisor action or explicit server action after approval over hidden broad triggers. The system is still under active build, and explicit action is easier to test and audit.

---

## UI contract

### Where it should appear

Best minimum UI locations:

1. Internal reconciliation/order accounting page
2. Pre-Sage/order readiness page
3. Supplier draft ready/actioned invoice history as a follow-up warning if missing

### Display wording

Show a clear control card:

```text
Retailer discount surplus
Customer funded: £199.99
Accepted supplier invoice: £161.99
Discount passed to importer: £38.00
Importer credit: missing / created / reversed
```

### Action button

If approved discount exists but no importer credit exists:

```text
Create importer credit
```

If credit exists:

```text
Importer credit created
```

If adjustment is rejected:

```text
Discount rejected / retired
```

---

## Accounting interpretation

This is not a bank transaction. It is a customer/importer account movement.

Conceptually:

1. Original receipt remains posted/represented as customer funding:

```text
Dr Bank / DVA clearing £199.99
Cr Importer/customer control £199.99
```

2. Supplier invoice/AP represents the actual purchase cost:

```text
Dr Purchases / stock / goods control £134.99
Dr Input VAT £27.00
Cr Supplier/AP £161.99
```

3. Approved retailer discount passed to importer creates/identifies the remaining importer credit balance:

```text
Importer/customer control remains in credit by £38.00
Platform subledger records importer credit £38.00
```

Sage posting design can later decide whether this is posted as a customer credit allocation, liability movement, or left as platform subledger until applied/refunded. This contract only defines the platform control state.

---

## Readiness rules

An order with a retailer discount surplus should not be pre-Sage complete until one of these is true:

- An approved pass-to-importer discount adjustment has a linked importer credit ledger row; or
- The discount is explicitly treated as platform-retained margin; or
- The difference is otherwise explained by an approved customer-facing adjustment.

For pass-to-importer discounts, missing importer credit is a blocker.

Suggested blocker message:

```text
Customer funded more than accepted supplier cost. Approved retailer discount must be passed to importer credit before final Sage/customer account readiness.
```

---

## Acceptance test: ORD-1777736251155

Given:

```text
order_id = 9ba43dac-6946-4756-b0f5-6d6987c99be0
order_ref = ORD-1777736251155
customer funding = £199.99
current supplier invoice = 09ed41d2-4a3f-44fa-b292-ed1bdcd92735
supplier invoice total = £161.99
old rejected discount adjustment = £38 linked to rejected invoice dedb016b...
```

Expected after fix:

1. Create or approve a current retailer discount adjustment:

```text
supplier_invoice_id = 09ed41d2-4a3f-44fa-b292-ed1bdcd92735
adjustment_type = retailer_discount
amount_gbp = 38.00
customer_treatment = pass_to_importer
approval_status = approved or auto_approved
```

2. Sync importer credit:

```text
importer_credit_ledger.direction = credit
amount_gbp = 38.00
source_type = retailer_discount
source_entity_type = order_value_adjustment
source_entity_id = new adjustment id
linked_order_id = 9ba43dac-6946-4756-b0f5-6d6987c99be0
```

3. Diagnostic should show:

```text
approved_discount_adjustments_gbp = 38.00
importer_credit_for_order_gbp = 38.00
commercial balance = 0.00
```

---

## SQL diagnostic expected after implementation

```sql
select
  o.order_ref,
  o.order_total_gbp_declared as customer_funded_basis_gbp,
  coalesce(si.ocr_invoice_total_gbp, fs.invoice_total_gbp) as accepted_supplier_invoice_gbp,
  coalesce(sum(ova.amount_gbp) filter (
    where ova.adjustment_type = 'retailer_discount'
      and ova.customer_treatment = 'pass_to_importer'
      and ova.approval_status in ('approved','auto_approved')
  ), 0) as approved_discount_passed_to_importer_gbp,
  coalesce(sum(abs(icl.amount_gbp)) filter (
    where icl.direction = 'credit'
      and icl.source_type = 'retailer_discount'
      and icl.source_entity_type = 'order_value_adjustment'
  ), 0) as importer_credit_created_gbp
from public.orders o
left join public.supplier_invoices si
  on si.order_id = o.id
 and si.id = '09ed41d2-4a3f-44fa-b292-ed1bdcd92735'
left join public.supplier_invoice_financial_summary fs
  on fs.supplier_invoice_id = si.id
left join public.order_value_adjustments ova
  on ova.order_id = o.id
left join public.importer_credit_ledger icl
  on icl.linked_order_id = o.id
where o.id = '9ba43dac-6946-4756-b0f5-6d6987c99be0'
group by o.order_ref, o.order_total_gbp_declared, si.ocr_invoice_total_gbp, fs.invoice_total_gbp;
```

---

## Build notes

Keep the first implementation small:

1. Add one RPC to sync approved retailer discount to importer credit.
2. Add one UI action where the missing credit is visible.
3. Add one readiness blocker if approved discount exists without credit.
4. Do not rebuild funding, DVA, credit note, or Sage posting flows.

This is a bridge between the adjustment layer and importer credit ledger, not a replacement for existing funding control.
