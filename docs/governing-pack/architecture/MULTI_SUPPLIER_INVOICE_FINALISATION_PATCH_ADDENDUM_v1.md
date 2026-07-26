# Multi-Supplier-Invoice Finalisation Patch Addendum v1

Status: governing corrective addendum

Parent contract: `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`

## Purpose

This patch closes the gap where invoice lines are fully reconciled but the supplier-invoice headers remain:

```text
review_status = pending_review
blocked_from_sage_yn = true
```

That stale header state keeps the order in evidence attention even though the real next blocker is tracking.

## Governing rule

Reconciliation is not complete until every ready live pending supplier invoice has passed through the canonical approval routine.

Required transition:

```text
pending_review + blocked_from_sage_yn = true
→ staff_approve_supplier_invoice_current(...)
→ approved_current + blocked_from_sage_yn = false
```

`is_current_for_order` remains compatibility/version-family state and must not be treated as approval.

## Canonical primitive

The existing `staff_approve_supplier_invoice_current(...)` function remains authoritative. The patch must not replace it with direct updates.

This preserves:

- staff-role enforcement;
- reference-family collision protection;
- reviewer audit fields;
- review-flag resolution;
- Sage unblock behaviour;
- corrected-reference handling.

## Order-level finaliser

Add:

```text
staff_finalize_order_supplier_invoices_v1(
  p_order_id uuid,
  p_review_notes text default null
)
```

The function must:

1. Require an authenticated active admin or supervisor via `auth.uid()`.
2. Select only live invoices in `pending_review`.
3. Fail the whole transaction if any selected invoice has:
   - no lines;
   - an undecided eligibility value;
   - an eligible line with missing confirmed quantity or amount;
   - no eligible lines;
   - an open or under-review invoice flag.
4. Lock selected invoice rows.
5. Call `staff_approve_supplier_invoice_current(...)` once per eligible invoice.
6. Return one row per transitioned invoice:

```text
supplier_invoice_id
invoice_ref
resulting_review_status
```

7. Ignore rejected, duplicate-blocked, superseded and already-approved invoices.
8. Use an explicit processed counter; do not rely on PL/pgSQL `FOUND` after statements inside the loop.
9. Use deployed columns only. `supplier_invoices.created_at` must not be referenced because it does not exist in the deployed schema. Use deterministic ordering such as `invoice_ref, id`.

## Seamless UI flow

The existing reconciliation-complete action must become:

```text
save exact invoice-line decisions
→ call staff_finalize_order_supplier_invoices_v1
→ refresh canonical order/audience status
→ show the next genuine blocker
```

Application call:

```ts
const { data, error } = await supabase.rpc(
  "staff_finalize_order_supplier_invoices_v1",
  {
    p_order_id: orderId,
    p_review_notes:
      "Approved after supplier-invoice reconciliation was completed.",
  },
);

if (error) throw error;
router.refresh();
```

The call must use the logged-in staff Supabase client so the staff JWT reaches `auth.uid()`.

The user must not be sent through a second hidden approval workbench. Finalisation is part of the existing reconciliation-complete action.

## Expected status result

When invoice approval succeeds and tracking is missing, the importer view should move directly to:

```text
Invoice reconciled; tracking open
Next action: Add tracking
```

It must not continue to show evidence attention solely because header approval was skipped.

## Repair rule

Historical affected orders must be repaired through the finaliser under an authenticated admin/supervisor identity. Direct updates to `review_status`, `blocked_from_sage_yn`, reviewer fields or review flags are prohibited unless a separately governed migration is required.

## Regression requirements

The patch must prove:

1. Three ready pending invoices approve atomically in one call.
2. One bad invoice prevents partial sibling approval.
3. Open flags, undecided lines and missing confirmed values fail closed.
4. Rejected, superseded, duplicate-blocked and approved invoices are ignored.
5. Same-reference collision protection still applies.
6. Unauthenticated and non-supervisor/admin callers are denied.
7. A second call after completion reports no pending invoices.
8. The importer status refreshes from evidence attention to tracking open when tracking remains missing.
9. Existing single-invoice approval remains unchanged.

## Acceptance invariant

```text
A successful reconciliation action must not leave a fully resolved live supplier invoice in pending_review.
```
