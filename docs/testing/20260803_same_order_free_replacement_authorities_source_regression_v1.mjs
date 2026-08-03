import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const acceptancePath = path.join(root, "supabase/migrations/20260803210000_same_order_free_replacement_acceptance_v1.sql");
const allocationPath = path.join(root, "supabase/migrations/20260803211000_same_order_free_replacement_tracking_allocation_v1.sql");
const foundationPath = path.join(root, "supabase/migrations/20260803203000_same_order_free_replacement_foundation_v1.sql");

for (const file of [acceptancePath, allocationPath, foundationPath]) {
  if (!fs.existsSync(file)) throw new Error(`Missing governed file: ${path.relative(root, file)}`);
}

const acceptance = fs.readFileSync(acceptancePath, "utf8");
const allocation = fs.readFileSync(allocationPath, "utf8");
const foundation = fs.readFileSync(foundationPath, "utf8");
const combined = `${acceptance}\n${allocation}`;

function requireText(source, text, label = text) {
  if (!source.includes(text)) throw new Error(`Missing required source contract: ${label}`);
}
function forbidText(source, text, label = text) {
  if (source.includes(text)) throw new Error(`Forbidden source scope found: ${label}`);
}

requireText(foundation, "CREATE TABLE public.physical_replacement_same_order_routes");
requireText(foundation, "CREATE FUNCTION public.tracking_allocation_effective_entitlement_v1");
requireText(acceptance, "CREATE FUNCTION public.staff_accept_same_order_free_replacement_v1");
requireText(allocation, "CREATE FUNCTION public.operator_allocate_same_order_replacement_tracking_v1");

requireText(acceptance, "p_confirmed_supplier_cost_mode");
requireText(acceptance, "free_replacement");
requireText(acceptance, "v_disposition.quantity");
requireText(acceptance, "replacement_child_order_id IS NOT NULL");
requireText(acceptance, "resolved_via_child_order_id IS NOT NULL");
requireText(acceptance, "replacement_child_order_id=NULL");
requireText(acceptance, "resolved_via_child_order_id=NULL");
requireText(acceptance, "status='in_progress'");
requireText(acceptance, "SAME_ORDER_FREE_REPLACEMENT");

requireText(allocation, "Duplicate route IDs are not allowed");
requireText(allocation, "ots.superseded_at IS NULL");
requireText(allocation, "ORDER BY r.id FOR UPDATE");
requireText(allocation, "ORDER BY a.id FOR UPDATE");
requireText(allocation, "tracking_allocation_effective_entitlement_v1");
requireText(allocation, "Negative effective entitlement produced");
requireText(allocation, "Successor allocation changed effective line quantity/value");
requireText(allocation, "SAME_ORDER_REPLACEMENT_TRACKING_ALLOCATED");

for (const forbidden of [
  "staff_accept_replacement_outcome_v1(",
  "create_replacement_child_order_v2(",
  "create_replacement_child_order(",
  "order_has_open_child_exceptions_v3",
  "recompute_order_status_v2",
  "CREATE OR REPLACE FUNCTION public.physical_remedy_allocation_guard",
  "CREATE OR REPLACE FUNCTION public.physical_remedy_sequence_guard",
  "CREATE OR REPLACE FUNCTION public.physical_receipt_review_guard",
  "ALTER TABLE public.physical_exception_remedy_allocations",
  "ALTER TABLE public.physical_receipt_reviews",
  "ALTER TABLE public.dispute_lines",
  "ALTER TABLE public.disputes",
]) forbidText(combined, forbidden);

for (const forbiddenDomain of [
  "sage_",
  "supplier_ap",
  "dva_",
  "customer_sales",
  "vat_",
  "shipment_batch",
  "customer_review_cycle",
  "customer_pre_shipment_hold",
]) forbidText(combined.toLowerCase(), forbiddenDomain, `unrelated domain ${forbiddenDomain}`);

const acceptanceCreateCount = (acceptance.match(/CREATE FUNCTION public\.staff_accept_same_order_free_replacement_v1/g) ?? []).length;
const allocationCreateCount = (allocation.match(/CREATE FUNCTION public\.operator_allocate_same_order_replacement_tracking_v1/g) ?? []).length;
if (acceptanceCreateCount !== 1 || allocationCreateCount !== 1) {
  throw new Error(`Expected exactly one authority definition each; got acceptance=${acceptanceCreateCount}, allocation=${allocationCreateCount}`);
}

console.log(JSON.stringify({
  result: "PASS",
  proof: "same-order acceptance and atomic successor allocation are additive, child-free, closure-free, Mini-Build-preserving and effective-entitlement guarded",
}, null, 2));
