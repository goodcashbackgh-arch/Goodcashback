# Stale Statement Mindee Job Recovery Addendum v1

## Purpose

Define the smallest seamless recovery for a DVA statement PDF extraction attempt where the external Mindee job has definitively expired or disappeared and the existing fetch returns HTTP 404 with a job-not-found response.

## Proven current behaviour

The statement import batch is created in the pre-OCR state `status = 'uploaded'` with `mindee_statement_ocr_status = 'not_started'`.

The existing statement extraction control blocks a fresh extraction when either:
- the batch status is `failed`; or
- a `mindee_statement_job_id` is still present.

The existing Mindee fetch route currently records a non-OK fetch as a failed OCR result. For the observed stale-job case this leaves the batch in `failed` with the obsolete external job id still stored, so the existing start path remains blocked.

The observed target batch has no staged rows, no committed rows, no downstream statement import links, no parsed output, and retains its original uploaded PDF.

## Seamless fix

For one condition only — the existing statement Mindee fetch receives HTTP 404 and the response definitively identifies the referenced Mindee job as not found — recover the same batch to its existing pre-OCR state so the existing extraction-start path becomes available again.

The recovery may change only the failed external OCR-attempt state:

- `status` -> `uploaded`
- `mindee_statement_ocr_status` -> `not_started`
- `mindee_statement_job_id` -> `NULL`
- `mindee_statement_inference_id` -> `NULL`
- `mindee_statement_enqueued_at` -> `NULL`
- `mindee_statement_completed_at` -> `NULL`
- `mindee_statement_result_saved_at` -> `NULL`
- `mindee_statement_last_http_status` -> `NULL`
- `mindee_statement_pages_consumed` -> `NULL`
- `mindee_statement_error_message` -> `NULL`
- `mindee_statement_raw_json` -> `NULL`
- `parse_errors_json` -> `NULL`

The recovery must be fail-closed and must not run unless the batch is uncommitted and has no staged statement import rows.

The recovery should be concurrency-safe: it must only clear the stale external job reference if the batch still holds the same job id that produced the definitive 404, so an old response cannot clear a newer extraction attempt.

## Existing path to reuse

After recovery, the current statement extraction control and current Mindee start route remain unchanged. They should naturally expose and execute the existing `Start document extraction` flow against the same uploaded PDF and same statement import batch.

## Explicitly out of scope / untouched

Do not change:
- any button;
- any button label, notification text, page wording, status wording, styling, layout or navigation;
- the statement extraction control page logic;
- the normal Mindee start route behaviour;
- normal successful, queued or processing Mindee fetch behaviour;
- generic HTTP 404 handling where the response is not definitively a missing Mindee job;
- timeout, 5xx, authentication or temporary external-service failure handling;
- statement parsing or staging;
- statement commit;
- statement lines or import links;
- allocations;
- funding;
- reconciliation;
- Sage/accounting;
- uploaded PDF storage, batch identity, filename, account context, source bank, currency, dates, importer/source mapping or any other statement metadata;
- `staff_reset_dva_statement_import_batch`.

No batch deletion, no PDF deletion, no automatic re-extraction, no new workflow and no new UI path.

## Implementation scope

Implementation is limited to:
1. one narrowly guarded database recovery operation for the definitive stale external job case;
2. one small branch in the existing statement Mindee fetch route to invoke that recovery after the definitive 404/job-not-found response;
3. regression proof that the stale job recovers while all protected paths remain unchanged.

Anything outside the above requires a separate addendum.