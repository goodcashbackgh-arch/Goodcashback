# Customer Applied-Credit Inclusion Presentation Addendum v1

Status: locked corrective governing addendum after full upstream/downstream dependency audit.

## 1. Proven defect

The customer operations page correctly displays the canonical amount applied to the order, but when account credit is part of that amount the component line can read as though the credit should be added again.

Example:

- accepted estimate: £740.00;
- confirmed DVA cash funding: £739.21;
- account credit applied: £0.79;
- canonical amount applied to the order: £740.00.

The £740.00 is correct. It already includes the £0.79 account credit. The defect is presentation wording only.

## 2. Governing semantics preserved

This addendum must not reinterpret or alter:

- `order_funding_events`;
- `order_funding_position_vw`;
- `internal_platform_order_status_v1()`;
- `order_audience_status_v1(uuid)`;
- `order_settlement_resolution_position_v1`;
- `order_settlement_audience_v1(uuid)`;
- accepted-estimate funding threshold;
- DVA reconciliation;
- importer credit application/reversal;
- final-balance payment allocation;
- pending receipt residual settlement;
- FX/card-difference classification;
- customer sale documents;
- Sage, VAT, supplier, shipment, tracking, hold or dispute controls.

Applied account credit is an order-funding component. The canonical amount applied to the order includes that component. Posted final-sale documents govern final sale value, final balance and final settlement classification; they do not change the meaning of the already-applied funding total.

## 3. Exact corrective scope

Use the existing customer-only presentation component:

`app/customer/orders/[order_id]/operations/SettlementCustomerPatch.tsx`

Preserve its existing wording correction:

`Amount received` -> `Payment applied to this order`

Where the same customer operations route renders an account-credit component line beginning:

`Account credit applied:`

clarify that component wording to:

`Includes account credit:`

Do not change the displayed canonical payment amount.

Do not add phase detection, posted-sale queries, funding queries, admin-client dependencies or new server props to the layout.

Do not change `app/customer/orders/[order_id]/operations/page.tsx`.

## 4. Acceptance case

For:

- accepted estimate £740.00;
- confirmed DVA cash funding £739.21;
- applied account credit £0.79;

customer presentation must read semantically as:

- Payment applied to this order: £740.00;
- Includes account credit: £0.79.

The presentation must not imply £740.79 has been applied and must not reinterpret the canonical £740.00 as cash-only £739.21.

## 5. Downstream and cross-surface boundary

No importer, internal, funding, settlement-resolution, DVA/card, accounting, Sage, VAT, supplier, shipment or database surface is changed.

The customer operations layout remains byte-for-byte equivalent to `main` for this build. The only runtime delta is customer-route text clarification inside the pre-existing presentation patch.

## 6. Regression requirements

Before merge confirm:

1. PR runtime diff contains only `SettlementCustomerPatch.tsx`.
2. Customer operations `page.tsx` is unchanged.
3. Customer operations `layout.tsx` is unchanged from `main`.
4. No SQL/migration/database object is changed.
5. No new Supabase query or `supabaseAdmin` dependency is introduced.
6. Canonical amount applied remains unchanged before and after posted sale documents.
7. Account-credit amount remains unchanged.
8. Final balance, pending credit, funding threshold and completion/status calculations remain unchanged.
9. Importer and internal surfaces remain unchanged.

## Locked implementation rule

> Preserve the canonical combined amount applied to the order. Clarify only that the displayed account-credit component is included in that total. Nothing else.
