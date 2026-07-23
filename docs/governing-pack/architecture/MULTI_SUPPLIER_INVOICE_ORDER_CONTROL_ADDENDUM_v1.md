# Multi-Supplier-Invoice Order Control Addendum v1

Status: governing contract for future build work

Source branch at drafting: `main`

Source commit inspected: `aa19f5248e3d489229c677cf0aac1e0032fbc4b4`

## 1. Purpose

This addendum governs one customer order that is fulfilled through two or more separate supplier invoices, receipts, corrected invoice versions, packages, or later supplier documents.

It locks the control model for:

- separate supplier-document identity;
- collective order reconciliation and baseline control;
- line progression across several supplier invoices;
- tracking and package allocation across those invoices;
- separate supplier AP and supplier-credit documents;
- one physical supplier-payment transaction allocated without inventing bank splits;
- repeated customer-review cycles;
- one main and repeated supplementary customer sales releases;
- exact release provenance and duplicate-billing prevention;
- order-, package-, and line-scoped customer holds;
- conversion of approved progressed or unprogressed held lines into the existing exception route;
- importer/operator retailer handling;
- shipper set-aside and physical return actions;
- customer and supplier credit-note boundaries;
- VAT, Sage, tenant, evidence, and audit integrity.

This addendum does not create a parallel order, invoice, exception, refund, return, payment-matching, or Sage workflow.

## 2. Authority and precedence

This addendum sits alongside and builds on the current governing pack, including:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
2. `docs/governing-pack/backend/Progressive_Commercial_Release_and_Replacement_Invoicing_Addendum_v1.md`
3. `docs/governing-pack/ui/EXCEPTION_REFUND_REPLACEMENT_ROUTE_CONTRACT.md`
4. `docs/governing-pack/ui/PHYSICAL_RETURN_TASK_BRIDGE_CONTRACT_v1.md`
5. `docs/governing-pack/architecture/PORTAL_AND_ORDER_OPERATIONS_ADDENDUM_V1.md`
6. the existing delivery-allocation, supplier AP, supplier-credit, DVA/card, cash-posting, VAT, and Sage controls.

Where an older document assumes any of the following, this addendum controls:

- only one legal supplier invoice may be current for an order;
- only one customer-review cycle may occur;
- only one supplementary customer invoice may occur;
- customer review links may remain order-wide dynamic queries;
- only unprogressed supplier lines may enter the customer-hold refund bridge;
- any active hold must block the whole order regardless of scope;
- supplier-payment matching requires invented statement splits;
- source-line IDs stored only in free-form or reconstructed JSON are sufficient for repeated customer releases.

## 3. Governing business truth

```text
One customer order may have many separate supplier invoices.

Each supplier invoice remains a separate legal, evidence, VAT,
accounting, supplier-AP, payment-allocation, refund, and Sage source.

The order may nevertheless be reconciled, progressed, reviewed,
tracked, shipped, and customer-invoiced collectively by exact source line.
```

The platform must never merge several supplier invoices into one artificial supplier invoice record merely to preserve an old one-invoice-per-order assumption.

## 4. Definitions

### 4.1 Supplier document

A supplier invoice, receipt, or accepted equivalent supplier charge document linked to an order.

### 4.2 Invoice reference family

All uploaded versions representing the same genuine supplier invoice reference for the same order.

### 4.3 Current version

The accepted live version of one invoice reference family. “Current” does not mean the only supplier invoice allowed for the order.

### 4.4 Active supplier invoice

A supplier invoice whose review status is not:

```text
rejected_resubmit_required
duplicate_blocked
superseded
```

### 4.5 Order supplier-invoice bundle

A read-only order-wide view built from all active supplier invoices and their exact lines. It is not duplicated accounting data.

### 4.6 Customer release membership

The durable link between a customer sales document line and the exact supplier/tracking source quantity released into that document.

### 4.7 Review cycle

One immutable set of customer-review-eligible lines presented through one customer review link or equivalent review snapshot.

### 4.8 Materialised package membership

The immutable set of exact supplier invoice lines and quantities contained in a package at the time a package-scoped decision is approved.

