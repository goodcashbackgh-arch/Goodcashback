import { readFileSync } from "node:fs";

function read(path) { return readFileSync(path, "utf8"); }
function requireText(path, values) {
  const text = read(path);
  for (const value of values) {
    if (!text.includes(value)) throw new Error(`${path} missing required contract: ${value}`);
  }
  return text;
}

const migration = requireText("supabase/migrations/20260802100000_hybrid_physical_receipt_operational_reads_v1.sql", [
  "importer_physical_receipt_reviews_v1",
  "staff_physical_receipt_reviews_v1",
  "can_read_physical_receipt_evidence_v1",
  "physical_receipt_evidence_importer_read_v1",
  "physical_receipt_evidence_staff_read_v1",
  "auth.uid()",
  "operator_importers",
  "SECURITY DEFINER",
  "REVOKE ALL",
  "FROM PUBLIC, anon",
  "TO authenticated",
  "review.status IN ('awaiting_importer_proposal','returned_for_information')",
  "review.status = 'awaiting_supervisor_review'",
  "physical_receipt_review_dispute_links",
  "desired_outcome",
]);
if (/service_role|SUPABASE_SERVICE_ROLE_KEY/i.test(migration)) throw new Error("Operational reads introduce service-role access.");
if (/\b(INSERT|UPDATE|DELETE)\b/i.test(migration.replace(/COMMENT ON[\s\S]*?;/gi, ""))) throw new Error("Operational read migration contains a data write statement.");

requireText("app/importer/layout.tsx", ["Physical Receipt Exceptions", "action_count", "/importer/physical-receipts"]);
requireText("app/internal/layout.tsx", ["Physical Receipt Reviews", "action_count", "/internal/physical-receipts"]);
requireText("app/importer/physical-receipts/page.tsx", ["ACTIONABLE", "currently require importer action"]);
requireText("app/internal/physical-receipts/page.tsx", ["awaiting_supervisor_review", "currently require supervisor action"]);

const importerAction = requireText("app/importer/physical-receipts/[review_id]/actions.ts", [
  "operator_submit_physical_receipt_proposal_v1",
  "p_proposals",
  "p_proposal_note",
  "Number.isInteger",
  "positive whole unit",
]);
if (/approved_|liable_party|supplier_cost_mode/.test(importerAction)) throw new Error("Importer action contains supervisor-only decision fields.");

const importerForm = requireText("app/importer/physical-receipts/[review_id]/ProposalForm.tsx", [
  "Add split",
  "refund",
  "replacement",
  "hold_investigate",
  "no_action",
  "Number.isInteger",
  "whole units",
]);
if (/approved_|liable_party|supplier_cost_mode/.test(importerForm)) throw new Error("Importer form contains supervisor-only decision fields.");

requireText("app/internal/physical-receipts/[review_id]/actions.ts", [
  "staff_decide_physical_receipt_review_v1",
  "p_allocations",
  "p_decision_note",
  "Number.isInteger",
  "close_no_action",
  "no_liability",
]);
requireText("app/internal/physical-receipts/[review_id]/DecisionForm.tsx", [
  "return_for_information",
  "approve_existing_exception",
  "approve_investigation",
  "close_no_action",
  "supplier_cost_mode",
  "allowedTypes",
  "Number.isInteger",
  "changeDecision",
]);
requireText("app/internal/physical-receipts/[review_id]/page.tsx", ["linked_disputes", "/internal/exceptions/"]);

requireText("docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md", [
  "whole units only",
  "Whole-unit remedy proposals and decisions",
  "default importer queue",
  "Receipt evidence access must be authorised",
  "rollback-only database and browser regression",
]);

const dbRegression = requireText("docs/testing/20260802_hybrid_physical_receipt_operational_reads_regression_v1.sql", [
  "BEGIN;",
  "ROLLBACK;",
  "can_read_physical_receipt_evidence_v1",
  "physical_receipt_evidence_importer_read_v1",
  "physical_receipt_evidence_staff_read_v1",
]);
if (!dbRegression.trimEnd().endsWith("ROLLBACK;")) throw new Error("Operational read regression is not rollback-only.");

console.log("PASS — physical receipt importer/supervisor operational UI source contracts passed");
