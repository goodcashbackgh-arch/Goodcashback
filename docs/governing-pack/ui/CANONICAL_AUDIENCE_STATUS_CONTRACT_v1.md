# Canonical Audience Status Contract v1

Status: locked implementation contract for removing status drift across supervisor, importer, customer and shipper-facing pages.

Purpose: prevent any user-facing page from independently calculating order truth in a way that contradicts the canonical operational status engine.

This contract extends:

- `PLATFORM_OPERATIONAL_STATUS_ENGINE_CONTRACT_v1.md`
- `FINAL_SALE_VALUE_AND_BALANCE_DUE_ADDENDUM_v1.md`
- `DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`
- `MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`

## 1. Core rule

There must be one canonical status spine for every active order.

Pages may format labels differently for their audience, but they must not recalculate the underlying order truth independently.

Canonical sources:

```text
internal_platform_order_status_v1()
internal_platform_order_progress_v1()
```

A page-specific/audience-specific status may exist only as a wrapper derived from those canonical sources.

## 2. Prohibited page-level calculations

User-facing pages must not independently calculate any of the following as source-of-truth values:

```text
final_balance_due_gbp
potential_credit_pending_review_gbp
order_complete_yn
current_stage
next_owner
next_action
gate_complete_count
gate_total
customer_sales_state
shipper_ap_state
accounting_sage_state
vat_compliance_state
```

The following local pattern is prohibited outside a canonical SQL function or approved derived wrapper:

```text
finalBalanceDueGbp = finalSaleValueGbp - acceptedEstimateFundingOnly
```

This pattern is wrong because it ignores confirmed final-balance payments and other approved settlement credits.

## 3. Final-balance settlement source of truth

For final-sale settlement, amount received must include all effective settled value allocated to the order.

```text
canonical_settlement_received_gbp =
  accepted_estimate_amount_received_gbp
  + confirmed_final_balance_payment_gbp
  + applied_credit_gbp
```

Where:

```text
accepted_estimate_amount_received_gbp = accepted-estimate/order-funding money already allocated to the order.
confirmed_final_balance_payment_gbp = confirmed DVA/card statement-line allocations with allocation_type = final_balance_payment.
applied_credit_gbp = approved/unlocked account credit actually applied to this order.
```

Final balance due must be:

```text
canonical_balance_due_gbp = max(final_sale_value_gbp - canonical_settlement_received_gbp, 0)
```

Potential credit pending review must be:

```text
potential_credit_pending_review_gbp = max(canonical_settlement_received_gbp - final_sale_value_gbp, 0)
```

No page may show final balance due where canonical balance due is zero.

## 4. Audience status wrapper

A canonical audience wrapper must be introduced before further user-facing status patches are made.

Required function:

```text
order_audience_status_v1(p_order_id uuid default null)
```

Required behaviour:

```text
- call internal_platform_order_status_v1();
- call internal_platform_order_progress_v1();
- return one row per active order, or one row for p_order_id when supplied;
- expose canonical monetary, gate and next-action facts;
- expose audience-formatted labels derived from those same facts;
- not mutate order, funding, DVA/card, Sage, VAT, shipping, credit or AP records.
```

Minimum columns:

```text
order_id
order_ref
raw_order_status
lifecycle_status
importer_id
importer_name
retailer_id
retailer_name
accepted_estimate_gbp
final_sale_value_gbp
canonical_settlement_received_gbp
canonical_balance_due_gbp
potential_credit_pending_review_gbp
internal_current_stage
internal_current_stage_label
internal_next_owner
internal_next_action
internal_next_href
internal_status_tone
gate_complete_count
gate_total
funding_state
dva_state
supplier_state
reconciliation_state
tracking_state
shipment_state
export_evidence_state
pod_delivery_state
customer_sales_state
shipper_ap_state
accounting_sage_state
vat_compliance_state
internal_complete_yn
customer_complete_yn
importer_complete_yn
shipper_complete_yn
customer_status_label
customer_next_action
importer_status_label
importer_next_action
shipper_status_label
shipper_next_action
```

## 5. Audience meaning rules

### Internal/staff status

Internal/staff status is the strict 12-gate operational status.

```text
internal_complete_yn = gate_complete_count = 12
```

A staff page may show `Complete` only where internal completion is true.

### Customer status

Customer-facing completion is narrower than internal operational completion.

A customer order may show complete when:

```text
canonical_balance_due_gbp <= 0.01
and pod_delivery_state = accepted_current
```

Customer-facing pages must still use canonical monetary values from the audience wrapper.

Customer-facing status must not expose internal-only blockers such as shipper AP unless deliberately surfaced as a neutral informational message.

### Importer/operator status

Importer/operator status must reflect what the importer/operator can or must do next.

An importer page must not show `Final balance due` when:

```text
canonical_balance_due_gbp <= 0.01
```

Importer/operator pages may show:

```text
- open evidence/query action;
- tracking action;
- reconciliation action;
- final balance action;
- no importer action required;
- order complete/customer complete.
```

These labels must be derived from the audience wrapper.

### Shipper status

Shipper-facing status must reflect shipper-owned actions only.

