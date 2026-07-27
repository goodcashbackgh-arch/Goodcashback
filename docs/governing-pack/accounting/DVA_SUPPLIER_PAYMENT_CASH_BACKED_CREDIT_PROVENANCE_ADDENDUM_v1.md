# DVA Supplier Payment Cash-Backed Credit Provenance Addendum v1

## Parent Contract

This addendum extends:

- `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_AUTO_RESOLUTION_ADDENDUM_v1.md`
- `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_SPLIT_CONTRACT_v1.md`

It governs one defect only: valid applied `settlement_credit` and `overfunding` amounts are omitted from the canonical supplier-payment DVA cash calculation even when their exact source is proven to be importer DVA cash.

## Verified Defect

The shared resolver currently recognises:

- direct `funding_contribution` events as DVA cash; and
- released completion-loyalty credit applications through the existing loyalty route.

It does not recognise qualifying applied credits with `source_type`:

- `settlement_credit`; or
- `overfunding`.

This omission understates remaining DVA cash funding and can incorrectly block supplier-payment allocation.

The current single, incremental, sequential and bundle supplier-allocation routes already call the shared resolver. They are the working execution routes and must not be rewritten.

## Permanent Fix Boundary

Replace only:

```text
public.internal_supplier_payment_bundle_source_v1(uuid, numeric)
```

The permanent migration must preserve:

- function name and signature;
- return columns and meanings;
- `STABLE` volatility;
- `SECURITY DEFINER`;
- search path;
- grants;
- existing direct-cash behaviour;
- existing completion-loyalty behaviour;
- existing exact-loyalty versus sufficient-cash ambiguity blocking;
- confirmed-allocation deduction;
- allocation locking, atomicity and sequential inheritance.

No allocator RPC, application file, table, column, trigger, status, approval rule, UI, statement interpretation, accounting snapshot, cash-posting route, Sage route or downstream consumer may change for this fix.

## Canonical Calculation

For supplier-payment source resolution:

```text
remaining proven DVA cash funding
=
  direct order funding_contribution amount
+ proven applied settlement_credit amount
+ proven applied overfunding amount
- confirmed supplier_invoice allocations already mapped to DVA_CASH_BANK_ACCOUNT
```

The originating receipt is provenance evidence only. It must not be added again to the target order funding total.

Amounts must be aggregated by proven event or source-lot identity. `SUM(DISTINCT amount)` and record-specific exceptions are prohibited.

## Exact Applied-Credit Chain

Every positive applied credit considered by this extension must prove:

```text
credit_applied order_funding_event
-> exact importer_credit_ledger application debit
-> exact originating importer_credit_ledger credit lot
```

The resolver must require:

1. the funding event identifies the application debit through `source_entity_type = 'importer_credit_ledger'` and `source_entity_id`;
2. exactly one qualifying funding event exists for that application debit;
3. the application debit belongs to the target importer and target order;
4. the application debit has `direction = 'debit'` and `source_type = 'credit_application'`;
5. the debit's source links identify the same originating credit lot;
6. the source credit belongs to the same importer, has `direction = 'credit'`, and is not locked;
7. the funding-event amount equals the application-debit amount within £0.01;
8. the application debit does not exceed the source lot; and
9. total explicitly linked debits do not exceed the source lot.

Missing, conflicting, duplicated or over-applied evidence must fail closed through the existing supplier-payment source-resolution blocker family.

## Settlement Credit Proof

An applied `settlement_credit` is DVA cash-backed only when:

1. the source credit identifies the exact `order_settlement_resolution_actions` row;
2. the action's `credit_ledger_id` identifies the same source credit;
3. action order and importer match the source credit;
4. `status = 'active'`;
5. `reversed_at IS NULL`;
6. `customer_credit_gbp` equals the source credit amount within £0.01; and
7. the source order has valid inbound `order_funding` receipt evidence that resolves through `internal_dva_statement_source_mapping_v1(...)` to:

```text
source_wallet_code = dva_cash
source_bank_account_mapping_code = DVA_CASH_BANK_ACCOUNT
```