## 5. Supplier document identity and versioning

Every supplier invoice must retain its own:

- supplier invoice ID;
- retailer/supplier identity;
- genuine invoice reference;
- PDF or source evidence;
- OCR and header result;
- invoice lines and line source;
- delivery and discount treatment;
- rejection and resubmission history;
- current-version state;
- reconciliation and progression facts;
- supplier AP purchase invoice;
- supplier-payment allocation;
- refund evidence and supplier credit-note provenance;
- Sage source, snapshot, request, response, and posting trace.

The database must protect:

```text
one current version per order and normalised supplier invoice reference
```

It must not protect:

```text
one current supplier invoice per order
```

A corrected upload with the same genuine reference may supersede only its rejected or superseded version family. A different genuine invoice reference must coexist.

The existing OCR/content duplicate gate remains in force. Multi-invoice support must not weaken duplicate detection.

## 6. Order supplier-invoice bundle

The build must add or equivalent read models for:

```text
order_supplier_invoice_bundle_lines_v1
order_supplier_invoice_bundle_summary_v1
```

Names may be shortened only where PostgreSQL identifier limits require it. The meaning must remain unchanged.

### 6.1 Bundle line truth

The line model must expose at least:

```text
order_id
supplier_invoice_id
supplier_invoice_ref
supplier_invoice_status
supplier_invoice_line_id
line_order
line_source
raw_qty
raw_gross_gbp
confirmed_qty
confirmed_gross_gbp
progressed_yn
non_physical_resolution_yn
open_exception_yn
active_hold_yn
allocated_tracking_qty
remaining_tracking_qty
```

### 6.2 Bundle summary truth

The summary must expose at least:

```text
active_invoice_count
approved_invoice_count
review_invoice_count
active_line_count
progressed_physical_qty
progressed_physical_value_gbp
exception_qty
exception_value_gbp
non_physical_value_gbp
tracking_allocated_qty
tracking_allocated_value_gbp
order_baseline_qty
order_baseline_value_gbp
remaining_baseline_qty
remaining_baseline_value_gbp
all_documents_resolved_yn
baseline_accounted_for_yn
```

The bundle must exclude retired supplier invoices and must not alter the underlying documents.

## 7. Reconciliation, progression, and order baseline

Reconciliation remains exact to the selected supplier invoice and exact line.

Order-baseline validation is collective:

```text
all active progressed physical supplier lines
must remain within the original order quantity and value controls
```

Progressing, approving, rejecting, or correcting one supplier invoice must not silently alter another supplier invoice.

Retired supplier invoice lines must not continue to count in:

- unresolved-line totals;
- active reconciliation totals;
- progression coverage;
- delivery allocation;
- customer review;
- customer sales release;
- operational status;
- supplier AP readiness;
- customer sales readiness;
- accounting readiness.

A non-physical line remains governed by the existing non-physical resolution contract. It must not be treated as a physical line merely because the order has other physical supplier invoices.

## 8. Delivery, tracking, package, and shipper truth

Every delivery/tracking allocation must preserve at least:

```text
order_id
supplier_invoice_id
supplier_invoice_line_id
tracking_submission_id
tracking_line_allocation_id
allocated_qty
allocated_value_gbp
```

Lines from different supplier invoices may be assigned to:

- the same tracking reference;
- different tracking references;
- the same package;
- different packages;
- the same shipment batch;
- different shipment batches.

The shared delivery-allocation loader must load all active progressed physical lines for the order, not only the latest supplier invoice.

The existing allocation action and quantity safeguards must be reused. No new delivery-allocation workflow is created.

Shipper pages continue to derive contents through tracking/package allocations and supplier invoice lines. Shippers do not receive supplier invoice totals, VAT, DVA/card, customer pricing, or Sage data.

## 9. Supplier AP and supplier-payment allocation

Each approved supplier invoice remains a separate supplier AP purchase-invoice candidate and a separate supplier accounting document.

A physical bank/card OUT remains one physical statement transaction and must be matched once.

Where one physical OUT paid several supplier invoices:

- reuse the existing statement-line allocation machinery;
- allocate the one source transaction across exact supplier invoice/AP targets;
- retain one source statement line and one physical transaction identity;
- ensure the confirmed allocation total cannot exceed the source OUT;
- preserve exact supplier invoice allocation amounts;
- do not invent duplicate bank statement rows;
- do not invent a split based on customer funding proportions;
- do not post the same physical cash movement more than once.

Supplier funding provenance remains order/source-lot controlled and must be traceable before supplier-payment readiness clears.

## 10. Customer sales release ledger

A durable customer release ledger is mandatory before reliable repeated releases are enabled.

Use a table such as:

```text
customer_sales_release_lines
```

or an equivalent durable structure.

Each membership must retain at least:

```text
sales_invoice_id
sales_invoice_type
order_id
supplier_invoice_id
supplier_invoice_line_id
tracking_submission_id
tracking_line_allocation_id
released_qty
goods_amount_gbp
delivery_share_gbp
discount_share_gbp
shipping_amount_gbp
release_status
created_at
reversed_at
```

The ledger, not a reconstructed display payload, is the source of truth for whether quantity or value has already been customer-released.

It must enforce:

1. A source tracking allocation or exact source quantity cannot be actively billed twice.
2. The first customer sales release for the commercial parent order is `main`.
3. Later eligible releases are `supplementary`.
4. More than one supplementary release is permitted.
5. A retry with the same release membership is idempotent and reuses the existing draft/result.
6. Voiding or superseding a draft does not silently free source membership without an audited reversal.
7. Source IDs from the existing release preview must survive draft creation.
8. Customer invoice JSON may mirror the ledger but must not replace it.
9. Sage posting remains through the existing freeze, validation, batch, and confirmation route.
10. A document is not marked posted until Sage confirms the posting result.

## 11. Customer sales document model

The existing document types remain:

```text
main
supplementary
credit_note
```

The order retains one non-void `main` customer sales invoice.

Later stable subsets may create repeated `supplementary` customer sales invoices linked to the main invoice where the current schema allows.

A shipping-only supplementary route already supported by the platform must remain compatible.

Customer sales release is progressive by stable source membership. Partial release must never be presented as whole-order completion.

VAT remains governed by the existing prepayment-first and sales-document reporting controls. Main and supplementary documents must not duplicate Box 6 where the value was already recognised under the approved prepayment timing rule.

## 12. Repeat customer review cycles

Every customer review cycle must have immutable line membership.

A review link must not dynamically acquire supplier lines, tracking allocations, or package contents that became eligible after the review link was created.

A line may enter a new review cycle only when it is:

```text
on an active supplier invoice
progressed
allocated to known tracking/package scope
received clean
not already actively customer-released
not under an active hold
not linked to an unresolved exception
not already assigned to another active review cycle
```

The review snapshot must retain the exact supplier line, tracking allocation, package, quantity, and review-link membership.

A later supplier invoice or later received-clean package creates a later review cycle containing only newly eligible source membership.

Creating a later review must not reopen, rewrite, or silently expand an earlier review.

## 13. Customer hold initiation and role boundary

A customer may request an order-, package/tracking-, or line-scoped hold through the customer review route.

A submitted hold enters supervisor review.

Before supervisor approval, the hold must not independently authorise:

- operator contact with the retailer;
- refund pursuit;
- replacement creation;
- supplier credit-note approval;
- physical return;
- customer credit-note creation;
- Sage or statement-line action.

The supervisor may approve, reject, hold, query, or require narrowing.

After supervisor approval, the approved scope becomes an active physical set-aside instruction and, where exact line membership exists, may bridge into the existing exception workflow.

## 14. Hold scope rules

### 14.1 Order hold

An approved order hold blocks every customer sales release and every shipment inclusion for the order while it remains active.

An order hold is not sufficiently precise for supplier refund accounting. It must be narrowed or materialised into exact supplier invoice line membership before a refund dispute is created.

### 14.2 Package/tracking hold

An approved package/tracking hold blocks that exact package or tracking scope.

Where package contents are complete and known, the system must materialise an immutable set of the package's exact supplier invoice lines and quantities.

Those exact lines may enter one compatible operational refund dispute without requiring the customer to select every line again.

