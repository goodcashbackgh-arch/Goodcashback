# Hybrid Physical Receipt Build 4 Authority Versioning Correction Addendum v1

## Status and authority

This correction addendum governs only the authority-versioning repair required after the Build 2 physical remedy guard and the Build 4 reconciliation authority were changed in place.

The original Build 4 addendum remains historical evidence. This correction supersedes only clauses that permitted an existing authority to be replaced in place. It does not reopen or expand any other Build 4 scope.

## Problem being corrected

An in-place replacement changes the behaviour seen by every existing dependency of that database object. Preserving a signature or public column list does not isolate changed semantics. The repair must therefore restore the original authorities and preserve the hybrid-specific behaviour under explicitly versioned objects.

## Final target architecture

| Object | Final purpose | Existing callers affected |
|---|---|---|
| `public.physical_remedy_allocation_guard_v1()` | Exact original foundation guard | None |
| `public.physical_remedy_allocation_guard_v2()` | Exact Build 2 outcome-specific multi-dispute compatibility guard | Existing hybrid remedy trigger only |
| `public.order_reconciliation_vw` | Exact pre-Build-4 reconciliation authority | Existing platform continues unchanged |
| `public.order_reconciliation_v2_vw` | Exact Build 4 authoritative-supplier reconciliation | Build 4 anomaly and acceptance checks only |
| `public.order_reconciliation_anomalies_v1` | Build 4 anomaly reporting | Must explicitly depend on `order_reconciliation_v2_vw` |

No old application page, RPC, accounting authority, VAT authority, status authority or unrelated database object may be redirected.

## Migration authority

The corrective migration is:

`20260802110000_hybrid_physical_receipt_restore_legacy_authorities_v1.sql`

It is a corrective migration, not feature scope. It must execute in one transaction and leave no partial state.

## Guard versioning build

1. Preflight must prove the currently installed `physical_remedy_allocation_guard_v1()` is the reviewed Build 2 body with `pg_get_functiondef` fingerprint `32e1d3eb9161cdc3e09114edb8c0d3c0`.
2. Preflight must prove `physical_remedy_allocation_guard_v2()` does not exist.
3. Before renaming, the migration must capture the installed function OID, owner and a name-independent canonical body/metadata hash covering `prosrc`, language, volatility, security-definer state, strictness, parallel safety, leakproof state, return type, argument types and `proconfig`.
4. The installed function object must be renamed with:

   `ALTER FUNCTION public.physical_remedy_allocation_guard_v1() RENAME TO physical_remedy_allocation_guard_v2;`

5. The trigger must not be dropped or recreated. PostgreSQL object identity must preserve its binding to the renamed v2 function.
6. After renaming, the v2 function must retain the captured OID, owner and name-independent canonical hash. A post-rename `pg_get_functiondef` hash is not authoritative because the function name itself has changed.
7. `physical_remedy_allocation_guard_v1()` must then be recreated literally from the complete original body in `20260801131000_hybrid_physical_receipt_integrity_v1.sql`.
8. The migration must contain no `CREATE OR REPLACE FUNCTION`, dynamic `EXECUTE`, function-definition extraction for reconstruction, or text replacement.
9. The exact foundation body and metadata must be verified against an in-transaction clean-replay reference function created from the same frozen foundation source. The comparison must use the same name-independent canonical hash.
10. Neither guard may be executable by `PUBLIC`, `anon` or `authenticated`.
11. The expected privileged owner must be preserved for both functions.

## Reconciliation versioning build

1. Preflight must prove `order_reconciliation_vw` is the reviewed Build 4 definition and has the exact expected public column sequence. This proof may use an in-transaction reference view created from the frozen Build 4 SQL rather than a guessed fingerprint.
2. Preflight must prove `order_reconciliation_v2_vw` does not exist.
3. The complete Build 4 reconciliation body must be copied unchanged into a new `CREATE VIEW public.order_reconciliation_v2_vw` statement.
4. The Build 4 v2 calculation must retain:
   - explicit current supplier-invoice identity;
   - approved-current or ref-corrected approval;
   - `blocked_from_sage_yn = false`;
   - non-superseded invoice identity;
   - exclusion of resolved dispute quantity and value already represented by authoritative invoice lines;
   - signed non-physical delivery, fee and discount treatment;
   - over-progress prevention in `whole_order_cleared_yn`.
