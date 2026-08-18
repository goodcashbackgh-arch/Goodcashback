# Final-Balance IN FX Residual Classification Amendment v1

Status: governing implementation amendment. Frozen before build.

Date: 2026-08-18.

Parent authority:
- `docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`

Preserved upstream/downstream authorities:
- June final-balance allocation writer: `public.staff_allocate_statement_line_to_final_balance_payment_v1(uuid,uuid,boolean,text)`.
- July amount-aware statement control: `public.statement_line_control_position_v1` and `public.internal_statement_line_control_resolver_v2(uuid)`.
- July canonical settlement: `public.order_settlement_resolution_position_v1`.
- August deferred pending-receipt surplus correction.
- August DVA funding-consumption hardening / PR #246.
- August completion-loyalty settlement-v2 integration / PR #238.
- Existing cash workbench and Sage FX-journal posting paths.

This amendment does not replace or rewrite those authorities. It closes one missing integration seam in the staff DVA/card workbench.

## 1. Proven defect

The governing workbench contract requires final-balance money to be handled in two stages when staff chooses not to classify the excess atomically:

```text
IN statement line
  -> final_balance_payment first
  -> only after final balance reaches zero
  -> classify any true residual
```

The live final-balance writer already supports the correct economic split when `p_classify_fx_excess = true`:

```text
final_balance_payment + fx_card_difference
```

A later June UI change deliberately set `p_classify_fx_excess = false` for the active client-controller path so staff could classify the residual separately after the balance had been cleared.

The separate residual form, however, delegates to `public.staff_allocate_statement_line_to_fx_card_or_fee(...)`, whose existing contract is deliberately OUT-only. Therefore a valid IN final-balance residual cannot complete the second stage.

This is an integration gap. It is not a settlement-arithmetic defect, not an order-funding defect, not an FX-ledger defect and not a reason to broaden the established OUT residual writer.

## 2. Controlled live proof

Controlled order:

```text
order_id  = 6f41a088-8e4a-44e3-80f3-f4631b3d0002
order_ref = ORD-1786712731703
```

Controlled statement line:

```text
statement_line_id        = f36b93f8-16aa-46f0-a92d-bebdd4b919c0
direction                = in
statement_account_context= importer_dva_card_account
statement GBP            = £20.19
confirmed final balance  = £19.99
canonical consumed       = £19.99
canonical remaining      = £0.20
canonical overconsumed   = £0.00
principal lane count     = 1
active principal lane    = final_balance_payment
confirmed FX on this line= £0.00
final balance due        = £0.00
```

The same order already has a separate, valid, confirmed customer-IN FX allocation of £7.53 from the original funding receipt. Canonical order settlement shows:

```text
funding_total_gbp                    = £752.99
final_balance_payment_gbp            = £19.99
inbound_fx_receipt_residual_gbp      = £7.53
order_attributed_receipt_gbp         = £780.51
gross_positive_difference_gbp       = £7.53
total_classified_gbp                 = £7.53
remaining_unresolved_gbp             = £0.00
over_resolved_gbp                    = £0.00
resolution_status                    = fully_resolved
```

Settlement v2 separately shows:

```text
amount_received_gbp  = £772.98
final sale value      = £772.98
final balance due     = £0.00
final settlement      = settled_nil
completion            = complete
```

These facts prove that final-balance cash and inbound FX are separate economic lanes downstream.

## 3. Reuse-first rule

The patch must reuse the existing treasury model. It must not create a parallel money model.

Reuse exactly:

1. `dva_statement_line_allocations` for the classification row.
2. Existing `fx_card_difference` allocation semantics.
3. Existing June final-balance FX row shape:
   - same statement line;
   - same linked order;
   - `allocation_type = 'fx_card_difference'`;
   - `allocation_status = 'confirmed'`;
   - `allocated_gbp_amount = residual`;
   - `fx_or_card_diff_gbp = residual`;
   - preserve statement `fx_rate_applied` and `card_markup_pct_applied`;
   - created/confirmed by the authenticated active staff user.
4. `statement_line_control_position_v1` as the only statement-consumption authority.
5. `internal_order_final_sale_settlement_v2(...)` only to prove the linked order final balance is already zero.
6. The existing residual UI form.
7. The existing OUT residual server action/RPC unchanged for OUT statement lines.
8. Existing canonical settlement, completion-loyalty, cash-posting and Sage FX-journal paths downstream.

## 4. Exact technical change

### 4.1 New sibling RPC

