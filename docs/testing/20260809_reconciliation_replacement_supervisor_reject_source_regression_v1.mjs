import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const files = {
  supervisorPage: path.join(root, "app/internal/exceptions/[dispute_id]/page.tsx"),
  supervisorActions: path.join(root, "app/internal/exceptions/[dispute_id]/actions.ts"),
  importerPage: path.join(root, "app/importer/exceptions/[dispute_id]/page.tsx"),
  importerActions: path.join(root, "app/importer/exceptions/[dispute_id]/actions.ts"),
  governingAddendum: path.join(root, "docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_1.md"),
};

for (const file of Object.values(files)) {
  if (!fs.existsSync(file)) throw new Error(`Missing governed file: ${path.relative(root, file)}`);
}

const supervisorPage = fs.readFileSync(files.supervisorPage, "utf8");
const supervisorActions = fs.readFileSync(files.supervisorActions, "utf8");
const importerPage = fs.readFileSync(files.importerPage, "utf8");
const importerActions = fs.readFileSync(files.importerActions, "utf8");
const governingAddendum = fs.readFileSync(files.governingAddendum, "utf8");

function requireText(source, text, label = text) {
  if (!source.includes(text)) throw new Error(`Missing required source contract: ${label}`);
}

function forbidText(source, text, label = text) {
  if (source.includes(text)) throw new Error(`Forbidden source scope found: ${label}`);
}

const predicate = 'stage_detected === "at_reconciliation" && dispute.desired_outcome === "replacement"';
const importerPredicate = 'accessGuard.dispute.stage_detected === "at_reconciliation" && accessGuard.dispute.desired_outcome === "replacement"';

requireText(governingAddendum, "## 3. Four-part layered guard");
requireText(governingAddendum, "No broader redesign is authorised.");

requireText(supervisorPage, 'const isReconciliationReplacement = dispute.stage_detected === "at_reconciliation" && dispute.desired_outcome === "replacement";');
requireText(supervisorPage, "rejectReconciliationReplacementAction");
requireText(supervisorPage, "Reject replacement — return to invoice reconciliation");
requireText(supervisorPage, ") : isReconciliationReplacement ? (");
requireText(supervisorPage, ") : (\n              <form action={acceptReplacementOutcomeAction}", "normal replacements retain accept path after reconciliation guard");

requireText(supervisorActions, 'if (dispute.stage_detected !== "at_reconciliation" || dispute.desired_outcome !== "replacement")');
requireText(supervisorActions, 'if (dispute.stage_detected === "at_reconciliation")');
requireText(supervisorActions, "rejectReconciliationReplacementAction");
requireText(supervisorActions, '.from("dispute_messages")');
requireText(supervisorActions, '.from("dispute_lines")\n    .delete()');
requireText(supervisorActions, '.from("disputes").delete()');
requireText(supervisorActions, "staff_accept_replacement_outcome_v1");

const acceptFunctionStart = supervisorActions.indexOf("export async function acceptReplacementOutcomeAction");
const acceptGuardIndex = supervisorActions.indexOf('if (dispute.stage_detected === "at_reconciliation")', acceptFunctionStart);
const retailerGuardIndex = supervisorActions.indexOf("requireRetailerMessageAndAcceptedOutcome", acceptFunctionStart);
const replacementRpcIndex = supervisorActions.indexOf('rpc("staff_accept_replacement_outcome_v1"', acceptFunctionStart);
if (acceptFunctionStart < 0 || acceptGuardIndex < 0 || retailerGuardIndex < 0 || replacementRpcIndex < 0) {
  throw new Error("Could not prove supervisor accept action guard ordering.");
}
if (!(acceptGuardIndex < retailerGuardIndex && retailerGuardIndex < replacementRpcIndex)) {
  throw new Error("Supervisor reconciliation-replacement guard must run before retailer validation and replacement RPC.");
}

requireText(importerPage, 'const isReconciliationReplacement = dispute.stage_detected === "at_reconciliation" && dispute.desired_outcome === "replacement";');
requireText(importerPage, "Replacement was raised from invoice reconciliation and is awaiting supervisor review. Continue through invoice reconciliation if rejected.");
requireText(importerPage, "{isReconciliationReplacement ? (");
requireText(importerPage, "<form action={saveRetailerUpdateAction}", "normal exception lanes retain retailer update form");

requireText(importerActions, importerPredicate);
const saveFunctionStart = importerActions.indexOf("export async function saveRetailerUpdateAction");
const importerGuardIndex = importerActions.indexOf(importerPredicate, saveFunctionStart);
const retailerRpcIndex = importerActions.indexOf('rpc("operator_update_dispute_retailer_update"', saveFunctionStart);
if (saveFunctionStart < 0 || importerGuardIndex < 0 || retailerRpcIndex < 0 || importerGuardIndex >= retailerRpcIndex) {
  throw new Error("Importer reconciliation-replacement guard must run before retailer-update RPC.");
}

for (const source of [supervisorPage, supervisorActions, importerPage, importerActions]) {
  forbidText(source, "CREATE TABLE", "no schema creation in application patch");
  forbidText(source, "ALTER TABLE", "no schema alteration in application patch");
}

for (const forbidden of [
  "physical_replacement_same_order_routes",
  "operator_allocate_same_order_replacement_tracking_v1",
  "staff_accept_same_order_free_replacement_v1",
]) {
  forbidText(`${supervisorPage}\n${supervisorActions}\n${importerPage}\n${importerActions}`, forbidden, `no physical replacement scope: ${forbidden}`);
}

const supervisorAcceptRpcCount = (supervisorActions.match(/staff_accept_replacement_outcome_v1/g) ?? []).length;
if (supervisorAcceptRpcCount !== 1) {
  throw new Error(`Existing replacement acceptance authority should remain a single untouched call site; found ${supervisorAcceptRpcCount}.`);
}

console.log(JSON.stringify({
  result: "PASS",
  proof: "reconciliation-stage replacement is four-layer guarded while refunds and non-reconciliation replacements retain existing paths",
}, null, 2));
