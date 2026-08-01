import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const BASE_REF = process.env.BASE_REF || "origin/main";

function fail(message) {
  console.error(`FAIL — ${message}`);
  process.exit(1);
}

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

function read(path) {
  return readFileSync(path, "utf8");
}

const allowed = new Set([
  "docs/implementation/20260801_hybrid_physical_receipt_build_3_ui_activation_impact_map_v1.md",
  "docs/testing/20260801_hybrid_physical_receipt_build_3_ui_source_regression_v1.mjs",
  "docs/testing/20260801_hybrid_physical_receipt_build_3_shipper_entry_read_regression_v1.sql",
  "supabase/migrations/20260801150000_hybrid_physical_receipt_shipper_entry_read_v1.sql",
  "app/shipper/actions.ts",
  "app/shipper/package-receipts/page.tsx",
  "app/shipper/package-receipts/v2/[tracking_submission_id]/page.tsx",
  "app/shipper/package-receipts/v2/PhysicalReceiptV2Form.tsx",
]);

const changed = git(["diff", "--name-only", `${BASE_REF}...HEAD`])
  .split("\n")
  .map((value) => value.trim())
  .filter(Boolean);

for (const path of changed) {
  if (!allowed.has(path)) fail(`Build 3 changed file outside the approved first-slice boundary: ${path}`);
}

const shipperActions = read("app/shipper/actions.ts");
if (!shipperActions.includes('rpc("shipper_record_package_receipt_v1"')) {
  fail("Legacy shipper receipt action no longer calls shipper_record_package_receipt_v1.");
}
if (!shipperActions.includes("recordPackageReceiptAction")) {
  fail("Legacy recordPackageReceiptAction was removed.");
}

const importerPage = git(["show", `${BASE_REF}:app/importer/exceptions/[dispute_id]/page.tsx`]);
const currentImporterPage = read("app/importer/exceptions/[dispute_id]/page.tsx");
if (currentImporterPage !== importerPage) {
  fail("Existing importer dispute page changed during the protected first shipper slice.");
}

const importerActions = git(["show", `${BASE_REF}:app/importer/exceptions/[dispute_id]/actions.ts`]);
const currentImporterActions = read("app/importer/exceptions/[dispute_id]/actions.ts");
if (currentImporterActions !== importerActions) {
  fail("Existing importer dispute actions changed during the protected first shipper slice.");
}

const internalPage = git(["show", `${BASE_REF}:app/internal/exceptions/[dispute_id]/page.tsx`]);
const currentInternalPage = read("app/internal/exceptions/[dispute_id]/page.tsx");
if (currentInternalPage !== internalPage) {
  fail("Existing internal dispute page changed during the protected first shipper slice.");
}

const migration = read("supabase/migrations/20260801150000_hybrid_physical_receipt_shipper_entry_read_v1.sql");
for (const required of [
  "shipper_physical_receipt_entry_v1",
  "SECURITY DEFINER",
  "auth.uid()",
  "REVOKE ALL",
  "FROM PUBLIC, anon",
  "GRANT EXECUTE",
  "TO authenticated",
]) {
  if (!migration.includes(required)) fail(`Shipper entry read migration missing required contract: ${required}`);
}
if (/service_role/i.test(migration)) fail("Shipper entry read migration introduces service-role access.");

const forbiddenAuthorities = [
  "create_replacement_child_order",
  "order_has_open_child_exceptions",
  "order_reconciliation_vw",
  "operator_submit_physical_receipt_proposal_v1",
  "staff_decide_physical_receipt_review_v1",
];
for (const authority of forbiddenAuthorities) {
  if (migration.includes(`CREATE OR REPLACE FUNCTION public.${authority}`)
      || migration.includes(`CREATE OR REPLACE VIEW public.${authority}`)) {
    fail(`Build 3 read migration attempts to replace protected authority: ${authority}`);
  }
}

console.log("PASS — Build 3 first-slice file boundary and protected workflow source contracts passed");
