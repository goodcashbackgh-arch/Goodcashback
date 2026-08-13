import assert from "node:assert/strict";
import fs from "node:fs";

const addendumPath = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1.md";
const amendmentPath = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_1.md";
const amendmentV12Path = "docs/governing-pack/architecture/CUSTOMER_ORDER_PRE_CREATION_REVIEW_AND_EARLY_CORRECTION_ADDENDUM_v1_2.md";
const migrationPath = "supabase/migrations/20260813124500_customer_order_early_correction_v1.sql";
const sharedFormPath = "app/importer/orders/new/OrderForm.tsx";
const customerCreatePagePath = "app/customer/orders/new/page.tsx";
const customerCreateActionPath = "app/customer/orders/new/actions.ts";
const correctionControlPath = "app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx";
const correctionUploadPath = "app/customer/orders/[order_id]/operations/uploadCorrectionScreenshots.ts";
const operationsLayoutPath = "app/customer/orders/[order_id]/operations/layout.tsx";

const addendum = fs.readFileSync(addendumPath, "utf8");
const amendment = fs.readFileSync(amendmentPath, "utf8");
const amendmentV12 = fs.readFileSync(amendmentV12Path, "utf8");
const migration = fs.readFileSync(migrationPath, "utf8");
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

console.log(JSON.stringify({
  regression_result: "PASS",
  proof: "customer-only review remains opt-in; existing create/auto-credit authority remains present; v1.1 authorises updated_at metadata and explicit active-operator authority; categories remain excluded; v1.2 adds a synchronous review-confirm one-shot guard and requires canonical Storage persistence; correction has no direct client DB mutation; RPC owns auth, row lock, full fail-closed gate and proportional quote preservation; screenshot replacement is one-for-one, restricted to verified order-screenshots objects and rebuilt from a trusted existing Storage prefix; no order deletion, existing-control replacement, RLS/schema mutation or physical Storage removal is introduced"
}, null, 2));
