# Outbound Supplier FX Settlement Classification Addendum v1

Status: locked corrective governing addendum for implementation.

## Purpose

Correct one narrow settlement-classification defect: a confirmed `fx_card_difference` on a DVA/card `OUT` supplier-payment line is already a known FX/payment variance, but the canonical settlement position does not currently count that variance as classified when the FX allocation itself has no `order_id`.

Controlled case: `ORD-1785274708774`. Its GBP 702.76 supplier-payment OUT is fully consumed by GBP 701.83 confirmed supplier-invoice allocations plus GBP 0.93 confirmed FX/payment variance. The GBP 0.93 FX row has no `order_id`, but the same statement line is unambiguously attributable to this one order through its confirmed supplier-invoice allocations.

## Locked accounting treatment

For an original order:

```text
order-attributed receipt
  = existing inbound receipt attribution only

confirmed settlement classification
  = existing confirmed customer credit
  + existing inbound FX classification
  + existing settlement-action FX classification
  + confirmed unambiguous supplier-payment OUT FX/payment variance

remaining unresolved
  = gross positive difference - confirmed settlement classification
```

A confirmed outbound FX/payment variance is a classification of the difference. It is not customer receipt, supplier-invoice value, order funding, final-balance payment or customer credit.

## Exact implementation boundary

Patch only `public.order_settlement_resolution_position_v1`.

An OUT FX allocation may participate in an order's existing `settlement_fx_card_difference_gbp` only where all of the following are true:

- the FX row has `allocation_type = 'fx_card_difference'`;
- the FX row has `allocation_status = 'confirmed'`;
- the linked statement line direction is `out`;
- the statement account context is `importer_dva_card_account`;
- that same statement line has confirmed `supplier_invoice` allocations;
- those confirmed supplier allocations resolve, through `supplier_invoices.order_id` or the allocation `order_id`, to exactly one distinct order.

The FX row's own `order_id` is not required. The order identity is derived only from the confirmed supplier allocations on the same supplier-payment OUT line.

If a supplier-payment OUT line resolves to zero or more than one distinct order, its FX variance is not attributed by this patch. It remains fail-closed for separate review rather than being duplicated or guessed across orders.

The existing view column contract and all existing downstream readers remain unchanged.

## Explicitly unchanged

No change to:

- physical statement lines or source-line balance;
- supplier-invoice allocations or supplier-payment amount;
- statement matching or sequential source consumption;
- funding events, funding gap or accepted estimate;
- pending-surplus rows or importer credit ledger;
- final sale documents or final order value;
- final-balance payments;
- allocation creation/reversal RPCs;
- Sage, VAT or cash posting;
- shipment, tracking, holds or disputes;
- permissions, navigation, UI wording, styling or action availability;
- historical business rows.

For the controlled case, GBP 0.93 remains on the bank OUT as FX/payment variance and remains part of the GBP 702.76 source-line consumption. The correction changes only how that already-confirmed FX fact participates in canonical settlement classification.

## Fail-closed requirements

The migration must stop before patching if the canonical view definition or expected calculation anchors have drifted. It must preserve the view column names/order and the existing internal settlement RPC contract.

Ambiguous multi-order supplier-payment lines must not receive inferred FX attribution.

## Regression requirement

Regression must prove:

1. the controlled GBP 0.93 FX row remains confirmed and has no order identity requirement;
2. its supplier-payment statement line resolves to exactly one order through confirmed supplier-invoice allocations;
3. the GBP 0.93 is included exactly once in the existing settlement FX classification;
4. it is not added to `order_attributed_receipt_gbp`;
5. supplier-invoice allocation remains GBP 701.83 and total statement-line consumption remains GBP 702.76;
6. existing inbound FX behaviour and settlement-action FX behaviour remain unchanged;
7. no business rows are mutated.
