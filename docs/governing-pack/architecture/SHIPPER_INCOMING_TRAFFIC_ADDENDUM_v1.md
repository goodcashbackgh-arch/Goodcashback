# SHIPPER_INCOMING_TRAFFIC_ADDENDUM_v1

## Status
Governing authority for the Shipper Incoming Traffic v1 build.

This addendum is intentionally additive and surgical. It authorises only the changes explicitly listed below. Existing working shipper, tracking, allocation, receipt, shipment, replacement, exception, funding, VAT, accounting and Sage behaviour is frozen.

## 1. Objective
Provide each authenticated shipper with a read-only Incoming Traffic page showing orders already in that shipper's existing lane where no valid item-to-tracking association exists yet.

This feature is visibility only. It must not create a new operational state, lane, workflow or authority.

## 2. Existing architecture to reuse
- `orders.shipper_id` remains the active shipper lane authority.
- Resolve the authenticated shipper using the existing pattern: `auth.uid()` -> active `shipper_users` -> `shipper_id`.
- Reuse existing `orders.importer_id`, `orders.retailer_id`, `orders.order_ref`, `orders.created_at`, and `orders.total_qty_declared`.
- Reuse the existing `order_tracking_line_allocations` relationship to `order_tracking_submissions` and `supplier_invoice_lines` as the canonical item-to-tracking association.
- Do not add a new tenant model, shipper assignment model, lane state, importer-to-shipper bridge, lifecycle flag, status or persisted incoming-traffic marker.

## 3. Authorised implementation surface
The build is limited to:
1. One new read-only RPC: `public.shipper_incoming_traffic_v1()`.
2. One new page: `app/shipper/incoming-traffic/page.tsx` at `/shipper/incoming-traffic`.
3. One surgical insertion in `app/shipper/page.tsx`: add `6. Incoming traffic` after `5. Upload charge document`.

No other existing application file, database function, table, trigger, RLS policy, workflow or component is authorised for modification.

## 4. Dashboard insertion
Add only one link after `5. Upload charge document`:
- Label: `6. Incoming traffic`
- Route: `/shipper/incoming-traffic`
- Reuse the existing secondary white/outlined shipper action-button styling and existing responsive wrapping.

Do not renumber, move, restyle or change buttons 1-5. Do not add a dashboard metric card. Do not change dashboard counts or worklist behaviour.

## 5. Incoming Traffic qualification rule
An order appears when:
- it belongs to the authenticated shipper's existing lane; and
- there is no valid existing item-to-tracking association for that order.

There is one qualification/exit rule only. Do not add order-status filtering in v1.

A valid item-to-tracking association requires the existing canonical relationship:
- `order_tracking_line_allocations.order_id = orders.id`
- a real `supplier_invoice_line_id`
- a non-null `tracking_submission_id`
- the referenced `order_tracking_submissions` row belongs to the same order
- the tracking submission is active: `superseded_at IS NULL`

Therefore:
- no item + no tracking -> show
- tracking only -> show
- item only -> show
- independent item and tracking records without the canonical association -> show
- at least one valid item-to-tracking association -> do not show

For a multi-item order, one valid item-to-tracking association is sufficient for the entire order to cease qualifying for this view. This is intentional.

Ceasing to qualify for Incoming Traffic must not update or remove `orders.shipper_id`; the order remains in the existing shipper lane and continues through existing workflows.

## 6. New RPC contract
Create `public.shipper_incoming_traffic_v1()` as an additive, read-only function.

Security requirements:
- require `auth.uid()`
- resolve the latest active `shipper_users` row for the caller
- fail if there is no active shipper user
- restrict rows to `orders.shipper_id = v_shipper_id`
- `SECURITY DEFINER`
- `SET search_path = public, pg_temp`
- revoke execution from `PUBLIC` and `anon`
- grant execution only to `authenticated`

Do not modify grants on any existing function.

Return only:
- `order_id`
- `order_date`
- `importer_id`
- `importer_name`
- `retailer_id`
- `retailer_name`
- `order_ref`
- `total_qty_declared`

Source mapping:
- order date -> `orders.created_at`
- order ref -> `orders.order_ref`
- qty -> `orders.total_qty_declared`
- importer -> existing `orders.importer_id -> importers`
- retailer -> existing `orders.retailer_id -> retailers`

Sort newest first by `orders.created_at DESC`.

Do not return or expose prices, DVA values, invoices, VAT, payments, accounting, shipment values, receipt details, exception details or replacement details.

