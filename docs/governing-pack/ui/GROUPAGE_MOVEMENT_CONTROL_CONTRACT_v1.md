# Groupage Movement Control — Build Contract v1

## 1. Purpose

Build a tenant-safe **Groupage Movement** layer that allows a shipper to group multiple existing shipment batches under one shared container / MBOL / export movement, generate one combined export evidence pack, upload one signed export pack, and upload POD / delivery evidence by selecting the real booking references covered.

The Groupage Movement layer must not replace the current shipment batch, order, customer invoice, shipper AP, export evidence, POD, credit, loyalty, VAT, DVA/card reconciliation, or accounting logic.

It must operate as a control layer above existing shipment batches.

---

## 2. Related governing contracts / continuity references

This contract is an extension/addendum to the existing governing pack. It must be read together with the following contracts and locked controls:

### 2.1 Locked governing pack

- `docs/governing-pack/CURRENT_LOCKED_PACK.md`

Continuity rule:

- This contract must not override the locked pack.
- Any conflict must be resolved in favour of the current locked pack unless the locked pack is explicitly amended later.

### 2.2 Multi-tenant UI wiring

- `docs/governing-pack/ui/Multi_Tenant_UI_Wiring_Control_Document_v1.md`

Continuity rule:

- Groupage Movement must be tenant-safe from day one.
- Where `tenant_id` is not fully enforced yet, the design must still carry nullable `tenant_id` and enforce the strongest current scoping: `shipper_id`, importer relationship, destination country/jurisdiction and active/non-voided batch status.
- Once the wider tenant model is finalised, `tenant_id` should be tightened and enforced in the relevant RPCs and read models.

### 2.3 Shipping control centre / export evidence flow

- `docs/governing-pack/backend/Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md`
- `docs/governing-pack/backend/Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md`

Continuity rule:

- Groupage Movement must reuse the existing shipment batch, export evidence and POD lanes.
- It must not create a parallel export evidence status engine.
- Groupage actions must write into the existing batch-level evidence/completion tables so existing pages and statuses continue to work.

### 2.4 Shipping control / customer billing alignment

- `docs/governing-pack/backend/Shipping_Control_Customer_Billing_Status_Alignment_Addendum_v1.md`
- `docs/governing-pack/ui/FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md`

Continuity rule:

- Groupage Movement must not change customer final invoice release logic.
- It must not change final sale value, final balance due, or customer billing controls.
- It may only provide export evidence and POD facts to the existing batch/order status engine.

### 2.5 Platform operational status and audience status contracts

- `docs/governing-pack/ui/PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`
- `docs/governing-pack/ui/CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`

Continuity rule:

- Groupage Movement status is aggregate/display-only.
- Canonical status remains order/batch driven.
- Groupage actions must update current canonical status only indirectly by writing the existing batch-level evidence rows expected by the current status engine.

### 2.6 Sage readiness / command centre / loyalty reward contracts

- `docs/governing-pack/ui/SAGE_READINESS_COMMAND_CENTRE_CONTRACT_v1.md`
- `docs/governing-pack/ui/COMMAND_CENTRES_AND_SAGE_RESOLVER_CONTRACT_v3.md`
- `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_AND_SAGE_POSTING_ADDENDUM_v1.md`

Continuity rule:

- Groupage Movement must not post to Sage/accounting.
- It must not change shipper AP, customer sales, credit, or loyalty reward posting logic.
- Loyalty/credit readiness remains dependent on the existing clean completion path, not on the groupage movement row itself.

### 2.7 VAT return / export evidence timing controls

- `docs/governing-pack/ui/VAT_RETURN_WORKBENCH_POINTER.md`
- `docs/governing-pack/ui/VAT_RETURN_WORKBENCH_DIRECT_SAGE_POSTINGS_ADDENDUM_v1.md`
- `docs/governing-pack/ui/VAT_RETURN_WORKBENCH_PARTIAL_PREPAYMENT_ADDENDUM_v1.md`

Continuity rule:

- Groupage Movement must not create VAT return lines directly.
- It must preserve the existing export evidence timing chain by attaching accepted export evidence/POD to existing shipment batches and orders.

---

