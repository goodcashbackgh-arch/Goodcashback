import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const BASE_REF = process.env.BASE_REF || "origin/main";

function fail(message) {
  console.error(`FAIL — ${message}`);
  process.exit(1);
}

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" });
}

function read(path) {
  return readFileSync(path, "utf8");
}

// This regression now runs on the cumulative Builds 1–4 branch. Do not reject
// later governed files merely because they sit outside the original Build 3
// first-slice file list. The protected Build 3 contracts below remain frozen.

const baselineShipperActions = git(["show", `${BASE_REF}:app/shipper/actions.ts`]);
const shipperActions = read("app/shipper/actions.ts");
if (shipperActions !== baselineShipperActions) {
  fail("Legacy app/shipper/actions.ts changed during the additive v2 slice.");
}
if (!shipperActions.includes('rpc("shipper_record_package_receipt_v1"')) {
  fail("Legacy shipper receipt action no longer calls shipper_record_package_receipt_v1.");
}
if (shipperActions.includes("shipper_record_package_receipt_v2")) {
  fail("Legacy shipper action file was coupled to the v2 authority.");
}

const v2Actions = read("app/shipper/package-receipts/v2/[tracking_submission_id]/actions.ts");
for (const required of [
  "recordExactPackageReceiptV2Action",
  'rpc("shipper_record_package_receipt_v2"',
  "p_tracking_submission_id",
  "p_receipt_submission_id",
  "p_dispositions",
  "p_evidence",
  "p_correction_of_receipt_id",
  "p_correction_reason",
  "tracking_line_allocation_id",
  "supplier_invoice_line_id",
  "storage_object_path",
]) {
  if (!v2Actions.includes(required)) fail(`V2 shipper action missing required contract: ${required}`);
}
if (v2Actions.includes("shipper_record_package_receipt_v1")) {
  fail("V2 shipper action calls the legacy v1 authority.");
}
if (/service_role|SUPABASE_SERVICE_ROLE_KEY/i.test(v2Actions)) {
  fail("V2 shipper action introduces service-role browser/server bypass access.");
}
if (/Math\.(round|floor|ceil|trunc)\s*\(/.test(v2Actions)) {
  fail("V2 shipper action rounds exact physical quantities.");
}

const importerPage = git(["show", `${BASE_REF}:app/importer/exceptions/[dispute_id]/page.tsx`]);
if (read("app/importer/exceptions/[dispute_id]/page.tsx") !== importerPage) {
  fail("Existing importer dispute page changed during the protected first shipper slice.");
}

const importerActions = git(["show", `${BASE_REF}:app/importer/exceptions/[dispute_id]/actions.ts`]);
if (read("app/importer/exceptions/[dispute_id]/actions.ts") !== importerActions) {
  fail("Existing importer dispute actions changed during the protected first shipper slice.");
}

const internalPage = git(["show", `${BASE_REF}:app/internal/exceptions/[dispute_id]/page.tsx`]);
if (read("app/internal/exceptions/[dispute_id]/page.tsx") !== internalPage) {
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

console.log("PASS — Build 3 protected workflow source contracts passed on cumulative branch");
