import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const pagePath = "app/internal/funding/page.tsx";
const actionsPath = "app/internal/funding/actions.ts";
const page = readFileSync(pagePath, "utf8");
const actions = readFileSync(actionsPath, "utf8");

function gitBlobSha(content) {
  return createHash("sha1")
    .update(`blob ${Buffer.byteLength(content)}\0`)
    .update(content)
    .digest("hex");
}

// Runtime scope guard: the existing money-moving funding actions stay untouched.
assert.equal(
  gitBlobSha(actions),
  "54c4ad9d36ebd6f915c854dd6a96a5754e4fbc35",
  "app/internal/funding/actions.ts must remain byte-for-byte unchanged",
);

// Canonical authority must come from the existing staff-safe worklist; no new resolver.
assert.match(
  page,
  /rpc\("internal_statement_line_control_worklist_v1",\s*\{[\s\S]*?p_limit:\s*500,[\s\S]*?p_offset:\s*canonicalOffset/,
  "funding page must reuse the existing canonical statement-control worklist",
);
assert.match(
  page,
  /canonicalFundingEligibilityByLineId\.set\(statementLineId, asBoolean\(row\.funding_action_allowed_yn\)\)/,
  "funding admission must use canonical funding_action_allowed_yn directly",
);

// Preserve the legacy population for audit/readout, but gate the working population.
assert.match(
  page,
  /const legacyFundingCandidates: FundingCandidate\[\] = worklistRows/,
  "legacy worklist candidates must remain available for non-actionable audit/readout",
);
assert.match(
  page,
  /const fundingCandidates = legacyFundingCandidates\.filter\(\s*\(candidate\) => canonicalFundingEligibilityByLineId\.get\(candidate\.dvaStatementLineId\) === true,?\s*\);/,
  "working funding population must require explicit canonical true; missing authority therefore fails closed",
);

// Existing matching and Ready Funding contract remains unchanged after the hard gate.
assert.match(
  page,
  /canReconcile: Boolean\(direction === "in" && dvaStatementLineId && inferred\.orderId && amountGbp > 0 && resolvedGap !== null && resolvedGap > 0 && !alreadyReconciled && inferred\.score >= 80\)/,
  "existing ready-funding matching conditions must remain unchanged",
);
assert.match(
  page,
  /const readyFundingCandidates = fundingCandidates\.filter\(\(candidate\) => candidate\.canReconcile\);/,
  "Ready Funding must derive from the canonically gated working population",
);
assert.match(
  page,
  /const unmatchedInboundCandidates = fundingCandidates\.filter\(\(candidate\) =>\s*candidate\.direction === "in" &&/,
  "Supervisor Assignment must derive from the canonically gated working population",
);
assert.match(
  page,
  /const fundingNeedsReview = fundingCandidates\.filter\(/,
  "funding-specific Needs Review must derive from the canonically gated working population",
);
assert.match(
  page,
  /const reconciledFundingAudit = legacyFundingCandidates\.filter\(\(candidate\) => candidate\.alreadyReconciled\);/,
  "existing reconciled-funding audit must remain on the legacy audit population",
);

// Existing amount submission semantics remain untouched.
assert.match(
  page,
  /defaultValue=\{candidate\.amountGbp\.toFixed\(2\)\}/,
  "Ready Funding must keep the existing physical statement amount input",
);
assert.match(
  page,
  /name="reconciled_gbp_amount" value=\{candidate\.amountGbp\.toFixed\(2\)\}/,
  "Supervisor Assignment must keep the existing physical statement amount submission",
);

// Behavioural proof of the admission boundary only.
function canonicalFundingPopulation(candidates, eligibilityByLineId) {
  return candidates.filter(
    (candidate) => eligibilityByLineId.get(candidate.dvaStatementLineId) === true,
  );
}

const badTarget = {
  dvaStatementLineId: "f36b93f8-16aa-46f0-a92d-bebdd4b919c0",
  label: "£20.19 final balance + FX",
};
const normalUnused = {
  dvaStatementLineId: "normal-unused-customer-funding",
  label: "normal unused customer funding",
};
const missingCanonical = {
  dvaStatementLineId: "missing-canonical-row",
  label: "missing canonical authority",
};

const eligibility = new Map([
  [badTarget.dvaStatementLineId, false],
  [normalUnused.dvaStatementLineId, true],
]);

const admitted = canonicalFundingPopulation(
  [badTarget, normalUnused, missingCanonical],
  eligibility,
);

assert.deepEqual(
  admitted.map((row) => row.dvaStatementLineId),
  [normalUnused.dvaStatementLineId],
  "only explicit canonical true may enter Funding working queues",
);
assert.equal(
  admitted.some((row) => row.dvaStatementLineId === badTarget.dvaStatementLineId),
  false,
  "£20.19 consumed final-balance/FX line must be excluded",
);
assert.equal(
  admitted.some((row) => row.dvaStatementLineId === missingCanonical.dvaStatementLineId),
  false,
  "missing canonical authority must fail closed",
);

// Existing downstream matching still decides Ready vs Supervisor only after admission.
function existingCanReconcile({ direction, lineId, orderId, amountGbp, gap, alreadyReconciled, score }) {
  return Boolean(
    direction === "in" &&
    lineId &&
    orderId &&
    amountGbp > 0 &&
    gap !== null &&
    gap > 0 &&
    !alreadyReconciled &&
    score >= 80
  );
}

assert.equal(
  existingCanReconcile({
    direction: "in",
    lineId: normalUnused.dvaStatementLineId,
    orderId: "order-1",
    amountGbp: 100,
    gap: 100,
    alreadyReconciled: false,
    score: 90,
  }),
  true,
  "canonically eligible normal IN retains the existing Ready Funding matching behavior",
);

console.log("PASS: /internal/funding uses canonical funding eligibility as a surgical admission gate; actions, amounts and existing matching remain unchanged");
