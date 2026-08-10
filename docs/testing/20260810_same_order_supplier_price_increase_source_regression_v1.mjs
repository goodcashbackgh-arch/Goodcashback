import fs from "node:fs";
import crypto from "node:crypto";

function read(path) {
  return fs.readFileSync(path, "utf8");
}

function assert(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
}

function gitBlobSha(text) {
  const body = Buffer.from(text, "utf8");
  const header = Buffer.from(`blob ${body.length}\0`, "utf8");
  return crypto.createHash("sha1").update(header).update(body).digest("hex");
}

const existingActionsPath = "app/internal/invoice-review/actions.ts";
const headerMigrationPath = "supabase/migrations/20260730_supplier_invoice_header_net_vat_review_v1.sql";
const canonicalApprovalMigrationPath = "supabase/migrations/20260719b_multi_supplier_invoice_sibling_safe_review_v1.sql";
const pagePath = "app/internal/invoice-review/page.tsx";
const readinessPath = "app/internal/invoice-review/readiness.ts";
const priceActionsPath = "app/internal/invoice-review/price-actions.ts";
const migrations = [
  "supabase/migrations/20260810_same_order_supplier_price_increase_v1.sql",
  "supabase/migrations/20260810a_same_order_supplier_price_guard_verified_alignment_v1.sql",
  "supabase/migrations/20260810b_same_order_supplier_price_concurrency_hardening_v1.sql",
  "supabase/migrations/20260810c_same_order_supplier_price_terminal_boundary_v1.sql",
];

const existingActions = read(existingActionsPath);
const headerMigration = read(headerMigrationPath);
const canonicalApprovalMigration = read(canonicalApprovalMigrationPath);
const page = read(pagePath);
const readiness = read(readinessPath);
const priceActions = read(priceActionsPath);
const migrationSource = migrations.map(read).join("\n\n");

// Freeze the two working seams the user explicitly prohibited us from changing.
assert(
  gitBlobSha(existingActions) === "f6d486b141a6cf298a9a72deea0cd3b046b27fe9",
  "existing invoice-review actions.ts changed; header/OCR/reject actions must remain untouched",
);
assert(
  gitBlobSha(headerMigration) === "c163b4b1699722950f0527d326c26714ce044378",
  "existing supplier header-review migration changed",
);
assert(
  gitBlobSha(canonicalApprovalMigration) === "223cd49297c7e22987abea6b40db1092e10e10f7",
  "existing canonical supplier approval migration changed",
);

