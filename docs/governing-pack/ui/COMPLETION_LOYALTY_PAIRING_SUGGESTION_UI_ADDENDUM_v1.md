# Completion Loyalty Pairing Suggestion UI Addendum v1

Status: locked UI/UX addendum for improving the completion-loyalty main-bank OUT + DVA/card IN pairing workflow without changing the accounting, credit release, Sage, VAT, residual, or shipper AP write logic.

This addendum governs the next UI/read-model build on:

`/internal/dva-reconciliation/main-bank?target=completion_loyalty`

It does **not** supersede the existing funding controls. It narrows how the interface should present and accelerate those controls.

This revision is aligned to `COMPLETION_LOYALTY_BULK_FUNDING_POT_AND_POSTING_CLARIFICATION_v1.md`, so it no longer assumes all bulk work is one reserved reward to one DVA/card IN line. Same-importer funding pots are allowed where one main-bank OUT and one DVA/card IN fund multiple same-importer rewards.

---

## 1. Builds on / linked governing sources

This addendum must be read together with the following existing contracts, addenda, and implementation locks:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
   - Current source-of-truth document.
   - Locks that completion-loyalty paired main-bank OUT + DVA/card IN is an internal transfer proof/release control.
   - Locks that applied-loyalty customer settlement is a separate Sage lane and must not be mixed with the funding proof lane.

2. `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
   - Governs the corrected cash-backed loyalty treatment.
   - Locks that the reward is not dashboard-available at clean completion or approval-in-principle.
   - Requires supervisor/admin funding/payment evidence before available dashboard credit is released.

3. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
   - Governs use of the shared main-bank matching workspace for completion loyalty.
   - Locks that shipper AP remains untouched.
   - Locks shared main-bank remaining-balance calculations and forbidden shortcuts.

4. `supabase/migrations/20260623_completion_loyalty_pairing_accounting_control_v1.sql`
   - Current backend implementation for:
     - `staff_stage_main_bank_line_to_completion_loyalty_v2(...)`;
     - `internal_staged_completion_loyalty_pairs_v1(...)`;
     - `internal_completion_loyalty_destination_in_candidates_v1(...)`;
     - `staff_pair_loyalty_destination_in_and_release_v1(...)`.
   - This addendum does not replace those RPCs.

5. `supabase/migrations/20260624_completion_loyalty_resetless_supersede_v1.sql`
   - Related corrective control for failed/unposted completion-loyalty Sage batches.
   - Included here only to preserve the boundary: funding proof/release is not the same as applied-loyalty Sage settlement or Sage-batch retirement.

6. `docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`
   - Governs DVA/card statement control principles that this UI must respect when selecting inbound DVA/card top-up lines.

7. `docs/governing-pack/ui/DVA_RECONCILIATION_ACTION_CONTRACT.md`
   - Governs DVA reconciliation action discipline and staff-only reconciliation controls.

8. `docs/governing-pack/ui/COMPLETION_LOYALTY_BULK_FUNDING_POT_AND_POSTING_CLARIFICATION_v1.md`
   - Clarifies that one main-bank OUT plus one DVA/card IN may fund many same-importer completion-loyalty rewards.
   - Confirms the applied-loyalty Sage batch lane is still driven by `order_funding_events.credit_applied` and does not need a runtime change for bulk funding pots.
   - Locks that future internal-transfer Sage posting should aggregate by funding pot rather than naïvely post one internal-transfer journal per reward match.

If any of these documents conflict, this addendum is subordinate to the accounting/funding principles in the Current Locked Pack, the Cash-Backed Credit Addendum v2, the Main Bank Loyalty Reward Funding Integration Addendum v1, and the Bulk Funding Pot clarification.

---

## 2. Existing locked backend behaviour remains unchanged

The UI must not introduce a new write path.

Existing write paths remain:

```text
Reserve/stage OUT:
staff_stage_main_bank_line_to_completion_loyalty_v2(...)

Pair destination IN and release dashboard credit:
staff_pair_loyalty_destination_in_and_release_v1(...)
```

The old backward-compatible name:

```text
staff_match_main_bank_line_to_completion_loyalty_v1(...)
```

must continue to stage only. It must not release dashboard credit from the main-bank OUT alone.

The UI/read-model work must not change:

```text
- main_bank_shipper_ap_allocations;
- shipper AP matching or posting;
- importer_credit_ledger release rules;
- order_funding_events credit application rules;
- VAT timing or VAT return logic;
- Sage posting behaviour;
- accepted-estimate funding thresholds;
- final sale settlement calculations;
- DVA/card statement import or reconciliation write semantics;
- FX/payment variance, bank fee, or hold residual posting.
```

---

## 3. UX correction being locked

The current functional workflow is correct but the original UI exposed too much of the two-stage accounting control at once.

Correct user mental model:

```text
Completion loyalty funding queue

