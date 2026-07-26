import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const pagePath = "app/importer/reconciliation/[order_id]/page.tsx";
const bulkControlsPath = "app/importer/reconciliation/[order_id]/BulkLineSelectionControls.tsx";
const actionsPath = "app/importer/reconciliation/[order_id]/actions.ts";
const nonPhysicalActionsPath = "app/importer/reconciliation/[order_id]/nonPhysicalActions.ts";
const ocrRoutePath = "app/internal/invoice-review/safe-fetch-mindee/route.ts";
const signedOcrMigrationPath = "supabase/migrations/20260725_signed_ocr_nonphysical_to_sage_v1.sql";
const signedSageScopePath = "supabase/migrations/20260725z_signed_ocr_nonphysical_sage_scope_v1.sql";
const addendumPath = "docs/governing-pack/architecture/SIGNED_OCR_FINANCIAL_LINE_AND_SUPPLIER_AP_PAYLOAD_ADDENDUM_v1.md";

const page = readFileSync(pagePath, "utf8");
const bulkControls = readFileSync(bulkControlsPath, "utf8");
const actions = readFileSync(actionsPath, "utf8");
const nonPhysicalActions = readFileSync(nonPhysicalActionsPath, "utf8");
const ocrRoute = readFileSync(ocrRoutePath, "utf8");
const signedOcrMigration = readFileSync(signedOcrMigrationPath, "utf8");
const signedSageScope = readFileSync(signedSageScopePath, "utf8");
const addendum = readFileSync(addendumPath, "utf8");

