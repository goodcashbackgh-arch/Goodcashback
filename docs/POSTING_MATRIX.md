# Posting Matrix

## Summary

| Business Event | Internal Source | Sage Outcome | Notes |
|---|---|---|---|
| Customer funding confirmed | DVA reconciliation | AR receipt / prepayment | Created when funding becomes valid |
| Released subset billed | Sales invoice intent | AR invoice | Only released subset |
| Post-invoice refund approved | Credit note intent | AR credit note | Must exist before payout/reusable credit |
| Prepayment application | Prepayment application intent | Allocation step within ar_receipt + ar_invoice flow — not a posting_type | Can be partial |
| FX difference | Funding / settlement difference | fx_gl | dva_reconciliation.fx_diff_gbp |
| Shipper liability settlement | Shipper liability | Offset or settlement entry | Exact route to confirm |

---

## Day 2 — Funding Receipt (posting_type: ar_receipt)

| Dr | Cr |
|---|---|
| Bank / Cash | Importer AR / Prepayment Clearing (ar_nominal_code) |

Not revenue. Not sales. Prepayment only.

---

## Day 6 — Sales Invoice (posting_type: ar_invoice)

| Dr | Cr |
|---|---|
| Importer AR / Prepayment Clearing (ar_nominal_code) | Sales Exports (sales_exports_nominal_code) |

---

## Day 6 — FX Difference (posting_type: fx_gl)

| Dr/Cr | Nominal |
|---|---|
| +/- | FX Gain/Loss (fx_gain_loss_nominal_code) |

Source: dva_reconciliation.fx_diff_gbp

---

## Box 6 VAT Timing Rule

If consideration received in April, invoice raised in May:
- April Box 6 picks up amount via box6_carry_in adjustment
- May must NOT count same amount again if vat_box6_reported_period = April

Controlled via:
- sales_invoices.consideration_received_date
- sales_invoices.tax_point_period
- sales_invoices.sage_invoice_period
- sales_invoices.vat_box6_reported_period
- vat_return_adjustments (box6_carry_in / box6_carry_out)
- vat_return_workings.final_box6

Hard constraint: vat_return_adjustments.source_sales_invoice_id is mandatory.
Box 6 timing logic is anchored to the sales invoice row, not the receipt row.
Receipt happens first. Invoice row carries the reporting metadata.

---

## Allowed posting_type values

ar_invoice | ar_credit_note | ar_receipt | ap_invoice | ap_payment | fx_gl | vat_adjustment_box6 | vat_adjustment_box1