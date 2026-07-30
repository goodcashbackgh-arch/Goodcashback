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

## Exact fix boundary

Patch only `enforceManualEditWithinBaseline()` and directly local helper code required by that function in:

`app/importer/reconciliation/[order_id]/actions.ts`

No other production file or database object is authorised to change.

## Quantity rule

For the manual-edit baseline guard only:

1. Physical goods rows retain their existing quantity.
2. Active `non_physical_financial` resolutions contribute zero physical quantity.
3. An unresolved OCR row contributes zero physical quantity only when it is proved as delivery or discount using the already-governed signed-baseline evidence rule:
   - discount requires a negative source amount and existing discount vocabulary;
   - delivery requires a positive source amount and existing delivery vocabulary;
   - the aggregate extracted amount for that invoice/type must agree with the existing `order_value_adjustments` fact within £0.01;
   - rejected adjustment facts are excluded;
   - description alone must never create zero-quantity treatment.
4. Anything ambiguous remains counted and therefore fails closed.
5. The edited line uses the same classification rule before applying `nextQty`.

Existing vocabulary only:
- delivery: `delivery|shipping|postage|freight|carriage`
- discount: `discount|promotion|promotional|promo|voucher|coupon|saving|savings`

## Amount rule frozen

Do not change the manual-edit amount calculation in this build.

The controlled order already proves the raw signed OCR row values total exactly £894.46. The existing `order_total_gbp_declared + £0.01` amount ceiling remains unchanged.

## Explicitly untouched

No change to:
- `enforceProgressionWithinBaseline()`;
- manual add guard;
- page/read-model selection capacity;
- progression RPCs;
- exception/dispute logic;
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
3. the five proved financial OCR rows contribute zero quantity only because their extracted totals match existing invoice adjustment facts;
4. a description-only financial-looking row without matching adjustment evidence still counts quantity;
5. a genuine physical edit taking physical quantity from 4 to 5 is still blocked;
6. retired invoice rows remain excluded exactly as before;
7. manual add, progression, exception and downstream routes are not modified.

## Scope freeze

Any change outside the one manual-edit quantity projection and its dedicated regression requires a separate diagnosis and explicit approval.