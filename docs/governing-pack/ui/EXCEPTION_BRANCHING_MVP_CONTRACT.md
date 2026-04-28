# Exception Branching MVP Contract

Status: contract only (MVP v3).

This document defines the fastest safe MVP flow for unresolved invoice-line exceptions after importer OCR/manual reconciliation. It is intentionally conservative: use existing schema and current operational lanes; do not add schema unless a tested blocker proves it is required.

---

## Governing sources checked

Primary sources reviewed before drafting:

- `docs/governing-pack/ui/INVOICE_LINE_RECONCILIATION_ACTION_CONTRACT.md`
- `docs/governing-pack/role-matrices/importer_role_stage_matrix_v7.md`
- `docs/governing-pack/backend/goodcashback-complete.v4.sql`

Key governing rules used:

- Correct lines may progress while unresolved lines become child exceptions.
- Parent order is fully cleared only when progressed lines plus resolved child outcomes reconcile back to the original submitted quantity/value.
- Funding recognition delay must not block operational reconciliation, child-exception creation, ready-for-shipment handoff, retailer communication, or shipper/logistics progression where goods are genuinely moving.
- Refund branch requires supervisor/admin approval before importer can pursue the refund route with the retailer.
- Replacement branch can proceed into retailer communication without the refund-specific approval gate.
- Importer/operator owns retailer conversation logging because they operate the retailer account.
- Staff/supervisor owns review, refund pursuit approval, final outcome acceptance, and replacement child creation approval.
- Final retailer outcome must be accepted/reviewed by supervisor/admin before downstream refund settlement or replacement child order creation.

---

## 1) MVP principle

The parent order remains the anchor.

For one parent order, the platform may show parallel lanes:

1. Progressed goods lane — clean invoiceable subset moving toward shipper/logistics, shipment evidence, delivery, invoicing/accounting release later.
2. Refund exception lane — unresolved lines grouped into a refund case, supervisor approval required to pursue refund, then importer-owned manual retailer conversation, then supervisor acceptance of final retailer outcome.
3. Replacement exception lane — unresolved lines grouped into a replacement case, importer-owned manual retailer conversation, then supervisor acceptance of final retailer replacement outcome, then replacement child order creation.

Do not collapse these lanes into one misleading status. One parent order can be partially progressed and still have open exception branches.

---

## 2) Schema mapping for MVP

Use existing schema only.

### Parent order

- `orders.id` = parent anchor
- live DB normal parent order type = `orders.order_type = 'original'`
- live DB replacement child type = `orders.order_type = 'replacement_child'`
- `orders.total_qty_declared`
- `orders.order_total_gbp_declared`

### Progressed invoiceable lines

- `supplier_invoice_lines.eligible_for_invoice_yn = 'Y'`
- `supplier_invoice_lines.qty_confirmed`
- `supplier_invoice_lines.amount_confirmed`
- surfaced through reconciliation/read models such as `order_reconciliation_vw`

### Exception case header

Use `disputes` as the grouped exception case header:

- `disputes.order_id` = parent order id
- `disputes.issue_type` = closest MVP issue classification, normally `missing`, `wrong_item`, `damaged`, `defective`, or `not_as_described`
- `disputes.desired_outcome` = `refund` or `replacement`
- `disputes.amount_impact_gbp` = total impact of grouped exception lines
- `disputes.status` = case-level status
- `disputes.refund_approved_by_staff_id` / `refund_approved_at` = approval to pursue refund route
- `disputes.replacement_child_order_id` = set only after retailer replacement outcome is agreed and supervisor accepts the outcome

### Exception line detail

Use `dispute_lines` for affected line-level detail:

- `dispute_lines.dispute_id` = grouped case header
- `dispute_lines.supplier_invoice_line_id` = affected OCR/manual line
- `dispute_lines.qty_impact`
- `dispute_lines.amount_impact_gbp`
- `dispute_lines.conversation_status`
- `dispute_lines.intended_remedy` = `refund` or `replacement`

