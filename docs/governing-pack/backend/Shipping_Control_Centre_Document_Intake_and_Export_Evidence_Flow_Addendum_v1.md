# Shipping Control Centre, Document Intake & Export Evidence Flow Addendum v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing backend/control and UI-flow addendum  
**Purpose:** Lock the efficient but robust shipping-control model after the shipper physical-truth build, so shipper invoices, OCR, master shipment grouping, export evidence and Sage/VAT readiness do not drift into one all-purpose page.

---

## 1. Governing effect

This addendum supplements and clarifies:

1. `docs/governing-pack/backend/Delivery_Allocation_Export_Evidence_and_Adjustment_Apportionment_Addendum_v1.md`
2. `docs/governing-pack/backend/VAT_Timing_and_Export_Evidence_Addendum_v1.md`
3. `docs/governing-pack/backend/Day6_8_Accounting_Release_and_VAT_Reporting_Clarification_Addendum_v1.md`
4. `docs/governing-pack/backend/closure_v2_functions_final_day6_8_clarified.sql`
5. `docs/governing-pack/ui/STATUS_SPINE_CONTROL_MODEL_v1.md`
6. `docs/governing-pack/role-matrices/shipper_role_stage_matrix_v5.md`
7. `docs/governing-pack/role-matrices/supervisor_role_stage_matrix_v7.md`
8. `docs/governing-pack/role-matrices/admin_role_matrix_v6.md`
9. `docs/governing-pack/ui/ORDER_OPERATIONS_MVP_CONTRACT.md`
10. `docs/governing-pack/ui/EXCEPTION_BRANCHING_MVP_CONTRACT.md`

If any earlier wording implies that shipper invoices, COS/BOL/POD, master BOL, container evidence, package receipt and shipment batch editing should all happen on the ordinary shipper shipment batch page, this addendum overrides that reading.

---

## 2. Final locked architecture

Use this structure:

```text
One supervisor shipping control centre
+ one shared document/OCR queue
+ separate processing lanes behind it
```

The system must not become a scattered set of unrelated pages, and it must not become one monster page that mixes shipping, COS, Sage, VAT, OCR, package receipt and cost apportionment.

---

## 3. Role split

### 3.1 Shipper

Shipper can perform operational logistics actions only:

- confirm package receipt / damage / hold / not received;
- view package contents as description + quantity only;
- create importer shipment batches from received packages/tracking refs;
- upload shipping invoice/receipt where the invoice is sent by the shipper;
- upload final export documents later where the role matrix permits.

Shipper must not:

- see supplier values, customer values, VAT, margin, Sage coding, DVA/card/payment data or adjusted net allocation values;
- allocate shipping costs;
- approve OCR;
- approve COS/export evidence;
- approve Sage readiness;
- perform VAT/export clearance;
- assign invoice lines to tracking refs.

### 3.2 Supervisor/admin

Supervisor/admin owns controlled financial and export-evidence review:

- document/OCR review for shipper invoices/receipts;
- linking shipper invoice/receipt to importer shipment batch or master shipment;
- shipping cost apportionment and override approval;
- pre-draft COS basis review;
- master shipment grouping;
- final COS/BOL/POD/container evidence review;
- Sage/AP/customer recharge readiness;
- VAT/export evidence clearance status.

---

## 4. Document categories

The platform should use one shared document intake/OCR queue pattern, with document type driving the downstream processing lane.

Document types:

```text
retailer_goods_invoice
retailer_credit_note_or_refund_document
shipper_invoice_or_shipping_receipt
export_evidence_document
```

One queue may show all document types, but each type must route to the correct review workflow.

---

## 5. Shared document/OCR queue rule

Reuse the existing invoice/OCR queue pattern where possible.

The queue may be `/internal/invoice-review` or a renamed broader internal document queue later, but the contract is:

```text
same queue pattern
same OCR/status/review language
same filtering pattern
different downstream lane by document_type
```

Required filters:

- document type;
- shipper;
- importer;
- shipment batch;
- master shipment;
- OCR status;
- review status;
- needs matching;
- ready for apportionment;
- ready for Sage/AP;
- blocked.

Do not create a completely separate OCR experience for shipper invoices unless the existing queue architecture cannot support it.

---

## 6. Shipper invoice / shipping receipt lane

### 6.1 Purpose

Shipper invoice / shipping receipt answers:

```text
What shipping cost was charged?
Which shipment batch or master shipment does it relate to?
How should that cost be apportioned?
Is it ready for Sage/AP and customer recharge/supplementary billing?
```

It does not answer:

```text
What physically exported?
What proves export for zero-rating?
```

Those belong to the export-evidence lane.

### 6.2 Upload ownership

Shipper invoice/receipt should never go to importer/operator.

Allowed upload routes:

1. Shipper uploads the invoice/receipt against a shipment batch or master shipment.
2. Supervisor/admin uploads the invoice/receipt if received outside the platform.

Importer/operator must not see or upload shipper invoice/receipt documents.

### 6.3 Link target

A shipper invoice/receipt must link to either:

- an importer shipment batch, where the charge is for one importer/batch; or
- a master shipment, where one invoice covers several importers, container movement, or master BOL movement.

If the invoice covers several importer shipment batches, the document should link to the master shipment or a controlled multi-batch shipping-charge group, not be duplicated against each batch.

### 6.4 OCR/review

OCR should extract, where available:

- shipper/supplier name;
- invoice/receipt reference;
- invoice date;
- currency;
- total amount;
- line descriptions;
- line amounts;
- tax/VAT indicators where relevant;
- shipment references / booking refs / container/BOL text if present.

Supervisor/admin reviews OCR and confirms the matched shipment context before apportionment.

### 6.5 Sage/AP readiness

A shipper invoice/receipt is not Sage/AP ready until:

- OCR/manual header is reviewed;
- document is linked to shipment batch or master shipment;
- cost allocation/apportionment basis is approved;
- required coding is complete;
- duplicate/reuse checks pass;
- supervisor/admin approves current.

Do not send shipper OCR directly to Sage.

---

## 7. Export evidence lane

Export evidence answers:

```text
What physically exported?
Which packages/items/values were in the shipment?
What COS/BOL/POD/container/master shipment documents prove export?
Can the export evidence support zero-rating clearance?
```

Export evidence documents include:

- draft COS/export schedule generated by platform;
- final COS/certificate of shipment;
- BOL/master BOL;
- container evidence;
- route/export movement evidence;
- POD / destination delivery evidence;
- supporting export pack documents.

These documents belong to the master-shipment/export-evidence lane, not the ordinary importer shipment batch header.

---

## 8. Shipment levels

### 8.1 Importer shipment batch

Importer shipment batch owns package movement for one importer:

- booking ref;
- shipment cut-off;
- dispatch date/time;
- box/carton count;
- selected packages/tracking refs;
- package/shipment notes.

It must not be treated as final export evidence.

### 8.2 Master shipment

Master shipment owns the shared export movement:

- container ref;
- master BOL;
- route;
- shared dispatch/export movement date;
- linked importer shipment batches;
- final export movement documents;
- final evidence review status.

If a container or master BOL covers multiple importers, use master shipment, not repeated importer-batch-level BOL/COS evidence.

### 8.3 Shipper invoice target selection

Shipper invoice should be linked according to actual commercial charging:

- one importer / one batch → importer shipment batch;
- several batches / one container / one shared charge → master shipment or multi-batch shipping-charge group.

---

## 9. Supervisor shipping control centre

Create a central supervisor page:

```text
/internal/shipping-control
```

This is the spine for shipping-stage visibility.

It should show rows at importer shipment batch level, with master shipment grouping visible where applicable.

Required columns or cards:

- shipment batch / booking ref;
- shipper;
- importer;
- dispatch date;
- package count;
- tracking refs/packages;
- item quantity summary;
- shipper receipt status;
- shipper invoice/receipt status;
- OCR status;
- shipping cost apportionment status;
- draft COS/export basis status;
- master shipment status;
- final COS/BOL/POD/export evidence status;
- Sage/AP/customer recharge readiness status;
- blockers/warnings.

Required filters:

- importer;
- shipper;
- dispatch date;
- booking ref;
- shipment status;
- missing shipper invoice;
- invoice OCR pending;
- needs shipping-cost apportionment;
- ready for draft COS review;
- missing final COS/BOL/POD;
- linked to master shipment;
- not linked to master shipment;
- ready for Sage/AP;
- blocked.

Required actions should drill down, not expand everything inline:

- view packages/items;
- review shipper invoice;
- link/upload shipper invoice;
- review draft COS basis;
- create/link master shipment;
- upload/review final export evidence;
- review shipping apportionment;
- review Sage readiness.

Do not put all subworkflows directly into the control-centre table.

---

## 10. Efficient UI principle

The page model is:

```text
Control centre = summary and next actions.
Detail page = review specific work item.
Queue = document intake/OCR status and filters.
```

Do not use large inline expandable detail tables in high-volume worklists. For 30+ items/packages, use links to dedicated detail pages.

Examples:

- package worklist row → `View contents` link;
- shipment control row → `View shipment detail` link;
- document queue row → `Review OCR` link;
- export evidence row → `Review draft COS basis` link.

---

## 11. Correct end-to-end flow

### Stage 1 — Package truth

```text
Operator submits tracking refs/packages.
Operator/supervisor allocates progressed invoice lines to packages.
Shipper receives packages.
Shipper creates importer shipment batch from received packages.
```

### Stage 2 — Supervisor shipping control visibility

```text
/internal/shipping-control shows shipment batches, packages, contents summary, receipt status and blockers.
```

### Stage 3 — Shipper invoice/receipt intake

```text
Shipper or supervisor uploads shipper invoice/receipt.
Document enters shared document/OCR queue with document_type = shipper_invoice_or_shipping_receipt.
OCR extracts header/line data.
Supervisor reviews OCR and links document to shipment batch or master shipment.
```

### Stage 4 — Shipping cost review

```text
Supervisor approves shipping-cost basis and apportionment.
Shipper invoice becomes ready for Sage/AP only after coding and approval.
Customer recharge/supplementary billing uses approved apportionment where required.
```

### Stage 5 — Draft COS/export basis review

```text
Supervisor reviews joined truth:
package → item allocation → adjusted values → shipment batch → sales invoice release.
```

### Stage 6 — Master shipment grouping

```text
Supervisor/admin groups importer shipment batches into a master shipment where shared container/BOL/export movement exists.
```

### Stage 7 — Final export evidence

```text
Shipper or supervisor uploads final COS/BOL/master BOL/container/POD documents in export evidence lane.
Supervisor clears or queries export evidence.
```

### Stage 8 — Sage/VAT readiness

```text
Sage/AP/customer billing readiness uses approved shipper invoice/cost allocation.
VAT/export clearance uses approved export evidence.
Do not merge the two approvals.
```

---

## 12. What blocks what

### 12.1 Shipper invoice/receipt blocks

Blocks shipping-cost Sage/AP readiness where:

- shipper invoice/receipt missing where required;
- OCR/review incomplete;
- document not linked to shipment batch/master shipment;
- cost allocation/apportionment not approved;
- coding incomplete;
- duplicate invoice risk unresolved.

Does not block stable goods invoice release merely because the final shipper invoice has not arrived.

### 12.2 Export evidence blocks

Blocks export evidence clearance/final closure where:

- draft COS basis not reviewed;
- item/package/shipment truth inconsistent;
- master shipment missing where shared container/BOL is required;
- final COS/BOL/POD/container evidence missing or mismatched;
- duplicate export allocation risk exists;
- zero-rating deadline breach unresolved.

Does not automatically block initial stable goods invoice release if the evidence timer is still on track.

### 12.3 Master shipment blocks

Blocks final export evidence clearance where:

- importer batches clearly share one container/BOL movement but no master shipment grouping exists;
- final master BOL/container evidence cannot be tied to importer batches;
- batches are linked to the wrong master shipment.

---

## 13. Required pages and lanes

### 13.1 Shipper pages

`/shipper`

- package worklist;
- receipt status;
- contents link only, not large inline item tables;
- no values.

`/shipper/package-receipts`

- package receipt action;
- contents link only;
- no values.

`/shipper/shipments/new`

- select received packages into importer shipment batch;
- booking/cutoff/dispatch/box count/notes only;
- no COS/BOL/container/POD fields.

`/shipper/shipments/[shipment_batch_id]`

- shipment batch detail;
- selected packages/tracking refs;
- contents link only;
- editable booking/dispatch facts until export review starts;
- no final export document upload.

`/shipper/shipping-documents/new` or equivalent

- upload shipper invoice/receipt only;
- choose shipment batch or master shipment where available;
- no cost allocation approval;
- no Sage approval.

### 13.2 Internal supervisor pages

`/internal/shipping-control`

- central status and action spine for shipment batches, shipping docs, export evidence and Sage readiness.

`/internal/invoice-review` or broader `/internal/document-review`

- shared document/OCR queue with document type filters.

`/internal/shipping-documents/[document_id]`

- supervisor review of shipper invoice/receipt OCR;
- match/link to shipment batch or master shipment;
- approve for apportionment/coding.

`/internal/shipping-apportionment/[shipping_document_id]`

- apportion shipping cost across selected shipment scope;
- default category-weighted basis;
- supervisor override with reason.

`/internal/export-evidence/draft/[shipment_batch_id]`

- pre-draft COS/export basis review.

`/internal/export-evidence/master-shipments`

- group importer shipment batches under master shipment/container/BOL/export movement.

