# Delivery Allocation, Export Evidence & Adjustment Apportionment Addendum v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing backend/control addendum  
**Purpose:** Lock the agreed delivery-allocation, package/shipment, master-shipment, COS/BOL/export evidence, adjustment-apportionment and fast-invoicing control model so implementation does not invent parallel flows, expose values to the wrong role, or over-gate customer invoicing.

---

## 0. Required companion addendum

This addendum must be read together with:

```text
docs/governing-pack/backend/Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md
```

That companion addendum governs:

- `/internal/shipping-control`;
- shared document/OCR queue usage;
- shipper invoice/receipt document intake;
- shipping cost apportionment;
- master-shipment grouping;
- final COS/BOL/POD/container evidence lane;
- Sage/AP/customer recharge readiness for shipping costs.

If there is any doubt:

```text
Importer shipment batch = package movement truth only.
Shipper invoice/receipt = shipping cost/Sage/AP lane.
COS/BOL/POD/container = export evidence/master-shipment lane.
```

---

## 1. Governing effect

This addendum supplements and clarifies:

1. `docs/governing-pack/backend/order_value_adjustments_policy_v1.sql`
2. `docs/governing-pack/backend/Progressive_Commercial_Release_and_Replacement_Invoicing_Addendum_v1.md`
3. `docs/governing-pack/backend/VAT_Timing_and_Export_Evidence_Addendum_v1.md`
4. `docs/governing-pack/backend/Day6_8_Accounting_Release_and_VAT_Reporting_Clarification_Addendum_v1.md`
5. `docs/governing-pack/ui/STATUS_SPINE_CONTROL_MODEL_v1.md`
6. `docs/governing-pack/role-matrices/shipper_role_stage_matrix_v5.md`
7. `docs/governing-pack/role-matrices/supervisor_role_stage_matrix_v7.md`
8. `docs/governing-pack/ui/ORDER_OPERATIONS_MVP_CONTRACT.md`
9. `docs/governing-pack/ui/EXCEPTION_BRANCHING_MVP_CONTRACT.md`
10. `docs/governing-pack/backend/Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md`

Where older wording implies that final COS/BOL/POD/export evidence must exist before any stable goods customer invoice release, this addendum overrides that reading.

Correct interpretation:

```text
Stable goods/customer invoice release can be progressive.
Export evidence clearance and whole-order closure remain later controlled stages.
```

---

## 2. Locked core principle

```text
Operator/supervisor owns item-to-tracking allocation.
Shipper owns package receipt and package-to-shipment confirmation.
Supervisor owns final export evidence review.
```

Plain-English interpretation:

- Tracking ref = package / parcel handle.
- Operator or supervisor allocates progressed supplier invoice/OCR lines to tracking refs/packages.
- Shipper confirms package receipt and selects received packages/tracking refs into importer shipment batches.
- Supervisor reviews the joined item/package/shipment truth before draft COS/export evidence is generated.
- Master shipment / BOL / container / final COS / POD evidence is a later export-evidence layer, not the initial package-batch layer.

This keeps shipper workload low while preserving item/package/shipment traceability for export evidence and HMRC audit support.

---

## 3. What this build must not do

Do not:

1. Make the shipper count every item.
2. Make the shipper assign invoice lines to tracking refs.
3. Hold stable goods invoicing behind final COS, BOL, POD, Ghana delivery, or final export evidence clearance.
4. Treat one full sales invoice as fully exported under two certificates without line/quantity/value allocation.
5. Allow shipper shipment selection at whole-order level only where an order has multiple tracking refs/packages.
6. Alter original supplier invoice/OCR lines merely to support package allocation.
7. Use gross/unadjusted invoice-line value for COS/export evidence where retailer discounts or retailer delivery charges exist.
8. Allow export evidence completion where selected package contents are unknown unless supervisor has accepted a controlled basis.
9. Put final COS, BOL, master BOL, container evidence, or POD upload onto the ordinary shipper shipment batch header page.
10. Expose supplier values, customer values, VAT values, margin, Sage coding, or adjusted net values to the shipper package workflow unless a later controlled role matrix explicitly permits it.

