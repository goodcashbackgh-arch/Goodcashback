import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const file = readFileSync(
  "app/internal/dva-reconciliation/workspace/RefundSettlementTargetSynchronizer.tsx",
  "utf8",
);

assert.match(file, /function score\(statementAmount: number, targetAmount: number\)/);
assert.match(file, /if \(difference < 0\.01\) return 100;/);
assert.match(file, /if \(difference <= 2\) return 75;/);
assert.match(file, /if \(difference <= 5\) return 50;/);
assert.match(file, /if \(difference <= 15\) return 25;/);
assert.match(file, /score\(statementAmount, acceptedSupplierCredit\)/);
assert.match(file, /startsWith\("Amount closeness score:"\)/);
assert.match(file, /Amount closeness score: \$\{score\(statementAmount, acceptedSupplierCredit\)\}/);
assert.doesNotMatch(file, /allocateStatementLineToSupplierInvoiceAction/);
assert.doesNotMatch(file, /allocateStatementLineToOperationalTargetAction/);
assert.doesNotMatch(file, /staff_allocate_statement_line/);

const score = (statementAmount, targetAmount) => {
  const difference = Math.abs(statementAmount - targetAmount);
  if (difference < 0.01) return 100;
  if (difference <= 2) return 75;
  if (difference <= 5) return 50;
  if (difference <= 15) return 25;
  return 0;
};

assert.equal(score(185.23, 184.99), 75);
assert.equal(score(185.23, 179.99), 25);

console.log("PASS: refund amount score uses authoritative settlement target only");
