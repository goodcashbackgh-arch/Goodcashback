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
const primaryMigrationPath = "supabase/migrations/20260810_same_order_supplier_price_increase_v1.sql";
const noopMigrationPaths = [
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
const primaryMigration = read(primaryMigrationPath);
const noopMigrations = noopMigrationPaths.map(read);
const migrationSource = [primaryMigration, ...noopMigrations].join("\n\n");

// Existing working seams stay byte-for-byte unchanged.
assert(
  gitBlobSha(existingActions) === "f6d486b141a6cf298a9a72deea0cd3b046b27fe9",
  "existing invoice-review actions.ts changed",
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
  gitBlobSha(readiness) === "95e1193fa60fbd08bb756c2d7f2cd447ae46354e",
  "shared supplier approval readiness changed; existing serious-flag routing must remain authoritative",
);

assert(
  !/create\s+or\s+replace\s+function\s+public\.staff_save_supplier_invoice_header_review\s*\(/i.test(migrationSource),
  "new migration replaces the frozen header-review RPC",
);
assert(
  !/create\s+or\s+replace\s+function\s+public\.staff_approve_supplier_invoice_current\s*\(/i.test(migrationSource),
  "new migration replaces the existing supplier-approval RPC",
);
assert(
  !/create\s+or\s+replace\s+function\s+public\.flag_order_bundle_limit_after_summary_v1\s*\(/i.test(migrationSource),
  "new migration replaces the existing bundle-limit INSERT authority",
);

// Price server action is provenance-bound and accepts no new amount.
assert(priceActions.includes('readString(formData, "order_id")'), "price action does not read order_id");
assert(priceActions.includes('readString(formData, "supplier_invoice_id")'), "price action does not bind to breach invoice provenance");
assert(priceActions.includes('p_supplier_invoice_id: supplierInvoiceId'), "price action does not pass breach invoice provenance");
assert(priceActions.includes('rpc("staff_approve_order_supplier_price_increase_v1"'), "price action does not call dedicated RPC");
assert(!/formData\.get\([^)]*(amount|new_order|new_total)/i.test(priceActions), "price action accepts a browser-supplied amount");
assert(!priceActions.includes("staff_save_supplier_invoice_header_review"), "price action is coupled to header review");

// Supplier Invoice Review keeps its original queue/routing logic. The new card is
// driven only by the already-open serious breach flag.
assert(page.includes("function shouldShowInInvoiceReview(invoice: InvoiceRow, decision: MatchDecisionRow | undefined)"), "original queue routing helper was replaced");
assert(page.includes('if (["needs_invoice_review", "ocr_pending"].includes(decision.routing_decision)) return true;'), "original match-decision queue routing changed");
assert(!page.includes("order_supplier_price_position_v1"), "discarded live-price authority is still wired into the page");
assert(!page.includes("review_anchor_supplier_invoice_id"), "discarded custom review-anchor model remains");
assert(page.includes('flag.flag_type === "order_bundle_limit_breach"'), "price card is not gated by the existing breach flag");
assert(page.includes('order?.order_type === "original"'), "price card is not original-order only");
assert(page.includes('supplier_invoice_financial_summary(invoice_total_gbp)'), "price display does not reuse the existing financial-summary source");
assert(page.includes("Approve order price increase"), "dedicated price-increase card is missing");
assert(page.includes('name="supplier_invoice_id" value={invoice.id}'), "price form does not carry breach invoice provenance");
assert(!/name=["'](?:amount|new_order|new_total)/i.test(page), "price form exposes a client monetary authority");
assert(page.includes("action={saveSupplierInvoiceHeaderReviewAction}"), "existing Save correction form was removed");
assert(page.includes("disabled={Boolean(ocrHeaderTotalsError)}"), "existing Save correction disable rule changed");

// Narrow DB seam 1: protect only the existing bundle breach from false resolve.
assert(primaryMigration.includes("protect_order_bundle_limit_breach_resolution_v1"), "bundle breach resolution protection is missing");
assert(primaryMigration.includes("BEFORE UPDATE OF status, resolved_by_staff_id, resolved_at, resolution_notes"), "bundle breach protection is not a narrow BEFORE UPDATE trigger");
assert(primaryMigration.includes("OLD.flag_type IS DISTINCT FROM 'order_bundle_limit_breach'"), "bundle breach protection is not flag-type scoped");
assert(primaryMigration.includes("NEW.status := OLD.status"), "persistent breach can still be resolved by generic Save");
assert(primaryMigration.includes("supplier_invoice_financial_summary fs"), "breach protection does not reuse existing financial-summary arithmetic");

// Narrow DB seam 2: preserve existing INSERT trigger and close only total UPDATE.
assert(primaryMigration.includes("flag_order_bundle_limit_after_summary_update_v1"), "summary UPDATE breach guard is missing");
assert(primaryMigration.includes("AFTER UPDATE OF invoice_total_gbp"), "summary UPDATE guard is broader than the proven total-update hole");
assert(primaryMigration.includes("pg_advisory_xact_lock(hashtext('order_bundle_limit:' || v_order_id::text))"), "summary UPDATE guard does not reuse the existing bundle lock family");
assert(primaryMigration.includes("v_order_type <> 'original'"), "summary UPDATE guard is not original-order scoped");
assert(primaryMigration.includes("COALESCE(NEW.entered_by_operator_id, OLD.entered_by_operator_id)"), "summary UPDATE breach does not preserve real operator provenance");
assert(primaryMigration.includes("f.raised_by_operator_id"), "summary UPDATE breach lacks existing-flag provenance fallback");
assert(primaryMigration.includes("no review flag was falsely attributed"), "missing operator provenance does not fail closed explicitly");
assert(!primaryMigration.includes("raised_by_operator_id\n    ) VALUES"), "source sanity placeholder");

// Narrow DB seam 3: dedicated server-derived same-order amendment.
assert(primaryMigration.includes("staff_approve_order_supplier_price_increase_v1(\n  p_order_id uuid,\n  p_supplier_invoice_id uuid,"), "dedicated RPC signature is not provenance-bound");
assert(primaryMigration.includes("f.supplier_invoice_id = p_supplier_invoice_id"), "RPC does not require the exact open breach invoice");
assert(primaryMigration.includes("f.flag_type = 'order_bundle_limit_breach'"), "RPC does not require the existing breach flag");
assert(primaryMigration.includes("f.status IN ('open','under_review')"), "RPC accepts resolved breach history");
assert(primaryMigration.includes("sum(fs.invoice_total_gbp)"), "RPC does not derive amount from existing summary bundle");
assert(!primaryMigration.includes("accepted_invoice_gross_gbp"), "RPC reintroduces discarded accepted-gross authority");
assert(!primaryMigration.includes("order_supplier_price_position_v1"), "RPC reintroduces discarded live-price read authority");
assert(!primaryMigration.includes("enforce_supplier_invoice_order_price_limit_v1"), "global supplier-approval transition guard remains");

const summaryLock = primaryMigration.indexOf("FOR UPDATE OF fs;", primaryMigration.indexOf("CREATE OR REPLACE FUNCTION public.staff_approve_order_supplier_price_increase_v1"));
const invoiceLock = primaryMigration.indexOf("FOR UPDATE OF si;", summaryLock + 1);
const advisoryLock = primaryMigration.indexOf("pg_advisory_xact_lock(hashtext('order_bundle_limit:' || p_order_id::text))", invoiceLock + 1);
const orderLock = primaryMigration.indexOf("WHERE o.id = p_order_id\n  FOR UPDATE;", advisoryLock + 1);
const breachFlagLock = primaryMigration.indexOf("FOR UPDATE OF f;", orderLock + 1);
assert(summaryLock >= 0 && invoiceLock > summaryLock && advisoryLock > invoiceLock && orderLock > advisoryLock && breachFlagLock > orderLock,
  "price RPC lock order must remain summary rows -> invoice rows -> advisory lock -> order -> breach flag");

assert(primaryMigration.includes("v_order.content_locked_at IS NOT NULL"), "content lock is not respected");
assert(primaryMigration.includes("v_order.accounting_release_ready_at IS NOT NULL"), "accounting release boundary is missing");
assert(primaryMigration.includes("v_order.vat_release_approved_at IS NOT NULL"), "VAT release boundary is missing");
assert(primaryMigration.includes("v_order.vat_return_period IS NOT NULL"), "VAT reporting boundary is missing");
assert(primaryMigration.includes("event_type = 'funding_reversed'"), "funding reversal history is not fail-closed");
assert(primaryMigration.includes("source_type = 'overfunding'"), "order-sourced overfunding credit is not fail-closed");
assert(primaryMigration.includes("order_pending_funding_surplus"), "pending funding surplus is not fail-closed");
assert(primaryMigration.includes("ABS(COALESCE(v_order.markup_applied_gbp, 0)) > 0.005"), "non-zero markup is not fail-closed in v1");
assert(primaryMigration.includes("public.order_funding_total_gbp(p_order_id)"), "canonical funding event total is not checked");
assert(primaryMigration.includes("public.order_funding_position_vw"), "live funding position is not checked");
assert(primaryMigration.includes("public.recompute_order_platform_funded(p_order_id)"), "funded_at is not recomputed");
assert(primaryMigration.includes("public.sync_order_overfunding_credit(p_order_id)"), "safe existing overfunding synchroniser is not retained");
assert(primaryMigration.includes("v_event_count_after <> v_event_count_before"), "amendment does not prove it created no funding event");
assert(primaryMigration.includes("v_order.quote_total_ghs / v_old_total"), "stored effective local quote rate is not preserved");
assert(!/set\s+bundled_quote_gbp\s*=/i.test(primaryMigration), "price build improperly rewrites bundled_quote_gbp");
assert(!/set\s+bundled_final_gbp\s*=/i.test(primaryMigration), "price build improperly rewrites bundled_final_gbp");

// The three earlier branch-only corrective drafts must remain inert.
for (const [index, source] of noopMigrations.entries()) {
  assert(!/create\s+or\s+replace\s+(?:function|view)/i.test(source), `superseded corrective migration ${index + 1} still creates runtime authority`);
  assert(!/create\s+trigger/i.test(source), `superseded corrective migration ${index + 1} still creates a trigger`);
}

console.log("PASS: same-order supplier price increase source regression v1");