---

## 4. Tracking ref = package handle

A tracking ref may represent:

- one item;
- multiple fashion items;
- part of one order;
- a full order;
- one parcel from a multi-parcel partial delivery;
- a late parcel arriving after an earlier shipment/container left.

Therefore, tracking refs must be treated as package records, not as proof that the whole order shipped.

The shipper should see and select received tracking refs/packages grouped by importer/order, not bare order rows.

---

## 5. Delivery allocation layer

A new delivery allocation layer is required conceptually.

Purpose:

```text
progressed supplier invoice/OCR line
→ quantity/value allocation
→ tracking ref/package
→ shipper package receipt
→ importer shipment batch
→ master shipment / export evidence review
→ COS/BOL/export evidence pack
```

The original supplier invoice line must remain intact.

Example:

```text
Supplier invoice/OCR line:
Zara white top — qty 4 — gross/value £80

Delivery allocation layer:
qty 2 → tracking ref DPD123 → value £40
qty 1 → tracking ref EVRI456 → value £20
qty 1 → unallocated / later parcel → value £20
```

Implementation may store allocation rows by quantity rather than creating one physical database row per unit.

---

## 6. Qty > 1 handling

For user clarity, qty > 1 lines may display as expandable allocation units.

Example collapsed view:

| Invoice line | Qty | Net allocated value |
|---|---:|---:|
| White top | 3 | £270 |

Example expanded view:

| Unit | Tracking ref | Base | Discount | Retailer delivery | Net |
|---|---|---:|---:|---:|---:|
| 1 | DPD123 | £100 | -£10 | £0 | £90 |
| 2 | EVRI456 | £100 | -£10 | £0 | £90 |
| 3 | EVRI456 | £100 | -£10 | £0 | £90 |

Important: this is display/allocation logic only. It must not rewrite the original supplier invoice line.

---

## 7. Retailer delivery and discount apportionment

The existing `order_value_adjustments` policy recognises retailer delivery and retailer discount adjustments as financial finalisation inputs. This addendum adds the required allocation rule.

Locked rule:

```text
Original invoice lines remain intact.
Delivery/discount adjustments are apportioned to allocation units.
Shipment/COS/export values use the adjusted net allocation value, not the unadjusted gross line value.
```

Final contract sentence:

```text
For delivery allocation, shipment batch, sales invoice release, shipping apportionment and COS/export evidence, item values must be based on adjusted net allocation value. Retailer discounts and retailer delivery charges must be apportioned across invoice lines/allocation units before those units can be locked for customer invoice release or export evidence.
```

### 7.1 Discount example

```text
Zara white top — qty 3 — base value £300
Retailer discount — £30
```

Allocation units:

| Unit | Base value | Discount share | Net value |
|---|---:|---:|---:|
| unit 1 | £100 | -£10 | £90 |
| unit 2 | £100 | -£10 | £90 |
| unit 3 | £100 | -£10 | £90 |

If unit 1 ships first and units 2–3 ship later:

- Shipment 1 COS/export value = £90.
- Shipment 2 COS/export value = £180.

The COS must not show £100 for unit 1 if the real adjusted net value is £90.

### 7.2 Retailer delivery example

```text
Item A = £100
Item B = £200
Retailer delivery charge = £15
```

Default apportionment by line value:

- Item A delivery share = £5.
- Item B delivery share = £10.

Each allocation unit should carry:

- goods base value;
- discount share;
- retailer delivery share;
- adjusted net/release value;
- export/COS value basis.

### 7.3 Rounding rule

Rounding differences must be assigned explicitly so that:

```text
sum(all allocation unit net values) = supplier invoice lines/adjustments net total
sum(all apportioned delivery/discount shares) = approved adjustment amount
```

Rounding may be assigned to the largest-value allocation unit or a clearly marked rounding adjustment unit, but it must be auditable.

