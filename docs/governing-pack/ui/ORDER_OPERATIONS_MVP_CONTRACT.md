# Shared Order Operations MVP Contract

Status: contract only (MVP v1).

This document defines the next build step after invoice reconciliation and exception branching: a shared order operations flow used by both original orders and replacement child orders.

---

## Governing sources checked

Primary sources reviewed before drafting:

- `docs/governing-pack/ui/EXCEPTION_BRANCHING_MVP_CONTRACT.md`
- `docs/governing-pack/ui/INVOICE_LINE_RECONCILIATION_ACTION_CONTRACT.md`
- `docs/governing-pack/role-matrices/importer_role_stage_matrix_v7.md`
- live DB discovery showing `markup_categories`, `order_category_lines`, `order_screenshots`, `order_tracking_submissions`, `supplier_invoices`, and `supplier_invoice_lines`

Key governing rules used:

- Replacement child orders must reuse existing operational lanes, not a special replacement-only workflow.
- Correct/progressed lines can move toward shipper/logistics while refund/replacement branches remain separate.
- Funding recognition delay must not block operational reconciliation, ready-for-shipment handoff, retailer communication, or shipper/logistics progression where goods are genuinely moving.
- Sage/VAT/accounting release remains downstream and must not be triggered by tracking, evidence upload, or exception creation alone.

---

## 1) MVP principle

Build one shared order operations flow.

It must work for:

- `orders.order_type = 'original'`
- `orders.order_type = 'replacement_child'`

Do not build a separate replacement-only flow.

The replacement child page should show clear context:

- this is a replacement child order
- parent order reference
- linked dispute/case if available

---

## 2) Shared order operations page

Preferred route:

- `/importer/orders/[order_id]/operations`

This page should become the operational hub for an order after creation or replacement-child creation.

It should show:

- order summary
- order type: original or replacement child
- parent order/dispute link if replacement child
- screenshots/category baseline where available
- tracking submissions
- supplier invoice/evidence state
- reconciliation link/state
- progressed lines/readiness summary
- next action for importer

---

## 3) Multiple tracking references

Retailers such as Zara may dispatch in multiple parcels.

Therefore, do not store tracking as a single order-level value.

Use `order_tracking_submissions` as a one-to-many table:

- one order can have multiple tracking submissions
- each submission represents one parcel/tracking reference/evidence item

MVP UI:

- show existing tracking submissions for the order
- add tracking reference
- add courier/carrier if existing schema supports it
- add tracking URL/reference if existing schema supports it
- add tracking screenshot URL/evidence if existing schema supports it
- checkbox: `This completes delivery for this order`

MVP behaviour:

- if checkbox is not checked: insert tracking submission only
- if checkbox is checked: insert tracking submission and mark order tracking as final/complete using existing order lock/status field if available

If the live schema lacks a final-delivery flag on `order_tracking_submissions`, add the smallest safe schema change:

- `is_final_delivery_yn boolean not null default false`

Do not supersede old tracking submissions for split deliveries.

`superseded_at` should only be used for correcting/replacing an erroneous submission, not for normal split deliveries.

### 3A) Tracking link and evidence-file separation

Locked rule from 2026-06-16:

- `courier_tracking_url` means the live retailer/courier tracking page used to monitor parcel movement.
- `tracking_evidence_url` means the uploaded supporting evidence file, such as dispatch screenshot, PDF, delivery note, or retailer confirmation.
- `tracking_screenshot_url` remains as a legacy/backward-compatible field only. It must not be removed or renamed during MVP hardening because existing shipper, delivery allocation, and historic tracking views still consume it.

Persistence rule:

- If the operator provides a live courier/retailer tracking URL, save it to `courier_tracking_url`.
- If the operator uploads a supporting evidence file, save its public/storage URL to `tracking_evidence_url`.
- For backward compatibility, keep writing `tracking_screenshot_url` using this fallback order:
  1. `tracking_evidence_url` if a file/evidence URL exists;
  2. otherwise `courier_tracking_url` if only a live tracking link exists.

Display rule:

