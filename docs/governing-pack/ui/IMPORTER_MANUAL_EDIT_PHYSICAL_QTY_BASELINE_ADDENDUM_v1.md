# Importer Manual Edit Physical Quantity Baseline Addendum v1

## Status

Scope-frozen corrective build contract.

## Proven defect

On importer supplier-invoice reconciliation, `enforceManualEditWithinBaseline()` currently sums `qty` from every live supplier-invoice row. OCR delivery and discount rows can carry source `qty = 1`, so non-physical rows incorrectly consume the order's physical quantity baseline.

Controlled order: `ORD-1785414534454`.

Declared baseline:
- quantity: 4
- value: £894.46

Current OCR bundle:
- 4 physical goods rows
- 2 discount rows
- 3 delivery rows
- all 9 OCR rows currently carry `qty = 1`
- raw signed row values already net exactly to £894.46

Therefore the current manual-edit guard falsely sees quantity 9 against baseline 4 while the amount test is valid.

## DB-confirmed working exception path

The current reconciliation-stage manual exception flow is a working path that must remain unchanged:

- unresolved physical lines with `eligible_for_invoice_yn = N` can be selected directly for Refund or Replacement;
- manually added physical lines participate in the same unresolved -> exception path;
- manually added historical examples exist for both refund and replacement outcomes;
- a line does not need to be progressed first to enter this manual exception path;
- current order `ORD-1785414534454` has no active dispute or active non-physical resolution on its unresolved goods/delivery/discount rows before this fix.

This build must not reinterpret or modify exception ownership, exception eligibility, refund/replacement lifecycle, manual line creation, or progression state.

## Exact fix boundary

Patch only `enforceManualEditWithinBaseline()` and directly local helper code required by that function in:

`app/importer/reconciliation/[order_id]/actions.ts`

No other production file or database object is authorised to change.

## Quantity rule

For the manual-edit baseline guard only:

1. Physical goods rows retain their existing quantity.
2. Active `non_physical_financial` resolutions contribute zero physical quantity.
3. A provisionally classified unresolved financial row contributes zero physical quantity only when ALL of the following are true:
   - `line_source = 'ocr_extracted'`;
   - the row is not linked to an unresolved `dispute_lines` membership (`dispute_lines.resolved_at IS NULL`), mirroring the existing application boundary without redefining dispute lifecycle;
   - discount requires a negative source amount and existing discount vocabulary;
   - delivery requires a positive source amount and existing delivery vocabulary;
   - the aggregate extracted amount for that invoice/type must agree with the existing `order_value_adjustments` fact within £0.01;
   - rejected adjustment facts are excluded;
   - description alone must never create zero-quantity treatment.
4. `manually_added` rows are never eligible for provisional financial zero-quantity treatment. Unless an existing active `non_physical_financial` resolution already classifies them, they retain their physical quantity and therefore remain available to the existing unresolved -> Refund/Replacement exception path.
5. Anything ambiguous remains counted and therefore fails closed.
6. The edited line uses the same classification rule before applying `nextQty`.

Existing vocabulary only:
- delivery: `delivery|shipping|postage|freight|carriage`
- discount: `discount|promotion|promotional|promo|voucher|coupon|saving|savings`

## Exception ownership boundary

The manual-edit guard may only READ unresolved `dispute_lines` membership to prevent an exception-owned row from being used as provisional financial proof.

It must NOT:
- create, resolve, close or mutate a dispute;
- infer that parent `disputes.resolved_at` changes the existing line-level application lock;
- unlock historical refunded/replaced lines;
- alter `exceptionEligible`, checkbox selection, Refund/Replacement choices, or `createExceptionCaseAction()`;
- alter existing exception/accounted quantity or value read models.

The build therefore mirrors the existing `dispute_lines.resolved_at IS NULL` boundary conservatively and does not redefine exception semantics.

## Amount rule frozen

Do not change the manual-edit amount calculation in this build.

The controlled order already proves the raw signed OCR row values total exactly £894.46. The existing `order_total_gbp_declared + £0.01` amount ceiling remains unchanged.

## Explicitly untouched

No change to:
- `enforceProgressionWithinBaseline()`;
- manual add guard or manual line creation;
- page/read-model selection capacity;
- `exceptionEligible` calculation or exception checkbox list;
- `createExceptionCaseAction()`;
- Refund/Replacement choice or dispute lifecycle;
- progression RPCs;
- exception/dispute mutation logic;
- Park/non-physical resolution RPCs;
- order baselines;
- supplier invoice approval/rejection;
- tracking/shipment;
- customer sales/release;
- funding, DVA, settlement, credit;
- Sage/accounting/VAT;
- permissions, navigation, wording or styling;
- historical business data;
- database schema/functions/views/triggers.

No migration is authorised.

## Required regression

Regression must prove:

1. controlled 9-row bundle resolves to physical quantity 4;
2. its raw signed amount remains £894.46 and amount logic is unchanged;
3. the five proved financial OCR rows contribute zero quantity only because they are `ocr_extracted`, have correct sign/vocabulary, are not exception-owned, and their extracted totals match existing invoice adjustment facts;
4. a `manually_added` delivery/discount-looking line is NOT provisionally zeroed and retains physical quantity;
5. a description-only financial-looking OCR row without matching adjustment evidence still counts quantity;
6. an unresolved exception-linked row is excluded from provisional financial proof and cannot create quantity capacity;
7. a genuine physical edit taking physical quantity from 4 to 5 is still blocked;
8. retired invoice rows remain excluded exactly as before;
9. manual add, progression, exception/refund/replacement and downstream routes are not modified.

## Scope freeze

Any change outside the one manual-edit quantity projection and its dedicated regression requires a separate diagnosis and explicit approval.
