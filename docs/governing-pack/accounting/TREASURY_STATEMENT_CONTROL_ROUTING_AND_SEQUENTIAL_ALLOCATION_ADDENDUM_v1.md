# Treasury Statement Control, Routing and Sequential Allocation Corrective Addendum v1

Status: locked corrective governing addendum for implementation. This document does not itself change the live database, application, Sage, VAT or accounting data.

Source branch at drafting: `agent/bank-statement-routing-sequential-allocation-contract-v1`

Evidence basis:

- repository `main` at commit `700315a898dbfda4e6290cb815a7a169c0e1e5d8`;
- the visual treasury and cash-reconciliation assessment workbook `goodcashback_visual_treasury_control_review.xlsx`;
- the focused live incident extract for `ORD-1784498556959`;
- the live loyalty and amount-aware-control audit supplied on 22 July 2026.

## 1. Purpose

This addendum locks one coordinated, additive correction pack for every bank, DVA and card statement surface.

It addresses:

- incorrect or ambiguous routing between funding, supplier payment, refund, final balance, loyalty, shipper AP, fee, FX and exception lanes;
- the unsafe manual completion-loyalty release route;
- the absence of an audited effective-direction and classification correction layer;
- the absence of one read-only summary showing what happened to every physical statement line;
- the absence of one coherent order-level treasury position;
- the loss of sequential reuse of one supplier OUT across several invoices;
- suggestion logic that can hide eligible targets instead of merely ranking them;
- incomplete unmatched-line triage;
- inconsistent remaining-amount calculations across workbenches;
- incomplete import-void and funding-reversal controls;
- incomplete proof that repository SQL is deployed and used by every relevant page;
- incomplete live proof of cash-posting and Sage handoff by category.

The solution is not a replacement cash-reconciliation workflow. It is a narrow control layer around existing specialist controls.

## 2. Authority and precedence

This addendum extends and must be read with:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
2. `docs/governing-pack/ui/DVA_CARD_STATEMENT_CONTROL_WORKBENCH_V2_CONTRACT.md`
3. `docs/governing-pack/accounting/AMOUNT_AWARE_STATEMENT_LINE_CONTROL_CONTRACT_v1.md`
4. `docs/governing-pack/ui/DVA_RECONCILIATION_ACTION_CONTRACT.md`
5. `docs/governing-pack/ui/DVA_CARD_STATEMENT_IMPORT_WORKBENCH_CONTRACT_v1.md`
6. `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`
7. `docs/governing-pack/accounting/DVA_SUPPLIER_PAYMENT_SOURCE_AUTO_RESOLUTION_ADDENDUM_v1.md`
8. `docs/governing-pack/ui/COMPLETION_LOYALTY_REWARD_CASH_BACKED_CREDIT_ADDENDUM_v2.md`
9. `docs/governing-pack/ui/MAIN_BANK_LOYALTY_REWARD_FUNDING_INTEGRATION_ADDENDUM_v1.md`
10. `docs/governing-pack/ui/COMPLETION_LOYALTY_PAIRING_SUGGESTION_UI_ADDENDUM_v1.md`
11. the existing cash-posting, Sage posting, refund, exception and reversal contracts.

Where an older document assumes any of the following, this addendum controls:

- raw OCR direction alone determines routing;
- every importer-account IN belongs on the order-funding page;
- any active supplier allocation exhausts the entire physical OUT;
- one physical OUT may be allocated only atomically or to one invoice;
- the suggestion score may remove otherwise eligible targets;
- a description/direction error may be fixed by overwriting physical evidence;
- a committed import may be voided after checking only `dva_statement_line_allocations`;
- repository presence proves live deployment;
- a detailed `SECURITY DEFINER` resolver may be directly executable by all authenticated users;
- a manual loyalty funding reference is sufficient to release dashboard credit.

## 3. Confirmed evidence and non-speculative conclusions

### 3.1 Three-invoice incident

The focused live extract for `ORD-1784498556959` proved:

- one order exists with three supplier invoices totalling `GBP 884.96`;
- all three invoices were `pending_review`;
- the order had no confirmed funding at the time of the first extract;
- the funding gap was `GBP 884.96`;
- the incident IN line was correctly stored as `in`, amount `GBP 867.81`;
- the incident OUT line was correctly stored as `out`, amount `GBP 844.78`;
- both lines belonged to the importer DVA/card account;
- neither line had an allocation at the time of the extract;
- neither line had stored supplier match suggestions;
- the deployed funding worklist exposed both IN and OUT rows;
- the funding page's application scoring did not enforce direction before presenting a candidate;
- the deployed supplier suggestion function filtered by individual invoice amount, approved status, Sage block and retailer text before ranking;
- the strict single-invoice allocator required the entire physical OUT and rejected any existing active allocation;
- the atomic bundle required all selected allocations to equal the full OUT.

Therefore:

