# Completion Loyalty Sage Accounting Posting Addendum v1

Status: locked implementation contract addendum to `COMPLETION_LOYALTY_MAIN_BANK_DVA_PAIRING_ACCOUNTING_CONTRACT_v1.md` and `COMPLETION_LOYALTY_APPLIED_ACCOUNTING_PREVIEW_ADDENDUM_v1.md`.

This addendum authorises the next MVP accounting/Sage build for completion loyalty without changing the already-locked loyalty activation, credit application, VAT return, DVA/card reconciliation, customer sales, supplier/AP, shipper/AP, or cash-posting flows except where this addendum explicitly approves the shared customer-receivable allocation prerequisite and final-balance customer-receipt bridge.

It deliberately does not rewrite the 23 June 2026 completion-loyalty contract. It narrows how the next Sage/accounting layer plugs into the existing platform.

This addendum does not invent a new Sage posting method. It creates dedicated completion-loyalty source lanes that feed existing proven Sage posting primitives already used elsewhere in the platform.

Existing proven Sage posting primitives to reuse:

```text
POST /contact_payments
POST /contact_allocations
POST /journals
```

Approved shared customer-receivable prerequisites now form part of this contract:

```text
confirmed final_balance_payment DVA/card IN allocations may be bridged into the existing customer receipt cash-posting workbench as source_type = dva_final_balance_allocation;
customer receipt allocation may allocate deterministically across multiple open posted customer_sales invoice snapshots for the same order and same Sage contact.
```

---

## 1. Locked accounting conclusion

Completion loyalty creates two different accounting events. They are linked, but they must not be collapsed into one posting.

### 1.1 Loyalty funding transfer event

When company money is moved from the main bank into the DVA/card/virtual-card account to fund/release loyalty, the accounting meaning is an internal transfer:

```text
Dr DVA/card/virtual-card bank / clearing asset
Cr main bank
```

This is cash movement only.

It is not customer funding.

It is not customer receipt.

It is not supplier/card spend.

It is not shipper/AP payment.

It does not create VAT timing.

### 1.2 Applied loyalty customer-settlement event

When the released completion-loyalty credit is actually applied to an order, the accounting meaning is customer balance settlement funded by the business:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / customer receivable / customer settlement clearing
```

This is not cash movement at the date of application.

It is not a supplier/card payment.

It is not a shipper/AP payment.

It is not a sales credit note.

It must not reduce or rewrite the customer sales invoice.

---

## 2. Source events

### 2.1 Internal transfer source

The only source for the loyalty internal-transfer accounting control is:

```text
main_bank_completion_loyalty_funding_matches
```

A row is eligible for internal-transfer journal materialisation only when:

```text
transfer_pair_status = 'paired_released'
match_status = 'released_available_dashboard_credit'
source OUT statement line exists
destination IN statement line exists
matched_gbp_amount > 0
```

The OUT side must be the main company bank statement line.

The IN side must be the DVA/card/virtual-card statement line for the same importer.

### 2.2 Applied-loyalty settlement source

The only source for the applied-loyalty settlement accounting layer is:

```text
order_funding_events.event_type = 'credit_applied'
```

where the linked source credit is:

```text
importer_credit_ledger.source_type = 'completion_loyalty_reward'
```

The source chain must remain:

```text
completion-loyalty credit ledger row
  -> debit ledger row applied to order
  -> order_funding_events.credit_applied