1. Create new OUT reservation, if needed.
2. Complete existing OUT reservation, if already staged.
3. For same-importer funding pots, review grouped source OUT/destination IN capacity and release selected reward rows through the existing validations.
```

When reserved OUT rows exist, the primary UI must be:

```text
Ready to release queue
→ show reserved OUT row or funding-pot group
→ show best same-importer DVA/card IN suggestion
→ staff clicks Pair IN and release, or later bulk action that preserves the same validations
```

The page must not force the user to scroll through the new-reservation card workflow when the current task is already at the pairing/release stage.

The manual reservation/residual workspace must remain accessible because it contains existing residual allocation controls.

---

## 4. Primary panel rule

In completion-loyalty mode, the top operational panel must prioritise existing reserved OUT rows and funding-pot release opportunities.

Primary panel name:

```text
Ready to release queue
```

It must show for single-row cases:

```text
- order reference;
- importer/customer name;
- reward amount;
- reserved main-bank OUT reference/date/amount;
- suggested same-importer DVA/card IN candidate;
- match quality label;
- reason for the suggestion;
- Pair IN and release action.
```

It must show for funding-pot cases:

```text
- importer/customer name;
- source main-bank OUT line;
- destination DVA/card IN line;
- total source OUT amount;
- total destination IN amount;
- amount already consumed by released rewards;
- remaining source/destination capacity;
- selected reward rows and total selected reward value;
- pot match quality label;
- review/release action only where same-importer and remaining-balance validations pass.
```

The lower/main-bank reservation workspace may appear as a secondary/manual section. It must not be removed because it also preserves the existing residual controls for FX/payment variance, bank fee, and hold allocation.

---

## 5. Importer filtering rule

DVA/card IN candidates must default-filter by the importer on the reserved OUT row or funding-pot group.

For a reserved OUT row:

```text
main_bank_completion_loyalty_funding_matches.importer_id = X
```

Normal candidate suggestions must only use:

```text
dva_statements.importer_id = X
statement_account_context = importer_dva_card_account
direction = in
remaining_gbp > 0
```

Different-importer DVA/card IN lines must not be presented as normal suggestions.

A future manual override may allow staff/admin to inspect different-importer lines only if a separate exception reason/audit trail is added. That override is not part of this v1 addendum.

---

## 6. Suggestion/rating card rule

The UI should not present a flat dropdown of every available DVA/card IN candidate as the default experience.

For each reserved OUT row or funding-pot group, show a ranked suggestion card.

Minimum scoring bands:

```text
Exact single-row
- same importer;
- remaining IN amount equals reserved reward amount;
- IN amount is sufficient;
- candidate is not already consumed.

Exact funding-pot
- same importer;
- one source OUT plus one destination IN can fund all selected same-importer reward rows;
- total selected reward equals or is within available remaining source/destination capacity;
- no different-importer rows included.

Strong
- same importer;
- remaining IN amount is sufficient;
- date is close or reference strongly suggests top-up/order/importer link;
- or source/destination IN appears to be a bulk top-up with enough remaining capacity.

Review
- same importer;
- amount/date/reference are plausible but ambiguous;
- multiple candidates have similar score;
- amount is higher than one reward and may represent a bulk top-up;
- selected rewards do not yet equal the pot amount exactly.

No match
- no same-importer IN candidate with sufficient remaining amount.
```

The score is advisory only. It must not release credit automatically.

---

## 7. Bulk handling for many orders

For a high-volume case, such as one importer/customer with 50 qualifying orders in one shipment, the page must not require 50 manual searches across unrelated candidates.

The UI must support two valid patterns:

```text
Single-row pattern:
1 reserved reward OUT amount -> 1 same-importer DVA/card IN candidate

Funding-pot pattern:
1 source main-bank OUT + 1 destination DVA/card IN -> many same-importer rewards
```

Required high-volume layout:

```text
Ready to release queue

Summary:
- Exact single-row matches
- Exact funding-pot matches
- Strong matches
- Review needed
- No IN found yet