- the raw IN/OUT values were not inverted in this incident;
- the first incident was not caused by an existing allocation;
- the supplier invoices were not eligible because funding and approval gates had not cleared;
- the funding-page routing layer could still present an OUT as apparent funding because page scoring used references without a direction eligibility gate;
- the former sequential allocation path is unavailable by design in the deployed single and bundle routes.

### 3.2 Loyalty audit

The live audit proved:

- `staff_confirm_completion_loyalty_reward_funding_v1` remained `SECURITY DEFINER`;
- it remained executable by `authenticated`;
- the completion-loyalty page still called it through `confirmCompletionLoyaltyRewardFundingAction`;
- the modern paired functions and match table existed;
- the amount-aware resolver objects from PR #129 were absent live;
- one seed-labelled `GBP 10.00` manual-style release requires ledger tracing;
- one `GBP 13.50` `legacy_released_out_only` record is historical review evidence, not a modern-pairing failure.

These are implementation facts, not design assumptions.

## 4. Target operating model

```text
IMMUTABLE BANK EVIDENCE
Original statement file, OCR/raw amount, raw direction and raw description
                              |
                              v
AUDITED INTERPRETATION
Effective direction + economic classification + corrected display description
Original amount cannot be changed
                              |
                              v
AUTHORITATIVE STATEMENT-LINE POSITION
Account context + active principal lane + consumed + reserved + remaining
+ reversals + blockers + next action
                              |
                              v
HARD ELIGIBILITY
Importer/account context -> effective direction -> classification
-> funding provenance -> invoice/target approval -> remaining amounts
-> compatible existing economic use
                              |
                              v
ADVISORY RANKING
Reference/auth/retailer/date/amount/description/combined-invoice fit
Ranking orders choices; it does not remove hard-eligible choices
                              |
                              v
PRIMARY ECONOMIC MATCH
Funding | Supplier payment | Refund | Final balance
Loyalty | Shipper AP | Exception
                              |
                              v
AUXILIARY RESIDUAL
FX/card difference | Bank fee | Hold
                              |
                              v
REVERSAL AND ACCOUNTING
Surgical reversal -> controlled rematch
Fully explained evidence -> freeze -> batch -> Sage
```

## 5. Existing controls that must remain unchanged

The build must reuse and preserve:

- statement upload, format detection, OCR/parser staging, review and commit;
- immutable statement file and physical statement-line identity;
- separate `importer_dva_card_account` and `main_company_bank_account` contexts;
- `dva_reconciliation` as the order-funding write path;
- funding before supplier-payment matching;
- supplier-payment funding and provenance readiness;
- approved supplier-invoice and remaining-invoice checks;
- the strict full-OUT single-invoice route;
- the atomic one-OUT/multiple-invoice bundle route;
- `dva_statement_line_allocations` as the multi-target allocation layer;
- `staff_reverse_dva_statement_line_allocation(...)` for surgical allocation reversal;
- modern main-bank OUT plus same-importer destination-IN loyalty pairing;
- loyalty-specific reversal;
- separate refund, final-balance, FX, fee and exception allocations;
- source bank/wallet provenance on supplier allocations;
- cash-posting snapshot, freeze, validation, batch and category posting controls;
- Sage mapping through configuration rather than hard-coded external IDs;
- current VAT, customer-sales, shipment, hold, exception and supplier-approval logic.

No change in this pack may weaken those controls.

## 6. One authoritative statement-line interpretation layer

### 6.1 Raw evidence is immutable

The following remain physical evidence and must never be overwritten by a correction page:

- source statement file;
- `dva_statement_lines.amount_local_ccy`;
- `dva_statement_lines.amount_gbp_equivalent`;
- raw OCR/parser direction;
- raw OCR/parser description and reference;
- original statement date;
- source bank/account context;
- import-batch and import-link history.

An amount error is not an interpretation correction. It requires reversal of active uses, guarded void/supersession of the import, and re-upload.

### 6.2 Additive correction ledger

Add one small audited table, named `statement_line_interpretation_corrections` or an equivalent short name.

Minimum fields:

```text
id
statement_line_id
effective_direction
economic_classification
corrected_display_description
correction_reason
correction_status
created_by_staff_id
created_at
reversed_by_staff_id
reversed_at
reversal_reason
```

Rules:

- one active correction per physical statement line;
- status values are `active` and `reversed`;
- no amount column;
- no account-context override;
- no importer override;
- no direct browser writes;
- every write uses a staff-only `SECURITY DEFINER` RPC;
- original and effective values are always available side by side;
- reversing a correction restores the previous effective interpretation without deleting history.

### 6.3 Permitted economic classifications

Only existing lanes are permitted:

```text
customer_order_funding
supplier_payment
retailer_refund
final_balance_payment
bank_fee
fx_card_difference
completion_loyalty_source_transfer
completion_loyalty_destination_transfer
main_bank_shipper_ap
exception_control
unmatched_hold
```

No new accounting category is created by this addendum.

### 6.4 Context/direction matrix

