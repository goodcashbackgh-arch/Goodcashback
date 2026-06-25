# Completion Loyalty Multi-Reward OUT Reservation Addendum v1

Status: locked UI/action addendum for reserving one main-bank OUT line against multiple same-importer completion-loyalty reward targets.

This addendum corrects the UX problem where staff previously had to select the same OUT line repeatedly for each reward target before the funding-pot group appeared.

The corrected user flow is:

```text
1. Select one main-bank OUT line.
2. Tick one or more clean completion-loyalty reward targets for the same importer.
3. Click Reserve selected reward(s) OUT.
4. The system creates one staged loyalty-funding match per selected reward, all linked to the same source OUT line.
5. The ready-to-release queue groups those staged rows into a funding pot.
6. Staff then pairs/releases the group against a same-importer DVA/card IN line.
```

---

## 1. Governing sources

This addendum builds on:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
2. `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
3. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
4. `docs/governing-pack/ui/COMPLETION_LOYALTY_PAIRING_SUGGESTION_UI_ADDENDUM_v1.md`
5. `docs/governing-pack/ui/COMPLETION_LOYALTY_BULK_FUNDING_POT_AND_POSTING_CLARIFICATION_v1.md`
6. `supabase/migrations/20260623_completion_loyalty_pairing_accounting_control_v1.sql`
7. `supabase/migrations/20260625_completion_loyalty_bulk_funding_pot_release_v1.sql`

If there is conflict, the cash-backed funding rule remains superior: reward credit is not dashboard-available until DVA/card/customer-account funding proof is paired/released.

---

## 2. Accounting boundary

This addendum does not change the accounting model.

The new UX only improves the reserve/stage step.

It must not change:

```text
- DVA/card IN pairing/release validation;
- importer_credit_ledger release rules;
- order_funding_events credit application;
- applied-loyalty Sage posting;
- internal-transfer Sage posting rules;
- VAT timing;
- customer sales invoicing;
- shipper AP matching/posting;
- FX/payment variance, bank fee, or hold residual posting.
```

---

## 3. Write-path rule

The multi-select reserve action must preserve the existing row-level reserve validation.

Allowed implementation:

```text
For each selected reward target:
  call staff_stage_main_bank_line_to_completion_loyalty_v2(...)
```

or a future wrapper that preserves the same validations.

The action may create several staged rows in one staff submission, but each staged row remains a separate `main_bank_completion_loyalty_funding_matches` row linked to its own completed order/reward approval.

This is important because apply-to-order, audit trail, and future Sage settlement rely on reward/order-level traceability.

---

## 4. UI rule

The manual reservation workspace should say:

```text
Select one main-bank OUT line
Tick loyalty reward target(s)
Reserve selected reward(s) OUT
```

It should not force staff to repeat the same OUT-line selection for each reward target.

For the summary/floating bar, show:

```text
- selected bank line;
- selected reward count;
- selected reward total;
- residual amount if any;
- gap/over-selection warning.
```

---

## 5. Same-importer rule

One main-bank OUT loyalty funding pot may reserve multiple rewards only when all selected reward targets belong to the same importer.

If selected rewards include more than one importer, block the action and require separate OUT lines/groups.

Reason:

```text
same importer + same source OUT line = funding-pot group
```

Different importers must not be grouped into one pot.

---

## 6. Remaining-balance rule

The selected reward total must not exceed the selected main-bank OUT line remaining amount after existing shipper AP, loyalty, and residual consumption.

If:

```text
selected rewards total > available OUT remaining
```

block reservation.

If:

```text
selected rewards total < available OUT remaining
```

the residual/variance route remains separate and must not be hidden.

---

## 7. Acceptance test

Given:

```text
main-bank OUT = £27.00
reward A = £13.50
reward B = £13.50
same importer
```

When staff selects the £27 OUT and ticks reward A and reward B, then clicks `Reserve selected reward(s) OUT`, expected result is:

```text
- two staged main_bank_completion_loyalty_funding_matches rows;
- both rows have same importer_id;
- both rows have same source dva_statement_line_id;
- both rows remain source_out_reserved;
- no dashboard credit released;
- no Sage posting;
- no VAT/customer invoice effect;
- ready-to-release queue shows one Exact pot with 2 rewards.
```

Then, after staff clicks `Bulk release exact pot` against the same-importer £27 DVA/card IN, expected result is:

```text
- the two staged rows are paired/released through existing validations;
- available dashboard credit is created/unlocked for each reward/order;
- the funding-pot card disappears from the waiting queue;
- applied-loyalty customer settlement remains unchanged and only starts when credit is later applied to an order.
```

---

## 8. Forbidden shortcuts

Do not:

```text
- infer reward/order rows from OUT/IN references alone;
- auto-select rewards from OCR/bank text;
- group different importers;
- release credit at the reserve step;
- post to Sage at the reserve step;
- hide residual controls;
- collapse multiple reward rows into one ledger row;
- remove order-level traceability.
```

---

## 9. Current implementation note

The current UI implementation may use a client-side multi-select list and the existing server action `matchMainBankLineToCompletionLoyaltyAction` to submit multiple `order_id` values.

The server action must re-check:

```text
- selected OUT exists;
- selected reward targets are still reward-ready/open;
- all selected rewards belong to one importer;
- selected total does not exceed remaining OUT capacity;
- each row is staged through staff_stage_main_bank_line_to_completion_loyalty_v2(...).
```

This keeps the improved UI aligned with the locked backend controls.