`/internal/export-evidence/master-shipments/[master_shipment_id]`

- final COS/BOL/POD/container evidence upload/review and clearance controls.

---

## 14. Data model guidance

Prefer additive objects and wrappers. Do not mutate existing shipment batch tables casually.

Likely conceptual objects:

### `shipping_documents`

- id;
- document_type = shipper_invoice_or_shipping_receipt;
- shipper_id;
- importer_id nullable;
- shipment_batch_id nullable;
- master_shipment_id nullable;
- uploaded_by_shipper_user_id nullable;
- uploaded_by_staff_id nullable;
- file_url;
- invoice_ref;
- invoice_date;
- currency;
- total_amount;
- ocr_status;
- review_status;
- linked_status;
- created_at.

### `shipping_document_lines`

- shipping_document_id;
- line_description;
- qty nullable;
- amount;
- confidence/source;
- review status.

### `shipping_cost_allocations`

- shipping_document_id;
- shipment_batch_id or master_shipment_id;
- allocation_method;
- basis snapshot;
- allocated amount;
- override reason;
- approved_by_staff_id;
- approved_at;
- status.

### `master_shipments`

- shipper_id;
- route;
- dispatch/export movement date;
- container_ref;
- master_bol_ref;
- status;
- evidence status;
- created_at.

### `master_shipment_batches`

- master_shipment_id;
- shipment_batch_id;
- active;
- linked_by;
- linked_at.

Actual names may differ after live DB inspection. Use live schema before coding.

---

## 15. Validation rules

System must prevent:

- shipper invoice/receipt being visible to importer/operator;
- shipper invoice OCR being processed as retailer goods invoice progression;
- final export docs being uploaded to ordinary importer shipment batch header;
- shipping cost allocation without reviewed OCR/manual header;
- Sage/AP readiness without approved shipping document and coding;
- one shipping invoice being duplicated against multiple batches without controlled master shipment/multi-batch allocation;
- master BOL/container evidence being repeated inconsistently across importer batches;
- export evidence clearance where master shipment grouping is required but missing;
- high-volume contents/items being dumped inline in worklist tables.

---

## 16. Implementation sequence

Efficient build order from current state:

1. Lock this contract/addendum.
2. Build `/internal/shipping-control` read-only control centre from existing shipment batches/packages/receipt/content data.
3. Add shipper invoice/receipt document type and upload route.
4. Add shared queue filter for shipper invoice/receipt.
5. Add supervisor shipper invoice review page and shipment/master-shipment linking.
6. Add shipping cost apportionment after reviewed shipper invoice.
7. Add pre-draft COS/export basis review.
8. Add master shipment grouping.
9. Add final COS/BOL/POD/container evidence upload/review.
10. Wire Sage/AP/customer recharge/VAT readiness only after the relevant approvals exist.

Do not jump directly to COS/BOL upload or Sage readiness before the control centre and shipper invoice/document lane exist.

---

## 17. Regression scenarios

### A. Shipper invoice for one importer batch

Shipper uploads invoice against one importer shipment batch. Supervisor OCR reviews, links, approves apportionment, and makes it ready for Sage/AP.

### B. Shipper invoice for shared container

One shipper invoice covers three importer batches. It is linked to a master shipment or controlled multi-batch group, not duplicated three times.

### C. Export docs without shipper invoice

Final COS/BOL/POD may support export evidence but does not by itself approve shipping cost/Sage AP.

### D. Shipper invoice without export docs

Shipper invoice may support shipping-cost review but does not by itself clear zero-rating/export evidence.

### E. Goods invoice released before shipping invoice

Stable goods invoice release is not blocked merely because shipper invoice is missing, where policy permits later supplementary shipping/recharge.

### F. 30 item package

Worklist shows compact package/content summary with link only. Full item list opens on a dedicated detail page. No large inline expansion.

### G. Importer/operator access

Importer/operator cannot see shipper invoice/receipt document, OCR, cost, apportionment, Sage/AP coding or internal shipping cost controls.

---

## 18. Final locked sentence

```text
Shipping control uses one supervisor control centre and one shared document/OCR queue, but document type controls the downstream lane. Shipper invoices/receipts are supervisor/admin finance documents, not importer/operator documents and not export evidence documents. Shipper invoices support shipping-cost apportionment and Sage/AP/customer recharge readiness. COS/BOL/container/POD documents support export evidence and VAT zero-rating clearance. Importer shipment batches hold package movement truth only; master shipments hold shared container/BOL/export movement truth; supervisor review joins the truth before COS, Sage and VAT readiness.
```