```text
Importer DVA/card + effective IN
  customer_order_funding
  retailer_refund
  final_balance_payment
  completion_loyalty_destination_transfer
  exception_control

Importer DVA/card + effective OUT
  supplier_payment
  bank_fee
  fx_card_difference
  exception_control
  unmatched_hold

Main company bank + effective OUT
  main_bank_shipper_ap
  completion_loyalty_source_transfer
  bank_fee
  fx_card_difference
  exception_control
  unmatched_hold

Main company bank + effective IN
  no automatic business lane in this pack;
  route to controlled review until a separately governed purpose exists.
```

The RPC must reject an incompatible combination.

## 7. Statement interpretation correction page

Create one staff-only page opened from the existing Payment Control Hub:

```text
/internal/dva-reconciliation/statement-interpretation
```

The page is not a matching workbench.

It must show:

- statement line ID and source statement;
- account context and importer where applicable;
- raw direction;
- effective direction;
- raw description/reference;
- corrected display description;
- raw amount and currency, read-only;
- current economic classification;
- active consumed, reserved and remaining amount;
- active principal lane;
- linked funding, allocation, loyalty, shipper-AP and cash-posting evidence;
- previous corrections and reversals;
- blocker explaining why correction is or is not allowed.

Permitted actions:

- create effective direction/classification/description correction;
- reverse the active correction;
- open the exact active economic-use row that must be reversed first;
- open the statement-line summary.

Guardrails:

- admin or supervisor only;
- mandatory reason of at least eight characters;
- no amount parameter;
- no account-context parameter;
- no importer parameter;
- no correction while an active principal economic use exists;
- no correction while an active loyalty reservation/pair exists;
- no correction while an active shipper-AP allocation exists;
- no correction while an active allocation exists;
- no correction while an unreversed order-funding reconciliation exists;
- no correction while an active cash snapshot, frozen batch row or posted Sage result exists;
- unposted accounting evidence must be retired/superseded through its governed path first;
- a Sage-posted line requires an accounting correction process, not a silent interpretation edit;
- unaccepted suggestions may be invalidated and regenerated after correction;
- accepted economic use must be reversed before correction.

## 8. Hardened amount-aware resolver

PR #129 must not be deployed unchanged.

The corrected implementation must:

1. read raw physical evidence;
2. read the active interpretation correction, if any;
3. expose both raw and effective direction;
4. expose raw and corrected display description;
5. use effective direction and economic classification for routing validation;
6. sum active consumption and reservation by amount;
7. count principal economic lanes, not raw evidence-table families;
8. treat linked documentary rows as evidence, not second consumption;
9. treat reversed rows as historical;
10. preserve explicit legacy loyalty statuses as historical review;
11. expose all usage evidence to staff-safe consumers;
12. expose consumed, reserved, remaining and overconsumed amounts;
13. expose blocker and next action;
14. become the common position source for every bank/DVA/card page;
15. guard order-funding inserts at database level.

### 8.1 Security

The detailed private resolver must not be directly executable by `PUBLIC`, `anon` or unrestricted `authenticated`.

Required pattern:

```text
private/base resolver
  -> no direct public execution
  -> callable by triggers/private helpers

staff-safe read model/RPC
  -> authenticated active staff only
  -> tenant/importer scope enforced where relevant
  -> paginated/filterable output
```

A direct authenticated grant is acceptable only when the function itself proves active staff access and applicable tenant scope before returning usage evidence.

### 8.2 Required public view integration

The implementation is incomplete unless all relevant existing public names consume the hardened position:

- funding worklist;
- DVA allocation summary;
- unmatched triage;
- DVA workspace line list;
- review pack;
- main-bank line remaining;
- completion-loyalty destination-IN candidates;
- import-void guard;
- new statement-line summary;
- new order treasury position.

Creating resolver objects without rewiring these consumers is not completion.

## 9. Statement-line control summary

Create one read-only page:

```text
/internal/dva-reconciliation/control-summary
```

Purpose:

```text
Show what happened to every committed physical bank/DVA/card statement line.
```

Minimum line card fields:

- statement-line ID;
- source statement/batch link;
- account context;
- importer or main-bank label;
- statement date;
- source bank;
- raw direction;
- effective direction;
- raw description;
- corrected display description;
- local amount/currency;
- GBP control amount;
- effective economic classification;
- active principal lane;
- active consumed amount;
- active reserved amount;
- remaining unconsumed amount;
- overconsumed amount;
- active allocation count;
- historical/reversed row count;
- control status;
- blocker;
- next action;
- funding reconciliation link;
- supplier/refund/final-balance/fee/FX/hold allocation links;
- loyalty source/destination match links;
- shipper AP link;
- cash snapshot/freeze/batch/Sage status;
- interpretation-correction history.

Required filters:

```text
account context
importer
date range
source bank
raw direction
effective direction
economic classification
open / part allocated / balanced / blocked / review / voided
active / historical
text/reference
```

Visual states:

```text
unmatched/open
part allocated
balanced/controlled
held/reserved
blocked/integrity issue
historical/voided
```

