# VAT Return Workbench and Sage Journal Contract v1

## 0. Contract status

This is the controlling contract for the VAT Return Workbench, VAT return calculation, Sage VAT adjustment journals, export evidence breach handling, Sage VAT-return matching, and admin-only VAT return controls.

Where this contract conflicts with older UI wiring notes, posting matrix notes, VAT timing notes, Sage command-centre notes, or role-matrix wording, this contract controls for the VAT Return Workbench until those older documents are separately harmonised.

Future VAT workbench build chats must check this file first.

---

## 1. Scope

This contract covers:

- `/internal/accounting-vat` and child pages;
- VAT return period selection and calculation;
- source-line VAT pack generation;
- Box 1, Box 4, Box 6 and Box 7 rules for the Goodcashback export model;
- prepayment-first Box 6 timing;
- Box 6 anti-duplicate reversal when Sage sales invoices are later posted;
- export evidence deadline and Box 1 breach/reinstatement rules;
- supplier/retailer refund and credit-note VAT handling;
- shipper AP VAT treatment;
- Sage `/journals` adjustment posting using `include_on_tax_return`;
- VAT return evidence capture, Sage submitted box matching, and final lock.

This contract does not make the platform the MTD submission tool. Sage remains the submission tool unless a later verified MTD integration contract replaces that approach.

---

## 2. Actor and access rule

Live VAT return controls are **admin only**.

Allowed:

- `staff.role_type = 'admin'`.

Not allowed:

- supervisor;
- finance supervisor;
- operator/importer;
- shipper;
- test override flags such as `accounting_admin_testing` or `admin_testing` for live VAT return approval, Sage VAT journal posting, Sage return evidence, or VAT return lock.

Supervisors may see high-level operational VAT readiness indicators elsewhere, but they must not generate, approve, post, submit evidence for, reopen, or lock VAT returns.

---

## 3. Core architecture

The platform is the VAT calculation/control engine. Sage is the accounting ledger and MTD submission system.

The VAT workbench flow is:

1. Admin selects VAT return period.
2. Platform generates the VAT return pack from controlled platform facts.
3. Platform calculates the statutory VAT position.
4. Platform calculates Sage natural VAT coverage from posted Sage objects.
5. Platform calculates required Sage VAT adjustment journals.
6. Admin reviews blockers and journals.
7. Admin approves journals.
8. Platform posts approved journals to Sage via `/journals`.
9. Admin opens Sage, reviews the VAT return and submits via Sage MTD.
10. Admin records Sage submitted box values/reference/evidence back in the platform.
11. Platform matches Sage submitted values to the locked platform pack.
12. Return is locked.

Key formula:

```text
Required Sage adjustment = Platform statutory VAT position - Sage natural VAT position
```

Do not journalise everything. Journal only the gap.

---

## 4. Pages and UX

### 4.1 VAT dashboard

Route:

```text
/internal/accounting-vat
```

Purpose: command overview, not line-by-line working.

Cards:

- current VAT period due;
- last return status;
- prior return matched/locked status;
- open blockers;
- draft Box 1 / Box 4 / Box 6 / Box 7;
- Sage adjustment journals pending;
- export evidence breaches approaching;
- return history.

Primary actions:

- Generate VAT Return Pack;
- Open Current Draft;
- View Prior Return;
- View Blockers.

No Sage posting button should be exposed on the dashboard until the detailed return pack is clean and approved.

### 4.2 VAT return pack detail

Route:

```text
/internal/accounting-vat/returns/[return_run_id]
```

Tabs:

1. Summary.
2. Source Lines.
3. Box 6 Timing.
4. Export Evidence / Box 1.
5. Box 4 / Box 7 Purchases.
6. Sage Adjustment Journals.
7. Submission Evidence.

The page must make the workflow visually simple:

```text
Generate -> Review -> Approve journals -> Post journals -> Submit in Sage -> Match and lock
```

### 4.3 VAT blockers page

Route:

```text
/internal/accounting-vat/blockers
```

Show blocker groups, owner, source link, severity, reason, and required action.

### 4.4 VAT journal detail

Route:

```text
/internal/accounting-vat/journals/[journal_id]
```

Show source VAT line, reason code, target box, amount, period, journal lines, tax-return-included line, balancing excluded line, payload preview, Sage response, and reversal link if applicable.

---

## 5. Status model

VAT return run statuses:

- `draft`;
- `calculated`;
- `admin_review_required`;
- `blocked`;
- `admin_approved`;
- `sage_adjustment_journals_pending`;
- `sage_adjustment_journals_posted`;
- `sage_return_review_required`;
- `sage_return_submitted`;
- `matched_to_sage_locked`;
- `mismatch_needs_admin_review`;
- `reopened_for_correction`.

VAT adjustment journal statuses:

- `platform_calculated`;
- `dry_run_validated`;
- `dry_run_failed`;
- `admin_approved`;
- `posting_to_sage`;
- `posted_to_sage`;
- `failed_retryable`;
- `failed_terminal`;
- `included_in_sage_return`;
- `requires_reversal`;
- `reversed`.

---

## 6. Source objects and lineage

VAT return lines must be source-linked. Do not rely on free text references alone.

Important lineage paths:

```text
DVA statement line -> DVA reconciliation -> order_funding_events -> VAT return line -> Sage VAT journal
```

```text
order_funding_events -> cash_posting_snapshot -> cash_posting_batch_row -> Sage contact_payment/payment_on_account -> Sage contact_allocation -> Sage sales_invoice
```

```text
sales_invoices -> sage_posting_snapshots / sage_posting_batch_rows -> Sage sales_invoice id -> VAT return source line
```

```text
supplier invoice / supplier credit note / refund evidence -> Sage AP/credit-note posting -> VAT return source line
```

Every VAT return line must record enough lineage to explain:

- why it affects a box;
- which period it belongs to;
- whether Sage already covered it naturally;
- whether an adjustment journal was required;
- whether any later reversal/correction links back to it.

---

## 7. Required backend objects

Create additive objects rather than overloading summary-only legacy workings.

Required objects:

- `vat_return_runs`;
- `vat_return_run_lines`;
- `vat_return_adjustment_journals`;
- `vat_return_adjustment_journal_lines`;
- `vat_return_sage_match_evidence`;
- `vat_return_blockers`.

Later extension objects if needed:

- `vat_return_reopen_events`;
- `vat_return_correction_links`.

Existing objects to reuse:

- `order_funding_events`;
- `dva_reconciliation`;
- `dva_statement_lines`;
- `cash_posting_snapshots`;
- `cash_posting_batch_rows`;
- `sales_invoices`;
- `sage_posting_snapshots`;
- `sage_posting_batch_rows`;
- `supplier_invoices`;
- `supplier_invoice_lines`;
- `shipping_documents` / export evidence objects;
- `disputes`, `dispute_lines`, `dispute_messages` for refund/replacement exceptions.

---

## 8. Sage prerequisites

Before automatic VAT adjustment journals can be posted:

1. Sage OAuth connection must be active.
2. `GET /financial_settings` must confirm a compatible VAT scheme.
3. Flat Rate Scheme must block automated VAT journal logic.
4. Cash accounting must block or route to a separately tested rule path.
5. Standard/accrual VAT scheme is the supported route for this contract.
6. `GET /ledger_accounts` must verify mapped accounts for:
   - VAT on Sales / output VAT;
   - VAT on Purchases / input VAT;
   - export sales / income nominal;
   - purchases / expenditure nominal;
   - VAT adjustment clearing/control nominal.
7. `GET /tax_rates` must verify the relevant tax rates, including zero-rate/export and standard VAT where needed.

Standard VAT scheme does not mean every supply is standard-rated. Exports may be zero-rated and shipper costs may be zero-rated. The scheme check is about the VAT accounting basis, not the tax rate applied to every transaction.

---

## 9. Sage VAT journal mechanism

Sage VAT box adjustments are posted through `/journals`, not by a `/vat_returns` endpoint.

A Sage journal must balance. Therefore every VAT adjustment journal must have:

| Line | include_on_tax_return | Purpose |
|---|---:|---|
| VAT-box line | true | Drives Box 1, Box 4, Box 6 or Box 7 |
| Balancing line | false | Balances the journal without creating a second VAT-box effect |

Do not post one-sided journals. Do not include the balancing line on the VAT return unless a later tested rule explicitly requires it.

Box movement rules:

| Target | Sage journal movement |
|---|---|
| Increase Box 1 | Credit VAT on Sales / output VAT |
| Decrease Box 1 | Debit VAT on Sales / output VAT |
| Increase Box 4 | Debit VAT on Purchases / input VAT |
| Decrease Box 4 | Credit VAT on Purchases / input VAT |
| Increase Box 6 | Credit income nominal |
| Decrease Box 6 | Debit income nominal |
| Increase Box 7 | Debit expenditure nominal |
| Decrease Box 7 | Credit expenditure nominal |

