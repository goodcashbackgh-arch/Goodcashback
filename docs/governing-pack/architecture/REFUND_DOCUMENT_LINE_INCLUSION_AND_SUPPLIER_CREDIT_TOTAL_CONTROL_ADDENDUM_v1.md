# Refund Document Line Inclusion and Supplier Credit Total Control Addendum v1

Status: governing contract for build work

Source branch at drafting: `main`

## 1. Purpose

This addendum governs the treatment of structured refund-document lines after a formal supplier credit note, refund proof without a credit note, or no-document refund submission has been captured.

It introduces a reversible, audited inclusion decision so that duplicate, irrelevant, or incorrectly created lines can be excluded from supplier-credit processing without deleting the source evidence or creating a parallel workflow.

The control must reuse the existing refund-document OCR, release, coding, refund-IN matching, approval, Sage-readiness, freeze, and purchase-credit-note posting lanes.

## 2. Authority and precedence

This addendum sits alongside and builds on:

1. `docs/governing-pack/CURRENT_LOCKED_PACK.md`
2. `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`
3. the existing refund-document workbench and credit-note OCR controls;
4. the existing supplier-credit-note accounting and Sage posting lane;
5. the existing formal credit-note date, alignment, approval, and freeze guards.

Where an older implementation assumes that every stored refund-document line must always enter supplier-credit processing, this addendum controls.

## 3. Governing business truth

```text
Stored evidence is not the same as accepted supplier-credit scope.

A refund-document line may remain immutable evidence while being excluded
from release, coding, refund-IN settlement and Sage posting.

Only included lines form the accepted supplier-credit line set.
```

No evidence row may be physically deleted merely because it is duplicated, irrelevant, or not part of the accepted supplier credit.

## 4. Definitions

### 4.1 Stored evidence line

A row in `dispute_refund_document_lines`, including:

- `ocr_extracted`;
- `operator_prefill`;
- `delivery_adjustment`;
- `discount_adjustment`;
- any later controlled evidence-line source.

### 4.2 Included line

A stored evidence line currently authorised to participate in supplier-credit alignment, release, coding, settlement and Sage posting.

### 4.3 Excluded line

A stored evidence line retained for audit but omitted from every supplier-credit progression and accounting calculation.

### 4.4 Formal credit-note face total

The verified gross total printed on the supplier credit note and stored as the OCR credit-note total.

### 4.5 Supplementary refund outside the credit note

A genuine additional refund component not printed anywhere on the formal credit note and not included in its face total. It may be represented by an included delivery or discount adjustment evidence line.

### 4.6 Accepted supplier credit

The authoritative amount that must be used consistently by coding, approval, refund-IN allocation, Sage readiness, payload freezing and purchase-credit-note posting.

## 5. Inclusion model

Every existing and future refund-document line defaults to included.

The durable control fields are:

```text
included_in_supplier_credit_yn
exclusion_reason
excluded_by_staff_id
excluded_at
```

A restore action clears the exclusion metadata and returns the line to included status.

The implementation may retain the inverse physical column name where necessary for compatibility, but all read models and UI must present the positive business meaning: included or excluded from supplier credit.

## 6. Staff action and audit requirements

Only an active admin or supervisor may exclude or restore a line.

A reason is mandatory for exclusion and restoration.

Each action must write an immutable internal audit message containing:

- submission ID;
- line ID;
- line source;
- description;
- amount;
- previous inclusion state;
- new inclusion state;
- staff ID;
- reason;
- timestamp.

The source evidence row remains present and readable after exclusion.

## 7. Lock boundaries

Exclusion or restoration is permitted only before accounting progression becomes durable.

The action must fail closed where any of the following is true:

1. the target line has been released to supplier control;
2. any accounting code exists for the target line;
3. any line on the submission has already been released, where changing scope would invalidate the established submission alignment;
4. the submission is approved current;
5. an active Sage posting snapshot exists;
6. the submission is rejected and audit-only;
7. the submission does not belong to an accessible refund-document record;
8. the requested state is already the current state.

The implementation must use row locking and recheck these conditions within the write transaction.

## 8. Formal credit-note alignment

For `document_mode = 'credit_note'`:

```text
included OCR line gross total
= formal credit-note face total
```

Only included `ocr_extracted` lines participate in this document-line alignment test.

Included supplementary delivery or discount lines outside the formal credit note do not cause the formal document-line comparison to fail.

Reference, date, retailer and header-amount matching remain unchanged.

A formal credit note cannot become ready for release unless:

- OCR is completed;
- reference, date, retailer and header amount are aligned;
- at least one included OCR line exists;
- included OCR lines reconcile to the OCR credit-note face total;
- no other existing control blocks readiness.

## 9. Accepted supplier-credit total

For a formal credit note:

```text
accepted supplier credit
= verified OCR credit-note face total
+ included supplementary delivery refunds outside the credit note
+ included supplementary discount refunds outside the credit note
```

For refund proof without a credit note and no-document evidence:

```text
accepted supplier credit
= sum of all included evidence lines
```