Grouped by importer.
```

Bulk release may be added only after single-row release is proven.

Bulk release constraints:

```text
- same importer;
- sufficient remaining source OUT capacity;
- sufficient remaining destination IN capacity;
- no different-importer rewards included;
- staff explicitly selects/approves the rows;
- no automatic/background release;
- backend still calls staff_pair_loyalty_destination_in_and_release_v1 row-by-row, or a later wrapper that preserves the same validations for each contributing match.
```

Do not require one DVA/card IN line per reward where a same-importer funding pot legitimately funds multiple rewards.

---

## 8. Manual review behaviour

Manual picker remains available only as a secondary control.

Manual review rows must show why the row is not exact:

```text
- amount mismatch;
- multiple same-amount candidates;
- date distance;
- reference mismatch;
- bulk top-up amount greater than one reward;
- selected reward total does not equal the funding pot amount;
- no same-importer candidate.
```

The staff user should be able to select a candidate manually only within the same importer by default.

The write action must still route through:

```text
staff_pair_loyalty_destination_in_and_release_v1(...)
```

or a later wrapper that preserves the same importer, remaining source/destination capacity, locking, and staff-authority validations.

---

## 9. Read-model shape for the build

Preferred smallest read-only addition:

```text
internal_completion_loyalty_pairing_suggestions_v1(
  p_importer_id uuid default null,
  p_search text default null,
  p_status text default 'open',
  p_limit integer default 100,
  p_offset integer default 0
)
```

Minimum output fields:

```text
loyalty_match_id
order_id
order_ref
importer_id
importer_name
reserved_out_statement_line_id
reserved_out_reference
reserved_out_date
reserved_out_amount_gbp
matched_gbp_amount
suggested_in_statement_line_id
suggested_in_reference
suggested_in_date
suggested_in_remaining_gbp
match_band
match_score
match_reason
candidate_count_same_importer
candidate_count_exact_amount
funding_pot_key
funding_pot_total_gbp
funding_pot_remaining_source_gbp
funding_pot_remaining_destination_gbp
funding_pot_selected_reward_total_gbp
can_bulk_release
blocker
```

This read model may wrap existing:

```text
internal_staged_completion_loyalty_pairs_v1(...)
internal_completion_loyalty_destination_in_candidates_v1(...)
```

It must not perform writes.

---

## 10. Acceptance tests

### A. Existing single reserved OUT

Given:

```text
Reserved OUT: ORD-1781788078147, importer X, £13.50
DVA/card IN: importer X, £13.50
```

Expected:

```text
- primary panel shows the reserved OUT row first;
- exact same-importer IN candidate is suggested first;
- staff can click Pair IN and release;
- result becomes released_available_dashboard_credit / paired_released;
- importer_credit_ledger credit is created/unlocked;
- no Sage posting is triggered.
```

### B. No reserved OUT, but clean reward targets exist

Expected:

```text
- create-new-reservation workspace appears or is accessible as secondary/manual reservation;
- user can select main-bank OUT and reward target;
- action creates source_out_reserved only;
- dashboard credit is still not available.
```

### C. Reserved OUT exists, no same-importer IN

Expected:

```text
- primary panel shows No match / Waiting for DVA/card IN;
- release button is disabled;
- unrelated different-importer IN lines are not suggested as normal matches.
```

### D. One importer, many rewards, one OUT and one IN funding pot

Given:

```text
50 same-importer qualifying reward rows
one main-bank OUT large enough to fund the selected rows
one DVA/card IN large enough to fund the selected rows
```

Expected:

```text
- rows grouped by importer/funding pot;
- selected reward total, source OUT remaining, and destination IN remaining are visible;
- system does not demand one DVA/card IN per reward;
- staff can release selected same-importer rows only through existing validations or a wrapper preserving them;
- no duplicate release or reused over-capacity DVA/card IN line is possible;
- no Sage posting is triggered by the pairing UI.
```

---

## 11. Forbidden shortcuts

Do not:

```text
- auto-release loyalty without a staff action;
- suggest different-importer IN lines as normal matches;
- hide the fact that the credit is not released until IN pairing;
- merge this workflow into shipper AP matching;
- reuse main_bank_shipper_ap_allocations for loyalty;
- bypass main-bank remaining balance checks;
- bypass destination IN remaining balance checks;
- remove or hide FX/payment variance, bank fee, or hold residual posting controls;
- post to Sage from this suggestion UI;
- create VAT or customer invoice effects from this suggestion UI;
- change credit application to future orders;
- change applied-loyalty Sage batch materialisation.
```

---

## 12. Build consequence

The next UI build should be a safe presentation/read-model layer first:

```text
1. Read-only suggestion queue.
2. Single-row pair/release from suggestion card using existing RPC.
3. Funding-pot grouping/readiness display for same-importer bulk cases.
4. Bulk release only after single-row behaviour is proven, and only through existing validations or a wrapper preserving them.
5. Manual-review controls only after exact/strong suggestion behaviour is proven.
```

No applied-loyalty posting code change is required for this UI layer.
