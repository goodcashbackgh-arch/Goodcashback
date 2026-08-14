import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const assert = (condition, message) => { if (!condition) throw new Error(message); };
const gitBlobSha = (content) => {
  const body = Buffer.from(content, "utf8");
  return crypto.createHash("sha1").update(`blob ${body.length}\0`).update(body).digest("hex");
};

const authorityPath = "docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1_4.md";
const exactPagePath = "app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx";
const internalActionsPath = "app/internal/reconciliation/[order_id]/actions.ts";
const importerPagePath = "app/importer/reconciliation/[order_id]/page.tsx";
const importerActionsPath = "app/importer/reconciliation/[order_id]/actions.ts";
const importerNonPhysicalPath = "app/importer/reconciliation/[order_id]/nonPhysicalActions.ts";
const bulkControlsPath = "app/importer/reconciliation/[order_id]/BulkLineSelectionControls.tsx";
const accountingPagePath = "app/internal/reconciliation/[order_id]/page.tsx";
const v13MigrationPath = "supabase/migrations/202608141700_supervisor_progressed_selection_baseline_guard_v1.sql";

const authority = read(authorityPath);
const exactPage = read(exactPagePath);
const internalActions = read(internalActionsPath);
const importerPage = read(importerPagePath);
const importerActions = read(importerActionsPath);
const importerNonPhysical = read(importerNonPhysicalPath);
const bulkControls = read(bulkControlsPath);
const accountingPage = read(accountingPagePath);
const v13Migration = read(v13MigrationPath);

// Governing authority must explicitly constrain the build.
for (const required of [
  "governing additive authority",
  "app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx",
  "app/internal/reconciliation/[order_id]/actions.ts",
  "No other production file is authorised to change.",
  "No SQL migration is authorised.",
  "The all-line review list must render independently of `physicalCandidates.length`",
  "STOP",
]) assert(authority.includes(required), `Missing v1.4 governing control: ${required}`);

// Frozen working implementations must remain byte-for-byte unchanged.
assert(gitBlobSha(importerPage) === "c628f3740b335a1e55a9cfe0d3bb2674fde59791", "Importer reconciliation page changed.");
assert(gitBlobSha(importerActions) === "0e01ed8b98a594c5757ef595085ff0cd343381a2", "Importer reconciliation actions changed.");
assert(gitBlobSha(importerNonPhysical) === "ece9dc94445030be65b7a43e95ba21401044736b", "Importer non-physical action changed.");
assert(gitBlobSha(bulkControls) === "968565fb16edfe1b1fbd25154ce32e39ea33102f", "Importer bulk selection component changed.");
assert(gitBlobSha(accountingPage) === "d84f7ddb24aa7d9ed1c06c604b72e2a149f31afa", "Supervisor accounting page changed.");
assert(gitBlobSha(v13Migration) === "a5413ad41c485d03155b271e6e3451d1f205d117", "Governed v1.3 staff progression migration changed.");

// The exact supervisor page must port only the relevant importer-parity state/display pieces.
for (const required of [
  'BulkLineSelectionControls from "../../../../../importer/reconciliation/[order_id]/BulkLineSelectionControls"',
  'supervisorResolveSupplierInvoiceLineNonPhysicalAction } from "../../actions"',
  'type Search = { success?: string; error?: string }',
  'supplier_invoice_line_id, resolution_type, financial_type, notes',
  'disputes!inner(id, desired_outcome, resolved_at)',
  '.is("resolved_at", null)',
  'const resolutions = new Map',
  'const disputes = new Map<string, string>()',
  'const locked = Boolean(dispute || resolution)',
  'const classificationOnly = obviousNonPhysical(line)',
  'const suggestedType = suggestedFinancialType(line)',
  'invoiceLines.map((line) =>',
  'id="bulk-progress-form"',
  'form="bulk-progress-form"',
  'disabled={!canProgress}',
  '<BulkLineSelectionControls selectableCount={physicalCandidates.length} />',
  '!done && !locked',
  'Non-physical classification required',
  'It cannot enter physical progression, tracking or shipment.',
  'supervisorResolveSupplierInvoiceLineNonPhysicalAction',
]) assert(exactPage.includes(required), `Missing exact-page importer-parity contract: ${required}`);

// Existing description/sign vocabulary must stay aligned with importer.
for (const vocabulary of [
  "discount|promotion|promotional|promo|voucher|coupon|saving|savings",
  "delivery|shipping|postage|freight|carriage",
  "fee|charge|surcharge",
]) {
  assert(exactPage.includes(vocabulary), `Supervisor vocabulary missing: ${vocabulary}`);
  assert(importerPage.includes(vocabulary), `Importer reference vocabulary missing: ${vocabulary}`);
}
assert(exactPage.includes("Number(line.amount_inc_vat_gbp ?? 0) < 0"), "Negative-amount non-physical boundary missing from supervisor page.");

// Suggested financial type mapping and visible allow-list must match importer vocabulary.
for (const value of ["delivery", "discount", "fee", "zero_value_delivery", "rounding", "other_non_physical"]) {
  assert(exactPage.includes(`<option value="${value}">${value}</option>`), `Supervisor Park option missing: ${value}`);
  assert(importerNonPhysical.includes(`"${value}"`), `Importer action allow-list missing: ${value}`);
}
for (const mapping of [
  'if (isDiscountDescription(line.description)) return "discount";',
  'if (isDeliveryDescription(line.description)) return "delivery";',
  'if (isFeeDescription(line.description)) return "fee";',
  'return "other_non_physical";',
]) assert(exactPage.includes(mapping), `Suggested financial type drifted: ${mapping}`);

