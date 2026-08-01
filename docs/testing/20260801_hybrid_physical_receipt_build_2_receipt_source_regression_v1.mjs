import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const BASE = process.env.BASE_REF || "origin/main";

function run(command, args) {
  return execFileSync(command, args, { encoding: "utf8" }).trim();
}

function fail(message) {
  throw new Error(`FAIL: ${message}`);
}

const allowed = new Set([
  "docs/implementation/20260801_hybrid_physical_receipt_build_2_impact_map_v1.md",
  "supabase/migrations/20260801139900_hybrid_physical_receipt_v2_terminal_correction_guard_v1.sql",
  "supabase/migrations/20260801140000_hybrid_physical_receipt_v2_rpc_v1.sql",
  "docs/testing/20260801_hybrid_physical_receipt_build_2_receipt_regression_v1.sql",
  "docs/testing/20260801_hybrid_physical_receipt_build_2_receipt_source_regression_v1.mjs",
]);

const changed = run("git", ["diff", "--name-only", `${BASE}...HEAD`])
  .split("\n")
  .filter(Boolean);

for (const file of changed) {
  if (!allowed.has(file)) fail(`unexpected changed file: ${file}`);
}

for (const file of allowed) {
  if (!changed.includes(file)) fail(`required Build 2 receipt file missing from diff: ${file}`);
}

const guardPath = "supabase/migrations/20260801139900_hybrid_physical_receipt_v2_terminal_correction_guard_v1.sql";
const rpcPath = "supabase/migrations/20260801140000_hybrid_physical_receipt_v2_rpc_v1.sql";
const regressionPath = "docs/testing/20260801_hybrid_physical_receipt_build_2_receipt_regression_v1.sql";
const impactPath = "docs/implementation/20260801_hybrid_physical_receipt_build_2_impact_map_v1.md";

const guard = readFileSync(guardPath, "utf8");
const rpc = readFileSync(rpcPath, "utf8");
const regression = readFileSync(regressionPath, "utf8");
const impact = readFileSync(impactPath, "utf8");

for (const [path, text] of [[guardPath, guard], [rpcPath, rpc]]) {
  const beginCount = (text.match(/^BEGIN;$/gm) || []).length;
  const commitCount = (text.match(/^COMMIT;$/gm) || []).length;
  if (beginCount !== 1 || commitCount !== 1) {
    fail(`${path} must contain exactly one outer BEGIN and COMMIT`);
  }
  if (/\bDROP\s+(TABLE|VIEW|FUNCTION|SCHEMA)\b/i.test(text)) {
    fail(`${path} contains destructive DROP`);
  }
  if (/CREATE\s+OR\s+REPLACE/i.test(text)) {
    fail(`${path} replaces an existing object`);
  }
  if (/\bCASCADE\b/i.test(text)) {
    fail(`${path} contains CASCADE`);
  }
}

if (!(guardPath < rpcPath)) fail("terminal guard migration must sort before RPC migration");

const protectedNames = [
  "shipper_record_package_receipt_v1",
  "customer_review_cycle_candidates_v1",
  "internal_materialize_customer_review_cycles_v1",
  "customer_review_receipt_materialize_v1",
  "shipper_tracking_review_state_v1",
  "shipper_shipment_batch_candidates_v1",
  "shipper_create_shipment_batch_v1",
  "shipper_shipment_batch_effective_lines_v1",
  "internal_customer_sales_release_sources_v1",
  "customer_sales_release_guard_v1",
  "customer_sales_release_financial_guard_v1",
  "customer_hold_create_refund_exception_v2",
  "customer_hold_refund_target_lines_v1",
  "create_replacement_child_order",
  "order_has_open_child_exceptions",
  "approve_vat_release",
  "mark_order_accounting_release_ready",
  "recompute_order_status",
  "order_reconciliation_vw",
];

for (const name of protectedNames) {
  const createPattern = new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:FUNCTION|VIEW)\\s+public\\.${name}\\b`, "i");
  if (createPattern.test(guard) || createPattern.test(rpc)) {
    fail(`protected existing object is created/replaced: ${name}`);
  }
}

const requiredRpcTokens = [
  "shipper_record_package_receipt_v2",
  "pg_advisory_xact_lock",
  "FOR UPDATE OF ots",
  "shipper-receipts/",
  "storage_object_path NOT LIKE v_evidence_prefix",
  "POSITION('..' IN x.storage_object_path) > 0",
  "receipt_state IS DISTINCT FROM 'finalised'",
  "v_prior_created_at + INTERVAL '1 microsecond'",
  "awaiting_importer_proposal",
  "awaiting_supervisor_review",
  "returned_for_information",
  "approved_for_investigation",
  "idempotent_retry",
];

for (const token of requiredRpcTokens) {
  if (!rpc.includes(token)) fail(`RPC missing required control: ${token}`);
}

if (rpc.includes("'approved_for_investigation',\n        'rejected'")) {
  fail("terminal review remains in RPC correction supersession list");
}

for (const token of [
  "approved_to_existing_exception",
  "rejected",
  "closed_no_action",
  "superseded",
  "Use controlled staff remediation",
]) {
  if (!guard.includes(token)) fail(`terminal correction guard missing: ${token}`);
}

if (!regression.trimEnd().endsWith("ROLLBACK;")) {
  fail("SQL regression must end with ROLLBACK");
}
if ((regression.match(/^BEGIN;$/gm) || []).length !== 1) {
  fail("SQL regression must contain one outer BEGIN");
}
if (/^COMMIT;$/m.test(regression)) {
  fail("SQL regression must not contain COMMIT");
}

for (const token of [
  "no feature flag",
  "does not activate",
  "must not create",
  "Build 3",
  "Build 4",
]) {
  if (!impact.toLowerCase().includes(token.toLowerCase())) {
    fail(`impact map missing boundary statement: ${token}`);
  }
}

console.log(`PASS: Build 2 receipt source regression passed for ${changed.length} files.`);
