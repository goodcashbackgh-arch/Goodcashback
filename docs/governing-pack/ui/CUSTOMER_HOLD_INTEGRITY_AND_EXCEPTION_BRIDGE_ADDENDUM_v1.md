# Customer Hold Integrity and Exception Bridge Addendum v1

Status: governing compatibility and control addendum

## 1. Purpose

This addendum locks the customer-hold integrity rules required to connect:

- immutable customer review cycles;
- order-, package/tracking-, and line-scoped holds;
- supervisor approval;
- shipper set-aside visibility;
- the existing refund/replacement exception route;
- operator/importer retailer handling;
- shipper physical return actions;
- supplier refund/credit-note evidence;
- customer sales release provenance;
- DVA/card refund-IN matching;
- Sage and VAT readiness.

It does not create a new customer-hold, exception, refund, return, credit-note, statement-matching, or Sage workflow.

## 2. Controlling cross-reference

For multi-supplier-invoice orders and repeated customer review/customer sales releases, this addendum must be read with:

```text
docs/governing-pack/architecture/
MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md
```

That addendum is controlling for:

- durable customer release membership;
- immutable review-link membership;
- package membership across several supplier invoices;
- repeated supplementary customer invoices;
- already-customer-released checks;
- customer credit-note treatment;
- supplier-document provenance;
- build sequence and regression coverage.

This file exists as the customer-hold and exception-bridge authority pointer. It must not be implemented as a separate parallel project.

## 3. Core integrity rule

```text
Progression proves what was bought and received.
A hold proves what must not be released or shipped.
An exception proves why the item is being refunded, replaced, or otherwise resolved.

Approving a hold must not erase progression, tracking, package,
receipt, supplier-invoice, or audit evidence.
```

## 4. Review-cycle integrity

Every customer review cycle must contain immutable exact source membership.

An old review link must not dynamically gain lines that became eligible later.

A newly eligible line may enter a later review only when it is:

- on an active supplier invoice;
- progressed;
- allocated to known tracking/package scope;
- received clean;
- not already actively customer-released;
- not under an active hold;
- not linked to an unresolved exception;
- not already assigned to another active review cycle.

## 5. Hold scope

### Order hold

Blocks the entire order from customer sales release and shipment while active.

It must be narrowed or materialised to exact supplier invoice lines before refund accounting proceeds.

### Package/tracking hold

Blocks the exact package or tracking scope.

Where package contents are complete and known, the platform must materialise the exact contained supplier invoice lines and quantities. Those lines may enter one compatible existing refund exception.

Where contents are unknown or incomplete, physical set-aside remains active but exception conversion fails closed.

### Line hold

Blocks only the exact supplier invoice line and affected quantity.

Clean, unheld lines remain eligible for progression, shipment, and customer release subject to their normal gates.

## 6. Supervisor approval and shipper visibility

A requested hold enters supervisor control.

Before approval, it does not authorise retailer contact, refund pursuit, replacement, return, supplier credit-note approval, customer credit-note creation, or Sage action.

After approval, the shipper's existing hold worklist must show:

```text
SET ASIDE / DO NOT SHIP
```

This means the approved instruction is available in the shipper worklist. It does not prove that a shipper user opened the page, and it is not a push notification.

## 7. Patched exception bridge

An approved exact held line may create or link the existing exception whether the line is:

```text
unprogressed
or
progressed, tracked, and received clean
```

The bridge must no longer exclude a line merely because `eligible_for_invoice_yn = 'Y'` or an equivalent progressed value.

Conversion must require:

1. supervisor-approved hold;
2. exact affected line and quantity;
3. line belongs to the order;
4. supplier invoice is active;
5. package holds are materialised to exact lines;
6. no duplicate incompatible unresolved dispute membership;
7. affected quantity has not already been released to a non-void customer sales document;
8. compatible open refund dispute is reused where available;
9. supervisor approval identity and timestamp are preserved;
10. tenant/importer/order ownership is enforced.

The bridge must preserve:

- progression;
- confirmed quantity and value;
- tracking allocation;
- package membership;
- receipt evidence;
- supplier invoice identity;
- shipment evidence;
- audit history.

## 8. Existing exception and refund route

Once the approved hold bridges into the exception route:

```text
supervisor-approved hold
→ refund pursuit already approved where refund was selected
→ operator/importer contacts retailer
→ operator/importer records retailer response
→ supervisor accepts or rejects final outcome
→ operator/importer submits return instructions where required
→ shipper performs collection/return and uploads proof
→ supervisor reviews shipper proof
→ operator/importer submits supplier credit-note/refund/no-document evidence
→ retailer refund IN is matched
→ supplier-credit and Sage controls continue
```

No separate “hold refund” route may be built.

## 9. Return-action boundary

Hold approval gives the shipper a set-aside instruction, not an immediate return instruction.

An actionable shipper return appears only when the operator/importer has submitted the retailer-provided operational information through the existing exception route, such as:

- return instructions;
- return label;
- courier;
- collection/tracking reference;
- evidence URL;
- operational note.

The shipper then uses the existing `/shipper/return-actions` path.

## 10. Hold closure

An approved hold must not remain indefinitely in the active shipper set-aside queue.

It must stop qualifying as active after:

- rejection;
- supersession by a narrower hold;
- explicit supervisor clearance;
- approved cancellation;
- accepted physical return/collection proof;
- permanent approved removal from shipment scope;
- another terminal exception outcome that clears the physical hold.

Audit records remain immutable.

The shipper next-state sequence remains:

```text
set aside only
return action ready
return proof submitted
return accepted
cleared or superseded
```

Physical return acceptance does not equal refund-money receipt, supplier-credit approval, Sage posting, or final financial closure.

## 11. Customer sales and credit-note boundary

The normal pre-shipment review route should exclude held lines before customer invoicing.

Where affected quantity has already been customer-released:

- do not silently treat it as unreleased;
- retain the supplier refund and physical return exception route;
- create a customer credit note against the exact affected customer sales invoice;
- create separate customer credit notes where the correction spans main and supplementary customer sales invoices.

## 12. Supplier refund provenance

One operational dispute may cover lines from several supplier invoices, but supplier credit-note/refund evidence must remain tied to the exact original supplier invoice and affected lines.

The physical return may be one operational action. The legal supplier credit documents remain separate where the retailer issued separate documents.

Refund money must be matched once and must not be counted twice across supplier invoices or disputes.

## 13. Non-negotiable reuse

Reuse the existing:

- customer hold worklist;
- exception route;
- operator/importer retailer update lane;
- structured return/collection submission;
- shipper return action;
- supervisor return-proof review;
- refund document control;
- DVA/card retailer refund matching;
- supplier credit-note accounting lane;
- customer sales release/Sage/VAT controls.

Do not add a new workbench, statement selector, Sage route, OCR provider, or replacement flow for this bridge.

## 14. Build dependency

The progressed-line bridge must not be considered fully released until the durable customer release ledger exists, because the bridge must prove that affected quantity has not already been customer-invoiced.

Implementation order remains:

1. multi-supplier document identity and bundle;
2. portal integration;
3. customer release ledger and repeated releases;
4. immutable reviews, scoped holds, and patched exception bridge.

## 15. Minimum regression proof

The build must prove:

1. unprogressed approved line continues to convert;
2. progressed/tracked/received-clean approved line converts;
3. progression and tracking remain unchanged;
4. known package materialises exact contained lines;
5. package spanning several supplier invoices preserves each source line;
6. unknown package membership fails closed;
7. compatible dispute is reused;
8. shipper sees set-aside after approval;
9. shipper receives return action only after operator/importer instructions;
10. accepted return removes the active set-aside instruction without deleting audit history;
11. physical return does not falsely mark refund money received;
12. already-customer-released value routes to exact customer credit note treatment;
13. supplier refund evidence remains tied to the original supplier invoice;
14. retailer refund IN is matched once;
15. existing one-invoice and unprogressed-hold flows remain unchanged.

## 16. Customer hold history item identity

Historical customer hold audit must remain intelligible after the affected line is no longer part of the current customer review-ready set.

For a line-scoped hold, the authoritative identity anchor is the existing:

```text
customer_pre_shipment_hold_requests.supplier_invoice_line_id
→ supplier_invoice_lines.id
```

Customer hold history must not depend on the current `customer_review_ready_line_ids_v1()` result to recover the historical item identity. A resolved, superseded, converted, or otherwise closed line hold may legitimately remain in audit history after that line has left the current review-ready set.

The existing customer review RPC may therefore enrich each hold object additively with only:

- `line_description`;
- `line_qty`;
- `line_amount_inc_vat_gbp`.

These fields must be sourced by a direct left join from the hold's existing `supplier_invoice_line_id` to `supplier_invoice_lines.id`.

The customer review history UI may display those fields for line-scoped holds so that a customer can identify which historical item the hold concerned.

This enrichment is presentation/read-model only. It must not:

- alter hold creation, approval, rejection, narrowing, resolution, supersession, or exception conversion;
- alter `customer_review_ready_line_ids_v1()`;
- reintroduce a closed line into the current review-ready item set;
- alter shipment eligibility or blocking;
- alter customer invoice eligibility or release;
- alter exception/refund/return state;
- alter DVA, supplier AP, Sage, VAT, or accounting readiness;
- alter RLS, grants, review-link scope, expiry, or customer permissions.

The customer payload must not expose additional internal identifiers or operational/accounting detail merely to support history identity. In particular, this change does not authorise exposure of supplier invoice references, tracking references, supplier invoice ids, VAT fields, OCR data, DVA data, Sage data, or internal review statuses.

Where no line identity is available, the existing hold history card must continue to render safely without fabricated fallback data.

## 17. Regression extension for history identity

In addition to section 15, the history-identity build must prove:

1. an existing resolved line hold retains its original `supplier_invoice_line_id`;
2. the historical supplier line remains joinable even when absent from `customer_review_ready_line_ids_v1()`;
3. the customer review RPC returns `line_description`, `line_qty`, and `line_amount_inc_vat_gbp` additively for that hold;
4. existing hold keys and status/reason values remain unchanged;
5. current review-ready membership remains unchanged;
6. hold row counts and active/closed classifications remain unchanged;
7. no hold lifecycle, shipment, exception, refund, return, Sage, VAT, DVA, RLS, grant, or permission behaviour is modified;
8. the Customer Review history renders the historical item identity only for line-scoped holds where that identity exists.

This section is the governing authority for the customer hold history item-identity correction. Implementation must not exceed this scope.