Multiple source receipts are permitted only when every receipt used in the proof resolves to that same economic source. Duplicate evidence must not increase proven receipt capacity.

## Overfunding Proof

An applied `overfunding` credit is DVA cash-backed only when:

1. `order_pending_funding_surplus.confirmed_credit_ledger_id` identifies the exact source credit;
2. pending-surplus order and importer match the source credit;
3. `status = 'credit_confirmed'`;
4. `reversed_at IS NULL`;
5. `pending_surplus_gbp` equals the source credit amount within £0.01;
6. `dva_reconciliation_id` and `dva_statement_line_id` identify the same exact `order_funding` reconciliation and inbound statement line;
7. the statement belongs to the same importer; and
8. `internal_dva_statement_source_mapping_v1(...)` resolves the exact statement line to `dva_cash` and `DVA_CASH_BANK_ACCOUNT` without ambiguity.

A generic order link without the exact confirmed pending-surplus and statement-line chain is insufficient.

## Supported Types

This change supports only:

- existing `completion_loyalty_reward` handling through the unchanged loyalty route;
- `settlement_credit` through the proof above; and
- `overfunding` through the proof above.

Other positive applied credit types retain the existing fail-closed behaviour.

## Behaviour That Must Remain Untouched

The patch must not alter:

- direct DVA cash results;
- released virtual-GBP or DVA-GHS loyalty results;
- source ambiguity rules;
- supplier invoice approval rules;
- statement importer and direction checks;
- selection behaviour;
- permissions or roles;
- allocation atomicity or sequential controls;
- source mapping stored on confirmed allocations;
- totals, rounding or signed-amount conventions;
- banking, treasury, posting, Sage, VAT, shipment, hold or exception behaviour;
- existing allocations, ledger rows, reconciliations, snapshots, batches or posted records.

## Historical Rows

The permanent fix is a resolver correction. It must not rewrite historical business rows.

Any repair to an already confirmed, frozen or posted row is a separate bounded change and is outside this addendum.

## Regression Execution Contract

The regression file must run directly in Supabase SQL Editor inside one explicit transaction and finish with `ROLLBACK`.

It may use narrowly bounded test mutations or copied fixture rows only when required to prove a negative condition that is not present in live data. Every such fixture must be contained in a PL/pgSQL exception subtransaction or the outer transaction so it is automatically rolled back. The regression must never commit, post, freeze, allocate through an authenticated RPC, or leave persistent business rows.

Where a safe behavioural fixture cannot be created without invoking unrelated triggers or workflows, the regression may use an exact deployed-definition assertion for that control, but it must state that limitation in the SQL notice.

## Regression Gate

Before merge, regression SQL must prove:

1. the defective cash-backed combination resolves correctly;
2. a direct-cash-only working flow is unchanged;
3. completion-loyalty behaviour is unchanged;
4. reversed settlement evidence blocks;
5. reversed or unconfirmed overfunding evidence blocks;
6. event/debit amount mismatch blocks;
7. source-lot disagreement blocks;
8. importer mismatch blocks;
9. unsupported applied credit blocks;
10. conflicting source mapping blocks;
11. duplicate evidence does not increase funding;
12. confirmed prior DVA-cash allocations are deducted once;
13. reversed allocations are excluded;
14. exact loyalty plus sufficient cash remains ambiguous;
15. sequential allocation retains the first confirmed source mapping; and
16. repeated resolver execution creates no rows or mutations.

A real order may be used as proof, but no real identifier may appear in the permanent function or migration.

## Required Deliverables

The implementation is limited to:

1. this addendum;
2. one deterministic Supabase migration replacing only `public.internal_supplier_payment_bundle_source_v1(uuid, numeric)`; and
3. one Supabase-runnable regression SQL file that follows the rollback-only execution contract above.

No additional file or database-object change is permitted unless new evidence proves the shared resolver is not the active execution layer. If that occurs, implementation must stop and this addendum must be revised before further work.
