# Funding Action Contract — Day 2 UI Wiring

Status: locked after inspecting the committed final governing pack.

This document resolves the gap between the UI Wiring Control Document and the final backend SQL for `/internal/funding`.

## Authority used

- `docs/governing-pack/ui/Multi_Tenant_UI_Wiring_Control_Document_v1.md`
- `docs/governing-pack/backend/closure_v2_functions_final_day6_8_clarified.sql`
- `docs/governing-pack/backend/day2_to_day9_final_regression_v5.sql`
- `docs/governing-pack/backend/goodcashback-complete.v4.sql`
- `docs/governing-pack/backend/closure_v2_migration_v2.sql`

## Plain-English conclusion

The business process is not missing.

Supervisor/admin must be able to:

1. review DVA/card funding lines;
2. reconcile funding to an order;
3. apply importer credit;
4. see immutable funding history.

But the final backend exposes these actions differently:

- **Importer credit application is RPC-based.**
- **DVA reconciliation is table/trigger-based in the final SQL, not exposed as the named RPCs listed in the UI control document.**

Therefore, do not wire DVA match/reconcile buttons directly from the UI control document names until a server-side contract is confirmed.

## Read-only funding page sources

The live `/internal/funding` page can read:

- `day2_dva_review_worklist_vw`
- `order_funding_position_vw`
- `importer_balance_vw`
- `dva_statement_lines`
- `order_funding_events`

Observed live column note:

- `order_funding_position_vw` uses `gap_remaining_gbp`, not `funding_gap_gbp`.
- The UI must use `gap_remaining_gbp` for the current funding gap.

## Confirmed RPC action

### Apply importer credit

Final SQL contains:

```sql
apply_importer_credit_to_order(
  p_importer_id uuid,
  p_order_id uuid,
  p_amount_gbp numeric,
  p_staff_id uuid
) RETURNS jsonb
```

This function:

- validates positive amount;
- validates the target order exists;
- blocks importer/order mismatch;
- blocks replacement child orders;
- blocks already-funded orders;
- checks available credit from `importer_balance_vw`;
- checks remaining gap using `order_funding_gap_gbp(p_order_id)`;
- inserts a debit row into `importer_credit_ledger`;
- writes an explicit `credit_applied` row into `order_funding_events`;
- recomputes platform-funded state;
- can surface admin review for high-value credit application.

UI implication:

- `Apply credit` is the first safe funding action to wire.
- It must be staff-only.
- It must call a server action/API route that invokes the RPC.
- It must be disabled for replacement child orders, already-funded orders, zero available credit, or zero gap.

## DVA reconciliation contract

The final SQL does **not** clearly expose these named RPCs:

```text
confirm_reconciliation_to_order(...)
accept_order_match_suggestion_and_reconcile(...)
```

The final SQL instead proves DVA reconciliation by inserting/updating `dva_reconciliation` rows.

The trigger:

```sql
trg_sync_order_funding_event_from_dva_reconciliation()
```

runs after insert/update/delete on:

```sql
dva_reconciliation
```

and does the important backend work:

- creates or updates `order_funding_events` with `event_type = 'funding_contribution'`;
- links the funding event to `source_entity_type = 'dva_reconciliation'`;
- recomputes `orders.funded_at` through `recompute_order_platform_funded(...)`;
- syncs overfunding credit through `sync_order_overfunding_credit(...)`.

The final regression proves this by directly inserting and updating `dva_reconciliation` and checking the resulting funding events and funded state.

UI implication:

- DVA match/reconcile is not yet a confirmed client-callable RPC.
- The UI must not invent calls to `confirm_reconciliation_to_order` or `accept_order_match_suggestion_and_reconcile` until such functions are either found or added.
- A staff server action may eventually write to `dva_reconciliation`, but only after RLS/server privilege and validation rules are confirmed.

## Minimum fields for DVA order-funding reconciliation

A DVA order-funding reconciliation row needs:

```sql
dva_statement_line_id
reconciliation_type = 'order_funding'
order_id
reconciled_gbp_amount
reconciled_by_staff_id
reconciled_at
notes
```

The baseline constraint requires:

- for `order_funding`, `order_id` must be present;
- `supplier_invoice_id` and `dispute_id` must be null.

## Important RLS / server-action warning

The smoke tests prove the database logic under SQL execution.

They do **not** prove that a browser/session user can insert into `dva_reconciliation` through Supabase Data API.

Before wiring DVA reconcile buttons, verify one of these:

1. staff RLS policy allows the intended insert/update path; or
2. a `SECURITY DEFINER` RPC exists/will be added; or
3. a server-side privileged route is deliberately used and audited.

Do not guess.

## Recommended wiring order

1. Keep `/internal/funding` read-only.
2. Wire `Apply importer credit` first using the confirmed RPC.
3. Add visible backend error handling.
4. Then decide DVA reconciliation route:
   - use existing direct table insert only if staff write/RLS is proven; or
   - add a small additive RPC wrapper and rerun the relevant Day 2 regression.
5. Only after that wire DVA match/reconcile buttons.

## Current UI decision

For now:

- show DVA worklist rows;
- show funding positions;
- show importer balances;
- show immutable funding events;
- show diagnostics;
- do not show DVA reconcile/match buttons yet;
- do not show importer-facing funding controls.
