# IMPORTER FUNDING UNMATCHED IN SUPERVISOR FALLBACK ADDENDUM v1

## Status

Build contract for the Importer Funding Control page only.

## Objective

Expose the existing safe order-funding reconciliation route for unmatched customer/importer inbound statement money when the bank text does not contain the platform order reference or payment-auth reference.

The change must allow an authenticated admin or supervisor to select the correct same-importer open order, preview the funding/surplus split, and submit through the existing funding RPC path.

## Proven live defect

An inbound statement line can be valid customer/importer funding but remain non-actionable when:

- the statement line is positive IN money;
- the importer is known;
- the statement line is unused and unmatched;
- no strong platform order reference or payment-auth reference appears in bank text;
- multiple same-importer orders may exist, so automatic selection is unsafe.

The current page reduces these rows to a non-actionable summary rather than providing the existing controlled manual assignment route.

## Governing existing architecture

The build must reuse without changing behaviour:

- `public.day2_dva_review_worklist_vw` for inbound review rows;
- `public.order_funding_position_vw` for order funding positions and live gaps;
- `public.staff_reconcile_dva_line_to_order` for normal funding;
- `public.staff_reconcile_dva_line_to_order_pending_surplus_v1` when the entered IN exceeds the positive live order gap;
- `public.staff_reconcile_dva_line_to_order_customer_fx_gain_v1` only when the existing explicit FX-gain confirmation is used;
- the existing `reconcileDvaLineToOrderAction` server action for authentication, role enforcement, RPC selection, revalidation and success/error reporting.

No new reconciliation table, funding event path, credit path, allocation lane, accounting route or Sage behaviour is permitted.

## Page placement

Preserve the existing page order and styling.

The working sections become:

1. Ready inbound statement money.
2. Unmatched inbound statement money requiring supervisor assignment.
3. Ready importer credit.
4. Non-actionable rows summary.

The new section must sit immediately after `1. Ready inbound statement money` and before importer credit.

The existing header, summary metrics, Funding Boundary panel, audit, diagnostics and control-boundary content remain in place.

## New section behaviour

### Eligible rows

Show only rows that satisfy all of the following:

- statement line id exists;
- direction is `in`;
- positive GBP equivalent amount;
- not already reconciled or confirmed;
- no existing safe order match meeting the current automatic threshold;
- importer id exists.

Do not surface OUT rows, already-reconciled rows, zero/negative rows or rows already in the ready automatic queue.

### Order choices

For each eligible IN row, list only orders from `order_funding_position_vw` where:

- importer id exactly matches the statement line importer id;
- order id exists;
- live gap is positive;
- order is not already funded.

The UI may rank choices for convenience using existing evidence such as retailer text, amount proximity, order reference, payment-auth reference and recency, but it must not auto-select an order unless the existing safe automatic threshold is already met. The supervisor remains accountable for the fallback choice.

### Display

Each fallback card must show:

- statement date;
- raw bank reference;
- statement amount;
- importer identity or importer id;
- statement line id;
- selectable same-importer open order;
- selected order reference;
- selected order live funding gap;
- preview of amount applied to funding;
- preview of residual pending surplus when statement amount exceeds the selected order gap.

### Submission

Submission must post through the existing `reconcileDvaLineToOrderAction` using:

- full statement amount as `reconciled_gbp_amount`;
- selected order id;
- selected order live gap as `gap_remaining_gbp`;
- no match suggestion id unless a proven existing suggestion belongs to that exact line and order;
- an audit note identifying supervisor manual assignment from unmatched IN review.

When statement amount exceeds the selected positive order gap and no FX confirmation is supplied, the existing action must call `staff_reconcile_dva_line_to_order_pending_surplus_v1`.

## Filters

Add a compact page-level filter above the working queues using URL search parameters only.

Required controls:

- importer: all or a specific importer id;
- queue: all, ready funding, unmatched IN review, ready credit;
- search: order reference, payment-auth reference, statement reference, retailer text or statement line id.

Filtering must be read-only presentation logic. It must not alter candidate eligibility, scoring, RPC routing or database state.

## Credit correction

The page must not create actionable importer-credit cards from `importer_balance_vw.available_credit_gbp` when the canonical eligible normal credit-lot function returns no spendable lots.

The build must use the canonical normal-account-credit source-lot result for actionable credit availability. Completion-loyalty, restricted, consumed, historical or otherwise ineligible balances must not power an Apply Credit form.

If practical access to the canonical lot function cannot be achieved safely from the existing server component without a database object or RPC change, stop that part of the build and preserve the current credit action rather than inventing a new credit calculation. The unmatched-IN fallback remains independently buildable.

## Explicitly untouched

Do not change:

- automatic match scores or thresholds;
- existing ready funding cards;
- existing funding RPC definitions;
- pending-surplus classification rules;
- FX-gain confirmation rules;
- supplier OUT matching;
- retailer refund allocation;
- exception/hold allocation;
- final-balance allocation;
- credit ledger data;
- order totals, funding totals or status rules;
- permissions;
- navigation outside the funding page;
- Sage posting or readiness behaviour;
- wording or styling outside the minimum new fallback/filter UI.

## Acceptance criteria

1. A positive unmatched same-importer IN with no strong order/auth reference appears in the new supervisor-assignment queue.
2. Only positive-gap orders for that exact importer are selectable.
3. No order is silently auto-selected by the fallback.
4. Selecting an order shows the live gap and resulting pending-surplus preview.
5. Submitting uses the existing server action and existing RPC routing.
6. A statement amount above the selected gap funds only the gap and preserves the residual as pending surplus.
7. The statement line cannot be reused after successful reconciliation.
8. Existing automatic ready funding cards continue unchanged.
9. OUT, supplier, refund, exception, final-balance and Sage routes remain unchanged.
10. Page-level filters change only what is displayed.
11. No new database migration is required for the unmatched-IN fallback.
12. The target case supports statement line `4c52ae34-ec72-40ad-b954-fdcd4b686b03` selecting order `abf15b7b-771f-482f-9751-2af0ee0bcbb1`, previewing £804.93 funding and £81.20 pending surplus.

## Build limit

Prefer the fewest changed files and lines:

- this addendum;
- `app/internal/funding/page.tsx`;
- no server-action change unless the existing action cannot accept the exact form payload described above;
- no migration unless a separately proven canonical-credit access limitation requires one and the user separately approves it.