// Internal source regression. This is not a Supabase SQL Editor script and is
// not a manual operator release step. It is retained under docs/testing as
// repository evidence for CI/developer execution only.
assert.match(page, /BulkLineSelectionControls selectableCount=\{selectable\.length\}/, "restored bulk selection controls must remain wired to the selectable set");
assert.match(page, /from\("order_value_adjustments"\).*select\("supplier_invoice_id, adjustment_type, amount_gbp, approval_status"\).*neq\("approval_status","rejected"\)/s, "the page must reuse accepted declared adjustment facts");
assert.match(page, /const isDeliveryDescription = .*delivery\|shipping\|postage\|freight\|carriage/s, "the page must reuse the established delivery description vocabulary");
assert.match(page, /const isDiscountDescription = .*discount\|promotion\|promotional\|promo\|voucher\|coupon\|saving\|savings/s, "the page must reuse the established discount description vocabulary");
assert.match(page, /const deliveryMatched=declaredDelivery>0&&extractedDelivery>0&&Math\.abs\(extractedDelivery-declaredDelivery\)<=0\.01;/, "delivery rows must be treated as proven financial rows only on exact declared-amount agreement");
assert.match(page, /const discountMatched=declaredDiscount>0&&extractedDiscount>0&&Math\.abs\(extractedDiscount-declaredDiscount\)<=0\.01;/, "discount rows must be treated as proven financial rows only on exact declared-amount agreement");
assert.match(page, /const nonPhysicalLineIds=new Set\(lines\.filter\(l=>Number\(l\.amount_inc_vat_gbp\)<0\)\.map\(l=>l\.id\)\);/, "every source-negative row must remain outside physical progression");
assert.match(page, /for\(const lineId of matchedDeliveryIds\) nonPhysicalLineIds\.add\(lineId\);/, "matched positive delivery rows must remain outside physical progression");
assert.match(page, /const unresolved=lines\.filter\(l=>!progressed\(l\)&&!disputes\.has\(l\.id\)&&!resolutions\.has\(l\.id\)\);/, "the original unresolved state model must remain unchanged");
assert.match(page, /const unresolvedMatchedFinancialOffset=round2\(unresolved\.filter\(l=>matchedDeliveryIds\.has\(l\.id\)\|\|matchedDiscountIds\.has\(l\.id\)\)\.reduce/, "only proven unresolved signed financial rows may adjust the physical allowance");
assert.match(page, /const physicalRemainingValue=Math\.max\(0,round2\(remainingValue-unresolvedMatchedFinancialOffset\)\);/, "physical allowance must use the signed invoice equation");
assert.match(page, /const selectable=unresolved\.filter\(l=>!nonPhysicalLineIds\.has\(l\.id\).*Number\(l\.amount_inc_vat_gbp\)<=physicalRemainingValue\+0\.01\);/, "ordinary goods selection must be restored while financial rows remain excluded");
assert.match(page, /const exceptionEligible=unresolved\.filter\(l=>!nonPhysicalLineIds\.has\(l\.id\)\);/, "proven financial rows must stay out of refund\/replacement exception selection");

assert.match(page, /<select name="financial_type" defaultValue="" required/, "Park classification must begin blank and require an explicit choice");
assert.match(page, /<option value="">Select type<\/option>/, "the blank governed classification option must be present");
assert.doesNotMatch(page, /suggestedFinancialType|defaultValue=\{.*discount|Non-physical classification required|OCR financial row:/, "the restored page must not preselect or present a replacement classification panel");

assert.match(page, /financialRow=nonPhysicalLineIds\.has\(line\.id\)/, "the page must lock proven financial source rows without changing ordinary goods cards");
assert.match(page, /name="amount_inc_vat_gbp" type="number" min=\{Number\(line\.amount_inc_vat_gbp\)<0\?undefined:0\}/, "the immutable amount field must display a negative source value without an invalid HTML minimum");
assert.equal((page.match(/readOnly=\{locked\|\|financialRow\}/g) ?? []).length, 3, "financial rows must keep quantity, amount and size immutable");
assert.match(page, /\{!locked&&!financialRow\?<button form=\{`edit-\$\{line\.id\}`\}/, "financial rows must not expose the generic Save action");

assert.match(bulkControls, /Select all unresolved progressable lines/, "Select all wording must remain unchanged");
assert.match(bulkControls, /Clear selection/, "Clear selection wording must remain unchanged");
assert.match(bulkControls, /input\[name="line_ids"\]\[form="bulk-progress-form"\]:not\(:disabled\)/, "bulk controls must still act only on enabled original checkboxes");

assert.match(nonPhysicalActions, /"delivery",\s*"discount",\s*"fee",\s*"zero_value_delivery",\s*"rounding",\s*"other_non_physical"/s, "the existing allowed non-physical classification set must remain authoritative");
assert.match(nonPhysicalActions, /Select a valid non-physical financial type\./, "blank or invalid classification must fail through the existing server action");
assert.match(nonPhysicalActions, /operator_resolve_supplier_invoice_line_non_physical/, "Park must continue to call the existing canonical RPC");

assert.match(actions, /submittedAmount === null \|\| submittedAmount < 0/, "generic manual edit must continue to reject a submitted negative amount");
assert.match(actions, /const effectiveAmount = isOcrLine \? Number\(existingLine\.amount_inc_vat_gbp \?\? 0\) : submittedAmount;/, "OCR source amount preservation in the server action must remain intact");
assert.match(actions, /staff_allocate|operator_mark_supplier_invoice_line_progressed|operator_bulk_mark_supplier_invoice_lines_progressed/, "existing progression server routes must remain present");

assert.match(ocrRoute, /const lines: ParsedLine\[\] = rawLines\.map/, "the Mindee parser must pass every source row forward");
assert.match(ocrRoute, /amount_inc_vat_gbp: line\.amount/, "the Mindee parser must preserve the source sign");
assert.doesNotMatch(ocrRoute, /amount\s*<\s*0\)\s*return null/, "the production parser must not discard negative rows");

assert.match(signedOcrMigration, /WHERE COALESCE\(NULLIF\(arr\.line_item->>'amount_inc_vat_gbp', ''\)::numeric, 0\) < 0/, "the OCR wrapper must materialise only omitted source-negative rows");
assert.match(signedOcrMigration, /'ocr_extracted',\s*'N'/s, "signed source rows must remain unresolved OCR evidence");
assert.match(signedOcrMigration, /existing\.line_order = arr\.ord::integer/, "repeat saves must remain idempotent by OCR line order");

assert.match(signedSageScope, /WHERE NOT EXISTS \(\s*SELECT 1 FROM affected a WHERE a\.supplier_invoice_id = p\.source_id\s*\)/s, "unaffected invoices must receive the preserved supplier AP helper output");
assert.match(signedSageScope, /WHERE EXISTS \(\s*SELECT 1 FROM affected a WHERE a\.supplier_invoice_id = e\.source_id\s*\)/s, "only affected invoices may receive signed non-physical enrichment");

assert.match(addendum, /£499\.99 goods\s*- £50\.01 discount\s*= £449\.98 supplier invoice gross/s, "the governing addendum must lock the target signed equation");
assert.match(addendum, /must not silently classify or preselect a financial type/, "the governing addendum must lock explicit classification");
assert.match(addendum, /appear in `resolved_lines` exactly once/, "the governing addendum must lock one-time Sage payload inclusion");

const invoiceAGoodsPence = 49999;
const invoiceADiscountPence = -5001;
const invoiceAGrossPence = 44998;
assert.equal(invoiceAGoodsPence + invoiceADiscountPence, invoiceAGrossPence, "NIN-240726-A signed lines must total £449.98");

const invoiceBGoodsPence = 17999 + 6999;
const invoiceBDeliveryPence = 1001;
const invoiceBDiscountPence = -1000;
const invoiceBGrossPence = 24999;
assert.equal(invoiceBGoodsPence + invoiceBDeliveryPence + invoiceBDiscountPence, invoiceBGrossPence, "NIN-240726-B signed delivery and discount must total £249.99");

console.log("PASS: signed OCR reconciliation keeps original controls and uses proven signed adjustment facts");
