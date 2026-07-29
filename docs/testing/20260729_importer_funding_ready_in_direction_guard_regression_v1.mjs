import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const pagePath = "app/internal/funding/page.tsx";
const page = readFileSync(pagePath, "utf8");

// Production-source guard: direction must be read once and included in the existing
// automatic ready-funding eligibility before any matched row can become actionable.
assert.match(
  page,
  /const direction = asString\(row\.direction\)\.toLowerCase\(\);/,
  "funding candidate must read the statement direction explicitly",
);

assert.match(
  page,
  /canReconcile: Boolean\(direction === "in" && dvaStatementLineId && inferred\.orderId && amountGbp > 0 && resolvedGap !== null && resolvedGap > 0 && !alreadyReconciled && inferred\.score >= 80\)/,
  "automatic ready funding must require direction=in while preserving the existing eligibility conditions",
);

// The existing unmatched-IN supervisor lane must remain independently IN-only.
assert.match(
  page,
  /const unmatchedInboundCandidates = fundingCandidates\.filter\(\(candidate\) =>\s*candidate\.direction === "in" &&/,
  "unmatched supervisor fallback must remain restricted to inbound lines",
);

// The ready queue must continue to derive solely from canReconcile; the direction
// control therefore lives at candidate eligibility rather than as a cosmetic hide.
assert.match(
  page,
  /const readyFundingCandidates = fundingCandidates\.filter\(\(candidate\) => candidate\.canReconcile\);/,
  "ready queue must continue to use the governed canReconcile eligibility",
);

// Behavioural proof of the exact defect: a supplier OUT whose auth text contains
// the order payment auth may score strongly, but direction alone must keep it out.
function canReconcile({ direction, lineId, orderId, amountGbp, gap, alreadyReconciled, score }) {
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

const sharedStrongMatch = {
  lineId: "statement-line",
  orderId: "order",
  amountGbp: 702.76,
  gap: 664.63,
  alreadyReconciled: false,
  score: 90,
};

assert.equal(
  canReconcile({ ...sharedStrongMatch, direction: "out" }),
  false,
  "OUT AUTH-1785274708774-NINJA style match must never become ready funding even with score 90",
);

assert.equal(
  canReconcile({ ...sharedStrongMatch, direction: "in" }),
  true,
  "equivalent valid IN strong match must remain eligible under the existing rules",
);

// No wording/workflow redesign is part of this fix.
assert.match(page, /Ready: customer\/importer IN → order funding/, "existing ready-funding wording must remain unchanged");
assert.match(page, /Supplier OUT/, "existing supplier OUT routing boundary must remain present");

console.log("PASS: importer funding ready queue requires IN direction; strong OUT matches remain non-actionable");