- Show `Track parcel` from `courier_tracking_url`.
- Show `Open evidence` from `tracking_evidence_url`, falling back to legacy `tracking_screenshot_url` where no split-column value exists.
- When showing legacy `tracking_screenshot_url`, label it as legacy tracking/evidence unless the system can safely classify it.

Compatibility rule:

- Do not change tracking final-delivery logic.
- Do not change shipment allocation, shipper package receipt, export evidence, Sage, VAT, funding, customer sales invoice, or invoice reconciliation behaviour as part of this split.
- Additive columns and a v2 insert RPC are preferred over changing/removing the existing RPC signature.

---

## 4) Delivery completion rule

Importer/operator must declare whether the order is fully delivered for that retailer order.

Valid states:

- no tracking submitted
- tracking partially submitted
- tracking fully submitted / final delivery declared

The dashboard should distinguish:

- `No tracking`
- `Tracking submitted - partial`
- `Tracking complete`

Do not infer full delivery merely because at least one tracking reference exists.

---

## 5) Supplier invoice/evidence upload

The shared order operations page should surface the existing invoice/evidence flow.

For MVP:

- if no supplier invoice exists, allow submitting invoice reference + invoice PDF URL using the existing safe action/RPC if available
- if supplier invoice exists, show it and link to reconciliation
- do not build full OCR automation in this step unless already wired

This must work for replacement child orders too.

---

## 6) Reconciliation handoff

If supplier invoice exists:

- show link to `/importer/reconciliation/[order_id]`
- show progressed/unresolved summary from existing reconciliation data

If clean/progressed lines exist:

- show progressed subset as ready for downstream shipment handoff

Do not create Sage/VAT/accounting postings from this page.

---

## 7) Shipper handoff readiness

MVP should show readiness, not necessarily complete shipper quote automation.

Ready-for-shipper signal should depend on:

- at least one progressed invoiceable line, or replacement child clean evidence as appropriate
- tracking/evidence submitted as required by the operational stage
- no unresolved non-exception lines blocking the handoff

Staff/internal shipper handoff can remain a later page if not already built.

---

## 8) Order creation relationship

The live DB supports order creation structures:

- `markup_categories`
- `order_category_lines`
- `order_screenshots`
- `orders.total_qty_declared`
- `orders.order_total_gbp_declared`

However, the importer create-order route is not currently verified as wired in the repo.

Do not block shared order operations on the full create-order UI.

Build order operations first because it serves:

- seeded/test original orders
- existing real orders
- replacement child orders created from exception flow

Then later build or reconnect `/importer/orders/new` using the same baseline/category/screenshot components.

---

## 9) Hard controls

Do not allow:

- single tracking reference to overwrite prior tracking rows for split deliveries
- marking full delivery accidentally without explicit importer declaration
- replacement child order to detach from parent/dispute context
- shipping/Sage/VAT/accounting side effects from tracking submission alone
- funding/DVA logic changes in this step
- special replacement-only duplicated workflow

---

## 10) Required MVP regression

1. Original order can open shared operations page.
2. Replacement child order can open same shared operations page.
3. Replacement child page shows parent/dispute context.
4. Add first tracking reference without final checkbox -> tracking partial.
5. Add second tracking reference with final checkbox -> tracking complete.
6. Old tracking references remain visible; not superseded.
7. Dashboard distinguishes no tracking vs partial tracking vs complete tracking.
8. Existing missing-invoice/evidence upload path still works or remains visibly linked.
9. Reconciliation link still opens the existing reconciliation page.
10. No Sage/VAT/funding/shipping postings are triggered by tracking submission.
11. New tracking rows can preserve both a live courier tracking URL and an uploaded evidence file.
12. Old rows using `tracking_screenshot_url` still display through the legacy fallback.

---

## 11) Non-scope for MVP v1

Do not build yet unless explicitly approved:

- full create-order UI rebuild
- full OCR automation
- automated shipping quote creation
- shipper receipt approval UI
- Sage/VAT posting
- mobile/web push notifications

MVP goal: one shared operational page that can carry both original and replacement child orders through tracking/evidence/reconciliation readiness without duplicating workflows.
