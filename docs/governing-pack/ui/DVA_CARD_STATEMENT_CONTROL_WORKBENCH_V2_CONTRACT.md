# DVA/Card Statement Control Workbench v2 Contract

Status: draft governance contract. Do not add write buttons, SQL wrappers, allocation tables, Sage payload posting, or schema changes from this document until explicitly approved and tested. Updated on 2026-06-08 to clarify final-balance target card behaviour, final-balance residual handling, and confirmed-partial visual state rules.

## Purpose

The DVA/card statement control workbench is the staff/supervisor financial-control layer for money spent or refunded through card, bank, or DVA statement lines.

It must not duplicate operator invoice reconciliation. It consumes the operational truth already created by order operations, OCR, supplier invoice lines, progressed lines, exception cases, supervisor approvals, and final sale settlement read models.

## Relationship to the existing funding build

The existing funding build is not wasted. It remains the accepted-estimate funding and credit spine.

Reuse from the funding build:

- staff-only internal access pattern;
- server action pattern;
- active staff/admin/supervisor validation;
- SECURITY DEFINER RPC principle for all staff financial writes;
- `dva_statements` and `dva_statement_lines` as the statement header/line store;
- `dva_reconciliation` as the high-level statement-line reconciliation record where the existing constraint allows it;
- `match_suggestions` as the suggestion scaffold;
- `order_funding_position_vw` for accepted-estimate funding context;
- `importer_balance_vw` for available credit context;
- `importer_credit_ledger` for approved credit/debit movements;
- `/internal/funding` as the Day 2 money-in/order-funding page.

Do not reuse the order-funding RPC for supplier purchase, refund matching, or final-balance settlement.

`staff_reconcile_dva_line_to_order(...)` is order-funding only. It reconciles inbound DVA/card funding lines to original orders and handles order funding gap/overfunding logic. It must not be stretched to supplier purchases, retailer refunds, exception settlement, replacement charge matching, or final-balance settlement after the accepted estimate is already covered.

## Page boundary

### `/internal/funding`

Purpose:

```text
Money received from importer -> fund accepted estimate for the order.
```

Shows:

- inbound DVA/card funding lines;
- order funding gaps;
- funded totals;
- importer credit balances;
- overfunding;
- funding events audit trail.

Permitted action family:

- apply importer credit to order;
- reconcile inbound DVA/card line to original order for accepted-estimate funding;
- handle explicit accepted-estimate overfunding.

### `/internal/dva-reconciliation`

Purpose:

```text
Money spent/refunded/settled on card/bank/DVA statement -> match to invoices, refunds, exceptions, final-balance payments, FX/card differences, and Sage control payload.
```

Shows:

- local currency statement lines;
- daily FX and card markup context;
- GBP equivalent;
- suggested retailer/order/invoice/dispute/final-balance linkage;
- supplier invoices and OCR/header totals;
- progressed invoice-line totals;
- open paper/commercial exception amounts;
- refund/replacement status;
- final balance payment targets where final sale value exists and balance due is open;
- FX/card difference;
- true unallocated balance;
- links to order, invoice, reconciliation, exception, credit ledger, and funding page.

Future action family, only after dedicated RPCs and tests:

- allocate one statement line to one supplier invoice;
- allocate one statement line to multiple supplier invoices;
- allocate one IN statement line to an order final-balance payment target;
- match retailer refund line to a dispute/exception;
- mark exception as not charged / close no refund due;
- hold/query operator;
- mark replacement as free;
- match charged replacement to replacement child order;
- handle refund plus repurchase;
- create/unlock importer credit after approved refund or approved true final-sale surplus;
- prepare Sage reconciliation payload for supplier clearing, final-balance settlement evidence, and FX/card difference posting.

## No duplication principle

The workbench must not ask staff to redo operator/importer reconciliation.

Operator/importer reconciles commercial truth once:

```text
order screenshots -> supplier invoice/OCR lines -> progressed lines -> exceptions -> sale documents/final sale value
```

Staff/supervisor reconciles financial truth once:

```text
statement line -> invoice/refund/exception/final balance/FX difference
```

The DVA/card statement page must consume and link to the existing work. It must not require:

- re-entering supplier invoice lines;
- re-checking order screenshots line by line;
- rebuilding exception cases;
- duplicating supplier invoice approval;
- performing a second order/invoice reconciliation;
- recalculating final sale value outside the final sale settlement read model.

Staff should only answer:

```text
Does the money movement match the already-approved operational/final-sale truth?
```

## Statement upload and extraction

