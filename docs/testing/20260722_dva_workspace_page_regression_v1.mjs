import assert from "node:assert/strict";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const pagePath = "app/internal/dva-reconciliation/workspace/page.tsx";
const actionPath = "app/internal/dva-reconciliation/actions.ts";
const sequentialActionPath = "app/internal/dva-reconciliation/sequential-allocation/actions.ts";
const controllerPath = "app/internal/dva-reconciliation/workspace/SafeWorkspaceSelectionController.tsx";
const atomicMigrationPath = "supabase/migrations/20260723a_supplier_bundle_incremental_atomic_v1.sql";
const navPath = "app/internal/DvaSupervisorFlowNav.tsx";

const page = readFileSync(pagePath, "utf8");
const actions = readFileSync(actionPath, "utf8");
const sequentialActions = readFileSync(sequentialActionPath, "utf8");
const controller = readFileSync(controllerPath, "utf8");
const atomicMigration = readFileSync(atomicMigrationPath, "utf8");
const nav = readFileSync(navPath, "utf8");
const incrementalRpc = "staff_allocate_statement_line_to_supplier_invoice_incremental_v";
const impossibleIncrementalRpc = `${incrementalRpc}1`;

function sourceFiles(root) {
  return readdirSync(root).flatMap((entry) => {
    const path = join(root, entry);
    return statSync(path).isDirectory()
      ? sourceFiles(path)
      : /\.(?:ts|tsx)$/.test(path)
        ? [path]
        : [];
  });
}

assert.match(
  page,
  /const selectedLine = selectedLineFromUrl \?\? filteredStatementLines\[0\] \?\? statementLines\[0\];/,
  "an explicit line_id must remain authoritative after its status changes",
);
assert.doesNotMatch(page, /selectedLineIsVisible/, "filter visibility must not replace an explicitly selected statement line");

assert.match(page, /Math\.min\(selectedStatementRemaining, selectedSupplierRemaining\)/, "supplier suggestion must be min(statement remaining, invoice remaining)");
assert.match(page, /name="allocated_gbp_amount" value=\{suggestedAllocation\.toFixed\(2\)\}/, "supplier hidden amount must use the suggested allocation");
assert.match(page, />Confirm supplier allocation<\/button>/, "supplier button wording must be the governed wording");
assert.doesNotMatch(page, /Allocate full OUT to supplier invoice/, "obsolete one-OUT-one-invoice wording must be absent");
assert.doesNotMatch(page, /num\(selectedLine\?\.active_allocation_count\)/, "existing supplier allocations must not block the next invoice leg");

assert.match(page, /form action=\{allocateStatementLineToFxCardOrFeeAction\}/, "existing FX/card button must call the existing server action");
assert.equal((page.match(/>Add FX\/card diff next<\/button>/g) ?? []).length, 1, "the existing action bar must expose exactly one FX/card button");
assert.match(page, /name="allocation_type" value="fx_card_difference"/, "FX/card residual must post the existing allocation type");
assert.match(page, /name="allocated_gbp_amount" value=\{selectedStatementRemaining\.toFixed\(2\)\}/, "FX/card residual must post the selected remaining amount");
assert.match(page, /text\(selectedLine\?\.direction\) === "out"/, "FX/card residual must require an OUT line");
assert.match(page, /selectedOperationalAllocation > 0/, "FX/card residual must require a confirmed operational allocation");
assert.match(page, /!bool\(selectedLine\?\.confirmed_balanced_yn\)/, "FX/card residual must be disabled for a balanced line");
assert.match(page, /num\(selectedLine\?\.supplier_invoice_allocated_gbp\)/, "supplier allocations must contribute to operational allocation state");
assert.match(page, /num\(selectedLine\?\.retailer_refund_allocated_gbp\)/, "retailer refunds must contribute to operational allocation state");
assert.match(page, /num\(selectedLine\?\.exception_or_hold_allocated_gbp\)/, "exceptions/holds must contribute to operational allocation state");

