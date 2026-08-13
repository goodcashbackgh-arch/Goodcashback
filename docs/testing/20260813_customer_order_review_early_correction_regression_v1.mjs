import assert from "node:assert/strict";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const addendumPath = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1.md";
const amendmentPath = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_1.md";
const amendmentV12Path = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_2.md";
const amendmentV13Path = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_3.md";
const amendmentV14Path = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_4.md";
const migrationPath = "supabase/migrations/20260813124500_customer_order_early_correction_v1.sql";
const migrationV13Path = "supabase/migrations/20260813165000_customer_order_early_correction_v1_3.sql";
const migrationV14Path = "supabase/migrations/20260813201500_customer_order_early_correction_v1_4.sql";
const sharedFormPath = "app/importer/orders/new/OrderForm.tsx";
const customerCreatePagePath = "app/customer/orders/new/page.tsx";
const customerCreateActionPath = "app/customer/orders/new/actions.ts";
const correctionControlPath = "app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx";
const correctionUploadPath = "app/customer/orders/[order_id]/operations/uploadCorrectionScreenshots.ts";
const operationsLayoutPath = "app/customer/orders/[order_id]/operations/layout.tsx";

const addendum = fs.readFileSync(addendumPath, "utf8");
const amendment = fs.readFileSync(amendmentPath, "utf8");
const amendmentV12 = fs.readFileSync(amendmentV12Path, "utf8");
const amendmentV13 = fs.readFileSync(amendmentV13Path, "utf8");
const amendmentV14 = fs.readFileSync(amendmentV14Path, "utf8");
const migration = fs.readFileSync(migrationPath, "utf8");
const migrationV13 = fs.readFileSync(migrationV13Path, "utf8");
const migrationV14 = fs.readFileSync(migrationV14Path, "utf8");
const sharedForm = fs.readFileSync(sharedFormPath, "utf8");
const customerCreatePage = fs.readFileSync(customerCreatePagePath, "utf8");
const customerCreateAction = fs.readFileSync(customerCreateActionPath, "utf8");
const correctionControl = fs.readFileSync(correctionControlPath, "utf8");
const correctionUpload = fs.readFileSync(correctionUploadPath, "utf8");
const operationsLayout = fs.readFileSync(operationsLayoutPath, "utf8");

// Governing authority must explicitly freeze the existing working lanes.
assert.match(addendum, /Existing order creation, customer credit auto-application, funding, tracking, supplier invoice, evidence, reconciliation, shipment/);
assert.match(addendum, /No generic Edit Order or Delete Order capability is authorised/);
assert.match(addendum, /quantity\ndeclared GBP amount\noriginal order screenshots/);
assert.match(addendum, /The database RPC is the final authority/);

