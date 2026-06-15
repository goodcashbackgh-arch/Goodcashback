# VAT Return Workbench Partial Prepayment Addendum v1

## 0. Contract status

This addendum supplements `VAT_RETURN_WORKBENCH_AND_SAGE_JOURNAL_CONTRACT_v1.md` for Box 6 timing where an order has part-payment before the Sage sales-invoice VAT period and the remaining balance is paid in the same period as the later Sage sales invoice.

This addendum is narrow. It does not replace the main VAT Return Workbench contract. It locks the amount basis for partial prepayment and anti-duplicate reversal source lines.

If this addendum conflicts with older timing notes, UI notes, SQL harnesses, or draft generator assumptions, this addendum controls for partial-prepayment Box 6 timing.

---

## 1. Problem being controlled

The main VAT workbench contract already requires:

- prepayment-first Box 6 timing;
- Box 6 anti-duplicate reversal when a later Sage sales invoice naturally includes the same value;
- source-linked VAT return lines;
- reuse of `order_funding_events`, `dva_reconciliation`, and `sales_invoices`.

The gap is the amount basis where the later Sage sales invoice is greater than the amount paid before the invoice VAT period.

Example:

```text
Order final sales invoice in February: £250
Payment received in January: £200
Balance payment received in February: £50
```

Correct VAT Box 6 result:

```text
January Box 6 increase: £200
February Sage natural invoice value: £250
February Box 6 anti-duplicate decrease: £200
Net February Box 6 effect for the order: £50
Total Box 6 across periods: £250
```

The platform must not pull the full £250 into January merely because the final invoice is £250. Only the amount actually received before the invoice VAT period may be pulled forward.

---

## 2. Source linkage rule

The controlled linkage path is order-level:

```text
DVA/card statement line
-> dva_reconciliation.order_id
-> order_funding_events.order_id
-> sales_invoices.order_id
-> vat_return_run_lines
-> Sage VAT journal
```

No direct payment-to-sales-invoice foreign key is required for this phase.

The platform must use `order_id` plus funding event date/period to determine how much of a later invoice value had already created a Box 6 timing obligation before the invoice VAT period.

---

## 3. Funding events included in Box 6 timing

Include as consideration funding:

```text
order_funding_events.event_type IN (
  'funding_contribution',
  'credit_applied'
)
```

Subtract from consideration funding:

```text
order_funding_events.event_type = 'funding_reversed'
```

Exclude by default:

```text
order_funding_events.event_type IN (
  'overfunding_credit_created',
  'manual_adjustment'
)
```

`manual_adjustment` may only be included if a later explicit contract/update classifies a specific adjustment subtype as customer consideration for a specific order/supply.

Wallet/general overfunding is not Box 6 until applied to a specific order/supply through an included funding event.

---

## 4. Amount basis rule

For each sales invoice being assessed for Box 6 timing:

```text
invoice_period_start = first day of sales_invoices.sage_invoice_period
```

or, where `sage_invoice_period` is unavailable, the first day of the month containing `sales_invoices.sage_invoice_date`.

Calculate:

```text
pre_invoice_period_funding_gbp =
  sum(included funding_contribution and credit_applied amounts for the same order_id
      where order_funding_events.created_at::date < invoice_period_start)
  minus
  sum(funding_reversed amounts for the same order_id
      where order_funding_events.created_at::date < invoice_period_start)
```

Then cap the amount:

```text
box6_prepaid_amount_for_invoice =
  least(
    greatest(pre_invoice_period_funding_gbp, 0),
    abs(sales_invoices.amount_gbp)
  )
```

The Box 6 timing engine must use `box6_prepaid_amount_for_invoice`, not the full sales invoice amount, for:

- `box6_prepayment_increase`;
- `box6_anti_duplicate_decrease`.

---

## 5. Same-period balance payment rule

Payments received in the same VAT period as the Sage sales invoice must not be separately accrued where the Sage sales invoice naturally covers the correct final sales value.

In the example:

```text
January payment before invoice period: £200 -> pulled into January Box 6
February payment inside invoice period: £50 -> not pulled forward
February Sage invoice: £250 -> naturally included by Sage
February anti-duplicate decrease: £200
February net Box 6: £50
```

This prevents the February £50 from being double-counted or incorrectly accrued early.

---

## 6. Anti-duplicate reversal rule

When the later Sage sales invoice appears, the Box 6 decrease must equal only the amount previously pulled forward from pre-invoice-period funding.

It must not automatically equal the full later Sage invoice value.

Formula:

```text
box6_anti_duplicate_decrease_amount =
  min(previously_reported_pre_invoice_funding_for_order_or_invoice, abs(sales_invoices.amount_gbp))
```

Where a prior VAT return lock/evidence table is available, use the actually reported source-line amount. Where the run is being generated before lock history exists, calculate from `order_funding_events` using the amount basis rule above.

---

## 7. Required source-line evidence

Every generated VAT timing line must store enough `source_json` / `source_lineage_json` to explain:

- `order_id`;
- `sales_invoice_id`;
- `invoice_amount_gbp`;
- `invoice_period_start`;
- funding event IDs used;
- included funding total;
- reversed funding total;
- capped Box 6 timing amount;
- excluded same-period funding amount, if any;
- reason code.

Required reason codes:

```text
box6_partial_prepayment_increase_from_order_funding_events
box6_partial_prepayment_anti_duplicate_decrease
```

Existing reason codes for full-prepayment cases may remain valid where the funded amount equals the invoice amount, but the source line should still show the funding-event calculation.

---

## 8. Blockers

Block VAT return approval if any of the following are true:

1. A payment-before-invoice Box 6 line is required but has no linked `order_funding_events` evidence.
2. The Box 6 prepayment amount exceeds confirmed pre-invoice-period funding for the same `order_id`.
3. The Box 6 anti-duplicate decrease exceeds the amount previously pulled forward.
4. Funding events used for Box 6 timing include `overfunding_credit_created` or unclassified `manual_adjustment`.
5. A later Sage invoice exists for an order with prior pre-invoice funding but no anti-duplicate decrease/source-line explanation.

---

## 9. Proof scenario required before the build is considered complete

The build must pass a rollback-only proof using real VAT source-pack functions:

```text
Order A:
  Payment 1: £200 in January
  Final Sage sales invoice: £250 in February
  Payment 2 / balance: £50 in February

Expected:
  January Box 6 prepayment increase = £200
  February Sage natural Box 6 = £250
  February Box 6 anti-duplicate decrease = £200
  February net Box 6 effect = £50
  Total Box 6 across January and February = £250
```

The proof must also confirm the February £50 payment is not pulled into January because it is not before the February invoice period.

---

## 10. Build boundary

The simplest permitted patch is to amend the existing VAT timing source-line function so that Box 6 timing amounts are calculated from `order_funding_events` by `order_id` and funding date, capped at the sales invoice amount.

Do not introduce a direct payment-to-sales-invoice allocation table unless the order-level calculation is proven insufficient.

Do not add a manual `box6_prepaid_amount_gbp` column to `sales_invoices` for this phase.

Do not change Sage posting adapters, UI routes, DVA/card reconciliation workflow, importer/operator workflow, or shipment/export-evidence workflow for this patch.

The intended downstream impact is limited to VAT source-line generation and Sage VAT adjustment proposal evidence for Box 6 timing.
