import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const customerPage = fs.readFileSync(path.join(root, "app/customer/page.tsx"), "utf8");

function requireIncludes(source, needle, label) {
  if (!source.includes(needle)) {
    throw new Error(`Missing required ${label}: ${needle}`);
  }
}

function requireExcludes(source, needle, label) {
  if (source.includes(needle)) {
    throw new Error(`Forbidden ${label} remains: ${needle}`);
  }
}

function gbp(value) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function expectedLoyaltyStatus(readyLoyaltyGbp, pendingLoyaltyGbp) {
  const loyaltyStatusParts = [];

  if (readyLoyaltyGbp > 0.01) {
    loyaltyStatusParts.push(`${gbp(readyLoyaltyGbp)} ready to use`);
  }

  if (pendingLoyaltyGbp > 0.01) {
    loyaltyStatusParts.push(`${gbp(pendingLoyaltyGbp)} pending activation`);
  }

  return loyaltyStatusParts.length > 0
    ? loyaltyStatusParts.join(" · ")
    : "No loyalty reward active yet";
}

// Existing backend/read-model contract remains untouched.
requireIncludes(
  customerPage,
  'supabase.rpc("customer_completion_loyalty_reward_balance_v1")',
  "customer completion-loyalty balance RPC"
);
requireIncludes(
  customerPage,
  "const pendingLoyaltyGbp = loyaltyRows.reduce((sum, row) => sum + Number(row.pending_activation_gbp ?? 0), 0);",
  "existing pending balance reduction"
);
requireIncludes(
  customerPage,
  "const readyLoyaltyGbp = loyaltyRows.reduce((sum, row) => sum + Number(row.ready_to_use_gbp ?? 0), 0);",
  "existing ready balance reduction"
);

// Authorized presentation-only correction.
requireIncludes(customerPage, "const loyaltyStatusParts: string[] = [];", "independent loyalty status parts");
requireIncludes(
  customerPage,
  'loyaltyStatusParts.push(`${gbp(readyLoyaltyGbp)} ready to use`);',
  "ready-to-use status append"
);
requireIncludes(
  customerPage,
  'loyaltyStatusParts.push(`${gbp(pendingLoyaltyGbp)} pending activation`);',
  "pending-activation status append"
);
requireIncludes(customerPage, 'loyaltyStatusParts.join(" · ")', "combined ready/pending presentation");
requireExcludes(
  customerPage,
  "const loyaltyStatusText = readyLoyaltyGbp > 0.01",
  "mutually exclusive ready-over-pending rendering"
);

const cases = [
  [0, 0, "No loyalty reward active yet"],
  [0, 50, "£50.00 pending activation"],
  [100, 0, "£100.00 ready to use"],
  [100, 50, "£100.00 ready to use · £50.00 pending activation"],
];

for (const [ready, pending, expected] of cases) {
  const actual = expectedLoyaltyStatus(ready, pending);
  if (actual !== expected) {
    throw new Error(`Loyalty status case failed for ready=${ready}, pending=${pending}: ${actual}`);
  }
}

console.log("customer completion loyalty pending/ready display static regression: PASS");
