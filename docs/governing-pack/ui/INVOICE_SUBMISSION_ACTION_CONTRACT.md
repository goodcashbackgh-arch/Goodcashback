# Invoice Submission Action Contract

Status: contract only. Do not add SQL, server actions, UI buttons, OCR automation, or schema changes from this document alone.

## Purpose

Provide a controlled importer/operator action for submitting retailer supplier invoice evidence after purchase, in either sequence with tracking evidence, without waiting for staff funding recognition.

This action is an evidence-capture action. It creates the supplier invoice source needed for later OCR/reconciliation work. It does not itself confirm OCR lines, progress lines, create child exceptions, release shipment scope, release accounting/VAT, or settle any refund/credit/payout outcome.

## Governing sources

- `docs/governing-pack/ui/Multi_Tenant_UI_Wiring_Control_Document_v1.md`
- `docs/governing-pack/backend/goodcashback-complete.v4.sql`
- `docs/governing-pack/backend/closure_v2_migration_v2.sql`
- `docs/governing-pack/backend/closure_v2_functions_final_day6_8_clarified.sql`
- `docs/governing-pack/role-matrices/importer_role_stage_matrix_v7.md`
- `docs/governing-pack/role-matrices/supervisor_role_stage_matrix_v7.md`
- `docs/governing-pack/role-matrices/admin_role_stage_matrix_v6.md`

## Governing decision

V1 should submit directly into:

```sql
supplier_invoices
```

Reason:

- The importer role matrix states that invoice upload is a normal importer/operator Day 3 action.
- Tracking and invoice are independent child submissions under the same order.
- Invoice can arrive before tracking, after tracking, before funding match, or after funding match.
- Once the invoice exists, the importer can enter the OCR/reconciliation workspace.
- A separate pending-evidence staging table would add a staff promotion step that is not in the locked importer flow.

Direct insert is allowed only through a controlled authenticated server/RPC path. Browser/client code must not insert directly into `supplier_invoices`.

## Target table

The action creates one row in:

```sql
supplier_invoices
```

Required target columns:

- `order_id`
- `retailer_id`
- `retailer_account_id`
- `invoice_ref`
- `invoice_pdf_url`
- `uploaded_by_operator_id`
- `ocr_service_used`

V1 default:

```sql
ocr_service_used = 'manual'
```

OCR extraction is a later action. Do not trigger Mindee/OCR automatically unless a separate OCR action contract and backend function approve that side effect.

## Proposed RPC

```sql
operator_submit_supplier_invoice(
  p_order_id uuid,
  p_invoice_ref text,
  p_invoice_pdf_url text
) returns jsonb
```

Optional future parameters may be added only after contract update:

```sql
p_retailer_account_id uuid
p_invoice_total_gbp numeric
p_note text
```

Do not expose `p_retailer_id`, `p_uploaded_by_operator_id`, or `p_ocr_service_used` to the browser. These must be derived server-side.

## Required server-side write pattern

Use:

```text
Browser form
→ Next server action
→ authenticated operator-safe SECURITY DEFINER wrapper validating auth.uid()
→ supplier_invoices insert
```

The browser must never use service-role keys and must never insert directly into `supplier_invoices`.

## Required validations

The RPC must validate all of the following before inserting:

1. `auth.uid()` resolves to an active `operators` row.
2. The operator has a current, non-revoked `operator_importers` relationship to the order's importer.
3. The order exists.
4. The order belongs to that authorised importer.
5. The order is not archived/cancelled/completed in a way that should block new evidence.
6. `p_invoice_ref` is not blank after trimming.
7. `p_invoice_pdf_url` is not blank after trimming.
8. The uploaded file path/URL is in the approved Supabase storage location for importer invoice evidence.
9. `retailer_id` is derived from `orders.retailer_id`; it must not be supplied by the client.
10. `uploaded_by_operator_id` is derived from the authenticated operator; it must not be supplied by the client.
11. `retailer_account_id` is safely derivable for the order's retailer/shipper context.
12. The derived `retailer_account_id` belongs to the same `retailer_id` as the order.
13. If `retailer_accounts.shipper_id` is populated, it must match the order's `shipper_id`.
14. If multiple active retailer accounts match, the RPC must reject and require staff/admin configuration resolution. It must not pick arbitrarily.
15. The unique supplier invoice constraint must be respected: `(retailer_id, invoice_ref, order_id)`.
16. Duplicate submission should return a clear duplicate error or an idempotent existing invoice response only if intentionally designed.