Add one function only:

```text
public.staff_classify_final_balance_in_fx_residual_v1(
  p_dva_statement_line_id uuid,
  p_expected_residual_gbp numeric,
  p_notes text default null
) returns jsonb
```

This is not a general IN residual classifier. It classifies only a proven final-balance IN residual as `fx_card_difference`.

The RPC must:

1. require `auth.uid()`;
2. require active `admin` or `supervisor` staff;
3. lock the selected physical statement line;
4. require `direction = 'in'`;
5. require `statement_account_context = 'importer_dva_card_account'`;
6. read `statement_line_control_position_v1`;
7. require canonical `overconsumed_gbp = 0` within the existing 0.005 tolerance;
8. require canonical `active_reserved_gbp = 0` within tolerance;
9. require `principal_lane_count = 1`;
10. require `final_balance_payment` to be an active economic lane;
11. require exactly one confirmed, non-reversed `final_balance_payment` allocation on the selected line with a non-null `order_id`;
12. derive the order from that allocation; the browser must not supply an order id;
13. lock and validate that order;
14. require statement importer = order importer;
15. reject archived/cancelled orders;
16. call `internal_order_final_sale_settlement_v2(derived_order_id)` and require posted final-sale value plus final balance due = £0.00 within tolerance;
17. read canonical `remaining_unconsumed_gbp` and require it to be positive;
18. require `p_expected_residual_gbp` to equal the canonical remaining amount within 0.005; the caller cannot choose a different economic amount;
19. require no existing confirmed/non-reversed `fx_card_difference` allocation on this exact statement line;
20. insert exactly one confirmed `fx_card_difference` row using the established June row shape;
21. re-read canonical statement control after insert;
22. require canonical remaining = £0.00, overconsumed = £0.00, reserved = £0.00 and principal-lane count still = 1;
23. return the inserted allocation id, derived order id/ref, residual amount and canonical postcondition values.

No UPDATE or DELETE of existing allocation rows is permitted.

### 4.2 Server action

Add one direction-aware sibling server action.

It must read the selected statement line direction before mutation.

```text
OUT -> delegate to existing allocateStatementLineToFxCardOrFeeAction(formData) unchanged.
IN  -> permit only allocation_type = fx_card_difference, then call the new sibling RPC.
other/null -> reject.
```

For IN, `allocated_gbp_amount` from the existing form is treated as `p_expected_residual_gbp`; the database proves it equals canonical remaining.

The server action must not send an order id to the new RPC.

### 4.3 UI

Reuse the existing `FxResidualAllocationForm`.

Change only its form action to the direction-aware sibling server action.

Do not redesign the form, labels, filters, amounts, selectors or layout in this patch.

The existing OUT user experience must remain observationally equivalent because OUT delegates to the exact existing action.

### 4.4 Older server-rendered final-balance route

Do not rewrite the final-balance RPC in this patch.

The active client-controller route already deliberately submits `classify_fx_excess = false`.

Any older server-rendered route that still exposes automatic classification must be treated as a separate consistency cleanup unless live routing proves it can still be reached in the same production path. This amendment does not authorize broad rewiring of final-balance actions merely to remove dead/fallback code.

## 5. Explicitly frozen / forbidden changes

The patch must not modify the definitions of:

```text
public.staff_allocate_statement_line_to_final_balance_payment_v1(...)
public.staff_allocate_statement_line_to_fx_card_or_fee(...)
public.staff_reconcile_dva_line_to_order(...)
public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1(...)
public.staff_reconcile_dva_line_to_order_pending_surplus_v1(...)
public.internal_order_final_sale_settlement_v1(...)
public.internal_order_final_sale_settlement_v2(...)
public.internal_statement_line_control_resolver_v2(...)
public.statement_line_control_position_v1
public.statement_line_control_usage_v1
public.order_settlement_resolution_position_v1
public.internal_cash_posting_workbench_rows_v1(...)
public.internal_freeze_cash_control_rows_v1(...)
```

Also forbidden:

- no accepted-estimate funding changes;
- no final-sale arithmetic changes;
- no customer/importer credit creation;
- no change to the existing £7.53 inbound-FX allocation;
- no supplier OUT FX reclassification;
- no change to pending-receipt surplus/£0.79 logic;
- no completion-loyalty change;
- no Sage mapping/posting change;
- no VAT change;
- no statement import/OCR change;
- no supplier allocation change;
- no shipper/AP change;
- no historical rewrite/backfill;
- no automatic mass repair of existing residuals.

