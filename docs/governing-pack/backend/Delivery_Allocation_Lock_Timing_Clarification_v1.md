# Delivery Allocation Lock Timing Clarification v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing backend/control clarification  
**Applies to:** `Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md`

---

## 1. Purpose

This clarification locks the agreed timing rule for item-to-tracking/package allocation edits.

The goal is to keep shipper operations moving without treating shipper package-level actions as proof of item contents.

---

## 2. Correct rule

Shipper package-level events do **not** lock item-to-tracking allocation.

The following do not, by themselves, lock item allocation:

1. Shipper confirms package receipt.
2. Shipper selects package/tracking ref into a shipment batch.
3. Shipper submits shipment quote.
4. Shipper submits shipment invoice.
5. Shipper enters booking reference.

Reason:

```text
Shipper confirms package movement and package/shipment truth.
Operator/supervisor confirms item-content truth.
```

A shipper may receive or ship tracking ref DHL1234 before the operator has completed allocation of the exact invoice lines inside that package.

That is acceptable, provided downstream sales invoice, Sage readiness, COS/export evidence and final closure do not rely on unresolved item allocation.

---

## 3. Hard lock points

Item-to-tracking allocation becomes hard-locked only when it has been used by downstream financial/export controls, including:

1. Customer/sales invoice release using those allocation values.
2. Draft COS/export evidence pack generation.
3. Sage payload queue or Sage posting.
4. Final export evidence clearance.
5. Explicit export/accounting allocation lock flag.

After hard lock, changes must use controlled reversal, amendment, supplementary invoice, credit note, or supervisor/admin correction route.

Do not silently edit historical allocation truth after hard lock.

---

## 4. UI rule

Fully allocated does not mean locked.

Correct UI behaviour:

```text
Fully allocated + no downstream lock
= complete but still editable/reworkable.

Fully allocated + downstream lock
= no direct edit; correction/amendment route required.
```

Operator/supervisor may clear and rework unlocked allocation rows even when a line is fully allocated.

The page should explain that shipper receipt, package selection, quote, and shipment invoice do not lock item allocation.

---

## 5. Downstream readiness rule

Before sales invoice release, draft COS/export pack generation, Sage queue/posting, or final export clearance, allocation readiness must verify:

```text
sum(qty_allocated for each progressed supplier invoice line)
=
original progressed line quantity
```

unless a supervisor/admin has accepted a controlled uncertainty/estimate route.

---

## 6. Final locked sentence

```text
Shipper actions move package/shipment truth forward, but they do not lock item-content allocation. Item allocation remains editable until it is consumed by sales invoice release, draft COS/export evidence generation, Sage queue/posting, final export evidence clearance, or an explicit export/accounting lock.
```
