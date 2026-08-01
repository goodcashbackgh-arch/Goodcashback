import fs from "node:fs";

const migrationPath = "supabase/migrations/20260801210000_hybrid_physical_receipt_build_4_lifecycle_reconciliation_v1.sql";
const atomicFixPath = "supabase/migrations/20260801213000_hybrid_physical_receipt_build_4_atomic_replacement_acceptance_fix_v1.sql";
const actionPath = "app/internal/exceptions/[dispute_id]/actions.ts";
const addendumPath = "docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md";

const migration = fs.readFileSync(migrationPath, "utf8");
const atomicFix = fs.readFileSync(atomicFixPath, "utf8");
const action = fs.readFileSync(actionPath, "utf8");
const addendum = fs.readFileSync(addendumPath, "utf8");

const checks = [
  [addendum.includes("Frozen Build 4 scope"), "alignment addendum freezes Build 4 scope"],
  [migration.includes("Build 4 drift stop: create_replacement_child_order changed"), "migration drift-stops replacement authority"],
  [migration.includes("Build 4 drift stop: order_has_open_child_exceptions changed"), "migration drift-stops parent blocker"],
  [migration.includes("Build 4 drift stop: order_reconciliation_vw changed"), "migration drift-stops reconciliation authority"],
  [migration.includes("replacement_source_dispute_line_id"), "replacement child retains source dispute line"],
  [migration.includes("replacement_child_order_id = v_child_id"), "physical remedy is linked to replacement child"],
  [migration.includes("status = 'in_progress'"), "physical remedy uses guarded in-progress transition"],
  [migration.includes("child.status = 'cancelled'"), "cancelled replacement child is explicitly handled"],
  [migration.includes("create or replace view public.order_reconciliation_anomalies_v1"), "anomaly read model is additive"],
  [migration.includes("NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE"), "non-authoritative eligible evidence is exposed"],
  [migration.includes("RAW_QTY_OVER_PROGRESS"), "raw quantity over-progression is exposed"],
  [migration.includes("RAW_AMOUNT_OVER_PROGRESS"), "raw amount over-progression is exposed"],
  [atomicFix.includes("create or replace function public.staff_accept_replacement_outcome_v1"), "atomic acceptance authority is installed"],
  [atomicFix.includes("Physical and legacy replacement lines cannot be mixed"), "atomic authority separates physical and legacy paths"],
  [atomicFix.includes("v_physical_line_count > 0 and v_active_line_count <> 1"), "physical replacement requires one exact line"],
  [atomicFix.includes("v_physical_line_count = 0 and v_active_line_count > 1"), "legacy multi-line aggregation remains supported"],
  [action.includes('.rpc("staff_accept_replacement_outcome_v1"'), "application uses one atomic replacement RPC"],
  [!action.includes('.rpc("create_replacement_child_order"'), "application does not call child creation separately"],
  [!action.includes('.from("orders")\n    .insert({\n      order_ref: childOrderRef'), "parallel direct replacement order insert remains removed"],
  [!migration.includes("update public.orders\n  set order_total_gbp_declared"), "canonical migration does not rewrite parent declared amount"],
  [!migration.includes("update public.orders\n  set total_qty_declared"), "canonical migration does not rewrite parent declared quantity"],
];

const failed = checks.filter(([passed]) => !passed);
if (failed.length) {
  for (const [, label] of failed) console.error(`FAIL: ${label}`);
  process.exit(1);
}

for (const [, label] of checks) console.log(`PASS: ${label}`);
console.log("PASS: Hybrid Physical Receipt Build 4 source regression");