Staff/supervisor owns statement upload. Importer/operator does not upload or reconcile DVA/card/bank statements.

Recommended location:

```text
/internal/funding/statements/upload
```

or equivalent staff-only statement upload route linked from the internal funding/control area.

Storage model:

- `dva_statements` stores one row per uploaded statement file/header;
- `dva_statement_lines` stores one row per extracted statement line;
- statement file evidence should remain linked to the statement header;
- extracted lines must preserve the raw reference, auth/reference fields, statement date, local amount, local currency, FX inputs, card markup input, and calculated GBP equivalent.

CSV/native bank export is preferred where available. OCR is fallback for scanned/PDF statements, but the resulting extracted lines still land in `dva_statement_lines`.

## Daily FX and card markup logic

Use daily FX rates where available because local currencies can be volatile.

FX source should be country/currency specific, for example Bank of Ghana mid-rate for GHS. The FX source, rate date, and rate used must be auditable.

For each statement line, the system should support:

- statement date;
- local currency;
- local amount;
- official daily mid-rate source;
- official daily mid-rate;
- configurable card/provider markup percentage;
- calculated GBP control amount;
- actual card/bank GBP amount if supplied by the card provider;
- FX/card difference.

If a provider/card markup is included in a converted card amount, remove the markup by division, not multiplication.

Example:

```text
Card converted charge including 10% markup = £110
Underlying supplier/invoice amount = £110 / 1.10 = £100
```

Do not calculate `0.9 x £110`; that gives £99 and is wrong for removing a 10% markup from a grossed-up amount.

If the system starts from local currency and official FX, then adds estimated provider markup:

```text
estimated card GBP = official_mid_rate_converted_gbp x (1 + card_markup_pct)
```

If the system starts from actual card GBP charge and needs to estimate the underlying invoice clearing value:

```text
estimated invoice clearing GBP = actual_card_gbp / (1 + card_markup_pct)
```

The contract must preserve both values where possible:

- invoice clearing amount;
- FX/card/provider difference amount.

## One statement line to multiple invoices or targets

A real card/bank statement line may cover more than one target.

Supplier purchase example:

```text
Statement line: Zara charge £100
Supplier invoice A: £60
Supplier invoice B: £40
```

Final-balance example:

```text
Statement line: Customer payment £39.74
Open final balance: £39.62
Final-balance allocation: £39.62
FX/card difference after balance closure: £0.12
```

The workbench must allow allocation of one statement line across multiple targets without duplicating the statement line.

The current live `dva_reconciliation.dva_statement_line_id` unique constraint means the baseline table has a one-statement-line-to-one-reconciliation model. Therefore, multi-target matching requires the approved allocation layer:

```text
dva_statement_line_allocations
```

Allocation layer purpose:

- one row per allocation from a statement line to a supplier invoice, dispute, fee/FX/card difference, hold bucket, or final-balance payment;
- preserve the single real statement line;
- allow multiple allocations under one statement line;
- calculate remaining allocation balance;
- feed control reporting and later Sage payload preparation.

Do not bypass this allocation layer for new multi-target DVA/card matching.

## Allocation logic

### Supplier purchases

For supplier purchases:

```text
statement GBP amount
minus allocated supplier invoice GBP amounts
minus approved FX/card/provider difference
= true unallocated balance
```

A remaining supplier-purchase difference must not automatically be applied to the next invoice.

First classify the difference:

1. FX/card/provider charge or gain/loss;
2. true supplier overpayment/prepayment;
3. unmatched amount requiring investigation;
4. refund/credit relationship;
5. data/extraction error.

Only a true supplier overpayment/prepayment may be carried to another invoice after supervisor confirmation.

### Final balance payments

For final-balance payments, the rule is different from supplier purchases.

Converted GBP on an IN statement line must reduce the open final balance first.

Do not create FX/card difference while the final balance is still open.

Only after the final balance reaches zero may excess remaining on that selected statement line be classified as FX/card difference, bank fee, unmatched hold, or another explicitly approved residual.

Calculation:

```text
statement_remaining_gbp = unallocated GBP remaining on the selected statement line
balance_due_gbp = current final sale balance still due
amount_to_final_balance_gbp = min(statement_remaining_gbp, balance_due_gbp)
fx_card_excess_gbp = max(statement_remaining_gbp - balance_due_gbp, 0)
balance_after_allocation_gbp = max(balance_due_gbp - statement_remaining_gbp, 0)
```

If `balance_after_allocation_gbp > 0`, the whole selected line amount goes to `final_balance_payment` and no FX/card difference is created for that line.