Manual accounting adjustment rows do not define or increase accepted evidence. They remain accounting reconciliation rows only.

The expected exception amount is not an accepted-credit fallback. It is used to calculate any residual unresolved shortfall:

```text
unresolved shortfall
= greatest(expected exception amount - accepted supplier credit, 0)
```

The expected exception amount must never inflate the Sage purchase credit note.

## 10. One authoritative downstream amount

The same accepted supplier-credit total must govern:

1. refund-document accounting totals;
2. gross reconciliation and approval;
3. refund-IN allocation coverage;
4. Sage-readiness blockers;
5. frozen posting payload totals;
6. final Sage purchase-credit-note gross.

No downstream function may recompute the accepted amount using `GREATEST(...)` across expected exception, dispute impact, captured amount or other targets for formal credit notes.

## 11. Release and coding behaviour

Excluded lines:

- must not appear in the active release selection;
- cannot be released;
- cannot be coded;
- do not count as progressed or uncoded lines;
- do not contribute to gross reconciliation;
- do not enter Sage payload construction.

They must remain visible in a separate audit-only section with their exclusion reason, staff and timestamp.

Included lines continue through the existing release and coding actions without a replacement workflow.

## 12. OCR fetch and correction behaviour

OCR safe fetch may continue to replace unreleased `ocr_extracted` rows for a fresh OCR result.

It must not delete or silently reactivate non-OCR supplementary evidence lines.

Where an OCR line identity is recreated by the existing fetch process, the implementation must either preserve a durable exclusion decision through stable provenance or require the staff inclusion review to be repeated before release. It must never silently progress a previously excluded economic line.

Header correction must recalculate alignment using included OCR lines only.

## 13. User interface contract

The existing credit-note OCR page is the inclusion-control surface.

It must show:

- included lines available for exclusion;
- excluded lines in an audit-only section;
- `Exclude selected lines`;
- `Restore selected lines`;
- a mandatory reason;
- the included OCR document total;
- included supplementary total;
- accepted supplier-credit total.

The existing refund-document control page remains the release and coding surface and must receive only included active lines.

No separate coding page or parallel supplier-credit workflow is permitted.

## 14. Existing delivery and discount inputs

Delivery and discount evidence inputs remain available for all existing document modes because they are required for genuine supplementary refunds and for no-credit-note routes.

For formal credit notes, UI wording must make clear that these fields are only for amounts not printed on, and not included in, the formal credit note.

A line may still be excluded after OCR where the operator entered a supplementary amount that the credit note itself already contains.

## 15. Manual accounting adjustment boundary

`dispute_refund_document_accounting_adjustment_lines` remains a separate accounting-only mechanism for controlled rounding or accounting reconciliation.

It must not be used to:

- remove duplicate evidence;
- replace an excluded evidence line;
- manufacture accepted supplier credit;
- bridge a residual exception shortfall into Sage.

## 16. Resubmission boundary

Line exclusion is appropriate for a duplicate or irrelevant line within otherwise valid evidence.

Resubmission remains required where the submission contains:

- the wrong legal credit-note file;
- the wrong original supplier invoice;
- a materially incorrect credit-note reference or date that cannot be corrected under the existing header-correction control;
- evidence belonging to another dispute or supplier document;
- another defect that makes the legal source itself unreliable.

## 17. Migration and compatibility

The migration must be additive and default every existing line to included.

Existing approved, frozen or posted submissions must not be changed or reopened.

Existing no-credit-note and no-document flows must continue to work without requiring OCR.

Existing line IDs, accounting-code records, release provenance and Sage source IDs must remain stable.

## 18. Required regression scenarios

The implementation is not complete until the following pass:

1. Formal CN contains goods £179.99 and delivery £5.00; duplicate operator delivery £5.00 is excluded; included OCR total and accepted supplier credit both equal £184.99.
2. A genuine £5.00 supplementary refund outside a £179.99 formal CN remains included; accepted supplier credit equals £184.99 while OCR document alignment remains £179.99.
3. Excluded rows remain visible but cannot be released, coded or posted.
4. Restoring a pre-release line recalculates readiness and accepted totals.
5. Exclusion fails after line release, coding, approval or active Sage freeze.
6. Refund proof without a credit note uses included operator/evidence lines as its accepted total.
7. No-document evidence uses included evidence lines and preserves supervisor review requirements.
8. Expected exception amount greater than accepted supplier credit creates a residual shortfall but does not inflate Sage gross.
9. Refund-IN allocation must cover accepted supplier credit, not expected exception value.
10. Sage resolved lines and gross contain included evidence lines and permitted accounting reconciliation rows only.
11. An approved/frozen/posted legacy submission is unchanged by the migration.
12. Every exclude/restore action creates an immutable audit message.

## 19. Non-goals

This addendum does not:

- change the legal supplier invoice or credit-note identity;
- create customer credit notes;
- alter refund payment routing;
- replace bank/DVA/card reconciliation;
- change VAT rates or nominal coding policy;
- create a new Sage endpoint;
- delete source evidence;
- reopen approved or posted documents.
