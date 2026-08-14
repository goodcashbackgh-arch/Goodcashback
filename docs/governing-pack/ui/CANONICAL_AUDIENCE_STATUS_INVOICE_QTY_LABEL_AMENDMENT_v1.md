# Canonical Audience Status — Importer Invoice Quantity Label Amendment v1

Status: governing authority for one presentation-only correction on the importer order-operations invoice card.

Extends:

- `CANONICAL_AUDIENCE_STATUS_CONTRACT_v1.md`

Baseline:

- branch base / current `main`: `303ed710c44688a0983f58a3eccba76a7540f31b`
- governed production file: `app/importer/orders/[order_id]/operations/page.tsx`

## 1. Purpose

The importer order-operations invoice card currently displays the label `Goods qty` beside the existing aggregate quantity value. That aggregate intentionally reflects the current invoice-line quantity calculation and must not be changed by this amendment.

The presentation label must be changed to `Invoice qty` so the visible wording accurately describes the existing value without introducing a goods-classification rule.

## 2. Exact authorised production change

In `app/importer/orders/[order_id]/operations/page.tsx`, change only the literal rendered text:

```diff
- Goods qty
+ Invoice qty
```

No other production-code change is authorised.

## 3. Calculation and logic freeze

The existing quantity and amount aggregation must remain byte-for-byte unchanged:

```ts
current.qty += Number(line.qty ?? 0);
current.amount += Number(line.amount_inc_vat_gbp ?? 0);
```

This amendment must not alter, add, remove, wrap, filter, branch, classify or reinterpret any invoice line.

## 4. Canonical status freeze

The following are explicitly frozen:

- `order_audience_status_v1`
- canonical importer status and next-action output
- invoice `review_status`
- reconciliation state
- supplier state
- order lifecycle state
- `eligible_for_invoice_yn`
- non-physical line resolutions
- dispute/hold state
- tracking state
- shipment state
- customer-sales state
- accounting/Sage state
- VAT/compliance state

No status, balance, workflow or audience calculation may change.

## 5. Data and backend freeze

No change is authorised to:

- Supabase queries or selected columns
- database tables or views
- RPCs/functions
- SQL or migrations
- RLS/permissions
- database writes
- supplier-invoice line data
- order-value adjustments
- accounting coding
- Sage posting
- VAT logic
- tracking or shipment logic
- supervisor actions
- importer reconciliation actions
- customer or shipper code

## 6. UI structure freeze

No change is authorised to:

- JSX structure
- CSS/Tailwind classes
- components
- imports
- types
- variables
- helper functions
- links/routes
- forms/buttons
- conditional rendering
- invoice values
- visible status badges
- any label other than the exact `Goods qty` literal

## 7. Build stop rule

The production diff must contain exactly one semantic application change:

```diff
- <span className="text-slate-500">Goods qty</span>
+ <span className="text-slate-500">Invoice qty</span>
```

If implementation requires any additional production change, stop and do not merge.

## 8. Acceptance proof

Before merge, prove all of the following:

1. Exactly one production file changed.
2. The only production-code semantic difference is `Goods qty` → `Invoice qty`.
3. The existing `current.qty += Number(line.qty ?? 0);` line is unchanged.
4. The existing `current.amount += Number(line.amount_inc_vat_gbp ?? 0);` line is unchanged.
5. `order_audience_status_v1` and all SQL/migrations are untouched.
6. No importer calculation, query, status, reconciliation, tracking, accounting, Sage or VAT logic changed.
7. The rendered numeric quantity remains exactly the pre-patch value; only its label changes.

## 9. Scope statement

This is a presentation-only wording correction. It is not a physical-goods quantity fix and must not be expanded into one.
