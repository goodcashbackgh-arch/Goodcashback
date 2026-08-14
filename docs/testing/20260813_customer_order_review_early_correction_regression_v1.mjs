import assert from "node:assert/strict";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const addendumPath = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1.md";
const amendmentV14Path = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_4.md";
const migrationV14Path = "supabase/migrations/20260813201500_customer_order_early_correction_v1_4.sql";
const accessMigrationPath = "supabase/migrations/20260814141500_customer_order_early_correction_order_scoped_access_v1.sql";
const sharedFormPath = "app/importer/orders/new/OrderForm.tsx";
const customerCreatePagePath = "app/customer/orders/new/page.tsx";
const customerCreateActionPath = "app/customer/orders/new/actions.ts";
const correctionControlPath = "app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx";
const correctionUploadPath = "app/customer/orders/[order_id]/operations/uploadCorrectionScreenshots.ts";
const operationsLayoutPath = "app/customer/orders/[order_id]/operations/layout.tsx";

const addendum = fs.readFileSync(addendumPath, "utf8");
const amendmentV14 = fs.readFileSync(amendmentV14Path, "utf8");
const migrationV14 = fs.readFileSync(migrationV14Path, "utf8");
const accessMigration = fs.readFileSync(accessMigrationPath, "utf8");
const sharedForm = fs.readFileSync(sharedFormPath, "utf8");
const customerCreatePage = fs.readFileSync(customerCreatePagePath, "utf8");
const customerCreateAction = fs.readFileSync(customerCreateActionPath, "utf8");
const correctionControl = fs.readFileSync(correctionControlPath, "utf8");
const correctionUpload = fs.readFileSync(correctionUploadPath, "utf8");
const operationsLayout = fs.readFileSync(operationsLayoutPath, "utf8");

// Original governing authority remains intact.
assert.match(addendum, /Existing order creation, customer credit auto-application, funding, tracking, supplier invoice, evidence, reconciliation, shipment/);
assert.match(addendum, /No generic Edit Order or Delete Order capability is authorised/);
assert.match(addendum, /The database RPC is the final authority/);

// v1.4 remains the financial/correction authority and now governs the integration correction.
for (const expected of [
  /every existing funding event, if any, is `credit_applied`/,
  /Credit itself stays frozen/,
  /quantity-only correction is allowed/,
  /screenshot-only correction is allowed/,
  /£100 fully funded by £100 credit cannot be reduced to £70/,
  /already-installed v1\.4 database behaviour proven by rollback simulation is frozen/,
  /The order being corrected is the authority for importer scope/,
  /require a non-revoked `operator_importers` row for that exact `operator_id` and the loaded `order\.importer_id`/,
  /correction RPC is the single authoritative business-eligibility and mutation contract/,
  /public\.customer_order_correction_eligibility_v1\(uuid\)/,
  /direct browser no-op call using values read earlier is not authorised/,
  /row lock is already held and the values come from the same transaction/,
  /`loading`[\s\S]*`eligible`[\s\S]*`blocked`[\s\S]*`check_failed`/,
  /must not independently reproduce the complete backend blocker graph/,
  /already-applied `20260813201500_customer_order_early_correction_v1_4\.sql` is also historical/,
  /one new forward migration/,
  /RLS policies are not authorised to change/,
]) assert.match(amendmentV14, expected);

// Existing customer creation/review lane stays unchanged and retains auto-credit.
assert.match(sharedForm, /reviewBeforeSubmit = false/);
assert.match(customerCreatePage, /reviewBeforeSubmit=\{true\}/);
assert.match(customerCreateAction, /customer_apply_available_credit_to_order_v1/);
assert.match(customerCreateAction, /order_type: "original"/);
assert.match(customerCreateAction, /status: "pending_dva_funding"/);
assert.match(customerCreateAction, /note: "Original order screenshot"/);

// Correction remains additive in the existing operations layout.
assert.match(operationsLayout, /CustomerOrderCorrectionControl/);
assert.match(operationsLayout, /<CustomerOrderCorrectionControl orderId=\{orderId\} \/>/);

// The browser reads only the viewed order for form seed values. It does not read the blocker
// graph and it probes through the race-safe wrapper, while actual mutation stays on the correction RPC.
assert.match(correctionControl, /\.from\("orders"\)[\s\S]*\.select\("id, importer_id, total_qty_declared, order_total_gbp_declared"\)/);
for (const forbiddenBrowserAuthority of [
  "order_funding_events",
  "order_funding_position_vw",
  "order_tracking_submissions",
  "supplier_invoices",
  "operator_importers",
  "dva_reconciliation",
  "shipping_quote_orders",
]) assert.ok(!correctionControl.includes(forbiddenBrowserAuthority), `browser must not independently read ${forbiddenBrowserAuthority}`);