This page is the authoritative read-only audit surface. It does not replace specialist action pages.

## 10. Order treasury position

Create one read-only order-level control view and page/section, for example:

```text
/internal/dva-reconciliation/order-money
```

It must not collapse unlike economic lanes into one misleading net number.

For each order it must show five separate control equations.

### 10.1 Funding position

```text
accepted-estimate funding requirement
- confirmed customer/order funding IN
- applied normal credit
- applied released loyalty credit
= remaining funding gap
```

### 10.2 Supplier-payment position

```text
approved supplier invoice total
- confirmed supplier-payment OUT allocations
= supplier invoices remaining unmatched
```

Each supplier invoice remains separate.

### 10.3 Statement-line explanation position

```text
physical statement amount
- active consumed amount
- active reserved amount
= unexplained statement amount
```

### 10.4 Refund/exception position

```text
approved refund/credit outcome
- matched retailer refund receipts
= outstanding cash refund evidence
```

Operational exception status remains separate from cash receipt.

### 10.5 Customer final-settlement position

```text
final sale value
- accepted-estimate funding/credits already applied
- final-balance receipts
= final balance due
```

The page must also show:

- linked IN and OUT lines;
- fees and FX residuals separately;
- holds and unresolved amounts;
- active and reversed evidence;
- cash-posting/Sage status;
- links to exact orders, invoices, disputes and statement lines.

This resolves the assessment gap without changing accounting writes.

## 11. Payment Control Hub and routing

The current hub remains the entry point but must route from the hardened resolver, not raw direction alone.

Top-level queues:

```text
Needs interpretation
Funding
Supplier payments
Retailer refunds
Final balances
Main-bank shipper AP
Completion loyalty
Fees / FX / holds
Unmatched / investigation
Blocked integrity
Audit / historical
```

Rules:

- ordinary importer-account IN must not automatically route to Funding;
- `customer_order_funding` routes to Funding;
- `retailer_refund` routes to refund/dispute matching;
- `final_balance_payment` routes to final-balance targets;
- `completion_loyalty_destination_transfer` routes to the loyalty pairing queue;
- importer OUT routes to supplier/fee/FX/hold based on classification and eligibility;
- main-bank OUT routes to shipper AP, loyalty source or residual based on classification;
- unclassified lines route to `Needs interpretation`;
- incompatible or overconsumed lines route to `Blocked integrity`;
- review-pack shipper labels remain advisory only and never become posting proof.

The hub must show queue counts and the exact reason for each route.

## 12. Funding page

The funding page must receive only lines for which the hardened resolver permits funding.

Minimum requirement:

```text
account context = importer_dva_card_account
effective direction = in
classification = customer_order_funding
remaining unconsumed amount > 0
no incompatible active principal lane
no amount integrity blocker
```

Reference/auth/order scoring remains advisory.

The page must not present:

- supplier OUT;
- retailer refund IN;
- final-balance IN;
- loyalty destination IN;
- main-bank lines;
- fully consumed lines;
- voided lines.

The order-funding RPC and database trigger remain the final write guards.

## 13. Loyalty lockdown

### 13.1 Remove unsafe application route

The application patch must:

1. remove `FundingForm` from the completion-loyalty page;
2. remove `confirmCompletionLoyaltyRewardFundingAction`;
3. remove the application call to `staff_confirm_completion_loyalty_reward_funding_v1`;
4. replace the manual form with a link to the existing main-bank completion-loyalty pairing queue.

### 13.2 Close direct database execution

Before changing the function, extract live:

- `pg_get_functiondef`;
- owner;
- ACL;
- dependency/call chain;

for:

```text
staff_confirm_completion_loyalty_reward_funding_v1
staff_stage_main_bank_line_to_completion_loyalty_v2
staff_pair_loyalty_destination_in_and_release_v1
staff_pair_loyalty_funding_pot_and_release_v1
```

Then:

- revoke execute from `PUBLIC`, `anon` and `authenticated` on the old manual function;
- make any direct call fail closed;
- do not break modern paired functions if they currently call shared release logic;
- move shared release logic to a private helper when necessary;
- require the exact paired-match ID;
- lock and validate source OUT;
- lock and validate destination IN;
- require same importer;
- require active paired state;
- require exact release amount within remaining capacities;
- prevent previous/duplicate release.

### 13.3 Historical loyalty evidence

- `legacy_released_out_only` is shown once as AMBER historical review;
- explicit legacy OUT-only status is excluded from modern-pairing failure counts;
- it is not silently upgraded to paired release;
- the `GBP 10.00` seed-labelled release must be traced through credit lot, debits/applications, `order_funding_events` and current unused balance;
- unused seed value is corrected with auditable compensating/reversal records;
- used seed value retains ledger history and receives controlled correction;
- no deletion of ledger history.

## 14. Supplier-payment target visibility

The supplier workspace must show:

```text
Suggested
All eligible
Blocked invoices
Manual classification
```