## 3. Naming

Use the product name:

```text
Groupage Movement
```

Do not use “Master COS” as the main feature name, because the feature controls more than a certificate of shipment. It controls the shared movement, export pack, signed evidence, POD linkage, and grouped status visibility.

Allowed UI labels:

- Groupage Movements
- Groupage Movement Control
- Groupage Export Pack
- Signed Export Pack
- POD / Delivery Evidence
- Included Booking References

Avoid:

- Master COS as the main feature name
- Fake suffix booking references
- Any wording that implies the groupage record replaces original batch booking references

---

## 4. Core design rule

The source of truth remains:

```text
Order → Shipment Batch → Batch Evidence / POD → Existing Status Logic
```

The Groupage Movement is only a shared movement/control layer.

The Groupage Movement must write back into the existing batch-level tables so that existing canonical statuses continue to update naturally across customer, importer, shipper, supervisor, and internal pages.

Groupage Movement status is aggregate/display-only. It must not become the canonical order or batch status.

---

## 5. Multi-tenant rule

A Groupage Movement must be scoped to one tenant, one shipper branch, and one destination jurisdiction.

Grouping must not cross:

- tenant;
- shipper;
- destination country/jurisdiction;
- currency branch, where applicable.

If `tenant_id` is not fully live yet, the tables must still include `tenant_id` as nullable, and current enforcement must use the strongest existing scope available:

- `shipper_id`;
- importer relationship;
- destination country / `country_id` where available;
- active/non-voided shipment batch status.

Later, when the tenant model is finalised, `tenant_id` should be tightened to `NOT NULL` and enforced in all groupage RPCs.

---

## 6. Existing objects to preserve

Do not change the meaning of:

- `shipper_shipment_batches`;
- `shipper_shipment_batch_packages`;
- `shipper_create_shipment_batch_v1`;
- `shipper_update_shipment_batch_header_v1`;
- customer sales invoice logic;
- shipper AP / shipping apportionment logic;
- DVA/card reconciliation;
- credit ledger;
- loyalty reward logic;
- canonical order status logic.

The real batch `booking_ref` remains the shipper quote/booking reference.

Do not create artificial references such as `BOOKING-A`, `BOOKING-B`, etc.

---

## 7. Existing repo baseline this contract builds on

The current repo already supports the correct batch-level architecture:

- final shipment/COS facts live outside `shipper_shipment_batches`, in the export evidence lane;
- batch export evidence completion fields already store MBOL/BOL, container, seal, vessel, ports, place of delivery, export date, package confirmation, authorised name, and signature/stamp confirmation;
- batch export pack preview already returns booking ref, EEP ref, shipper name, customer/importer name, movement fields, invoice refs, item descriptions, quantity, unit value, total value, and destination;
- final export evidence and POD are already stored per `shipment_batch_id` in `shipper_final_export_evidence_documents`;
- current status logic already separates export evidence from POD through `document_kind`.

This contract must reuse those mechanics rather than replacing them.

---

## 8. New database objects

### 8.1 `shipper_groupage_movements`

Purpose: stores one shared groupage/container/export movement.

Fields:

```text
id
tenant_id
shipper_id
destination_country_id or country_id
currency_code, if available/relevant
groupage_movement_ref
status
mbl_bol_sea_waybill_ref
container_number
seal_number
vessel_voyage
port_of_loading
port_of_discharge
place_of_delivery
export_shipment_date
weight_text
exporter_name_snapshot
exporter_address_snapshot
exporter_vat_number_snapshot
shipper_name_snapshot
shipper_address_snapshot
movement_consignee_name_snapshot
movement_consignee_address_snapshot
notify_party_name_snapshot
notify_party_address_snapshot
authorised_name
signature_stamp_confirmation_yn
created_by_shipper_user_id
created_at
updated_at
```

Important rules:

- Use snapshots so the export pack remains stable even if tenant, shipper, or importer data changes later.
- `weight_text` is used because weight may not be held in the current operational flow. Do not fabricate weight.

### 8.2 `shipper_groupage_movement_batches`

Purpose: links one Groupage Movement to existing shipment batches.

Fields:

```text
id
tenant_id
groupage_movement_id
shipment_batch_id
shipper_id
importer_id_snapshot
importer_name_snapshot
booking_ref_snapshot
final_recipient_name_snapshot
final_recipient_address_snapshot
active
added_at
```

Rules:

- `shipment_batch_id` must reference an existing batch.
- `booking_ref_snapshot` must preserve the real booking reference.
- A shipment batch must not be in more than one active Groupage Movement.
- Do not overwrite the batch `booking_ref`.

### 8.3 `shipper_groupage_movement_documents`

Purpose: stores files uploaded at groupage level for audit/navigation.

Fields:

```text
id
tenant_id
groupage_movement_id
document_kind
document_ref
file_url
notes
created_by_shipper_user_id
created_at
```

Important:

This table is not enough by itself. The signed export pack and POD must still be written into the existing per-batch evidence table to trigger current statuses.

### 8.4 `tenant_export_evidence_profiles` or `shipper_export_evidence_profiles`

Purpose: replaces dummy COS/export-pack placeholders with real tenant/shipper/export evidence profile data.

Fields:

```text
id
tenant_id
shipper_id or country_id scope
profile_name
exporter_name
exporter_address
exporter_vat_number
default_movement_consignee_name
default_movement_consignee_address
default_notify_party_name
default_notify_party_address
active
created_at
updated_at
```

Use this profile to populate:

- exporter/supplier details;
- default movement consignee / receiving hub;
- notify party where relevant.

### 8.5 `importer_export_delivery_profiles`

Purpose: stores final recipient/importer consignee details for export schedules.

If current importer onboarding does not already hold final recipient/consignee address fields, add this table.

Fields:

```text
id
tenant_id
importer_id
country_id
final_recipient_name
final_recipient_address_line_1
final_recipient_address_line_2
final_recipient_city
final_recipient_region
final_recipient_country
final_recipient_phone
final_recipient_email
active
created_at
updated_at
```

When a batch is added to a Groupage Movement, snapshot these details into `shipper_groupage_movement_batches`.

---

## 9. RPCs / server actions

### 9.1 `shipper_groupage_candidate_batches_v1`

Returns eligible batches for grouping.

Eligibility:

- same tenant, where `tenant_id` exists;
- same shipper;
- same destination jurisdiction/country;
- not voided;
- has real `booking_ref`;
- not already in another active Groupage Movement;
- has packages;
- ideally has content allocated / export pack preview rows.

Returned fields:

```text
shipment_batch_id
booking_ref
importer_id
importer_name
final_recipient_name
final_recipient_address
box_count
package_count
item_qty
invoice_value
export_evidence_status
pod_status
existing_groupage_movement_id, if any
```

### 9.2 `shipper_create_groupage_movement_v1`

Creates a Groupage Movement.

Inputs:

- selected `shipment_batch_ids`;
- `groupage_movement_ref`;
- movement facts where already known;
- export evidence profile id, if used.

Validations:

- all selected batches belong to same shipper;
- all selected batches belong to same tenant when `tenant_id` is available;
- all selected batches belong to same destination jurisdiction/country;
- none are voided;
- none are already in another active Groupage Movement;
- all have real `booking_ref`.

Action:

- create `shipper_groupage_movements` row;
- create `shipper_groupage_movement_batches` rows;
- snapshot booking refs, importer names, final recipient details.

### 9.3 `shipper_save_groupage_movement_facts_v1`

Saves shared movement details.

Inputs:

- `groupage_movement_id`;
- MBOL / sea waybill;
- container number;
- seal number;
- vessel / voyage;
- port of loading;
- port of discharge;
- place of delivery;
- export shipment date;
- authorised name;
- signature/stamp confirmation;
- `weight_text`;
- consignee / notify party overrides, if needed.

Action:

- update `shipper_groupage_movements`;
- apply those shared movement facts into existing `shipper_export_evidence_completion_fields` rows for every active included `shipment_batch_id`.

This is critical because existing final evidence upload depends on batch-level completion fields being ready.

### 9.4 `shipper_groupage_export_pack_preview_v1`

Returns the combined groupage export pack preview.

Action:

- load groupage movement header;
- load included batches;
- call or reuse the existing batch export pack preview logic per `shipment_batch_id`;
- combine results into one movement-level view.

Returned sections:

- movement header;
- exporter details;
- shipper details;
- movement consignee / receiving hub;
- notify party;
- transport details;
- included real booking refs;
- per-booking/importer section;
- invoice refs;
- item descriptions;
- quantities;
- values;
- packages;
- final recipient/importer destination;
- blockers.

### 9.5 `shipper_submit_groupage_signed_export_pack_v1`

Uploads one signed/stamped groupage export pack.

Inputs:

- `groupage_movement_id`;
- `file_url`;
- `document_ref`;
- notes.

Action:

- insert groupage-level document row;
- for every active included batch, insert normal batch-level evidence row into `shipper_final_export_evidence_documents`:
  - `shipment_batch_id = included batch`;
  - `document_kind = completed_cos`;
  - `document_ref = groupage_movement_ref`;
  - `file_url = same signed groupage pack`;
  - `review_status = submitted_for_review`.

Optional:

- also insert `final_eep_packing_list` pointing to the same file if the UI needs a separate EEP row. Do not add a new `document_kind` unless necessary.

### 9.6 `shipper_submit_groupage_pod_v1`

Uploads POD / delivery evidence for selected real booking refs.

Inputs:

- `groupage_movement_id`;
- selected `shipment_batch_ids`;
- POD `file_url`;
- `document_ref`;
- notes.

Validation:

- selected batches must belong to the groupage movement;
- selected batches must belong to the same shipper/tenant scope;
- POD must not be applied to batches not selected.

Action:

- insert groupage-level document row, optional;
- insert normal batch-level evidence rows into `shipper_final_export_evidence_documents`:
  - `shipment_batch_id = selected batch`;
  - `document_kind = pod_delivery_evidence`;
  - `document_ref = groupage movement ref or POD ref`;
  - `file_url = same POD file`;
  - `review_status = submitted_for_review`.

### 9.7 `internal_shipping_control_v2`

Additive supervisor read model.

Do not break `internal_shipping_control_v1`.

`internal_shipping_control_v2` should wrap existing shipping control data and add:

```text
groupage_movement_id
groupage_movement_ref
groupage_status
groupage_export_pack_status
groupage_pod_status
grouped_yn
groupage_batch_count
groupage_completed_batch_count
```

Use this for supervisor filters and columns.

---

## 10. Shipper UI

### 10.1 New pages

Add:

```text
/shipper/groupage-movements
/shipper/groupage-movements/[movement_id]
```

### 10.2 Groupage movement list page

Cards / sections:

- Create groupage movement;
- Draft movements;
- Movements awaiting signed export pack;
- Movements with POD pending;
- Completed movements.

### 10.3 Groupage movement detail page

Sections:

1. Movement facts;
2. Included booking refs;
3. Export pack preview / download;
4. Signed export pack upload;
5. POD / delivery evidence;
6. Batch status summary.

Each included booking row must show:

- booking ref;
- importer;
- final recipient / destination;
- boxes / packages;
- quantity;
- value;
- export evidence status;
- POD status;
- `Open batch →`.

### 10.4 Existing batch page integration

On the existing shipper batch page, if grouped, show:

```text
This booking is included in Groupage Movement [ref].
Open groupage movement →
```

This is required for seamless navigation both ways.

---

## 11. Supervisor UI

The internal shipping control centre must show groupage information.

Add to the shipment batch worklist:

- Groupage column;
- Groupage status badge;
- Open groupage movement action.

Filters:

- All;
- Grouped;
- Not grouped;
- Groupage facts incomplete;
- Groupage export pack submitted;
- Groupage export pack accepted;
- Groupage POD pending;
- Groupage complete.

Add optional focused page:

```text
/internal/shipping-control/groupage-movements
```

Purpose:

- supervisor overview of groupage movements across importers;
- grouped/not grouped visibility;
- signed export pack review visibility;
- POD review visibility;
- drill-down to batch detail and final evidence/POD review pages.

---

## 12. Export pack generation

The groupage export pack must reuse the existing batch EEP/COS template and data logic.

