# Amount-Aware Statement-Line Control Contract v1

Status: additive governing contract for review and implementation on branch `agent/amount-aware-statement-line-control`.

## 1. Purpose

This contract governs one shared, read-only interpretation of every bank/DVA/card statement line before any page or write action decides what the line can do.

It fixes the architectural problem proven by the live audit:

- raw table-family count is not the same as economic-use count;
- a single economic workflow can create evidence in more than one table;
- one physical line can legitimately be split by amount across compatible uses;
- reversed rows and test rows remain historical evidence and must not be silently rewritten;
- a page-level filter cannot safely decide whether a line is funding, supplier payment, loyalty transfer, refund, final balance, shipper AP, fee, FX/card difference, or held residue.

The resolver is therefore upstream of page filtering. It does not replace any existing action RPC.

## 2. Locked boundaries

The implementation is additive and read-only.

It must not:

- edit or delete statement lines;
- edit or delete reconciliations, allocations, loyalty matches, confirmations, cash snapshots, or shipper AP allocations;
- invent source lots;
- relabel bank-account mappings;
- convert legacy loyalty evidence into modern paired loyalty;
- convert test or manual-seed rows into production evidence;
- alter order funding, supplier-payment, loyalty, refund, shipper AP, cash-posting, Sage, VAT, sales-ledger, OCR, shipment, or customer-hold write paths;
- change `/internal/funding` or any other page in this build;
- make a raw `family_count > 1` an automatic blocker.

Historical remediation remains a separate approved build.

## 3. Statement account contexts

The live schema has two account contexts:

1. `importer_dva_card_account`
2. `main_company_bank_account`

The context is authoritative. A reference or order/auth identifier is identity evidence; it does not override the account context or transaction direction.

## 4. Full workflow list

### 4.1 Statement import and preservation

Flow:

`statement file -> import batch -> parsed statement -> physical statement lines`

The physical line remains immutable evidence. Later tables describe use of the amount; they do not replace the line.

### 4.2 Customer/order funding

Flow:

`importer DVA/card IN -> dva_reconciliation(order_funding) -> order_funding_events(funding_contribution) -> funding position -> funded_at`

Required shape:

- account context: `importer_dva_card_account`
- direction: `in`
- amount consumed: `dva_reconciliation.reconciled_gbp_amount`

This is an economic lane: `customer_order_funding`.

### 4.3 Customer IN surplus routed to FX gain

Flow:

`one importer IN -> order funding up to current gap + confirmed fx_card_difference for surplus`

This is a valid amount-aware multi-family result.

Example proven by the audit:

- statement line: £111
- order funding: £100
- FX gain: £11
- raw families: `order_funding_reconciliation` and `dva_allocation`
- economic interpretation: one principal funding lane plus one auxiliary residual lane
- expected blocker: none

The resolver must not classify this as statement-line reuse.

### 4.4 Intentional overfunding and normal account credit

Flow:

`importer IN -> order funding reconciliation above the gap, only when expressly allowed -> overfunding credit lot -> later normal account-credit application`

The statement line is consumed by the funding reconciliation. The credit ledger and later application are downstream provenance, not a second statement-line consumption.

### 4.5 Normal account credit application

Flow:

`available normal credit lots -> staff_apply_importer_credit_to_order -> debit per exact source lot -> order_funding_events(credit_applied)`

This lane does not consume a new statement line at application time. The resolver must not invent a statement-line source for it.

Completion loyalty is excluded from normal account credit.

### 4.6 Completion-loyalty source OUT

Flow:

`main company bank OUT -> main_bank_completion_loyalty_funding_matches.dva_statement_line_id`

Required shape:

- account context: `main_company_bank_account`
- direction: `out`
- economic lane: `completion_loyalty_source_transfer`
- amount consumed: active `matched_gbp_amount`

One source OUT may fund multiple reward rows. Those rows are one economic lane and must be summed by amount, not counted as conflicting uses.

### 4.7 Completion-loyalty destination IN

Flow:

`paired importer DVA/card IN -> main_bank_completion_loyalty_funding_matches.destination_in_statement_line_id -> release confirmation -> completion-loyalty credit lot`

Required shape:

