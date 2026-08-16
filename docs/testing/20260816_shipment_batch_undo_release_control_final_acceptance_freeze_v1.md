# Shipment Batch Undo & Release Control — Final Acceptance / Freeze v1

Date: 2026-08-16

Governing addendum:
`docs/governing-pack/architecture/SHIPMENT_BATCH_UNDO_RELEASE_CONTROL_ADDENDUM_v1.md`

## Final status

**ACCEPTED — FROZEN**

Shipment Batch Undo & Release Control v1 has completed implementation, postflight, behavioural regression and genuine two-session concurrency proof.

No known runtime defect remains in the governed Shipment Batch Undo scope.

From this acceptance point, the Shipment Batch Undo runtime, migration, authorised writer hardening, permissions and protected Groupage boundary are frozen. Any future change requires a new governing addendum / explicitly approved scope rather than an in-place alteration of this accepted build.

## Accepted runtime authority

Migration:
`supabase/migrations/20260816123000_shipment_batch_undo_release_control_v1.sql`

Primary authority:
`public.shipper_undo_shipment_batch_v1(uuid,text)`

Accepted installed definition MD5 from live postflight:
`e2c6f1ffc86bb2105346288143dcf331`

Accepted permissions:
- `SECURITY DEFINER`
- `search_path = public, pg_temp`
- no `PUBLIC` execute
- no `anon` execute
- `authenticated` execute

## Accepted protected-authority fingerprints

The following protected authorities remained unchanged throughout postflight, behavioural regression, adjustment proof and live two-session concurrency proof:

- `public.groupage_recompute_movement_status_v1(uuid)`
  - MD5 `e78cc0c67e422a88afbae815bc600a0b`
- `public.internal_review_final_export_evidence_document_v1(uuid,text,text)`
  - MD5 `87c619fbd1bcea84f90718dc538bf6ef`
- `public.shipper_block_shipment_line_membership_mutation_v1()`
  - MD5 `c56d6a1a2b2c1bf0ef751a07e3b33ff2`
- `public.shipper_create_groupage_movement_v1(uuid[],text,uuid)`
  - MD5 `8691cf78f34912d9522f545ebb495529`

The accepted Groupage rule remains absolute: Shipment Undo may read active Groupage membership only. It does not mutate Groupage.

## Proof record

### 1. Live preflight

File:
`docs/testing/20260816_shipment_batch_undo_release_control_preflight_v1.sql`

Result: `READY`

Established required relations/functions and froze protected/writer definitions and ACL metadata before runtime acceptance.

### 2. Live migration execution

File:
`supabase/migrations/20260816123000_shipment_batch_undo_release_control_v1.sql`

Result: successful execution with no result set / no reported migration error.

### 3. Live postflight

File:
`docs/testing/20260816_shipment_batch_undo_release_control_postflight_v1.sql`

Result: `PASS`

Confirmed:
- Undo authority installed with expected security/ACL/search-path contract;
- final-evidence blocker checks any evidence row;
- Groupage blocker is read-only;
- voided audit/integrity anomalies all zero;
- protected Groupage/line authorities unchanged;
- four authorised writer definitions changed only within accepted hardening scope while their ACL/owner/search-path/security metadata remained preserved.

### 4. Main behavioural regression

File:
`docs/testing/20260816_shipment_batch_undo_release_control_regression_v1.sql`

Executed runtime behaviours all passed. The original overall result was coverage-incomplete because several suitable live fixtures did not exist; no executed behaviour failed.

Notable proven behaviours included:
- active customer release blocks;
- active Groupage blocks;
- active shipping document blocks;
- blank reason rejects;
- clean legacy Undo succeeds;
- dispatched-at alone does not block;
- repeat Undo rejects;
- stale writers reject a voided batch;
- unauthenticated caller rejects;
- protected authorities remain unchanged.

### 5. Remaining behavioural regression v3

File:
`docs/testing/20260816_shipment_batch_undo_release_control_remaining_regression_v3.sql`

Result: all available governed behaviours passed except the mutable-progressed adjustment case, which had no suitable live fixture in that run.

