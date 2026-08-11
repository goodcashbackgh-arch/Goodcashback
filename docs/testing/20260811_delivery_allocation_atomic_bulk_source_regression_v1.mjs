import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

function read(path) {
  return readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
}

const addendum = read("docs/governing-pack/backend/Delivery_Allocation_Lock_Timing_Clarification_v1.md");
const migration = read("supabase/migrations/20260811190000_delivery_allocation_atomic_bulk_control_v1.sql");
const actions = read("app/delivery-allocation/actions.ts");
const data = read("app/delivery-allocation/data.ts");
const workspace = read("app/delivery-allocation/DeliveryAllocationWorkspace.tsx");
const bulkControls = read("app/delivery-allocation/DeliveryAllocationBulkControls.tsx");
const floatingActionBar = read("app/_components/FloatingActionBar.tsx");

assert.match(addendum, /Governing amendment v1\.1 — atomic bulk allocation and exact-provenance rework/);
assert.match(addendum, /No generic table-wide trigger enforcing raw `SUM\(qty_allocated\)/);
assert.match(addendum, /Both the existing single-line allocation action and the new bulk action must use this same database authority/);
assert.match(addendum, /Do not delete downstream history merely to make allocation deletion succeed/);

assert.match(migration, /CREATE OR REPLACE FUNCTION public\.delivery_allocate_tracking_lines_v1/);
assert.match(migration, /CREATE OR REPLACE FUNCTION public\.delivery_clear_tracking_allocations_v1/);
assert.match(migration, /CREATE OR REPLACE FUNCTION public\.delivery_allocation_control_state_v1/);
assert.match(migration, /pg_advisory_xact_lock\(hashtext\(p_order_id::text\)\)/);
assert.match(migration, /successor_tracking_line_allocation_id = a\.id/);
assert.match(migration, /receipt_model_version = 2/);
assert.match(migration, /shipper_shipment_batch_line_memberships/);
assert.match(migration, /recalculate_invoice_adjustment_consumption_v1/);
assert.doesNotMatch(migration, /CREATE\s+TRIGGER\s+.*order_tracking_line_allocations/is);
assert.doesNotMatch(migration, /DROP\s+TABLE\s+public\./i);
assert.doesNotMatch(migration, /ALTER\s+TABLE\s+public\.order_tracking_line_allocations/i);

assert.match(actions, /rpc\("delivery_allocate_tracking_lines_v1"/);
assert.match(actions, /p_request_kind: "single"/);
assert.match(actions, /p_request_kind: "bulk"/);
assert.match(actions, /rpc\("delivery_clear_tracking_allocations_v1"/);
assert.doesNotMatch(actions, /from\("order_tracking_line_allocations"\)\.insert/);
assert.doesNotMatch(actions, /from\("order_tracking_line_allocations"\)[\s\S]{0,120}\.delete\(/);
assert.doesNotMatch(actions, /recalculate_invoice_adjustment_consumption_v1/);

assert.match(data, /qty_confirmed/);
assert.match(data, /amount_confirmed/);
assert.match(data, /delivery_allocation_control_state_v1/);
assert.match(data, /accepts_new_allocations/);
assert.match(data, /can_simple_clear/);

assert.match(workspace, /DeliveryAllocationBulkControls/);
assert.match(workspace, /form="bulk-delivery-allocation-form"/);
assert.match(workspace, /Clear editable allocations/);
assert.match(workspace, /cannot be cleared here\. Use the controlled correction route/);
assert.match(workspace, /disabled=!tracking\.accepts_new_allocations|disabled=\{!tracking\.accepts_new_allocations\}/);
assert.doesNotMatch(workspace, /Shipper receipt, package selection, or quote does not lock contents/);

assert.match(bulkControls, /FloatingActionBar/);
assert.match(bulkControls, /Select all available/);
assert.match(bulkControls, /I confirm these selected items are in this tracking package/);
assert.match(bulkControls, /Apply tracking ref/);
assert.match(bulkControls, /setConfirmed\(false\)/);
assert.doesNotMatch(bulkControls, /name="qty_allocated"/);

assert.match(floatingActionBar, /export function FloatingActionBar/);

console.log("delivery allocation atomic bulk source regression passed");