---

## 8. Fast customer invoicing rule

Stable goods invoicing must not wait for final export evidence.

Goods/customer invoice release may proceed when the released subset is stable enough:

- supplier invoice/OCR line is progressed;
- quantity/value is stable;
- required delivery/tracking allocation is complete or supervisor-accepted;
- shipper receipt/entry into shipper lane exists where required;
- funding control is satisfied;
- the same quantity/value has not already appeared in a non-void customer invoice release;
- there is no contradiction on that released subset.

Do not wait for:

- final COS;
- final BOL;
- POD;
- Ghana delivery;
- final shipper invoice;
- whole parent order closure;
- unrelated child exception resolution.

Final export evidence clearance and whole-order closure remain blocked until export/POD/evidence controls are satisfied.

---

## 9. Shipping charge / shipper invoice rule

The shipper invoice / logistics charge may arrive after goods invoice release.

Shipping charge treatment:

- If known before customer invoice release, it may be included in that release subject to approval.
- If known after goods invoice release, it may create a supplementary shipping/export adjustment.
- It must be linked to the shipment batch or master shipment and apportioned across the shipped package/item/category scope.

Customer/importer invoicing remains per importer. A master container/BOL may include multiple importers, but importer evidence/invoice packs must remain separately traceable.

Operational clarification:

```text
Shipper invoices/receipts are not importer/operator documents. They enter the supervisor/admin document/OCR queue and then the shipping-cost lane, not the operator goods-invoice lane.
```

See companion addendum:

```text
docs/governing-pack/backend/Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md
```

---

## 10. Shipping cost apportionment

Default method:

```text
category-weighted shipped value
```

Basis hierarchy:

1. Exact item/category from supplier invoice/order line.
2. Order category line.
3. Retailer default category profile.
4. Supervisor override with reason.

Illustrative category factors:

- Fashion clothing: 1.0
- Shoes / bags: 1.3–1.5
- Small electronics: 1.8
- Appliances: 3.0
- Bulky / furniture: higher or manual

The allocation basis and any override must be stored and locked once approved.

---

## 11. Shipper receipt and importer shipment batch flow

### 11.1 Shipper package receipt

Shipper confirms package-level receipt/condition:

- received clean;
- received damaged;
- received opened/tampered;
- not received;
- held/query;
- wrong/unclear parcel.

For fashion, default handling may be:

```text
parcel received, contents not counted
```

For appliances or bulky/high-risk goods, stronger unit/model/condition confirmation may be required.

### 11.2 Importer shipment batch

Shipper bulk-selects received packages/tracking refs, grouped by importer/order.

Shipper does not select invoice lines.

The importer shipment batch is the package-level statement that certain received packages left the shipper’s UK lane under a booking/cutoff.

Importer shipment batch fields conceptually include:

- importer;
- shipper;
- booking ref;
- shipment cutoff date/time;
- dispatch date;
- selected tracking refs/packages;
- box/carton count;
- exclusions with reason;
- package/shipment notes.

Importer shipment batch must not be treated as final export evidence.

Do not put the following on the ordinary importer shipment batch header as final evidence fields:

- final COS upload;
- BOL upload;
- master BOL upload;
- final container evidence;
- POD upload;
- zero-rating clearance decision;
- Sage/VAT posting release decision.

If the shipper has early operational hints such as a provisional container/loading note, they may only be captured later as clearly marked provisional notes or on the master-shipment/export-evidence lane. They must not be used as final export evidence until supervisor review accepts them.

The system derives the related item descriptions, quantities, and values from the delivery allocation layer. The shipper’s batch action remains package-level only.

### 11.3 Shipper-visible package contents preview

Shippers should be able to see what is expected inside a package at a practical operations level, but they must not see values.

Allowed shipper-visible contents:

- item description;
- allocated quantity;
- order ref;
- retailer;
- tracking ref/package;
- allocation status, e.g. allocated / partial / unknown / needs operator evidence.

