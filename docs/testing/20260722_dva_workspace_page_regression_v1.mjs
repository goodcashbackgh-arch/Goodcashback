import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";

const pagePath = "app/internal/dva-reconciliation/workspace/page.tsx";
const actionPath = "app/internal/dva-reconciliation/actions.ts";
const navPath = "app/internal/DvaSupervisorFlowNav.tsx";

const page = readFileSync(pagePath, "utf8");
const actions = readFileSync(actionPath, "utf8");
const nav = readFileSync(navPath, "utf8");

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
assert.match(actions, /staff_allocate_statement_line_to_supplier_invoice_incremental_v1/, "supplier workflow must retain the existing incremental RPC route");
assert.equal(existsSync("app/internal/dva-reconciliation/workspace/actions.ts"), false, "duplicate workspace server action file must not exist");

assert.match(nav, /Importer matching/, "navigation must retain the single importer-matching workbench");
assert.doesNotMatch(nav, /Atomic Split OUT|Sequential OUT/, "navigation must not expose separate supplier workbench cards");

console.log("PASS: DVA workspace sequential supplier and FX/card page regression");
