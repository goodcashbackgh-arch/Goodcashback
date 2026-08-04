# Grouped Physical Refund Final-Outcome Alignment Addendum v1

**Status:** governing corrective clarification and non-regression authority  
**Effective date:** 4 August 2026  
**Applies to:** hybrid physical receipt grouped refund lanes

## 1. Purpose

This addendum corrects the grouped physical-refund integration so that it reuses the established refund route without replacing, bypassing or duplicating any upstream or downstream authority.

The grouped lane is an orchestration surface only. It is not a settlement authority.

## 2. Controlling sequence

The required refund sequence is:

```text
physical receipt partitions affected quantities into downstream-compatible refund disputes
-> operator records retailer response
-> supervisor accepts the final retailer refund outcome
-> every selected refund dispute reaches awaiting_refund_credit
-> importer/operator submits refund document evidence through the existing evidence authority
-> existing refund-document review, supplier-control, accounting, VAT and Sage controls continue
-> existing customer-settlement authority confirms customer credit only when its normal blockers are clear
```

## 3. Grouped supervisor action

One grouped supervisor action may accept the final retailer outcome for all compatible refund items in one lane.

The grouped action must:

- require an active supervisor or admin;
- require every selected remedy allocation to belong to the refund lane;
- require exact unresolved physical-item coverage for each affected dispute;
- require the existing refund-pursuit approval;
- require a recorded retailer reply;
- require each unresolved line to be at `retailer_response_received`;
- advance each selected dispute only through the legal status spine:

```text
raised -> under_review -> approved_refund -> awaiting_refund_credit
```

- record one grouped decision using `refund_final_outcome_accept`;
- leave the lane in `partially_resolved` while importer evidence and downstream controls remain outstanding;
- preserve the existing same-order free-replacement behavior for replacement lanes.

## 4. Prohibited behavior

The grouped supervisor action must not:

- resolve dispute lines;
- set `conversation_status = resolved_credit`;
- set `resolution_method = refund`;
- set dispute status to `refunded` or `closed`;
- create or update an `importer_credit_ledger` settlement-credit row;
- call `staff_confirm_order_settlement_credit_v1`;
- call `staff_close_refund_exception_as_settlement_credit_v1`;
- auto-submit, auto-approve or auto-link refund evidence;
- introduce a trigger or parallel evidence route;
- change invoice-progression, refund-document, DVA/card, settlement, VAT, Sage or accounting authorities.

## 5. Protected existing authorities

The following existing authorities remain unchanged and authoritative:

```text
operator_update_dispute_retailer_update(uuid,text,text)
operator_submit_refund_document_evidence(uuid,uuid,uuid,text,text,date,numeric,text,text,jsonb,numeric,numeric,text)
link_physical_outcome_refund_evidence_v1(uuid,uuid[],uuid,text)
staff_confirm_order_settlement_credit_v1(uuid,text,text)
internal_order_settlement_resolution_v1(uuid)
operator_mark_supplier_invoice_line_progressed(uuid,uuid)
operator_bulk_mark_supplier_invoice_lines_progressed(uuid,uuid[])
```

The grouped implementation must integrate into those authorities rather than replace them.

## 6. UI contract

The refund lane must use the wording:

```text
Final refund outcome
Accept final refund outcome
```

After acceptance, the lane must show:

```text
awaiting importer refund evidence
```

The UI must state that customer credit has not been created and remains controlled by the existing downstream settlement route.

## 7. Corrective fixture restoration

The seeded grouped-outcome fixture affected on 4 August 2026 must be restored by removing only the erroneous grouped settlement artifacts and returning its refund lane to the pre-decision state.

The restoration must preserve:

- the seeded funding contribution;
- the posted customer invoice;
- retailer replies;
- refund-pursuit approval timestamps;
- replacement lane state;
- all protected authorities.

The restored fixture state is:

```text
refund lane: awaiting_supervisor_decision
refund disputes: raised, unresolved
refund lines: affected, retailer_response_received, unresolved
settlement position: credit_due
settlement credit rows: 0
replacement lane: unchanged
```

## 8. Release gate

A release passes only when:

- the grouped refund action reaches `awaiting_refund_credit` and stops;
- no refund line is resolved by that action;
- no settlement-credit row is created by that action;
- importer refund evidence remains required;
- the replacement lane remains on the original order and creates no child order;
- invoice-progression and existing refund downstream authorities retain their reviewed definitions and behavior.