If `balance_after_allocation_gbp = 0` and `fx_card_excess_gbp > 0`, allocate the balance due to `final_balance_payment` and classify only the excess as `fx_card_difference`, `bank_fee`, or `unmatched_hold`, depending on staff/supervisor confirmation.

## Final-balance target cards

Final-balance payment must appear as a target card in the existing right-side target list of `/internal/dva-reconciliation`.

Do not create a separate final-balance workbench.

The card label must be:

```text
Final balance payment · ORD-xxxx
```

The card must show:

```text
Order ref
Importer/customer
Authorisation ref where available
Final sale value
Amount received so far
Current final balance due
Selected statement line remaining, when a line is selected
Amount that will apply to final balance
Balance after this allocation
FX/card excess, only where the selected line exceeds the current balance due
```

The card must not use:

```text
Overfunding
Extra funding
Customer credit
Supplementary invoice payment
Recharge
Service fee
Agency fee
```

### Card scenarios

Partial payment:

```text
Final balance due: £100.00
Selected statement line: £60.38 IN
Apply to final balance: £60.38
Balance after this payment: £39.62
FX/card difference now: £0.00
```

Expected action result:

```text
£60.38 allocated to final_balance_payment
Statement line becomes balanced / green
Final balance card remains open at £39.62
No FX/card difference
No importer credit
No overfunding
```

Final payment with excess:

```text
Final balance due: £39.62
Selected statement line: £39.74 IN
Apply to final balance: £39.62
Balance after this payment: £0.00
FX/card difference: £0.12
```

Expected action result:

```text
£39.62 allocated to final_balance_payment
£0.12 allocated to fx_card_difference, or held as unmatched_hold if staff is not ready to classify it
Statement line becomes balanced / green if the residual is classified
Final balance card closes or disappears from open targets
No importer credit
No overfunding
```

Exact payment:

```text
Final balance due: £39.62
Selected statement line: £39.62 IN
```

Expected action result:

```text
£39.62 allocated to final_balance_payment
Statement line becomes balanced / green
Final balance due becomes £0.00
No FX/card difference
No importer credit
No overfunding
```

## Statement-line visual states

Statement-line colour and filter state must reflect confirmed allocation progress, not only open/draft allocation rows.

Correct visual-state rule:

```text
Selected = sky
Balanced = confirmed_balanced_yn = true
Part allocated = confirmed_allocated_gbp > 0 and confirmed_balanced_yn = false
Open/draft pending = open_allocated_gbp > 0, shown as a secondary badge
Unmatched = confirmed_allocated_gbp = 0 and open_allocated_gbp = 0 and confirmed_balanced_yn = false
```

The current flaw is that a confirmed partially allocated line can appear white/unmatched if there is no open/draft allocation.

Example:

```text
Statement line: £120.00
Confirmed allocated: £100.00
Open/draft allocation: £0.00
Remaining: £20.00
Confirmed balanced: false
```

Correct display:

```text
Part allocated / amber
Remaining £20.00
```

Incorrect display:

```text
Unmatched / white
```

This is a UI classification correction only. It must not change accounting data.

## Direction guards

Final-balance payment allocation is only permitted for IN statement lines.

OUT statement lines must not be selectable for final-balance payment.

Server-side RPC validation must enforce this even if the browser is bypassed.

Supplier invoice allocations normally use OUT lines.

Retailer refund/credit allocations normally use IN lines.

FX/card and bank-fee allocation direction depends on the source line and target context and must be validated by the dedicated RPC.

## Exception examples

### Retailer charged less than order baseline

```text
Order baseline: £120
Supplier invoice: £100
Open exception: £20
Statement outflow: £100
```

Conclusion:

```text
Retailer did not charge £20 -> close exception as not charged / no refund due.
```

### Retailer charged full amount and refunded later

```text
Statement outflow: £120
Supplier invoice/progressed or exception context shows £20 issue
Later statement inflow/refund: £20
```

Conclusion:

```text
Match refund line to dispute -> create/unlock importer credit after supervisor approval -> close exception as refunded.
```

### Retailer charged full amount and no refund yet

```text
Statement outflow: £120
Open exception: £20
No refund line found
```

Conclusion:

```text
Supervisor may approve refund pursuit -> operator chases retailer -> exception remains open.
```

### Replacement child order

Replacement charge treatment depends on retailer behaviour:

- free replacement: no new card charge required;
- charged replacement: match charge line to replacement child order/invoice context;
- refund plus repurchase: match refund line to parent exception and new charge line to child purchase.

