import fs from "node:fs";

const lifecyclePath = "supabase/migrations/20260801210000_hybrid_physical_receipt_build_4_lifecycle_reconciliation_v1.sql";
const atomicPath = "supabase/migrations/20260801213000_hybrid_physical_receipt_build_4_atomic_replacement_acceptance_fix_v1.sql";
const actionPath = "app/internal/exceptions/[dispute_id]/actions.ts";
const addendumPath = "docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md";

const lifecycle = fs.readFileSync(lifecyclePath, "utf8");
const atomic = fs.readFileSync(atomicPath, "utf8");
const action = fs.readFileSync(actionPath, "utf8");
const addendum = fs.readFileSync(addendumPath, "utf8");

const replacementActionMatch = action.match(
  /export async function acceptReplacementOutcomeAction[\s\S]*$/,
);
const replacementAction = replacementActionMatch?.[0] ?? "";

const noFunctionReplacement = !/create\s+or\s+replace\s+function/i.test(`${lifecycle}\n${atomic}`);

const checks = [
  [addendum.includes("Single supplier-invoice authority rule"), "addendum freezes one invoice-authority rule"],
  [addendum.includes("Build 4 must finish with exactly two migrations"), "addendum freezes two-migration structure"],
  [noFunctionReplacement, "Build 4 migrations never replace an existing function"],
  [lifecycle.includes("Build 4 drift stop: create_replacement_child_order changed"), "lifecycle migration verifies the existing replacement authority without changing it"],
  [lifecycle.includes("Build 4 drift stop: order_has_open_child_exceptions changed"), "lifecycle migration verifies the existing parent blocker without changing it"],
  [lifecycle.includes("create function public.create_replacement_child_order_v2"), "lifecycle migration adds a versioned replacement-child authority"],
  [lifecycle.includes("create function public.order_has_open_child_exceptions_v2"), "lifecycle migration adds a versioned parent blocker"],
  [lifecycle.includes("Build 4 drift stop: order_reconciliation_vw changed"), "lifecycle migration drift-stops reconciliation authority"],
  [lifecycle.includes("si.is_current_for_order = true"), "canonical reconciliation requires explicit current invoice identity"],
  [lifecycle.includes("si.is_current_for_order is distinct from true"), "anomaly classification uses the null-safe inverse of current identity"],
  [lifecycle.includes("si.blocked_from_sage_yn is distinct from false"), "anomaly classification is null-safe for Sage blocking"],
  [lifecycle.includes("NON_AUTHORITATIVE_INVOICEABLE_EVIDENCE"), "non-authoritative eligible evidence is exposed"],
  [lifecycle.includes("replacement_source_dispute_line_id"), "physical child retains exact source dispute line"],
  [lifecycle.includes("replacement_child_order_id = v_child_id"), "physical remedy links to the child"],
  [atomic.includes("create function public.staff_accept_replacement_outcome_v1"), "atomic acceptance is created only as a new authority"],
  [atomic.includes("already exists; migration will not replace it"), "atomic migration fails closed if the function already exists"],
  [atomic.includes("public.create_replacement_child_order_v2"), "atomic physical path uses the versioned child authority"],
  [atomic.includes("A physical replacement requires exactly one approved remedy-linked dispute line"), "physical replacement requires one exact source line"],
  [atomic.includes("Physical and legacy replacement lines cannot be mixed"), "physical and legacy lines cannot be mixed"],
  [atomic.includes("legacy_source_dispute_line_ids"), "legacy source-line set is retained"],
  [atomic.includes("replacement_source_dispute_line_id, funded_at") && atomic.includes("null,\n      null,\n      now(),"), "legacy child does not claim one arbitrary source line"],
  [replacementAction.includes('.rpc("staff_accept_replacement_outcome_v1"'), "replacement application path uses one atomic RPC"],
  [!replacementAction.includes('.rpc("create_replacement_child_order"'), "replacement application path does not call child creation separately"],
  [!replacementAction.includes("transitionDisputeStatus("), "replacement application path does not perform separate status mutations"],
  [!replacementAction.includes('.from("orders")'), "replacement application path does not write orders directly"],
  [!lifecycle.includes("update public.orders\n  set order_total_gbp_declared"), "lifecycle migration does not rewrite parent declared amount"],
  [!lifecycle.includes("update public.orders\n  set total_qty_declared"), "lifecycle migration does not rewrite parent declared quantity"],
];

const failed = checks.filter(([passed]) => !passed);
if (failed.length) {
  for (const [, label]) of failed) console.error(`FAIL: ${label}`);
  process.exit(1);
}

for (const [, label] of checks) console.log(`PASS: ${label}`);
console.log("PASS: Hybrid Physical Receipt Build 4 source regression");
