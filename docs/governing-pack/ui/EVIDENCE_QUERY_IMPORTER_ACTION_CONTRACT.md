# Evidence Query Importer Action Contract

Status: contract only. Do not add SQL, server actions, UI buttons, importer portal controls, or status-changing behaviour from this document alone.

## Purpose

Provide a controlled staff action for asking the importer/operator to clarify missing or unclear evidence during Day 3 Evidence/OCR review.

This action is for information gathering only. It does not itself change order progression, OCR eligibility, shipping readiness, refund status, dispute status, VAT release, or accounting release.

## Governing sources

- `docs/governing-pack/ui/Multi_Tenant_UI_Wiring_Control_Document_v1.md`
- `docs/governing-pack/backend/goodcashback-complete.v4.sql`
- `docs/governing-pack/backend/closure_v2_migration_v2.sql`
- `docs/governing-pack/backend/closure_v2_functions_final_day6_8_clarified.sql`

## Why this must not use dispute tables

The baseline has dispute-focused communication tables including `dispute_notes` and `dispute_messages`. Those require or derive from a `dispute_id` and belong to child exception / retailer / shipper / internal dispute handling.

Evidence queries are different:

- A missing invoice is not automatically a dispute.
- A missing tracking reference is not automatically a dispute.
- An unclear OCR line is not automatically a dispute.
- A staff clarification request should not create a child exception or pollute the dispute trail.

Therefore Query Importer needs its own evidence-query trail rather than using dispute messages as a shortcut.

## Proposed table

Future additive SQL should create:

```sql
order_evidence_queries
```

### Proposed fields

Required:

- `id uuid primary key default gen_random_uuid()`
- `order_id uuid not null references orders(id)`
- `query_type text not null`
- `message text not null`
- `status text not null default 'open'`
- `created_by_staff_id uuid not null references staff(id)`
- `created_at timestamptz not null default now()`
- `answered_by_operator_id uuid references operators(id)`
- `answered_at timestamptz`
- `answer_text text`
- `closed_by_staff_id uuid references staff(id)`
- `closed_at timestamptz`
- `cancelled_by_staff_id uuid references staff(id)`
- `cancelled_at timestamptz`
- `resolution_notes text`

Optional later:

- `supplier_invoice_id uuid references supplier_invoices(id)`
- `supplier_invoice_line_id uuid references supplier_invoice_lines(id)`
- `order_tracking_submission_id uuid references order_tracking_submissions(id)`
- `related_dispute_id uuid references disputes(id)` only after escalation creates a real dispute
- `priority text default 'normal'`
- `due_at timestamptz`

## Query types

Initial allowed values should be narrow:

- `missing_invoice`
- `missing_tracking`
- `ocr_unclear`
- `invoice_total_mismatch`
- `line_clarification`
- `general_evidence_question`

Do not use Query Importer for:

- approving refunds;
- creating replacement child orders;
- marking OCR lines progressed;
- editing supplier invoice lines;
- deleting evidence;
- confirming shipment readiness;
- releasing accounting/VAT.

## Status lifecycle

Allowed statuses:

- `open`
- `answered`
- `closed`
- `cancelled`

Allowed transitions:

```text
open -> answered
open -> closed
open -> cancelled
answered -> closed
answered -> open
```

Meaning:

- `open`: staff has asked the importer/operator for clarification.
- `answered`: importer/operator has responded, but staff has not closed the query.
- `closed`: staff has reviewed the response and considers the query settled.
- `cancelled`: staff created the query in error or it is no longer needed.

Creating a query must not change the order status.

Answering a query must not change the order status.

Closing a query must not change the order status.

Only actual evidence/reconciliation/dispute actions should change operational state.

## Actor permissions

### Staff

Supervisor/admin may create evidence queries.

Supervisor/admin may close or cancel evidence queries.

### Importer/operator

Importer/operator may view queries for orders they are authorised to access.

Importer/operator may answer open queries.