Confirmed:
- clean exact-line Undo;
- exact-line identity/value immutability;
- inactive line cannot be reactivated;
- active approved shipping cost blocks;
- export lock blocks;
- active accounting snapshot blocks;
- posted accounting history blocks even when inactive;
- inactive never-posted accounting history does not block;
- submitted/accepted/rejected final evidence all block;
- completion fields alone do not block;
- inactive shipping document/cost history does not block;
- wrong shipper rejects;
- protected authorities remain unchanged.

Inactive Groupage and reversed customer-release non-blocking cases used structural fallback because no safe real live fixture existed. The fallback intentionally avoided Groupage mutation or trigger bypass.

### 6. Mutable-progressed adjustment proof v5

File:
`docs/testing/20260816_shipment_batch_undo_release_control_adjustment_regression_v5.sql`

Result: `PASS`

Live proof established:
- existing active mutable `progressed_allocated` row selected on the proven batch;
- rollback-only fixture changed only `shipment_batch_id` before Undo;
- old progressed row superseded;
- exactly one replacement progressed row created;
- rebuilt row cleared `shipment_batch_id`;
- source identity preserved;
- all financial values preserved;
- terminal row remained untouched;
- RPC reported `rebuilt_progressed_adjustment_count = 1`;
- transaction rolled back;
- protected authorities remained unchanged.

Observed source allocation:
`4bbb4239-73e9-45b5-a233-0b2efa1a8aee`

Observed original progressed row:
`183cf803-6e14-4f33-8774-d5e387eee165`

### 7. Genuine two-session concurrency proof

Files:
- `docs/testing/20260816_shipment_batch_undo_release_control_concurrency_session_a.sql`
- `docs/testing/20260816_shipment_batch_undo_release_control_concurrency_session_b.sql`

The first manual attempt was invalid because Session B ran after Session A had already rolled back. That result is not accepted as product evidence.

The original pair was then rerun with correct overlap while Session A held the real Undo transaction locks.

Final Session B result: `PASS`

All six expected live race signals returned PostgreSQL SQLSTATE `55P03` lock timeout:

1. concurrent completion-fields writer serialized;
2. concurrent customer-sales release allocation serialized;
3. concurrent final-evidence writer serialized;
4. concurrent header writer serialized;
5. concurrent re-batching / shipment creation serialized;
6. concurrent shipping-document writer serialized.

The customer-sales release proof additionally confirmed the installed release guard still uses the exact allocation `FOR UPDATE` lock.

Protected authorities remained unchanged during the live race proof.

This closes governing addendum proof items 27, 28 and 29 with an actual two-session transaction race rather than static inspection alone.

The subsequently-created `concurrency_session_a_v2.sql` / `concurrency_session_b_v2.sql` files are synchronization-hardened test harness variants and were not required for final acceptance because the original pair subsequently produced the valid overlapping `PASS` result.

## Required regression proof disposition

The governing addendum's required proof set is accepted as closed for this build.

The only fixture-depth qualifications retained in the evidence record are:
- inactive Groupage non-blocking proof used a no-Groupage-mutation structural fallback because no safe live inactive fixture existed;
- reversed customer-release non-blocking proof used structural fallback because no real reversed release fixture existed.

These are evidence-depth qualifications only. No runtime defect was observed, and no protected authority was changed to manufacture those fixtures.

## Freeze boundary

Effective from this acceptance record, do not modify any of the following under the completed Shipment Batch Undo work item without a new governing scope:

- `shipper_undo_shipment_batch_v1` runtime behaviour;
- accepted migration `20260816123000_shipment_batch_undo_release_control_v1.sql`;
- Shipment Undo permissions / ACL contract;
- the four accepted parent-batch writer hardenings;
- exact-line mutation trigger;
- Groupage authorities or Groupage workflow;
- final-evidence review authority;
- shipment candidate/routing authorities;
- invoice-adjustment recalculation authority;
- unrelated shipment/accounting/customer-release workflows.

The feature is now **frozen and complete**.
