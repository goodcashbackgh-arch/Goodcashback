# Completion Loyalty Sage Accounting Posting Addendum v1

Status: locked implementation contract addendum to `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md` and `COMPLETION_LOYALTY_APPLIED_ACCOUNTING_PREVIEW_ADDENDUM_v1.md`.

This addendum governs how completion-loyalty accounting plugs into the existing Sage posting primitives. It must not rewrite loyalty activation, credit application, VAT return, DVA/card reconciliation, customer sales, supplier/AP, shipper/AP, or cash-posting flows except where explicitly stated here.

Existing Sage posting primitives to reuse:

```text
POST /contact_payments
POST /contact_allocations
POST /journals
```

Completion loyalty creates two separate accounting events. They are linked commercially, but they must not be collapsed into one posting.

---

## 1. Loyalty funding transfer event

When company money moves from the main bank into the DVA/card/virtual-card account to fund/release loyalty, the accounting meaning is an internal transfer:

```text
Dr DVA/card/virtual-card bank or clearing asset
Cr main bank
```

This is cash movement only. It is not customer funding, not a customer receipt, not supplier/card spend, not shipper/AP payment, and does not create VAT timing.

The only source for this lane is:

```text
main_bank_completion_loyalty_funding_matches
```

A row is eligible for internal-transfer journal materialisation only when:

```text
transfer_pair_status = paired_released
match_status = released_available_dashboard_credit
source OUT statement line exists
destination IN statement line exists
matched_gbp_amount > 0
```

Do not materialise an internal-transfer journal from a lone main-bank OUT, lone DVA/card IN, staged OUT, pending/rejected loyalty row, or released-but-unused credit.

---

## 2. Applied-loyalty customer-settlement event

When released completion-loyalty credit is applied to an order, the accounting meaning is customer balance settlement funded by the business:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / receivable
```

The only source for this lane is:

```text
order_funding_events.event_type = credit_applied
```

where the linked source credit is:

```text
importer_credit_ledger.source_type = completion_loyalty_reward
```

This is not cash movement at the date of application, not a supplier/card payment, not shipper/AP payment, not a sales credit note, and must not reduce or rewrite the customer sales invoice.

For Sage customer-account correctness, applied-loyalty settlement uses the existing customer-account mechanics in a dedicated non-cash loyalty lane:

```text
1. create non-cash customer receipt/payment-on-account using a dedicated loyalty clearing bank/account;
2. allocate it to the posted Sage customer sales invoice(s);
3. clear the loyalty clearing balance to loyalty reward expense using a VAT-safe journal/clearing entry.
```

It must remain a separate loyalty lane with separate tables, statuses, idempotency keys, and UI labels.

---

## 3. Internal-transfer Sage journal posting boundary

The internal-transfer journal must use the existing Sage journal posting primitive. It does not require a new Sage endpoint or a new external posting method.

Required frozen step:

```text
posting_group_type = completion_loyalty_internal_transfer_journal
step_type = loyalty_internal_transfer_journal
endpoint_path = /journals
method = POST
```

Required Sage endpoint:

```text
POST /journals
```

The adapter must read the endpoint from the frozen step and must fail closed if it is not `/journals`.

Before posting, the adapter must validate:

```text
exactly two journal lines;
both lines use Sage long ledger account ids;
debits equal credits;
journal total equals the posting group amount;
include_on_tax_return = false on every line;
no tax_rate_id is carried on the internal-transfer journal lines.
```

Live posting must use the existing journal-style live gate:

```text
SAGE_LIVE_BANK_GL_POSTING_ENABLED=true
```

Do not require a new Vercel environment variable for this MVP internal-transfer category.

Do not use a generic cash-posting live switch to enable this journal lane.

The UI must make the posting path visible to staff:

```text
Internal-transfer Sage journal batch
Endpoint: /journals
Post Sage journal batch
```

Avoid vague labels such as:

```text
Post loyalty Sage batch
```

because completion loyalty contains more than one Sage posting lane.

---

## 4. Database function naming boundary

PostgreSQL identifiers are length-limited. Future database functions must not rely on silent truncation of long names.

For new or replacement RPCs, use explicit short stable names rather than names that exceed PostgreSQL's identifier length.

Required pattern:

```text
short explicit RPC name
clear comment/docstring mapping it to the longer business phrase
application calls the explicit short name, not a silently truncated name
```

If a long legacy function has already been truncated by PostgreSQL, a later repair migration should add a deliberately named wrapper with a short stable name and then update the app to call that wrapper.

---

## 5. No VAT timing change

Neither the internal-transfer journal lane nor the applied-loyalty settlement posting lane creates new VAT timing. VAT timing remains driven by the locked order funding, customer sales invoice, export evidence, and VAT return contracts.