assert.equal((correctionControl.match(/\.rpc\("customer_order_correction_eligibility_v1"/g) ?? []).length, 1);
assert.equal((correctionControl.match(/\.rpc\("customer_correct_unprocessed_order_v1"/g) ?? []).length, 1);
assert.match(correctionControl, /\.rpc\("customer_order_correction_eligibility_v1", \{[\s\S]*p_order_id: orderId/);
assert.match(correctionControl, /p_total_qty_declared: totalQty[\s\S]*p_order_total_gbp_declared: roundedAmount[\s\S]*p_replacement_screenshot_urls: replacementUrls/);
assert.doesNotMatch(correctionControl, /p_total_qty_declared: currentQty[\s\S]*p_replacement_screenshot_urls: null/);
assert.doesNotMatch(correctionControl, /\.update\s*\(|\.insert\s*\(|\.delete\s*\(/);
assert.doesNotMatch(correctionControl, /service_role/i);
assert.doesNotMatch(correctionControl, /recompute_order_platform_funded|customer_apply_available_credit_to_order_v1|sync_order_overfunding_credit|credit_revers\w*/i);

// Eligibility can no longer disappear silently: all four governed states are represented.
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

// Business blockers and technical failure stay distinct.
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
assert.match(correctionControl, /uploadCorrectionScreenshots\([\s\S]*files: replacementFiles/);
assert.match(correctionUpload, /from\("order-screenshots"\)\.upload/);
assert.doesNotMatch(correctionUpload, /\.remove\s*\(|service_role/i);

// Installed v1.4 financial behaviour remains present and unchanged in source.
for (const expected of [
  /x\.event_type IS DISTINCT FROM 'credit_applied'/,
  /v_previously_fully_funded := v_order\.funded_at IS NOT NULL[\s\S]*v_funding\.threshold_met_yn[\s\S]*v_funding\.gap_remaining_gbp <= 0\.01/,
  /v_new_amount <= v_credit_event_sum \+ 0\.01/,
  /v_proposed_funding_gap <= 0\.01/,
  /PERFORM public\.recompute_order_platform_funded\(p_order_id\)/,
  /corrected value would require credit release or financial-state repair/,
  /credit funding event and ledger position disagree/,
  /Replacement screenshot row count postcondition failed/,
  /Replacement screenshot display order postcondition failed/,
]) assert.match(migrationV14, expected);
assert.doesNotMatch(migrationV14, /customer_apply_available_credit_to_order_v1\s*\(|sync_order_overfunding_credit\s*\(/);
for (const frozenTable of ["importer_credit_ledger", "order_funding_events", "dva_reconciliation"]) {
  assert.doesNotMatch(migrationV14, new RegExp(`(?:INSERT\\s+INTO|UPDATE|DELETE\\s+FROM)\\s+public\\.${frozenTable}`, "i"));
}

// The already-installed v1.4 migration must be byte-for-byte unchanged by this follow-up.
const historicalMigrationDelta = execFileSync("git", ["diff", "386a64dd23d9a964cf4ebf472e0bf4bc9641af7a", "--", migrationV14Path], { encoding: "utf8" });
assert.equal(historicalMigrationDelta, "", "installed v1.4 migration must remain historical and unchanged");

// New forward migration is surgical: order-scoped access rewrite plus one race-safe delegating wrapper.
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
assert.match(accessMigration, /SECURITY DEFINER[\s\S]*SET search_path = public, pg_temp/);
const eligibilityWrapper = accessMigration.match(/CREATE OR REPLACE FUNCTION public\.customer_order_correction_eligibility_v1[\s\S]*?\n\$\$;/)?.[0] ?? "";
assert.ok(eligibilityWrapper, "eligibility wrapper must exist");
assert.match(eligibilityWrapper, /FROM public\.orders o[\s\S]*FOR UPDATE OF o/);
assert.match(eligibilityWrapper, /op\.auth_user_id = auth\.uid\(\)/);
assert.match(eligibilityWrapper, /oi\.importer_id = o\.importer_id/);
assert.match(eligibilityWrapper, /oi\.revoked_at IS NULL/);
assert.match(eligibilityWrapper, /RETURN public\.customer_correct_unprocessed_order_v1\([\s\S]*v_order\.total_qty_declared[\s\S]*v_order\.order_total_gbp_declared[\s\S]*NULL::text\[\]/);
assert.doesNotMatch(eligibilityWrapper, /order_funding_events|order_funding_position_vw|supplier_invoices|dva_reconciliation|shipping_quote_orders/);
assert.doesNotMatch(eligibilityWrapper, /INSERT\s+INTO|UPDATE\s+public\.|DELETE\s+FROM/i);

assert.doesNotMatch(accessMigration, /ALTER\s+TABLE|CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER|CREATE\s+POLICY|DROP\s+POLICY|CREATE\s+TABLE|CREATE\s+VIEW/i);
assert.doesNotMatch(accessMigration, /INSERT\s+INTO\s+public\.|UPDATE\s+public\.|DELETE\s+FROM\s+public\./i);
assert.doesNotMatch(accessMigration, /CREATE(?: OR REPLACE)? FUNCTION public\.recompute_order_platform_funded/i);
assert.match(accessMigration, /REVOKE ALL ON FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.match(accessMigration, /GRANT EXECUTE ON FUNCTION public\.customer_correct_unprocessed_order_v1/);
assert.match(accessMigration, /REVOKE ALL ON FUNCTION public\.customer_order_correction_eligibility_v1/);
assert.match(accessMigration, /GRANT EXECUTE ON FUNCTION public\.customer_order_correction_eligibility_v1/);

// Frozen create actions and shared form stay outside this continuation.
for (const frozenPath of [sharedFormPath, customerCreateActionPath, "app/importer/orders/new/actions.ts"]) {
  const delta = execFileSync("git", ["diff", "167dd976e93f64ea89d8daae9598b6a01bedb9f1", "--", frozenPath], { encoding: "utf8" });
  assert.equal(delta, "", `${frozenPath} must remain unchanged`);
}

// Presentation stays additive and familiar.
assert.match(correctionControl, /<details open=\{isOpen\}/);
assert.match(correctionControl, /border border-sky-600 bg-sky-600 px-3 py-1\.5 text-xs font-black text-white/);
assert.match(correctionControl, /setIsOpen\(false\)/);

console.log(JSON.stringify({
  regression_result: "PASS",
  proof: "customer review/create and financial machinery remain frozen; installed v1.4 semantics remain historical; race-safe eligibility wrapper locks current values and delegates to the correction RPC; order-scoped importer access is forward-only; UI exposes eligible, blocked and technical-failure states instead of silently disappearing"
}, null, 2));