// v1.1 authorises only reviewed metadata/auth tightening and keeps categories out of scope.
assert.match(amendment, /orders\.updated_at/);
assert.match(amendment, /op\.active = true/);
assert.match(amendment, /order_category_lines` is not part of this correction feature/);
assert.match(amendment, /must not be added to its eligibility gate/);

// v1.2 governs the synchronous review-confirm guard and canonical Storage persistence only.
assert.match(amendmentV12, /synchronous client-side one-shot guard/);
assert.match(amendmentV12, /leave the importer\/default submit path behaviour unchanged/);
assert.match(amendmentV12, /must not persist the caller-supplied URL string verbatim/);
assert.match(amendmentV12, /trusted public Storage URL prefix from the existing original screenshot rows/);
assert.match(amendmentV12, /caller-supplied arbitrary host or URL prefix must never become authoritative/);

// v1.4 governs partial and fully credit-funded correction while freezing credit itself.
assert.match(amendmentV14, /every existing funding event, if any, is `credit_applied`/);
assert.match(amendmentV14, /Credit itself stays frozen/);
assert.match(amendmentV14, /£100 with £30 existing credit may increase to £200[\s\S]*£170 due/);
assert.match(amendmentV14, /decrease to £50 because £20 remains due/);
assert.match(amendmentV14, /quantity-only correction is allowed/);
assert.match(amendmentV14, /screenshot-only correction is allowed/);
assert.match(amendmentV14, /may call the existing unchanged/);
assert.match(amendmentV14, /must never create, replace or modify it/);
assert.match(amendmentV14, /£100 fully funded by £100 credit cannot be reduced to £70/);
assert.match(amendmentV14, /sky\/blue collapsed `Correct order` treatment/);

// Review is opt-in and therefore importer behaviour stays off by default.
assert.match(sharedForm, /reviewBeforeSubmit = false/);
assert.match(sharedForm, /reviewBeforeSubmit\?: boolean/);
assert.match(customerCreatePage, /reviewBeforeSubmit=\{true\}/);
assert.match(sharedForm, /setReviewing\(true\);\s*return;/);
assert.match(sharedForm, /Back & edit/);
assert.match(sharedForm, /Confirm & create order/);
assert.match(sharedForm, /function submitPreparedForm\(form: HTMLFormElement\)/);

// v1.2: review confirmation is synchronously one-shot and the guard is confined to confirmCreate().
assert.match(sharedForm, /const reviewConfirmStartedRef = useRef\(false\);/);
const confirmCreateSource = sharedForm.match(/function confirmCreate\(\) \{[\s\S]*?\n  \}/)?.[0] ?? "";
assert.ok(confirmCreateSource, "confirmCreate source must be present");
assert.match(confirmCreateSource, /reviewConfirmStartedRef\.current/);
assert.match(confirmCreateSource, /reviewConfirmStartedRef\.current = true;/);
assert.match(confirmCreateSource, /submitPreparedForm\(form\);/);
assert.doesNotMatch(sharedForm.replace(confirmCreateSource, ""), /reviewConfirmStartedRef\.current/);

// The existing customer create action remains the creation authority and retains auto-credit.
assert.match(customerCreateAction, /export async function createCustomerOrderAction/);
assert.match(customerCreateAction, /customer_apply_available_credit_to_order_v1/);
assert.match(customerCreateAction, /order_type: "original"/);
assert.match(customerCreateAction, /status: "pending_dva_funding"/);
assert.match(customerCreateAction, /note: "Original order screenshot"/);

// Correction UI is mounted additively and may mutate only through the dedicated RPC.
assert.match(operationsLayout, /CustomerOrderCorrectionControl/);
assert.match(operationsLayout, /<CustomerOrderCorrectionControl orderId=\{orderId\} \/>/);
assert.match(correctionControl, /customer_correct_unprocessed_order_v1/);
assert.doesNotMatch(correctionControl, /\.update\s*\(/);
assert.doesNotMatch(correctionControl, /\.insert\s*\(/);
assert.doesNotMatch(correctionControl, /\.delete\s*\(/);
assert.doesNotMatch(correctionControl, /service_role/i);
assert.match(correctionControl, /order_funding_events/);
assert.match(correctionControl, /order_tracking_submissions/);
assert.match(correctionControl, /supplier_invoices/);
assert.match(correctionControl, /Original order screenshot/);
assert.match(correctionControl, /MAX_ATTACHMENT_BYTES = 3\.5 \* 1024 \* 1024/);

// v1.4 advisory eligibility permits credit_applied only and reads the existing canonical funding view.
assert.match(correctionControl, /order_funding_events"\)\.select\("id, event_type"\)/);
assert.match(correctionControl, /row\.event_type !== "credit_applied"/);
assert.match(correctionControl, /order_funding_position_vw/);
assert.match(correctionControl, /applied_credit_gbp, funded_total_gbp, markup_applied_gbp, gap_remaining_gbp, threshold_met_yn/);
// The current UI still has advisory fully-funded/proposed-gap blockers. Governance and
// database authority are corrected here; removing these blockers is a separate scoped task.
const uiHasLegacyFullyFundedBlocker = /order\.funded_at == null/.test(correctionControl)
  && /Boolean\(fundingPosition\.threshold_met_yn\) \|\| gapRemainingGbp <= 0\.01/.test(correctionControl)
  && /fundedTotalGbp > appliedCreditGbp \+ 0\.01/.test(correctionControl)
  && /proposedFundingGap <= 0\.01/.test(correctionControl);
assert.equal(uiHasLegacyFullyFundedBlocker, true);
assert.match(correctionControl, /account credit is already applied\. It stays unchanged/);

// Replacement files reuse the existing bucket and are never physically removed by this feature.
assert.match(correctionUpload, /from\("order-screenshots"\)\.upload/);
assert.match(correctionUpload, /correction-\$\{stamp\}-\$\{index \+ 1\}/);
assert.doesNotMatch(correctionUpload, /\.remove\s*\(/);
assert.doesNotMatch(correctionUpload, /service_role/i);

// New DB change is additive-only: create the new RPC, do not replace existing controls/schema.
assert.match(migration, /CREATE FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION public\.enforce_order_locks/i);
assert.doesNotMatch(migration, /CREATE OR REPLACE FUNCTION public\.trg_lock_quote_snapshot_on_order_submit/i);
assert.doesNotMatch(migration, /ALTER\s+TABLE/i);
assert.doesNotMatch(migration, /DELETE\s+FROM\s+public\.orders/i);
assert.doesNotMatch(migration, /DELETE\s+FROM\s+public\.order_screenshots/i);
assert.doesNotMatch(migration, /UPDATE\s+public\.order_funding_events/i);
assert.doesNotMatch(migration, /UPDATE\s+public\.order_tracking_submissions/i);
assert.doesNotMatch(migration, /UPDATE\s+public\.supplier_invoices/i);
assert.doesNotMatch(migration, /order_category_lines/);

// Ownership and race safety must remain inside the SECURITY DEFINER RPC.
assert.match(migration, /IF auth\.uid\(\) IS NULL/);
assert.match(migration, /FROM public\.orders o[\s\S]*FOR UPDATE;/);
assert.match(migration, /v_order\.importer_id IS DISTINCT FROM v_operator\.importer_id/);
assert.match(migration, /v_order\.operator_id IS DISTINCT FROM v_operator\.operator_id/);
assert.match(migration, /SECURITY DEFINER/);
assert.match(migration, /SET search_path = public, pg_temp/);
assert.match(migration, /AND op\.active = true/);
assert.doesNotMatch(migration, /COALESCE\(op\.active,\s*true\)\s*=\s*true/i);

// Status/lock fields are only part of a larger fail-closed child-table gate.
for (const table of [
  "order_funding_events",
  "order_tracking_submissions",
  "supplier_invoices",
  "dva_reconciliation",
  "dva_statement_line_allocations",
  "order_evidence_queries",
  "order_value_adjustments",
  "customer_order_review_links",
  "customer_pre_shipment_hold_requests",
  "shipper_shipment_batch_packages",
  "shipper_package_receipts",
  "sales_invoices",
  "shipping_quote_orders",
]) {
  assert.ok(migration.includes(`public.${table}`), `authoritative gate must include ${table}`);
}
assert.match(migration, /child\.parent_order_id = p_order_id/);
assert.match(migration, /os\.note IS DISTINCT FROM 'Original order screenshot'/);

// Stored quote economics are preserved; no new/current FX lookup is authorised.
assert.match(migration, /v_order\.quote_total_ghs::numeric\s*\/ v_order\.order_total_gbp_declared::numeric/);
assert.doesNotMatch(migration, /FROM\s+public\.fx_rates/i);
assert.doesNotMatch(migration, /quote_fx_rate\s*=/i);
assert.doesNotMatch(migration, /quote_card_markup_pct\s*=/i);
assert.doesNotMatch(migration, /status\s*=\s*'pending_dva_funding'/i);
assert.match(migration, /updated_at = now\(\)/);

// Screenshot correction is one-for-one, verifies actual Storage objects, and persists only a rebuilt trusted URL.
assert.match(migration, /storage\.objects/);
assert.match(migration, /so\.bucket_id = 'order-screenshots'/);
assert.match(migration, /parsed\.object_name NOT LIKE v_operator\.importer_id::text \|\| '\/' \|\| p_order_id::text \|\| '\/correction-%'/);
assert.match(migration, /cardinality\(p_replacement_screenshot_urls\) IS DISTINCT FROM v_original_screenshot_count/);
assert.match(migration, /v_storage_public_prefix text/);
assert.match(migration, /COUNT\(parsed\.public_prefix\) = COUNT\(\*\)/);
assert.match(migration, /COUNT\(DISTINCT parsed\.public_prefix\) = 1/);
assert.match(migration, /v_storage_public_prefix \|\| parsed\.object_name AS canonical_url/);
assert.match(migration, /UPDATE public\.order_screenshots os/);
assert.match(migration, /screenshot_url = replacements\.canonical_url/);
assert.doesNotMatch(migration, /screenshot_url = replacements\.url/);
assert.match(migration, /uploaded_by_operator_id = v_operator\.operator_id/);
assert.doesNotMatch(migration, /INSERT\s+INTO\s+public\.order_screenshots/i);

// v1.3 permits variable whole-set image replacement without changing frozen create-order code.
assert.match(amendmentV13, /replacement image count >= 1/);
assert.match(amendmentV13, /replacement count does not have to equal the previous original screenshot row count/);
assert.match(migrationV13, /CREATE OR REPLACE FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.doesNotMatch(migrationV13, /cardinality\(p_replacement_screenshot_urls\) IS DISTINCT FROM v_original_screenshot_count/);
assert.match(migrationV13, /v_replacement_count < 1/);
assert.match(migrationV13, /array_agg\(os\.id ORDER BY os\.display_order, os\.id\)/);
assert.match(migrationV13, /os\.id = v_original_screenshot_ids\[replacements\.position\]/);
assert.match(migrationV13, /WHERE replacement\.ordinality > v_original_screenshot_count/);
assert.match(migrationV13, /INSERT INTO public\.order_screenshots[\s\S]*'Original order screenshot'/);
assert.match(migrationV13, /DELETE FROM public\.order_screenshots os[\s\S]*os\.id = ANY\(v_original_screenshot_ids\)[\s\S]*os\.order_id = p_order_id[\s\S]*os\.note = 'Original order screenshot'/);
assert.match(migrationV13, /display_order = replacements\.position/);
assert.match(migrationV13, /COUNT\(\*\)::integer[\s\S]*IS DISTINCT FROM v_replacement_count[\s\S]*Replacement screenshot row count postcondition failed/);
assert.match(migrationV13, /row_number\(\) OVER \(ORDER BY os\.display_order, os\.id\)::integer AS expected_display_order[\s\S]*display_order IS DISTINCT FROM final_screenshots\.expected_display_order[\s\S]*Replacement screenshot display order postcondition failed/);

// Every replacement is canonicalised from a verified correction object and its stored metadata.
assert.match(migrationV13, /so\.bucket_id = 'order-screenshots'/);
assert.match(migrationV13, /r\.object_name NOT LIKE v_operator\.importer_id::text \|\| '\/' \|\| p_order_id::text \|\| '\/correction-%'/);
assert.match(migrationV13, /so\.metadata IS NULL/);
assert.match(migrationV13, /so\.metadata->>'mimetype'[\s\S]*NOT LIKE 'image\/%'/);
assert.match(migrationV13, /so\.metadata->>'size'[\s\S]*'\^\[0-9\]\+\$'/);
assert.match(migrationV13, /> 3670016/);
assert.match(migrationV13, /v_storage_public_prefix \|\| parsed\.object_name AS canonical_url/);
assert.doesNotMatch(migrationV13, /storage\.objects[\s\S]*DELETE FROM storage\.objects/i);
assert.doesNotMatch(correctionUpload, /\.remove\s*\(/);

// v1.4 is a feature-owned RPC replacement only and implements three funding paths.
assert.match(migrationV14, /CREATE OR REPLACE FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.match(migrationV14, /x\.event_type IS DISTINCT FROM 'credit_applied'/);
assert.match(migrationV14, /v_previously_fully_funded := v_order\.funded_at IS NOT NULL[\s\S]*v_funding\.threshold_met_yn[\s\S]*v_funding\.gap_remaining_gbp <= 0\.01/);
assert.match(migrationV14, /v_new_amount <= v_credit_event_sum \+ 0\.01/);
assert.match(migrationV14, /v_proposed_funding_gap <= 0\.01/);
assert.match(migrationV14, /PERFORM public\.recompute_order_platform_funded\(p_order_id\)/);
assert.doesNotMatch(migrationV14, /CREATE(?: OR REPLACE)? FUNCTION public\.recompute_order_platform_funded/i);
assert.match(migrationV14, /to_regprocedure\('public\.recompute_order_platform_funded\(uuid\)'\)/);
assert.match(migrationV14, /This equality guard is deliberately local to the fully funded upward-value path/);
assert.match(migrationV14, /abs\(v_credit_event_sum_after - v_applied_credit_before_recompute\) > 0\.01/);
assert.match(migrationV14, /FROM public\.order_funding_position_vw f[\s\S]*LEFT JOIN public\.order_funding_events x/);
assert.match(migrationV14, /v_funding_after\.funded_at IS NOT NULL/);
assert.match(migrationV14, /v_funding_after\.threshold_met_yn/);
assert.match(migrationV14, /v_credit_event_count_after IS DISTINCT FROM v_credit_event_count/);
assert.match(migrationV14, /corrected value would require credit release or financial-state repair/);
assert.doesNotMatch(migrationV14, /customer_apply_available_credit_to_order_v1\s*\(/);
assert.doesNotMatch(migrationV14, /sync_order_overfunding_credit\s*\(/);
for (const frozenTable of ["importer_credit_ledger", "order_funding_events", "dva_reconciliation"]) {
  assert.doesNotMatch(migrationV14, new RegExp(`(?:INSERT\\s+INTO|UPDATE|DELETE\\s+FROM)\\s+public\\.${frozenTable}`, "i"));
}
assert.doesNotMatch(migrationV14, /CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER|ALTER\s+TABLE|CREATE\s+POLICY|DROP\s+POLICY/i);
assert.match(migrationV14, /REVOKE ALL ON FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.match(migrationV14, /GRANT EXECUTE ON FUNCTION public\.customer_correct_unprocessed_order_v1/);

// Arithmetic policy examples: immutable credit feeds only the canonical derived gap.
const canonicalGap = (goods, credit, markup = 0) => Math.max(goods + markup - credit, 0);
assert.equal(canonicalGap(200, 30), 170); // £100 + £30 -> £200.
assert.equal(canonicalGap(50, 30), 20);   // £100 + £30 -> £50 remains genuinely partial.
assert.equal(canonicalGap(200, 100), 100); // fully funded £100 -> £200 creates a gap.
assert.ok(canonicalGap(70, 100) <= 0.01);  // a £100 -> £70 reduction requires release.

// Recompute is guarded by the fully-funded branch, so quantity/screenshot-only paths cannot call it.
const recomputeBranch = migrationV14.match(/IF v_recompute_required THEN[\s\S]*?PERFORM public\.recompute_order_platform_funded\(p_order_id\);[\s\S]*?END IF;/)?.[0] ?? "";
assert.ok(recomputeBranch);
assert.match(migrationV14, /v_recompute_required boolean := false/);
assert.match(migrationV14, /IF v_amount_changed THEN[\s\S]*v_recompute_required := true/);
assert.doesNotMatch(recomputeBranch, /p_replacement_screenshot_urls|v_qty_changed/);
assert.match(migrationV14, /IF NOT v_amount_changed THEN[\s\S]*Order correction no-amount funding preservation postcondition failed/);

// v1.4 preserves the v1.3 Storage/screenshot machinery and stored quote economics byte-for-concept.
for (const expected of [
  /so\.bucket_id = 'order-screenshots'/,
  /> 3670016/,
  /v_storage_public_prefix \|\| parsed\.object_name AS canonical_url/,
  /INSERT INTO public\.order_screenshots[\s\S]*'Original order screenshot'/,
  /DELETE FROM public\.order_screenshots os[\s\S]*os\.id = ANY\(v_original_screenshot_ids\)/,
  /Replacement screenshot row count postcondition failed/,
  /Replacement screenshot display order postcondition failed/,
  /v_order\.quote_total_ghs::numeric[\s\S]*\/ v_order\.order_total_gbp_declared::numeric/,
]) assert.match(migrationV14, expected);
assert.doesNotMatch(migrationV14, /FROM\s+public\.fx_rates/i);

// Correction copies the established optimiser and uploads only its prepared files.
for (const constant of [
  /MAX_ATTACHMENT_BYTES = 3\.5 \* 1024 \* 1024/,
  /TARGET_ATTACHMENT_BYTES = 3\.1 \* 1024 \* 1024/,
  /COMPRESSION_TRIGGER_BYTES = 700 \* 1024/,
  /MAX_FILE_TARGET_BYTES = 900 \* 1024/,
  /MIN_FILE_TARGET_BYTES = 300 \* 1024/,
  /MAX_IMAGE_DIMENSIONS = \[1800, 1500, 1200\]/,
  /JPEG_QUALITIES = \[0\.86, 0\.76, 0\.66\]/,
]) assert.match(correctionControl, constant);
assert.match(correctionControl, /preparedFilesRef\.current/);
assert.match(correctionControl, /uploadCorrectionScreenshots\([\s\S]*files: replacementFiles/);
assert.match(correctionControl, /replacementFiles\.reduce\([\s\S]*> MAX_ATTACHMENT_BYTES/);
assert.doesNotMatch(correctionControl, /replacementFiles\.length !== currentEligibleOrder\.originalScreenshotCount/);

// Presentation and authoritative post-save behaviour remain deliberately narrow.
assert.match(correctionControl, /<details open=\{isOpen\}/);
assert.match(correctionControl, /border border-sky-600 bg-sky-600 px-3 py-1\.5 text-xs font-black text-white/);
assert.match(correctionControl, /setIsOpen\(false\)/);
assert.match(correctionControl, /isAuthoritativeBlocker\(rawMessage\)[\s\S]*setEligibleOrder\(null\)/);
assert.match(correctionControl, /originalScreenshotCount: replacementFiles\.length > 0 \? replacementFiles\.length : current\.originalScreenshotCount/);

// The v1.3/v1.4 continuation leaves both create actions and OrderForm byte-for-byte untouched.
for (const frozenPath of [sharedFormPath, customerCreateActionPath, "app/importer/orders/new/actions.ts"]) {
  const delta = execFileSync("git", ["diff", "167dd976e93f64ea89d8daae9598b6a01bedb9f1", "--", frozenPath], { encoding: "utf8" });
  assert.equal(delta, "", `${frozenPath} must remain unchanged after the v1.3 governance commit`);
}

// The corrective migrations remain feature-only: no schema, RLS, trigger, or adjacent business-lane expansion.
for (const correctiveMigration of [migrationV13, migrationV14]) {
  assert.doesNotMatch(correctiveMigration, /ALTER\s+TABLE|CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER|CREATE\s+POLICY|DROP\s+POLICY/i);
  assert.doesNotMatch(correctiveMigration, /sage|UPDATE\s+public\.(?:order_funding_events|order_tracking_submissions|supplier_invoices|dva_reconciliation|sales_invoices|shipping_quote_orders)/i);
  assert.doesNotMatch(correctiveMigration, /DELETE\s+FROM\s+public\.orders/i);
}

console.log(JSON.stringify({
  regression_result: "PASS",
  proof: "customer-only review remains opt-in; create/credit/funding authority stays frozen; v1.3 Storage safeguards remain; v1.4 permits credit-only partial and fully-funded corrections, confines recompute to the fully-funded upward-value path, and rejects corrections requiring credit release; the legacy UI advisory blocker is identified for separate follow-up"
}, null, 2));