Not allowed in shipper package views:

- supplier cost;
- customer sales value;
- VAT value;
- adjusted net allocation value;
- margin;
- Sage code;
- DVA/card funding or payment data.

The shipper contents preview must be read-only.

Recommended UI placement:

1. `/shipper` package worklist — link next to each tracking ref: `View contents`.
2. `/shipper/package-receipts` — link next to each package before receipt action.
3. `/shipper/shipments/new` — link next to each eligible package before selection.
4. `/shipper/shipments/[shipment_batch_id]` — link in selected packages table.

For high-volume packages, do not show item descriptions inline in worklists. The worklist should show only a compact count/quantity link, and full descriptions should open on a dedicated detail page.

If the operator/supervisor has not allocated contents yet, the shipper should see:

```text
Contents not allocated yet — package can be received, but export evidence/COS review will require operator/supervisor allocation.
```

This supports practical receiving and shipping without forcing the shipper to count every item.

---

## 12. Master shipment and importer shipment batches

When one container/BOL contains multiple importers, use two levels.

### 12.1 Master shipment

Master shipment represents the shared export movement.

Master shipment owns:

- container ref;
- master BOL;
- shipper;
- route;
- dispatch/export movement date;
- vessel/flight/vehicle details where relevant;
- final shipment/export evidence;
- links to one or more importer shipment batches.

### 12.2 Importer shipment batch

Importer shipment batch owns:

- importer;
- selected packages/tracking refs;
- linked orders;
- linked allocation lines;
- linked sales invoice releases;
- importer-specific manifest / COS support pack.

This prevents mixed customer evidence and supports one BOL/container across multiple importer batches.

### 12.3 Bulk master shipment creation

A later master shipment page should allow staff/supervisor, and possibly shipper where role matrices permit, to bulk group importer shipment batches that share the same export movement.

The grouping criteria may include:

- same shipper;
- same dispatch/export date;
- same container/loading reference;
- same route;
- same master BOL.

This is where container ref, master BOL, final export movement documents, and shared shipment evidence belong — not on the initial importer shipment batch form.

---

## 13. Draft COS / export evidence pack rule

Draft COS/export pack is generated from shipment batch truth, not from the full invoice alone.

A sales invoice may contain more items than the current shipment batch. That is acceptable only if the export allocation schedule shows which invoice lines/quantities/values are included in each COS/BOL pack.

Example:

```text
Sales invoice SI-001 has two items.
Shipment batch 1/COS 1 exports item 1 only.
Shipment batch 2/COS 2 exports item 2 only.
```

The invoice does not need to show the shipment batch. The export allocation schedule bridges the invoice to each COS/BOL.

System must prevent the same invoice line/quantity/value from being exported twice.

---

## 14. Supervisor pre-draft COS review

Supervisor checks before draft COS generation:

1. Shipment batch contains only received/eligible packages.
2. Selected packages have delivery allocations to invoice lines/quantities/values.
3. Discounts and retailer delivery charges are fully apportioned to allocation units.
4. Adjusted net values, not gross values, are used for COS/export values.
5. No invoice line/quantity/value is already allocated to another COS beyond available quantity/value.
6. Unknown contents are resolved or supervisor-accepted with reason.
7. Draft COS only shows goods actually in that shipment batch.
8. Full sales invoices are not blindly attached as if wholly exported where only partial invoice lines shipped.
9. The correct importer shipment batch or batches are linked to the correct master shipment where one container/BOL covers multiple importers.

---

## 15. Locking and amendment control

Discount/delivery apportionment and item-to-tracking allocation should lock when any of the following occurs:

- customer sales invoice release is created;
- export evidence pack is generated;
- Sage payload is queued;
- export evidence allocation is marked complete.

Importer shipment batch header details may be corrected while the batch is still a package-level operational batch and before export-evidence review begins.