Where package membership is unknown, incomplete, over-allocated, or disputed, the physical package remains set aside but refund conversion fails closed until exact affected line membership is proven.

### 14.3 Line hold

An approved line hold excludes only the exact supplier invoice line and quantity represented by that hold.

Other clean and unheld lines remain eligible for shipment and customer sales release, subject to the normal gates.

### 14.4 Nested customer invoice payloads

Any hold-conflict helper retained for compatibility must inspect both:

- legacy top-level line arrays; and
- the current nested `line_items_json.lines` structure.

A scoped line or package hold must not be broadened to an order-wide block merely because one compatibility helper cannot read the current JSON shape.

## 15. Patched customer-hold-to-exception bridge

This section is the controlling correction for Mini-build 4.

An approved customer hold may create or link the existing refund exception whether the affected line is:

```text
unprogressed
or
progressed, tracked, and received clean
```

The conversion must not reset, delete, or falsify:

- `eligible_for_invoice_yn`;
- confirmed quantity or amount;
- supplier invoice identity;
- tracking allocation;
- package membership;
- receipt evidence;
- shipment evidence;
- progression timestamp;
- source evidence;
- audit timestamps.

Progression and tracking prove what was purchased and physically received. The hold and dispute prove why that item must not be released or shipped.

The conversion trigger or function must no longer reject an exact line merely because:

```text
eligible_for_invoice_yn = Y
```

Instead, conversion must require:

1. Hold status is `supervisor_approved`.
2. Exact line membership and affected quantity are known.
3. The supplier line belongs to the hold's order.
4. The supplier invoice is active.
5. The hold is line-scoped or package membership has been materialised into exact lines.
6. The same unresolved line/quantity is not duplicated into another incompatible dispute.
7. The relevant quantity has not already been customer-released through a non-void customer sales document.
8. A compatible existing open refund dispute is reused rather than duplicated.
9. `refund_approved_at` and the approving staff identity reflect the supervisor's approved customer hold.
10. Tenant/importer/order ownership checks remain enforced.

The existing unprogressed route and the progressed customer-review route must converge on the same dispute, retailer, return, refund evidence, DVA/card refund-IN, supplier-credit, and Sage controls.

## 16. Existing refund route must be reused

Once the approved hold creates or links a refund dispute, the route is:

```text
supervisor-approved customer hold
→ refund pursuit already approved
→ operator/importer contacts retailer
→ operator records retailer response
→ supervisor accepts or rejects final retailer outcome
→ operator uploads retailer return/collection instructions when required
→ shipper executes the physical return action
→ supervisor reviews shipper proof
→ operator uploads supplier credit note/refund/no-document evidence
→ retailer refund IN is matched in the existing DVA/card workspace
→ supplier credit-note accounting and Sage controls continue
→ exception closes only when the required physical and financial gates clear
```

No separate “customer-hold refund” workflow, table family, workbench, or Sage route may be created.

Operator/importer execution and supervisor control boundaries remain as defined by the existing exception route contract.

## 17. Shipper visibility and physical return

Immediately after supervisor approval, the shipper's existing hold worklist must show the applicable instruction:

```text
SET ASIDE / DO NOT SHIP
```

This is worklist visibility. It is not proof that a shipper user opened the page, and it is not a push notification.

At hold approval, the shipper is not automatically instructed to return the goods.

The actionable return route appears only when the operator/importer has submitted retailer return information through the existing exception lane, such as:

- retailer return instructions;
- return label;
- courier;
- collection or tracking reference;
- tracking/evidence URL;
- required action;
- operational note.

The shipper then uses that existing information to complete the collection/return and submit proof.

The shipper must never see or alter VAT, refund value, supplier coding, supplier credit-note approval, DVA/card allocation, customer credit-note decisions, or Sage controls.

## 18. Hold lifecycle and operational closure

An approved hold must not remain indefinitely in the active shipper set-aside queue after the physical scope has been resolved.

The hold must stop qualifying as an active set-aside when one of the following occurs:

- supervisor rejection;
- supersession by a narrower approved hold;
- explicit supervisor clearance;
- approved cancellation of the route;
- accepted physical return/collection proof for the affected scope;
- permanent approved removal from shipment scope;
- another approved terminal exception outcome that clears the physical hold.

Audit history must remain. Operational closure removes the active instruction, not the record.

The existing shipper next-state sequence remains:

```text
set aside only
return action ready
return proof submitted
return accepted
cleared or superseded
```

Physical return acceptance does not by itself prove that refund money was received or that the supplier credit note was posted.

## 19. Multi-invoice refund and supplier-credit provenance

One operational refund dispute may contain affected lines from several supplier invoices.

The physical hold, package return, and retailer conversation may remain one operational case where appropriate.

Supplier refund evidence and supplier credit-note accounting must remain separated by original supplier invoice.

Each structured refund/credit submission must preserve at least:

```text
dispute_id
original_order_id
original_supplier_invoice_id
affected_supplier_invoice_line_ids
credit_note_ref
credit_note_date
credit_note_or_refund_file
net_gbp
vat_gbp
gross_gbp
refund_statement_allocation_ids
sage_source_and_posting_trace
```

Where one package contains lines from several original supplier invoices:

- package membership is materialised once;
- dispute lines remain exact;
- supplier credit documents remain tied to their original supplier invoices;
- refund money is allocated once and cannot be counted twice;
- one supplier credit note must not be falsely attached to an unrelated supplier invoice.

## 20. Customer credit notes

The normal customer review route occurs before customer invoicing. Held lines should therefore ordinarily be excluded from customer release rather than credited later.

Where affected quantity has already appeared on a non-void customer sales document:

- it must not silently re-enter the pre-shipment hold conversion route;
- the existing exception may continue for supplier refund and physical return purposes;
- a customer credit note is required for the released customer value;
- the credit note must reference the exact affected customer sales invoice;
- a correction spanning a main and one or more supplementary invoices requires a separate customer credit note for each affected customer sales invoice;
- supplier credit notes and customer credit notes remain separate legal and accounting documents.

The single `linked_invoice_id` relationship on a customer credit note must not be stretched to represent several original customer sales invoices.

## 21. Replacement boundary

Replacement continues through the existing `replacement_child` route.

This addendum must not broaden replacement eligibility for OCR/supplier-issued lines where the current replacement action only permits the existing approved source class.

A replacement child remains a separate operational fulfilment order.

Whether later replacement value is customer-invoiced depends on whether that value was already released to the customer, not merely on the existence of a replacement child.

## 22. Supplier invoice rejection and correction safety

A supplier invoice may be rejected or corrected only while downstream facts remain safely reversible.

Rejection must fail closed once any of its lines or document identity is used in:

- tracking allocation;
- immutable customer review membership;
- active customer hold;
- unresolved exception;
- customer sales release membership;
- frozen or posted supplier AP;
- confirmed supplier-payment allocation;
- supplier refund or credit-note control;
- frozen or posted customer sales evidence;
- another irreversible accounting artefact.

Until the release ledger exists, customer-sales rejection safety must be conservative: once a non-void customer main or supplementary draft/posting exists for the order, rejection requires the controlled correction route.

Corrected same-reference resubmission remains available through the existing upload/review route.

## 23. Role boundaries

### Customer

- Reviews only the immutable lines assigned to the current review cycle.
- Requests order-, package-, or line-scoped holds.
- Does not approve refunds, returns, supplier documents, or accounting actions.

### Importer/operator

- Adds and corrects supplier invoices individually.
- Reconciles one selected supplier invoice at a time.
- Sees one order-wide bundle summary.
- Adds tracking and allocates exact lines from every active supplier invoice.
- Contacts the retailer only after supervisor approval/push.
- Submits retailer responses, return instructions, and refund/credit evidence through the existing exception lane.

### Supervisor

- Reviews and rejects exact supplier invoices.
- Progresses, codes, and approves exact documents and lines.
- Sees the aggregate order position.
- Approves, rejects, holds, queries, narrows, or clears customer holds.
- Controls exception initiation and final retailer outcome.
- Reviews shipper return proof and refund/credit evidence.

### Shipper