Do not assume all replacement children require fresh funding or fresh charge.

## Sage readiness and payload principle

The DVA/card statement control workbench does not post directly to Sage.

It prepares a controlled reconciliation payload only when:

- statement line extraction is complete;
- FX source/rate/markup is present or explicitly overridden;
- supplier invoice/header/OCR/progressed-line context is linked where relevant;
- final-balance target context is linked where relevant;
- allocation total is balanced or variance is classified;
- open exceptions are matched, held, or deliberately unresolved;
- FX/card/provider difference is calculated and classified;
- supervisor approval has been recorded.

Example payload shape:

```json
{
  "statement_line_id": "uuid",
  "retailer": "ZARA",
  "statement_date": "2026-05-02",
  "local_ccy": "GHS",
  "amount_local": 1650.00,
  "official_fx_source": "Bank of Ghana",
  "official_fx_date": "2026-05-02",
  "official_mid_rate": 15.00,
  "card_markup_pct": 10.00,
  "statement_gbp_equivalent": 110.00,
  "invoice_allocations": [
    {
      "supplier_invoice_id": "invoice-a",
      "invoice_ref": "ZARA-001",
      "allocated_gbp": 60.00
    },
    {
      "supplier_invoice_id": "invoice-b",
      "invoice_ref": "ZARA-002",
      "allocated_gbp": 40.00
    }
  ],
  "fx_or_card_diff_gbp": 10.00,
  "unallocated_balance_gbp": 0.00,
  "sage_posting": {
    "clear_supplier_invoices_gbp": 100.00,
    "post_fx_loss_or_card_charge_gbp": 10.00
  }
}
```

Final-balance settlement payloads must remain customer-sale settlement evidence and must not be posted as supplier clearing. Any later Sage treatment must be governed by the Sage posting matrix and VAT return contracts.

Sage posting later must be queue-driven, idempotent, and mapped through the Sage posting matrix. FX/card difference should post to the approved FX gain/loss or card charge nominal, not silently become invoice allocation.

## Required future RPC/action families

Do not expose these actions until live schema and governing pack checks are complete and dedicated SECURITY DEFINER RPCs exist:

- `staff_allocate_statement_line_to_supplier_invoice(...)`;
- `staff_allocate_statement_line_to_final_balance_payment_v1(...)`;
- `staff_match_statement_refund_to_dispute(...)`;
- `staff_mark_exception_not_charged(...)`;
- `staff_hold_statement_line_for_query(...)`;
- `staff_classify_statement_line_fx_card_difference(...)`;
- `staff_prepare_statement_line_sage_payload(...)`.

Names are illustrative unless explicitly created in a migration.

Each future RPC must:

- derive staff identity from `auth.uid()`;
- require active admin/supervisor role unless the relevant matrix says otherwise;
- validate importer/order/retailer consistency;
- validate statement-line direction and amount rules;
- validate no duplicate/over-allocation;
- preserve the original statement line;
- create auditable allocation/reconciliation records;
- return a clear JSON payload for UI confirmation.

Final-balance RPCs must not call `staff_reconcile_dva_line_to_order(...)` and must not create overfunding or importer credit automatically.

## Build order

1. Keep existing `/internal/funding` order-funding actions as-is.
2. Use the DVA/card workbench as read-only visibility first.
3. Add source links back to order, supplier invoice, invoice reconciliation, exception, credit ledger, final-sale settlement, and funding page.
4. Inspect live schema for allocation support.
5. If missing, propose an additive allocation layer or additive constraint change; do not alter existing constraints casually.
6. Add one staff-only RPC at a time.
7. Test one exact statement line/invoice/dispute/final-balance scenario at a time.
8. Only then prepare Sage payload generation.

## Non-negotiable controls

- No direct browser writes to DVA/card reconciliation, allocations, disputes, supplier invoices, importer credit ledger, final-balance settlement records, or Sage queues.
- No write action without a dedicated staff/supervisor SECURITY DEFINER RPC.
- No duplication of operator invoice reconciliation work.
- No stretching `staff_reconcile_dva_line_to_order` beyond accepted-estimate order funding.
- No treating FX/card difference as invoice allocation.
- No creating FX/card difference from a final-balance IN payment while final balance remains open.
- No applying unclassified balance to another invoice or target.
- No creating importer credit or overfunding credit from final-balance payment variance.
- No Sage posting until reconciliation payload is balanced, classified, approved, and queued.
- No schema changes without explicit approval.
