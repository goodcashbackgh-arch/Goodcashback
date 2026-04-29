# Create Order MVP Contract

Status: MVP v1 source of truth.

This contract defines the importer order-entry flow for the current MVP.

---

## Governing sources

- `docs/governing-pack/role-matrices/importer_role_stage_matrix_v7.md`
- live schema: `orders`, `order_category_lines`, `order_screenshots`, `markup_categories`

---

## Core principles

- Importer creates the parent order.
- Importer does not choose shipper.
- Importer does not choose destination hub/city.
- Shipper and destination hub/city are assigned during onboarding and inherited onto the order.
- Destination hub/city must still be stored on the order so shipper quote/handoff screens can use it.
- Children’s clothing, infant clothing, school uniform, and similar restricted clothing items are out of MVP product scope.
- Product-scope exclusion must be framed as commercial scope/control, not VAT wording.

---

## Importer order-entry UI

Create order page must show:

1. Retailer dropdown
2. Assigned shipper — read-only
3. Assigned destination city/hub — read-only
4. Screenshot upload — required, one or more files
5. Goods row:
   - Qty
   - Total GBP
6. Grand total:
   - Total qty
   - Total GBP
7. Product confirmation checkbox
8. Pro Forma Quote / Create order action

Do not show:

- shipper dropdown
- destination hub dropdown
- category dropdown
- screenshot URL field
- fixed three-row category placeholder
- children’s clothing row in MVP
- VAT wording to importer

---

## Product confirmation wording

Use this brief wording at the Pro Forma Quote / order submission stage:

> Product confirmation
>
> I confirm this order does not include children’s clothing, infant clothing, school uniform, or similar restricted items.
>
> If restricted items are found, the order may be rejected or refunded, and an admin charge may apply.

Checkbox label:

> I confirm and accept

Full policy detail belongs in onboarding terms, not on the order page.

---

## Category storage

Even though the importer UI shows a simple Goods row, the backend must still use `order_category_lines`.

For MVP:

- one default active category should represent general retail goods / goods total
- do not label it VATable in importer UI
- `order_category_lines.markup_category_id` stores the default/general category
- `order_category_lines.qty` stores submitted qty
- `order_category_lines.amount_inc_vat_gbp` stores submitted goods value
- `orders.total_qty_declared` rolls up from category line qty
- `orders.order_total_gbp_declared` rolls up from category line value

Children’s clothing should not be accepted into the MVP order-entry flow.

---

## Quote wording

Use “Pro Forma Quote” for the order estimate stage.

Use this wording:

> Pro Forma Quote
>
> This estimate is based on the goods value you submitted. Shipping is not included at this stage.
>
> Shipping will be quoted separately after the goods are received, checked, and assessed by the shipper.

---

## Submission behaviour

On submit:

1. validate active importer/operator access
2. derive assigned shipper and destination hub/city from onboarding data
3. require retailer
4. require at least one screenshot upload
5. require qty > 0
6. require amount > 0
7. require product confirmation checkbox
8. create parent `orders` row
9. create one `order_category_lines` row using the default/general category
10. upload/store screenshots and create `order_screenshots` rows
11. generate `order_ref`
12. generate `payment_auth_id`
13. set status to `pending_dva_funding`
14. show created order with order ref, auth ref, totals, and pro forma wording

---

## Out of scope for MVP

Do not build yet:

- children’s clothing pricing/rate treatment
- VAT classification workflow
- importer-selected shipper
- importer-selected destination hub
- final shipping quote at order creation
- Sage/VAT posting
- DVA reconciliation from importer UI

---

## Required regression

1. Retailer dropdown loads.
2. Assigned shipper displays read-only.
3. Assigned destination city/hub displays read-only.
4. Screenshot upload is required.
5. Screenshot URL field is removed.
6. Qty and amount are required and positive.
7. Product confirmation checkbox is required.
8. Order creates with one general/default category line.
9. Order totals match the row qty/value.
10. Screenshots create `order_screenshots` rows.
11. Order enters `pending_dva_funding`.
12. Created order appears on importer dashboard.
13. Destination hub/city is stored for later shipper quote/handoff.
14. No shipper/hub/category dropdown is exposed to importer.