Importer/operator must not close or cancel staff queries.

### Shipper

Shipper must not see importer evidence queries unless a later shipper-specific evidence-query flow is explicitly designed.

## Required server-side write pattern

Do not write directly from client components.

Use:

```text
Browser form
→ Next server action
→ staff-only SECURITY DEFINER wrapper validating auth.uid()
→ order_evidence_queries insert/update
```

Future functions:

```sql
staff_create_order_evidence_query(...)
staff_close_order_evidence_query(...)
staff_cancel_order_evidence_query(...)
operator_answer_order_evidence_query(...)
```

The first implementation should only add staff create, then staff page display.

Importer answering can be added after importer portal boundary is reviewed.

## Staff create RPC contract

Proposed first RPC:

```sql
staff_create_order_evidence_query(
  p_order_id uuid,
  p_query_type text,
  p_message text,
  p_supplier_invoice_id uuid default null,
  p_supplier_invoice_line_id uuid default null,
  p_order_tracking_submission_id uuid default null
) returns jsonb
```

Validations:

1. `auth.uid()` resolves to active staff.
2. Staff role is `admin` or `supervisor`.
3. Order exists.
4. Order is not archived/cancelled unless admin-only exception is later designed.
5. Query type is one of the allowed values.
6. Message is not blank.
7. Linked invoice, line, or tracking row, if supplied, belongs to the same order.
8. Insert one `order_evidence_queries` row with `status = 'open'`.
9. Return query id, order id, query type, status, and created timestamp.

No order status update.

No dispute creation.

No escalation creation in v1.

## UI placement

### Internal evidence list

The list page may show open query counts later, but should not become the main compose surface.

### Internal evidence detail page

The first staff UI action should be on:

```text
/internal/evidence/[order_id]
```

Add a small staff-only form:

- query type dropdown;
- message textarea;
- optional context label for invoice/line/tracking;
- submit button;
- open query history table.

No importer-facing UI in the first PR.

## Settlement flow

1. Staff reviews evidence detail page.
2. Staff identifies a gap:
   - tracking exists but invoice missing;
   - invoice exists but tracking missing;
   - OCR line unclear;
   - invoice total mismatch;
   - line needs clarification;
   - general evidence question.
3. Staff creates query.
4. Query remains open.
5. Importer/operator later provides missing evidence or answer.
6. Staff reviews response.
7. Staff either:
   - closes query as resolved;
   - reopens / leaves open for further clarification;
   - escalates to child exception/dispute if the response proves a real goods/value issue.

## Definition of done for first implementation

The first implementation is complete only when:

- additive SQL table exists;
- staff create RPC exists;
- staff create regression passes;
- `/internal/evidence/[order_id]` can create an open query;
- the query appears in the evidence detail history;
- no order status changes from query creation;
- no dispute is created from query creation;
- importer-facing pages remain untouched.

## Test scenarios

### Scenario 1 — Missing invoice query

Given an order with tracking but no supplier invoice, staff creates `missing_invoice` query.

Expected:

- one `order_evidence_queries` row;
- status `open`;
- linked to order;
- no order status change;
- no dispute created.

### Scenario 2 — Missing tracking query

Given an order with invoice but no tracking, staff creates `missing_tracking` query.

Expected:

- one `order_evidence_queries` row;
- status `open`;
- no order status change.

### Scenario 3 — OCR unclear query

Given a supplier invoice line, staff creates `ocr_unclear` query linked to that line.

Expected:

- linked line belongs to the same order;
- query inserted;
- no line eligibility change.

### Scenario 4 — Invalid linked line blocked

Staff tries to create a query against an invoice line from another order.

Expected:

- RPC rejects;
- no query row inserted.

### Scenario 5 — Non-staff blocked

Unauthenticated or non-staff user calls staff RPC.

Expected:

- RPC rejects;
- no query row inserted.

## Hard boundary

Query Importer is not an exception workflow. It is the controlled evidence clarification trail before escalation.
