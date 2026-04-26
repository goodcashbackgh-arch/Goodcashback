# DVA Reconciliation Action Contract — Staff-safe UI Wiring

Status: draft contract only. Do not wire UI buttons from this document until the wrapper is installed and tested.

## Authority used

- `docs/governing-pack/backend/goodcashback-complete.v4.sql`
- `docs/governing-pack/backend/closure_v2_migration_v2.sql`
- `docs/governing-pack/backend/closure_v2_functions_final_day6_8_clarified.sql`
- `docs/governing-pack/backend/day2_to_day9_final_regression_v5.sql`
- `docs/governing-pack/ui/FUNDING_ACTION_CONTRACT.md`
- `docs/governing-pack/ui/Multi_Tenant_UI_Wiring_Control_Document_v1.md`

## Plain-English conclusion

A wrapper is needed before DVA reconcile/match buttons are wired.

The final backend proves DVA order-funding reconciliation through `dva_reconciliation` rows and the existing trigger path. It does not currently prove a browser/session-safe RPC for staff UI writes.

Therefore the UI must not insert directly into `dva_reconciliation`, and must not invent calls to older/unconfirmed names such as:

```text
confirm_reconciliation_to_order(...)
accept_order_match_suggestion_and_reconcile(...)
```

The safe pattern must follow the Apply Credit production proof:

```text
Browser form
→ Next server action
→ staff-only SECURITY DEFINER wrapper validating auth.uid()
→ proven backend table/trigger path
```

## Proven backend behaviour to preserve

The final regression proves these DVA funding behaviours:

1. A partial DVA reconciliation inserted into `dva_reconciliation` creates one `order_funding_events` row with `event_type = 'funding_contribution'`.
2. Updating the `dva_reconciliation.reconciled_gbp_amount` updates the funding position.
3. `orders.funded_at` is stamped only when cumulative funding reaches the order total.
4. DVA overfunding is valid Day 2 behaviour.
5. When DVA funding exceeds the order total, the excess is mirrored into `importer_credit_ledger` as available overfunding credit.

Important: the wrapper must not blindly reject fully funded orders. It must either allow overfunding through the existing trigger/credit path, or require an explicit overfunding flag. This contract uses an explicit flag.

## Required staff-safe RPC

### Name

```sql
staff_reconcile_dva_line_to_order
```

### Proposed signature

```sql
staff_reconcile_dva_line_to_order(
  p_dva_statement_line_id uuid,
  p_order_id uuid,
  p_reconciled_gbp_amount numeric DEFAULT NULL,
  p_allow_overfunding boolean DEFAULT false,
  p_match_suggestion_id uuid DEFAULT NULL,
  p_notes text DEFAULT NULL
) RETURNS jsonb
```

### Security model

The function must be:

```sql
SECURITY DEFINER
SET search_path = public, pg_temp
```

The wrapper must derive the acting staff user from `auth.uid()`. The browser/server action must not provide `p_staff_id`.

## Required validations

The wrapper must validate all of the following before inserting into `dva_reconciliation`.

### Staff validation

1. Resolve `auth.uid()` to an active row in `staff`.
2. Require `staff.role_type IN ('admin', 'supervisor')`.
3. Reject if no active staff row exists.

### DVA statement line validation

1. Lock the target `dva_statement_lines` row with `FOR UPDATE`.
2. Join through `dva_statements` to identify the owning importer.
3. Require `dva_statement_lines.direction = 'in'` for order funding.
4. Reject if a `dva_reconciliation` row already exists for the same `dva_statement_line_id`, because the baseline table has a unique one-line-to-one-reconciliation model.
5. Default the reconciled amount to `dva_statement_lines.amount_gbp_equivalent` when `p_reconciled_gbp_amount IS NULL`.
6. Require the final reconciled amount to be greater than zero.

### Order validation

1. Lock the target `orders` row with `FOR UPDATE`.
2. Require `orders.importer_id = dva_statements.importer_id`.
3. Require `orders.order_type = 'original'`.
4. Reject `replacement_child` targets, because replacement child orders are operational tracking paths and not fresh customer-funded orders.
5. Reject archived/cancelled orders unless a later admin-only exception path is deliberately designed.

### Optional match suggestion validation

If `p_match_suggestion_id` is provided:

1. Confirm the match suggestion exists.
2. Confirm it belongs to `p_dva_statement_line_id`.
3. Confirm `suggested_match_type = 'order'`.
4. Confirm `suggested_match_id = p_order_id`.
5. On successful reconciliation, stamp the suggestion as accepted if the existing schema/path supports it without breaking regression behaviour.

## Overfunding handling

DVA overfunding is proven and must remain supported.

The wrapper must calculate the current order gap before insert using the existing funding model. Conceptually:

```sql
v_gap_before := order_funding_gap_gbp(p_order_id);
v_effective_amount := COALESCE(p_reconciled_gbp_amount, dva_statement_lines.amount_gbp_equivalent);
v_overfunding_amount := GREATEST(v_effective_amount - v_gap_before, 0);
```

Rules:

1. If `v_gap_before = 0` and `p_allow_overfunding = false`, reject with a clear error: order is already funded; overfunding requires explicit confirmation.
2. If `v_effective_amount > v_gap_before` and `p_allow_overfunding = false`, reject with a clear error showing the current gap and proposed amount.
3. If `p_allow_overfunding = true`, allow the insert for an original order and rely on the existing trigger/helper path to:
   - create/update `order_funding_events`;
   - recompute `orders.funded_at`;
   - mirror excess funding into `importer_credit_ledger` as overfunding credit.
