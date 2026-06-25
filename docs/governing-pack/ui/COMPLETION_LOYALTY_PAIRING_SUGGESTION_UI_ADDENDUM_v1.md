# Completion Loyalty Pairing Suggestion UI Addendum v1

Status: locked UI/UX addendum for improving the completion-loyalty main-bank OUT + DVA/card IN pairing workflow without changing the accounting, credit release, Sage, VAT, or shipper AP write logic.

This addendum governs the next UI/read-model build on:

`/internal/dva-reconciliation/main-bank?target=completion_loyalty`

It does **not** supersede the existing funding controls. It narrows how the interface should present and accelerate those controls.

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

If any of these documents conflict, this addendum is subordinate to the accounting/funding principles in the Current Locked Pack, the Cash-Backed Credit Addendum v2, and the Main Bank Loyalty Reward Funding Integration Addendum v1.

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
- DVA/card statement import or reconciliation write semantics.
```

---

## 3. UX correction being locked

The current functional workflow is correct but the original UI exposed too much of the two-stage accounting control at once.

Correct user mental model:

```text
Completion loyalty funding queue

1. Create new OUT reservation, if needed.
2. Complete existing OUT reservation, if already staged.
```

When reserved OUT rows exist, the primary UI must be:

```text
Complete existing reservation
→ show reserved OUT row
→ show best DVA/card IN suggestion
→ staff clicks Pair IN and release
```

The page must not force the user to scroll through the new-reservation card workflow when the current task is already at the pairing/release stage.

---

## 4. Primary panel rule

In completion-loyalty mode, the top operational panel must prioritise existing reserved OUT rows.

Primary panel name:

```text
Complete existing reservation
```

It must show:

```text
- order reference;
- importer/customer name;
- reward amount;
- reserved main-bank OUT reference/date/amount;
- suggested DVA/card IN candidate;
- match quality label;
- reason for the suggestion;
- Pair IN and release action.
```

The lower/main-bank card reservation workspace may appear only where a new reward target is available or where staff explicitly opens a secondary/manual section.

---

## 5. Importer filtering rule

DVA/card IN candidates must default-filter by the importer on the reserved OUT row.

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

For each reserved OUT row, show a ranked suggestion card.

Minimum scoring bands:

```text
Exact
- same importer;
- remaining IN amount equals reserved reward amount;
- IN amount is sufficient;
- candidate is not already consumed.

Strong
- same importer;
- remaining IN amount is sufficient;
- date is close or reference strongly suggests top-up/order/importer link.

Review
- same importer;
- amount/date/reference are plausible but ambiguous;
- multiple candidates have similar score;
- amount is higher than the reward and may represent a bulk top-up.

No match
- no same-importer IN candidate with sufficient remaining amount.
```

The score is advisory only. It must not release credit automatically.

---

## 7. Bulk handling for 50+ orders

For a high-volume case, such as 50 qualifying orders and 50 OUT payments, the page must not require 50 manual searches across unrelated candidates.

Required high-volume layout:

```text
Ready to release queue

Summary:
- Exact matches
- Strong matches
- Review needed
- No IN found yet

Grouped by importer.
```

Bulk release may be added only for exact matches.

Bulk exact release constraints:

```text
- same importer;
- exact remaining amount match;
- one reserved OUT row maps to one DVA/card IN candidate;
- one DVA/card IN candidate maps to one reserved OUT row;
- no ambiguity;
- staff explicitly clicks bulk release;
- backend still calls staff_pair_loyalty_destination_in_and_release_v1 row-by-row or through a wrapper that preserves the same validations.
```

No automatic/background release is allowed.

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
- no same-importer candidate.
```

The staff user should be able to select a candidate manually only within the same importer by default.

The write action must still route through:

```text
staff_pair_loyalty_destination_in_and_release_v1(...)
```

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
- create-new-reservation workspace appears;
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

### D. 50 reserved OUT rows and 50 IN candidates

Expected:

```text
- rows grouped by importer;
- exact/strong/review/no-match counts shown;
- exact one-to-one matches can be bulk released only after staff confirmation;
- ambiguous rows remain manual review;
- no duplicate release or reused DVA/card IN line is possible.
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
- post to Sage from this suggestion UI;
- create VAT or customer invoice effects from this suggestion UI;
- change credit application to future orders.
```

---

## 12. Build consequence

The next UI build should be a safe presentation/read-model layer first:

```text
1. Read-only suggestion queue.
2. Single-row pair/release from suggestion card using existing RPC.
3. Exact-match bulk release only after the single-row behaviour is proven.
4. Manual-review controls only after exact/strong suggestion behaviour is proven.
```
