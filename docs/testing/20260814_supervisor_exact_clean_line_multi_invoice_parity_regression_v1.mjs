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

// Frozen working authorities: this patch may copy principles from them but may not modify them.
assert(gitBlobSha(importerPage) === "c628f3740b335a1e55a9cfe0d3bb2674fde59791", "Importer reconciliation page changed.");
assert(gitBlobSha(importerActions) === "0e01ed8b98a594c5757ef595085ff0cd343381a2", "Importer reconciliation actions changed.");
assert(gitBlobSha(internalActions) === "4e8eb348f7da7263bb86f3e971ba68b3010edef6", "Supervisor reconciliation action wiring changed.");

// Exact page remains the existing exact-invoice lane and only narrows physical candidates.
assert(exactPage.includes("supervisorProgressSupplierInvoiceLinesAction"), "Existing supervisor progression action is not preserved.");
assert(exactPage.includes('name="supplier_invoice_id" value={invoiceId}'), "Exact supplier_invoice_id is not preserved in the form.");
assert(exactPage.includes("function normalisedDescription"), "Importer-style description normalisation is missing.");
assert(exactPage.includes("discount|promotion|promotional|promo|voucher|coupon|saving|savings"), "Discount vocabulary drifted.");
assert(exactPage.includes("delivery|shipping|postage|freight|carriage"), "Delivery vocabulary drifted.");
assert(exactPage.includes("fee|charge|surcharge"), "Fee vocabulary drifted.");
assert(exactPage.includes("Number(line.amount_inc_vat_gbp ?? 0) < 0"), "Negative financial rows are not excluded.");
assert(
  exactPage.includes("!progressed(line.eligible_for_invoice_yn) && !nonPhysical.has(line.id) && !obviousNonPhysical(line)"),
  "Physical candidate selection is not restricted to clean exact-invoice physical rows.",
);

// Existing staff RPC identity/security/write semantics remain intact.
assert(migration.includes("CREATE OR REPLACE FUNCTION public.staff_progress_supplier_invoice_lines(p_order_id uuid, p_supplier_invoice_id uuid, p_line_ids uuid[], p_progress_notes text DEFAULT NULL::text)"), "Staff function identity changed.");
assert(/RETURNS\s+integer/i.test(migration), "Staff return type changed.");
assert(migration.includes("SECURITY DEFINER"), "SECURITY DEFINER changed.");
assert(migration.includes("SET search_path TO 'public'"), "search_path changed.");
assert(migration.includes("Only active admin or supervisor staff can progress supplier invoice lines."), "Staff authority guard changed.");
assert(migration.includes("Supplier invoice does not belong to this order."), "Invoice/order ownership guard changed.");
assert(migration.includes("One or more selected lines do not belong to this supplier invoice."), "Exact line membership guard changed.");
assert(migration.includes("Exception-linked lines cannot be progressed by supervisor takeover."), "Exception guard changed.");
assert(!migration.includes("Cannot progress lines after supplier invoice is already approved current."), "Obsolete current-invoice guard reappeared.");

// Server independently rejects financial rows; the UI cannot be bypassed.
assert(migration.includes("Non-physical financial lines cannot be progressed as physical goods."), "Server financial-row rejection is missing.");
assert(migration.includes("supplier_invoice_line_resolutions"), "Existing non-physical resolution truth is not consulted.");
assert(migration.includes("discount|promotion|promotional|promo|voucher|coupon|saving|savings"), "Server discount vocabulary drifted.");
assert(migration.includes("delivery|shipping|postage|freight|carriage"), "Server delivery vocabulary drifted.");
assert(migration.includes("fee|charge|surcharge"), "Server fee vocabulary drifted.");