## Retailer account derivation rule

V1 must not let the importer/operator manually choose the retailer account.

Derivation should be deterministic:

```text
order_id
→ orders.retailer_id
→ orders.shipper_id
→ active retailer_accounts matching retailer_id and shipper_id
```

If the live schema/configuration does not provide a single safe active account for the order context, stop and fix configuration or add an approved backend contract. Do not insert fake `retailer_account_id` data.

## Side effects explicitly forbidden in V1

Submitting an invoice must not:

- change order status;
- change funding state;
- reconcile DVA/funding;
- trigger OCR automatically;
- create supplier invoice lines manually;
- mark any line progressed;
- create a child exception/dispute;
- close an evidence query;
- create shipment readiness;
- release accounting/VAT;
- create Sage postings.

## Permitted side effects in V1

Permitted:

- insert one `supplier_invoices` row;
- return the created supplier invoice id and basic metadata;
- allow read models/pages to show invoice count and invoice details after refresh.

Optional later, only after explicit approval:

- link an existing open `order_evidence_queries` row to the created `supplier_invoice_id`;
- mark a missing-invoice query as answered by evidence upload;
- queue OCR extraction.

These are not part of V1.

## UI placement

Initial importer UI can be placed in one of these locations after the contract is implemented:

1. `/importer/evidence-queries` when the open query type is `missing_invoice`; or
2. the importer order detail/dashboard evidence section for the relevant order.

The first implementation should be guided and narrow:

- show order reference;
- accept invoice reference;
- accept/upload invoice PDF/image;
- submit;
- show success/failure;
- refresh invoice count/details.

Do not expose retailer account selection.

## Staff/internal visibility

After successful submission, staff/internal evidence pages should show the invoice through existing reads:

- `/internal/evidence`
- `/internal/evidence/[order_id]`

The visible outcome should be:

- invoice count increases;
- invoice ref appears;
- invoice PDF/link appears;
- OCR lines remain zero until OCR/manual line workflow runs.

## Definition of done for backend contract implementation

The implementation is complete only when:

- additive SQL file exists if a new RPC is required;
- no locked baseline schema is edited;
- RPC validates authenticated operator access;
- RPC derives `retailer_id`, `uploaded_by_operator_id`, and `retailer_account_id` safely;
- RPC inserts one valid `supplier_invoices` row;
- no order status changes;
- no dispute/query/funding/accounting side effects occur;
- duplicate invoice handling is clear;
- regression proves unauthorised operator is blocked;
- regression proves wrong-order/wrong-importer submission is blocked;
- regression proves ambiguous retailer account configuration is blocked.

## Test scenarios

### Scenario 1 — Tracking-first missing invoice

Given an order with tracking and no supplier invoice, authorised operator submits invoice ref and invoice file.

Expected:

- one `supplier_invoices` row is inserted;
- row links to the correct order;
- row uses order retailer;
- row uses derived retailer account;
- row uses authenticated operator;
- `ocr_service_used = 'manual'`;
- no order status change;
- no query auto-close in V1;
- staff evidence page shows invoice count 1.

### Scenario 2 — Invoice-first order

Given an order with no tracking yet, authorised operator submits invoice ref and invoice file.

Expected:

- invoice is accepted;
- tracking remains absent;
- OCR workspace can later open once OCR/manual line flow exists;
- no funding gate blocks submission.

### Scenario 3 — Unauthorised operator blocked

Given an operator who is not linked to the order's importer, the operator calls the RPC.

Expected:

- RPC rejects;
- no `supplier_invoices` row inserted.

### Scenario 4 — Ambiguous retailer account blocked

Given multiple active matching retailer accounts for the same retailer/shipper context, operator submits invoice.

Expected:

- RPC rejects with configuration ambiguity;
- no arbitrary retailer account selection;
- no row inserted.

### Scenario 5 — Duplicate invoice blocked or idempotently returned

Given the same `retailer_id`, `invoice_ref`, and `order_id` already exist, operator submits again.

Expected:

- either clear duplicate error; or
- existing invoice response if idempotency is intentionally implemented.

The chosen behaviour must be explicit in the implementation notes.

## Hard boundary

Invoice Submission is not OCR reconciliation. It is not Query Importer. It is not dispute handling. It is the controlled creation of the supplier invoice evidence source needed for the later OCR/reconciliation lane.
