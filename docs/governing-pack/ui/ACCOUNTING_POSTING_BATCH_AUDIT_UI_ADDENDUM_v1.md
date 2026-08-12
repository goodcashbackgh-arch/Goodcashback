# Accounting Posting Batch Audit UI Addendum v1

Status: governing authority for the posting-batch history/audit build.

## Purpose

Make one surgical, read-only history/audit improvement without changing any working accounting, batch lifecycle or Sage behaviour.

The build must:

- show a maximum of 10 recent active batches on the Accounting Command Centre;
- add a dedicated read-only `/internal/accounting-command-centre/batch-history` page;
- filter that audit by Lane and Status only;
- support 20 / 50 / 100 rows per page with server-side pagination;
- allow every audit batch to open the existing `/internal/accounting-command-centre/batches/[batch_id]` page;
- provide navigation back to the Accounting Command Centre and `/internal` dashboard.

## Deny-by-default build boundary

No existing production file, function, table, trigger, policy, posting action or accounting workflow may be modified unless explicitly authorised below.

### Existing production file authorised for modification

`app/internal/accounting-command-centre/PostingBatchHistoryPanel.tsx`

Only these changes are authorised in that file:

1. Keep the existing `internal_sage_posting_batch_history_v1` call and `p_limit: 30` unchanged.
2. Keep the existing cancelled/superseded filtering unchanged, then append `.slice(0, 10)` to the displayed rows.
3. Change the stale audit helper sentence so it directs staff to `View full history`.
4. Change `Open full history grid` to `View full history`.
5. Change its destination from `/internal/accounting-command-centre?queue=all` to `/internal/accounting-command-centre/batch-history`.

The existing panel table, columns, styles, status tones, lane-mix display, links, error handling, formatting and RPC contract must otherwise remain unchanged.

### New production files authorised

`app/internal/accounting-command-centre/batch-history/page.tsx`

`supabase/migrations/20260812_accounting_posting_batch_audit_v1.sql`

No other production file is authorised.

## Audit page contract

Title: `Posting Batch History`

Supporting text: `Read-only history of accounting posting batches.`

Top navigation:

- `← Accounting Command Centre` -> `/internal/accounting-command-centre`
- `Internal dashboard` -> `/internal`

The page is read-only. It must contain no freeze, revalidation, batch creation, validation, Sage posting, retry, supersede, cancellation, editing or other mutation action.

## Access control

The page must preserve the existing accounting-admin access model locally:

- `role_type = admin`, or
- `permissions_json.accounting_admin_testing = true`, or
- `permissions_json.admin_testing = true`.

Do not alter `app/internal/layout.tsx` or refactor shared access code.

The RPC must independently require an authenticated user and `internal_has_accounting_admin_access_v1()`.

## Allowed filters

### Lane

Query parameter: `lane`

Allowed values:

- `all`
- `customer_sales`
- `supplier_goods_ap`
- `supplier_credit_note`
- `shipper_ap`
- `mixed`

Invalid values fall back to `all`.

### Status

Query parameter: `status`

Allowed values:

- `all`
- `draft`
- `validated`
- `posted`
- `cancelled_or_superseded`

`cancelled_or_superseded` means `b.status = 'cancelled' OR b.batch_status = 'superseded'`.

Invalid values fall back to `all`.

The table displays the stored `status`; `Cancelled / superseded` is a filter grouping only.

## Page size and pagination

Query parameter: `page_size`.

Allowed values: `20`, `50`, `100`.

Default/invalid value: `20`.

Query parameter: `page`.

Default/invalid/non-positive value: `1`.

Offset: `(page - 1) * page_size`.

Display `Showing A–B of N`, `Previous`, `Page X of Y`, `Next`.

Previous/Next preserve `lane`, `status` and `page_size`.

Filter/page-size form submissions do not carry `page`, so they return naturally to page 1.

No special out-of-range redirect logic is authorised.

## Audit table

Columns only:

