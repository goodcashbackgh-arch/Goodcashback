# Completion Loyalty Bulk Funding Pot and Posting Clarification v1

Status: locked clarification after reviewing the existing completion-loyalty funding, release, and Sage posting build.

This document answers whether the already-built completion-loyalty Sage posting solution must change because one importer/customer may have many qualifying orders in a shipment and the business may make one main-bank OUT and one DVA/card IN top-up to fund multiple completion-loyalty rewards.

Conclusion: the already-built **applied-loyalty customer settlement Sage batch lane does not need a code change** for this scenario. The required correction is to the future **internal-transfer posting presentation/materialisation**, not the applied-loyalty settlement batch.

---

## 1. Linked governing sources

This clarification builds on:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
   - Locks that paired main-bank OUT + DVA/card IN is an internal-transfer proof/release control.
   - Locks that applied-loyalty customer settlement is a separate Sage lane from `order_funding_events.credit_applied`.

2. `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
   - Locks that reward credit becomes available only after supervisor/admin funding proof.

3. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
   - Locks shared main-bank OUT consumption and residual allocation handling.

4. `docs/governing-pack/ui/COMPLETION_LOYALTY_PAIRING_SUGGESTION_UI_ADDENDUM_v1.md`
   - Locks same-importer filtering and suggestion cards.
   - This document supersedes only the narrow one-to-one bulk assumption in that UI addendum where a same-importer bulk top-up funds multiple rewards.

5. `docs/governing-pack/ui/COMPLETION_LOYALTY_SAGE_ACCOUNTING_POSTING_ADDENDUM_v1.md`
   - Locks separate accounting lanes:
     - loyalty funding transfer;
     - applied-loyalty customer settlement.

6. `docs/governing-pack/ui/COMPLETION_LOYALTY_SAGE_BATCH_POSTING_ADDENDUM_v1.md`
   - Locks the batch-led posting model for applied-loyalty customer settlement.

7. `supabase/migrations/20260623_completion_loyalty_pairing_accounting_control_v1.sql`
   - Current funding/release implementation:
     - `staff_stage_main_bank_line_to_completion_loyalty_v2(...)`;
     - `staff_pair_loyalty_destination_in_and_release_v1(...)`;
     - `staff_apply_completion_loyalty_to_order_v1(...)`.

8. `supabase/migrations/20260624_completion_loyalty_sage_posting_lifecycle_controls_v1.sql`
   - Current applied-loyalty Sage materialisation implementation.

9. `supabase/migrations/20260624_completion_loyalty_sage_batch_posting_v1.sql`
   - Current applied-loyalty Sage batch wrapper.

---

## 2. Existing backend already supports bulk funding consumption

The funding/release backend does not require a strict one-to-one source statement line per reward.

A single main-bank OUT line can be consumed by more than one completion-loyalty funding match because the staging function subtracts existing loyalty allocations on the source OUT line before allowing a new staged amount.

A single DVA/card IN line can be consumed by more than one completion-loyalty release because the destination IN candidate and pairing logic subtract already-consumed loyalty IN amounts before allowing the next release.

Therefore the control model can support:

```text
Importer A
50 completed orders qualify for loyalty
Total reward = £675

One main-bank OUT = £675
One DVA/card IN = £675

