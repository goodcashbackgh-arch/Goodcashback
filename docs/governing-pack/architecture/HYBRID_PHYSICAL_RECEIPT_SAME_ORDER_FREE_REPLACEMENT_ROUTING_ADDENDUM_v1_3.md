# Hybrid Physical Receipt Same-Order Free Replacement Routing Addendum v1.3

**Status:** governing corrective addendum

**Effective date:** 17 August 2026

**Baseline:** `main` at `b35c256653847369820276fb4656fd26b54087b9`

## Purpose

Correct only the broken application handoff after a supervisor accepts a same-order free replacement.

The accepted same-order replacement must continue into the already-built and already-tested importer replacement tracking handoff from PR #231. No replacement workflow is to be redesigned or recreated.

## Existing tested authority to preserve

The following existing implementation remains authoritative and must not be replaced:

- `app/importer/ReplacementOrdersPanel.tsx`
- `app/importer/replacement-orders-data/route.ts`
- `operator_allocate_same_order_replacement_tracking_v1`
- original-order tracking submission through the existing order operations page
- same-order route table `physical_replacement_same_order_routes`

The current `ReplacementOrdersPanel.tsx` and `app/importer/replacement-orders-data/route.ts` are the same tested implementation merged by PR #231. Their tracking-allocation behavior must remain unchanged.

## Defect

After `staff_accept_same_order_free_replacement_v1` succeeds, the importer exception detail page shows `Replacement accepted — awaiting successor tracking`, but the tested replacement tracking handoff is hidden because `ReplacementOrdersPanel` only renders on the exact `/importer` pathname.

That leaves the accepted exception detail page looking terminal even though the replacement route is waiting for successor tracking.

## Required correction

Reuse the existing tested `ReplacementOrdersPanel` on the importer exception detail page for the current dispute only.

Implementation rules:

1. Add only an optional dispute filter/presentation mode to `ReplacementOrdersPanel`.
2. When no dispute is supplied, preserve its existing `/importer` dashboard behavior exactly.
3. When a dispute is supplied, render the same tested handoff for routes belonging only to that dispute.
4. Do not show unrelated legacy child-order rows on the dispute-specific rendering.
5. The existing route GET/POST implementation and `operator_allocate_same_order_replacement_tracking_v1` call remain unchanged.
6. The existing original-order operations page remains the place where a new tracking submission is entered; the handoff continues to attach that existing tracking submission to the same-order route.
7. Render the dispute-specific handoff from `app/importer/exceptions/[dispute_id]/layout.tsx` only when a same-order replacement route exists and no replacement child order exists.

## Non-scope

Do not change:

- supervisor acceptance RPC or database authority;
- same-order route schema;
- tracking allocation RPC;
- replacement quantity/value rules;
- physical receipt logic;
- shipment logic;
- reconciliation;
- accounting/VAT/Sage;
- refund logic;
- legacy child records/functions;
- permissions/RLS;
- migrations.

## Required proof

Before merge prove:

- `ReplacementOrdersPanel.tsx` still calls only `/importer/replacement-orders-data` for the tested handoff;
- `app/importer/replacement-orders-data/route.ts` is unchanged from PR #231;
- dispute-specific rendering filters to the current dispute;
- dashboard rendering remains unchanged when no dispute is supplied;
- no database or migration files change;
- no child-order path is reintroduced;
- the accepted replacement exception page now exposes the tested successor-tracking handoff instead of ending at a terminal message.