assert(
  !/create\s+or\s+replace\s+function\s+public\.staff_save_supplier_invoice_header_review\s*\(/i.test(migrationSource),
  "new migrations replace the existing header-review RPC",
);
assert(
  !/create\s+or\s+replace\s+function\s+public\.staff_approve_supplier_invoice_current\s*\(/i.test(migrationSource),
  "new migrations replace the existing supplier-approval RPC",
);

// New server action: only order id + note; browser cannot submit the new total.
assert(priceActions.includes('readString(formData, "order_id")'), "price action does not read order_id");
assert(!priceActions.includes('readString(formData, "new_order'), "price action accepts a browser-supplied new order value");
assert(!priceActions.includes('formData.get("new_order'), "price action accepts a browser-supplied new order value");
assert(priceActions.includes('rpc("staff_approve_order_supplier_price_increase_v1"'), "price action does not call dedicated RPC");
assert(!priceActions.includes("staff_save_supplier_invoice_header_review"), "price action is coupled to header-review RPC");

// Queue stays an exceptions queue; only one deterministic live over-limit anchor is retained.
assert(page.includes('from("order_supplier_price_position_v1")'), "invoice review page does not bulk-read live supplier price position");
assert(page.includes("review_anchor_supplier_invoice_id === invoice.id"), "invoice review page does not retain only the deterministic price anchor");
assert(page.includes("if (isPriceReviewAnchor(invoice, pricePosition)) return true;"), "price anchor is not retained before normal routing-away logic");
assert(page.includes("pricePositionUnavailable && invoice.review_status === \"pending_review\""), "price-position query failure does not retain pending invoices fail-safe");
assert(page.includes("Approve order price increase"), "dedicated price-increase action is not rendered");
assert(page.includes("Finish the ordinary invoice/header or delivery/discount verification first"), "unverified supplier evidence does not suppress executable price approval");

// Existing Save correction remains in place and keeps its pre-existing projection-only disable rule.
assert(page.includes("action={saveSupplierInvoiceHeaderReviewAction}"), "existing Save header correction form was removed");
assert(page.includes("disabled={Boolean(ocrHeaderTotalsError)}"), "existing Save correction disable rule changed");

// Shared readiness only adds the new check after established invoice readiness succeeds.
assert(readiness.includes("assertVerifiedSupplierBundleWithinOrderValue"), "shared readiness lacks live price check");
assert(readiness.includes("if (unsettledLineIds.length === 0)"), "existing settled-line fast path was lost");
assert(readiness.includes("return assertVerifiedSupplierBundleWithinOrderValue(supabase, String(invoice.order_id));"), "otherwise-ready invoice does not receive live price check");
for (const flag of [
  "wrong_invoice",
  "ocr_unclear",
  "invoice_total_mismatch",
  "delivery_discount_query",
  "manual_line_needed",
  "order_bundle_limit_breach",
]) {
  assert(readiness.includes(`\"${flag}\"`), `existing serious review flag ${flag} disappeared`);
}

// Database source contract.
assert(migrationSource.includes("order_supplier_price_position_v1"), "live order supplier price position is missing");
assert(migrationSource.includes("accepted_invoice_gross_gbp"), "new price position invents a total instead of reusing accepted supplier gross");
assert(migrationSource.includes("unverified_invoice_count"), "verified-bundle control is missing");
assert(migrationSource.includes("missing_accepted_total_count"), "missing accepted supplier totals are not fail-closed");
assert(migrationSource.includes("review_anchor_supplier_invoice_id"), "deterministic review anchor is missing");
assert(migrationSource.includes("trg_enforce_supplier_invoice_order_price_limit_v1"), "database approval transition backstop is missing");
assert(migrationSource.includes("AFTER INSERT OR UPDATE OF order_id, review_status, blocked_from_sage_yn, ocr_invoice_total_gbp, ocr_raw_json"), "approval backstop does not cover insert/update approved-current state");
assert(migrationSource.includes("pg_advisory_xact_lock(hashtext('order_bundle_limit:' || p_order_id::text))"), "price RPC does not reuse bundle-limit concurrency lock");
assert(migrationSource.includes("v_position.review_anchor_supplier_invoice_id IS NULL"), "price RPC can execute without a live pending review anchor");
assert(migrationSource.includes("v_order.content_locked_at IS NOT NULL"), "content lock is not respected");
assert(migrationSource.includes("v_order.accounting_release_ready_at IS NOT NULL"), "accounting release boundary is missing");
assert(migrationSource.includes("v_order.vat_release_approved_at IS NOT NULL"), "VAT release boundary is missing");
assert(migrationSource.includes("v_order.vat_return_period IS NOT NULL"), "VAT reporting boundary is missing");
assert(migrationSource.includes("event_type = 'funding_reversed'"), "funding reversal history is not fail-closed");
assert(migrationSource.includes("source_type = 'overfunding'"), "order-sourced overfunding credit is not fail-closed");
assert(migrationSource.includes("order_pending_funding_surplus"), "pending funding surplus is not fail-closed");
assert(migrationSource.includes("ABS(COALESCE(v_order.markup_applied_gbp, 0)) > 0.005"), "non-zero markup is not fail-closed in v1");
assert(migrationSource.includes("public.order_funding_total_gbp(p_order_id)"), "canonical funding event total is not checked");
assert(migrationSource.includes("public.order_funding_position_vw"), "live funding position is not checked");
assert(migrationSource.includes("public.recompute_order_platform_funded(p_order_id)"), "funded_at is not recomputed after order value change");
assert(migrationSource.includes("public.sync_order_overfunding_credit(p_order_id)"), "existing safe overfunding synchroniser is not called");
assert(migrationSource.includes("v_event_count_after <> v_event_count_before"), "price amendment does not prove it created no funding event");
assert(migrationSource.includes("v_order.quote_total_ghs / v_old_total"), "stored effective local quote rate is not preserved");
assert(!/set\s+bundled_quote_gbp\s*=/i.test(migrationSource), "price build improperly rewrites bundled_quote_gbp");
assert(!/set\s+bundled_final_gbp\s*=/i.test(migrationSource), "price build improperly rewrites bundled_final_gbp");

console.log("PASS: same-order supplier price increase source regression v1");
