# Supplier Payment Funding Provenance Governing Addendum v1

Status: locked implementation contract for the existing funding and DVA/card supplier-payment paths.

## Authority and scope

This addendum governs only:

- credit applied to an order by staff;
- supplier-invoice candidates in the existing DVA/card statement workspace;
- the final supplier-invoice allocation RPC; and
- the source fields already consumed by cash posting.

It extends, and does not replace:

- `docs/governing-pack/ui/FUNDING_ACTION_CONTRACT.md`;
- `docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`;
- `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_AUTO_RESOLUTION_ADDENDUM_v1.md`;
- the existing source-lot account-credit functions;
- the existing completion-loyalty approval, release, pairing and order-application lane; and
- the existing DVA/card statement allocation and cash-posting architecture.

## Locked decisions

### 1. Reuse the existing source-lot ledger

Credit must never be reduced to an unexplained aggregate debit when it is applied to an order.

Normal account credit continues to use the existing deterministic source-lot order from `internal_importer_available_account_credit_lots_v1(...)`:

1. settlement credit;
2. overfunding;
3. refund resolution;
4. liability settlement;
5. payout reversal; and
6. manual credit.

Each amount consumed must create its own debit row linked to the exact original credit row through both supported source-link fields.

### 2. Completion loyalty remains a separate controlled lane

Completion loyalty is not reintroduced into the normal account-credit helper.

Its approval, release, main-bank pairing and application to an order remain controlled by the existing completion-loyalty functions and workbench. When completion loyalty is applied, its debit must remain linked to the exact completion-loyalty credit lot.

Therefore all credit forms retain exact source-lot provenance, but normal account credit and completion loyalty remain separate application lanes.

### 3. Order creation remains unchanged

The existing customer/importer order-creation routes continue calling `customer_apply_available_credit_to_order_v1(...)`.

This addendum does not change order creation, quote calculation, screenshots, order totals, order status progression or the completion-loyalty workbench.

### 4. Staff credit application must use the same normal source-lot truth

The public staff RPC name and argument contract remain unchanged:

```text
staff_apply_importer_credit_to_order(importer_id, order_id, amount_gbp, staff_id)
```

Its implementation must consume `internal_importer_available_account_credit_lots_v1(...)` and create one linked debit per source lot. It must preserve:

- active admin/supervisor authentication;
- importer/order ownership validation;
- original-order-only validation;
- order locking and credit-ledger locking;
- the remaining funding-gap cap;
- the available-credit cap;
- the existing £500 escalation rule; and
- a response compatible with the current Funding page.

The existing importer-credit trigger remains the only funding-event synchronisation mechanism for these new debit rows. The staff function must not create a second duplicate funding event.

### 5. Supplier-payment matching has one readiness gate

For an original order, a supplier-invoice payment may be selected or allocated only when:

- `order_funding_position_vw.threshold_met_yn` is true;
- every effective `credit_applied` funding event links to its application debit;
- every application debit links to an existing original credit lot for the same importer;
- every completion-loyalty lot used by the order has released, paired funding evidence and a resolved destination wallet; and
- every effective cash-funding contribution has its existing DVA reconciliation link.

A missing, broken, unknown or ambiguous link fails closed with a precise blocker. No source is inferred from currency, amount, statement balance, browser input or aggregate importer balance.

Replacement-child orders retain the existing `funding not required` architecture. This readiness gate must not invent a new customer-funding requirement for a replacement child. The exact source of its physical supplier-payment OUT must still be resolved or fail closed.

### 6. Candidate and final-write enforcement must agree

The existing workspace must consume one governed supplier-payment candidate/readiness result.

The normal `usable` queue continues to apply its existing `approved_current` filter. Same-importer scoping and completed-target handling remain in place.

The governed result adds:

- funding/provenance readiness;
- invoice total;
- confirmed matched amount;
- remaining unmatched amount; and
- a precise blocker where the invoice is not selectable.

Non-ready rows may remain visible in audit/status filters, but they must not be selectable.

The final allocation RPC must independently repeat the readiness check. The browser and candidate view are not security boundaries.

### 7. One physical OUT is matched once

A single physical bank/card/DVA OUT is one statement line and is allocated once against the real invoice balance.

Customer funding proportions must not create artificial supplier-payment legs.

Example:

```text
Order funding:
£100 released completion loyalty
£300 cash

Physical supplier payment:
one £400 OUT
```

The system must not manufacture a £100 supplier allocation and a £300 supplier allocation solely because the order funding was mixed.

Separate supplier allocations are created only where separate physical OUT transactions exist. Where the source of one physical OUT cannot be resolved cleanly from existing evidence, allocation stops instead of guessing.

### 8. DVA cash is allowed only when proven

`DVA_CASH_BANK_ACCOUNT` remains valid where the existing cash-funding evidence covers the proposed allocation, or where no customer funding is required and the physical OUT has no applied-credit provenance requiring another source.

The final unresolved fallback `default_real_dva_cash_no_released_loyalty_source` is prohibited.

An allocation with applied credit that cannot be classified cleanly must fail with:

```text
source_funding_required_for_supplier_payment_bank_resolution
```

Multiple exact released-loyalty sources continue to fail with:

```text
source_funding_ambiguous_for_supplier_payment_bank_resolution
```

### 9. Existing accounting boundaries remain unchanged

This change must not add or redesign:

- a workbench or page;
- a database allocation table;
- a statement upload selector;
- a browser-supplied source selector;
- a Sage route or Sage bank id;
- a VAT calculation or VAT release rule;
- shipper AP;
- cash-posting snapshots, batches or freeze rules;
- statement import;
- OCR or invoice-line reconciliation;
- logistics, shipment or hold workflows; or
- historical funding records.

Cash posting continues reading `dva_statement_line_allocations.source_bank_account_mapping_code`. Sage external ids remain controlled by `sage_mapping_settings`.

No automatic historical backfill is permitted. Legacy aggregate credit applications remain auditable and are blocked from new supplier-payment allocation where provenance cannot be proved.

## Required implementation surface

1. Replace only the internals of the existing staff normal-credit RPC with source-lot consumption.
2. Add one read-only supplier-payment readiness function.
3. Add one read-only supplier-payment candidate/status view.
4. Call the readiness function inside the existing final supplier allocation RPC.
5. Remove the unresolved DVA-cash fallback.
6. Wire the existing workspace to the governed view and show total, matched and remaining.
7. Add regression checks covering source-lot application, legacy unlinked credit, pure cash, released loyalty, mixed/ambiguous funding, replacement children, duplicate prevention and over-allocation.

## Non-regression rule

Operational evidence collection and movement remain parallel to funding. Invoice upload, OCR, reconciliation, exceptions, tracking, shipment preparation and logistics are not globally blocked by this addendum. Only supplier-payment bank matching is gated by funding and provenance for original orders.
