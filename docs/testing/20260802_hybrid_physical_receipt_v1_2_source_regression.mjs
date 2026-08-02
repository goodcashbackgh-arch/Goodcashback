import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

function read(path) {
  return readFileSync(new URL(`../../${path}`, import.meta.url), "utf8");
}

const addendum = read("docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md");
const shipperActions = read("app/shipper/actions.ts");
const shipperPage = read("app/shipper/return-actions/page.tsx");
const replacementOperatorAction = read("app/importer/exceptions/[dispute_id]/replacement-return-actions.ts");
const replacementOperatorForm = read("app/importer/exceptions/[dispute_id]/ReplacementOriginalItemReturnForm.tsx");
const replacementSupervisorPanel = read("app/internal/exceptions/[dispute_id]/ReplacementReturnEvidenceReviewPanel.tsx");
const replacementReturnMigration = read("supabase/migrations/20260802211500_hybrid_physical_receipt_replacement_return_adapters_v1.sql");
const exactRepairMigration = read("supabase/migrations/20260802212500_hybrid_physical_receipt_exact_gbp60_repair_v1.sql");

assert.match(addendum, /locked technical specification and non-regression authority/i);
assert.match(addendum, /The builder must not guess/i);
assert.match(addendum, /staff_decide_physical_receipt_review_v2/);
assert.match(addendum, /create_replacement_child_order_v2/);

assert.match(shipperActions, /rpc\("shipper_submit_return_task_confirmation_v2"/);
assert.doesNotMatch(shipperActions, /rpc\("shipper_submit_return_task_confirmation_v1"/);

assert.match(shipperPage, /rpc\("shipper_return_tasks_v2"/);
assert.doesNotMatch(shipperPage, /rpc\("shipper_return_tasks_v1"/);
assert.match(shipperPage, /Original item return for replacement/);
assert.match(shipperPage, /refund exceptions and original-item returns for approved physical replacements/i);

assert.match(replacementOperatorAction, /operator_submit_replacement_return_collection_tracking_v1/);
assert.match(replacementOperatorAction, /Add retailer instructions, a return label, a tracking reference, a tracking URL, or a meaningful note/);
assert.match(replacementOperatorAction, /Final return\/collection requires courier, tracking reference and tracking date/);
assert.doesNotMatch(replacementOperatorAction, /operator_submit_return_collection_tracking\b/);

assert.match(replacementOperatorForm, /Original damaged item return \/ collection/);
assert.match(replacementOperatorForm, /Missing items cannot use this action/);
assert.match(replacementOperatorForm, /Save the shipper-facing instructions before the replacement child is created/);
assert.match(replacementOperatorForm, /uploadReplacementReturnCollectionAction/);

assert.match(replacementSupervisorPanel, /Operational return evidence review/);
assert.match(replacementSupervisorPanel, /does not approve supplier refund value, customer settlement, accounting, or replacement-child funding/);
assert.match(replacementSupervisorPanel, /reviewReturnCollectionEvidenceAction/);
assert.match(replacementSupervisorPanel, /return_tracking_submission_id/);

assert.match(replacementReturnMigration, /CREATE FUNCTION public\.operator_submit_replacement_return_collection_tracking_v1/);
assert.match(replacementReturnMigration, /CREATE FUNCTION public\.shipper_return_tasks_v2/);
assert.match(replacementReturnMigration, /CREATE FUNCTION public\.shipper_submit_return_task_confirmation_v2/);
assert.match(replacementReturnMigration, /CREATE UNIQUE INDEX uq_shipper_return_task_one_pending_v1/);
assert.match(replacementReturnMigration, /disposition_type IN \('damaged','wrong'\)/);
assert.match(replacementReturnMigration, /RETURN public\.shipper_submit_return_task_confirmation_v1/);
assert.match(replacementReturnMigration, /resolved_via_child_order_id = d\.replacement_child_order_id/);

assert.match(exactRepairMigration, /9e7f6c25-e920-4c90-a16a-0ffb6381a3d6/);
assert.match(exactRepairMigration, /126ed01a-09b4-47e4-a2db-c52e7480d814/);
assert.match(exactRepairMigration, /d7b32314-603e-49bf-83d1-1a01e2e4d29f/);
assert.match(exactRepairMigration, /60\.00/);
assert.match(exactRepairMigration, /RAISE EXCEPTION/);

console.log("hybrid physical receipt v1.2 source regression passed");
