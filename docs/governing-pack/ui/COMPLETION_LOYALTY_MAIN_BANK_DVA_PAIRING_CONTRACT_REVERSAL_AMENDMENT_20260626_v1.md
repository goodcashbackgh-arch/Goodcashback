# Completion loyalty main-bank/DVA pairing contract reversal amendment 2026-06-26 v1

Status: Locked amendment to `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md`  
Related addendum: `COMPLETION_LOYALTY_RELEASE_REVERSAL_AND_CONFIRMATION_ADDENDUM_v1.md`

## Amendment summary

The original pairing contract remains valid. This amendment narrows and clarifies the reversal rule discovered during controlled testing of same-importer DVA/card IN selection.

The backend already blocks destination-IN lines from a different importer. The remaining risk is wrong same-importer IN selection, especially where a single reward is released against a much larger IN line that was intended for a grouped pot.

## Replacement rule for released-but-unapplied reversal

Section 19.4 of the original contract is amended as follows.

A released completion-loyalty reward may be reversed only if the released credit has not been applied to an order. When eligible, reversal must reset the reward to before funding selection, not merely before destination-IN selection.

The reset must:

1. keep the approved reward entitlement;
2. make the reward selectable again in the main-bank OUT reservation target list;
3. mark the old funding match as reversed for audit;
4. lock or otherwise remove the released credit ledger row from customer availability;
5. mark the funding confirmation as reversed/cancelled;
6. clear active links from the approval to the released credit/funding confirmation;
7. clear active links from the reversed funding match;
8. leave all unrelated DVA, main-bank, VAT, shipper AP, supplier AP, and Sage lanes untouched.

## Explicitly prohibited shortcut

Do not reverse only the DVA/card IN selection while leaving the reward reserved to the same main-bank OUT line.

Reason: a wrong IN selection can indicate a wrong grouping of rewards, OUT lines, and top-ups. Staff must repeat the full selection chain.

## UI confirmation amendment

Before release, the UI must show:

- selected reward order refs and amounts;
- selected main-bank OUT reference;
- selected DVA/card IN reference;
- destination IN remaining before release;
- selected loyalty amount;
- excess left after release;
- whether the selection is exact, sufficient, or high-risk.

Single-row high-excess releases must be visually warned before release. The warning must say the excess is unconsumed IN balance, not loyalty FX.

## No-impact boundary

This amendment does not authorise any change to:

- customer order creation;
- customer self-service credit application;
- staff apply-loyalty-to-order logic;
- `order_funding_events` semantics;
- VAT timing;
- customer sales invoice posting;
- applied-loyalty Sage batch materialisation;
- internal-transfer Sage posting;
- supplier/shipper/AP matching;
- residual allocation categories.

No Sage posting may be built as part of this amendment.
