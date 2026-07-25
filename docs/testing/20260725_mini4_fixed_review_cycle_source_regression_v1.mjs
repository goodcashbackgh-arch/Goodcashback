import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const cyclePath = "supabase/migrations/20260725zz_mini4_fixed_deadline_review_cycle_v1.sql";
const aclPath = "supabase/migrations/20260725zz1_mini4_private_helper_acl_v1.sql";
const holdPath = "supabase/migrations/20260725zzz_mini4_exact_hold_membership_bridge_v1.sql";
const hardeningPath = "supabase/migrations/20260725zzzz_mini4_review_cycle_integrity_hardening_v1.sql";
const alignmentPath = "supabase/migrations/20260725zzzzz_mini4_legacy_deadline_alignment_v1.sql";
const finalPath = "supabase/migrations/20260725zzzzzz_mini4_final_scope_alignment_v1.sql";
const payloadPath = "supabase/migrations/20260725zzzzzz_mini4_review_payload_compat_v1.sql";

const cycle = readFileSync(cyclePath, "utf8");
const acl = readFileSync(aclPath, "utf8");
const hold = readFileSync(holdPath, "utf8");
const hardening = readFileSync(hardeningPath, "utf8");
const alignment = readFileSync(alignmentPath, "utf8");
const finalAlignment = readFileSync(finalPath, "utf8");
const payload = readFileSync(payloadPath, "utf8");
const executableCycle = cycle.replace(/'(?:''|[^'])*'/g, "''");

assert.match(cycle, /CREATE TABLE public\.customer_review_cycle_memberships/);
assert.match(cycle, /goods_amount_gbp/);
assert.match(cycle, /delivery_share_gbp/);
assert.match(cycle, /discount_share_gbp/);
assert.match(cycle, /PERFORM pg_advisory_xact_lock/);
assert.match(cycle, /candidate\.receipt_recorded_at < v_deadline/);
assert.match(cycle, /v_deadline := v_anchor_receipt \+ interval '24 hours'/);
assert.doesNotMatch(executableCycle, /SET\s+expires_at\s*=\s*v_deadline/);
assert.match(cycle, /CREATE TRIGGER trg_customer_review_receipt_materialize_v1/);
assert.match(cycle, /customer_tracking_review_deadline_v1/);
assert.match(cycle, /shipper_shipment_batch_candidates_v1/);
assert.match(cycle, /shipper_create_shipment_batch_v1/);
assert.match(cycle, /link_row\.expires_at IS NULL/);

assert.match(acl, /FROM PUBLIC, anon, authenticated/);
assert.match(acl, /TO service_role/);
assert.match(acl, /Mini 4 private helper execution leaked to authenticated/);

assert.match(hold, /CREATE TABLE public\.customer_hold_review_memberships/);
assert.match(hold, /CREATE TRIGGER trg_customer_hold_00_review_membership_sync_v1/);
assert.match(hold, /CREATE OR REPLACE FUNCTION public\.customer_hold_refund_target_lines_v1/);
assert.match(hold, /Timed hold % has no exact review membership/);
assert.match(hold, /Exact legacy implementation retained for untimed links only/);
assert.match(hold, /existing customer_hold_create_refund_exception_v2 function and its/);

assert.match(hardening, /customer_review_cycle_membership_net_nonnegative_chk/);
assert.match(hardening, /BEFORE INSERT OR UPDATE OR DELETE\s+ON public\.customer_review_cycle_memberships/);
assert.match(hardening, /BEFORE INSERT OR UPDATE OR DELETE\s+ON public\.customer_hold_review_memberships/);
assert.match(hardening, /CREATE TRIGGER trg_customer_review_link_fixed_deadline_guard_v1/);
assert.match(hardening, /New customer review links require a fixed deadline/);
assert.match(hardening, /Customer review cycle deadline is immutable/);
assert.match(hardening, /link_row\.expires_at IS NULL/);
assert.match(hardening, /now\(\) >= latest_receipt\.recorded_at/);
assert.match(hardening, /now\(\) < latest_receipt\.recorded_at \+ interval '24 hours'/);
assert.match(hardening, /shipper_shipment_batch_packages/);
assert.match(hardening, /package_row\.active = true/);

assert.match(alignment, /trg_customer_review_cycle_00_cumulative_qty_guard_v1/);
assert.match(alignment, /FOR UPDATE/);
assert.match(alignment, /v_existing_review_qty \+ NEW\.review_qty > v_allocated_qty/);
assert.match(alignment, /trg_customer_review_resolve_expired_legacy_issue_v1/);
assert.match(alignment, /customer_review_cycle_legacy_issues/);
assert.match(alignment, /pre_mini4_timed_membership_unproven/);
assert.match(alignment, /p_receipt_recorded_at < link_row\.expires_at/);
assert.match(alignment, /p_receipt_recorded_at \+ interval '24 hours'/);

assert.match(finalAlignment, /FROM PUBLIC, anon, authenticated/);
assert.match(finalAlignment, /TO service_role/);
assert.match(finalAlignment, /CREATE TRIGGER trg_customer_review_cycle_01_component_guard_v1/);
assert.match(finalAlignment, /Customer review membership value components do not match the exact allocation and quantity/);
assert.match(finalAlignment, /ROUND\(v_existing_review_qty, 3\)/);
assert.match(finalAlignment, /Open-cycle join is governed only by the already stored deadline/);
assert.match(finalAlignment, /WHERE candidate\.receipt_recorded_at < v_deadline\s+ON CONFLICT DO NOTHING/s);
assert.match(finalAlignment, /IF TG_OP = 'INSERT'/);
assert.match(finalAlignment, /Timed hold % has no frozen review membership/);
assert.match(finalAlignment, /Customer hold target cannot move outside its frozen review membership/);

assert.match(payload, /'qty', supplier_line\.qty/);
assert.match(payload, /'amount_inc_vat_gbp', supplier_line\.amount_inc_vat_gbp/);
assert.doesNotMatch(payload, /'qty', membership\.review_qty/);
assert.doesNotMatch(payload, /'amount_inc_vat_gbp', membership\.(goods_amount_gbp|delivery_share_gbp|discount_share_gbp)/);
assert.match(payload, /Customer review payload compatibility proof failed/);

for (const source of [cycle, acl, hold, hardening, alignment, finalAlignment, payload]) {
  assert.doesNotMatch(source, /CREATE OR REPLACE FUNCTION public\.internal_resolved_customer_sales_sage_payload_v1/);
  assert.doesNotMatch(source, /CREATE OR REPLACE FUNCTION public\.internal_supplier_goods_ap/);
  assert.doesNotMatch(source, /CREATE OR REPLACE FUNCTION public\.internal_create_cash_control_batch_v1/);
  assert.doesNotMatch(source, /CREATE TABLE .*cash_posting/i);
  assert.doesNotMatch(source, /CREATE TABLE .*customer_hold_released_credit_requirements/i);
  assert.doesNotMatch(source, /CREATE TABLE .*customer_hold_credit_note_documents/i);
  assert.doesNotMatch(source, /src\/lib\/sage\/posting/);
}

console.log("PASS: Mini 4 is limited to fixed review cycles, exact hold provenance, integrity guards, legacy deadline alignment, unchanged review payload values and existing shipment deadline consumers");
