import fs from "node:fs";
import crypto from "node:crypto";

function read(path) { return fs.readFileSync(path, "utf8"); }
function assert(condition, message) { if (!condition) throw new Error(`FAIL: ${message}`); }
function gitBlobSha(text) {
  const body = Buffer.from(text, "utf8");
  const header = Buffer.from(`blob ${body.length}\0`, "utf8");
  return crypto.createHash("sha1").update(header).update(body).digest("hex");
}

const existingActions = read("app/internal/invoice-review/actions.ts");
const headerMigration = read("supabase/migrations/20260730_supplier_invoice_header_net_vat_review_v1.sql");
const canonicalApprovalMigration = read("supabase/migrations/20260719b_multi_supplier_invoice_sibling_safe_review_v1.sql");
const readiness = read("app/internal/invoice-review/readiness.ts");
const page = read("app/internal/invoice-review/page.tsx");
const priceActions = read("app/internal/invoice-review/price-actions.ts");
const migration = read("supabase/migrations/20260810_same_order_supplier_price_increase_v1.sql");
const addendum = read("docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md");

assert(gitBlobSha(existingActions) === "f6d486b141a6cf298a9a72deea0cd3b046b27fe9", "existing invoice-review actions changed");
assert(gitBlobSha(headerMigration) === "c163b4b1699722950f0527d326c26714ce044378", "existing header-review migration changed");
assert(gitBlobSha(canonicalApprovalMigration) === "223cd49297c7e22987abea6b40db1092e10e10f7", "existing canonical supplier approval migration changed");
assert(gitBlobSha(readiness) === "95e1193fa60fbd08bb756c2d7f2cd447ae46354e", "shared supplier approval readiness changed");