5. `order_reconciliation_vw` must be restored with the complete definition from `20260724_order_reconciliation_signed_nonphysical_v1.sql`.
6. `CREATE OR REPLACE VIEW` is authorised only for that restoration because dropping the existing view could break dependent objects and grants.
7. The restored legacy view must retain fingerprint `89cc95922a2b8ec1fa040ba79f12907a`, its exact column order and data types, owner and grants.

## Exact dependency control

Before restoration, the migration must capture the exact dependent object identities of `order_reconciliation_vw`, not only a count. Identity must include dependent class, schema, object name, object identity and dependency type.

After restoration and anomaly rewiring:

- every prior dependency must remain attached to `order_reconciliation_vw`, except the intentional dependency from `order_reconciliation_anomalies_v1`;
- `order_reconciliation_anomalies_v1` must instead have an explicit dependency on `order_reconciliation_v2_vw`;
- no other dependency may be added, removed or redirected.

Any unexpected dependency difference must abort the transaction.

## Anomaly authority repair

`order_reconciliation_anomalies_v1` must be recreated with its existing body unchanged except for:

```sql
canonical AS (
  SELECT *
  FROM public.order_reconciliation_v2_vw
)
```

Preflight must verify the reviewed current anomaly definition before changing it. No anomaly code, evidence JSON, threshold or classification may otherwise change.

## Required regressions

### Structural regression

Must prove:

- v1 and v2 guard existence;
- exact independent guard canonical hashes;
- trigger object identity remains bound to v2;
- no trigger is attached to restored v1;
- exact owners and privileges;
- legacy and v2 reconciliation definitions, columns and grants;
- exact dependency preservation with only the authorised anomaly redirection;
- anomaly view dependency on v2.

### Behaviour regression

All test writes must roll back. It must prove:

- a foundation-style single compatibility-link case is accepted by v1;
- the controlled Build 2 outcome-specific multi-dispute case is accepted through the trigger-bound v2;
- the equivalent multi-dispute row is rejected by v1;
- legacy reconciliation known-order results remain unchanged;
- v2 excludes non-current, blocked, superseded and pending-review invoice evidence;
- v2 includes current approved unblocked evidence exactly once;
- resolved dispute evidence represented by an authoritative invoice is not double-counted;
- signed delivery, fee and discount treatment remains correct;
- over-progress cannot clear an order;
- anomaly output remains based on v2 and is unaffected by restoration of the legacy view.

### Source regression

Must forbid:

- `CREATE OR REPLACE FUNCTION public.physical_remedy_allocation_guard...`;
- dropping either guard;
- dynamic SQL reconstruction;
- `pg_get_functiondef` combined with text replacement;
- unrelated writes or replacements affecting orders, disputes, dispute lines, supplier invoices or lines, VAT, accounting release, Sage, status recomputation, funding, shipment, customer release, payout or AP authorities.

It must require the literal rename, literal v1 creation, both guard canonical-hash checks, trigger OID binding proof, v2 view creation, legacy view restoration and anomaly dependency on v2.

## Acceptance sequence

1. Run the read-only preflight report for the current guard fingerprint, canonical hash, reconciliation definition, trigger OID binding, anomaly dependency, owners, grants and exact dependents.
2. Apply migration 6.
3. Run the structural regression.
4. Run the rollback-only behavioural regression.
5. Run the corrected Build 2 and Build 4 regressions.
6. Run application source checks proving no existing page or RPC was redirected from `order_reconciliation_vw`.

## Scope boundary

The correction changes only:

- one function rename;
- one literal restoration function;
- one new versioned reconciliation view;
- one legacy reconciliation view restoration;
- one anomaly-view dependency;
- correction documentation and tests.

It must not change order status logic, replacement acceptance, dispute transitions, refunds, customer balances, supplier-invoice approval, VAT, Sage, AP, payout, funding, shipment, unrelated permissions or any UI.
