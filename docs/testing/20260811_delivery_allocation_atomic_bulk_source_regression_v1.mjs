import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const BASE = "49fe8bbe4fdd6ea7f1cdf84d05294b6c9e4b5a2e";

function read(path) {
  return readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
}

function atBase(path) {
  return execFileSync("git", ["show", `${BASE}:${path}`], { encoding: "utf8" });
}

const addendum = read("docs/governing-pack/backend/Delivery_Allocation_Lock_Timing_Clarification_v1.md");
const migration = read("supabase/migrations/20260811190000_delivery_allocation_atomic_bulk_control_v1.sql");
const actions = read("app/delivery-allocation/actions.ts");
const baseActions = atBase("app/delivery-allocation/actions.ts");
const data = read("app/delivery-allocation/data.ts");
const baseData = atBase("app/delivery-allocation/data.ts");
const workspace = read("app/delivery-allocation/DeliveryAllocationWorkspace.tsx");
const bulkControls = read("app/delivery-allocation/DeliveryAllocationBulkControls.tsx");

assert.match(addendum, /Governing amendment v1\.3 — bulk assignment wrapper only/);
assert.match(addendum, /This patch is only a bulk-assignment wrapper around the existing delivery-allocation lane/);
assert.match(addendum, /existing `saveDeliveryAllocationAction` remains on its pre-patch implementation/);
assert.match(addendum, /`app\/delivery-allocation\/data\.ts` remains byte-for-byte unchanged/);

assert.equal(data, baseData, "delivery-allocation data loader must remain byte-identical to the branch base");
assert.ok(actions.startsWith(baseActions), "existing delivery-allocation actions must remain byte-identical at the start of actions.ts");
const appendedActions = actions.slice(baseActions.length).trim();
assert.match(appendedActions, /^export async function saveBulkDeliveryAllocationAction\(formData: FormData\)/);
assert.doesNotMatch(baseActions, /saveBulkDeliveryAllocationAction/);

assert.match(actions, /rpc\("delivery_allocate_tracking_lines_bulk_v1"/);
assert.doesNotMatch(appendedActions, /delivery_allocate_tracking_lines_v1/);
assert.match(actions, /revalidatePath\(`\/importer\/delivery-allocation\/\$\{orderId\}`\)/);
assert.match(actions, /revalidatePath\(`\/internal\/reconciliation\/\$\{orderId\}`\)/);

assert.match(workspace, /DeliveryAllocationBulkControls/);
assert.match(workspace, /const originalQty = Number\(line\.qty \?\? 0\)/);
assert.match(workspace, /return allocations\.reduce\(\(sum, allocation\) => sum \+ Number\(allocation\.qty_allocated \?\? 0\), 0\)/);
assert.doesNotMatch(workspace, /effectiveLineQty|effectiveLineAmount|counts_toward_ordinary_remaining|physical_replacement_same_order_routes/);
assert.match(
  workspace,
  /!complete && !hasDownstreamLock \? \([\s\S]{0,500}<input form="bulk-delivery-allocation-form" type="checkbox" name="line_ids"/
);
assert.match(
  workspace,
  /!complete && !hasDownstreamLock \? \([\s\S]{0,500}<form action=\{saveDeliveryAllocationAction\}/
);
assert.match(workspace, /data-remaining-qty=\{remainingQty\}/);
assert.match(workspace, /name="qty_allocated" type="number"/);
assert.match(workspace, /Clear unlocked allocations/);

assert.match(bulkControls, /FloatingActionBar/);
assert.match(bulkControls, /Select all available/);
assert.match(bulkControls, /selectableCheckboxes\(\)/);
assert.match(bulkControls, /I confirm these selected items are in this tracking package/);
assert.match(bulkControls, /Apply tracking ref/);
assert.match(bulkControls, /setConfirmed\(false\)/);
assert.doesNotMatch(bulkControls, /name="qty_allocated"/);

assert.match(migration, /CREATE FUNCTION public\.delivery_allocate_tracking_lines_bulk_v1/);
assert.doesNotMatch(migration, /CREATE FUNCTION public\.delivery_allocate_tracking_lines_v1\b/);
assert.doesNotMatch(migration, /delivery_clear_tracking_allocations_v1|delivery_allocation_control_state_v1/);
assert.doesNotMatch(migration, /physical_replacement_same_order_routes|successor_tracking_line_allocation_id|tracking_allocation_effective_entitlement_v1/);
assert.match(migration, /pg_advisory_xact_lock\(hashtext\(p_order_id::text\)\)/);
assert.match(migration, /SUM\(a\.qty_allocated\)/);
assert.match(migration, /resolution_type = 'non_physical_financial'/);
assert.match(migration, /COALESCE\(sil\.qty_confirmed, sil\.qty, 0\)/);
assert.match(migration, /COALESCE\(sil\.amount_confirmed, sil\.amount_inc_vat_gbp, 0\)/);
assert.match(migration, /recalculate_invoice_adjustment_consumption_v1/);
assert.doesNotMatch(migration, /CREATE\s+TRIGGER|ALTER\s+TABLE/is);

const changedFiles = execFileSync("git", ["diff", "--name-only", BASE, "--"], { encoding: "utf8" })
  .trim()
  .split("\n")
  .filter(Boolean);
const allowedFiles = new Set([
  "app/delivery-allocation/DeliveryAllocationBulkControls.tsx",
  "app/delivery-allocation/DeliveryAllocationWorkspace.tsx",
  "app/delivery-allocation/actions.ts",
  "docs/governing-pack/backend/Delivery_Allocation_Lock_Timing_Clarification_v1.md",
  "docs/testing/20260811_delivery_allocation_atomic_bulk_postflight_v1.sql",
  "docs/testing/20260811_delivery_allocation_atomic_bulk_source_regression_v1.mjs",
  "supabase/migrations/20260811190000_delivery_allocation_atomic_bulk_control_v1.sql",
]);
for (const path of changedFiles) {
  assert.ok(allowedFiles.has(path), `unexpected scope creep file: ${path}`);
}
assert.ok(!changedFiles.includes("app/delivery-allocation/data.ts"));
assert.ok(!changedFiles.includes("app/_components/FloatingActionBar.tsx"));
assert.ok(!changedFiles.some((path) => path.includes("ReplacementOrdersPanel") || path.includes("replacement-orders-data")));

console.log("delivery allocation bulk wrapper v1.3 source regression passed");
