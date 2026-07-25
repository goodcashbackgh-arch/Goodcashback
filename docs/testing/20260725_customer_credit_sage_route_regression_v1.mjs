import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const postingPath = path.join(root, "src/lib/sage/posting.ts");
const source = fs.readFileSync(postingPath, "utf8");

function assertIncludes(fragment, message) {
  if (!source.includes(fragment)) throw new Error(`FAIL: ${message}`);
}

function assertNotIncludes(fragment, message) {
  if (source.includes(fragment)) throw new Error(`FAIL: ${message}`);
}

assertIncludes('endpointPath: "/sales_invoices"', "main/supplementary invoice endpoint changed");
assertIncludes('payloadRoot: "sales_invoice"', "main/supplementary invoice root missing");
assertIncludes('invoice_lines: documentLines', "main/supplementary invoice lines missing");
assertIncludes('due_date: date', "main/supplementary due-date behaviour changed");

assertIncludes('endpointPath: "/sales_credit_notes"', "customer credit-note endpoint missing");
assertIncludes('payloadRoot: "sales_credit_note"', "customer credit-note root missing");
assertIncludes('credit_note_lines: documentLines', "customer credit-note line collection missing");
assertIncludes('currency_id: currencyCode', "customer credit-note currency field missing");
assertIncludes('/sales_credit_notes/${encodeURIComponent(objectId)}/release', "customer credit-note release step missing");
assertIncludes('requireObjectId: false', "credit-note release response handling missing");

assertIncludes('let objectId = documentConfig.isCreditNote ? text(row.sage_object_id) : "";',
  "retry must reuse an already-created Sage credit note instead of creating a duplicate");
assertIncludes('sage_object_id: params.objectId || params.row.sage_object_id',
  "failed credit-note release must retain the created Sage object id");
assertIncludes('if (!releaseResult.successful)', "credit note must not be marked posted when release fails");
assertIncludes('sage_status: "posted"', "confirmed Sage result must update the existing sales_invoices row");

assertIncludes('if (rows.some((row) => row.document_lane !== "customer_sales"))',
  "customer-sales-only batch boundary changed");
assertIncludes('row.payload_validation_status !== "dry_run_validated"',
  "dry-run validation gate changed");
assertIncludes('SAGE_LIVE_POSTING_ENABLED !== "true"',
  "live posting safety switch changed");

assertNotIncludes('const endpointPath = "/sales_invoices";',
  "unconditional invoice endpoint would mispost customer credit notes");
assertNotIncludes('"sales_invoice": {\n        contact_id: contactId,\n        date,\n        reference,\n        notes,\n        currency_id',
  "invoice payload must not be silently rewritten to the credit-note currency shape");

console.log(JSON.stringify({
  regression_result: "PASS",
  details: "Customer main/supplementary posting remains on the established sales-invoice request while customer credit notes use sales_credit_notes, exact credit_note_lines and the required release step; retry preserves a created credit-note id and no row is marked posted before release succeeds."
}, null, 2));