Once export-evidence review, COS generation, final evidence upload, Sage queueing, or VAT/export lock exists, changes must use supervisor-controlled correction, reversal, supplementary evidence, or adjustment. Do not silently edit historical allocation truth.

---

## 16. Blocking and warning rules

### 16.1 Must block

Block where:

- tracking ref is selected into shipment before shipper receipt;
- tracking ref/package is shipped twice;
- invoice line allocation exceeds progressed quantity;
- invoice line export allocation exceeds available quantity/value;
- same invoice line/value is allocated to multiple COS packs beyond its total quantity/value;
- discount is not fully apportioned before adjusted-value lock;
- retailer delivery charge is not fully apportioned before adjusted-value lock;
- COS value uses gross value where approved discount exists;
- shipment batch selected units have unapportioned delivery/discount adjustments;
- final export evidence is marked complete without required final COS/BOL/POD or approved equivalent;
- final closure is attempted while export evidence, shipper discrepancy, commercial exception, DVA/card financial mismatch, or VAT evidence breach remains unresolved.

### 16.2 Warn but do not block stable goods invoice release

Warn, but do not block stable goods customer invoicing, where:

- final COS is pending;
- BOL is pending;
- POD is pending;
- Ghana delivery is pending;
- shipper invoice is not final;
- export evidence is still on-track/at-risk but not overdue;
- unrelated child exceptions remain open.

---

## 17. Required UI surfaces

### Operator/importer

`/importer/delivery-allocation/[order_id]`

Shows:

- progressed supplier invoice/OCR lines;
- approved retailer delivery/discount adjustments;
- adjusted net allocation values;
- tracking refs/packages;
- allocation status;
- evidence upload;
- assign/split controls.

Actions:

- auto-allocate all lines to the only tracking ref;
- assign all remaining to a tracking ref;
- assign selected lines;
- split by quantity;
- mark unknown / needs evidence;
- use dispatch screenshot as basis;
- submit for supervisor review.

### Supervisor/internal

`/internal/shipping-control`

Central status and action spine for shipment batches, shipper invoice/receipt intake, OCR status, shipping cost apportionment, draft COS/export basis, master shipment grouping, final export evidence and Sage readiness.

`/internal/delivery-allocation/[order_id]`

Actions:

- complete allocation;
- accept/query allocation;
- accept unknown/category estimate with reason;
- lock allocation for invoice/export pack;
- review adjusted net values.

`/internal/export-evidence/draft/[shipment_batch_id]`

Shows:

- selected packages;
- allocated lines/units;
- adjusted net values;
- sales invoices;
- supplier invoices;
- warnings;
- draft COS/export manifest preview.

`/internal/export-evidence/master-shipments` or equivalent

Shows:

- importer shipment batches ready for master shipment grouping;
- shared dispatch/container/BOL movement;
- final COS/BOL/POD evidence upload/review;
- supervisor export evidence clearance controls.

`/internal/shipping-documents/[document_id]` or equivalent

Shows shipper invoice/receipt OCR review, shipment/master-shipment linking, shipping-cost review status and Sage/AP readiness controls. This is not the retailer goods invoice progression page.

### Shipper

`/shipper`

Shows expected/received/outstanding packages by importer/order. Each tracking ref/package should have a read-only `View contents` link showing description and quantity only where allocation exists.

`/shipper/package-receipts`

Package receipt action page. Each package should allow receipt action and read-only contents link. Receipt actions do not lock item allocation, COS, Sage or VAT.

`/shipper/shipments/new`

Bulk importer shipment batch creation by importer/cutoff using received packages/tracking refs.

Must show:

- package/tracking refs;
- order ref;
- retailer;
- read-only contents link: description and quantity only;
- no values;
- no COS/BOL/POD upload;
- no final container evidence.

`/shipper/shipments/[shipment_batch_id]`

Importer shipment batch detail.

Must show:

- booking ref;
- cutoff/dispatch facts;
- box/carton count;
- notes;
- selected packages/tracking refs;
- read-only contents link: description and quantity only;
- tracking evidence links.

