# Hybrid Physical Receipt Whole-Unit Entry Clarification v1

Status: implementation clarification to the existing Hybrid Physical Receipt, Quantity Fulfilment and Remedy Control Addendum v1 and Build 3 UI activation contract.

Date: 1 August 2026

## Purpose

This clarification narrows the shipper interaction used to produce the existing canonical v2 physical-receipt payload. It does not introduce a new receipt model, lifecycle, remedy workflow, database structure, RPC signature or downstream state machine.

## Governing interpretation

For the shipper exact physical receipt route:

1. Physical item quantities are whole units.
2. Each allocation line opens with affected quantity equal to `0`.
3. Clean quantity initially equals the full allocated quantity.
4. The shipper edits only affected quantity.
5. Affected quantity is selected dynamically from the inclusive range `0..allocated quantity`.
6. Clean quantity is derived as `allocated quantity - affected quantity` and is not independently editable.
7. When affected quantity returns to `0`, affected disposition and factual note are cleared and disabled.
8. When affected quantity is above `0`, affected disposition and factual note are required.
9. Package evidence remains required when the sum of affected quantities across the package is above `0`.
10. The server recomputes clean quantity from allocated and affected values and does not trust a browser-supplied clean quantity.
11. The server rejects non-integer, negative or out-of-range physical quantities.
12. Existing numeric database column types remain unchanged because integer enforcement belongs at this physical-receipt boundary, not across unrelated allocation or accounting domains.

## Canonical payload compatibility

The resulting disposition payload is unchanged.

For an allocation of two units with one damaged unit, the canonical rows remain:

```text
clean quantity 1
damaged quantity 1 with factual note
```

For an all-clean allocation, only the clean disposition is emitted. For a wholly affected allocation, only the selected affected disposition is emitted.

The exact allocation identity, supplier invoice line identity, tracking submission identity, correction chain, evidence references and immutable receipt snapshot rules remain unchanged.

## Upstream non-impact

This clarification does not change:

- `shipper_physical_receipt_entry_v1` read semantics;
- supplier invoice or supplier invoice line identity;
- tracking submission identity;
- tracking line allocation identity or financial allocation values;
- order creation, invoice import, tracking creation or dispatch workflows;
- historical v1 receipt compatibility.

A non-whole physical allocation encountered by this shipper route must be blocked for controlled remediation rather than rounded or silently converted.

## Downstream non-impact

This clarification does not change:

- `shipper_record_package_receipt_v2` payload meaning;
- `shipper_package_receipt_line_dispositions` row meaning;
- physical review creation or status progression;
- importer remedy proposal;
- supervisor route approval;
- existing dispute and retailer-conversation linkage;
- refund, replacement, return or collection workflows;
- replacement child provenance or acceptance;
- shipment, customer-sales release, VAT, Sage, accounting or reconciliation controls.

## Build 3 UI activation amendment

The Build 3 shipper receipt UI must present one editable affected-quantity control per exact allocation line. It must dynamically produce whole-number options from zero through the allocation quantity, default to zero, display derived clean quantity, and conditionally enable issue fields.

The UI must retain automatic image optimisation, upload-size feedback and a submitting lock that prevents duplicate taps.

## Build 4 lifecycle compatibility note

Build 4 lifecycle reconciliation continues to consume the same canonical receipt, review and replacement records. The derived clean-quantity interaction is a safer producer of the existing payload and must not alter correction supersession, terminal review guards, replacement acceptance, parent blocking or reconciliation outcomes.

## Required regression cases

- allocated 1, affected 0 => clean 1;
- allocated 1, affected 1 => clean 0 and issue details required;
- allocated 2, affected 1 => clean 1;
- allocated 2, affected 2 => clean 0;
- affected changed back to 0 => issue type and note cleared;
- all-clean package => no evidence required;
- any affected package => evidence required;
- tampered fractional affected quantity => server rejection;
- tampered affected quantity above allocated => server rejection;
- correction submission => complete replacement snapshot and correction reason remain required;
- generated disposition rows retain the existing canonical schema and downstream behavior.
