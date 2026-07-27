# Supervisor Exact Invoice Action Routing Addendum v1

## Objective

Correct the **Operator reconciliation** button on the internal invoice-review card so that an admin/supervisor opens the existing exact-invoice supervisor action page for the selected supplier invoice.

This is a routing-only patch. It must reuse the current supervisor progression, accounting and approval flow without introducing a new workflow.

## Proven current state

The internal invoice-review card currently displays one supplier invoice record and has the selected invoice's:

- `invoice.id`;
- `invoice.order_id`;
- invoice PDF;
- review and OCR state.

The existing button routes only by order to:

```text
/importer/reconciliation/[order_id]
```

That is the operator/importer workspace and does not identify the exact supplier invoice selected on the card.

The platform already has the staff-authorised exact-invoice action route:

```text
/internal/reconciliation/[order_id]/invoice-bundle/[supplier_invoice_id]
```

That route already:

- requires an active `staff` record with `role_type` of `admin` or `supervisor`;
- validates that the supplier invoice belongs to the stated order;
- loads only that exact invoice and its lines;
- permits staff progression only through the existing `supervisorProgressSupplierInvoiceLinesAction`;
- excludes active non-physical financial resolutions from physical progression;
- continues to the existing accounting workspace;
- permits approval only through the existing readiness and accounting controls.

## Required patch

In:

```text
app/internal/invoice-review/page.tsx
```

replace only the current **Operator reconciliation** link for each invoice card.

### Current target

```text
/importer/reconciliation/${invoice.order_id}
```

### Required target

```text
/internal/reconciliation/${invoice.order_id}/invoice-bundle/${invoice.id}
```

### Required label

```text
Open reconciliation
```

The label is frozen by the existing supervisor reconciliation contract and must not be changed by this routing-only patch.

## Mandatory fail-closed behaviour

The link must use the exact `invoice.id` already rendered by the current invoice card.

Do not:

- select the latest invoice for the order;
- use a cookie-selected invoice;
- route only by `order_id`;
- infer an invoice from `is_current_for_order`;
- fall back silently to a sibling invoice;
- add a new server action, RPC, table, view, trigger or permission path.

If the exact invoice is no longer active or no longer belongs to the order, the existing exact-invoice page must retain its current redirect/fail-closed behaviour.

## Scope freeze

The implementation may change only:

```text
app/internal/invoice-review/page.tsx
```

A regression test may be added if one already exists for route assertions, but no production behaviour outside this link may be changed.

## Explicitly untouched

The patch must not alter:

- operator reconciliation UI or permissions;
- operator line editing, manual-line or exception actions;
- supervisor progression logic or RPCs;
- invoice-line eligibility calculations;
- non-physical financial-row classification;
- multi-invoice bundle calculations;
- supplier invoice approval readiness;
- accounting coding;
- Sage posting or Sage blocking;
- VAT, funding, treasury or banking;
- tracking, shipment or customer review;
- invoice rejection, resubmission or undo behaviour;
- card styling, status badges, invoice totals or OCR display;
- any database object or migration.

## Acceptance criteria

1. From `/internal/invoice-review`, clicking **Open reconciliation** on an invoice card opens:

```text
/internal/reconciliation/<that card's order_id>/invoice-bundle/<that card's invoice.id>
```

2. The destination identifies the same invoice reference shown on the originating card.

3. An active admin/supervisor can use the existing progression controls where eligible.

4. A non-staff user cannot gain staff access through the link.

5. Orders with multiple active supplier invoices open the selected card's invoice, not the first, latest or current sibling.

6. No database migration is created.

7. Existing operator, accounting, Sage, approval, tracking and shipment behaviour remains unchanged.

## Implementation shape

The intended production diff is one JSX link target and one button-label replacement. Any wider code change requires fresh evidence and a separate contract.
