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

const migrationPath = "supabase/migrations/202608141700_supervisor_progressed_selection_baseline_guard_v1.sql";
const priorMigrationPath = "supabase/migrations/202608141630_supervisor_exact_clean_line_multi_invoice_parity_v1.sql";
const exactPagePath = "app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx";
const importerPagePath = "app/importer/reconciliation/[order_id]/page.tsx";
const importerActionsPath = "app/importer/reconciliation/[order_id]/actions.ts";
const internalActionsPath = "app/internal/reconciliation/[order_id]/actions.ts";

const migration = read(migrationPath);
const prior = read(priorMigrationPath);
const exactPage = read(exactPagePath);
const importerPage = read(importerPagePath);
const importerActions = read(importerActionsPath);
const internalActions = read(internalActionsPath);

// Frozen working application paths must remain untouched.
assert(gitBlobSha(importerPage) === "c628f3740b335a1e55a9cfe0d3bb2674fde59791", "Importer reconciliation page changed.");
assert(gitBlobSha(importerActions) === "0e01ed8b98a594c5757ef595085ff0cd343381a2", "Importer reconciliation actions changed.");
assert(gitBlobSha(internalActions) === "4e8eb348f7da7263bb86f3e971ba68b3010edef6", "Supervisor action wiring changed.");
assert(gitBlobSha(exactPage) === "b515d8e990987cc10bc113b1fa12c08d6c45a9a4", "Exact supervisor page changed in the edge-case correction.");

// Function contract/security/write semantics remain present.
for (const required of [
  "CREATE OR REPLACE FUNCTION public.staff_progress_supplier_invoice_lines(p_order_id uuid, p_supplier_invoice_id uuid, p_line_ids uuid[], p_progress_notes text DEFAULT NULL::text)",
  "RETURNS integer",
  "SECURITY DEFINER",
  "SET search_path TO 'public'",
  "Only active admin or supervisor staff can progress supplier invoice lines.",
  "Supplier invoice does not belong to this order.",
  "One or more selected lines do not belong to this supplier invoice.",
  "Exception-linked lines cannot be progressed by supervisor takeover.",
  "Non-physical financial lines cannot be progressed as physical goods.",
  "participating_invoices",
  "order_value_adjustments",
  "retailer_discount",
  "retailer_delivery",
  "coalesce(ova.approval_status, '') <> 'rejected'",
  "abs(abs(e.extracted_amount) - abs(a.adjustment_amount)) <= 0.01",
  "coalesce(v_order.total_qty_declared, 0)",
  "coalesce(v_order.order_total_gbp_declared, 0) + 0.01",
  "eligible_for_invoice_yn = 'Y'",
  "qty_confirmed = coalesce(sil.qty_confirmed, sil.qty)",
  "amount_confirmed = coalesce(sil.amount_confirmed, sil.amount_inc_vat_gbp)",
  "grant execute on function public.staff_progress_supplier_invoice_lines(uuid, uuid, uuid[], text) to authenticated;",
]) assert(migration.toLowerCase().includes(required.toLowerCase()), `Missing preserved contract: ${required}`);

// Exact defect/fix: prior function contained the exclusion; replacement must not.
const staleExclusion = "and not (sil.id = any(p_line_ids))";
assert(prior.includes(staleExclusion), "Expected defect predicate is not present in the prior governed migration.");
assert(!migration.includes(staleExclusion), "Already-progressed selected lines are still excluded from current progressed totals.");

// Selected proposal must remain new/unprogressed only.
assert(
  migration.includes("where sil.supplier_invoice_id = p_supplier_invoice_id\n    and sil.id = any(p_line_ids)\n    and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1');"),
  "Selected proposal no longer restricts itself to unprogressed selected lines.",
);

// Exact write restriction remains unchanged.
assert(
  migration.includes("where sil.supplier_invoice_id = p_supplier_invoice_id\n     and sil.id = any(p_line_ids)\n     and coalesce(lower(sil.eligible_for_invoice_yn), '') not in ('y', 'yes', 'true', '1');"),
  "Final progression write is not exact to selected invoice/unprogressed selected lines.",
);

// No schema/workflow expansion.
assert(!/\bCREATE\s+TABLE\b/i.test(migration), "Unexpected table creation.");
assert(!/\bCREATE\s+(OR\s+REPLACE\s+)?VIEW\b/i.test(migration), "Unexpected view creation.");
assert(!/\bCREATE\s+TRIGGER\b/i.test(migration), "Unexpected trigger creation.");
assert(!/\bALTER\s+TABLE\b/i.test(migration), "Unexpected table alteration.");
assert(!/\bINSERT\s+INTO\b/i.test(migration), "Unexpected data insert.");
assert(!/\bDELETE\s+FROM\b/i.test(migration), "Unexpected data delete.");
const updateTargets = [...migration.matchAll(/\bupdate\s+public\.([a-z0-9_]+)/gi)].map((m) => m[1]);
assert(updateTargets.length === 1 && updateTargets[0] === "supplier_invoice_lines", `Unexpected UPDATE target(s): ${updateTargets.join(", ")}`);

// Arithmetic regressions for the edge case.
const projectedQty = (alreadyProgressed, newlySelected) => alreadyProgressed + newlySelected;
assert(projectedQty(4, 2) === 6 && projectedQty(4, 2) > 4, "4 progressed + 2 new must block against baseline 4.");
assert(projectedQty(2, 2) === 4 && projectedQty(2, 2) <= 4, "2 progressed + 2 new must fit baseline 4.");
assert(projectedQty(4, 1) === 5 && projectedQty(4, 1) > 4, "Genuine fifth unit must block.");
assert(projectedQty(4, 0) === 4, "Already-progressed selected lines must not reduce the current position.");

const baselineValue = 752.99;
const tolerance = 0.01;
assert(753.01 > baselineValue + tolerance, "Genuine value excess must block above £0.01 tolerance.");
assert(753.00 <= baselineValue + tolerance, "Existing £0.01 tolerance changed.");

console.log(JSON.stringify({
  regression_result: "PASS",
  defect_removed: staleExclusion,
  frozen_application_blobs: {
    importer_page: gitBlobSha(importerPage),
    importer_actions: gitBlobSha(importerActions),
    internal_actions: gitBlobSha(internalActions),
    exact_supervisor_page: gitBlobSha(exactPage),
  },
  arithmetic: {
    mixed_stale_request: "4 already progressed + 2 new = 6 -> BLOCK against 4",
    normal_remaining_request: "2 already progressed + 2 new = 4 -> PASS against 4",
    genuine_fifth_unit: "4 already progressed + 1 new = 5 -> BLOCK against 4",
  },
  detail: "Only the staff RPC current-progressed undercount predicate is removed; application paths and downstream/upstream workflows remain unchanged.",
}, null, 2));
