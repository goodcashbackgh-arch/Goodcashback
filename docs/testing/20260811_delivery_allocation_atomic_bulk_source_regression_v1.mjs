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
const replacementPanel = read("app/importer/ReplacementOrdersPanel.tsx");
const replacementRpc = read("supabase/migrations/20260803211000_same_order_free_replacement_tracking_allocation_v1.sql");

assert.match(addendum, /Governing amendment v1\.2 — narrow atomic bulk ordinary allocation/);
assert.match(addendum, /This patch does one thing: add atomic bulk submission to the existing ordinary delivery-allocation lane/);
assert.match(addendum, /replacement successor rows are excluded only from ordinary-remaining arithmetic/);
assert.match(addendum, /existing ordinary clear\/rework behaviour/);

assert.match(migration, /CREATE FUNCTION public\.delivery_allocate_tracking_lines_v1/);
assert.doesNotMatch(migration, /delivery_clear_tracking_allocations_v1/);
assert.doesNotMatch(migration, /delivery_allocation_control_state_v1/);
assert.match(migration, /pg_advisory_xact_lock\(hashtext\(p_order_id::text\)\)/);
assert.match(migration, /successor_tracking_line_allocation_id=a\.id/);
assert.match(migration, /route_status='tracking_allocated'/);
assert.match(migration, /Single allocation requires exact quantity mode/);
assert.match(migration, /qty_confirmed/);
assert.match(migration, /amount_confirmed/);
assert.match(migration, /recalculate_invoice_adjustment_consumption_v1/);
assert.doesNotMatch(migration, /CREATE\s+TRIGGER/is);
assert.doesNotMatch(migration, /ALTER\s+TABLE\s+public\.order_tracking_line_allocations/i);

assert.match(actions, /rpc\("delivery_allocate_tracking_lines_v1"/);
assert.match(actions, /p_request_kind: "single"/);
assert.match(actions, /quantity_mode: "exact"/);
assert.match(actions, /p_request_kind: "bulk"/);
assert.match(actions, /quantity_mode: "remaining"/);
assert.match(actions, /from\("order_tracking_line_allocations"\)[\s\S]{0,200}\.delete\(/);
assert.doesNotMatch(actions, /delivery_clear_tracking_allocations_v1/);

assert.match(data, /qty_confirmed/);
assert.match(data, /amount_confirmed/);
assert.match(data, /physical_replacement_same_order_routes/);
assert.match(data, /successor_tracking_line_allocation_id/);
assert.match(data, /counts_toward_ordinary_remaining/);
assert.doesNotMatch(data, /delivery_allocation_control_state_v1/);

assert.match(workspace, /DeliveryAllocationBulkControls/);
assert.match(workspace, /form="bulk-delivery-allocation-form"/);
assert.match(workspace, /filter\(\(allocation\) => allocation\.counts_toward_ordinary_remaining\)/);
assert.match(workspace, /effectiveLineQty/);
assert.match(workspace, /effectiveLineAmount/);
assert.match(workspace, /Clear unlocked allocations/);
assert.match(workspace, /Shipper receipt, package selection, or quote does not lock contents/);

assert.match(bulkControls, /FloatingActionBar/);
assert.match(bulkControls, /Select all available/);
assert.match(bulkControls, /I confirm these selected items are in this tracking package/);
assert.match(bulkControls, /Apply tracking ref/);
assert.match(bulkControls, /setConfirmed\(false\)/);
assert.doesNotMatch(bulkControls, /name="qty_allocated"/);

assert.match(floatingActionBar, /export function FloatingActionBar/);
assert.match(replacementPanel, /Allocate successor tracking/);
assert.match(replacementRpc, /operator_allocate_same_order_replacement_tracking_v1/);
assert.doesNotMatch(migration, /operator_allocate_same_order_replacement_tracking_v1[\s\S]*CREATE|CREATE[\s\S]*operator_allocate_same_order_replacement_tracking_v1/);

console.log("delivery allocation atomic bulk v1.2 source regression passed");
