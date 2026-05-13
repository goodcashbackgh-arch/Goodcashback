# Shipping Document OCR Pre-fill Clarification Addendum v1

**Project:** Multi Tenant Platform Build  
**Status:** Governing clarification addendum  
**Purpose:** Lock the OCR integration approach for shipper invoices/receipts so the build enhances the already-built manual supervisor review lane without creating a parallel workflow or changing downstream accounting controls.

---

## 1. Governing effect

This addendum supplements:

1. `Shipping_Control_Centre_Document_Intake_and_Export_Evidence_Flow_Addendum_v1.md`
2. `Multi_Tenant_UI_Wiring_Control_Document_v1.md`
3. the existing `/internal/shipping-control/shipper-documents/[shipping_document_id]` supervisor review lane
4. the existing shipper document acceptance, shipping apportionment and Ready for Sage/AP readiness chain

If any earlier wording implies that shipper OCR should create a separate review page, bypass supervisor review, directly approve a shipping document, directly apportion shipping costs, or feed Sage directly, this addendum overrides that reading.

---

## 2. Locked principle

```text
OCR replaces manual data entry only. It does not replace supervisor judgement, document acceptance, apportionment approval, Sage mapping, Sage posting, VAT/export evidence clearance, or final order closure.
```

OCR is a pre-fill and match-assist layer for the existing shipper document review lane.

---

## 3. Existing lane remains the control point

The control point remains:

```text
/internal/shipping-control/shipper-documents/[shipping_document_id]
```

The existing manual fields remain the target fields for OCR pre-fill:

```text
extracted_document_ref
extracted_document_date
extracted_total_amount
```

Currency may remain in the existing page/model for now as legacy/internal default GBP, but it is not part of the shipper OCR match decision for UK shipper documents.

---

## 4. Expected upload facts

When the shipper uploads the invoice/receipt, the platform already knows or captures:

```text
expected shipper
selected booking ref
selected importer
submitted amount GBP
uploaded file
```

The selected booking ref is the key commercial link. Importer is useful context but should be derived from the booking/shipment context and not used as a fragile OCR-only blocker.

---

## 5. OCR extracted facts

OCR should extract, where available:

```text
shipper/supplier name
booking/reference text
invoice/receipt reference
invoice/receipt date
total amount
line descriptions and line amounts, if available
raw OCR JSON for audit/debug
```

Do not expose currency as a primary match field for UK shipper invoice review. UK shipper invoices are assumed GBP unless later business rules say otherwise.

---

## 6. Match logic

Primary green checks:

```text
shipper name matches expected shipper
booking ref is present in OCR reference/booking text
submitted amount equals OCR total, within rounding tolerance
```

Secondary informational checks:

```text
invoice/receipt ref captured
invoice/receipt date captured
OCR lines captured, if available
```

Recommended status meanings:

```text
Green = primary checks pass; ready for supervisor acceptance or bulk acceptance.
Amber = primary checks pass but secondary evidence is weak/missing; supervisor review needed.
Red = shipper mismatch, booking ref mismatch, amount mismatch, unreadable/wrong document, or technical OCR failure.
```

---

## 7. No manual fetch step

The user should not need to guess when to fetch OCR results.

The target behaviour is:

```text
send selected document(s) to OCR
status becomes OCR processing
OCR completion is recorded automatically by webhook or scheduled polling
row changes to OCR ready / needs review when extraction is available
```

A manual fetch button may be used only as a temporary developer/admin fallback during integration testing. It must not become the normal supervisor workflow.

---

## 8. Review and correction

Supervisor/admin must be able to:

```text
open uploaded document
compare expected facts against OCR facts
see OCR line extraction where available
edit extracted ref/date/total if OCR is wrong
reject completely if wrong document
request resubmission where the document cannot support the charge
accept current document when satisfied
```

OCR failure or weak OCR is not automatically a resubmission event. If the document is visually valid, the supervisor may correct the extracted fields and accept with audit note.

Retry OCR is only for technical failure or clearly failed processing, not the normal correction route.

---

## 9. Downstream chain must not change

The existing downstream chain remains:

```text
OCR pre-fills extracted_* fields on shipping_documents
→ supervisor reviews/edits if needed
→ supervisor accepts current document
→ accepted document becomes the trusted shipper/AP money source
→ shipping cost apportionment uses the accepted document total
→ apportionment approval feeds shipper/AP purchase invoice intent into Ready for Sage
→ Sage posting remains blocked until mapping/API posting controls are built
```

Do not feed OCR directly into:

```text
shipping cost apportionment approval
Ready for Sage approval
Sage posting
VAT/export evidence clearance
COS/BOL/POD generation
order closure
```

---

## 10. Efficiency requirement

The shipper document queue should support high-volume processing:

```text
bulk select not-OCRed rows
bulk send selected rows to OCR
show OCR processing / OCR ready / needs review states
highlight only mismatches or weak extractions
allow bulk acceptance of green rows after the lane is proven
use detail pages only for exceptions or audit inspection
```

The normal supervisor should not have to open every document unless there is a mismatch, weak extraction, or audit concern.

---

## 11. Final locked sentence

```text
Shipper invoice OCR is a pre-fill and match-assist layer for the existing supervisor shipper-document review page. It replaces manual typing of extracted document facts where OCR is confident, but it does not change the existing acceptance, apportionment, Sage readiness, Sage posting, VAT/export evidence, or closure controls.
```