assert(!/create\s+or\s+replace\s+function\s+public\.staff_save_supplier_invoice_header_review\s*\(/i.test(migration), "header-review RPC replaced");
assert(!/create\s+or\s+replace\s+function\s+public\.staff_approve_supplier_invoice_current\s*\(/i.test(migration), "supplier-approval RPC replaced");
assert(!/create\s+or\s+replace\s+function\s+public\.flag_order_bundle_limit_after_summary_v1\s*\(/i.test(migration), "existing bundle INSERT authority replaced");
assert(!migration.includes("order_supplier_price_position_v1"), "discarded commercial read model returned");
assert(!migration.includes("enforce_supplier_invoice_order_price_limit_v1"), "discarded global approval trigger returned");
assert(!migration.includes("accepted_invoice_gross_gbp"), "discarded accepted-gross authority returned");

assert(page.includes("function shouldShowInInvoiceReview(invoice: InvoiceRow, decision: MatchDecisionRow | undefined)"), "existing queue helper replaced");
assert(page.includes('if (["needs_invoice_review", "ocr_pending"].includes(decision.routing_decision)) return true;'), "existing queue routing changed");
assert(page.includes('flag.flag_type === "order_bundle_limit_breach"'), "price card is not gated by existing breach flag");
assert(page.includes('order?.order_type === "original"'), "price card is not literal-original only");
assert(page.includes('supplier_invoice_financial_summary(invoice_total_gbp)'), "price display does not use existing summary source");
assert(page.includes("Approve order price increase"), "price card missing");
assert(page.includes('name="supplier_invoice_id" value={invoice.id}'), "breach invoice provenance missing");
assert(!/name=["'](?:amount|new_order|new_total)/i.test(page), "browser form exposes monetary authority");
assert(page.includes("action={saveSupplierInvoiceHeaderReviewAction}"), "existing Save form removed");

assert(priceActions.includes('readString(formData, "order_id")'), "price action missing order id");
assert(priceActions.includes('readString(formData, "supplier_invoice_id")'), "price action missing supplier invoice id");
assert(priceActions.includes('rpc("staff_approve_order_supplier_price_increase_v1"'), "price action missing dedicated RPC");
assert(!/formData\.get\([^)]*(amount|new_order|new_total)/i.test(priceActions), "price action accepts browser amount");

assert(migration.includes("protect_order_bundle_limit_breach_resolution_v1"), "breach protector missing");
assert(migration.includes("BEFORE UPDATE OF status, resolved_by_staff_id, resolved_at, resolution_notes"), "breach protector trigger scope changed");
assert(migration.includes("pg_advisory_xact_lock(hashtext('order_bundle_limit:' || v_order_id::text))"), "breach protector does not use existing bundle lock");
assert(migration.includes("NEW.status := OLD.status"), "Save path does not preserve live breach");
assert(migration.includes("v_invoice_status IN ('approved_current','ref_corrected_approved')"), "approval-state hard stop missing");
assert(migration.includes("OR v_blocked_from_sage IS FALSE"), "accounting-unblocked hard stop missing");
assert(migration.includes("Cannot approve supplier invoice while active supplier invoices exceed the accepted order value"), "approval bypass is not transactionally rejected");

assert(migration.includes("flag_order_bundle_limit_after_summary_update_v1"), "summary UPDATE companion missing");
assert(migration.includes("AFTER UPDATE OF invoice_total_gbp"), "summary UPDATE trigger scope changed");
assert(migration.includes("v_order_type IS DISTINCT FROM 'original'"), "summary UPDATE trigger does not fail closed on non-original/NULL type");
assert(migration.includes("COALESCE(NEW.entered_by_operator_id, OLD.entered_by_operator_id)"), "summary UPDATE trigger loses operator provenance");
assert(migration.includes("Supplier invoice total update would create an order bundle limit breach, but genuine operator provenance is missing"), "missing provenance does not fail closed");

const rpcStart = migration.indexOf("CREATE OR REPLACE FUNCTION public.staff_approve_order_supplier_price_increase_v1");
const summaryLock = migration.indexOf("FOR UPDATE OF fs;", rpcStart);
const invoiceLock = migration.indexOf("FOR UPDATE OF si;", summaryLock + 1);
const breachLock = migration.indexOf("FOR UPDATE OF f;", invoiceLock + 1);
const advisoryLock = migration.indexOf("pg_advisory_xact_lock(hashtext('order_bundle_limit:' || p_order_id::text))", breachLock + 1);
const orderLock = migration.indexOf("WHERE o.id = p_order_id\n  FOR UPDATE;", advisoryLock + 1);
assert(rpcStart >= 0 && summaryLock > rpcStart && invoiceLock > summaryLock && breachLock > invoiceLock && advisoryLock > breachLock && orderLock > advisoryLock,
  "price RPC lock order must remain summary -> invoice -> breach flag -> advisory -> order");

assert(migration.includes("v_order.order_type IS DISTINCT FROM 'original'"), "RPC does not require literal original type");
assert(migration.includes("f.supplier_invoice_id = p_supplier_invoice_id"), "RPC not bound to exact breach invoice");
assert(migration.includes("f.flag_type = 'order_bundle_limit_breach'"), "RPC not bound to existing breach type");
assert(migration.includes("f.status IN ('open','under_review')"), "RPC accepts resolved breach history");
assert(migration.includes("sum(fs.invoice_total_gbp)"), "RPC does not derive server amount from existing summary bundle");
assert(!/p_(?:amount|new_total|new_order)/i.test(migration.match(/CREATE OR REPLACE FUNCTION public\.staff_approve_order_supplier_price_increase_v1[\s\S]*?RETURNS TABLE/)?.[0] ?? ""), "RPC exposes monetary parameter");
assert(migration.includes("v_order.content_locked_at IS NOT NULL"), "content lock missing");
assert(migration.includes("v_order.accounting_release_ready_at IS NOT NULL"), "accounting terminal boundary missing");
assert(migration.includes("v_order.vat_release_approved_at IS NOT NULL"), "VAT release boundary missing");
assert(migration.includes("event_type = 'funding_reversed'"), "funding reversal fail-close missing");
assert(migration.includes("source_type = 'overfunding'"), "overfunding fail-close missing");
assert(migration.includes("order_pending_funding_surplus"), "surplus fail-close missing");
assert(migration.includes("public.order_funding_total_gbp(p_order_id)"), "canonical funding total check missing");
assert(migration.includes("public.order_funding_position_vw"), "funding view consistency check missing");
assert(migration.includes("v_order.quote_total_ghs / v_old_total"), "stored quote ratio not preserved");
assert(migration.includes("public.recompute_order_platform_funded(p_order_id)"), "funded_at recompute missing");
assert(migration.includes("public.sync_order_overfunding_credit(p_order_id)"), "safe existing overfunding synchroniser missing");
assert(migration.includes("v_event_count_after <> v_event_count_before"), "concurrent/new funding-event guard missing");

assert(!migration.includes("FOR UPDATE OF ofe"), "price RPC locks funding event rows");
assert(!migration.includes("FOR UPDATE OF icl"), "price RPC locks credit-ledger rows");
assert(!migration.includes("FOR UPDATE OF ps"), "price RPC locks pending-surplus rows");
assert(!/set\s+bundled_quote_gbp\s*=/i.test(migration), "legacy bundled_quote_gbp rewritten");
assert(!/set\s+bundled_final_gbp\s*=/i.test(migration), "legacy bundled_final_gbp rewritten");
assert(addendum.includes("summary rows for the order deterministically → supplier-invoice rows deterministically → exact open breach flag → existing `order_bundle_limit:<order_id>` advisory lock → order row"), "addendum lock order does not match runtime");
assert(addendum.includes("no superseded/no-op migration files are authorised"), "addendum does not lock branch-cleanup scope");

console.log("PASS: same-order supplier price increase source regression v1");
