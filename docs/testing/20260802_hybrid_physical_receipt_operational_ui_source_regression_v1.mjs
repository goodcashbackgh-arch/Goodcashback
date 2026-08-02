import { readFileSync } from "node:fs";

function read(path) { return readFileSync(path, "utf8"); }
function requireText(path, values) {
  const text = read(path);
  for (const value of values) if (!text.includes(value)) throw new Error(`${path} missing required contract: ${value}`);
  return text;
}

const reads = requireText("supabase/migrations/20260802100000_hybrid_physical_receipt_operational_reads_v1.sql", [
  "importer_physical_receipt_reviews_v1", "staff_physical_receipt_reviews_v1",
  "can_read_physical_receipt_evidence_v1", "operator_importers", "SECURITY DEFINER",
  "review.status IN ('awaiting_importer_proposal','returned_for_information')",
  "review.status = 'awaiting_supervisor_review'", "desired_outcome",
]);
if (/service_role|SUPABASE_SERVICE_ROLE_KEY/i.test(reads)) throw new Error("Operational reads introduce service-role browser access.");

const importerV2 = requireText("supabase/migrations/20260802103000_hybrid_physical_receipt_whole_unit_proposal_authority_v2.sql", [
  "operator_submit_physical_receipt_proposal_v2", "operator_submit_physical_receipt_proposal_v1",
  "proposal_row.proposed_remedy_qty <> TRUNC(proposal_row.proposed_remedy_qty)",
  "FROM PUBLIC, anon, authenticated", "TO authenticated",
]);
const supervisorV2 = requireText("supabase/migrations/20260802104000_hybrid_physical_receipt_supervisor_whole_unit_gateway_v2.sql", [
  "staff_decide_physical_receipt_review_v2", "staff_decide_physical_receipt_review_v1",
  "allocation_row.approved_remedy_qty <> TRUNC(allocation_row.approved_remedy_qty)",
  "FROM PUBLIC, anon, authenticated", "TO authenticated",
]);
for (const [name, text] of [["importer", importerV2], ["supervisor", supervisorV2]]) {
  if (/ABS\s*\([\s\S]*ROUND\s*\(/i.test(text)) throw new Error(`${name} gateway uses tolerance-based whole-unit validation.`);
  if (/CREATE OR REPLACE FUNCTION public\.physical_remedy_/i.test(text)) throw new Error(`${name} gateway modifies a protected remedy authority.`);
}

const importerAction = requireText("app/importer/physical-receipts/[review_id]/actions.ts", [
  "operator_submit_physical_receipt_proposal_v2", "Number.isInteger", "positive whole unit",
]);
if (importerAction.includes("operator_submit_physical_receipt_proposal_v1")) throw new Error("Importer application calls v1 directly.");

const supervisorAction = requireText("app/internal/physical-receipts/[review_id]/actions.ts", [
  "staff_decide_physical_receipt_review_v2", "Number.isInteger", "close_no_action", "no_liability",
]);
if (supervisorAction.includes("staff_decide_physical_receipt_review_v1")) throw new Error("Supervisor application calls v1 directly.");

const supervisorForm = requireText("app/internal/physical-receipts/[review_id]/DecisionForm.tsx", [
  "canApproveExisting", "initialDecision", "rowForDecision", "disabled={!canApproveExisting}",
  "This decision changes every listed proposal to Hold / investigate.",
  "This decision closes every listed proposal with no action.",
]);
if (/proposedType[^\n]*:[^\n]*"refund"/.test(supervisorForm)) throw new Error("Supervisor form silently defaults incompatible proposals to refund.");

requireText("app/importer/layout.tsx", ["Physical Receipt Exceptions", "action_count"]);
requireText("app/internal/layout.tsx", ["Physical Receipt Reviews", "action_count"]);
requireText("app/internal/physical-receipts/[review_id]/page.tsx", ["linked_disputes", "/internal/exceptions/"]);
requireText("docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md", [
  "Importer authenticated write boundary", "Supervisor authenticated write boundary",
  "Mandatory implementation artefacts", "Required behavioral database proof", "Required authenticated browser proof",
]);

const behavior = requireText("docs/testing/20260802_hybrid_physical_receipt_operational_authority_behavior_regression_v1.sql", [
  "BEGIN;", "SET LOCAL ROLE authenticated", "ROLLBACK;",
  "runtime_importer_v1_denial", "runtime_supervisor_v1_denial",
  "Importer queue is not action-only", "Supervisor queue is not action-only",
  "ARRAY[0::numeric,-1::numeric,1.0004::numeric,1.5::numeric]",
  "importer_valid", "supervisor_return", "supervisor_reject",
  "supervisor_investigation", "supervisor_no_action", "supervisor_existing",
  "physical_receipt_review_dispute_links", "storage.objects",
]);
if (!behavior.trimEnd().endsWith("ROLLBACK;")) throw new Error("Behavior regression is not rollback-only.");

const browser = requireText("docs/testing/20260802_hybrid_physical_receipt_browser_acceptance_v1.mjs", [
  "PLAYWRIGHT_BASE_URL", "IMPORTER_A_STORAGE_STATE", "IMPORTER_B_STORAGE_STATE",
  "SUPERVISOR_STORAGE_STATE", "ORDINARY_STAFF_STORAGE_STATE", "PHYSICAL_REVIEW_ID",
  "prepareSplitProposal", "submitProposal", "return_for_information",
  "Browser resubmission", "approve_existing_exception", "Linked disputes",
  "Expected exactly two linked outcome-specific disputes", "Ordinary staff direct supervisor access",
]);
if (!browser.includes('fill("1.5")') || !browser.includes('fill("1")')) {
  throw new Error("Browser acceptance does not prove fractional blocking followed by valid whole-unit submission.");
}

console.log("PASS — physical receipt operational source contracts passed");
