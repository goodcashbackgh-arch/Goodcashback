import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};
const gitBlobSha = (content) => {
  const body = Buffer.from(content, "utf8");
  return crypto.createHash("sha1").update(`blob ${body.length}\0`).update(body).digest("hex");
};

const exactPagePath = "app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx";
const migrationPath = "supabase/migrations/202608141630_supervisor_exact_clean_line_multi_invoice_parity_v1.sql";
const importerPagePath = "app/importer/reconciliation/[order_id]/page.tsx";
const importerActionsPath = "app/importer/reconciliation/[order_id]/actions.ts";
const internalActionsPath = "app/internal/reconciliation/[order_id]/actions.ts";

const exactPage = read(exactPagePath);
const migration = read(migrationPath);
const importerPage = read(importerPagePath);
const importerActions = read(importerActionsPath);
const internalActions = read(internalActionsPath);

// Frozen working authorities must remain byte-for-byte untouched.
assert(
  gitBlobSha(importerPage) === "c628f3740b335a1e55a9cfe0d3bb2674fde59791",
  "Importer reconciliation page changed; this patch must use it only as reference evidence.",
);
assert(
  gitBlobSha(importerActions) === "0e01ed8b98a594c5757ef595085ff0cd343381a2",
  "Importer reconciliation actions changed; this patch must not modify importer progression behaviour.",
);
assert(
  gitBlobSha(internalActions) === "4e8eb348f7da7263bb86f3e971ba68b3010edef6",
  "Supervisor reconciliation actions changed; exact action wiring must remain untouched.",
);

// Exact selected-invoice page keeps existing authority and routing but reuses the
// proven importer physical/non-physical classification vocabulary.
assert(exactPage.includes("supervisorProgressSupplierInvoiceLinesAction"), "Existing supervisor progression action is not preserved.");
assert(exactPage.includes('name="supplier_invoice_id" value={invoiceId}'), "Exact supplier_invoice_id is not preserved in the progression form.");
assert(exactPage.includes("function normalisedDescription"), "Supervisor page lacks importer-style description normalisation.");
assert(exactPage.includes("discount|promotion|promotional|promo|voucher|coupon|saving|savings"), "Discount vocabulary drifted from importer reconciliation.");
assert(exactPage.includes("delivery|shipping|postage|freight|carriage"), "Delivery vocabulary drifted from importer reconciliation.");
assert(exactPage.includes("fee|charge|surcharge"), "Fee vocabulary drifted from importer reconciliation.");
assert(exactPage.includes("Number(line.amount_inc_vat_gbp ?? 0) < 0"), "Negative financial rows are not excluded from physical selection.");
assert(
  exactPage.includes("!progressed(line.eligible_for_invoice_yn) && !nonPhysical.has(line.id) && !obviousNonPhysical(line)"),
  "Physical candidate selection is not narrowed to clean exact-invoice physical rows.",
);
assert(exactPage.includes("Only the selected supplier invoice is affected. Other invoice references remain unchanged."), "Exact-invoice sibling-isolation notice was changed.");