### Conversation log

Use `dispute_messages` for the manual retailer conversation log now, and AI-ready conversation later:

- `message_type`
- `counterparty`
- `subject`
- `body`
- `generated_by = 'manual'` for importer-entered manual draft/log entries or staff internal notes where applicable
- `generated_by = 'retailer_paste'` for importer-pasted retailer replies
- later AI can use `generated_by = 'claude'`, `ai_input_context_json`, `ai_model_used`, and `ai_prompt_hash` without replacing the workflow

Ownership rule:

- Importer/operator logs retailer-facing conversation and retailer replies.
- Staff/supervisor may add internal notes only.
- Staff/supervisor must not be the primary actor for pasting retailer replies in MVP.

Message edit rule:

- Historical messages are immutable.
- The latest importer-submitted retailer response may be edited only until staff accepts a final outcome or downstream approval/settlement starts.
- After staff acceptance/approval that relies on the message, the message is locked.
- Corrections to older messages must be added as a new message.

### Retailer outcome state

Importer/operator must be able to mark the current retailer outcome for the exception case:

- still_waiting
- retailer_accepted
- retailer_disputed_or_rejected
- more_info_requested

MVP storage may use existing `dispute_lines.conversation_status` values and/or `disputes.status` conventions, but the UI must make the current outcome obvious to staff.

Staff/supervisor final acceptance depends on this importer-updated outcome plus at least one retailer conversation message.

### Replacement child order

Use existing order parent/child relationship only after replacement outcome is accepted:

- child `orders.parent_order_id` = original parent order id
- child `orders.order_type = 'replacement_child'`
- `disputes.replacement_child_order_id` = child order id

The child order then reuses existing operational lanes where applicable:

- tracking submission
- supplier invoice/evidence
- shipper quote/handoff
- shipment evidence/POD
- Ghana delivery
- downstream accounting/VAT release later

---

## 3) Grouping rule

For MVP, group unresolved lines by remedy intent under the same parent order:

- all selected refund-intent lines for the same parent order -> one refund dispute case
- all selected replacement-intent lines for the same parent order -> one replacement dispute case

Line-level audit remains under `dispute_lines`.

Avoid one workflow per line unless the importer/staff deliberately needs separate handling.

---

## 4) Refund branch MVP flow

1. Importer/operator identifies unresolved lines after reconciliation.
2. Importer selects remedy intent = refund for selected unresolved lines.
3. System creates or reuses one grouped refund dispute case for the parent order.
4. System creates `dispute_lines` for each selected affected line.
5. Refund case enters approval-required state to pursue refund with retailer.
6. Staff supervisor/admin approves or rejects permission to pursue refund route.
7. Once approved, importer contacts retailer manually and logs/pastes conversation in the case.
8. Retailer responds: agrees refund, rejects, asks for more info, or offers alternative.
9. Importer logs retailer response and selects current retailer outcome.
10. If retailer asks for more info, disputes, or rejects, importer can continue the manual loop and add further messages.
11. If retailer accepts refund, importer marks retailer outcome as accepted / ready for staff review.
12. Supervisor/admin reviews messages and accepts the final retailer refund outcome before downstream settlement.
13. Final settlement, payout, credit application, customer credit note, Sage/VAT release remain downstream and gated.

MVP shortcut allowed:

- Use simple staff approval UI/action against `disputes.refund_approved_by_staff_id` and `refund_approved_at` for permission to pursue refund.
- Use `dispute_messages` for manual retailer conversation and retailer replies.
- Use simple outcome buttons/dropdown for importer outcome marking.
- Evidence query pattern may be reused only to ask importer for missing proof, not to fake refund approval or final outcome acceptance.

---

## 5) Replacement branch MVP flow

