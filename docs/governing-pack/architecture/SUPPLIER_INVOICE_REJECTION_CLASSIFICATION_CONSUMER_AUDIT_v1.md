# Supplier invoice rejection classification — consumer audit v1

## Audited fields

- `supplier_invoices.review_status`
- `supplier_invoices.blocked_from_sage_yn`
- `supplier_invoices.is_current_for_order`

## Existing semantic contract

The repository consistently treats the following review statuses as retired invoice versions:

- `rejected_resubmit_required`
- `duplicate_blocked`
- `superseded`

Those statuses are consumed broadly by invoice-family identity, duplicate prevention, progression, tracking allocation, shipment, customer release, supplier AP, VAT and status/read-model routes. Therefore this patch must not introduce a new review status and must not alter the existing meaning of `blocked_from_sage_yn` or `is_current_for_order`.

## Consumer groups confirmed

### Supervisor review and OCR

- `app/internal/invoice-review/page.tsx`
- `app/internal/invoice-review/actions.ts`
- `docs/governing-pack/backend/supplier_invoice_review_gate_v1.sql`
- `docs/governing-pack/backend/supplier_invoice_review_rpc_v1.sql`
- `docs/governing-pack/backend/supplier_invoice_review_rpc_v2_reject_adjustments.sql`
- `docs/governing-pack/backend/supplier_invoice_review_rpc_v3_retire_rejected_lines.sql`
- `docs/governing-pack/backend/supplier_invoice_header_review_rpc_v1.sql`
- Mindee result, duplicate-gate and cached-result recovery functions/migrations.

### Importer upload, resubmission and dashboard

- `app/importer/page.tsx`
- `app/importer/reconciliation/[order_id]/actions.ts`
- `docs/governing-pack/backend/operator_submit_supplier_invoice_v3_resubmission.sql`
- `supabase/migrations/20260605_operator_supplier_invoice_one_active_guard_v1.sql`

Current importer behaviour derives “corrected evidence required” from `review_status='rejected_resubmit_required'`. This is the only behaviour that must become classification-aware.

### Invoice identity, current-version and duplicate controls

- `supabase/migrations/20260719a_multi_supplier_invoice_reference_family_identity_v1.sql`
- `supabase/migrations/20260719b_multi_supplier_invoice_sibling_safe_review_v1.sql`
- post-OCR duplicate-gate functions and migrations.

These consumers must continue seeing both rejection classifications as the same retired invoice state.

### Progression, reconciliation and tracking

- `app/delivery-allocation/data.ts`
- `app/internal/reconciliation/[order_id]/page.tsx`
- `app/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]/page.tsx`
- `app/internal/reconciliation/[order_id]/staff-confirm-lines/page.tsx`
- supplier-line progression migrations.

No early-tracking gate is changed. Tracking may still be recorded before an invoice exists. Assignment remains a separate later step once allocatable progressed lines exist.

### Shipment, export, POD and returns

Shipping document intake, shipper RPCs, groupage status, export/POD, return-task and apportionment functions consume invoice status/current identity directly or through eligible lines. They must remain unchanged.

### Customer release and order status

- customer-sales release foundation and route migrations
- customer release effective-membership alignment
- platform operational/status functions
- qualifying net-spend read model

These consumers must continue excluding both rejection classifications through the existing retired state and inactive lines.

### Supplier AP, Sage and VAT

- supplier-goods AP command-centre and payload functions
- Sage invoice-date/accounting-posting guards
- VAT purchase-source refresh and VAT return UI/read models
- pre-Sage financial-readiness status routes

Both classifications remain blocked from Sage and non-current, so these consumers require no behavioural change.

### Audit, diagnostics and tests

Historical migrations, governing SQL and regression scripts contain references for proof and compatibility. They are not production consumers to rewrite. New regression must assert their established contracts remain true.

## Minimal authorised implementation scope

1. Add one nullable classification field to `supplier_invoices`:
   - `true`: corrected evidence required
   - `false`: exclude from this order; no corrected evidence requested
   - `NULL`: not rejected / legacy unknown

2. Backfill every existing `rejected_resubmit_required` row to `true`, because that was the only historical meaning.

3. Preserve `review_status='rejected_resubmit_required'`, `blocked_from_sage_yn=true`, `is_current_for_order=false` for both decisions.

4. Preserve the existing `staff_reject_supplier_invoice_resubmission(uuid,text)` signature as the `true` wrapper.

5. Add one sibling supervisor RPC for the `false` classification, reusing the same retirement and downstream-use guards.

6. Make only importer resubmission prompting and same-reference replacement acceptance classification-aware.

7. Reuse the existing snapshot undo route and restore the classification from the captured pre-rejection invoice JSON.

8. Do not change early tracking, shipment, accounting, Sage, VAT, customer release, funding, treasury, refunds or status sequencing.

## Files authorised for implementation review

- one additive Supabase migration
- `app/internal/invoice-review/actions.ts`
- `app/internal/invoice-review/page.tsx`
- `app/importer/page.tsx`
- the existing importer supplier-invoice submission/resubmission SQL implementation only if its current same-reference gate requires classification awareness
- one regression SQL file

Any additional production file requires new evidence before modification.
