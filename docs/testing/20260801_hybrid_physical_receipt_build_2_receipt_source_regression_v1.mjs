import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const BASE = process.env.BASE_REF || "origin/main";
const TEMP_WORKFLOW = ".github/workflows/run-build-2-importer-source-regression.yml";

function run(command, args) {
  return execFileSync(command, args, { encoding: "utf8" }).trim();
}

function fail(message) {
  throw new Error(`FAIL: ${message}`);
}

const alignmentPath =
  "docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md";
const impactPath =
  "docs/implementation/20260801_hybrid_physical_receipt_build_2_impact_map_v1.md";
const guardPath =
  "supabase/migrations/20260801139900_hybrid_physical_receipt_v2_terminal_correction_guard_v1.sql";
const receiptRpcPath =
  "supabase/migrations/20260801140000_hybrid_physical_receipt_v2_rpc_v1.sql";
const importerRpcPath =
  "supabase/migrations/20260801141000_hybrid_physical_receipt_importer_proposal_rpc_v1.sql";
const compatibilityPath =
  "supabase/migrations/20260801142000_hybrid_physical_receipt_dispute_compatibility_v1.sql";
const supervisorRpcPath =
  "supabase/migrations/20260801143000_hybrid_physical_receipt_supervisor_initial_decision_rpc_v1.sql";
const privilegeFixPath =
  "supabase/migrations/20260801143100_hybrid_physical_receipt_supervisor_rpc_privilege_fix_v1.sql";
const receiptRegressionPath =
  "docs/testing/20260801_hybrid_physical_receipt_build_2_receipt_regression_v2.sql";
const importerRegressionPath =
  "docs/testing/20260801_hybrid_physical_receipt_build_2_importer_proposal_regression_v1.sql";
const supervisorRegressionPath =
  "docs/testing/20260801_hybrid_physical_receipt_build_2_supervisor_decision_regression_v1.sql";

const allowed = new Set([
  alignmentPath,
  impactPath,
  guardPath,
  receiptRpcPath,
  importerRpcPath,
  compatibilityPath,
  supervisorRpcPath,
  privilegeFixPath,
  receiptRegressionPath,
  importerRegressionPath,
  supervisorRegressionPath,
  "docs/testing/20260801_hybrid_physical_receipt_build_2_receipt_source_regression_v1.mjs",
]);

const changed = run("git", ["diff", "--name-only", `${BASE}...HEAD`])
  .split("\n")
  .filter(Boolean)
  .filter((file) => !(file === TEMP_WORKFLOW && !existsSync(TEMP_WORKFLOW)));

for (const file of changed) {
  if (!allowed.has(file)) fail(`unexpected changed file: ${file}`);
}

for (const file of allowed) {
  if (!changed.includes(file)) fail(`required Build 2 file missing from diff: ${file}`);
}

const alignment = readFileSync(alignmentPath, "utf8");
const impact = readFileSync(impactPath, "utf8");
const guard = readFileSync(guardPath, "utf8");
const receiptRpc = readFileSync(receiptRpcPath, "utf8");
const importerRpc = readFileSync(importerRpcPath, "utf8");
const compatibility = readFileSync(compatibilityPath, "utf8");
const supervisorRpc = readFileSync(supervisorRpcPath, "utf8");
const privilegeFix = readFileSync(privilegeFixPath, "utf8");
const receiptRegression = readFileSync(receiptRegressionPath, "utf8");
const importerRegression = readFileSync(importerRegressionPath, "utf8");
const supervisorRegression = readFileSync(supervisorRegressionPath, "utf8");

for (const [path, text] of [
  [guardPath, guard],
  [receiptRpcPath, receiptRpc],
  [importerRpcPath, importerRpc],
  [compatibilityPath, compatibility],
  [supervisorRpcPath, supervisorRpc],
  [privilegeFixPath, privilegeFix],
]) {
  const beginCount = (text.match(/^BEGIN;$/gm) || []).length;
  const commitCount = (text.match(/^COMMIT;$/gm) || []).length;
  if (beginCount !== 1 || commitCount !== 1) {
    fail(`${path} must contain exactly one outer BEGIN and COMMIT`);
  }
  if (/\bDROP\s+(TABLE|VIEW|FUNCTION|SCHEMA)\b/i.test(text)) {
    fail(`${path} contains destructive DROP`);
  }
  if (/\bCASCADE\b/i.test(text)) fail(`${path} contains CASCADE`);
}

for (const [path, text] of [
  [guardPath, guard],
  [receiptRpcPath, receiptRpc],
  [importerRpcPath, importerRpc],
  [supervisorRpcPath, supervisorRpc],
]) {
  if (/CREATE\s+OR\s+REPLACE/i.test(text)) {
    fail(`${path} replaces an existing object`);
  }
}

const replacements =
  compatibility.match(/CREATE\s+OR\s+REPLACE\s+FUNCTION/gi) || [];
if (replacements.length !== 1) {
  fail("compatibility migration must replace exactly one audited function");
}
if (
  !/CREATE\s+OR\s+REPLACE\s+FUNCTION\s+public\.physical_remedy_allocation_guard_v1\s*\(\s*\)/i.test(
    compatibility,
  )
) {
  fail("compatibility migration replaces an unaudited object");
}