## 6. Live fingerprints frozen for this build

The 2026-08-18 live preflight established these current fingerprints. The migration/regression must fail closed if any of these differ before the controlled release:

```text
staff_allocate_statement_line_to_final_balance_payment_v1 = c8ef31c0e5ef974624d261b3fd2d200b
staff_reconcile_dva_line_to_order_customer_fx_gain_v1      = ab9a0a7db133fced0ab2995c6ee35ee2
staff_allocate_statement_line_to_fx_card_or_fee             = f36e0e0fdc35a15bcd4b80f16b33a21b
internal_order_final_sale_settlement_v2                      = f952daa5eafc87279c446ec09aa5a692
order_settlement_resolution_position_v1                      = 9fdcf4597e682b1d29f88320700c8856
internal_freeze_cash_control_rows_v1                         = be6bbe8b164556976215af6ff598290b
internal_cash_posting_workbench_rows_v1                      = bcd232d99015ac20b2f2c22795989fc6
```

The August frozen authorities also matched exactly and must remain unchanged:

```text
staff_reconcile_dva_line_to_order(...)                       = 3d888918bff171d132049104b5692937
staff_reconcile_dva_line_to_order_pending_surplus_v1(...)    = 93d34501d77c71d4c3ace0424f1d29b5
internal_statement_line_control_resolver_v2(uuid)             = eb9bfa5ea572335272217c372fa02f53
statement_line_control_position_v1                            = fe6ee2fc8909e383b8d584995b30cc78
statement_line_control_usage_v1                               = 581d367a31ab0f689f3d31b46df5922e
```

## 7. Required regression

Provide one assertion-driven regression SQL that runs inside a transaction and rolls back all behavioural fixtures.

It must prove:

1. all frozen fingerprints match before the exercise;
2. new RPC exists, is SECURITY DEFINER, search path locked, anon execute revoked and authenticated execute granted;
3. OUT residual writer definition is unchanged;
4. final-balance writer definition is unchanged;
5. valid synthetic case:
   - importer DVA/card IN line;
   - confirmed final-balance allocation already present;
   - linked settlement final balance = zero;
   - canonical residual positive;
   - new RPC inserts one FX row;
   - canonical remaining becomes zero;
   - overconsumed remains zero;
   - principal lane count remains one;
6. wrong direction is rejected with no residue;
7. open final balance is rejected with no residue;
8. amount mismatch/over-allocation is rejected with no residue;
9. absence of confirmed final-balance allocation is rejected with no residue;
10. duplicate FX classification on the same line is rejected with no residue;
11. existing customer-IN funding+FX path remains unchanged;
12. existing OUT FX path remains unchanged;
13. all frozen fingerprints match again after exercises;
14. the regression transaction rolls back and leaves no fixture rows.

`BLOCKED_PREREQUISITE` is not a pass. Merge requires `PASS`.

## 8. Controlled live acceptance

After migration + rollback regression pass and application build succeeds, use only the existing controlled live residual:

```text
statement line: f36b93f8-16aa-46f0-a92d-bebdd4b919c0
expected residual: £0.20
```

Expected post-UAT statement position:

```text
physical statement amount = £20.19
final_balance_payment      = £19.99
fx_card_difference         = £0.20
active consumed            = £20.19
remaining                  = £0.00
overconsumed               = £0.00
principal lane count       = 1
```

Expected order settlement v2 remains:

```text
amount received        = £772.98
final sale value       = £772.98
final balance due      = £0.00
final settlement state = settled_nil
completion state       = complete
```

Expected canonical settlement changes only by the new classified inbound FX:

```text
inbound_fx_receipt_residual_gbp: £7.53 -> £7.73
gross_positive_difference_gbp:  £7.53 -> £7.73
total_classified_gbp:            £7.53 -> £7.73
remaining_unresolved_gbp:        £0.00
over_resolved_gbp:               £0.00
resolution_status:               fully_resolved
```

The pre-existing £7.53 allocation row must remain byte-for-byte/row-for-row untouched.

## 9. Release order

Required order:

```text
1. governing amendment committed;
2. implementation committed;
3. regression committed;
4. application/build checks pass;
5. migration deliberately run in live Supabase;
6. regression returns PASS;
7. controlled £0.20 UAT through existing workspace control;
8. post-UAT read-only verification;
9. only then mark PR ready/merge.
```

No step may be skipped because the surrounding treasury build is intentionally preservation-first.