- Batch
- Status
- Lane
- Value
- Included
- Excluded
- Created
- Action

Batch displays `batch_ref` with `batch_kind` beneath it.

Created displays `created_at` with `created_by_name` beneath it.

Both the batch reference and `Open` link route directly to `/internal/accounting-command-centre/batches/${batch_id}`.

Do not add Lane mix to the new audit page.

## Zero-row batches

Historical parent batches with no `sage_posting_batch_rows` must remain visible and clickable.

For them, Included and Excluded are both zero.

The audit query must therefore preserve parent batches with a left join to aggregated child-row counts.

## New read-only RPC

Create only:

`public.internal_sage_posting_batch_audit_v1`

Inputs:

- `p_lane text DEFAULT 'all'`
- `p_status text DEFAULT 'all'`
- `p_limit integer DEFAULT 20`
- `p_offset integer DEFAULT 0`

The function validates lane/status values, clamps limit to 1..100 and offset to >= 0.

Output only:

- `batch_id`
- `batch_ref`
- `batch_kind`
- `status`
- `lane`
- `total_amount_gbp`
- `included_count`
- `excluded_count`
- `created_at`
- `created_by_name`
- `total_count`

Child-row count semantics must match the established history logic exactly:

- Included = `COUNT(r.id) FILTER (WHERE r.posting_status <> 'excluded')`
- Excluded = `COUNT(r.id) FILTER (WHERE r.posting_status = 'excluded')`

Aggregate child rows to one row per batch first, left join that aggregate to `sage_posting_batches`, left join `staff` only for creator name, apply Lane/Status at parent-batch level, calculate total count across the filtered one-row-per-batch set, order by `b.created_at DESC`, then LIMIT/OFFSET.

## RPC security

Use `SECURITY DEFINER` and `SET search_path = public, pg_temp`.

Require:

- `auth.uid() IS NOT NULL`;
- `public.internal_has_accounting_admin_access_v1()`.

Revoke PUBLIC and anon execution; grant authenticated execution.

## Migration boundary

The migration may only create the new audit function, set its permissions, optionally comment it, and reload the PostgREST schema.

It must not alter tables, create tables, alter columns, mutate data, change triggers/RLS, or replace/modify any existing function or RPC.

## Explicit no-touch boundary

Do not modify:

- `app/internal/accounting-command-centre/page.tsx`
- `app/internal/layout.tsx`
- existing accounting action/posting files
- `app/internal/accounting-command-centre/batches/[batch_id]/page.tsx`
- `internal_sage_posting_batch_history_v1`
- `internal_sage_posting_batch_detail_v1`
- `internal_accounting_command_centre_grid_v1`
- any working freeze, revalidation, batch creation, validation, approval, Sage posting, retry, supersede, cancellation, VAT, mapping, snapshot, source-evidence, reconciliation or accounting-calculation path.

## Out of scope

No search, Type filter, date filter, exports, column sorting, summary cards, bulk actions, infinite scrolling, new statuses, new lanes or new batch types.

## Diff gate

The only production paths permitted in the build diff are:

- `app/internal/accounting-command-centre/PostingBatchHistoryPanel.tsx`
- `app/internal/accounting-command-centre/batch-history/page.tsx`
- `supabase/migrations/20260812_accounting_posting_batch_audit_v1.sql`

The only governance addition permitted is this addendum.

Any other production-file change requires a stop and explicit review.

## Acceptance gate

The build passes only if the Accounting Command Centre and all existing workbench/posting controls remain unchanged; the recent panel shows a maximum of 10 active rows; the existing history RPC remains unchanged; the audit page is accounting-admin protected and read-only; Lane/Status and 20/50/100 pagination work; cancelled/superseded, mixed and zero-row historical batches remain reachable; both audit drill-down links open the existing batch detail; all pre-existing database objects remain unchanged; the only database object added is `internal_sage_posting_batch_audit_v1`; no unauthorised production file changes; and `npm run build` passes before deployment.
