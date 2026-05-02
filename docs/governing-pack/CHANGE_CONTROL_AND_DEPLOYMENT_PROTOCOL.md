# Change Control and Deployment Protocol

Status: binding project protocol for all future Goodcashback build work.

This document supplements the governing pack, role matrices, action contracts, schema references, and backend SQL packs. If this protocol conflicts with a casual implementation shortcut, this protocol wins.

## Purpose

The platform now contains interdependent order, funding, invoice, OCR, exception, shipping, Sage, VAT, and credit flows. A small uncontrolled change can damage financial truth, deployment stability, or audit integrity.

The build pattern must therefore prioritise inspection, explicit approval, small reversible changes, and deployment verification.

## Mandatory workflow before changing code, SQL, or deployment state

For every non-trivial change, follow this sequence:

1. Inspect the relevant governing pack, role matrices, contracts, live DB/Supabase objects, and current repo file.
2. Propose the exact file changes before editing when the change affects an existing workflow, schema, action, RPC, or deployment-sensitive route.
3. Patch on a branch or as a tiny isolated commit only.
4. Show the diff or list exactly which files changed.
5. Ask for explicit approval before any rollback, force-reset, force-push, destructive file operation, schema mutation, function drop, constraint change, or production-risk action.
6. Deploy only after approval when risk is not trivial, and confirm Vercel READY before treating the change as live.

## Absolute no-go actions without explicit user approval

Do not perform any of the following without Ian's explicit approval in the current chat:

- force-resetting or force-pushing `main`;
- rewriting branch history used by production;
- rolling back production;
- deleting files or directories;
- dropping tables, columns, functions, views, policies, triggers, or constraints;
- widening or weakening constraints;
- replacing whole SQL packs or large files when a surgical patch would work;
- changing RLS behaviour;
- adding write buttons to financial, funding, exception, Sage, VAT, credit, or reconciliation pages;
- using service-role keys in browser/client code;
- merging a pull request or branch into `main` where the change is not trivial.

## Branching rule

Use a branch for changes that are governance, architecture, workflow, DB, financial-control, or production-risk related.

Main-branch direct commits are only acceptable for tiny, clearly isolated, low-risk changes after inspection. When in doubt, branch first.

## Diff discipline

After any patch, report:

- changed file paths;
- whether each file is new, modified, or deleted;
- whether the change affects runtime code, DB/SQL, contracts, or documentation only;
- whether it can trigger Vercel deployment;
- whether Vercel is READY if deployment was triggered.

## Existing flow protection

Never remove, trim, refactor, or simplify existing code that belongs to another working flow unless the user explicitly approves and the exact dependency impact has been inspected.

This protection applies especially to:

- order creation and operations;
- importer/operator invoice upload;
- Mindee/OCR routes and parser logic;
- invoice line reconciliation;
- refund/replacement exceptions;
- supplier invoice coding and approval;
- DVA/card statement reconciliation;
- importer credit ledger logic;
- shipping handoff and evidence;
- Sage queue/posting logic;
- VAT/export evidence logic.

## Deployment rule

A GitHub commit to `main` can trigger Vercel production deployment. Do not assume GitHub success means production success.

A change is live only when Vercel reports READY for the expected commit SHA.

If deployment fails, stop, inspect the exact build error, and patch only the failing point. Do not perform rollback, force-reset, or destructive history operations without explicit approval.

## DVA/card workbench note

The `/internal/funding` page remains the Day 2 order-funding workflow.

The `/internal/dva-reconciliation` page is a separate DVA/card statement-control workbench for statement-line visibility against supplier charges, refunds, invoice totals, progressed lines, exceptions, and credit context.

Do not mix order funding actions with supplier charge/refund/exception control actions unless a governing contract and dedicated SECURITY DEFINER RPCs have been approved and tested.

## Short operating checklist

Before acting, ask:

1. Am I changing an existing working flow?
2. Have I inspected the governing source and live/repo shape?
3. Can this be done as a tiny branch-only patch?
4. Have I shown the intended diff or change scope?
5. Would this trigger production deployment?
6. Is this destructive or hard to reverse?

If the answer to question 6 is yes, stop and ask Ian first.
