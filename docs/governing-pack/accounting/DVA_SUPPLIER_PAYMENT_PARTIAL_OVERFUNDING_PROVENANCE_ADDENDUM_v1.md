# DVA Supplier Payment Partial Overfunding Provenance Addendum v1

## Status

LOCKED.

## Parent Contract

This addendum narrows and extends only the `Overfunding Proof` section of:

- `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_CASH_BACKED_CREDIT_PROVENANCE_ADDENDUM_v1.md`

All other clauses in that addendum remain unchanged.

## Defect Proven

A valid cash-backed `overfunding` credit can be created from a larger original pending receipt residual after downstream settlement evidence is complete.

In that lifecycle:

- `order_pending_funding_surplus.pending_surplus_gbp` remains the original receipt residual;
- `staff_confirm_surplus_from_evidence_min_v1(...)` creates only the final evidence-supported customer credit;
- the pending row becomes `credit_confirmed` and links to that exact credit;
- the canonical settlement position can be `fully_resolved` with `remaining_unresolved_gbp = 0.00` even when the confirmed credit is smaller than the original pending residual.

The existing supplier-payment resolver incorrectly rejects this valid case because its overfunding proof requires the original pending residual to equal the confirmed credit amount.

## Exact Fix Boundary

Replace only:

```text
public.internal_supplier_payment_bundle_source_v1(uuid, numeric)
```

No allocator RPC, table, column, trigger, UI, settlement function, settlement view, audience function, funding event, credit row, pending-surplus row, reconciliation row, Sage route, VAT route, posting route or historical business row may be changed.

The function name, arguments, return shape, volatility, security, search path, grants and all non-overfunding behaviour must remain unchanged.

## Existing Full-Overfunding Proof Must Remain

The existing proof remains valid and unchanged when:

```text
pending_surplus_gbp == confirmed overfunding credit amount
```

within the existing £0.01 tolerance and all existing provenance checks pass.

This path must continue to work without requiring canonical settlement state.

## New Partial-Overfunding Proof

A confirmed `overfunding` credit smaller than the original pending receipt residual may be treated as DVA cash-backed only when every existing overfunding provenance check still passes and all of the following additional conditions are true:

1. the source credit is the exact credit linked by `order_pending_funding_surplus.confirmed_credit_ledger_id`;
2. `pending_surplus_gbp` is greater than the source credit amount by more than the existing £0.01 tolerance;
3. the source order's existing `order_settlement_resolution_position_v1` row exists;
4. `resolution_status = 'fully_resolved'`;
5. `remaining_unresolved_gbp <= 0.01`;
6. `over_resolved_gbp <= 0.01`;
7. `pending_evidence_count = 0`;
8. `pending_credit_confirmed_count > 0`;
9. the canonical confirmed customer-credit total equals the exact linked source credit amount within £0.01; and
10. the original inbound receipt still passes the existing exact DVA-cash statement/reconciliation proof.

This is an additional proof route only. It does not redefine the original pending receipt residual and does not recalculate settlement.

## Fail-Closed Rules

The partial path must fail closed when any required canonical settlement fact is missing or inconsistent, including:

- settlement not fully resolved;
- positive remaining unresolved amount;
- over-resolved settlement;
- pending evidence still present;
- missing confirmed pending-surplus state;
- source credit not exactly linked to the pending-surplus row;
- confirmed customer-credit total not matching the linked source credit;
- reversed pending-surplus evidence;
- wrong importer or order;
- wrong statement direction;
- missing/ambiguous DVA cash mapping;
- unsupported applied credit type;
- duplicate, over-applied or conflicting credit provenance.

No generic rule such as `credit_amount <= pending_surplus_gbp` is permitted by itself.

## Explicitly Untouched

This fix must not change:

- the original pending receipt residual amount;
- the confirmed customer credit amount;
- `staff_confirm_surplus_from_evidence_min_v1(...)`;
- `order_settlement_resolution_position_v1` arithmetic;
- `staff_resolve_order_settlement_v1(...)`;
- the source order's `fully_resolved` / `nothing_remaining` result;
- customer/importer audience state;
- direct funding totals or threshold logic;
- completion-loyalty source resolution;
- ordinary full-overfunding source resolution;
- supplier invoice amounts or approval state;
- supplier allocation locking, atomicity or sequential inheritance;
- source mappings already stored on confirmed allocations;
- cash posting, Sage, VAT, shipment, holds, disputes or exception handling.

## Dependency Boundary Proven Before Build

The live dependency audit proved:

- `internal_supplier_payment_bundle_source_v1` is consumed directly only by the supplier allocation core/incremental routes;
- the public bundle route reaches it through the bundle core;
- no live routine or view consumes both the supplier-source resolver and the canonical settlement chain;
- the canonical settlement/audience/reversal consumers are separate.

This fix is therefore limited to supplier-payment source eligibility and source mapping. It must not modify settlement state.

## Regression Gate

Before merge, Supabase SQL regression must prove all of the following:

1. a valid partial confirmed overfunding credit with a larger original pending residual and canonical `fully_resolved` source order resolves as DVA cash;
2. the same case preserves the original pending residual and confirmed credit amounts unchanged;
3. the source order remains `fully_resolved` with `remaining_unresolved_gbp = 0.00` before and after resolver execution;
4. an ordinary full-overfunding case still passes through the original equality path;
5. a partial case with unresolved or over-resolved settlement fails closed;
6. existing direct-cash behaviour is unchanged;
7. existing completion-loyalty behaviour is unchanged;
8. unsupported or ambiguous provenance still fails closed;
9. repeated resolver execution creates no rows and mutates no business data; and
10. allocator RPC definitions, settlement RPC/view definitions and source-mapping storage contracts remain unchanged.

## Deliverables

This change is limited to exactly:

1. this addendum;
2. one additive Supabase migration replacing only `public.internal_supplier_payment_bundle_source_v1(uuid,numeric)` by guarded in-place definition patch; and
3. one rollback-only Supabase regression SQL file.

Any additional database object, UI change, allocator change or settlement calculation change is outside scope and must stop for review.