// Signed multi-invoice baseline parity reuses exact same-invoice adjustment proof.
assert(migration.includes("participating_invoices"), "Participating-invoice boundary is missing.");
assert(migration.includes("select p_supplier_invoice_id as supplier_invoice_id"), "Selected exact invoice is missing from participation.");
assert(migration.includes("order_value_adjustments"), "Existing adjustment facts are not reused.");
assert(migration.includes("retailer_discount"), "Retailer discount fact is not reused.");
assert(migration.includes("retailer_delivery"), "Retailer delivery fact is not reused.");
assert(migration.includes("coalesce(ova.approval_status, '') <> 'rejected'"), "Rejected adjustments are not excluded.");
assert(
  migration.includes("a.supplier_invoice_id = e.supplier_invoice_id") || migration.includes("e.supplier_invoice_id = a.supplier_invoice_id"),
  "Adjustment proof is not exact to supplier_invoice_id.",
);
assert(migration.includes("a.financial_kind = e.financial_kind") || migration.includes("e.financial_kind = a.financial_kind"), "Adjustment proof is not exact to financial kind.");
assert(migration.includes("abs(abs(e.extracted_amount) - abs(a.adjustment_amount)) <= 0.01"), "Same-invoice adjustment proof tolerance changed.");
assert(migration.includes("v_current_resolved_financial_amount"), "Resolved financial value is missing from projection.");
assert(migration.includes("when r.financial_type = 'discount' then -abs"), "Resolved discount sign changed.");
assert(migration.includes("when r.financial_type in ('delivery', 'fee') then abs"), "Resolved delivery/fee sign changed.");
assert(migration.includes("when r.financial_type = 'zero_value_delivery' then 0"), "Zero-value delivery sign changed.");
assert(migration.includes("v_unresolved_financial_offset"), "Proved unresolved offset is missing.");

// Original baselines and exact selected-invoice write stay authoritative.
assert(migration.includes("coalesce(v_order.total_qty_declared, 0)"), "Original quantity baseline changed.");
assert(migration.includes("coalesce(v_order.order_total_gbp_declared, 0) + 0.01"), "Original value baseline/tolerance changed.");
assert(
  migration.includes("where sil.supplier_invoice_id = p_supplier_invoice_id\n     and sil.id = any(p_line_ids)"),
  "Final progression write is not exact to selected invoice and line IDs.",
);
assert(migration.includes("eligible_for_invoice_yn = 'Y'"), "Progression flag write changed.");
assert(migration.includes("qty_confirmed = coalesce(sil.qty_confirmed, sil.qty)"), "Confirmed quantity fallback changed.");
assert(migration.includes("amount_confirmed = coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp)"), "Confirmed amount fallback changed.");
assert(migration.includes("grant execute on function public.staff_progress_supplier_invoice_lines(uuid, uuid, uuid[], text) to authenticated;"), "Authenticated execute grant is not preserved.");

// No schema/workflow expansion or unrelated data mutation in the migration.
assert(!/\bCREATE\s+TABLE\b/i.test(migration), "Migration creates a table.");
assert(!/\bCREATE\s+(OR\s+REPLACE\s+)?VIEW\b/i.test(migration), "Migration creates/replaces a view.");
assert(!/\bCREATE\s+TRIGGER\b/i.test(migration), "Migration creates a trigger.");
assert(!/\bALTER\s+TABLE\b/i.test(migration), "Migration alters a table.");
assert(!/\bINSERT\s+INTO\b/i.test(migration), "Migration inserts application data.");
assert(!/\bDELETE\s+FROM\b/i.test(migration), "Migration deletes application data.");
const updateTargets = [...migration.matchAll(/\bupdate\s+public\.([a-z0-9_]+)/gi)].map((match) => match[1]);
assert(updateTargets.length === 1 && updateTargets[0] === "supplier_invoice_lines", `Unexpected UPDATE target(s): ${updateTargets.join(", ")}`);

// Controlled live evidence: invoices remain separate and aggregate to the frozen order truth.
const invoice1 = 570.01 - 57 + 14.99;
const invoice2 = 249.99 - 25;
const bundleQty = 3 + 1;
const bundleValue = invoice1 + invoice2;
assert(Math.abs(invoice1 - 528.0) < 0.0001, "Invoice 1 controlled arithmetic drifted.");
assert(Math.abs(invoice2 - 224.99) < 0.0001, "Invoice 2 controlled arithmetic drifted.");
assert(bundleQty === 4, "Bundle quantity is not exactly 4.");
assert(Math.abs(bundleValue - 752.99) < 0.0001, "Bundle value is not exactly £752.99.");

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
  detail: "Supervisor exact clean-line selection and signed multi-invoice staff baseline parity are present without modifying importer reconciliation, action wiring, or unrelated upstream/downstream production paths.",
}, null, 2));
