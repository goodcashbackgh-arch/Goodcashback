# Supplier Goods AP Zero-Value Line and Partial-Success Retry Amendment v1

Status: governing corrective amendment

Effective scope: Supplier Goods AP Sage payload construction and recovery of a locally failed row inside a partially posted Supplier Goods AP batch

## 1. Purpose

This amendment governs a narrow corrective change to the existing Supplier Goods AP Sage posting path.

It does not create a new supplier-invoice, reconciliation, VAT, accounting-coding, Sage-ready, freeze, batch, attachment or posting workflow. It preserves all existing upstream and downstream controls and changes only:

1. the treatment of an explicitly present all-zero Supplier Goods AP financial line at the final Sage API payload boundary; and
2. the recovery path for one locally failed Supplier Goods AP posting row inside a partially posted batch where no Sage object was created for that failed row.

The implementation must be additive and surgical. Working behaviour outside this exact scope is protected.

## 2. Authority and precedence

This amendment must be read with the existing multi-supplier-invoice, Supplier Goods AP, Sage posting, VAT, accounting-command-centre and source-evidence controls, including:

- `MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`;
- `MULTI_SUPPLIER_INVOICE_MINI_BUILDS_3_4_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1.md`;
- the existing Supplier Goods AP ready/freeze/dry-run/posting migrations and application code;
- the existing Accounting Command Centre batch-detail and AP posting actions.

Where an older implementation treats an explicitly present numeric zero as equivalent to a missing amount at the final application payload builder, this later corrective amendment controls for Supplier Goods AP.

No historical migration is to be rewritten.

## 3. Protected baseline

The following are protected and must not be changed by this amendment:

- supplier invoice upload and OCR extraction;
- supplier invoice review/approval status;
- reconciliation and financial summary logic;
- supplier invoice line identity and eligibility;
- non-physical financial line resolution;
- delivery and discount recognition;
- accounting coding, nominal accounts, tax-rate mappings and VAT splits;
- Supplier Goods AP ready-row logic;
- freeze and snapshot evidence;
- dry-run VAT/gross/net controls;
- posted Sage purchase invoices and their stored Sage object identifiers;
- customer sales, shipper AP and supplier credit-note behaviour;
- whole-batch supersede protection;
- existing source PDF evidence and attachment history;
- existing batch count/status recomputation after posting.

A corrective implementation must not rewind a supplier invoice to reconciliation or rewrite accepted commercial facts merely because an all-zero financial line is present.

## 4. Explicit zero is not missing

For Supplier Goods AP only, the final application payload builder must distinguish:

```text
amount field absent / null / blank / non-numeric
```

from:

```text
amount field explicitly present and numeric 0.00
```

These states are not equivalent.

### 4.1 Missing amount

A line whose required amount cannot be resolved from the existing approved amount paths must continue to fail closed with the existing missing-amount control.

The correction must not turn malformed or incomplete lines into silent zero-value lines.

### 4.2 Valid all-zero financial line

A Supplier Goods AP line may be treated as an all-zero financial line only when all of the following are true after the existing validations:

- gross amount is explicitly present and numeric;
- net amount is explicitly present and numeric;
- VAT amount is explicitly present and numeric;
- rounded gross amount is exactly `0.00`;
- rounded net amount is exactly `0.00`;
- rounded VAT amount is exactly `0.00`;
- description is present;
- ledger account is present;
- tax rate is present;
- the existing explicit net + VAT = gross control passes.

Only after those checks may the line be omitted from the `purchase_invoice.invoice_lines` array sent to Sage.

The line remains authoritative source/audit evidence everywhere upstream of the Sage API request.

## 5. Source-total and evidence preservation

An all-zero line must remain in:

- OCR/source evidence;
- `supplier_invoice_lines`;
- non-physical financial resolution where applicable;
- accounting coding;
- Supplier Goods AP ready payload;
- frozen snapshot payload;
- posting batch request payload;
- dry-run validation evidence.

It must still participate in the existing source-total accumulation. Because its value is zero, omitting it from the final Sage API invoice line array must not alter the approved invoice total, net total or VAT total.

No frozen or source evidence is to be edited merely to make Sage posting succeed.

## 6. Negative and positive lines remain unchanged

The correction must not alter the existing handling of:

- positive goods lines;
- positive delivery or other non-physical financial lines;
- negative promotional discount lines;
- any other valid signed Supplier Goods AP line.

