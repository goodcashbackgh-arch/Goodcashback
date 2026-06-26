# Completion loyalty release reversal and confirmation addendum v1

Status: Locked MVP addendum  
Date: 2026-06-26  
Scope: Completion-loyalty main-bank OUT reservation, DVA/card IN release, reversal, and staff confirmation controls.

This addendum extends the completion-loyalty main-bank/DVA pairing contract and the sufficient-IN pot release addendum. It does not change the reward entitlement calculation, VAT return logic, customer sales posting, shipper AP, supplier AP, or Sage posting lanes.

## 1. Problem locked by this addendum

A staff user can select a valid same-importer DVA/card IN line that is not the intended IN line for the selected reward or reward pot.

The backend already prevents cross-importer release. The operational risk is therefore not importer leakage. The risk is wrong same-importer line selection.

Example risk pattern:

- selected reward amount: GBP 777.77;
- selected same-importer DVA/card IN remaining: GBP 4,444.44;
- unconsumed IN balance after release: GBP 3,666.67;
- credit is released, but the selected IN was likely intended for a different reward pot.

The correction must restore the item to a safe pre-selection state before any Sage posting or order application occurs.

## 2. Locked reversal principle

A reversal of a released but unapplied completion-loyalty funding release must reset the reward to before funding selection, not merely before destination-IN selection.

The reversed state must require staff to repeat the full chain:

1. select the reward card;
2. select the main-bank OUT line;
3. select the DVA/card or virtual-card IN line;
4. confirm release.

This is deliberate. A wrong IN selection can indicate a wrong mental grouping of rewards and top-ups. Repeating only the IN step is not sufficient control.

## 3. Reversal eligibility states

### 3.1 OUT reserved but not released

A staged OUT reservation that has not created a credit ledger entry may be undone by reversing the funding match. The reward entitlement remains available for new funding selection.

### 3.2 Released credit, not applied to an order

A released completion-loyalty credit may be reset only if all of the following are true:

- the loyalty funding match has `match_status = 'released_available_dashboard_credit'`;
- the loyalty funding match has `transfer_pair_status = 'paired_released'`;
- the match has a `credit_ledger_id`;
- the credit ledger row exists and is a completion-loyalty credit;
- there are no unlocked debit rows in `importer_credit_ledger` that consume that credit ledger lot;
- there are no `order_funding_events` linked to a debit created from that credit ledger lot;
- no Sage applied-loyalty posting has been created from that credit application.

If those conditions are met, the release is eligible for a reset-to-selection reversal.

### 3.3 Credit already applied to an order

If a completion-loyalty credit has been applied to an order, a simple reset is not allowed.

That case must be handled by a later correction/reversal lane that considers customer settlement, order funding events, Sage posting state, and customer-facing account balance.

## 4. Locked reset-to-selection write behaviour

For an eligible released but unapplied credit, the reset-to-selection reversal must:

1. mark or lock the released importer credit ledger credit so it is no longer available;
2. mark the funding confirmation as reversed/cancelled where the table supports a status update;
3. reset the approval to `approved_pending_funding`;
4. clear active approval links to credit/funding confirmation/release timestamps;
5. mark the old funding match as `reversed`;
6. clear active funding match links:
   - `destination_in_statement_line_id`,
   - `credit_ledger_id`,
   - `funding_confirmation_id`,
   - `variance_gbp`;
7. preserve the old funding match row as audit evidence;
8. append staff id, auth user id, timestamp, and reason to notes/audit fields;
9. leave the source main-bank OUT and destination DVA/card IN statement lines unallocated except for any unrelated existing allocations.

The old funding match must not be deleted. Reversal is an audit correction, not test cleanup.

## 5. Customer-facing balance boundary

After reset-to-selection reversal, the customer must not see the reversed completion-loyalty credit as available.

The reward may return to pending/selectable internal status, but it must not be customer-usable until staff repeats the funding selection and release process.

## 6. Single-row sufficient-IN excess rule

A single reward may be released against a same-importer IN line with sufficient remaining value only when the staff confirmation makes the excess explicit.

For a single-row release, excess is:

`destination_in_remaining_before_release - selected_reward_amount`

The excess is not loyalty FX. It is unconsumed DVA/card IN balance.

Single-row releases must not treat large excess as ordinary variance without staff warning. The UI must display the excess before release and must highlight high-risk excess.

Recommended high-risk thresholds for MVP:

- warning if excess exceeds GBP 5.00 or 2% of selected reward;
- high-risk confirmation if excess exceeds GBP 25.00 or 10% of selected reward.

The backend may continue to enforce importer, direction, account-context, and sufficient-balance gates. The UI must add the operator control so staff cannot release customer-available credit without seeing the selected IN line and excess.

## 7. Bulk-pot sufficient-IN rule remains valid

Bulk-pot sufficient-IN release remains allowed where:

- all selected rewards belong to one importer;
- all selected rewards use one source main-bank OUT line;
- the destination IN belongs to the same importer;
- the destination IN remaining balance is at least the selected reward pot total.

The selected loyalty pot amount is consumed. Any excess remains on the DVA/card IN statement line and is not loyalty FX.

The confirmation must show:

- reward count;
- selected reward total;
- source OUT reference and amount;
- destination IN reference and remaining amount;
- excess remaining after release;
- statement that no loyalty FX is posted by the release.

## 8. No-impact boundary

This addendum must not change:

- reward entitlement calculation;
- supervisor approval/rejection logic except where reset returns an approval to pending funding;
- order funding thresholds;
- customer sales invoice posting;
- VAT return workbench or VAT timing;
- supplier invoice or supplier payment reconciliation;
- shipper AP matching/posting;
- residual allocation categories;
- applied-loyalty Sage batch materialisation;
- future internal-transfer Sage posting design.

## 9. Build order locked by this addendum

1. Add read-only reversal eligibility view/RPC.
2. Add reset-to-selection reversal RPC for eligible, unapplied releases only.
3. Add internal reversal page for staff review and reversal action.
4. Add release confirmation UI for single and bulk releases.
5. Add single-row high-excess warning/high-risk confirmation.
6. Do not build Sage posting until reversal and confirmation controls are live and tested.