## 7. Existing RPC freeze
Do not modify or replace:
- `shipper_package_receipt_dashboard_v1()`
- `shipper_package_dashboard_v1()`
- package contents preview functions
- shipment candidate functions
- receipt functions
- allocation functions
- replacement/exception functions
- any other existing RPC

The dedicated new reader is required specifically to minimise regression risk.

## 8. Incoming Traffic page
Route: `/shipper/incoming-traffic`

Heading: `Incoming traffic`

Description: `Orders in your shipper lane that do not yet have an item linked to tracking.`

Provide a normal `Back to shipper dashboard` link to `/shipper`.

Table columns only:
- Order date
- Importer
- Retailer
- Order ref
- Qty

No row actions and no v1 click-through requirement.

Empty state: `No incoming traffic awaiting item/tracking allocation.`

Reuse the existing shipper visual language and responsive table/form patterns. Do not create a new design system, shared abstraction, toast framework, loading framework or navigation shell.

## 9. Filters
Reuse the existing shipper dashboard pattern based on URL `searchParams`, a normal form, Apply and Reset.

Filters:
- Importer
- Date from
- Date to
- Retailer
- Qty
- Order ref
- Apply
- Reset

Rules:
- Importer dropdown options must be derived only from the already shipper-scoped RPC rows.
- Retailer dropdown options must be derived only from the already shipper-scoped RPC rows.
- Date filters operate on order date.
- Qty is an exact filter on `total_qty_declared` in v1.
- Order ref is a case-insensitive text match.
- Filtering occurs only after the authenticated shipper-scoped RPC result is returned.
- The RPC takes no filter parameters.
- Filters are read-only and must not mutate database state or tenancy.

Do not add status filters, quantity ranges, generic filter services, dynamic SQL, API routes or client-side state architecture.

## 10. Explicitly forbidden database changes
Do not:
- alter `orders`
- alter `shipper_users`
- alter `order_tracking_submissions`
- alter `order_tracking_line_allocations`
- alter `supplier_invoice_lines`
- create a new table
- create a materialized view
- create triggers
- create new lifecycle columns or flags
- create new statuses
- change constraints
- change existing RLS policies
- change existing indexes
- update or backfill historical data
- replace any existing database function

The only database change authorised is creation and permissioning of the new read-only RPC.

## 11. Frozen working functionality
No behavioural changes are authorised to:
- package receipt dashboard
- dashboard metrics
- package worklist and its existing filters
- View shipment batches
- Create shipment batch
- Package receipt actions
- Return tasks
- Upload charge document
- tracking submission
- item allocation
- physical receipt
- shipment eligibility and batching
- returns
- exceptions
- replacements
- customer holds
- customer order creation
- DVA/funding
- VAT/accounting/Sage

## 12. Required acceptance and regression tests
Traffic logic:
1. New shipper-lane order with no tracking -> visible.
2. Tracking only -> visible.
3. Item/allocation information without a valid tracking association -> visible.
4. One valid item-to-tracking association -> order no longer visible.
5. Multi-item order with only one valid association -> whole order no longer visible.

Tenant isolation:
6. A shipper sees only `orders.shipper_id` matching its authenticated shipper id.
7. A second shipper sees only its own lane.
8. Importer filter values are limited to the authenticated shipper's returned rows.
9. Retailer filter values are limited to the authenticated shipper's returned rows.

Regression:
10. Existing shipper dashboard loads unchanged apart from the new link.
11. Existing dashboard metrics are unchanged.
12. Existing package worklist filters still work.
13. Existing receipt workflow still works.
14. Existing shipment creation still works.
15. Existing return tasks still work.
16. Existing replacement and exception flows remain untouched.

## 13. Diff guard
Apart from this governing addendum, the implementation diff is expected to contain only:
- NEW `supabase/migrations/<timestamp>_shipper_incoming_traffic_v1.sql`
- NEW `app/shipper/incoming-traffic/page.tsx`
- EDIT `app/shipper/page.tsx`

The edit to `app/shipper/page.tsx` must be limited to the Incoming Traffic link insertion (plus only the exact import change if technically required; no import change is expected because `Link` already exists).

Any unrelated formatting, refactor, variable rename, code movement, cleanup or behavioural change is outside authority and must be rejected.

## 14. Hard stop rule
If implementation appears to require changing an existing RPC, table, RLS policy, tracking rule, allocation rule, order lifecycle, receipt rule, shipment rule, replacement rule or exception rule, stop rather than expand scope.