// Physical candidates stay supervisor-owned and must exclude progressed/parked/disputed/obvious financial rows.
for (const required of [
  "!progressed(line.eligible_for_invoice_yn)",
  "!resolutions.has(line.id)",
  "!disputes.has(line.id)",
  "!obviousNonPhysical(line)",
]) assert(exactPage.includes(required), `Physical candidate guard missing: ${required}`);
assert(!exactPage.includes("provedUnresolvedFinancialOffset"), "Importer order-baseline engine leaked into supervisor page.");
assert(!exactPage.includes("remainingQty"), "Importer quantity baseline leaked into supervisor page.");
assert(!exactPage.includes("remainingValue"), "Importer value baseline leaked into supervisor page.");

// All-line visibility must be independent from physicalCandidates availability.
const lineReviewIndex = exactPage.indexOf("Invoice line review");
const allLinesIndex = exactPage.indexOf("invoiceLines.map((line) =>");
const physicalActionIndex = exactPage.indexOf("Progress clean physical lines on this invoice");
assert(lineReviewIndex >= 0 && allLinesIndex > lineReviewIndex, "All-line review is missing.");
assert(physicalActionIndex > allLinesIndex, "Physical action block unexpectedly gates the all-line review list.");

// Park wrapper must be importer-parity plus exact supervisor route isolation only.
const parkStart = internalActions.indexOf("export async function supervisorResolveSupplierInvoiceLineNonPhysicalAction");
const parkEnd = internalActions.indexOf("export async function supervisorProgressSupplierInvoiceLinesAction", parkStart);
assert(parkStart >= 0 && parkEnd > parkStart, "Supervisor Park action not found.");
const parkAction = internalActions.slice(parkStart, parkEnd);
for (const required of [
  "requireSupervisorOrAdmin()",
  'from("supplier_invoices")',
  '.eq("id", invoiceId)',
  '.eq("order_id", orderId)',
  'from("supplier_invoice_lines")',
  '.eq("id", lineId)',
  '.eq("supplier_invoice_id", invoiceId)',
  'rpc("staff_resolve_supplier_invoice_line_non_physical"',
  "p_order_id: orderId",
  "p_supplier_invoice_line_id: lineId",
  "p_financial_type: financialType",
]) assert(parkAction.includes(required), `Park exact-authority guard missing: ${required}`);
assert(!parkAction.includes("operator_resolve_supplier_invoice_line_non_physical"), "Supervisor Park action calls importer/operator authority.");
assert(!parkAction.includes("obviousNonPhysical"), "New supervisor-only non-physical server classifier was introduced.");
assert(!/\.from\("supplier_invoice_line_resolutions"\)[\s\S]*\.(insert|update|delete)\(/.test(parkAction), "Park wrapper directly mutates resolution rows.");
assert(!/\.from\("supplier_invoice_lines"\)[\s\S]*\.(insert|update|delete)\(/.test(parkAction), "Park wrapper directly mutates supplier invoice lines.");

// The six-value action allow-list must exist and contain no extra value.
const allowListMatch = internalActions.match(/const ALLOWED_NON_PHYSICAL_FINANCIAL_TYPES = new Set\(\[([\s\S]*?)\]\);/);
assert(allowListMatch, "Supervisor Park allow-list missing.");
const allowValues = [...allowListMatch[1].matchAll(/"([a-z_]+)"/g)].map((match) => match[1]);
assert(JSON.stringify(allowValues) === JSON.stringify(["delivery", "discount", "fee", "zero_value_delivery", "rounding", "other_non_physical"]), `Supervisor Park allow-list drifted: ${allowValues.join(", ")}`);

// Existing physical progression wiring must remain present and unchanged in authority/routing semantics.
const progressStart = internalActions.indexOf("export async function supervisorProgressSupplierInvoiceLinesAction");
const progressEnd = internalActions.indexOf("export async function approveCurrentSupplierInvoiceFromReconciliationAction", progressStart);
assert(progressStart >= 0 && progressEnd > progressStart, "Existing supervisor progression action missing.");
const progressAction = internalActions.slice(progressStart, progressEnd);
for (const required of [
  'rpc("staff_progress_supplier_invoice_lines"',
  "p_order_id: orderId",
  "p_supplier_invoice_id: invoiceId",
  "p_line_ids: lineIds",
  "p_progress_notes: progressNotes || null",
  "Continue accounting coding.",
  "supplierInvoiceReconciliationHref(orderId, invoiceId",
]) assert(progressAction.includes(required), `Existing supervisor progression contract drifted: ${required}`);
assert(!progressAction.includes("staff_resolve_supplier_invoice_line_non_physical"), "Physical progression action was mixed with Park authority.");

console.log(JSON.stringify({
  regression_result: "PASS",
  governing_authority: authorityPath,
  exact_page: exactPagePath,
  park_action: "supervisorResolveSupplierInvoiceLineNonPhysicalAction",
  frozen_blobs: {
    importer_page: gitBlobSha(importerPage),
    importer_actions: gitBlobSha(importerActions),
    importer_non_physical: gitBlobSha(importerNonPhysical),
    importer_bulk_controls: gitBlobSha(bulkControls),
    accounting_page: gitBlobSha(accountingPage),
    v13_progression_migration: gitBlobSha(v13Migration),
  },
  scope: "Two production files only; importer/database/accounting/downstream paths frozen.",
}, null, 2));