- account context: `importer_dva_card_account`
- direction: `in`
- economic lane: `completion_loyalty_destination_transfer`
- amount consumed: active match rows' `matched_gbp_amount`

`completion_loyalty_reward_funding_confirmations` is documentary evidence where it is linked to the same modern loyalty match. It must not consume the amount again.

This directly resolves the live false multi-family results:

- `completion_loyalty_destination_in`
- `completion_loyalty_funding_confirmation`

Those are two raw evidence families for one economic lane.

### 4.8 Completion-loyalty bulk funding pot

Flow:

`one source OUT + one destination IN -> several released rewards for the same importer`

The resolver must:

- sum active match amounts;
- count one principal economic lane;
- preserve every reward/match row in `usage_evidence`;
- leave any excess destination IN amount unconsumed;
- not convert the excess to loyalty FX automatically.

### 4.9 Completion-loyalty reversal before order application

Flow:

`paired/released loyalty -> reversal before application -> match/confirmation/credit reset to selection`

Reversed rows are historical. They remain in evidence but do not consume current available amount.

A line can therefore have active and reversed rows in the same family without being double-consumed.

### 4.10 Legacy completion-loyalty funding confirmation

A confirmation that has no modern linked `main_bank_completion_loyalty_funding_matches` row is legacy evidence.

The resolver must expose it as:

- economic lane: `legacy_completion_loyalty_funding`
- control status: review required
- blocker: `legacy_loyalty_evidence_without_modern_match_link`

It must not silently mark it as modern paired loyalty.

### 4.11 Completion-loyalty application to an order

Flow:

`released completion-loyalty credit lot -> exact debit -> order_funding_events(credit_applied)`

This consumes credit provenance, not the statement line again. The line remains consumed only by the source/destination transfer lane.

### 4.12 Supplier payment — single invoice

Flow:

`importer DVA/card OUT -> approved supplier invoice -> confirmed dva_statement_line_allocations(supplier_invoice)`

Required shape:

- account context: `importer_dva_card_account`
- direction: `out`
- economic lane: `supplier_payment`

Source-bank and wallet provenance remain owned by the existing supplier-payment source resolver.

### 4.13 Supplier payment — multi-invoice bundle

Flow:

`one physical OUT -> several approved supplier invoices on one order/importer/retailer -> atomic bundle allocations`

All child allocations are one principal economic lane: `supplier_payment`.

The resolver must:

- sum confirmed child allocation amounts;
- retain every invoice allocation in evidence;
- not treat several invoice rows as several conflicting uses;
- expose any remaining amount.

### 4.14 Supplier-payment auxiliary residuals

Existing allocation types can describe the remainder or control treatment:

- `fx_card_difference`
- `bank_fee`
- `exception_hold`
- `not_charged_closure`
- `unmatched_hold`

These are auxiliary lanes. They may coexist with one principal importer-DVA lane where direction and account context remain valid.

They do not create a second principal purpose by themselves.

### 4.15 Retailer refund / credit-note receipt

Flow:

`importer DVA/card IN -> confirmed dva_statement_line_allocations(retailer_refund) -> dispute/refund control`

Required shape:

- account context: `importer_dva_card_account`
- direction: `in`
- economic lane: `retailer_refund`

Reversed refund allocations are historical only.

### 4.16 Final-balance payment

Flow:

`importer DVA/card IN -> confirmed final_balance_payment allocation -> order final-balance control`

Required shape:

- account context: `importer_dva_card_account`
- direction: `in`
- economic lane: `final_balance_payment`

### 4.17 Main-bank shipper AP payment

Flow:

`main company bank OUT -> posted shipper AP target -> main_bank_shipper_ap_allocations`

Required shape:

- account context: `main_company_bank_account`
- direction: `out`
- economic lane: `main_bank_shipper_ap`

A main-bank OUT cannot simultaneously be a shipper AP payment and a completion-loyalty source transfer without a blocker.

### 4.18 Customer-receipt cash posting and Sage

Flow:

`order-funding reconciliation -> cash_posting_snapshot -> Sage customer receipt`

The snapshot is downstream documentary evidence. It does not consume the statement line again.

### 4.19 Completion-loyalty internal-transfer journal and Sage

