# Importer Funding Canonical Statement Eligibility Addendum v1

**Status:** GOVERNING ADDENDUM — implementation scope locked; no runtime change authorised beyond this document's boundary  
**Scope:** `/internal/funding` statement-line actionability only  
**Principle:** economic eligibility must come from the existing canonical statement-line control; page-local reconciliation status is not economic availability authority

## 1. Objective

Correct the `/internal/funding` consumer boundary so that a DVA/card statement line can appear as actionable order funding only when the existing canonical statement-line control says funding is allowed.

This is not a new funding model, reconciliation model, FX model, allocation model, or accounting model. The canonical control already exists and is already correct. The defect is that `/internal/funding` still makes part of its actionability decision from the legacy funding worklist and legacy reconciliation-status fields instead of deferring to canonical economic-use truth.

## 2. Proven live defect

Controlled live read-only probes proved the following statement line:

- statement line: `f36b93f8-16aa-46f0-a92d-bebdd4b919c0`
- physical IN: `£20.19`
- confirmed `final_balance_payment`: `£19.99`
- confirmed `fx_card_difference`: `£0.20`
- canonical consumed: `£20.19`
- canonical reserved: `£0.00`
- canonical remaining: `£0.00`
- canonical overconsumed: `£0.00`
- active economic lanes: `final_balance_payment`, `fx_card_difference`
- principal lane count: `1`
- canonical `funding_action_allowed_yn`: `false`
- canonical control status: `controlled`

The same line simultaneously:

- remains present in `public.day2_dva_review_worklist_vw`;
- has no `order_funding` reconciliation;
- has no legacy reconciliation id exposed to the Funding page;
- does not have a legacy `match_status` of `reconciled` or `confirmed`;
- therefore passes the Funding page's current page-local "unused IN" test.

The live diagnosis returned:

> canonical control blocks funding but legacy funding worklist still exposes the line as unused.

This proves an application consumer mismatch, not a failure of the canonical control.

## 3. Confirmed root cause

`/internal/funding` reads `public.day2_dva_review_worklist_vw` as its statement-line working population.

Its current local `alreadyReconciled` logic is based on legacy funding reconciliation/status evidence. Its unmatched supervisor-assignment queue additionally checks direction, positive amount, importer presence, `!alreadyReconciled`, and absence of a strong match.

Those checks answer whether the old order-funding reconciliation path has already been used. They do **not** answer whether the physical statement money has already acquired another valid economic use through the broader statement-line allocation/control architecture.

The canonical resolver already answers that question. In particular, an active `final_balance_payment` lane is not funding-eligible.

The defect therefore exists because the Funding page bypasses the already-built canonical economic-eligibility decision when constructing actionable funding queues.

## 4. Governing authority

For statement-line funding actionability, the existing canonical authority is:

`public.internal_statement_line_control_resolver_v2(uuid)`

and its staff-safe/canonical projections, including the existing canonical statement-line control worklist/position objects where already established.

The authoritative funding decision is the existing canonical field:

`funding_action_allowed_yn`

The authoritative amount-control fields include the existing:

- `active_consumed_gbp`
- `active_reserved_gbp`
- `remaining_unconsumed_gbp`
- `overconsumed_gbp`
- `active_economic_lanes`
- `principal_lane_count`

No page-specific economic resolver, lane list, duplicate funding formula, or replacement status system may be created.

## 5. Required Funding-page behaviour

### 5.1 Hard eligibility must precede matching/ranking

The Funding page may continue using its existing worklist fields, order matching, reference matching, scoring, same-importer order choices, search, filters, labels and presentation.

However, a statement line must not enter an actionable funding queue unless canonical funding eligibility is true.

Canonical hard eligibility comes before advisory matching/ranking.

### 5.2 Both actionable funding queues are governed

The rule applies to both:

1. **Ready Funding**; and
2. **Supervisor Assignment Required**.

A line with canonical `funding_action_allowed_yn = false` must not appear as actionable in either queue.

The canonical gate must be applied to the Funding page's working statement-line population before Ready Funding, Supervisor Assignment Required, and the funding-specific non-actionable review bucket are derived. This prevents a canonically non-funding line from merely moving from an actionable card into the page's separate funding-review summary. Existing reconciled-funding audit evidence and raw diagnostics may continue to use the legacy population because they are non-actionable audit/readout surfaces.

### 5.3 Missing canonical authority must fail closed

If the Funding page cannot obtain a canonical control result for a statement line, that line must not be offered as an actionable funding candidate.

Do not fall back to the legacy `reconciliation_id` / `match_status` test as economic authority.

### 5.4 Legacy reconciliation fields remain metadata

Existing `reconciliation_id`, `match_status`, suggestion fields and audit display may remain in use for presentation, audit, ranking and compatibility behaviour.

They are not the authority for whether physical statement money remains economically available for a new funding action.

## 6. Amount rule

This addendum does **not** authorise a general rewrite of funding amounts.

The current Funding page submits the statement amount through the existing funding action/RPC path. For a genuinely unused funding receipt, canonical remaining should equal the physical receipt amount.

Therefore the implementation must first use canonical eligibility to prevent already-used/reserved/non-funding lines from becoming actionable.

Do not silently replace every submitted amount with `remaining_unconsumed_gbp` unless a separate controlled regression proves that partially consumed lines are intentionally permitted to remain funding-eligible under the existing canonical contract.