### 14.1 Suggested

Shows hard-eligible invoices ordered by advisory score.

### 14.2 All eligible

Shows every invoice that passes hard controls even when score is low or absent.

A low score must never remove a hard-eligible invoice.

### 14.3 Blocked invoices

Shows disabled rows with the exact blocker, including:

```text
supplier_invoice_not_approved_current
order_not_fully_funded
funding_provenance_not_ready
supplier_invoice_total_missing_or_non_positive
supplier_invoice_fully_matched
incompatible_statement_line_use
statement_line_remaining_insufficient
```

Blocked rows must not become selectable.

### 14.4 Manual classification

Opens interpretation/triage controls. It does not bypass invoice approval, funding, importer, amount or source-provenance rules.

## 15. Ranking and suggestion contract

### 15.1 Hard eligibility may filter

Only objective controls may remove a target:

- account context;
- effective direction;
- economic classification;
- importer;
- active staff/tenant access;
- funding threshold;
- funding provenance;
- supplier-invoice approval;
- target status;
- remaining statement amount;
- remaining target amount;
- same-order/importer/retailer or same-shipper requirements;
- incompatible active principal use;
- active hold where governed;
- reversed/voided status;
- freeze/posting restrictions.

### 15.2 Soft evidence only ranks

The following affect score and explanation only:

- order/payment-auth reference;
- retailer/merchant text;
- corrected display description;
- transaction date proximity;
- amount similarity;
- individual invoice fit;
- combined invoice fit;
- description-token similarity;
- prior accepted merchant aliases.

Required labels:

```text
Strong
Review
Manual eligible
No eligible target
```

The score explanation must be visible.

### 15.3 Multi-invoice amount fit

Supplier suggestion logic must consider:

- individual remaining invoice amounts;
- combined remaining invoice value for the same order/retailer;
- user-selected combination total;
- physical OUT remaining amount.

It must not require the whole OUT to be within a small tolerance of each invoice individually before displaying otherwise eligible invoices.

### 15.4 Suggestion lifecycle

- corrections, reversals, voids, target approval changes and remaining-amount changes invalidate stale unaccepted suggestions;
- suggestion regeneration does not create accounting use;
- accepting a target still calls only the specialist write RPC;
- suggestions never release loyalty credit or post accounting.

## 16. Three supplier-payment routes

### 16.1 Strict single-invoice route

Preserve the existing route:

```text
one untouched physical OUT
-> one approved invoice
-> full physical OUT amount
```

Do not weaken it.

### 16.2 Atomic multi-invoice bundle

Preserve the existing route:

```text
one untouched physical OUT
-> several approved invoices
-> same order/importer/retailer
-> selected total equals full OUT
-> all-or-nothing insert
```

Do not weaken it.

### 16.3 Incremental sequential fallback

Add a separate short-named RPC, for example:

```text
staff_allocate_supplier_out_increment_v1
```

Required behavior:

- lock the physical statement line;
- lock the selected supplier invoice;
- read the hardened resolver inside the transaction;
- require importer DVA/card account;
- require effective direction `out`;
- require classification `supplier_payment`, or a controlled unclassified-to-supplier action that records the classification atomically;
- repeat `internal_supplier_payment_readiness_v1(order_id)`;
- require the invoice to be approved/selectable;
- require amount greater than zero;
- require amount not greater than statement remaining;
- require amount not greater than invoice remaining;
- permit reuse only where all existing active principal allocations on the OUT are `supplier_invoice`;
- require all supplier allocations on the OUT to belong to the same order, importer and retailer;
- prevent adding supplier allocations after a final residual allocation has closed the line;
- resolve source bank/wallet only on the first supplier allocation;
- copy the first allocation's exact source mapping to every later allocation;
- reject any mapping inconsistency;
- retain the existing active `(statement line, supplier invoice)` duplicate guard;
- lock the line before calculating remaining to prevent concurrent over-allocation;
- return the new statement remaining and invoice remaining;
- keep the line selectable while remaining exceeds `GBP 0.01`;
- show part-allocated state rather than unmatched;
- permit a final FX/card, bank-fee or hold residual only after at least one supplier allocation.

The new route does not replace the strict or atomic routes.

## 17. Unmatched and manual triage

The existing unmatched page must become a complete operational queue.

It must support, through existing or governed specialist routes:

- generate/regenerate suggestions;
- open `All eligible`;
- open the interpretation correction page;
- route to supplier payment;
- route to retailer refund;
- route to final balance;
- route to main-bank shipper AP;
- route to completion loyalty;
- classify standalone bank fee;
- classify FX/card residual only when its primary-use prerequisite is satisfied;
- place an unmatched hold/query with reason;
- open related order/invoice/dispute evidence;
- reverse an incorrect active use;
- open import void only after all active uses are cleared.

It must never manufacture cash, supplier invoices, refunds or accounting explanations.

## 18. Reversal controls

### 18.1 Allocation reversal

Keep `staff_reverse_dva_statement_line_allocation(...)`.