Shipper-facing pages must not compute customer final balance independently.

## 6. Pages that must consume the wrapper

The following pages must consume `order_audience_status_v1` or a thin route/helper backed by it before further status work is considered complete:

```text
app/importer/page.tsx
app/importer/orders/[order_id]/operations/page.tsx
app/customer/orders/[order_id]/operations/page.tsx
app/internal/supervisor-command-centre/page.tsx
app/internal/evidence/[order_id]/page.tsx
```

Supervisor Command Centre may continue to call the internal canonical functions directly if it does not perform any contradictory page-level status or balance calculation.

Importer/customer/shipper pages must not keep local source-of-truth status calculations after the wrapper is available.

## 7. Drift audit

A permanent drift audit must exist.

Required function or view:

```text
internal_order_status_drift_audit_v1
```

It must return rows where canonical and legacy/local-style calculations would disagree.

At minimum it must detect:

```text
- LOCAL_PAGE_BALANCE_DRIFT:
  legacy balance due differs from canonical balance due;

- CANONICAL_STATUS_BALANCE_DRIFT:
  internal_platform_order_status_v1().final_balance_due_gbp differs from the independently recomputed canonical balance;

- AUDIENCE_STATUS_DRIFT:
  any audience wrapper label/action conflicts with canonical monetary/gate facts.
```

Normal expected result:

```text
0 rows
```

Any non-zero result blocks release of status-related UI changes.

## 8. Acceptance proof

For every active order, the following must be true:

```text
No importer/customer/shipper page displays final balance due where canonical_balance_due_gbp = 0.
No user-facing page calculates final balance using final sale value minus accepted-estimate funding only.
No page displays a next action that contradicts internal_next_action for its audience-owned responsibility.
Supervisor Command Centre 12-gate result matches internal_platform_order_progress_v1().
Customer/importer pages use audience-specific labels only after receiving canonical monetary/status facts.
```

Known proof case:

```text
Order: ORD-1777736251155
Final sale value: £211.99
Accepted-estimate received: £199.99
Confirmed final-balance payment: £12.00
Canonical balance due: £0.00
Correct result: no page may show Final balance due.
```

## 9. Non-negotiables

Do not fix drift by hard-coding a single order.

Do not fix drift by changing customer, importer, supervisor and shipper pages separately without a shared wrapper.

Do not remove the distinction between customer-complete and internal-complete.

Do not change Sage posting, VAT, shipper AP posting, DVA/card allocation, credit ledger or accepted-estimate funding logic merely to fix display status drift.

Do not treat absence of a document as proof of completion. A lane closes only from a positive completion fact, an approved no-action closure fact, or a canonical rule explicitly approved in the governing pack.

## 10. Implementation sequence

```text
1. Add order_audience_status_v1 wrapper.
2. Add internal_order_status_drift_audit_v1.
3. Patch app/importer/page.tsx to consume the wrapper.
4. Patch app/importer/orders/[order_id]/operations/page.tsx to consume the wrapper.
5. Patch app/customer/orders/[order_id]/operations/page.tsx to consume the wrapper.
6. Re-check app/internal/supervisor-command-centre/page.tsx and app/internal/evidence/[order_id]/page.tsx for local drift.
7. Run drift audit across all active orders.
8. Only then continue with new workflow builds.
```

## 11. User-facing terminology exposure addendum

This addendum covers visible UI wording only. It does not change the canonical status engine, database schema, RPCs, routes, integrations, permissions, calculations or workflow gates.

### 11.1 Purpose

External and semi-external users must not be shown the names of internal vendors, accounting systems, automation tools, tax mechanics or implementation details unless the page is explicitly internal/staff-only and the wording is necessary for staff control.

This is a presentation-layer control. It must not be used to hide operational truth, change accounting treatment, change payment matching, alter evidence requirements, or weaken the audit trail.

### 11.2 No-functionality-change boundary

Allowed changes:

```text
- visible headings;
- visible labels;
- helper text;
- button text;
- warning text;
- badge text;
- downloadable README text;
- route response/error text shown to users;
- display-only sanitising of dynamic warning/note/status text already being rendered.
```

Prohibited changes:

```text
- renaming tables, columns, RPCs, functions, route folders, imports, adapters or environment variables;
- changing payment/funding/settlement logic;
- changing statement matching or allocation logic;
- changing document-read/OCR implementation logic;
- changing accounting-system posting logic;
- changing tax/VAT return logic;
- changing role permissions or RLS;
- changing canonical status calculations;
- changing workflow gates;
- changing database-stored historic evidence solely to make wording cleaner.
```

Internal code identifiers may retain implementation names where required for safe operation. The restriction is on user-visible text and downloadable/user-visible output.

### 11.3 Replacement map for visible UI text

The following visible terms must be replaced where they appear in customer, importer, shipper or generic staff-demo UI:

```text
Mindee                         -> document processor / document parser / document read
OCR                            -> document read / document extraction / statement extraction
PDF OCR control                -> PDF statement extraction / Statement document control
Run, fetch and parse statement OCR -> Run document read and parse statement
Sage / Sage Cloud              -> accounting system / finance system / accounting records
pre-Sage readiness             -> accounting readiness / posting readiness
Sage readiness                 -> accounting readiness
Sage posting                   -> accounting posting
posted to Sage                 -> posted to accounting records
Sage invoice ID                -> accounting document ID
Sage reference                 -> accounting reference
DVA/card                       -> payment account / statement account / collection account
DVA statement                  -> payment statement / collection statement
card line                      -> statement line / payment line
FX/card diff                   -> FX/payment variance
bank fee                       -> bank/payment fee
shipper AP invoice             -> shipper charge record / shipping charge document
AP invoice                     -> payable charge document / supplier charge record
posted shipper AP invoices     -> approved shipper charge records
supplier invoice               -> supplier charge document / retailer purchase document, depending context
sales invoice                  -> final order document / customer final invoice / shipment support document, depending audience
final balance                  -> remaining order balance, where customer/importer-facing
funding                        -> payment / order payment / payment received, where customer/importer-facing
Importer funding               -> Importer payment matching / Order payment matching
allocation                     -> matching / payment matching, where customer/importer-facing
VAT                            -> tax / compliance / statutory review, unless strictly internal tax-admin context
HMRC                           -> internal compliance authority wording only; not shipper/customer-facing
Box 1 / Box 4 / Box 6 / Box 7  -> tax return box values, internal-only
ledger                         -> account balance / account record, where user-facing
auth ref                       -> payment reference / reference
reconciliation                 -> matching / review / statement matching, where user-facing
```

### 11.4 Screenshot-specific replacements agreed in implementation

The following screenshot-visible wording must be replaced:

```text
Mindee direction out corrected to in...
-> Document direction corrected to inbound...

PDF OCR control
-> PDF statement extraction

Run, fetch and parse statement OCR
-> Run document read and parse statement

pre-Sage readiness
-> accounting readiness

Importer DVA/card allocation for supplier, refund, FX/card, fee and hold items
-> Importer payment matching for supplier charges, refunds, FX/payment variance, fees and hold items

Main company bank OUT lines matched to posted shipper AP invoices
-> Main company bank OUT lines matched to approved shipper charge records

FX/card diff
-> FX/payment variance

Allocate FX/card or bank fee
-> Allocate FX/payment variance or bank fee

Apply to final balance
-> Apply to remaining order balance

Confirm supplier allocation
-> Confirm supplier charge matching
```

### 11.5 Dynamic text sanitising rule

Some leaked wording may come from stored database warning strings, parser notes or audit messages rather than hardcoded page text. UI pages that render dynamic notes, warnings, parsed statement messages or status messages must pass those values through a display-only sanitiser before rendering.

Required helper pattern:

```text
cleanUiText(value)
```

Required behaviour:

```text
- accept string/null/undefined;
- return a display-safe string;
- replace banned visible terms using the replacement map;
- preserve numbers, dates, references and operational meaning;
- not mutate the underlying database value;
- not change business logic or matching decisions.
```

Example:

```text
Stored value: Mindee direction out corrected to in using balance-after movement.
Displayed value: Document direction corrected to inbound using balance-after movement.
```

### 11.6 Page-scope priority

Cleanup must proceed in this order:

```text
1. Shipper-facing pages and shipper downloadable/route output.
2. Customer-facing pages.
3. Importer/operator-facing pages.
4. Internal staff UI intended for screenshots/demo walkthroughs.
5. Downloadable evidence packs and route response text.
6. Repository docs/migrations only if surfaced in the app or demo pack.
```

### 11.7 Shipper-facing acceptance proof

For `app/shipper/**`, the following visible terms must not appear in rendered UI copy or user-visible route output:

```text
Mindee
OCR
Sage
Sage Cloud
pre-Sage
VAT
DVA
DVA/card
sales invoice
sales-invoices
shipper AP
AP invoice
```

Shipper-facing pages must remain focused on:

```text
- package receipt;
- package contents;
- shipment batch facts;
- shipping charge document upload/replacement;
- final export/COS/POD evidence;
- set-aside and return actions;
- approved shipper charge records;
- shipment document ZIP / support pack wording.
```

Shipper-facing pages must not show customer balance due, customer/importer next action, internal accounting-system names, tax-return language, payment-account mechanics or implementation-vendor names.

### 11.8 Audit requirement

A UI terminology audit script should be added before the wider cleanup is considered complete.

Expected behaviour:

```text
- scan UI-visible files first: app/**/*.tsx, app/**/*.ts route response text, src/**/*.tsx, components/**/*.tsx;
- report banned visible terms;
- allow explicit exceptions for internal implementation files, adapters, migrations, SQL, and docs not rendered in the app;
- fail or warn before release where banned terms appear in user-facing UI copy.
```

This audit must not force unsafe renaming of implementation identifiers.

### 11.9 Acceptance proof for terminology cleanup

The terminology cleanup is complete only when:

```text
- canonical status drift audit remains clean;
- no status/action/balance behaviour changes;
- app/shipper search returns no visible banned terms;
- customer/importer-facing pages are searched and patched next;
- internal/demo-facing pages are searched and patched after external pages;
- any remaining banned terms are documented as internal-code exceptions, not visible UI copy.
```