In particular, a negative discount is not a zero line and must continue to be sent to Sage using the established signed-line behaviour.

## 7. Lane isolation

The zero-value-line correction is scoped to `supplier_goods_ap`.

The shared generic amount helper must not be loosened globally in a way that changes `shipper_ap` behaviour.

A non-zero Supplier Goods AP payload must produce the same Sage accounting payload as before this amendment.

## 8. Partial-success recovery boundary

A partially posted batch must never be replayed as a whole merely to recover one locally failed Supplier Goods AP row.

Already-posted rows are immutable for this recovery path.

Whole-batch supersede protection must remain in force.

The recovery unit is one exact `sage_posting_batch_rows.id`.

## 9. Failed-row-only retry eligibility

A failed-row retry may be offered and executed only when the server proves all of the following immediately before posting:

- the parent batch is the expected Supplier Goods AP batch and is in partial-success / partially-posted state;
- the selected row belongs to that batch;
- `document_lane = 'supplier_goods_ap'`;
- posting status is `failed_terminal` or `failed_retryable`;
- the failure being recovered is a local pre-Sage payload-builder failure, not an ambiguous Sage/network outcome;
- `error_code = 'payload_builder_failed'` for the initial corrective use case;
- the row has no `sage_object_id`;
- the row has no `posted_at`;
- the linked snapshot has no `sage_invoice_id`;
- the linked snapshot has no `sage_posted_at`;
- the linked snapshot is not posted;
- the existing live Sage posting feature flag is enabled;
- the corrected payload builder succeeds before any Sage API request is made.

If any guard fails, the retry must refuse to post.

No UI-only condition is sufficient; the server action/posting function must enforce the same guards.

## 10. No batch-wide revalidation during row recovery

The corrective row-retry path must not run the existing whole-batch dry-run validator across a partially posted batch because that validator updates batch-row validation/response state for the batch.

The posted sibling must not have its stored Sage response or validation history overwritten as a side effect of recovering another row.

The failed row's corrected application payload must be built and validated locally before its Sage request.

## 11. Reuse the existing posting engine

The implementation must not create a second AP posting engine.

The existing AP posting function may be extended with an optional exact row identifier or equivalent narrow selector so that:

- normal batch posting with no row selector retains its existing behaviour;
- corrective retry selects exactly one failed row;
- existing Sage OAuth/business resolution is reused;
- existing request/response logging is reused;
- existing idempotency key is reused;
- existing row/snapshot success/failure updates are reused;
- existing batch-status/count recomputation is reused.

The corrective selector must never cause an already-posted sibling row to be selected.

## 12. Attachment isolation

After a successful failed-row retry, source-PDF attachment handling must target only the snapshot belonging to the successfully retried row.

The corrective retry must not scan the whole partially posted batch and opportunistically revisit an already-posted sibling's attachment state.

Normal batch posting retains its existing attachment behaviour.

## 13. Batch completion

The existing batch-count/status recomputation remains authoritative.

After the failed row posts successfully, if every active row in the batch is posted, the existing recomputation should naturally move the batch from partial success to posted.

No new batch-completion rule is to be introduced.

## 14. Prohibited changes

This amendment explicitly prohibits the corrective build from:

- changing OCR extraction;
- changing reconciliation;
- changing accepted invoice totals;
- changing VAT calculation or tax-rate mapping;
- changing accounting coding or nominal-account selection;
- changing delivery/discount classification;
- deleting the zero-value source line;
- converting a genuine missing amount into zero;
- changing shipper AP zero-line behaviour;
- refreezing the failed source merely to recover this incident;
- superseding a partially posted batch;
- replaying an already-posted Sage invoice;
- revalidating the entire partially posted batch as part of row recovery;
- rewriting posted Sage response payloads;
- creating a second AP posting engine;
- performing any business-data cleanup migration for this correction.

## 15. Mandatory regression gates

The corrective build is not acceptable unless all of the following pass before live retry is enabled:

1. A known-good, non-zero Supplier Goods AP invoice produces the same Sage accounting payload before and after the zero-line correction.
2. A Supplier Goods AP invoice containing positive goods, one explicit all-zero delivery line and a negative discount builds successfully.
3. The all-zero line remains in source/frozen evidence but is absent from the final Sage API `invoice_lines`.
4. The final Sage gross result remains equal to the approved header amount.
5. Explicit net/VAT/gross totals remain unchanged.
6. The negative discount remains in the Sage API payload.
7. A genuinely missing gross/amount field still fails with the missing-amount control.
8. A line with zero gross but non-zero net or VAT does not qualify for zero-line omission and must fail the existing reconciliation check.
9. An invoice whose every financial line is zero must not create an empty Sage purchase invoice.
10. Shipper AP behaviour is unchanged.
11. Normal Supplier Goods AP batch posting with no row selector is unchanged for existing valid cases.
12. The row-retry path refuses a posted row.
13. The row-retry path refuses any row or snapshot already carrying a Sage invoice/object identifier or posted timestamp.
14. The row-retry path refuses a failure that is not the governed local payload-builder case.
15. The row-retry path selects only the requested failed row.
16. A successful retry updates only that row and its snapshot, then relies on existing batch recomputation.
17. Corrective attachment handling targets only the retried snapshot.
18. TypeScript typecheck passes.
19. Production build passes.

## 16. Live retry preflight

Immediately before the one live corrective retry, perform a final read-only state check confirming at minimum:

- already-posted sibling remains posted and retains its Sage object id;
- failed row remains failed and has no Sage object id or posted timestamp;
- failed snapshot remains unposted and has no Sage invoice id or posted timestamp;
- no downstream Sage posting record/object has appeared for the failed source meanwhile.

If any of those facts differ from the proven state, stop and reassess before posting.

### 16.1 Preflight evidence — SPB-1787160473

Read-only production preflight completed on 22 August 2026 before merge/retry. It proved:

- batch `91039a03-a368-48e0-9573-47a39f1801c0` remained `partial_success` / `partially_posted`, with two active rows, one success and one failure, total GBP 759.99;
- posted sibling row `021fe2c5-604a-4417-905e-f988b301d375` remained `posted` with Sage object `84bd90492be14fb5bab231782a7748a9` and a non-null posted timestamp;
- failed row `3f1517bf-5ed0-4aa1-a5d1-e114892bfec4` remained `failed_terminal`, `payload_builder_failed`, `dry_run_failed`, with no Sage object and no posted timestamp;
- failed-row retained dry-run evidence remained `validation_errors=[]`, `sage_api_call_made=false`, `sage_object_created=false`;
- failed snapshot `c2e8a314-705d-4a10-ba44-7d2dc2e40f03` remained active, `approved_frozen`, `ok_to_post`, `posting_failed`, with no Sage invoice id and no Sage posted timestamp;
- `sage_api_request_log` contained zero posting requests for the failed row;
- all five final retry guards evaluated true.

This evidence authorises only the governed exact-row recovery. It does not authorise whole-batch revalidation, replay, refreeze or supersede.

## 17. Implementation discipline

Build from this amendment exactly.

The corrective work should be split so that the zero-line payload correction is independently reviewable from the failed-row recovery surface. No opportunistic refactor or adjacent cleanup is part of this amendment.

## 18. Authoritative post-claim retry lifecycle correction

This section governs the final corrective specification for the Supplier Goods AP exact-row retry lifecycle. It supersedes any implementation assumption that the parent batch must remain `partial_success` after the failed row has been successfully claimed for posting.

### 18.1 Existing platform behaviour is authoritative

The existing `sage_posting_batch_rows` status-sync trigger is protected working behaviour and must not be changed for this correction.

When the exact failed row is claimed by changing its `posting_status` to `posting`, the existing trigger synchronously recomputes the parent `sage_posting_batches.status` to `posting` because the batch then contains a row in posting state.

That trigger does not introduce a new `batch_status` lifecycle value for this transition. The existing `batch_status = 'partially_posted'` remains the required recovery lifecycle state until the existing completion/recomputation logic later determines the final result.

The retry implementation must conform to this existing lifecycle. The database trigger must not be changed to preserve an application-side stale-state assumption.

### 18.2 Required pre-claim state

Immediately before the exact failed row is claimed, the existing retry eligibility remains unchanged and must require:

```text
sage_posting_batches.status = 'partial_success'
sage_posting_batches.batch_status = 'partially_posted'
```

All existing exact-row, exact-snapshot, no-Sage-object, no-posted-timestamp, local-builder-failure, payload-hash, attempt-state and zero-prior-posting-request guards remain mandatory and unchanged.

### 18.3 Required post-claim state

After both the exact failed row and its exact snapshot have been successfully claimed, and before any Sage posting request audit row or Sage API call is created, the parent batch must be re-read and must satisfy exactly:

```text
sage_posting_batches.status = 'posting'
sage_posting_batches.batch_status = 'partially_posted'
```

Requiring `status = 'partial_success'` at this point is incorrect because it contradicts the existing synchronous batch-row status trigger.

The production logic correction is therefore limited to the Supplier Goods AP row-retry post-claim assertion in `src/lib/sage/apPosting.ts`: replace the stale post-claim expectation of `partial_success` with the expected derived state `posting`. The pre-claim `partial_success` requirement must remain unchanged.

### 18.4 Failure safety and rollback

If the post-claim batch re-read does not return exactly `posting / partially_posted`, the retry must retain the existing fail-closed behaviour:

- restore the claimed row to its exact pre-claim failed state;
- restore the claimed snapshot to its exact pre-claim posting-failed state;
- verify those restores matched the claimed records;
- create no Sage posting request audit row;
- make no Sage API call.

No compensating database change, trigger bypass, trigger rewrite or manual batch-status mutation is authorised.

### 18.5 Authoritative lifecycle

The governed platform lifecycle for this recovery path is:

```text
partial_success / partially_posted
        ↓
claim exact eligible Supplier Goods AP failed row
        ↓
posting / partially_posted
        ↓
existing Sage posting result handling
        ↓
posted / posted
or
partial_success / partially_posted
```

The existing row/snapshot success and failure updates and existing batch count/status recomputation remain authoritative after the Sage result. No new completion rule is introduced.

### 18.6 Scope lock

The lifecycle correction authorises no change to:

- the database trigger or any migration;
- `updateBatchCounts` or other existing batch recomputation logic;
- Shipper AP;
- Customer Sales;
- supplier credit notes;
- normal whole-batch Supplier Goods AP posting;
- OCR or source extraction;
- reconciliation or financial summaries;
- VAT or tax-rate mapping;
- accounting coding or nominal accounts;
- freeze, snapshot or supersede semantics;
- zero-value-line payload construction already governed by this amendment;
- attachment-engine behaviour;
- Accounting Command Centre UI behaviour;
- Sage OAuth/business selection;
- request/response logging semantics;
- idempotency behaviour;
- unrelated refactors or cleanup.

The only authorised production-logic change for this lifecycle defect is the post-claim Supplier Goods AP exact-row retry batch-status assertion described in section 18.3.

### 18.7 Additional mandatory regression gates

Before this lifecycle correction may be merged or used for a live retry, all of the following must be proved in addition to section 15:

1. A qualifying Supplier Goods AP partial-success retry begins from `partial_success / partially_posted`.
2. Claiming the exact eligible failed row causes the existing platform lifecycle to present `posting / partially_posted` at the post-claim recheck.
3. The post-claim guard accepts exactly that expected state and does not weaken any other eligibility condition.
4. Any unexpected post-claim parent state still triggers the existing verified rollback before a Sage request audit row or Sage API call.
5. Normal Supplier Goods AP posting with no row selector is behaviourally unchanged.
6. Shipper AP posting is behaviourally unchanged.
7. Successful row retry continues to rely on existing result handling and batch recomputation to reach `posted / posted` when all active rows are posted.
8. A Sage failure after a real request continues to use the existing failure path and must not be converted back into the local-builder-only retry class.
9. The implementation diff contains no trigger, migration, UI, accounting, attachment, payload-builder or unrelated cleanup change.
10. TypeScript typecheck and production build pass.

### 18.8 Post-block recovery evidence

A read-only production recovery check completed on 22 August 2026 after the blocked first retry proved that the fail-closed rollback completed cleanly:

- the batch was restored to `partial_success / partially_posted`;
- the failed row was restored to `failed_terminal` with `error_code = 'payload_builder_failed'` and `payload_validation_status = 'dry_run_failed'`;
- the failed row still had no Sage object id and no posted timestamp;
- the linked snapshot was restored to `posting_failed` with no Sage invoice id and no Sage posted timestamp;
- `sage_api_request_log` still contained zero posting requests for the failed row;
- all five recovery guards evaluated true.

Accordingly, no business-data repair, refreeze, supersede, replay or Sage-side cleanup is authorised or required before implementing this lifecycle correction.

### 18.9 Governing authority

Sections 18.1 through 18.8 are the governing authority for the lifecycle correction described above.

Implementation and review must be measured against this exact specification. Any broader behavioural change requires an explicit later governing amendment; it must not be introduced opportunistically as part of this correction.