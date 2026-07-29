# Outbound Supplier FX Settlement Classification Addendum v1

Status: locked corrective governing addendum for implementation.

## Purpose

Correct one narrow settlement-classification defect: a confirmed order-linked `fx_card_difference` on a DVA/card `OUT` supplier-payment line is already a known FX/payment variance, but the canonical settlement position does not currently count that confirmed variance as classified. As a result, the same amount can remain inside `remaining_unresolved_gbp` and be projected as potential customer credit.

Controlled case: `ORD-1785274708774`, where GBP 0.93 is confirmed FX/payment variance on the supplier-payment OUT and must not remain inside the potential-credit calculation.

## Locked accounting treatment

For an original order:

```text
order-attributed receipt
  = existing inbound receipt attribution only

confirmed settlement classification
  = existing confirmed customer credit
  + existing inbound FX classification
  + existing settlement-action FX classification
  + confirmed order-linked outbound FX/payment variance

remaining unresolved
  = gross positive difference - confirmed settlement classification
```

A confirmed outbound FX/payment variance is a classification of the difference. It is not customer receipt, supplier-invoice value, order funding, final-balance payment or customer credit.

## Exact implementation boundary

Patch only `public.order_settlement_resolution_position_v1` so its existing `settlement_fx_card_difference_gbp` amount also includes confirmed `dva_statement_line_allocations` rows where:

- `allocation_type = 'fx_card_difference'`;
- `allocation_status = 'confirmed'`;
- `order_id` is present;
- the linked statement line direction is `out`;
- the statement account context is `importer_dva_card_account`.

The existing column contract and all existing downstream readers remain unchanged.

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

The GBP 0.93 remains on the bank OUT as FX/payment variance and remains part of the GBP 702.76 source-line consumption. The correction changes only how the already-confirmed FX fact participates in the canonical settlement calculation.

## Fail-closed requirements

The migration must stop before patching if the canonical view definition or expected calculation anchors have drifted. It must preserve the view column names/order and the existing internal settlement RPC contract.

## Regression requirement

Regression must prove:

1. confirmed order-linked OUT FX is included once in the existing settlement FX classification;
2. it is not added to `order_attributed_receipt_gbp`;
3. supplier-invoice allocation total and statement-line consumption remain unchanged;
4. IN FX behaviour remains unchanged;
5. no business rows are mutated.