4. The wrapper must not manually create duplicate overfunding credit. The existing trigger/helper path owns that behaviour.
5. The return payload must surface overfunding clearly so the UI can show what happened.

## Insert contract

When all validations pass, insert exactly one row into `dva_reconciliation`:

```sql
INSERT INTO dva_reconciliation (
  dva_statement_line_id,
  reconciliation_type,
  order_id,
  supplier_invoice_id,
  dispute_id,
  reconciled_gbp_amount,
  reconciled_by_staff_id,
  reconciled_at,
  notes
)
VALUES (
  p_dva_statement_line_id,
  'order_funding',
  p_order_id,
  NULL,
  NULL,
  v_effective_amount,
  v_staff_id,
  now(),
  p_notes
);
```

The trigger path must remain responsible for funding-event sync and credit mirroring.

## Return shape

The RPC should return `jsonb` with at least:

```json
{
  "ok": true,
  "dva_reconciliation_id": "uuid",
  "dva_statement_line_id": "uuid",
  "order_id": "uuid",
  "order_ref": "text",
  "importer_id": "uuid",
  "reconciled_gbp_amount": 1200.00,
  "gap_before_gbp": 1000.00,
  "funding_total_after_gbp": 1200.00,
  "gap_after_gbp": 0.00,
  "overfunding_gbp": 200.00,
  "overfunding_credit_expected_yn": true,
  "funded_at": "timestamptz-or-null"
}
```

For normal non-overfunding reconciliation, `overfunding_gbp` should be `0.00` and `overfunding_credit_expected_yn` should be `false`.

## Error behaviour

The wrapper should raise clear exceptions for:

- unauthenticated user;
- active staff row not found;
- staff role not admin/supervisor;
- DVA line not found;
- DVA line already reconciled;
- DVA line is not an inbound funding line;
- order not found;
- importer mismatch between DVA statement and order;
- replacement child order target;
- amount less than or equal to zero;
- order already funded and `p_allow_overfunding = false`;
- proposed amount exceeds remaining gap and `p_allow_overfunding = false`;
- invalid match suggestion.

## Required test scenarios before UI buttons

Do not wire UI buttons until these scenarios pass in Supabase SQL Editor or an equivalent regression harness.

### Scenario 1 — Partial funding

- Order total: £1,000.
- DVA inbound line: £600.
- Call wrapper with `p_allow_overfunding = false`.

Expected:

- `dva_reconciliation` row inserted.
- `order_funding_events` has one `funding_contribution` row linked to the reconciliation.
- funding total becomes £600.
- gap becomes £400.
- `funded_at` remains null.
- no importer overfunding credit is created.

### Scenario 2 — Exact funding

- Existing funding: £600.
- Remaining gap: £400.
- DVA inbound line or reconciled amount: £400.
- Call wrapper with `p_allow_overfunding = false`.

Expected:

- funding total becomes £1,000.
- gap becomes £0.
- `funded_at` is stamped.
- no overfunding credit is created.

### Scenario 3 — Accidental overfunding blocked

- Order total: £1,000.
- Remaining gap: £1,000.
- DVA inbound line: £1,200.
- Call wrapper with `p_allow_overfunding = false`.

Expected:

- wrapper rejects the call.
- no `dva_reconciliation` row inserted.
- no `order_funding_events` row inserted.
- no importer overfunding credit created.

### Scenario 4 — Explicit overfunding allowed

- Order total: £1,000.
- Remaining gap: £1,000.
- DVA inbound line: £1,200.
- Call wrapper with `p_allow_overfunding = true`.

Expected:

- `dva_reconciliation` row inserted.
- `order_funding_events` records £1,200 funding contribution.
- funding total becomes £1,200.
- gap becomes £0.
- `funded_at` is stamped.
- importer overfunding credit of £200 is surfaced in `importer_credit_ledger` and `importer_balance_vw`.

### Scenario 5 — Already funded order with explicit overfunding

- Order already funded.
- DVA inbound line belongs to the same importer.
- Call wrapper with `p_allow_overfunding = true`.

Expected:

- allowed only for original orders.
- funding event is created.
- excess becomes importer credit through the existing trigger/helper path.
- return payload clearly reports overfunding.

### Scenario 6 — Importer mismatch blocked

- DVA statement belongs to Importer A.
- Target order belongs to Importer B.

Expected:

- wrapper rejects.
- no reconciliation or funding event is created.

### Scenario 7 — Replacement child blocked

- Target order has `order_type = 'replacement_child'`.

Expected:

- wrapper rejects even if `p_allow_overfunding = true`.

## UI wiring rule

No DVA match/reconcile buttons may be wired until all of the following are true:

1. `staff_reconcile_dva_line_to_order` exists in the live database.
2. The wrapper has passed the required test scenarios above.
3. The Next server action calls only the wrapper, not direct table writes.
4. The UI disables or clearly confirms overfunding before passing `p_allow_overfunding = true`.
5. The UI shows the returned `gap_after_gbp`, `funded_at`, and `overfunding_gbp` after success.

Until then, `/internal/funding` may show DVA rows, funding positions, importer balances, and immutable funding events, but must not expose DVA write buttons.

## Implementation note for later

When this contract is implemented, keep the change additive and narrow:

- one SQL wrapper function;
- one SQL regression section for the wrapper;
- no changes to the existing DVA trigger/helper behaviour unless the wrapper test proves a defect;
- no UI button until the wrapper is installed and tested.
