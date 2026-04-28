# Exception Branching MVP Contract

Status: contract only (MVP v1).

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
- Funding recognition delay must not block operational reconciliation, child-exception creation, ready-for-shipment handoff, or shipper/logistics progression where goods are genuinely moving.
- Refund branch requires supervisor/admin approval before importer can proceed with refund retailer communication.
- Replacement branch can proceed into retailer communication without the refund-specific approval gate, but remains inside the child-exception status machine.

---

## 1) MVP principle

The parent order remains the anchor.

For one parent order, the platform may show parallel lanes:

1. Progressed goods lane — clean invoiceable subset moving toward shipper/logistics, shipment evidence, delivery, invoicing/accounting release later.
2. Refund exception lane — unresolved lines grouped into a refund case, staff approval required before refund retailer communication.
3. Replacement exception lane — unresolved lines grouped into a replacement case, later linking to a replacement child order when replacement is confirmed.

Do not collapse these lanes into one misleading status. One parent order can be partially progressed and still have open exception branches.

---

## 2) Schema mapping for MVP

Use existing schema only:

### Parent order

- `orders.id` = parent anchor
- `orders.order_type = 'main'`
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
- `disputes.refund_approved_by_staff_id` / `refund_approved_at` for refund approval gate
- `disputes.replacement_child_order_id` links to the replacement child order once created

### Exception line detail

Use `dispute_lines` for affected line-level detail:

- `dispute_lines.dispute_id` = grouped case header
- `dispute_lines.supplier_invoice_line_id` = affected OCR/manual line
- `dispute_lines.qty_impact`
- `dispute_lines.amount_impact_gbp`
- `dispute_lines.conversation_status`
- `dispute_lines.intended_remedy` = `refund` or `replacement`

### Replacement child order

Use existing order parent/child relationship:

- child `orders.parent_order_id` = original parent order id
- child `orders.order_type = 'replacement'`
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
5. Refund case enters approval-required state.
6. Staff supervisor/admin approves or rejects refund path.
7. Until approved, importer refund retailer communication is blocked/greyed out.
8. Once approved, importer can continue retailer communication / AI-assisted draft loop.
9. Retailer outcome resolves to refund / credit / closed-no-action as governed.
10. Final settlement, payout, credit application, customer credit note, Sage/VAT release remain downstream and gated.

MVP shortcut allowed:

- Use simple staff approval UI/action against `disputes.refund_approved_by_staff_id` and `refund_approved_at`.
- Evidence query pattern may be reused only to ask importer for missing proof, not to fake refund approval.

---

## 5) Replacement branch MVP flow

1. Importer/operator identifies unresolved lines after reconciliation.
2. Importer selects remedy intent = replacement for selected unresolved lines.
3. System creates or reuses one grouped replacement dispute case for the parent order.
4. System creates `dispute_lines` for each selected affected line.
5. Replacement case enters remedy-selected / retailer communication state.
6. Importer can proceed with retailer communication without refund approval gate.
7. Once retailer agrees replacement, staff/operator creates linked replacement child order.
8. Replacement child order uses existing order operational flow:
   - tracking
   - invoice/evidence upload
   - reconciliation if needed
   - shipping quote/handoff
   - delivery/POD
9. Child outcome reconciles back to the parent via the dispute case.

MVP shortcut allowed:

- Do not build full AI communication in v1 if not needed for demo. A simple status + notes path is acceptable if it preserves `dispute_lines.conversation_status` and `intended_remedy`.

---

## 6) Progressed goods lane

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

## 7) Hard controls

Do not allow:

- progressed invoiceable subset to exceed parent declared qty/value baseline
- OCR source line deletion
- refund retailer communication before staff refund approval
- final parent completion while exception branches remain unresolved
- final financial settlement while funding recognition is not complete
- Sage/VAT/accounting release directly from exception creation
- replacement child order to become detached from original parent order

---

## 8) MVP UI surfaces

### Importer reconciliation page

Add later, after current baseline-guard tests pass:

- select unresolved line(s)
- choose remedy intent: refund or replacement
- create exception case
- show grouped exception cases linked to this parent order

### Staff/internal exception view

MVP view should show:

- parent order
- progressed qty/value
- unresolved qty/value
- grouped refund case(s)
- grouped replacement case(s)
- refund approval required/approved
- replacement child order link if created

### Replacement child order

Reuse existing order pages/flows as far as possible instead of building a special replacement-only system.

---

## 9) Required MVP regression

1. Clean OCR line can progress within parent baseline.
2. Manual line can progress within parent baseline.
3. Progression is blocked if selected lines exceed parent baseline.
4. Unresolved selected lines can create refund grouped dispute case.
5. Unresolved selected lines can create replacement grouped dispute case.
6. Refund case blocks importer communication until staff approval.
7. Replacement case can proceed without refund approval gate.
8. Replacement child order links back via `parent_order_id` and `replacement_child_order_id`.
9. Progressed subset remains visible and does not disappear when exceptions exist.
10. Parent does not fully clear until progressed subset plus resolved child outcomes reconcile back to original parent baseline.
11. No DVA, Sage, VAT, funding, or shipping side effects occur from exception case creation alone.

---

## 10) Non-scope for MVP v1

Do not build yet unless specifically approved:

- full AI retailer drafting loop
- advanced multi-case splitting UI
- separate workflows per individual line by default
- new schema tables
- automated replacement child order creation before retailer agreement
- automatic credit note/Sage/VAT posting from exception creation
- final refund payout automation

MVP goal: controlled branch creation and linkage first; richer automation can come in v2.
