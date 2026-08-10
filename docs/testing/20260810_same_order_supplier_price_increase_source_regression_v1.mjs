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
const adjustmentActions = read("app/internal/adjustments/actions.ts");
const headerMigration = read("supabase/migrations/20260730_supplier_invoice_header_net_vat_review_v1.sql");
const canonicalApprovalMigration = read("supabase/migrations/20260719b_multi_supplier_invoice_sibling_safe_review_v1.sql");
const existingBundleMigration = read("supabase/migrations/20260725_order_bundle_limit_supervisor_flag_v1.sql");
const readiness = read("app/internal/invoice-review/readiness.ts");
const page = read("app/internal/invoice-review/page.tsx");
const priceActions = read("app/internal/invoice-review/price-actions.ts");
const migration = read("supabase/migrations/20260810_same_order_supplier_price_increase_v1.sql");
const addendum = read("docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md");

// Frozen working seams.
assert(gitBlobSha(existingActions) === "f6d486b141a6cf298a9a72deea0cd3b046b27fe9", "existing invoice-review actions changed");
assert(gitBlobSha(adjustmentActions) === "3349f9763842a0a4ca4d8d9b200b85b71c9413ef", "existing adjustment actions changed");
assert(gitBlobSha(headerMigration) === "c163b4b1699722950f0527d326c26714ce044378", "existing header-review migration changed");
assert(gitBlobSha(canonicalApprovalMigration) === "223cd49297c7e22987abea6b40db1092e10e10f7", "existing canonical supplier approval migration changed");
assert(gitBlobSha(existingBundleMigration) === "61404ff2a1b41c876da02436a99939dbf3eac053", "existing operator bundle migration changed");
assert(gitBlobSha(readiness) === "95e1193fa60fbd08bb756c2d7f2cd447ae46354e", "shared supplier approval readiness changed");

