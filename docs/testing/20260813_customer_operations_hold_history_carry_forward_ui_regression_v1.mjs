import fs from "node:fs";

const pagePath = "app/customer/orders/[order_id]/operations/page.tsx";
const authorityPath = "docs/governing-pack/ui/CUSTOMER_OPERATIONS_HOLD_HISTORY_CARRY_FORWARD_ADDENDUM_v1.md";

const page = fs.readFileSync(pagePath, "utf8");
const authority = fs.readFileSync(authorityPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
}

const accessGate = 'if (!access) redirect("/customer");';
const holdQuery = '.from("customer_pre_shipment_hold_requests")';
const paymentSummary = '<summary className="cursor-pointer list-none text-xl font-black">Payment details</summary>';
const evidenceSummary = '<summary className="cursor-pointer list-none text-xl font-black">Order evidence</summary>';
const holdSummary = '<summary className="cursor-pointer list-none text-xl font-black">Hold request history</summary>';

assert(authority.includes("This file is the governing authority for the customer operations-page hold-history carry-forward."), "governing authority marker missing");
assert(authority.includes("No database migration, schema change, RPC creation/replacement"), "authority does not prohibit backend scope creep");

assert(page.includes('type HoldHistoryRow = {'), "hold-history type missing");
assert(page.includes(holdQuery), "hold-history table read missing");
assert(page.indexOf(accessGate) >= 0 && page.indexOf(holdQuery) > page.indexOf(accessGate), "hold-history read is not after the existing access gate");
assert(page.includes('.eq("order_id", orderId).eq("requested_scope", "line").not("supplier_invoice_line_id", "is", null).order("created_at", { ascending: false })'), "hold-history read is not tightly scoped to current order line holds");
assert(page.includes('supplier_invoice_lines(description, qty, amount_inc_vat_gbp)'), "hold identity does not reuse the existing supplier-line relationship");

assert(page.includes('if (hold.status === "requested" || hold.status === "rejected") return false;'), "requested/rejected exclusion missing");
assert(page.includes('return hold.status === "supervisor_approved" || Boolean(hold.converted_dispute_id);'), "approved/actioned qualification rule missing");
assert(page.includes('holdHistoryRes.error ? []'), "optional history read does not fail closed without breaking existing page");

assert(page.includes('{holdHistory.length > 0 ? ('), "zero-history conditional rendering gate missing");
assert(page.includes(holdSummary), "Hold request history summary missing");
assert(page.indexOf(paymentSummary) >= 0, "Payment details summary missing");
assert(page.indexOf(evidenceSummary) > page.indexOf(paymentSummary), "Order evidence no longer follows Payment details");
assert(page.indexOf(holdSummary) > page.indexOf(evidenceSummary), "Hold request history is not appended after Order evidence");

const holdDetailsStart = page.lastIndexOf('<details className="mt-5 rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm">', page.indexOf(holdSummary));
assert(holdDetailsStart >= 0, "Hold request history details wrapper missing");
const holdDetailsHeader = page.slice(holdDetailsStart, page.indexOf(holdSummary));
assert(!/\bopen(?:=|\s|>)/.test(holdDetailsHeader), "Hold request history must be collapsed by default");

assert(page.includes('<p className="font-black">Item hold</p>'), "existing Item hold presentation missing");
assert(page.includes('{friendly(hold.status)}'), "existing hold status presentation missing");
assert(page.includes('{line.description}'), "historical line description missing");
assert(page.includes('Qty {line.qty ?? "—"}{line.amount_inc_vat_gbp != null ? ` · ${money(line.amount_inc_vat_gbp)}` : ""}'), "null-safe qty/amount presentation missing");
assert(page.includes('{hold.reason}'), "hold reason missing");
assert(page.includes('Review note:'), "supervisor review-note presentation missing");

assert(!/\.from\("customer_pre_shipment_hold_requests"\)[\s\S]{0,800}\.(insert|update|delete|upsert)\(/.test(page), "prohibited hold-table write detected");
assert(!page.includes('customer_review_cycle_memberships'), "membership machinery was introduced into operations page");
assert(!page.includes('customer_review_ready_line_ids_v1'), "review-ready machinery was introduced into operations page");

console.log(JSON.stringify({
  verdict: "PASS — CUSTOMER OPERATIONS HOLD HISTORY CARRY-FORWARD UI REGRESSION",
  authority: authorityPath,
  runtime_file: pagePath,
  checks: {
    access_gate_preserved_before_read: true,
    order_scoped_read: true,
    requested_rejected_excluded: true,
    approved_or_converted_only: true,
    zero_history_hidden: true,
    appended_after_order_evidence: true,
    collapsed_by_default: true,
    existing_history_presentation_reused: true,
    null_safe_amount: true,
    no_hold_writes: true,
    no_membership_or_review_ready_logic: true
  }
}, null, 2));
