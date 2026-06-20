# Groupage Movement Supporting Shipment Document ZIP Addendum v1

## 1. Purpose

This addendum tightens the Groupage Movement pack workflow by making the existing single-shipment supporting document ZIP available at Groupage Movement level.

The Groupage Export Pack remains the movement certificate, booking / recipient schedule, and invoice line / goods annex. The supporting shipment document ZIP is a separate supporting evidence download containing the posted customer sales invoice PDFs referenced by that annex.

## 2. Continuity rule

This addendum does not replace `GROUPAGE_MOVEMENT_CONTROL_CONTRACT_v1.md`.

It extends the pack workflow so that a shipper can complete the same evidence bundle at groupage level that already exists for a single shipment batch:

```text
Download combined export pack
Download supporting shipment documents ZIP
Upload signed export pack
Upload POD / delivery evidence where applicable
```

The source of truth remains:

```text
Order -> Shipment Batch -> Batch Evidence / POD -> Existing Status Logic
```

The supporting ZIP must not become a new canonical status engine and must not mutate order, batch, evidence, POD, customer sales, Sage posting, VAT, credit, or loyalty state.

## 3. Required route

Add the route:

```text
/shipper/groupage-movements/[groupage_movement_id]/sales-invoices-zip
```

The route must:

1. authenticate the shipper user;
2. call `shipper_groupage_export_pack_preview_v1(groupage_movement_id)`;
3. read the unique `sales_invoice_ref` values returned by the groupage export pack preview;
4. resolve posted main `sales_invoices` rows using `sage_reference` or `sage_invoice_id`;
5. fetch the posted invoice PDFs server-side through the existing document/PDF retrieval mechanism;
6. return one ZIP named from the Groupage Movement reference;
7. include a `manifest.txt` explaining that the ZIP supports the Groupage Export Pack and does not replace the signed export evidence upload.

## 4. Required ZIP contents

The ZIP should contain:

```text
manifest.txt
shipment-documents/[booking-ref]-[sales-invoice-ref].pdf
shipment-documents/[booking-ref]-[sales-invoice-ref].pdf
...
```

For `GM200626`, an expected example is:

```text
GM200626-supporting-shipment-documents.zip
  manifest.txt
  shipment-documents/J0110526-SI-3.pdf
  shipment-documents/J0124353-SI-6.pdf
```

## 5. UI placement

On `/shipper/groupage-movements/[movement_id]`, expose the supporting ZIP beside the existing export pack action.

Required labels:

```text
Download combined export pack
Download supporting shipment documents ZIP
```

Avoid labels that expose accounting system names or provider names to the shipper/customer UI.

## 6. Separation from signed export evidence upload

The signed/stamped Groupage Export Pack upload remains governed by `shipper_submit_groupage_signed_export_pack_v1`.

The signed upload must still write normal batch-level evidence rows for every active included shipment batch:

```text
shipment_batch_id = included batch
document_kind = completed_cos
document_ref = groupage_movement_ref
file_url = same signed groupage pack
review_status = submitted_for_review
```

The supporting shipment document ZIP is download-only support. It is not uploaded as the completed COS and must not drive export evidence status by itself.

## 7. Done definition

The Groupage Movement pack workflow is complete when:

1. the combined Groupage Export Pack generates without blockers;
2. the pack includes the certificate, booking / recipient schedule, and invoice line / goods annex;
3. the supporting shipment documents ZIP downloads all posted customer sales invoice PDFs referenced in the annex;
4. the Groupage Movement page exposes both download actions without requiring the shipper to open each batch separately;
5. signed export pack upload still writes to existing batch-level evidence records for all included batches;
6. no new Sage/accounting posting action is introduced by this addendum.