if (
  !(
    guardPath < receiptRpcPath &&
    receiptRpcPath < importerRpcPath &&
    importerRpcPath < compatibilityPath &&
    compatibilityPath < supervisorRpcPath &&
    supervisorRpcPath < privilegeFixPath
  )
) {
  fail(
    "Build 2 migrations are not ordered guard -> receipt -> importer -> compatibility -> supervisor -> privilege fix",
  );
}

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
  const createPattern = new RegExp(
    `CREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:FUNCTION|VIEW)\\s+public\\.${name}\\b`,
    "i",
  );
  for (const text of [guard, receiptRpc, importerRpc, compatibility, supervisorRpc]) {
    if (createPattern.test(text)) {
      fail(`protected existing object is created/replaced: ${name}`);
    }
  }
}

for (const token of [
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
]) {
  if (!receiptRpc.includes(token)) {
    fail(`receipt RPC missing required control: ${token}`);
  }
}

if (receiptRpc.includes("'approved_for_investigation',\n        'rejected'")) {
  fail("terminal review remains in receipt RPC correction supersession list");
}

for (const token of [
  "approved_to_existing_exception",
  "rejected",
  "closed_no_action",
  "superseded",
  "Use controlled staff remediation",
]) {
  if (!guard.includes(token)) {
    fail(`terminal correction guard missing: ${token}`);
  }
}

for (const token of [
  "operator_submit_physical_receipt_proposal_v1",
  "importer_proposal_note",
  "auth.uid()",
  "operator_importers",
  "revoked_at IS NULL",
  "pg_advisory_xact_lock",
  "awaiting_importer_proposal",
  "returned_for_information",
  "awaiting_supervisor_review",
  "SET status = 'cancelled'",
  "proposed_remedy_qty",
  "> disposition.quantity + 0.0005",
]) {
  if (!importerRpc.includes(token)) {
    fail(`importer RPC missing required control: ${token}`);
  }
}

for (const prohibited of [
  "approved_remedy_type =",
  "approved_remedy_qty =",
  "approved_by_staff_id =",
  "linked_dispute_id =",
  "supplier_claim_amount_gbp =",
  "customer_commercial_value_gbp =",
  "supplier_cost_mode =",
  "replacement_child_order_id =",
  "DELETE FROM public.physical_exception_remedy_allocations",
  "SET status = 'superseded'",
]) {
  if (importerRpc.includes(prohibited)) {
    fail(`importer RPC writes prohibited fact: ${prohibited}`);
  }
}

for (const token of [
  "physical_remedy_allocation_id",
  "physical_receipt_review_dispute_links",
  "uq_dispute_lines_open_legacy",
  "uq_dispute_lines_open_physical",
  "physical_review_dispute_link_guard_v1",
  "physical_dispute_line_guard_v1",
  "Physical review/dispute links are immutable",
  "approved whole-unit remedy",
  "physical_receipt_review_dispute_links link_row",
]) {
  if (!compatibility.includes(token)) {
    fail(`compatibility migration missing required control: ${token}`);
  }
}

for (const token of [
  "staff_decide_physical_receipt_review_v1",
  "awaiting_supervisor_review",
  "return_for_information",
  "approve_existing_exception",
  "Every active importer proposal row must be explicitly decided",
  "Return for information if a different split is required",
  "Fractional quantities are not rounded",
  "physical_remedy_allocation_id IS NULL",
  "at_ghana_delivery",
  "physical_receipt_review_dispute_links",
  "CASE link_row.desired_outcome",
  "linked_to_exception",
]) {
  if (!supervisorRpc.includes(token)) {
    fail(`supervisor RPC missing required control: ${token}`);
  }
}

for (const token of [
  "staff_decide_physical_receipt_review_v1",
  "FROM PUBLIC, anon",
  "TO authenticated",
]) {
  if (!privilegeFix.includes(token)) {
    fail(`supervisor privilege fix missing required control: ${token}`);
  }
}

for (const prohibited of [
  "DELETE FROM public.physical_exception_remedy_allocations",
  "create_replacement_child_order(",
  "replacement_child_order_id =",
  "customer_commercial_value_gbp =",
  "supplier_claim_amount_gbp =",
  "status = 'refunded'",
  "status = 'replaced'",
]) {
  if (supervisorRpc.includes(prohibited)) {
    fail(`supervisor RPC writes prohibited completion fact: ${prohibited}`);
  }
}

for (const [path, text] of [
  [receiptRegressionPath, receiptRegression],
  [importerRegressionPath, importerRegression],
  [supervisorRegressionPath, supervisorRegression],
]) {
  if (!text.trimEnd().endsWith("ROLLBACK;")) {
    fail(`${path} must end with ROLLBACK`);
  }
  if ((text.match(/^BEGIN;$/gm) || []).length !== 1) {
    fail(`${path} must contain one outer BEGIN`);
  }
  if (/^COMMIT;$/m.test(text)) fail(`${path} must not contain COMMIT`);
}

for (const token of [
  "HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md",
  "HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md",
  "does not activate",
  "no feature flag",
  "fractional refund/replacement approval fails closed",
  "separate refund and replacement disputes",
  "legacy unresolved-line uniqueness remains effective",
  "must not widen `dispute_lines.qty_impact`",
]) {
  if (!impact.toLowerCase().includes(token.toLowerCase())) {
    fail(`impact map missing aligned boundary statement: ${token}`);
  }
}

for (const token of [
  "Where this document is more specific",
  "dispute_lines.qty_impact` is `integer",
  "must reject any such quantity",
  "must not be combined in one dispute",
  "many-link structure",
  "physical_remedy_allocation_id",
  "legacy unresolved dispute lines",
  "refund precedes replacement",
  "no fractional quantity may be silently rounded",
]) {
  if (!alignment.includes(token)) {
    fail(`alignment addendum missing governing decision: ${token}`);
  }
}

console.log(`PASS: Build 2 source regression passed for ${changed.length} files.`);