For the proven £20.19 defect, no amount rewrite is required: canonical funding eligibility is already false, so the line must be excluded from funding actionability entirely.

## 7. Proven positive control

A live read-only control also identified an unused IN line with:

- canonical consumed: `£0.00`
- canonical reserved: `£0.00`
- canonical remaining equal to the full physical receipt;
- no active allocations;
- no order-funding reconciliation;
- canonical `funding_action_allowed_yn = true`;
- presence in the legacy funding worklist.

That line passed the canonical funding eligibility control.

A separate search for a currently unused normal customer receipt with order/auth reference returned no rows. This means no such live production sample was available at the time of this addendum; it does not establish a failure of the canonical rule.

A simulated/controlled regression for a normal unused customer funding receipt is therefore mandatory before merge.

## 8. Required implementation boundary

The intended production code change is limited to the Funding-page consumer boundary necessary to enforce existing canonical funding eligibility.

Reuse the existing `public.internal_statement_line_control_worklist_v1(uuid,integer,integer)` staff-safe projection to obtain `funding_action_allowed_yn` for the legacy Funding-page statement-line IDs. Page through that existing RPC as required until the current legacy Funding-page population has either been resolved or the canonical worklist is exhausted. Missing canonical rows must fail closed.

The existing legacy funding worklist remains the source of suggestion/reference/display fields. Existing matching, scoring, same-importer order selection, funding amounts and audit metadata remain unchanged after the canonical admission gate.

The implementation must be fail-closed and must not invent a second resolver, a new database object, or page-local economic formulas.

## 9. Frozen scope — do not change

This addendum does **not** authorise changes to:

- `public.internal_statement_line_control_resolver_v2(uuid)` economics;
- `public.statement_line_control_position_v1` economics;
- `public.staff_reconcile_dva_line_to_order(...)`;
- the existing order-funding database guard/trigger;
- customer-IN funding+FX write logic;
- pending-surplus logic;
- final-balance allocation logic;
- `staff_classify_final_balance_in_fx_residual_v1`;
- the confirmed £19.99 final-balance allocation;
- the confirmed £0.20 FX/card allocation;
- retailer-refund logic;
- customer credit or importer credit economics;
- settlement calculations;
- Sage readiness, mappings, posting snapshots or posting payloads;
- VAT logic;
- supplier payment or supplier-invoice logic;
- shipper AP, shipping or allocation economics;
- loyalty economics;
- order progression/status logic;
- historical statement/reconciliation/allocation rows;
- UI navigation, permissions, labels, totals or layout except the minimum actionability wiring required by this addendum.

No unrelated cleanup or refactor is permitted.

## 10. Required regression gates before merge

Implementation is not complete unless regression proves all of the following:

1. The proven £20.19 line is absent from **Ready Funding** and **Supervisor Assignment Required** because canonical funding eligibility is false.
2. A controlled normal unused customer funding receipt remains actionable when canonical funding eligibility is true and the full receipt remains unused/unreserved.
3. A valid unused IN control remains actionable.
4. OUT lines are not actionable as funding.
5. Existing order-funded IN lines cannot be offered for reuse.
6. Active `final_balance_payment` lines cannot be offered for funding, including partially allocated residual cases.
7. Active retailer-refund, supplier-payment, loyalty and other canonically non-funding economic lanes remain excluded where governed by the resolver.
8. Reserved, blocked or overconsumed lines remain non-actionable.
9. Missing canonical authority fails closed.
10. Existing same-importer supervisor-assignment matching behaviour remains unchanged for genuinely eligible unused funding lines.
11. Existing Ready Funding matching/ranking remains unchanged after hard eligibility for retained lines.
12. Importer-credit behaviour remains unchanged.
13. Existing funding RPCs/actions and database guard remain byte-for-byte/functionally unchanged unless a separately proven defect requires a new addendum.
14. Final balance, FX, settlement, Sage, VAT, supplier, shipper and loyalty flows show no regression.
15. Canonically non-funding statement lines are not reintroduced into the Funding page's funding-specific non-actionable review summary; reconciled-funding audit and raw diagnostics remain unchanged.

Do not prove safety by clicking the known £20.19 production line. Use read-only/live comparison and controlled regression data.

## 11. Acceptance statement

The change is accepted only when `/internal/funding` behaves as follows:

> A statement line may be shown as actionable order funding only when the existing canonical statement-line control says funding is allowed. Matching and supervisor assignment remain advisory/application concerns after that hard eligibility decision. Already-consumed, reserved, blocked or otherwise non-funding money must never become actionable merely because the legacy funding reconciliation fields do not show an order-funding reconciliation.

For the proven £20.19 case, the required result is:

```text
£20.19 physical IN
→ £19.99 final_balance_payment confirmed
→ £0.20 fx_card_difference confirmed
→ canonical consumed £20.19
→ canonical remaining £0.00
→ funding_action_allowed_yn = false
→ absent from Ready Funding
→ absent from Supervisor Assignment Required
→ absent from funding-specific Needs Review
→ no accounting, FX, settlement, Sage, VAT, supplier, shipper, credit or historical record change
```

## 12. Implementation authorisation boundary

This document freezes the problem definition, authority chain, non-goals and acceptance tests.

It does **not** authorise broad database or accounting changes. The permitted implementation is the smallest Funding-page consumer change required to defer actionable statement-line admission to the existing canonical funding eligibility, followed by the regression gates above.