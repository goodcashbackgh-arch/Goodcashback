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
const accessMigrationPath = "supabase/migrations/20260814141500_customer_order_early_correction_order_scoped_access_v1.sql";
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
const accessMigration = fs.readFileSync(accessMigrationPath, "utf8");
const sharedForm = fs.readFileSync(sharedFormPath, "utf8");
const customerCreatePage = fs.readFileSync(customerCreatePagePath, "utf8");
const customerCreateAction = fs.readFileSync(customerCreateActionPath, "utf8");
const correctionControl = fs.readFileSync(correctionControlPath, "utf8");
const correctionUpload = fs.readFileSync(correctionUploadPath, "utf8");
const operationsLayout = fs.readFileSync(operationsLayoutPath, "utf8");

// Original governing authority must remain intact.
assert.match(addendum, /Existing order creation, customer credit auto-application, funding, tracking, supplier invoice, evidence, reconciliation, shipment/);
assert.match(addendum, /No generic Edit Order or Delete Order capability is authorised/);
assert.match(addendum, /quantity\ndeclared GBP amount\noriginal order screenshots/);
assert.match(addendum, /The database RPC is the final authority/);

// v1.1 historical metadata/auth tightening remains governed and categories remain out of scope.
assert.match(amendment, /orders\.updated_at/);
assert.match(amendment, /op\.active = true/);
assert.match(amendment, /order_category_lines` is not part of this correction feature/);
assert.match(amendment, /must not be added to its eligibility gate/);

// v1.2 historical synchronous review guard and canonical Storage persistence remain governed.
assert.match(amendmentV12, /synchronous client-side one-shot guard/);
assert.match(amendmentV12, /leave the importer\/default submit path behaviour unchanged/);
assert.match(amendmentV12, /must not persist the caller-supplied URL string verbatim/);
assert.match(amendmentV12, /trusted public Storage URL prefix from the existing original screenshot rows/);
assert.match(amendmentV12, /caller-supplied arbitrary host or URL prefix must never become authoritative/);

// v1.3 historical variable whole-set replacement authority remains governed.
assert.match(amendmentV13, /replacement image count >= 1/);
assert.match(amendmentV13, /replacement count does not have to equal the previous original screenshot row count/);

// v1.4 remains the financial/correction authority and governs this integration correction.
for (const expected of [
  /every existing funding event, if any, is `credit_applied`/,
  /Credit itself stays frozen/,
  /quantity-only correction is allowed/,
  /screenshot-only correction is allowed/,
  /£100 fully funded by £100 credit cannot be reduced to £70/,
  /already-installed v1\.4 database behaviour proven by rollback simulation is frozen/,
  /The order being corrected is the authority for importer scope/,
  /require a non-revoked `operator_importers` row for that exact `operator_id` and the loaded `order\.importer_id`/,
  /single authoritative business-eligibility and mutation contract/,
  /public\.customer_order_correction_eligibility_v1\(uuid\)/,
  /direct browser no-op call using values read earlier is not authorised/,
  /form seed snapshot must therefore use the feature-owned wrapper/,
  /browser must seed the correction form only from the successful wrapper response/,
  /applied-credit message and conditional original-attachment replacement guidance are part of the non-regression UI baseline/,
  /`loading`[\s\S]*`eligible`[\s\S]*`blocked`[\s\S]*`check_failed`/,
  /already-applied `20260813201500_customer_order_early_correction_v1_4\.sql` is also historical/,
  /RLS policies are not authorised to change/,
]) assert.match(amendmentV14, expected);

// Review is still customer-only opt-in; importer/default behaviour stays off by default.
assert.match(sharedForm, /reviewBeforeSubmit = false/);
assert.match(sharedForm, /reviewBeforeSubmit\?: boolean/);
assert.match(customerCreatePage, /reviewBeforeSubmit=\{true\}/);
assert.match(sharedForm, /setReviewing\(true\);\s*return;/);
assert.match(sharedForm, /Back & edit/);
assert.match(sharedForm, /Confirm & create order/);
assert.match(sharedForm, /function submitPreparedForm\(form: HTMLFormElement\)/);

// v1.2 one-shot confirmation guard remains synchronous and confined to confirmCreate().
assert.match(sharedForm, /const reviewConfirmStartedRef = useRef\(false\);/);
const confirmCreateSource = sharedForm.match(/function confirmCreate\(\) \{[\s\S]*?\n  \}/)?.[0] ?? "";
assert.ok(confirmCreateSource, "confirmCreate source must be present");
assert.match(confirmCreateSource, /reviewConfirmStartedRef\.current/);
assert.match(confirmCreateSource, /reviewConfirmStartedRef\.current = true;/);
assert.match(confirmCreateSource, /submitPreparedForm\(form\);/);
assert.doesNotMatch(sharedForm.replace(confirmCreateSource, ""), /reviewConfirmStartedRef\.current/);

// Customer create action remains creation authority and retains auto-credit.
assert.match(customerCreateAction, /export async function createCustomerOrderAction/);
assert.match(customerCreateAction, /customer_apply_available_credit_to_order_v1/);
assert.match(customerCreateAction, /order_type: "original"/);
assert.match(customerCreateAction, /status: "pending_dva_funding"/);
assert.match(customerCreateAction, /note: "Original order screenshot"/);

// Correction remains additive in the existing operations layout.
assert.match(operationsLayout, /CustomerOrderCorrectionControl/);
assert.match(operationsLayout, /<CustomerOrderCorrectionControl orderId=\{orderId\} \/>/);

// Browser gets both eligibility and form seed from one race-safe wrapper snapshot.
assert.doesNotMatch(correctionControl, /\.from\("orders"\)|\.from\("operators"\)|\.from\("operator_importers"\)/);
for (const forbiddenBrowserAuthority of [
  "order_funding_events",
  "order_funding_position_vw",
  "order_tracking_submissions",
  "supplier_invoices",
  "dva_reconciliation",
  "shipping_quote_orders",
]) assert.ok(!correctionControl.includes(forbiddenBrowserAuthority), `browser must not independently read ${forbiddenBrowserAuthority}`);
assert.equal((correctionControl.match(/\.rpc\("customer_order_correction_eligibility_v1"/g) ?? []).length, 1);
assert.equal((correctionControl.match(/\.rpc\("customer_correct_unprocessed_order_v1"/g) ?? []).length, 1);
assert.match(correctionControl, /\.rpc\("customer_order_correction_eligibility_v1", \{[\s\S]*p_order_id: orderId/);
for (const snapshotField of [
  "importer_id",
  "current_qty",
  "current_amount",
  "original_screenshot_count",
  "applied_credit_gbp",
  "funded_total_gbp",
  "markup_applied_gbp",
  "previously_fully_funded",
]) assert.ok(correctionControl.includes(snapshotField), `UI must consume wrapper snapshot field ${snapshotField}`);
assert.match(correctionControl, /snapshot\?\.ok !== true[\s\S]*snapshot\?\.eligible !== true[\s\S]*snapshot\?\.changed !== false/);
assert.match(correctionControl, /p_total_qty_declared: totalQty[\s\S]*p_order_total_gbp_declared: roundedAmount[\s\S]*p_replacement_screenshot_urls: replacementUrls/);
assert.doesNotMatch(correctionControl, /\.update\s*\(|\.insert\s*\(|\.delete\s*\(/);
assert.doesNotMatch(correctionControl, /service_role/i);
assert.doesNotMatch(correctionControl, /recompute_order_platform_funded|customer_apply_available_credit_to_order_v1|sync_order_overfunding_credit|credit_revers\w*/i);

// Existing immediate guidance is preserved as advisory UI only.
const amountChangeGuard = correctionControl.match(/if \(roundedAmount !== currentEligibleOrder\.currentAmount\) \{[\s\S]*?\n    \}/)?.[0] ?? "";
assert.ok(amountChangeGuard, "amount-change advisory guard must remain");
assert.match(amountChangeGuard, /roundedAmount \+ currentEligibleOrder\.markupAppliedGbp - currentEligibleOrder\.fundedTotalGbp/);
assert.match(amountChangeGuard, /proposedFundingGap <= 0\.01/);
assert.match(amountChangeGuard, /currentEligibleOrder\.previouslyFullyFunded && roundedAmount <= currentEligibleOrder\.currentAmount/);
assert.match(correctionControl, /account credit is already applied\. It stays unchanged/);
assert.match(correctionControl, /eligibleOrder\.originalScreenshotCount > 0/);
assert.match(correctionControl, /complete existing set of \{eligibleOrder\.originalScreenshotCount\} original/);
assert.match(correctionControl, /originalScreenshotCount: replacementFiles\.length > 0 \? replacementFiles\.length : current\.originalScreenshotCount/);
assert.match(correctionControl, /previouslyFullyFunded: current\.previouslyFullyFunded && roundedAmount > current\.currentAmount \? false/);

// Eligibility never silently disappears: all four governed states remain explicit.
assert.match(correctionControl, /type EligibilityState = "loading" \| "eligible" \| "blocked" \| "check_failed"/);
assert.match(correctionControl, /setEligibilityState\("loading"\)/);
assert.match(correctionControl, /setEligibilityState\("eligible"\)/);
assert.match(correctionControl, /setEligibilityState\("blocked"\)/);
assert.match(correctionControl, /setEligibilityState\("check_failed"\)/);
assert.doesNotMatch(correctionControl, /if \(!eligibleOrder\) return null/);
assert.match(correctionControl, /Checking correction availability/);
assert.match(correctionControl, /We could not check whether this order can be corrected/);
assert.match(correctionControl, /Check again/);
assert.match(correctionControl, /Order correction/);
assert.match(correctionControl, />Correct order</);

// Business blockers and technical failures remain distinct.
for (const rpcMessage of [
  "processing has started",
  "downstream evidence",
  "credit funding event and ledger position disagree",
  "non-credit funding has started",
  "does not belong to the active customer/operator assignment",
  "active customer/operator assignment not found",
]) assert.match(correctionControl, new RegExp(rpcMessage));
assert.match(correctionControl, /isAuthoritativeBlocker\(rawMessage\)[\s\S]*setEligibilityState\("blocked"\)[\s\S]*setEligibilityMessage\(correctionError\(rawMessage\)\)/);
assert.match(correctionControl, /setEligibilityState\("check_failed"\)[\s\S]*eligibilityCheckFailedMessage/);

// Existing attachment optimiser/upload boundary remains intact.
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
assert.match(correctionUpload, /from\("order-screenshots"\)\.upload/);
assert.match(correctionUpload, /correction-\$\{stamp\}-\$\{index \+ 1\}/);
assert.doesNotMatch(correctionUpload, /\.remove\s*\(|service_role/i);

// Historical v1 migration stays additive-only and retains its original ownership/security gates.
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
assert.match(migration, /IF auth\.uid\(\) IS NULL/);
assert.match(migration, /FROM public\.orders o[\s\S]*FOR UPDATE;/);
assert.match(migration, /v_order\.importer_id IS DISTINCT FROM v_operator\.importer_id/);
assert.match(migration, /v_order\.operator_id IS DISTINCT FROM v_operator\.operator_id/);
assert.match(migration, /SECURITY DEFINER/);
assert.match(migration, /SET search_path = public, pg_temp/);
assert.match(migration, /AND op\.active = true/);
assert.doesNotMatch(migration, /COALESCE\(op\.active,\s*true\)\s*=\s*true/i);

// Historical v1 authoritative blocker graph and quote/Storage safeguards stay present.
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
]) assert.ok(migration.includes(`public.${table}`), `v1 gate must include ${table}`);
assert.match(migration, /child\.parent_order_id = p_order_id/);
assert.match(migration, /os\.note IS DISTINCT FROM 'Original order screenshot'/);
assert.match(migration, /v_order\.quote_total_ghs::numeric\s*\/ v_order\.order_total_gbp_declared::numeric/);
assert.doesNotMatch(migration, /FROM\s+public\.fx_rates/i);
assert.doesNotMatch(migration, /quote_fx_rate\s*=/i);
assert.doesNotMatch(migration, /quote_card_markup_pct\s*=/i);
assert.doesNotMatch(migration, /status\s*=\s*'pending_dva_funding'/i);
assert.match(migration, /updated_at = now\(\)/);
assert.match(migration, /storage\.objects/);
assert.match(migration, /so\.bucket_id = 'order-screenshots'/);
assert.match(migration, /v_storage_public_prefix text/);
assert.match(migration, /COUNT\(parsed\.public_prefix\) = COUNT\(\*\)/);
assert.match(migration, /COUNT\(DISTINCT parsed\.public_prefix\) = 1/);
assert.match(migration, /v_storage_public_prefix \|\| parsed\.object_name AS canonical_url/);
assert.match(migration, /screenshot_url = replacements\.canonical_url/);
assert.doesNotMatch(migration, /screenshot_url = replacements\.url/);

// Historical v1.3 variable whole-set replacement and Storage metadata safeguards stay present.
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
assert.match(migrationV13, /so\.bucket_id = 'order-screenshots'/);
assert.match(migrationV13, /r\.object_name NOT LIKE v_operator\.importer_id::text \|\| '\/' \|\| p_order_id::text \|\| '\/correction-%'/);
assert.match(migrationV13, /so\.metadata IS NULL/);
assert.match(migrationV13, /so\.metadata->>'mimetype'[\s\S]*NOT LIKE 'image\/%'/);
assert.match(migrationV13, /so\.metadata->>'size'[\s\S]*'\^\[0-9\]\+\$'/);
assert.match(migrationV13, /> 3670016/);
assert.match(migrationV13, /v_storage_public_prefix \|\| parsed\.object_name AS canonical_url/);
assert.doesNotMatch(migrationV13, /storage\.objects[\s\S]*DELETE FROM storage\.objects/i);

// Installed v1.4 financial behaviour remains present and historical.
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

// Arithmetic policy examples remain frozen.
const canonicalGap = (goods, credit, markup = 0) => Math.max(goods + markup - credit, 0);
assert.equal(canonicalGap(200, 30), 170);
assert.equal(canonicalGap(50, 30), 20);
assert.equal(canonicalGap(200, 100), 100);
assert.ok(canonicalGap(70, 100) <= 0.01);

// Recompute remains confined to the fully-funded amount-change branch.
const recomputeBranch = migrationV14.match(/IF v_recompute_required THEN[\s\S]*?PERFORM public\.recompute_order_platform_funded\(p_order_id\);[\s\S]*?END IF;/)?.[0] ?? "";
assert.ok(recomputeBranch);
assert.match(migrationV14, /v_recompute_required boolean := false/);
assert.match(migrationV14, /IF v_amount_changed THEN[\s\S]*v_recompute_required := true/);
assert.doesNotMatch(recomputeBranch, /p_replacement_screenshot_urls|v_qty_changed/);
assert.match(migrationV14, /IF NOT v_amount_changed THEN[\s\S]*Order correction no-amount funding preservation postcondition failed/);

// v1.4 preserves v1.3 Storage/screenshot machinery and stored quote economics.
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

// The already-installed v1.4 migration must be byte-for-byte unchanged by this follow-up.
const historicalMigrationDelta = execFileSync("git", ["diff", "386a64dd23d9a964cf4ebf472e0bf4bc9641af7a", "--", migrationV14Path], { encoding: "utf8" });
assert.equal(historicalMigrationDelta, "", "installed v1.4 migration must remain historical and unchanged");

// New forward migration is surgical: order-scoped access rewrite plus one locked snapshot wrapper.
assert.match(accessMigration, /pg_get_functiondef/);
assert.match(accessMigration, /EXECUTE v_new_definition/);
assert.match(accessMigration, /op\.auth_user_id = auth\.uid\(\)/);
assert.match(accessMigration, /op\.active = true/);
assert.match(accessMigration, /v_order\.operator_id IS DISTINCT FROM v_operator\.operator_id/);
assert.match(accessMigration, /oi\.operator_id = v_operator\.operator_id/);
assert.match(accessMigration, /oi\.importer_id = v_order\.importer_id/);
assert.match(accessMigration, /oi\.revoked_at IS NULL/);
assert.match(accessMigration, /v_operator\.importer_id := v_order\.importer_id/);
assert.match(accessMigration, /Expected v1\.4 operator-resolution block not found/);
assert.match(accessMigration, /Expected v1\.4 ownership block not found/);
assert.match(accessMigration, /Order-scoped access rewrite postcondition failed/);

assert.match(accessMigration, /CREATE OR REPLACE FUNCTION public\.customer_order_correction_eligibility_v1/);
const eligibilityWrapper = accessMigration.match(/CREATE OR REPLACE FUNCTION public\.customer_order_correction_eligibility_v1[\s\S]*?\n\$\$;/)?.[0] ?? "";
assert.ok(eligibilityWrapper, "eligibility wrapper must exist");
assert.match(eligibilityWrapper, /SECURITY DEFINER[\s\S]*SET search_path = public, pg_temp/);
assert.match(eligibilityWrapper, /o\.importer_id[\s\S]*o\.total_qty_declared[\s\S]*o\.order_total_gbp_declared[\s\S]*o\.funded_at/);
assert.match(eligibilityWrapper, /FROM public\.orders o[\s\S]*FOR UPDATE OF o/);
assert.match(eligibilityWrapper, /op\.auth_user_id = auth\.uid\(\)/);
assert.match(eligibilityWrapper, /oi\.importer_id = o\.importer_id/);
assert.match(eligibilityWrapper, /oi\.revoked_at IS NULL/);
assert.match(eligibilityWrapper, /v_probe := public\.customer_correct_unprocessed_order_v1\([\s\S]*v_order\.total_qty_declared[\s\S]*v_order\.order_total_gbp_declared[\s\S]*NULL::text\[\]/);
assert.match(eligibilityWrapper, /v_probe->>'ok'[\s\S]*v_probe->>'changed'/);
const probeIndex = eligibilityWrapper.indexOf("v_probe := public.customer_correct_unprocessed_order_v1");
const fundingSnapshotIndex = eligibilityWrapper.indexOf("FROM public.order_funding_position_vw");
const screenshotCountIndex = eligibilityWrapper.indexOf("FROM public.order_screenshots");
assert.ok(probeIndex >= 0 && fundingSnapshotIndex > probeIndex && screenshotCountIndex > probeIndex, "presentation snapshot reads must follow delegated eligibility");
assert.match(eligibilityWrapper, /'importer_id', v_order\.importer_id/);
assert.match(eligibilityWrapper, /'current_qty', v_order\.total_qty_declared/);
assert.match(eligibilityWrapper, /'current_amount', ROUND\(v_order\.order_total_gbp_declared::numeric, 2\)/);
assert.match(eligibilityWrapper, /'original_screenshot_count', v_original_screenshot_count/);
assert.match(eligibilityWrapper, /'applied_credit_gbp', ROUND\(v_funding\.applied_credit_gbp, 2\)/);
assert.match(eligibilityWrapper, /'funded_total_gbp', ROUND\(v_funding\.funded_total_gbp, 2\)/);
assert.match(eligibilityWrapper, /'markup_applied_gbp', ROUND\(v_funding\.markup_applied_gbp, 2\)/);
assert.match(eligibilityWrapper, /'previously_fully_funded', v_previously_fully_funded/);
assert.doesNotMatch(eligibilityWrapper, /order_tracking_submissions|supplier_invoices|dva_reconciliation|shipping_quote_orders/);
assert.doesNotMatch(eligibilityWrapper, /INSERT\s+INTO|UPDATE\s+public\.|DELETE\s+FROM/i);

assert.doesNotMatch(accessMigration, /ALTER\s+TABLE|CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER|CREATE\s+POLICY|DROP\s+POLICY|CREATE\s+TABLE|CREATE\s+VIEW/i);
assert.doesNotMatch(accessMigration, /INSERT\s+INTO\s+public\.|UPDATE\s+public\.|DELETE\s+FROM\s+public\./i);
assert.doesNotMatch(accessMigration, /CREATE(?: OR REPLACE)? FUNCTION public\.recompute_order_platform_funded/i);
assert.match(accessMigration, /REVOKE ALL ON FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.match(accessMigration, /GRANT EXECUTE ON FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.match(accessMigration, /REVOKE ALL ON FUNCTION public\.customer_order_correction_eligibility_v1/);
assert.match(accessMigration, /GRANT EXECUTE ON FUNCTION public\.customer_order_correction_eligibility_v1/);

// Frozen create actions and shared form remain byte-for-byte outside this continuation.
for (const frozenPath of [sharedFormPath, customerCreateActionPath, "app/importer/orders/new/actions.ts"]) {
  const delta = execFileSync("git", ["diff", "167dd976e93f64ea89d8daae9598b6a01bedb9f1", "--", frozenPath], { encoding: "utf8" });
  assert.equal(delta, "", `${frozenPath} must remain unchanged`);
}

// Historical and new corrective migrations remain feature-only: no schema/RLS/trigger/adjacent-lane expansion.
for (const correctiveMigration of [migrationV13, migrationV14, accessMigration]) {
  assert.doesNotMatch(correctiveMigration, /ALTER\s+TABLE|CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER|CREATE\s+POLICY|DROP\s+POLICY/i);
  assert.doesNotMatch(correctiveMigration, /sage|UPDATE\s+public\.(?:order_funding_events|order_tracking_submissions|supplier_invoices|dva_reconciliation|sales_invoices|shipping_quote_orders)/i);
  assert.doesNotMatch(correctiveMigration, /DELETE\s+FROM\s+public\.orders/i);
}

// Presentation remains additive and familiar.
assert.match(correctionControl, /<details open=\{isOpen\}/);
assert.match(correctionControl, /border border-sky-600 bg-sky-600 px-3 py-1\.5 text-xs font-black text-white/);
assert.match(correctionControl, /setIsOpen\(false\)/);

console.log(JSON.stringify({
  regression_result: "PASS",
  proof: "historical v1/v1.1/v1.2/v1.3/v1.4 safeguards remain asserted; installed v1.4 financial semantics stay historical; order-scoped access is forward-only; the race-safe wrapper locks and validates the current snapshot before returning form/advisory values; UI retains prior credit, fully-funded and attachment guidance without reading blocker tables"
}, null, 2));