Flow:

`paired source OUT + destination IN -> completion-loyalty posting group/batch/steps -> Sage journal`

The journal is downstream documentary evidence. It does not consume either statement line again.

### 4.20 Reversed, superseded and test evidence

The resolver must preserve and expose:

- `reversed` allocation rows;
- reversed loyalty matches/confirmations;
- inactive cash snapshots;
- manual/test/seed references;
- historical wrong mappings.

They do not consume current amount unless their current table status is active.

No cleanup or historical correction is included in this build.

## 5. Raw families versus economic lanes

Raw evidence families currently covered:

- `order_funding_reconciliation`
- `dva_allocation`
- `main_bank_shipper_ap`
- `completion_loyalty_source_match`
- `completion_loyalty_destination_match`
- `completion_loyalty_funding_confirmation`
- `cash_posting_snapshot`

Economic lanes:

- `customer_order_funding`
- `supplier_payment`
- `retailer_refund`
- `final_balance_payment`
- `fx_card_difference`
- `bank_fee`
- `exception_control`
- `main_bank_shipper_ap`
- `completion_loyalty_source_transfer`
- `completion_loyalty_destination_transfer`
- `legacy_completion_loyalty_funding`
- `legacy_dva_reconciliation`

Documentary rows remain in raw evidence but are excluded from economic consumption.

## 6. Amount rules

For each physical statement line:

`statement amount - active consumed amount - active reserved amount = remaining unconsumed amount`

The resolver separately exposes:

- active consumed amount;
- active reserved amount;
- remaining unconsumed amount;
- overconsumed amount;
- active principal economic lanes;
- raw evidence families;
- historical evidence rows.

A line is amount-blocked when active consumed plus active reserved exceeds the physical statement amount by more than £0.01.

## 7. Principal-lane compatibility

A line is incompatible only when it has more than one active principal lane.

Principal lanes:

- customer order funding
- supplier payment
- retailer refund
- final balance payment
- main-bank shipper AP
- completion-loyalty source transfer
- completion-loyalty destination transfer
- legacy completion-loyalty funding
- legacy DVA reconciliation

Auxiliary lanes do not create principal conflict:

- FX/card difference
- bank fee
- exception/hold control

Therefore:

- funding + FX surplus is valid;
- supplier invoice + FX/card residual is valid;
- several supplier invoices in one bundle are valid;
- several loyalty reward rows against one source/destination pair are valid;
- destination match + linked funding confirmation is valid;
- shipper AP + loyalty source transfer is blocked;
- funding + refund on the same physical IN is blocked.

## 8. Resolver output

`internal_statement_line_control_resolver_v1(statement_line_id)` returns one row with:

- physical statement identity, account context, direction and amount;
- active consumed, reserved, remaining and overconsumed amounts;
- raw active families;
- active economic lanes;
- principal lane count;
- historical row count;
- direction/account-context validation;
- incompatible-lane validation;
- control status and blocker;
- next action;
- complete JSON usage evidence.

## 9. Integration delivered by v1

This build integrates the resolver without replacing specialist React pages or their established write RPCs:

1. The existing `dva_statement_line_allocation_summary_vw` public name becomes an amount-aware wrapper while the previous view is retained as `dva_statement_line_allocation_summary_base_v1`.
2. The existing `day2_dva_review_worklist_vw` public name becomes a resolver-filtered funding view while the previous view is retained as `day2_dva_review_worklist_base_v1`.
3. Funding therefore receives only importer DVA/card IN lines that are unresolved funding candidates or existing order-funding audit rows.
4. DVA reconciliation, unmatched triage, workspace and review-pack pages continue using their existing summary source but receive central consumed, reserved, remaining, collision and route fields.
5. Main-bank shipper line listing and completion-loyalty destination-IN candidates use the same resolver position.
6. A database trigger guards every new `order_funding` reconciliation insert, including non-UI callers.
7. Existing supplier, refund, final-balance, shipper-AP and loyalty RPC controls remain in place.
8. Historical remediation is handled separately.

A Funding-page direction filter alone is expressly rejected because it would hide symptoms while leaving loyalty IN, refund IN, final-balance IN and other workbenches capable of inconsistent decisions.