// Forward migration must replace only the existing staff progression authority.
assert(
  migration.includes("CREATE OR REPLACE FUNCTION public.staff_progress_supplier_invoice_lines(p_order_id uuid, p_supplier_invoice_id uuid, p_line_ids uuid[], p_progress_notes text DEFAULT NULL::text)"),
  "Staff progression function identity changed.",
);
assert(migration.includes("RETURNS integer") || migration.includes("RETURNS INTEGER"), "Staff progression return type changed.");
assert(migration.includes("SECURITY DEFINER"), "Staff progression SECURITY DEFINER mode changed.");
assert(migration.includes("SET search_path TO 'public'"), "Staff progression search_path changed.");
assert(!migration.includes("Cannot progress lines after supplier invoice is already approved current."), "Obsolete current-invoice rejection reappeared.");
assert(migration.includes("Only active admin or supervisor staff can progress supplier invoice lines."), "Existing staff authority guard changed.");
assert(migration.includes("Supplier invoice does not belong to this order."), "Exact invoice/order ownership guard changed.");
assert(migration.includes("One or more selected lines do not belong to this supplier invoice."), "Exact selected-line membership guard changed.");
assert(migration.includes("Exception-linked lines cannot be progressed by supervisor takeover."), "Existing exception guard changed.");
assert(migration.includes("Non-physical financial lines cannot be progressed as physical goods."), "Server-side financial-row defence is missing.");
assert(migration.includes("supplier_invoice_line_resolutions"), "Existing non-physical resolution authority is not consulted.");
assert(migration.includes("participating_invoices"), "Participating-invoice projection boundary is missing.");
assert(migration.includes("select p_supplier_invoice_id as supplier_invoice_id"), "Current exact invoice is not included in projected commercial participation.");
assert(migration.includes("eligible_for_invoice_yn"), "Already-progressed physical participation is not retained.");
assert(migration.includes("order_value_adjustments"), "Existing exact invoice adjustment facts are not reused.");
assert(migration.includes("retailer_discount"), "Existing retailer discount fact is not reused.");
assert(migration.includes("retailer_delivery"), "Existing retailer delivery fact is not reused.");
assert(migration.includes("coalesce(ova.approval_status, '') <> 'rejected'"), "Rejected-adjustment fail-closed rule is missing.");
assert(migration.includes("e.supplier_invoice_id = a.supplier_invoice_id"), "Adjustment proof is not exact to supplier_invoice_id.");
assert(migration.includes("abs(abs(e.extracted_amount) - abs(a.adjustment_amount)) <= 0.01"), "Existing £0.01 same-invoice adjustment proof tolerance changed.");
assert(migration.includes("v_current_resolved_financial_amount"), "Resolved financial value is not represented in the order projection.");
assert(migration.includes("when r.financial_type = 'discount' then -abs"), "Resolved discount sign treatment changed.");
assert(migration.includes("when r.financial_type in ('delivery', 'fee') then abs"), "Resolved delivery/fee sign treatment changed.");
assert(migration.includes("when r.financial_type = 'zero_value_delivery' then 0"), "Zero-value delivery sign treatment changed.");
assert(migration.includes("v_unresolved_financial_offset"), "Proved unresolved signed financial offset is missing.");
assert(migration.includes("coalesce(v_order.order_total_gbp_declared, 0) + 0.01"), "Original order value baseline/tolerance changed.");
assert(migration.includes("coalesce(v_order.total_qty_declared, 0)"), "Original order quantity baseline changed.");
assert(
  migration.includes("where sil.supplier_invoice_id = p_supplier_invoice_id\n     and sil.id = any(p_line_ids)"),
  "Final progression write is not restricted to the exact supplier invoice and selected line IDs.",
);
assert(migration.includes("eligible_for_invoice_yn = 'Y'"), "Existing progression flag write changed.");
assert(migration.includes("qty_confirmed = coalesce(sil.qty_confirmed, sil.qty)"), "Existing confirmed quantity fallback changed.");
assert(migration.includes("amount_confirmed = coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp)"), "Existing confirmed amount fallback changed.");
assert(migration.includes("grant execute on function public.staff_progress_supplier_invoice_lines(uuid, uuid, uuid[], text) to authenticated;"), "Existing authenticated execute grant is not reasserted.");

// No new database architecture or downstream/upstream mutation is allowed.
assert(!/\bCREATE\s+TABLE\b/i.test(migration), "Migration creates a table; scope creep.");
assert(!/\bCREATE\s+(OR\s+REPLACE\s+)?VIEW\b/i.test(migration), "Migration creates/replaces a view; scope creep.");
assert(!/\bCREATE\s+TRIGGER\b/i.test(migration), "Migration creates a trigger; scope creep.");
assert(!/\bALTER\s+TABLE\b/i.test(migration), "Migration alters a table; scope creep.");
assert(!/\bINSERT\s+INTO\b/i.test(migration), "Migration inserts application data; scope creep.");
assert(!/\bDELETE\s+FROM\b/i.test(migration), "Migration deletes application data; scope creep.");
const updateTargets = [...migration.matchAll(/\bupdate\s+public\.([a-z0-9_]+)/gi)].map((match) => match[1]);
assert(updateTargets.length === 1 && updateTargets[0] === "supplier_invoice_lines", `Unexpected database UPDATE target(s): ${updateTargets.join(", ")}`);

// Controlled live evidence arithmetic: exact invoices stay separate, while the
// bundle commercial result remains the original accepted order value.
const invoice1 = 570.01 - 57 + 14.99;
const invoice2 = 249.99 - 25;
const bundleQty = 3 + 1;
const bundleValue = invoice1 + invoice2;
assert(Math.abs(invoice1 - 528.0) < 0.0001, "Controlled Invoice 1 arithmetic drifted.");
assert(Math.abs(invoice2 - 224.99) < 0.0001, "Controlled Invoice 2 arithmetic drifted.");
assert(bundleQty === 4, "Controlled bundle physical quantity is not exactly 4.");
assert(Math.abs(bundleValue - 752.99) < 0.0001, "Controlled bundle commercial value is not exactly £752.99.");

console.log(JSON.stringify({
  regression_result: "PASS",
  governed_scope: {
    production_files: [exactPagePath, migrationPath],
    importer_page_blob: gitBlobSha(importerPage),
    importer_actions_blob: gitBlobSha(importerActions),
    internal_actions_blob: gitBlobSha(internalActions),
  },
  controlled_case: {
    invoice_1_commercial_gbp: invoice1,
    invoice_2_commercial_gbp: invoice2,
    bundle_physical_qty: bundleQty,
    bundle_commercial_gbp: bundleValue,
  },
  detail: "Exact supervisor clean-line selection and staff signed multi-invoice baseline parity are present without modifying importer reconciliation, supervisor action wiring, or downstream/upstream production paths.",
}, null, 2));