1. Importer/operator identifies unresolved lines after reconciliation.
2. Importer selects remedy intent = replacement for selected unresolved lines.
3. System creates or reuses one grouped replacement dispute case for the parent order.
4. System creates `dispute_lines` for each selected affected line.
5. Importer contacts retailer manually and logs/pastes conversation in the case.
6. Retailer responds: agrees replacement, rejects, asks for more info, or offers alternative.
7. Importer logs retailer response and selects current retailer outcome.
8. If retailer asks for more info, disputes, or rejects, importer can continue the manual loop and add further messages.
9. If retailer accepts replacement, importer marks retailer outcome as accepted / ready for staff review.
10. Supervisor/admin reviews messages and accepts the final replacement outcome.
11. Only after accepted replacement outcome does the platform create a linked `replacement_child` order.
12. System links the child order through `disputes.replacement_child_order_id`.
13. Replacement child order uses existing order operational flow:
    - tracking
    - invoice/evidence upload
    - reconciliation if needed
    - shipping quote/handoff
    - delivery/POD
14. Child outcome reconciles back to the parent via the dispute case.

MVP shortcut allowed:

- Do not build full AI communication in v1. Manual message logging is enough if it preserves `dispute_messages`, `dispute_lines.conversation_status`, and `intended_remedy` so AI drafting can replace manual drafting later.

---

## 6) Rescind/delete rules for MVP

Exception-linked lines leave the normal unresolved-line editing/progression lane.

Hide or disable normal actions for lines linked to open `dispute_lines`:

- Save line
- Mark progressed
- Delete manual line
- progression checkbox
- create exception checkbox

Show instead:

- `In refund exception case`, or
- `In replacement exception case`

Allow rescind only while no downstream activity has started.

### Refund rescind allowed only if

- refund pursuit has not been approved (`refund_approved_at is null`)
- no retailer communication/message exists for the dispute
- no credit note, payout, Sage/VAT/accounting settlement exists

### Replacement rescind allowed only if

- replacement child order has not been created
- no retailer communication/message exists for the dispute
- no shipment/accounting/VAT activity exists

If rescinded, remove the open dispute line linkage and, if the grouped case becomes empty, close/delete the empty case. For MVP, hard delete is acceptable for a never-acted-on test branch if audit requirements do not block it; otherwise set a closed/cancelled status using an existing allowed status.

---

## 7) Progressed goods lane

Progressed lines must not be blocked by exception lines.

If some lines are progressed and some are unresolved:

- progressed subset can move to ready-for-shipment / shipper handoff
- unresolved exception branches stay open separately
- parent order remains partially progressed / not fully cleared

The dashboard should eventually show both:

- progressed subset status
- exception case status

For MVP, it is acceptable for importer dashboard next action to show `Continue invoice reconciliation` while unresolved lines remain, provided staff/internal view still shows progressed subset and unresolved amount.

---

## 8) Hard controls

Do not allow:

- manual line add or manual line edit/save to push total invoice-line qty/value over parent declared baseline
- progressed invoiceable subset to exceed parent declared qty/value baseline
- OCR source line deletion
- exception-linked lines to remain editable/progressable/deletable through normal line actions
- refund retailer communication before staff refund-pursuit approval
- staff/supervisor to masquerade as importer-owned retailer response logger
- final outcome acceptance before at least one retailer message exists
- final outcome acceptance before importer marks retailer outcome accepted / ready for review
- replacement child order creation before retailer agreement is logged and supervisor/admin accepts final replacement outcome
- rescind after downstream activity begins
- final parent completion while exception branches remain unresolved
- final financial settlement while funding recognition is not complete
- Sage/VAT/accounting release directly from exception creation
- replacement child order to become detached from original parent order

---

## 9) MVP UI surfaces

### Importer reconciliation page

- select unresolved, non-exception-linked line(s)
- choose remedy intent: refund or replacement
- create exception case
- show grouped exception cases linked to this parent order
- show exception-linked lines as in-case, not normal editable/progressable unresolved lines
- link to importer exception detail page for conversation/outcome updates
- show rescind only when allowed

