# Signed OCR Financial Line and Supplier AP Payload Addendum v1

Status: governing addendum for signed supplier-invoice OCR evidence and supplier AP/Sage payload composition.

## Purpose

This addendum locks the existing end-to-end route for supplier-invoice rows whose commercial effect is signed, including retailer discounts and other explicitly classified non-physical financial rows.

It extends, but does not replace:

- `docs/governing-pack/ui/NON_PHYSICAL_SUPPLIER_INVOICE_LINE_RESOLUTION_CONTRACT_v1.md`;
- the current Mindee supplier-invoice OCR save contract;
- the current supervisor supplier-line accounting coding route;
- the current supplier-goods AP/Sage queue and immutable snapshot controls.

## Canonical source equation

Supplier invoice evidence must preserve the document's commercial signs:

```text
physical goods gross
+ qualifying delivery / fee gross
- discount / credit gross
= supplier invoice gross
```

For the current target invoice:

```text
£499.99 goods
- £50.01 discount
= £449.98 supplier invoice gross
```

The document sign is a source fact. It must not be converted to an absolute value merely to satisfy an ingestion, reconciliation, accounting or posting implementation.

## OCR ingestion boundary

1. The canonical Mindee result parser must preserve every valid source row, including a negative amount.
2. The canonical save route must preserve all existing authentication, invoice-state, idempotency, audit, review-flag and human-work protections.
3. Where the preserved legacy save implementation omits a negative source row, the signed-row wrapper may add only that omitted negative row.
4. A source-negative row must be stored as:
   - `line_source = 'ocr_extracted'`;
   - `eligible_for_invoice_yn = 'N'`;
   - original description, quantity, order and signed amount preserved.
5. A repeated result fetch/save must not create a duplicate row for the same OCR line order.
6. A seeded OCR-shaped fixture is not proof that the production enqueue/fetch/parser/save route accepts signed rows. Production-path regression evidence is required.

## Importer reconciliation boundary

1. A newly saved signed OCR row is `unresolved_default_n` until an explicit operator action resolves it.
2. The UI must not silently classify or preselect a financial type.
3. The classification control must start blank and require an explicit valid choice.
4. A source-negative row must remain visible as signed immutable evidence.
5. A source-negative row must not be available to:
   - single physical progression;
   - bulk physical progression;
   - refund/replacement exception selection;
   - tracking or package allocation;
   - shipment batching.
6. The importer page may recognise a delivery or discount row for lane exclusion and signed allowance only where:
   - its description matches the same established delivery/discount vocabulary used by the canonical Mindee parser; and
   - the extracted delivery or discount total agrees with the non-rejected `order_value_adjustments` amount for that supplier invoice within £0.01.
7. A description match without amount agreement must not alter the physical lane or remaining-value allowance.
8. For proven unresolved financial rows on the selected invoice, the physical-goods allowance is:

```text
physical remaining value
= order remaining net value
- sum of proven unresolved signed financial rows
```

For `NIN-240726-A` this restores the goods allowance to:

```text
£449.98 - (-£50.01) = £499.99
```

9. A proven positive delivery row and a source-negative row remain outside physical progression and refund/replacement selection.
10. Ordinary positive unresolved goods retain the existing selection, Select all, Clear selection, single progression and exception behaviour.
11. The existing `operator_resolve_supplier_invoice_line_non_physical(...)` RPC remains the canonical Park action.

## Progression enforcement parity

1. Importer selection eligibility and the server-side progression guard must use the same order-wide calculation and the same £0.01 tolerance.
2. Accounted quantity includes only progressed physical rows and physical rows linked to an open exception. Non-physical financial rows must never increase accounted quantity.
3. Accounted value includes:
   - progressed physical rows;
   - physical rows linked to an open exception; and
   - rows with an active non-physical financial resolution.
4. A still-unresolved delivery or discount row may contribute a signed allowance only where:
   - it belongs to the same supplier invoice as the physical row being assessed;
   - delivery is source-positive and discount is source-negative;
   - its description matches the established delivery/discount vocabulary; and
   - the aggregate extracted total for that type agrees with the active, non-rejected `order_value_adjustments` total for that supplier invoice within £0.01.
5. Unknown financial types, description-only matches, amount mismatches and cross-invoice offsets must fail closed and must not create progression capacity.
6. Single-line and bulk progression must apply the same calculation.
7. No invoice reference, line id or amount may be hard-coded into the production progression rule.
8. This parity correction must not replace or alter the existing progression RPCs, Park RPC, stored source rows, resolutions, exceptions or downstream adjustment-consumption route.

For the current proved order, the required progression equation is:

```text
£434.98 already accounted
+ £499.99 selected physical goods
- £50.01 proved same-invoice discount
= £884.96 order baseline
```

## Settlement-banner presentation gate

1. `order_settlement_audience_v1(...)` and all underlying settlement records and equations remain authoritative and unchanged.
2. The importer reconciliation settlement banner is presentation-only and must not render merely because a positive settlement amount exists.
3. The banner must be hidden where either:
   - `resolution_status = 'not_ready_no_final_sale'`; or
   - an open supplier-invoice cycle exists.
