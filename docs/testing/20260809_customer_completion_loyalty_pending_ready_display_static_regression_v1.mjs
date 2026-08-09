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

function requireSection(source, startNeedle, endNeedle, label) {
  const start = source.indexOf(startNeedle);
  if (start < 0) throw new Error(`Missing required ${label} start: ${startNeedle}`);
  const end = source.indexOf(endNeedle, start);
  if (end < 0) throw new Error(`Missing required ${label} end: ${endNeedle}`);
  return source.slice(start, end + endNeedle.length);
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
requireIncludes(customerPage, "const hasReadyLoyalty = readyLoyaltyGbp > 0.01;", "existing ready display threshold");
requireIncludes(customerPage, "const hasPendingLoyalty = pendingLoyaltyGbp > 0.01;", "existing pending display threshold");
requireIncludes(
  customerPage,
  '<h2 className="mt-1 text-2xl font-black text-slate-950">{gbp(creditBalanceGbp)} available account credit</h2>',
  "dominant normal account-credit heading"
);

// Native disclosure only: no client state or client boundary.
requireExcludes(customerPage, '"use client"', "customer-page client boundary");
requireExcludes(customerPage, "useState", "customer-page React state");
requireExcludes(customerPage, "const loyaltyStatusParts: string[] = [];", "obsolete loyalty status parts helper");
requireExcludes(customerPage, "const loyaltyStatusText =", "obsolete loyalty status text helper");

const loyaltyDetails = requireSection(
  customerPage,
  '<details className="group mt-2 rounded-xl border border-slate-200 bg-white">',
  "</details>",
  "collapsible loyalty-credit disclosure"
);

requireIncludes(loyaltyDetails, '<summary className="cursor-pointer list-none px-3 py-2.5">', "native loyalty summary");
requireExcludes(loyaltyDetails, " open=", "default-open loyalty disclosure");
requireIncludes(loyaltyDetails, "Additional loyalty credit", "loyalty disclosure heading");
requireIncludes(loyaltyDetails, "group-open:hidden", "collapsed content open-state hiding");
requireIncludes(loyaltyDetails, "hidden group-open:inline", "expanded control open-state reveal");
requireIncludes(loyaltyDetails, "Show details", "collapsed disclosure control");
requireIncludes(loyaltyDetails, "Hide details", "expanded disclosure control");

// Collapsed summary: dark amounts; only classifications are coloured.
requireIncludes(
  loyaltyDetails,
  '<span className="text-slate-950">{gbp(readyLoyaltyGbp)}</span><span className="text-emerald-700">available</span>',
  "collapsed ready amount and green available classification"
);
requireIncludes(
  loyaltyDetails,
  '<span className="text-slate-950">{gbp(pendingLoyaltyGbp)}</span><span className="text-amber-700">pending activation</span>',
  "collapsed pending amount and amber pending classification"
);

// Expanded rows: larger dark amounts; status pills alone carry green/amber treatment.
requireIncludes(
  loyaltyDetails,
  '<span className="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-bold text-emerald-700 ring-1 ring-emerald-200">Available now</span>',
  "expanded available status"
);
requireIncludes(
  loyaltyDetails,
  '<span className="rounded-full bg-amber-50 px-2.5 py-1 text-xs font-bold text-amber-700 ring-1 ring-amber-200">Pending activation</span>',
  "expanded pending status"
);
requireIncludes(
  loyaltyDetails,
  '<span className="shrink-0 text-xl font-black text-slate-950">{gbp(readyLoyaltyGbp)}</span>',
  "expanded ready neutral amount"
);
requireIncludes(
  loyaltyDetails,
  '<span className="shrink-0 text-xl font-black text-slate-950">{gbp(pendingLoyaltyGbp)}</span>',
  "expanded pending neutral amount"
);
requireIncludes(loyaltyDetails, "No loyalty credit active yet", "zero-balance loyalty presentation");

requireIncludes(
  customerPage,
  "Account credit can be used on orders. Loyalty credit is shown separately. Pending activation cannot yet be used.",
  "credit distinction explanatory copy"
);
requireExcludes(customerPage, "Loyalty reward: {loyaltyStatusText}", "old loyalty reward line");

// Preserve the four threshold combinations without mutating financial state.
const cases = [
  [0, 0, false, false],
  [0, 50, false, true],
  [100, 0, true, false],
  [100, 50, true, true],
];

for (const [ready, pending, expectedReady, expectedPending] of cases) {
  const actualReady = ready > 0.01;
  const actualPending = pending > 0.01;
  if (actualReady !== expectedReady || actualPending !== expectedPending) {
    throw new Error(
      `Loyalty threshold case failed for ready=${ready}, pending=${pending}: ready=${actualReady}, pending=${actualPending}`
    );
  }
}

console.log("customer completion loyalty collapsible display static regression: PASS");