Pack structure:

1. Groupage movement cover page;
2. Movement header;
3. Exporter profile details;
4. Shipper details;
5. Movement consignee / receiving hub;
6. Notify party, if any;
7. MBOL/container/seal/vessel/ports/date;
8. Weight text, if no weight exists;
9. Included real booking refs;
10. Per-booking/importer section;
11. Final recipient/importer details;
12. Sales invoice refs;
13. EEP/invoice line rows;
14. Quantity and value totals;
15. Signature/stamp page.

Do not use dummy values such as:

- `Goodcashback / tenant exporter`;
- `Ghana jurisdiction hub / tenant destination hub`;
- `Assorted retail goods` as the only description.

If a field is missing, show it as a blocker before final download/upload rather than silently producing weak evidence.

---

## 13. Status rules

Groupage status is aggregate only.

Example groupage statuses:

- draft;
- movement_facts_incomplete;
- movement_facts_ready;
- signed_export_pack_submitted;
- signed_export_pack_part_accepted;
- signed_export_pack_fully_accepted;
- pod_part_submitted;
- pod_part_accepted;
- pod_fully_accepted;
- complete.

Canonical statuses remain batch/order based.

Existing pages update because groupage actions write into the existing batch-level tables.

---

## 14. No-weight rule

Do not invent weight.

If no weight is available, use:

```text
Not separately recorded by issuing consolidator
```

or the shipper-entered wording.

If carrier/manifest weight is available later, use that.

The pack must clearly show packages, quantities, values, invoice refs, booking refs, route, and container/MBOL evidence.

---

## 15. Blockers

Do not allow final signed export pack upload if:

- movement facts are incomplete;
- no batches are selected;
- a selected batch is voided;
- a selected batch has no `booking_ref`;
- a selected batch belongs to a different shipper;
- a selected batch belongs to a different tenant once `tenant_id` is active;
- a selected batch belongs to a different destination jurisdiction;
- a selected batch is already in another active groupage movement;
- existing batch export pack preview has no rows;
- required exporter/consignee/final recipient profile data is missing.

Do not allow POD upload if:

- no POD file is uploaded;
- no booking refs are selected;
- selected booking refs are not part of the movement;
- selected batches are voided;
- selected batches are outside the current shipper/tenant scope.

---

## 16. Definition of done

The build is complete only when:

1. Shipper can create a Groupage Movement from existing real batch booking refs.
2. Shipper can enter movement facts once.
3. Movement facts are applied to existing batch completion fields.
4. Shipper can download one combined groupage export pack using existing batch EEP rows.
5. Exporter, shipper, movement consignee and final recipient details come from database-backed profiles/snapshots.
6. Shipper can upload one signed export pack.
7. The upload creates normal batch-level final evidence rows for every included batch.
8. Shipper can upload POD and choose which booking refs it covers.
9. The POD creates normal batch-level POD rows only for selected batches.
10. Existing customer/importer/shipper/supervisor/internal statuses update without new canonical status logic.
11. Existing batch pages link to the groupage movement.
12. Groupage movement pages link back to individual batches.
13. Supervisor shipping control shows grouped/not grouped state.
14. Supervisor can filter grouped shipments across importers.
15. No customer invoice, shipper AP, DVA/card reconciliation, VAT, credit ledger or loyalty logic is changed.
16. Multi-tenant columns/scope are present and ready to tighten when the wider tenant model is finalised.

---

## 17. Build sequencing

Recommended order:

1. Add database sidecar tables and export/final-recipient profile tables.
2. Add candidate batch and create movement RPCs.
3. Add save movement facts RPC that applies facts into existing batch completion fields.
4. Add groupage export pack preview/download by reusing current batch export pack preview.
5. Add signed export pack upload action that writes normal per-batch evidence rows.
6. Add POD upload action with selected booking refs only.
7. Add shipper groupage movement list/detail UI.
8. Add existing batch-page groupage banner and cross-link.
9. Add `internal_shipping_control_v2` and supervisor grouped/not grouped filters.
10. Run one end-to-end test with multiple importers under one shipper movement and confirm all existing statuses update from batch-level evidence rows.