4. An open supplier-invoice cycle exists where any non-retired supplier invoice for the order:
   - is not in `approved_current` or `ref_corrected_approved`; or
   - remains `blocked_from_sage_yn = true`.
5. Retired statuses are `rejected_resubmit_required`, `superseded` and `duplicate_blocked`.
6. Both conditions are required because the no-final-sale status protects the initial cycle, while the live-invoice gate protects later supplementary cycles after an earlier customer sale already exists.
7. Hiding the banner must not alter funding, customer credit, settlement classifications, supplier invoices, approvals, Sage readiness or any accounting record.
8. Once settlement is ready and no open supplier-invoice cycle remains, the existing banner amount, wording, colours and resolved/over-resolved presentation remain unchanged.

## Supervisor accounting boundary

1. `staff_bulk_save_supplier_invoice_line_accounting_codes_v2(uuid,jsonb)` is the canonical supervisor Save all route for this workflow.
2. Its codable population is:
   - progressed physical rows; and
   - rows with an active `non_physical_financial` resolution.
3. Signed net, VAT and gross values must satisfy:

```text
net_amount_gbp + vat_amount_gbp = gross_amount_gbp
```

within the existing tolerance.
4. The live amount-sign trigger remains authoritative. Negative accounting values are permitted only when the source line has an active permitted non-physical financial resolution.
5. Parking closes the operational blocker only. It does not itself complete accounting coding.
6. The supervisor must select the posting account and tax treatment. The platform must not infer those from the OCR description alone.

## Approval boundary

1. Approval/current-state rules remain unchanged.
2. All codable rows must be coded.
3. Accepted net, VAT and gross totals must reconcile under the existing approval readiness rules.
4. Approval is the existing point at which `blocked_from_sage_yn` may be cleared.
5. This addendum does not create a new approval state or bypass any review flag, reference-family or sibling-invoice control.

## Supplier AP and Sage payload boundary

1. The preserved supplier-goods AP helper remains authoritative for invoices without active coded non-physical rows.
2. Only affected invoices may receive additive signed non-physical enrichment.
3. An active coded non-physical source row must appear in `resolved_lines` exactly once.
4. The payload must preserve signed net, VAT and gross amounts.
5. The sum of all payload line gross amounts must equal the supplier invoice header amount within the existing tolerance.
6. Missing ledger or tax mapping must continue to block readiness.
7. The existing freeze/snapshot route remains immutable and idempotent.
8. A live Sage post must not be attempted until the frozen payload has been reviewed and the external API has accepted the signed purchase-invoice line shape.

## Unchanged routes

This addendum does not change:

- ordinary positive goods OCR handling;
- manual-line creation rules;
- existing Select all / Clear selection controls;
- refund or replacement exception workflows for genuine physical lines;
- tracking, package, shipment, export or POD controls;
- supplier funding, banking or treasury allocation;
- customer sales invoicing;
- VAT return snapshots;
- supplier credit-note or retailer-refund lanes;
- order status rules;
- permissions or navigation.

## Required regression evidence

The release must prove:

1. Actual Mindee-shaped source data containing a negative discount produces a stored signed OCR row.
2. Repeated save/fetch does not duplicate it.
3. Blank classification fails; explicit `discount` succeeds.
4. The signed row cannot enter single or bulk physical progression, exception selection, tracking or shipment.
5. Proven delivery/discount rows alter the physical allowance only on exact declared-adjustment agreement.
6. The original Select all, Clear selection and selected-progression controls remain available for ordinary goods.
7. Supervisor V2 bulk coding saves signed net, VAT and gross.
8. Accounting totals reconcile to the invoice header.
9. Approval remains blocked until complete and then uses the existing current-state route.
10. The supplier AP/Sage payload contains the signed row exactly once.
11. An unaffected invoice receives the exact preserved supplier AP helper output.
12. The importer reconciliation page retains the exact prior layout, wording and styling except for the narrow signed-row and proven-adjustment controls stated above.
13. Single and bulk progression use identical order-wide accounted quantity and value inputs.
14. Delivery-only, discount-only and combined delivery/discount invoices apply their signed same-invoice allowance correctly.
15. Multiple delivery rows and multiple discount rows are aggregated by supplier invoice and adjustment type.
16. Active Parked financial resolutions contribute signed value but never physical quantity.
17. Mismatched totals, unknown fees, description-only matches and cross-invoice financial rows do not create progression capacity.
18. `NIN-240726-A` progresses at exactly £884.96 without changing any source or adjustment amount.
19. A positive settlement amount with `resolution_status = 'not_ready_no_final_sale'` does not render the banner.
20. A later open supplier-invoice cycle suppresses the banner even where an earlier final sale exists.
21. The banner returns unchanged when settlement is ready and every live supplier invoice is approved current and no longer Sage-blocked.
22. The progression and banner patches do not alter any database function, table row, funding, banking, Sage, VAT, shipment, approval or settlement calculation.