- Sees physical package and allocated item truth.
- Sees supervisor-approved set-aside instructions.
- Sees actionable return instructions only after operator/importer submission.
- Submits collection/return outcome and physical proof.
- Does not see supplier/customer invoice values, VAT, DVA/card, or Sage data.

### Admin/accounting

- Sees separate supplier AP and supplier-credit documents.
- Sees one collective order readiness position.
- Sees exact customer release provenance.
- Cannot release the same source quantity twice.
- Cannot treat partial release, partial refund, or physical return as full financial closure.

## 24. Existing pages and functions must be reused

The build must extend existing routes rather than create duplicates, including where applicable:

```text
/importer/orders/[order_id]/operations
/importer/reconciliation/[order_id]
/internal/reconciliation/[order_id]
/internal/reconciliation/[order_id]/staff-confirm-lines
/internal/customer-holds
/shipper/customer-holds
/importer/exceptions
/importer/exceptions/[dispute_id]
/internal/exceptions
/internal/exceptions/[dispute_id]
/shipper/return-actions
/internal/refund-document-control
/internal/dva-reconciliation/workspace
/internal/accounting-command-centre
```

Existing exact-invoice, exact-line, allocation, refund evidence, supplier credit, and Sage primitives must be reused wherever they already enforce the required controls.

## 25. Explicit non-goals

This build must not:

- change original order creation;
- create a second supplier invoice upload lane;
- create a second delivery-allocation lane;
- create a second customer hold workbench;
- create a second exception, refund, return, supplier-credit, or Sage workflow;
- merge supplier invoices into one artificial legal document;
- invent statement transactions or bank splits;
- split supplier payments using customer funding proportions;
- bypass source-lot funding provenance;
- replace Mindee with another OCR provider;
- expose financial values to shippers;
- allow an operator to final-approve a retailer outcome;
- mark Sage documents posted before Sage confirms;
- weaken tenant isolation or RLS;
- broaden replacement eligibility outside its existing approved route;
- alter existing VAT, shipper AP, cash posting, loyalty, or funding rules except where they consume the new exact provenance.

## 26. Implementation sequence

The addendum is implemented through four independently reversible mini-builds.

### Mini-build 1 — supplier document and bundle foundation

- replace the one-current-invoice-per-order constraint with one-current-version-per-order-and-reference;
- preserve duplicate gates;
- preserve corrected same-reference resubmission;
- add rejection safety;
- add bundle line and summary read models;
- exclude retired invoices from active operational status.

### Mini-build 2 — portal integration

- importer adds, corrects, and navigates several supplier invoices;
- importer and supervisor reconciliation retain exact invoice selection;
- order-wide summary appears above exact-document work;
- delivery allocation loads all active progressed lines;
- admin readiness requires all represented active supplier invoices to be approved;
- shipper pages receive regression coverage without financial redesign.

### Mini-build 3 — customer release provenance

- add the durable release ledger;
- preserve preview source IDs in draft creation;
- allow one main and repeated supplementaries;
- enforce idempotency and no double billing;
- retain existing Sage freeze, validation, and posting route.

### Mini-build 4 — immutable review, scoped holds, and patched exception bridge

- add immutable review-cycle membership;
- calculate newly eligible review lines from received-clean unreleased source membership;
- enforce order/package/line hold scope;
- read nested and legacy customer invoice payloads where compatibility requires;
- allow progressed/tracked/received-clean approved held lines to use the existing refund path;
- allow a known whole package to bridge by materialising exact contained lines;
- preserve progression, tracking, receipt, and audit evidence;
- clear resolved holds from the active shipper set-aside worklist without deleting history.

Mini-build 4 depends on Mini-build 3 for definitive already-customer-released checks. The trigger correction may be developed earlier but must not be treated as fully released without durable release membership.

## 27. Preflight and release discipline

Before each mini-build:

1. Record current branch and commit.
2. Run `npm run lint`.
3. Run `npm run build`.
4. Inspect exact live Supabase function definitions, indexes, triggers, views, and relevant table columns.
5. Compare live definitions with the repo.
6. Stop if material drift invalidates the planned patch.