### Importer exception detail page

Build or use `/importer/exceptions/[dispute_id]`.

This page should show:

- parent order summary
- affected exception lines
- current refund/replacement path
- approval state for refund pursuit
- read-only conversation history
- paste retailer response form where allowed
- latest response edit option where allowed
- retailer outcome selector:
  - still waiting
  - retailer accepted
  - retailer disputed/rejected
  - more info requested
- submit/update action

Refund-specific importer gate:

- before refund pursuit approval, importer cannot log retailer refund conversation and should see waiting-for-approval state.

### Internal exception review page

Build/use `/internal/exceptions/[dispute_id]`.

This page should reuse the same context as the importer reconciliation page:

- parent order details
- original screenshots
- declared qty/value
- supplier invoice
- invoice lines
- progressed lines
- exception lines only
- refund/replacement status
- conversation log read-only for retailer messages
- internal staff notes where useful
- request more evidence link/path where existing evidence-query infrastructure is useful
- supervisor/admin approval buttons where allowed

Staff page rules:

- Staff can add internal notes if supported.
- Staff cannot paste retailer responses as if they were importer-owned retailer account activity.
- Staff can approve refund pursuit.
- Staff can accept final refund outcome only after importer retailer message exists and retailer outcome is accepted/ready for review.
- Staff can accept replacement outcome only after importer retailer message exists and retailer outcome is accepted/ready for review.

### Conversation log

Use simple manual logging now:

- importer pastes retailer reply
- importer updates retailer outcome
- staff may add internal note
- supervisor reviews read-only conversation before final acceptance

AI later should plug into this by generating draft messages into the same `dispute_messages` structure.

### Replacement child order

Reuse existing order pages/flows as far as possible instead of building a special replacement-only system.

---

## 10) Required MVP regression

1. Clean OCR line can progress within parent baseline.
2. Manual line can progress within parent baseline.
3. Manual line add is blocked if it pushes invoice total over parent baseline.
4. Manual line edit/save is blocked if it pushes invoice total over parent baseline.
5. Progression is blocked if selected lines exceed parent baseline.
6. Unresolved selected lines can create refund grouped dispute case.
7. Unresolved selected lines can create replacement grouped dispute case.
8. Replacement grouped dispute does not create replacement child order immediately.
9. Refund case blocks importer retailer conversation until staff approves refund pursuit.
10. Replacement case allows importer-owned manual retailer conversation without refund approval.
11. Same line cannot be added twice to active exception case.
12. Exception-linked lines do not show Save / Mark progressed / Delete / progression checkbox.
13. Rescind works before downstream activity.
14. Rescind is blocked after refund approval, messages, replacement child creation, or settlement activity.
15. Progressed subset remains visible and does not disappear when exceptions exist.
16. Supervisor/internal exception page shows parent order, invoice, screenshots, exception lines, conversation, and allowed approvals.
17. Staff page does not expose importer retailer-response logging.
18. Importer exception page can log retailer response and update retailer outcome.
19. Staff cannot accept final refund/replacement outcome until importer retailer message exists and outcome is accepted/ready for review.
20. Supervisor accepts final replacement outcome and only then creates replacement child order.
21. Parent does not fully clear until progressed subset plus resolved child outcomes reconcile back to original parent baseline.
22. No DVA, Sage, VAT, funding, or shipping side effects occur from exception case creation alone.

---

## 11) Non-scope for MVP v3

Do not build yet unless specifically approved:

- full AI retailer drafting loop
- real-time push/mobile notifications
- advanced multi-case splitting UI
- separate workflows per individual line by default
- new schema tables unless the existing status fields cannot support the MVP
- automatic credit note/Sage/VAT posting from exception creation
- final refund payout automation

MVP goal: controlled branch creation, importer-owned manual conversation logging, retailer outcome marking, supervisor outcome acceptance, and replacement-child linkage at the right point. Richer automation can come in v2.