Boxes 3 and 5 are calculated by Sage from Boxes 1 and 4. Do not post directly to Boxes 3 or 5.

---

## 10. Box 6 customer prepayment rules

For Goodcashback, customer/importer funds normally arrive before the final sales invoice. The customer receipt is posted to Sage as Bank to Customer Account / payment on account. Later, when the sales invoice is raised, the accounting flow is Customer Account to Sales GL, then cash allocation clears the payment-on-account against the invoice.

Therefore Sage may not naturally include Box 6 until the Sage sales invoice exists, but VAT timing may already be triggered by payment.

Rule:

```text
If customer full/part payment is received in VAT period A
and the payment is tied to a specific order/supply through order_funding_events
and no Sage sales invoice for the same order/subset is posted in Sage in period A
and no prior VAT return line has already reported that funding event
then create a Box 6 increase adjustment journal in period A.
```

When the Sage sales invoice is later posted:

```text
If the same value was previously reported in Box 6 from funding
and Sage would include the later sales invoice in Box 6
then create a Box 6 decrease adjustment journal in the invoice period
linked to the original Box 6 increase.
```

Do not reverse merely because the next period starts. Reverse only when a later Sage invoice, cancellation, refund, or correction creates the need to neutralise the earlier Box 6 inclusion.

If sales invoice and payment are in the same VAT period and the Sage sales invoice covers the correct value, no Box 6 adjustment is needed.

Wallet/general overfunding not tied to a specific supply is not Box 6 until applied to a specific order/supply.

---

## 11. Export evidence and Box 1 breach rules

For zero-rated export sales, the anchor is the time of supply/time of sale, not simply the sales invoice date and not normally the UK shipper warehouse receipt date.

For this model:

```text
zero_rating_deadline_start_date = earlier of:
  full customer payment / prepayment date
  dispatch/send-to-customer date
```

Because orders are normally paid in full up front, the deadline start date will usually be the full payment date.

The UK shipper warehouse receipt date is operational/export evidence. It is not the default start date for the export evidence deadline unless it is also the send/takeaway date and there was no earlier full payment.

If acceptable export evidence is not held by the deadline:

```text
Create Box 1 increase adjustment journal in the VAT period where the deadline expires.
```

Do not amend the original prepayment period. The breach is reported in the period in which the deadline expires.

If acceptable export evidence is later obtained:

```text
Create Box 1 decrease/reinstatement journal in the period evidence is received.
Link it to the original breach journal.
```

Breach VAT basis for the Goodcashback customer-paid export model:

```text
breach_vat_amount = taxable consideration received/invoiced x 1/6
```

Use VAT-inclusive treatment unless the customer contract/invoice expressly says VAT is chargeable in addition if zero-rating fails. The VAT return pack must store which basis was used and why.

---

## 12. Box 4 and Box 7 purchase rules

Supplier AP with valid UK VAT invoice:

- normal route is Sage purchase invoice posting;
- Sage should naturally drive Box 4 and Box 7;
- adjustment journal only if Sage natural result differs from the platform VAT pack.

Supplier AP missing valid VAT invoice:

- no Box 4 reclaim by default;
- Box 7 treatment requires admin-approved evidence/tax treatment;
- do not allow bank/card statement alone to create input VAT recovery.

Supplier credit note:

- normal route is Sage purchase credit note posting;
- Sage should naturally reduce Box 4 and Box 7;
- adjustment journal only if Sage natural result differs.

Retailer refund with no credit note:

| Evidence state | If original input VAT claimed | VAT treatment |
|---|---:|---|
| Credit note received | Yes | Purchase credit note route |
| Refund proof, no credit note | Yes | Admin VAT review; likely Box 4/7 decrease journal |
| Refund proof, no credit note | No | No Box 4 reversal; Box 7 only if purchase value was included |
| No document / unclear | Any | Block VAT return final approval |

Shipper AP:

- if zero-rated freight/logistics, no Box 4 input VAT;
- Box 7 purchase value only if Sage/tax-code treatment includes it or platform-approved adjustment is needed;
- unclear shipper VAT treatment blocks VAT return approval.

FX/card residuals and bank fees:

- FX residual: no VAT box by default;
- card markup/residual: no VAT box by default;
- bank fee: no Box 4 unless valid VAT evidence supports input VAT.

---

## 13. Journal templates

### Box 6 increase

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | Export sales/income nominal | Credit | true |
| Balance line | VAT adjustment clearing/control or paired income control | Debit | false |

### Box 6 decrease

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | Export sales/income nominal | Debit | true |
| Balance line | VAT adjustment clearing/control or paired income control | Credit | false |

