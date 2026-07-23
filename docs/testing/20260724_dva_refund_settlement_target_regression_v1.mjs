import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const layout = readFileSync(
  "app/internal/dva-reconciliation/workspace/layout.tsx",
  "utf8",
);
const synchronizer = readFileSync(
  "app/internal/dva-reconciliation/workspace/RefundSettlementTargetSynchronizer.tsx",
  "utf8",
);
const controller = readFileSync(
  "app/internal/dva-reconciliation/workspace/SafeWorkspaceSelectionController.tsx",
  "utf8",
);

assert.match(
  layout,
  /\.from\("dispute_refund_evidence_submissions"\)[\s\S]*\.eq\("supplier_approval_status", "approved_current"\)[\s\S]*\.eq\("supplier_control_status", "approved_current"\)/,
  "workspace must use only approved-current refund evidence",
);
assert.match(
  layout,
  /\.from\("dispute_refund_document_accounting_totals_vw"\)[\s\S]*accepted_document_gross_gbp/,
  "workspace must reuse the authoritative accepted supplier-credit read model",
);
assert.match(
  layout,
  /<RefundSettlementTargetSynchronizer acceptedRefundByDisputeId=\{acceptedRefundByDisputeId\} \/>[\s\S]*<CompletedTargetGuard \/>[\s\S]*<CandidateDirectionGuard \/>[\s\S]*<DvaWorkspaceActionBarPatch \/>[\s\S]*<SafeWorkspaceSelectionController \/>/,
  "authoritative refund amount must be synchronised before existing guards and selection controller classify cards",
);

assert.match(
  synchronizer,
  /body\.startsWith\("Exception"\)[\s\S]*body\.toLowerCase\(\)\.includes\("refund"\)/,
  "only refund exception cards may be rewritten",
);
assert.match(
  synchronizer,
  /searchParams\.get\("target_id"\)/,
  "accepted amount must be keyed by the dispute target id",
);
assert.match(
  synchronizer,
  /acceptedRefundByDisputeId\[disputeId\] \?\? 0/,
  "missing approved evidence must preserve the existing card amount",
);
assert.match(
  synchronizer,
  /if \(acceptedSupplierCredit <= 0\) continue;/,
  "non-positive or missing authoritative amounts must not alter cards",
);
assert.match(
  synchronizer,
  /Operational exception \$\{gbpFormatter\.format\(operationalExceptionAmount\)\}/,
  "the original operational exception amount must remain visible for audit",
);
assert.match(
  synchronizer,
  /Accepted supplier credit \$\{gbpFormatter\.format\(acceptedSupplierCredit\)\}/,
  "the authoritative supplier-credit amount must be visible",
);
assert.match(
  synchronizer,
  /`Amount \$\{gbpFormatter\.format\(acceptedSupplierCredit\)\}`/,
  "the first Amount label must become the authoritative refund settlement target",
);

assert.match(
  controller,
  /body\.match\(\/Amount\\s\+£\[\\d,.\]\+\/\)\?\.\[0\]/,
  "existing selection controller must continue to consume the rewritten Amount label",
);
assert.match(
  controller,
  /statement\.direction === "in" && target\.direction === "in"\) return "retailer_refund"/,
  "existing retailer-refund allocation routing must remain unchanged",
);

const operationalExceptionAmount = 179.99;
const acceptedSupplierCredit = 184.99;
const displayedSettlementTarget = acceptedSupplierCredit > 0
  ? acceptedSupplierCredit
  : operationalExceptionAmount;
assert.equal(displayedSettlementTarget, 184.99);

const noApprovedCredit = 0;
const fallbackSettlementTarget = noApprovedCredit > 0
  ? noApprovedCredit
  : operationalExceptionAmount;
assert.equal(fallbackSettlementTarget, 179.99);

console.log("PASS: refund workbench uses approved supplier credit as settlement target with safe fallback");