50 reward releases consume the same OUT/IN funding pot until remaining = £0
```

This is a **funding pot** pattern, not a strict one-reward/one-transfer pattern.

---

## 3. No change required to applied-loyalty customer settlement posting

The applied-loyalty Sage settlement lane starts only after released loyalty credit is later applied to an order.

Its source remains:

```text
order_funding_events.event_type = 'credit_applied'
linked to importer_credit_ledger debit
linked to source credit where source_type = 'completion_loyalty_reward'
```

That source chain remains valid whether the reward credit originally came from:

```text
- one OUT/IN pair funding one reward; or
- one OUT/IN funding pot funding many rewards; or
- several OUT/IN top-ups funding many rewards.
```

The existing applied-loyalty materialisation already works at the `credit_applied` event level. If a future order consumes multiple released loyalty lots, `staff_apply_completion_loyalty_to_order_v1(...)` creates debit ledger rows and `order_funding_events.credit_applied` rows per consumed lot. Those events can be materialised and batched through the existing applied-loyalty Sage batch lane.

Do not change the applied-loyalty posting adapter merely because a funding pot funded multiple rewards.

---

## 4. Future internal-transfer posting must aggregate by funding pot

The area that does require clarification is the later internal-transfer posting phase.

A naive internal-transfer journal per reward match would be technically reconcilable in total, but operationally poor if one source OUT and one destination IN fund 50 rewards. It would create 50 internal-transfer journals for one actual transfer pair.

For future internal-transfer Sage posting, group by funding pot:

```text
source_out_statement_line_id
+ destination_in_statement_line_id
+ importer_id
+ source_out_date
+ destination_in_date
+ activation_route
```

Then materialise one internal-transfer posting group for the aggregate amount:

```text
sum(main_bank_completion_loyalty_funding_matches.matched_gbp_amount)
```

Subject to:

```text
match_status = 'released_available_dashboard_credit'
transfer_pair_status = 'paired_released'
destination_in_statement_line_id is not null
```

The group must retain traceability to all contributing loyalty match ids and order ids.

Minimum aggregate group payload:

```text
source_out_statement_line_id
destination_in_statement_line_id
importer_id
source_out_date
destination_in_date
activation_route
matched_total_gbp
loyalty_match_ids[]
completed_order_ids[]
credit_ledger_ids[]
source_out_reference
destination_in_reference
```

---

## 5. Internal-transfer accounting treatment remains unchanged

If source OUT date and destination IN date are the same accounting date:

```text
Dr DVA/card/virtual-card bank / clearing asset
Cr main bank
```

If dates differ, especially across period cut-off, use the existing in-transit clearing treatment:

```text
On source OUT date:
Dr loyalty transfer in-transit clearing
Cr main bank

On destination IN date:
Dr DVA/card/virtual-card bank / clearing asset
Cr loyalty transfer in-transit clearing
```

This does not affect applied-loyalty customer settlement posting.

---

## 6. UI consequence

The completion-loyalty pairing UI must distinguish:

```text
Single exact match:
one reserved reward OUT amount = one DVA/card IN amount

Bulk funding pot:
one source OUT and one destination IN fund many same-importer rewards
```

For bulk funding pot cases, the UI should show:

```text
Importer: X
Funding pot OUT: £675
Funding pot IN: £675
Rewards selected/released: 50
Total selected reward: £675
Remaining source OUT: £0
Remaining destination IN: £0
```

The existing single-row suggestion card remains valid for low-volume cases. Bulk-pot UI is an additional efficiency layer, not a replacement for the locked RPCs.

---

## 7. No-impact boundary

This clarification must not change:

```text
- staff_stage_main_bank_line_to_completion_loyalty_v2(...);
- staff_pair_loyalty_destination_in_and_release_v1(...);
- staff_apply_completion_loyalty_to_order_v1(...);
- applied-loyalty customer settlement materialisation;
- applied-loyalty Sage batch posting;
- shipper AP matching/posting;
- FX/payment variance, bank fee, or unmatched hold residual posting;
- VAT timing or VAT return logic;
- final sale settlement logic;
- order funding threshold logic;
- customer sales invoice posting.
```

---

## 8. Simplest seamless future patch

The safest future implementation is additive and read-model first:

```text
1. Add read-only funding-pot grouping view/RPC for paired_released loyalty matches.
2. Show bulk-pot rows in the UI for staff review.
3. Keep existing single-row stage/pair/release RPCs as the only release write path unless a later wrapper is added.
4. If a wrapper is added, it must call or preserve the same validations as staff_pair_loyalty_destination_in_and_release_v1(...) for each contributing match.
5. Build internal-transfer Sage posting from grouped pot rows, not individual reward rows, only when the internal-transfer posting phase is explicitly built.
```

No immediate code change is required to the applied-loyalty Sage batch solution.
