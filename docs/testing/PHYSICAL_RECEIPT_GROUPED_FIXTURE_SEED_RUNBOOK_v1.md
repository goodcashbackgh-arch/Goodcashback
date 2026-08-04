# Physical Receipt Grouped Fixture Seed Runbook v1

## Purpose

This runbook records the proven procedure for creating a fresh five-line physical-receipt browser fixture that stops at:

`physical_receipt_reviews.status = 'awaiting_importer_proposal'`

It exists to prevent future trial-and-error seeding against an assumed schema.

The canonical seed is:

`docs/testing/20260804_hybrid_physical_receipt_grouped_outcome_browser_fixture_seed_v1.sql`

Successful seed commit:

`e02bf858673255a13998a445a753790832a7ca4c`

## Mandatory rule: prove the live database first

Before changing this seed or creating a similar fixture:

1. Run read-only catalog probes against the live database.
2. Read actual columns, constraints, unique indexes, triggers, function definitions, and status-transition rows.
3. Do not infer live schema from repository migrations alone.
4. Do not name an application column until its existence is proven by catalog output or `to_jsonb(row)` output.
5. Do not change the persistent seed after a failure until the responsible trigger/function/constraint has been read directly.
6. Treat every failed seed transaction as rolled back unless the SQL output proves otherwise.

## Proven live-schema facts

### `orders`

- `order_type` permits only:
  - `original`
  - `replacement_child`
- A normal fixture order must use `order_type = 'original'`.
- `order_ref` is unique.
- `payment_auth_id` has a partial unique index when non-null.
- The fixture therefore uses `payment_auth_id = NULL`.
- The order must start at `status = 'evidence_collecting'`.
- Inserting the approved supplier invoice causes `recompute_order_status()` to move the order through the valid active transition:

  `evidence_collecting -> reconciling`

- Starting at `partially_progressed` is invalid because invoice insertion attempts:

  `partially_progressed -> reconciling`

  and that transition is not active.

### `supplier_invoices`

Actual identifier columns are:

- `invoice_ref`
- `ocr_invoice_ref`
- `mindee_job_id`
- `mindee_inference_id`

The table does not have guessed columns such as `invoice_number`, `supplier_invoice_number`, or `created_at`.

Unique values must be generated for:

- invoice reference family
- approved OCR reference per retailer
- Mindee inference ID

### `supplier_invoice_lines`

Actual quantity column:

- `qty`

Not `quantity`.

The five product lines use:

- `line_order`
- `retailer_sku`
- `description`
- `qty = 1`
- `amount_inc_vat_gbp = 10`
- `line_source = 'manually_added'`
- `qty_confirmed = 1`
- `amount_confirmed = 10`
- `eligible_for_invoice_yn = 'Y'`

### Tracking and allocations

- Each line receives one `order_tracking_line_allocations` row.
- `qty_allocated` must be greater than zero.
- An allocated row requires a non-null `tracking_submission_id`.
- At least one actor is required; the cloned template operator is retained.

### Physical receipt

The fixture creates a model-v2 receipt as `pending`, then adds its child rows, then finalises it.

Required v2 shape:

- `receipt_model_version = 2`
- non-null unique `receipt_submission_id`
- non-empty `payload_fingerprint`
- `receipt_state = 'pending'` with `finalised_at = NULL`
- after child rows exist, update to `receipt_state = 'finalised'` and set `finalised_at`

Do not insert the receipt directly as finalised before dispositions and evidence exist.

### Dispositions

Allowed values include:

- `clean`
- `damaged`
- `missing`
- `wrong`
- `held`

The canonical five-line plan is:

| Line | Disposition | Later browser outcome |
|---|---|---|
| A | clean | untouched control |
| B | missing | replacement |
| C | damaged | replacement |
| D | missing | refund |
| E | wrong | refund |

### Evidence

- Every affected line receives one evidence row.
- The clean control receives no affected-line evidence row.
- Storage paths must be unique.
- The canonical seed produces four evidence rows.

### Physical receipt review

The seed stops at:

- `source_stage = 'at_shipper_receipt'`
- `status = 'awaiting_importer_proposal'`
- no importer proposal fields populated
- no supervisor decision fields populated
- no linked dispute

The seed must not create:

- a dispute
- a dispute line
- an outcome lane
- a replacement route
- a replacement child order
- a refund ledger entry

Those must be created by the normal application workflow during browser acceptance.

## Required seed invariants

The SQL must raise and roll back unless all are true:

- exactly five supplier invoice lines
- exactly five receipt dispositions
- exactly one clean disposition
- exactly four affected dispositions
- exactly four evidence rows
- the receipt passed normal v2 finalisation
- no dispute exists for the new order
- no child order references the new order

## Successful fixture generated on 2026-08-04

- Run ID: `35a985d7-2e32-47a3-8330-8c4819446a80`
- Order ID: `1b4a2a43-5ddd-41ef-aef5-45e621eb5819`
- Order ref: `PW-GROUPED-35a985d72e3247a383308c4819446a80`
- Supplier invoice ID: `3a52ff77-2c6b-47e7-ae33-ddb553d8844d`
- Tracking submission ID: `d9791dc1-3149-496d-b087-5ac8dcd28d3e`
- Receipt ID: `2d9bd1c5-f88b-4486-8e55-42641dca58af`
- Receipt submission ID: `ba9e1eef-aae0-4917-9ea3-37b23944e1f1`
- Review ID: `23e51455-9186-4207-81ff-3e502bbe9f4c`
- Review status: `awaiting_importer_proposal`
- Payment auth ID: `NULL`

## Failure history and lessons

### Invalid environment guard

An acceptance-only guard blocked legitimate execution. Do not add environment assumptions unless the live deployment requirement proves them necessary.

### Invalid order type

`standard` was guessed. Live constraint permits only `original` and `replacement_child`.

### Duplicate payment authorization

Cloning retained the template's unique `payment_auth_id`. The canonical fixture explicitly sets it to `NULL`.

### Guessed supplier-invoice columns

The first probes and seed referenced nonexistent fields such as:

- `created_at`
- `invoice_number`
- `supplier_invoice_number`

Future probes must use catalog metadata and `to_jsonb(row)` rather than speculative column lists.

### Invalid order status transition

Cloning `partially_progressed` caused the invoice insert trigger to attempt an illegal backward transition to `reconciling`.

The active transition table proved the correct starting state is `evidence_collecting`.

## Probe files retained for future diagnosis

- `docs/testing/20260804_grouped_fixture_live_schema_probe_v1.sql`
- `docs/testing/20260804_order_status_recompute_transition_probe_v1.sql`
- `docs/testing/20260804_order_status_transition_rows_probe_v1.sql`
- `docs/testing/20260804_order_insert_quote_lock_probe_v1.sql`

When the live schema changes, rerun these probes and update this runbook and seed together. Do not patch around errors one at a time without first identifying the responsible live authority.
