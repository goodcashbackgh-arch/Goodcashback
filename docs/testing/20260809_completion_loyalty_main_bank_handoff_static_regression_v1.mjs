import fs from "node:fs";
import path from "node:path";

const root = process.cwd();

function read(relativePath) {
  return fs.readFileSync(path.join(root, relativePath), "utf8");
}

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

const loyaltyPage = read("app/internal/completion-loyalty-rewards/page.tsx");
const loyaltyActions = read("app/internal/completion-loyalty-rewards/actions.ts");
const loyaltyClient = read("app/internal/completion-loyalty-rewards/WorkbenchClientEnhancements.tsx");
const mainBankActions = read("app/internal/dva-reconciliation/main-bank/actions.ts");
const mainBankPage = read("app/internal/dva-reconciliation/main-bank/page.tsx");
const customerPage = read("app/customer/page.tsx");
const lockdownMigration = read("supabase/migrations/20260722a_completion_loyalty_manual_release_lockdown_v1.sql");

// Completion-loyalty workbench must hand into the already-built main-bank route.
requireIncludes(
  loyaltyPage,
  "/internal/dva-reconciliation/main-bank?target=completion_loyalty",
  "Main Bank completion-loyalty handoff"
);
requireExcludes(
  loyaltyPage,
  "target=completion_loyalty&q=",
  "unsupported Main Bank loyalty order-ref search handoff"
);
requireIncludes(loyaltyPage, "Open Main Bank loyalty funding", "existing-route navigation label");
requireIncludes(loyaltyPage, 'row.workbench_status === "approved_pending_funding"', "existing pending-funding state");

// The stale direct/manual application path must be absent from active app code.
for (const [label, source] of [
  ["completion-loyalty page", loyaltyPage],
  ["completion-loyalty actions", loyaltyActions],
  ["completion-loyalty client enhancements", loyaltyClient],
]) {
  requireExcludes(source, "confirmCompletionLoyaltyRewardFundingAction", `${label} manual funding action`);
  requireExcludes(source, "data-funding-proof-form", `${label} manual funding form hook`);
  requireExcludes(source, "staff_confirm_completion_loyalty_reward_funding_v1", `${label} direct legacy funding RPC`);
}
requireExcludes(loyaltyPage, "function FundingForm", "legacy manual funding form");
requireExcludes(loyaltyPage, "Confirm funding proof and release dashboard credit", "legacy release button");
requireExcludes(loyaltyClient, "validateFundingProof", "legacy funding-proof validation");
requireExcludes(loyaltyClient, "clearFundingProofValidity", "legacy funding-proof validity handler");

// Existing approval and released-credit usage actions stay in place.
requireIncludes(loyaltyActions, "approveCompletionLoyaltyRewardAction", "existing approval action");
requireIncludes(loyaltyActions, "staff_approve_completion_loyalty_reward_v1", "existing approval RPC");
requireIncludes(loyaltyActions, "applyCompletionLoyaltyToOrderAction", "existing loyalty application action");
requireIncludes(loyaltyActions, "staff_apply_completion_loyalty_to_order_v1", "existing loyalty application RPC");

// Existing Main Bank implementation remains the authoritative funding route.
requireIncludes(mainBankActions, "internal_main_bank_completion_loyalty_targets_v1", "existing Main Bank loyalty target read model");
requireIncludes(mainBankActions, "staff_stage_main_bank_line_to_completion_loyalty_v2", "existing Main Bank OUT staging RPC");
requireIncludes(mainBankPage, "staff_pair_loyalty_destination_in_and_release_v1", "existing destination-IN paired release RPC");

// Existing customer pending/ready presentation remains available.
requireIncludes(customerPage, "pending activation", "customer pending-loyalty presentation");
requireIncludes(customerPage, "ready to use", "customer released-loyalty presentation");

// The July 22 database barrier remains fail-closed and points callers to paired release.
requireIncludes(
  lockdownMigration,
  "Direct completion-loyalty funding confirmation is disabled. Use the paired main-bank OUT and same-importer destination-IN release workflow.",
  "legacy direct funding fail-closed guard"
);
requireIncludes(lockdownMigration, "staff_pair_loyalty_destination_in_and_release_v1", "paired release wrapper");

console.log("completion loyalty main-bank handoff static regression: PASS");