```

Do not materialise a Sage/accounting posting from:

```text
pending loyalty approval
rejected loyalty approval
staged main-bank OUT
paired but unused DVA/card IN
released but unused loyalty credit
DVA/card transfer line alone
main-bank OUT line alone
```

---

## 3. MVP build order

The MVP must be built in this order.

### Phase 0 — Shared customer-receivable prerequisites

Before the loyalty settlement lane is built, the existing customer-receivable cash infrastructure must be capable of:

```text
1. exposing confirmed final_balance_payment DVA/card IN allocations as customer receipt rows;
2. freezing/posting those rows through the existing customer receipt cash-posting route;
3. allocating a receipt/payment-on-account across one or more open posted customer_sales invoice snapshots for the same order and same Sage contact.
```

This prerequisite is already aligned with the final-balance bridge migration and the shared multi-invoice cash allocation resolver. It is not a loyalty posting lane and does not make loyalty IN/OUT lines generic cash.

### Phase 1 — Applied-loyalty customer settlement posting

This is the first live-posting candidate because it is triggered by the existing `credit_applied` event and directly settles the customer account/order balance.

The implementation must not treat it as ordinary cash receipt from the customer. It must use a dedicated non-cash loyalty settlement lane.

### Phase 2 — Loyalty internal-transfer journal posting

The internal-transfer journal uses the existing proven `/journals` posting primitive.

It does not need a new Sage posting mechanism.

It does require dedicated loyalty source rows, dedicated mappings, dry-run/local validation, admin approval, idempotency, and Sage request/response logging.

Live posting may be enabled only after the loyalty main-bank, DVA/card, and any required in-transit clearing ledger mappings are configured and a controlled dry-run passes.

---

## 3A. Internal-transfer Sage journal posting boundary

The internal-transfer posting adapter must reuse the existing Sage OAuth/business-context/request/response logging infrastructure and the existing journal-posting primitive.

It must not create a second Sage journal mechanism.

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

The adapter must validate before posting:

```text
exactly two journal lines;
both journal lines use Sage long ledger account ids;
debits equal credits;
journal total equals the posting group amount;
include_on_tax_return = false on every line;
no tax_rate_id is carried on the internal-transfer journal lines.
```

Live posting must be controlled by the dedicated completion-loyalty internal-transfer journal flag only:

```text
SAGE_LIVE_COMPLETION_LOYALTY_INTERNAL_TRANSFER_POSTING_ENABLED=true
```

Do not enable this journal lane through generic cash-posting flags.

Specifically prohibited:

```text
SAGE_LIVE_CASH_POSTING_ENABLED must not enable completion-loyalty internal-transfer journal posting.
```

A broader future journal flag may be introduced only if it is explicitly documented as a Sage journal flag and does not make cash receipt/payment enablement imply journal enablement.

UI labels must make the posting path visible to staff:

```text
Internal-transfer Sage journal batch
Endpoint: /journals
Post Sage journal batch
```

Avoid the vague label:

```text
Post loyalty Sage batch
```

because completion-loyalty contains more than one Sage lane.

---

## 3B. Database function naming boundary

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

## 4. Correct Sage treatment for applied loyalty

A pure GL journal is not sufficient if the business needs the Sage customer/contact account to show the customer invoice as settled.

For MVP correctness, the applied-loyalty settlement should use the existing proven customer-account pattern, but in a dedicated non-cash loyalty lane:

```text
Step 1: create a non-cash customer receipt/payment-on-account using a dedicated loyalty clearing bank/account.
Step 2: allocate that payment-on-account to the posted Sage customer sales invoice(s) for the order.
Step 3: clear the loyalty clearing balance to loyalty reward expense using a VAT-safe journal/clearing entry.
```

Net accounting result:

```text
Dr loyalty reward expense / approved loyalty cost account
Cr customer account / receivable
```

Operational Sage result:

```text
Customer invoice receivable is settled on the Sage customer/contact account.
The loyalty clearing account is cleared.
No real DVA/main-bank cash is faked.
No VAT timing is created by this Sage settlement layer.
```

This mirrors the existing proven cash receipt + customer allocation mechanics, but must not reuse the generic cash-posting lane or labels.

The lane must be named distinctly, for example:

```text
completion_loyalty_non_cash_customer_settlement
```

---

## 5. Applied-loyalty settlement posting mechanics

### 5.1 Required Sage endpoints/patterns

The applied-loyalty customer settlement lane uses the same mechanics already proven by the existing cash receipt/allocation and journal posting code paths:

```text
POST /contact_payments
POST /contact_allocations
POST /journals
```

But it must remain a separate loyalty posting lane with separate tables, statuses, idempotency keys, and UI labels.

### 5.2 Required mappings

Applied-loyalty settlement requires only mappings needed for the applied-loyalty settlement lane. Internal-transfer ledger mappings must not be reused for customer-account settlement unless explicitly documented in a later addendum.

### 5.3 No VAT timing change

Applied-loyalty settlement posting does not create new VAT timing. VAT timing remains driven by the locked order funding, customer sales invoice, export evidence, and VAT return contracts.
