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
6. Ordinary positive unresolved rows retain the existing selection, bulk and exception behaviour. Description heuristics must not change their lane automatically.
7. The existing `operator_resolve_supplier_invoice_line_non_physical(...)` RPC remains the canonical Park action.

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
5. Supervisor V2 bulk coding saves signed net, VAT and gross.
6. Accounting totals reconcile to the invoice header.
7. Approval remains blocked until complete and then uses the existing current-state route.
8. The supplier AP/Sage payload contains the signed row exactly once.
9. An unaffected invoice receives the exact preserved supplier AP helper output.
10. The importer reconciliation page retains the exact prior layout, wording, styling, selection and bulk-control behaviour except for the narrow signed-row controls stated above.