It must continue to:

- reverse one row only;
- require admin/supervisor;
- require a reason;
- preserve the physical statement line;
- restore statement and target remaining amounts;
- retain reversal history.

Test it for supplier invoice, retailer refund, final balance, FX, fee and hold allocations.

### 18.2 Order-funding reversal

Add a governed order-funding reversal route because allocation reversal does not reverse `dva_reconciliation`.

Required behavior:

- active admin/supervisor only;
- lock the funding reconciliation, order, linked funding event and related credit provenance;
- preserve the original reconciliation row and amount;
- record reversed status, staff, timestamp and reason through the smallest live-compatible additive structure;
- reverse or compensate the linked `order_funding_events` contribution exactly once;
- recompute funding total, gap and `funded_at`;
- reverse unused overfunding credit created by that reconciliation;
- block when related credit has been applied or otherwise consumed until downstream use is reversed;
- block when supplier allocations depend on that funding until those allocations are reversed;
- block when active/frozen/posted cash-posting evidence depends on the funding until the accounting lane is retired or corrected;
- make the resolver treat the reconciliation as historical, not active consumption;
- permit a later correct reconciliation only through an audited active-row uniqueness model;
- never delete the original reconciliation, funding event or credit history.

The exact table/index patch must be chosen only after extracting the deployed reconciliation constraint, trigger and funding-event helper definitions.

## 19. Import void and replacement

The existing import void path is retained but its guard is incomplete if it checks only `dva_statement_line_allocations`.

The corrected void guard must use the hardened resolver and block when any linked line has:

- active order-funding reconciliation;
- active supplier/refund/final-balance/fee/FX/hold allocation;
- active loyalty source reservation or destination pair;
- active shipper-AP allocation;
- active cash snapshot/freeze/batch/posting evidence;
- incompatible or overconsumed state requiring investigation.

Required sequence for an incorrect amount:

```text
reverse downstream accounting, if any
-> reverse economic allocations/matches
-> reverse funding reconciliation, if any
-> verify every linked line has zero active consumed/reserved amount
-> void/inactivate the import links with reason
-> retain source file, rows and audit history
-> upload and commit the corrected statement
```

The same active fingerprint may be re-imported only after the earlier link is inactive/voided.

No physical line is deleted.

## 20. Main-bank remaining amount

The hardened resolver becomes the only authoritative remaining amount for main-bank lines.

The current UI may temporarily compare the new position with legacy arithmetic as a regression assertion, but it must not calculate availability from two competing models.

Required outcome:

```text
main-bank remaining
= physical amount
- active shipper AP
- active loyalty source reservation/release
- active FX/fee/hold residual
```

If legacy and resolver values disagree:

- block action;
- show an integrity error;
- do not choose the lower or higher value silently;
- investigate and correct the read model.

Shipper AP remains one counterparty/shipper per physical payment.

## 21. Accounting, cash posting and Sage boundary

No accounting row may be frozen until:

- the statement line is committed and active;
- interpretation is controlled;
- the primary economic use is confirmed;
- required residual is classified or held;
- consumed plus reserved does not exceed physical amount;
- required supplier/refund/final-balance/loyalty/shipper evidence exists;
- no incompatible principal lane exists;
- source bank/wallet mapping is valid;
- the line/category is not blocked by reversal or correction.

The statement-line summary must show:

```text
not ready
ready to freeze
frozen
batched
approved
posted
failed/review
retired/superseded
```

Interpretation correction and import void are blocked after freeze until unposted accounting evidence is retired/superseded.

Posted Sage entries require the governed Sage/accounting correction route.

This addendum does not:

- change VAT timing;
- change VAT return source snapshots;
- change customer sales posting;
- change supplier invoice values;
- roll FX into the next invoice;
- create a new posting engine;
- hard-code Sage IDs.

Before pilot, each existing category must pass a live-safe endpoint/feature-flag proof:

- customer receipt/order funding;
- supplier invoice payment;
- retailer refund receipt;
- final-balance receipt;
- bank fee;
- FX/card difference;
- shipper invoice payment;
- completion-loyalty applied settlement;
- completion-loyalty internal transfer where that lane is enabled.

## 22. Security and audit requirements

Every new write RPC must:

- be `SECURITY DEFINER`;
- set `search_path = public, pg_temp`;
- derive staff from `auth.uid()`;
- require active admin/supervisor unless a stricter role is governed;
- reject browser-supplied staff IDs;
- lock all affected rows before calculating remaining amounts;
- validate tenant/importer/account context;
- require reason for correction/reversal/void/hold;
- return an auditable result payload;
- revoke execute from `PUBLIC` and `anon`;
- grant only the minimum required execution path;
- remain within PostgreSQL identifier limits.

Read-only detailed evidence must be staff/tenant scoped.

## 23. Required implementation sequence

No live order correction begins until the contract is merged.

### Phase 0 — live preflight

Extract and retain:

- manual and paired loyalty function definitions, owners and ACLs;
- reconciliation unique constraints, triggers and funding-event helpers;
- deployed candidate/funding/summary/main-bank view definitions;
- deployed cash snapshot and posting dependencies;
- current import-void function definition;
- current resolver absence/presence.

### Phase 1 — loyalty lockdown

- remove manual UI/action;
- close direct old-function execution;
- preserve modern pairing;
- correct audit classification;
- trace seed release.

### Phase 2 — interpretation correction

- add correction ledger;
- add create/reverse RPCs;
- add correction page;
- preserve raw evidence.

### Phase 3 — hardened resolver and shared views

- add effective fields;
- harden access;
- deploy amount-aware usage/position;
- rewire every listed consumer;
- add database-level funding guard;
- update import-void guard to use all economic lanes.

### Phase 4 — read-only visibility

- statement-line control summary;
- order treasury position;
- Payment Control Hub queue routing;
- blocked invoice visibility;
- unmatched triage visibility.

### Phase 5 — write fallbacks

- incremental supplier allocator;
- governed funding reversal;
- stale-suggestion invalidation;
- residual sequencing.

### Phase 6 — accounting parity

- main-bank remaining becomes resolver-authoritative;
- cash-posting category parity;
- freeze/batch/Sage live-safe proof.

### Phase 7 — regression and incident retest

- automated SQL regression;
- application build;
- CI;
- live read-only verification;
- controlled test data reversal/re-upload;
- exact incident walkthrough.

Do not combine all phases into one unreviewable migration.

## 24. Comprehensive acceptance tests

### A. Statement evidence and interpretation

1. Raw amount, raw direction and raw description never change after correction.
2. Effective direction/classification changes only through the correction RPC.
3. Correction has no amount parameter.
4. One active correction per line.
5. Correction reversal restores prior effective interpretation.
6. Correction is blocked by active funding.
7. Correction is blocked by active allocations.
8. Correction is blocked by active loyalty pairing.
9. Correction is blocked by active shipper AP.
10. Correction is blocked by frozen/posted accounting.
11. Unaccepted suggestions become stale/regenerated after correction.
12. Context/direction matrix rejects invalid classification.

### B. Resolver and summary

13. Every committed active line appears once in the control summary.
14. Voided lines appear only in historical/audit filters.
15. Consumed, reserved and remaining equal the sum of active evidence.
16. Reversed evidence is historical and does not consume amount.
17. Documentary cash snapshots do not double-consume.
18. Linked loyalty confirmation does not double-consume the destination IN.
19. Several supplier invoice allocations remain one principal supplier-payment lane.
20. Funding plus valid FX surplus remains one principal funding lane plus auxiliary residual.
21. Incompatible principal lanes block action.
22. Overconsumption blocks action.
23. Every line shows blocker and next action.
24. Order treasury position reconciles its five separate equations.

### C. Funding and inbound routing

25. Genuine customer funding IN appears in Funding.
26. Supplier OUT does not appear in Funding.
27. Retailer refund IN does not appear in Funding.
28. Final-balance IN does not appear in Funding.
29. Loyalty destination IN does not appear in Funding.
30. Main-bank lines do not appear in Funding.
31. Partial funding reduces only the funding gap.
32. Exact funding stamps funded state.
33. Accidental overfunding is blocked unless expressly allowed.
34. Explicit overfunding uses the existing credit provenance.
35. Funding reversal restores gap and funded state without deletion.
36. Used overfunding credit blocks funding reversal until downstream reversal.

### D. Supplier payment

37. Strict full-OUT single-invoice route remains unchanged.
38. Atomic bundle remains all-or-nothing.
39. Incremental allocation can apply one OUT to invoice A.
40. The same OUT remains selectable with the correct remaining amount.
41. Incremental allocation can then apply to invoices B and C.
42. Cross-order incremental allocation is blocked.
43. Cross-importer incremental allocation is blocked.
44. Cross-retailer incremental allocation is blocked.
45. Unfunded order is blocked.
46. Unapproved invoice is blocked.
47. Amount above line remaining is blocked.
48. Amount above invoice remaining is blocked.
49. Concurrent calls cannot over-allocate.
50. Duplicate same-line/same-invoice active allocation is blocked.
51. Later allocations inherit the first source bank/wallet mapping.
52. Mapping disagreement blocks.
53. FX/card residual is permitted only after a supplier allocation.
54. Final residual closes the line.
55. Reversing one supplier allocation restores only that amount.
56. Part-allocated line shows amber/remaining, not unmatched.

### E. Suggestions and visibility

57. Suggested tab orders eligible invoices by score.
58. All eligible includes low/no-score eligible invoices.
59. Blocked invoices remain visible and disabled with blocker.
60. Merchant mismatch lowers score but does not remove eligible invoice.
61. Reference match raises score but cannot bypass direction.
62. Combined multi-invoice fit is considered.
63. Stale suggestions do not survive changed approval/remaining/correction state.
64. Manual classification never bypasses hard controls.