### Box 1 increase

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | VAT on Sales / output VAT | Credit | true |
| Balance line | VAT adjustment expense/control | Debit | false |

### Box 1 decrease

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | VAT on Sales / output VAT | Debit | true |
| Balance line | VAT adjustment expense/control | Credit | false |

### Box 4 increase

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | VAT on Purchases / input VAT | Debit | true |
| Balance line | VAT adjustment control | Credit | false |

### Box 4 decrease

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | VAT on Purchases / input VAT | Credit | true |
| Balance line | VAT adjustment control | Debit | false |

### Box 7 increase

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | Purchase/expenditure nominal | Debit | true |
| Balance line | VAT adjustment clearing/control or paired expense control | Credit | false |

### Box 7 decrease

| Line | Account | Direction | include_on_tax_return |
|---|---|---:|---:|
| VAT-box line | Purchase/expenditure nominal | Credit | true |
| Balance line | VAT adjustment clearing/control or paired expense control | Debit | false |

---

## 14. Blockers

Block VAT return approval/posting/lock if any of these exist:

1. Prior VAT return is not matched and locked.
2. Sage financial settings are not confirmed.
3. Flat Rate Scheme is detected.
4. Cash accounting is detected and no tested cash-accounting rule path exists.
5. Sage ledger mappings for VAT Sales, VAT Purchases, income, expense and clearing are missing.
6. Any VAT adjustment journal lacks a source VAT line.
7. Any balancing line is incorrectly marked `include_on_tax_return = true`.
8. A payment-before-invoice Box 6 event is unresolved.
9. A later invoice exists but the required Box 6 anti-duplicate reversal is missing.
10. Export evidence deadline breached with no Box 1 treatment.
11. Later export evidence exists but no linked Box 1 reinstatement treatment is present.
12. Refund received but supplier credit/VAT treatment unresolved.
13. AP input VAT claimed without valid VAT evidence or admin-approved treatment.
14. Any adjustment would duplicate a value already naturally included by Sage.
15. Method 2 VAT correction is required.
16. Sage submitted return values do not match the platform locked pack.

---

## 15. Idempotency and posting controls

All Sage VAT journal postings must be server-side only.

Never post Sage journals directly from the browser.

Each journal must have an idempotency key based on:

```text
vat_return_run_id + adjustment_type + source_line_id + direction + amount + period
```

Reversals must link to the original journal and must not be created as standalone orphan adjustments.

Sage request and response payloads must be logged with:

- endpoint path `/journals`;
- method `POST`;
- idempotency key;
- payload hash;
- Sage business id;
- response status;
- Sage journal id/reference;
- error code/message if failed.

---

## 16. Submission evidence and lock

Admin submits the VAT return in Sage after the platform journals have posted.

The platform must then record:

- Sage submitted Box 1;
- Sage submitted Box 2;
- Sage submitted Box 3;
- Sage submitted Box 4;
- Sage submitted Box 5;
- Sage submitted Box 6;
- Sage submitted Box 7;
- Sage submitted Box 8;
- Sage submitted Box 9;
- Sage/HMRC reference if available;
- submission timestamp;
- evidence file/screenshot/PDF/export if required.

Lock only when Sage submitted values match the platform expected values within the agreed tolerance.

Once locked, never mutate the locked return. Later changes are current-period correction lines linked back to the original return line.

---

## 17. Build sequence

1. Read-only VAT workbench page.
2. VAT return run and source-line snapshot.
3. Box 6 prepayment engine.
4. Box 1 export evidence breach/reinstatement engine.
5. Box 4/7 purchase and refund treatment engine.
6. Sage VAT journal queue with dry-run validation.
7. Sage `/journals` posting adapter.
8. Sage return evidence capture, matching and lock.

Do not build posting before the read-only pack and blockers are correct.

---

## 18. Definition of done

The VAT workbench is not done until:

1. Admin-only access is enforced.
2. Period selection works.
3. Source-line pack is explainable from platform facts.
4. Box 1/4/6/7 values are traceable.
5. Prepayment-first Box 6 logic works.
6. Later-invoice Box 6 reversal logic works.
7. Export evidence deadline breach and reinstatement work.
8. Journal balancing lines are excluded from the VAT return.
9. Sage `/journals` payloads are dry-run validated before live posting.
10. Sage journal responses are stored.
11. Sage submitted return values can be recorded.
12. Match/lock prevents accidental mismatch closure.
13. Prior locked returns are never mutated.
14. The UI is simple enough for an admin to understand the next action without reading SQL.