assert(!/create\s+or\s+replace\s+function\s+public\.staff_save_supplier_invoice_header_review\s*\(/i.test(migration), "header-review RPC replaced");
assert(!/create\s+or\s+replace\s+function\s+public\.staff_approve_supplier_invoice_current\s*\(/i.test(migration), "supplier-approval RPC replaced");
assert(!/create\s+or\s+replace\s+function\s+public\.flag_order_bundle_limit_after_summary_v1\s*\(/i.test(migration), "existing operator bundle INSERT authority replaced");
assert(!migration.includes("order_supplier_price_position_v1"), "discarded commercial read model returned");
assert(!migration.includes("enforce_supplier_invoice_order_price_limit_v1"), "discarded global approval trigger returned");

// Existing page/action seam remains client-non-authoritative.
assert(page.includes("function shouldShowInInvoiceReview(invoice: InvoiceRow, decision: MatchDecisionRow | undefined)"), "existing queue helper replaced");
assert(page.includes('if (["needs_invoice_review", "ocr_pending"].includes(decision.routing_decision)) return true;'), "existing queue routing changed");
assert(page.includes('flag.flag_type === "order_bundle_limit_breach"'), "price card is not gated by existing breach flag");
assert(page.includes('order?.order_type === "original"'), "price card is not literal-original only");
assert(page.includes('supplier_invoice_financial_summary(invoice_total_gbp)'), "price display does not use existing summary source");
assert(!/name=["'](?:amount|new_order|new_total)/i.test(page), "browser form exposes monetary authority");
assert(priceActions.includes('rpc("staff_approve_order_supplier_price_increase_v1"'), "price action missing dedicated RPC");
assert(!/formData\.get\([^)]*(amount|new_order|new_total)/i.test(priceActions), "price action accepts browser amount");

// Gap 1: new flag protection is literal-original only.
assert(migration.includes("protect_order_bundle_limit_breach_resolution_v1"), "breach protector missing");
assert(migration.includes("SELECT o.order_type::text"), "breach protector does not resolve order type");
assert(migration.includes("IF v_order_type IS DISTINCT FROM 'original' THEN\n    RETURN NEW;"), "non-original breach resolution is not left untouched");
assert(migration.includes("NEW.status := OLD.status"), "original-order Save path does not preserve live breach");
assert(migration.includes("v_invoice_status IN ('approved_current','ref_corrected_approved')"), "approval hard stop missing");

// Gap 2: companion is only the supervisor-entered upsert seam.
assert(migration.includes("flag_order_bundle_limit_after_supervisor_summary_change_v1"), "supervisor summary companion missing");
assert(migration.includes("AFTER INSERT OR UPDATE OF invoice_total_gbp"), "supervisor summary companion does not cover INSERT+total UPDATE");
assert(migration.includes("IF TG_OP = 'INSERT'"), "INSERT branch missing");
assert(migration.includes("NEW.source IS DISTINCT FROM 'supervisor_entered'"), "companion is not supervisor-entered scoped");
assert(migration.includes("NEW.invoice_total_gbp IS NOT DISTINCT FROM OLD.invoice_total_gbp"), "unchanged UPDATE is not ignored");
assert(migration.includes("v_order_type IS DISTINCT FROM 'original'"), "supervisor companion is not original-only");
assert(migration.includes("v_raised_by_operator_id := NEW.entered_by_operator_id"), "supervisor INSERT genuine provenance path missing");
assert(migration.includes("COALESCE(NEW.entered_by_operator_id, OLD.entered_by_operator_id)"), "supervisor UPDATE genuine provenance path missing");
assert(migration.includes("genuine operator provenance is missing"), "missing provenance does not fail closed");
assert(!migration.includes("entered_by_operator_id = v_staff"), "staff identity is fabricated as operator provenance");

// Gap 3: accepted gross is validator only; summary remains monetary authority.
assert(migration.includes("supplier_invoice_accounting_coding_totals_vw"), "accepted-gross consistency validator missing");
assert(migration.includes("accepted_invoice_gross_gbp"), "accepted gross is not checked");
assert(migration.includes("abs(fs.invoice_total_gbp - t.accepted_invoice_gross_gbp) > 0.01"), "stale-summary per-invoice mismatch gate missing");
assert(migration.includes("Reconcile the supplier invoice total first"), "stale-summary mismatch does not fail closed clearly");
assert(migration.includes("SELECT round(COALESCE(sum(fs.invoice_total_gbp), 0)::numeric, 2)\n  INTO v_new_total"), "financial-summary bundle is no longer the monetary authority");
assert(!/v_new_total\s*:=\s*[^;]*accepted_invoice_gross_gbp/i.test(migration), "accepted gross became monetary authority");
assert(!/update\s+public\.supplier_invoice_financial_summary[\s\S]{0,250}accepted_invoice_gross_gbp/i.test(migration), "price RPC rewrites financial summary from accepted gross");

const rpcStart = migration.indexOf("CREATE OR REPLACE FUNCTION public.staff_approve_order_supplier_price_increase_v1");
const summaryLock = migration.indexOf("FOR UPDATE OF fs;", rpcStart);
const invoiceLock = migration.indexOf("FOR UPDATE OF si;", summaryLock + 1);
const breachLock = migration.indexOf("FOR UPDATE OF f;", invoiceLock + 1);
const advisoryLock = migration.indexOf("pg_advisory_xact_lock(hashtext('order_bundle_limit:' || p_order_id::text))", breachLock + 1);
const orderLock = migration.indexOf("WHERE o.id = p_order_id\n  FOR UPDATE;", advisoryLock + 1);
assert(rpcStart >= 0 && summaryLock > rpcStart && invoiceLock > summaryLock && breachLock > invoiceLock && advisoryLock > breachLock && orderLock > advisoryLock,
  "price RPC lock order changed");

assert(migration.includes("v_order.order_type IS DISTINCT FROM 'original'"), "RPC does not require literal original type");
assert(migration.includes("f.supplier_invoice_id = p_supplier_invoice_id"), "RPC not bound to exact breach invoice");
assert(!/p_(?:amount|new_total|new_order)/i.test(migration.match(/CREATE OR REPLACE FUNCTION public\.staff_approve_order_supplier_price_increase_v1[\s\S]*?RETURNS TABLE/)?.[0] ?? ""), "RPC exposes monetary parameter");
assert(migration.includes("v_order.content_locked_at IS NOT NULL"), "content lock missing");
assert(migration.includes("public.order_funding_total_gbp(p_order_id)"), "funding total check missing");
assert(migration.includes("public.order_funding_position_vw"), "funding-view check missing");
assert(migration.includes("v_order.quote_total_ghs / v_old_total"), "stored quote ratio not preserved");
assert(migration.includes("public.recompute_order_platform_funded(p_order_id)"), "funded_at recompute missing");
assert(migration.includes("public.sync_order_overfunding_credit(p_order_id)"), "existing overfunding synchroniser missing");
assert(!migration.includes("FOR UPDATE OF ofe"), "price RPC locks funding event rows");
assert(!migration.includes("FOR UPDATE OF icl"), "price RPC locks credit-ledger rows");
assert(!migration.includes("FOR UPDATE OF ps"), "price RPC locks pending-surplus rows");
assert(!/set\s+bundled_quote_gbp\s*=/i.test(migration), "bundled_quote_gbp rewritten");
assert(!/set\s+bundled_final_gbp\s*=/i.test(migration), "bundled_final_gbp rewritten");

assert(addendum.includes("frozen both **definitionally and behaviourally**"), "working-part non-regression lock missing");
assert(addendum.includes("The only authorised behavioural interventions are:"), "four-intervention scope lock missing");
assert(addendum.includes("All other summary writes retain existing behaviour."), "supervisor companion scope is ambiguous");
assert(addendum.includes("use accepted gross only as a consistency validator"), "accepted gross validation-only rule missing");
assert(addendum.includes("no further runtime change is authorised to `page.tsx`, `price-actions.ts`, `app/internal/adjustments/actions.ts`"), "corrective file/runtime scope widened");

console.log("PASS: same-order supplier price increase source regression v1");