Each mini-build must have:

- its own branch and bounded commit;
- additive corrective migrations only;
- prerequisite assertions;
- transaction-based SQL regression coverage;
- portal smoke tests for every affected role;
- no live Sage posting during regression;
- no merge until its exit criteria pass.

Historical deployed migrations must not be edited or deleted. Corrections use new migrations and, where rollback is necessary, compensating migrations.

## 28. Required regression matrix

At minimum, the combined regression pack must prove:

1. Existing one-invoice order remains unchanged.
2. Three supplier invoices can coexist.
3. Approving one supplier invoice does not alter its siblings.
4. Same-reference live duplicate is blocked.
5. Corrected rejected same-reference invoice replaces only its own version family.
6. Rejecting one invoice leaves active sibling invoices untouched.
7. Rejection after irreversible downstream use fails closed.
8. Retired invoice lines disappear from every active bundle and downstream queue.
9. Bundle quantity and value reconcile to the order baseline.
10. Importer and supervisor can navigate exact invoices.
11. Delivery allocation lists progressed lines from every active invoice.
12. Lines from several supplier invoices can share one package.
13. Shipper sees correct combined package contents without financial values.
14. Supplier AP produces separate purchase-invoice candidates.
15. One physical OUT can allocate across several supplier invoices without duplicate cash posting.
16. First stable customer release creates one main invoice.
17. Three later stable releases create three supplementaries.
18. Retry/concurrency does not duplicate source membership or documents.
19. One tracking allocation split by quantity cannot be over-billed.
20. Old review links do not acquire later supplier lines.
21. A later review contains only newly eligible source membership.
22. Line hold excludes only the exact held line/quantity.
23. Tracking/package hold excludes the exact package.
24. A known package containing lines from several supplier invoices materialises exact dispute lines.
25. Unknown package membership fails closed for refund conversion.
26. Progressed, tracked, received-clean held line converts to the existing refund dispute after supervisor approval.
27. Unprogressed held line continues to use the same existing refund dispute route.
28. Progression, tracking, package, and receipt evidence remain unchanged after conversion.
29. Compatible existing refund dispute is reused rather than duplicated.
30. Shipper sees set-aside after supervisor approval.
31. Shipper does not receive a return action until operator/importer instructions exist.
32. Shipper proof moves to supervisor review and can be accepted/held/rejected.
33. Accepted physical return removes the active set-aside instruction while preserving audit history.
34. Physical return acceptance does not falsely mark refund money received.
35. Supplier refund evidence remains separated by original supplier invoice.
36. Retailer refund IN is matched once and cannot exceed the source statement transaction.
37. Customer-released affected value routes to customer credit notes rather than silent exclusion.
38. A correction spanning main and supplementary sales invoices creates a separate customer credit note per affected sales invoice.
39. Replacement child remains separate and existing replacement eligibility is unchanged.
40. Sage status changes to posted only after confirmed Sage response.
41. Existing VAT, shipper AP, cash posting, funding, loyalty, and tenant controls remain unchanged.

## 29. Acceptance rule

The architecture is complete only when the platform can prove, from exact source records:

```text
what the retailer legally invoiced
what the order collectively contains
what was progressed
what entered each package
what the customer reviewed
what the customer held
what was excluded or refunded
what the shipper set aside or returned
what was customer-invoiced
what supplier document was credited
what physical money moved
what Sage accepted
and what remains unresolved
```

No status, total, release, refund, or posting may be inferred solely from “latest supplier invoice”, order-wide dynamic JSON, or the existence of one successful sibling document.

## 21. One physical OUT across multiple supplier invoices

One physical OUT may cover supplier invoices A, B and C plus a final FX/card residual. Each invoice allocation is capped at `min(statement remaining, invoice remaining)`, and the same OUT remains available in the main importer-matching workspace until its balance is exhausted. Every supplier and residual allocation remains an individually auditable and reversible economic-use row, while the final invariant is strict: total confirmed uses must not exceed the physical OUT.

Existing atomic bundle routines remain available for a one-click, multi-leg database commit. They are transaction guarantees and are not a separate normal operator workbench.