### F. Loyalty

65. Manual FundingForm is absent.
66. Manual server action is absent.
67. Direct old-function execution fails.
68. Modern source OUT staging works.
69. Same-importer destination IN pairing works.
70. Different-importer pairing is blocked.
71. Duplicate release is blocked.
72. One funding pot can release several same-importer rewards within capacity.
73. No FX is created inside loyalty.
74. `legacy_released_out_only` appears once as historical AMBER.
75. Seed-labelled GBP 10 release is traced and corrected without deletion.

### G. Refund, final balance, fee, FX and exception

76. Refund IN routes to the refund target, not funding.
77. Final-balance IN routes to final balance.
78. Standalone bank fee can be classified with evidence.
79. Supplier FX residual requires primary supplier allocation.
80. No refund cash is invented from an operational outcome.
81. Unmatched hold preserves remaining evidence and blocks accounting.
82. Reversal restores the exact line/target balance.

### H. Import replacement

83. Import void is blocked by active funding.
84. Import void is blocked by active allocation.
85. Import void is blocked by loyalty use.
86. Import void is blocked by shipper AP.
87. Import void is blocked by frozen/posted accounting.
88. After all dependent reversals, void inactivates links and preserves history.
89. Corrected amount is introduced only by re-upload.
90. Duplicate fingerprint can be re-imported only after prior active link is voided.

### I. Main bank and accounting

91. Main-bank availability comes from one resolver position.
92. Legacy/resolver disagreement blocks action.
93. One main-bank payment cannot span several shippers.
94. Shipper AP flow is unchanged.
95. Cash freeze requires controlled source evidence.
96. Failed Sage posting remains reviewable.
97. Posted evidence cannot be silently corrected/voided.
98. No VAT behavior changes.
99. No customer-sales behavior changes.
100. No statement amount is edited.

## 25. Canonical live incident retest

After all preceding phases pass, use `ORD-1784498556959` or a clean equivalent test order.

Required sequence:

1. inspect the funding reconciliation created after the original test click;
2. prove no downstream supplier allocation, credit use, frozen cash snapshot or Sage posting depends on it;
3. reverse the funding through the new governed funding-reversal route;
4. verify order funding returns to the correct gap;
5. verify the original statement lines return to controlled/historical state;
6. void the original import only after every linked line has zero active use;
7. retain the original file and audit history;
8. upload a corrected statement whose amounts are supported by the actual source evidence and FX treatment;
9. commit the corrected rows;
10. fund the order with the correct IN;
11. approve the supplier invoices;
12. allocate the supplier OUT using strict, atomic or incremental route as appropriate;
13. use incremental allocation across the three invoices when testing sequential behavior;
14. classify only genuine remaining value as FX/card, fee or hold;
15. confirm the statement-line summary, order treasury position and cash-posting queue agree;
16. do not post to Sage until the test is fully reconciled and approved.

The corrected statement amount is derived from genuine source evidence. It is not manufactured merely to make the test balance.

## 26. Completion criteria

This corrective pack is complete only when:

- the addendum is merged into the locked governing pack;
- every required live preflight definition is retained;
- manual loyalty release is closed at UI and database level;
- raw evidence remains immutable;
- interpretation correction is audited and reversible;
- the hardened resolver is deployed and staff-safe;
- every listed workbench consumes the same statement-line position;
- the control-summary and order-treasury pages exist;
- funding routing excludes non-funding lanes;
- Suggested, All eligible and Blocked views work;
- sequential supplier allocation works without weakening strict/atomic routes;
- funding and allocation reversals are controlled;
- import void checks every active economic lane;
- main-bank remaining is authoritative and singular;
- all 100 acceptance checks pass or are explicitly marked not applicable with evidence;
- application build and CI pass;
- live views/functions are verified after deployment;
- the canonical incident retest passes before any Sage posting.

## 27. Non-goals

This addendum does not:

- rebuild statement import;
- replace `dva_reconciliation`;
- replace `dva_statement_line_allocations`;
- replace supplier-payment readiness;
- merge funding and supplier payment;
- create a new loyalty workspace;
- change shipper AP;
- change supplier invoices or invoice totals;
- change order funding thresholds;
- change VAT;
- change customer sales;
- create a new FX/fee engine;
- allow statement amount edits;
- delete historical evidence;
- treat repository files as proof of live deployment.

## 20. Unified funding and supplier-allocation clarification

Funding has three valid, explicit outcomes: exact funding, immediate FX classification when the existing FX confirmation is selected, or a neutral pending-surplus determination when an entered receipt exceeds the order gap without FX confirmation. Evidence must precede every non-FX surplus classification and any resulting customer credit.

The physical statement line remains immutable. Its governed uses may be multiple, but their confirmed total must never exceed its remaining physical balance. Supplier allocations are applied sequentially in the main importer-matching workspace, with each invoice leg independently auditable and reversible. Database transaction atomicity is a commit property; it is not a separate operator workflow or navigation lane.
