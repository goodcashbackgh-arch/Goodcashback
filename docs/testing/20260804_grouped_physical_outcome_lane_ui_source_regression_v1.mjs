import { readFileSync } from "node:fs";

function read(path) {
  return readFileSync(path, "utf8");
}

function requireText(path, values) {
  const text = read(path);
  for (const value of values) {
    if (!text.includes(value)) throw new Error(`${path} missing required contract: ${value}`);
  }
  return text;
}

const readMigration = requireText(
  "supabase/migrations/20260804002500_extend_staff_physical_receipt_reads_with_outcome_lanes_v1.sql",
  [
    "staff_physical_receipt_reviews_v1",
    "outcome_lanes",
    "caller_staff_id",
    "lane_status='awaiting_supervisor_decision'",
    "physical_receipt_outcome_lane_decision_items",
    "outcome_lane_action_count",
    "review.status='awaiting_supervisor_review'",
    "SECURITY DEFINER",
  ],
);
if (/service_role|SUPABASE_SERVICE_ROLE_KEY/i.test(readMigration)) {
  throw new Error("Grouped lane staff read introduces service-role browser access.");
}
if (!readMigration.trimEnd().endsWith("COMMIT;")) {
  throw new Error("Grouped lane staff read migration does not commit explicitly.");
}

const action = requireText(
  "app/internal/physical-receipts/[review_id]/actions.ts",
  [
    "decidePhysicalOutcomeLaneAction",
    "staff_decide_physical_outcome_lane_v1",
    "refund_settlement_credit",
    "replacement_accept",
    "supervisor_confirmed_credit",
    "p_item_decisions",
    "p_staff_id",
    "new Set(allocationIds).size",
  ],
);
if (/service_role|SUPABASE_SERVICE_ROLE_KEY/i.test(action)) {
  throw new Error("Grouped lane action introduces a service-role browser write.");
}
if (action.includes("staff_close_refund_exception_as_settlement_credit_v1") || action.includes("staff_accept_same_order_free_replacement_v1")) {
  throw new Error("UI bypasses the grouped lane authority and calls downstream authorities directly.");
}

const form = requireText(
  "app/internal/physical-receipts/[review_id]/OutcomeLaneDecisionForm.tsx",
  [
    "one grouped action applies to every item shown in this lane",
    "Settle grouped refund to credit balance",
    "Accept grouped same-order free replacement",
    "allocation_ids_json",
    "Supervisor note",
    "!confirmed",
  ],
);
if ((form.match(/<button/g) ?? []).length !== 1) {
  throw new Error("Grouped lane form must expose exactly one decision button.");
}
if (/checkbox[^\n]*name=/i.test(form)) {
  throw new Error("Grouped lane form exposes per-item selectable approval controls.");
}

requireText(
  "app/internal/physical-receipts/[review_id]/page.tsx",
  [
    "Grouped outcome lanes",
    "OutcomeLaneDecisionForm",
    "lane.can_decide",
    "Credit-balance settlement",
    "Same-order free replacement",
    "latest_decision",
    "caller_staff_id",
  ],
);

requireText(
  "app/internal/physical-receipts/page.tsx",
  [
    "Physical Receipt Actions",
    "initial_review_action_count",
    "outcome_lane_action_count",
    "activeLanes",
    "lane.can_decide",
  ],
);

const refundRegression = requireText(
  "docs/testing/20260803_physical_outcome_lane_grouped_supervisor_refund_rollback_regression_v2.sql",
  [
    "refund_settlement_mode='credit_balance'",
    "conversation_status='resolved_credit'",
    "expected one exact GBP 60 settlement credit",
    "identical authenticated replay did not return stored result",
    "ROLLBACK;",
  ],
);
if (!refundRegression.trimEnd().endsWith("ROLLBACK;")) {
  throw new Error("Grouped refund behavioral regression is not rollback-only.");
}

console.log("PASS — grouped physical outcome lane UI source contracts passed");