assert.match(actions, /supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, exception_or_hold_allocated_gbp/, "server action must read the operational allocation columns");
assert.match(actions, /confirmedOperationalAllocation <= 0/, "server action must enforce the same operational-allocation guard");
assert.match(actions, new RegExp(incrementalRpc), "single-invoice supplier workflow must call the registered incremental RPC");
assert.match(sequentialActions, new RegExp(incrementalRpc), "sequential workbench must call the registered incremental RPC");
assert.doesNotMatch(actions, new RegExp(impossibleIncrementalRpc), "main supplier action must not call the overlength identifier");
assert.doesNotMatch(sequentialActions, new RegExp(impossibleIncrementalRpc), "sequential workbench must not call the overlength identifier");
assert.equal(Buffer.byteLength(incrementalRpc, "utf8"), 63, "registered incremental RPC identifier must fit PostgreSQL's limit exactly");
assert.deepEqual(
  sourceFiles("app").filter((path) => readFileSync(path, "utf8").includes(impossibleIncrementalRpc)),
  [],
  "no frontend source file may call or reference the nonexistent overlength RPC name",
);
assert.match(actions, /if \(supplierInvoiceIds\.length === 1\)/, "one selected invoice must use the sequential branch");
assert.match(actions, /staff_allocate_statement_line_to_supplier_invoice_bundle/, "multiple selected invoices must use the existing atomic bundle RPC");
assert.match(controller, /targets\.size > 0/, "supplier confirmation must allow one or more selected targets");
assert.match(controller, /selectedSupplierTargets\.length === targets\.size/, "every selected target must be a supplier invoice");
assert.match(controller, /supplierAllocations\.length === targets\.size/, "every selected invoice must have a positive capped allocation");
assert.match(controller, /name="supplier_invoice_ids"/, "the same supplier form must submit every selected invoice");
assert.equal((controller.match(/Confirm supplier allocation/g) ?? []).length, 1, "controller must keep one governed supplier confirmation button");
assert.match(controller, /Bank selected: \{statements\.size\} · gross/, "existing bank footer totals must remain present");
assert.match(controller, /Operational selected: \{targets\.size\} · gross/, "existing operational footer totals must remain present");
assert.match(controller, /Net position gap:/, "existing net footer total must remain present");
assert.match(controller, /Absolute\/gross gap:/, "existing gross footer total must remain present");
assert.match(atomicMigration, /CREATE OR REPLACE FUNCTION public\.staff_allocate_statement_line_to_supplier_invoice_bundle/, "atomic migration must replace the controlled bundle RPC explicitly");
assert.doesNotMatch(atomicMigration, /pg_get_functiondef|v_bundle_definition|definition anchors/, "atomic migration must not depend on deparser text or formatting-sensitive anchors");
assert.match(atomicMigration, new RegExp(`to_regprocedure\\('public\\.${incrementalRpc}\\(uuid,uuid,numeric,text\\)'\\)`), "atomic migration must fail clearly when the incremental prerequisite is absent");
assert.match(atomicMigration, /v_requested_total > v_statement_total \+ 0\.005/, "atomic supplier total must not exceed the physical OUT");
assert.match(atomicMigration, /ARRAY_AGG\(si\.order_id ORDER BY si\.order_id\)/, "atomic bundle must select its UUID order without an unsupported UUID aggregate");
assert.match(atomicMigration, /ABS\(v_statement_total - v_requested_total\) < 0\.01/, "atomic result must expose a remaining residual as unbalanced");
assert.match(atomicMigration, /NOTIFY pgrst, 'reload schema'/, "successful migration must refresh the PostgREST schema cache");

const statementPence = 89000;
const invoicePence = [44998, 18499, 24999];
const supplierPence = invoicePence.reduce((total, remaining) => total + remaining, 0);
assert.equal(supplierPence, 88496, "A+B+C atomic supplier allocation must total £884.96");
assert.equal(statementPence - supplierPence, 504, "A+B+C must leave £5.04 for the existing FX/card path");
assert.equal(existsSync("app/internal/dva-reconciliation/workspace/actions.ts"), false, "duplicate workspace server action file must not exist");

assert.match(nav, /Importer matching/, "navigation must retain the single importer-matching workbench");
assert.doesNotMatch(nav, /Atomic Split OUT|Sequential OUT/, "navigation must not expose separate supplier workbench cards");

console.log("PASS: DVA workspace sequential supplier and FX/card page regression");
