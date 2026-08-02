# Hybrid Physical Receipt Operational Acceptance Ledger v1

Governing authority:

`docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md`

Branch:

`agent/hybrid-physical-receipt-build-4-lifecycle-reconciliation`

This ledger is the implementation gate. A file existing is not evidence that its requirement passed. `BUILT / UNRUN` means executable proof exists but has not been executed in the acceptance environment. `PASS` may be recorded only with the exact run output and head SHA.

| Addendum obligation | Implementation location | Executable assertion | Current state |
|---|---|---|---|
| Importer v2 rejects exact fractions | `20260802103000_hybrid_physical_receipt_whole_unit_proposal_authority_v2.sql` | source regression; behavioral values `0`, `-1`, `1.0004`, `1.5` | BUILT / UNRUN |
| Importer v1 unavailable to authenticated | importer v2 migration | ACL assertion plus runtime direct v1 call expecting `insufficient_privilege` | BUILT / UNRUN |
| Valid importer v2 preserves v1 atomic behavior | importer v2 gateway and preserved v1 | valid integer call, status transition, exact row count and integer persistence, savepoint rollback | BUILT / UNRUN |
| Supervisor v2 exact whole-unit boundary | `20260802104000_hybrid_physical_receipt_supervisor_whole_unit_gateway_v2.sql` | exact rejection for refund, replacement, investigation and no-action | BUILT / UNRUN |
| Supervisor v1 unavailable to authenticated | supervisor v2 migration | ACL assertion plus runtime direct v1 call expecting `insufficient_privilege` | BUILT / UNRUN |
| Valid supervisor routes preserve v1 behavior | supervisor v2 and preserved v1 | return, reject, investigation, no-action and mixed refund/replacement existing-exception savepoint scenarios | BUILT / UNRUN |
| Failed gateway calls leave state unchanged | operational authority SQL regression | status, proposal count, note and approved/link fields compared before/after | BUILT / UNRUN |
| Importer tenancy isolation | operational read authority | authorised, other-importer and revoked-importer JWT behavior | BUILT / UNRUN |
| Staff role isolation | operational read authority | supervisor succeeds; ordinary staff returns no review/evidence | BUILT / UNRUN |
| Real evidence object obeys RLS | storage policies and evidence helper | exact seeded `storage.objects` row visible only to authorised importer/supervisor | BUILT / UNRUN |
| Queues and badges are action-only | read RPCs and layouts | queue status sets and action-count equality in SQL; numeric badge visibility in browser | BUILT / UNRUN |
| Browser fractional input is blocked | importer proposal form | fill `1.5`, require disabled submit, restore integer | BUILT / UNRUN |
| Browser split proposal reaches v2 | importer form/action | add second row, submit refund/replacement whole-unit split, verify supervisor status | BUILT / UNRUN |
| Cross-importer direct URL denied | importer detail route/read RPC | authenticated importer B receives 404/403 or explicit denial | BUILT / UNRUN |
| Evidence opens for authorised browser user | importer and supervisor detail routes | signed evidence link request returns successful response | BUILT / UNRUN |
| Return reopens same review | supervisor and importer routes | submit return, revisit identical review UUID, show note and enabled proposal form | BUILT / UNRUN |
| Importer resubmits same review | importer route/action | second split submission on same UUID succeeds | BUILT / UNRUN |
| No silent supervisor conversion | decision form | allocation payload retains one refund and one replacement row | BUILT / UNRUN |
| Explicit final supervisor approval | supervisor route/action | submit `approve_existing_exception` and verify final status | BUILT / UNRUN |
| All linked disputes display and navigate | supervisor detail route | exactly two outcome-specific links, each route responds below 400 | BUILT / UNRUN |
| Ordinary staff direct supervisor URL denied | staff read RPC/detail route | ordinary-staff session receives 404/403 or explicit denial | BUILT / UNRUN |
| Source contract prevents regression dilution | operational source regression | requires every named SQL/browser scenario and rejects tolerance checks/direct v1 app calls | BUILT / UNRUN |
| All database proof is non-persistent | operational authority SQL regression | outer `BEGIN` and final `ROLLBACK`; successful routes isolated with savepoints | BUILT / UNRUN |

## Required run record

Record results only in this form:

```text
Head SHA:
Acceptance environment:
Migration application result:
Source regression command and result:
Operational SQL regression command and result:
Build 4 SQL regression commands and results:
Browser acceptance command and result:
Protected fingerprint result:
Final diff review result:
```

No row may be changed to `PASS` from source inspection alone. No readiness or merge recommendation is permitted while any mandatory row remains `BUILT / UNRUN` or `FAIL`.