May allow header correction while status is still `created` and export-evidence review has not started.

Must not be used for final COS/BOL/POD upload. Final evidence belongs to the master-shipment/export-evidence lane.

`/shipper/shipping-documents/new` or equivalent

Allows shipper to upload shipper invoice/receipt only, linked to shipment batch or master shipment where applicable. It must not perform cost allocation approval, Sage approval or VAT/export clearance.

---

## 18. Regression scenarios

### A. Single tracking ref

One tracking ref + all progressed lines should auto-allocate. COS includes all lines once shipped.

### B. Multiple tracking refs

Zara order with three progressed lines and two tracking refs. Operator allocates line 1/2 to ref A, line 3 to ref B. If shipper ships ref A only, COS shows line 1/2 only.

### C. Quantity split

Line qty 4 split across tracking refs. Original invoice line remains qty 4; allocation layer splits quantities and values.

### D. Discount apportionment

Line qty 3 base £300 with £30 discount. Allocation units carry £90 net each. COS uses £90/£180 if units ship in separate batches.

### E. Retailer delivery apportionment

Retailer delivery charge apportioned across allocation units. Shipment/COS/export values use adjusted net basis as configured.

### F. One invoice, two COS/BOLs

One sales invoice supports two COS/BOL packs only through line/quantity/value allocation. No duplicate export value.

### G. Master shipment with multiple importers

One master BOL links to multiple importer shipment batches. Each importer has separate manifest/evidence and customer invoice trace.

### H. Unknown contents

Unknown package may move operationally but export evidence clearance blocks until supervisor accepts allocation/basis.

### I. Shipper invoice after goods invoice

Goods invoice released first. Shipper invoice later enters supervisor/admin document OCR queue, is linked to shipment batch/master shipment, and drives shipping-cost apportionment/Sage AP/customer recharge readiness.

### J. Shipper contents preview without values

Shipper can see package item description and quantity on a dedicated detail page but cannot see supplier/customer values, VAT, margin, Sage coding, or DVA/payment data.

### K. Shipper invoice not visible to importer/operator

Importer/operator cannot see shipper invoice/receipt document, OCR, cost, apportionment, Sage/AP coding or internal shipping cost controls.

---

## 19. Implementation sequencing

Efficient build sequence:

1. Contract/addendum and live DB inspection.
2. Delivery allocation data model and read model.
3. Operator/supervisor delivery allocation workspace.
4. Shipper package receipt and received-package queue.
5. Shipper importer shipment batch creation using received tracking refs.
6. Shipper contents link: description and quantity only, no values.
7. `/internal/shipping-control` read-only control centre from existing shipment batches/packages/receipt/content data.
8. Shipper invoice/receipt document type and upload route.
9. Shared document/OCR queue filter for shipper invoice/receipt.
10. Supervisor shipper invoice review and shipment/master-shipment linking.
11. Shipping cost apportionment and supplementary customer recharge/Sage readiness.
12. Export evidence draft review and allocation guardrails.
13. Master shipment grouping and final COS/BOL/POD upload/review.
14. Status-control/VAT readiness integration.

Do not jump to final COS/POD screens before allocation, receipt truth, shipment batch truth, shipping-control visibility and shipper invoice/document lane exist.

---

## 20. Final locked sentence

```text
Tracking ref is the package. Operator/supervisor allocates progressed invoice lines and adjusted net allocation values to packages. Shipper may view package contents as description and quantity only, then bulk-selects received packages into importer shipment batches. Master shipment/BOL/container/final COS/POD evidence is a later export-evidence layer, not the shipment batch header. Shipper invoices/receipts enter the supervisor/admin document/OCR queue and shipping-cost lane, not importer/operator workflows. Supervisor reviews the joined item/package/shipment/document truth through the shipping control centre before COS, Sage and VAT readiness. Goods invoicing remains progressive and is not held behind final COS/BOL/POD; export evidence clearance and final closure are held behind those documents.
```
