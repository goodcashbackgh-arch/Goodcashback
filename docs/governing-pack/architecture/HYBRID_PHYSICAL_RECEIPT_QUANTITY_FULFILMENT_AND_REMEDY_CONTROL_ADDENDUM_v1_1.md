# Hybrid Physical Receipt, Quantity Fulfilment and Remedy Control Addendum v1.1

Status: governing amendment to v1

This amendment is additive and must be read with `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`. Where this amendment is more specific, it controls.

## 1. Whole-unit physical receipt entry

The production shipper UI records physical quantities as whole units only.

For each exact tracking allocation:

- affected quantity is an integer from zero through the allocated whole-unit quantity;
- clean quantity is derived as `allocated quantity - affected quantity` and is not independently editable;
- affected disposition and factual condition note are enabled only when affected quantity is greater than zero;
- evidence is required whenever any package allocation has affected quantity;
- server authority independently rejects non-whole, negative, over-allocated or unbalanced quantities.

Database numeric precision remains unchanged for provenance and downstream arithmetic. The UI must not imply that fractional physical units are accepted.

## 2. Whole-unit remedy proposals and decisions

Every importer physical-remedy proposal quantity is a whole unit because its source affected quantity is a whole physical unit. This applies to refund, replacement, hold/investigate and no-action proposals.

The importer may split several affected units across several remedy rows, but every row quantity must be a positive integer and the sum for one source disposition must not exceed that disposition's affected quantity.

The supervisor may reduce an individual proposed quantity but may not invent a different split. Refund and replacement approvals remain explicitly fail-closed against fractional quantities. A changed split must be returned to the importer for a replacement proposal on the same review.

Database numeric columns remain unchanged; the application and write authorities must reject fractional physical-remedy quantities rather than round them.

### 2.1 Technical write-authority correction

Whole-unit enforcement must exist in the authenticated database write path and must not depend on browser or server-action validation.

Implementation must:

1. preserve the existing `operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)` implementation as the internal atomic proposal authority;
2. add `operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)` as an authenticated `SECURITY DEFINER` gateway;
3. make v2 reject any proposal row whose quantity is null, non-positive or differs from its rounded value by more than `0.0005`;
4. make v2 reject unknown fields and remedy types before invoking v1;
5. call v1 only after the whole-unit payload has passed validation;
6. revoke authenticated execution from v1 so an ordinary authenticated caller cannot bypass v2;
7. retain v1 execution for its owner/internal call path and revoke both versions from `PUBLIC` and `anon`;
8. update application proposal submission to call v2 only.

This correction must not modify or weaken `physical_remedy_allocation_guard_v1`, review guards, lifecycle transitions, dispute authorities or replacement authorities.

## 3. Required operational navigation, queues and workload badges

The importer workspace must expose a visible `Physical Receipt Exceptions` entry point. The internal supervisor workspace must expose a visible `Physical Receipt Reviews` entry point.

Each entry point must show a role-scoped count badge for work currently requiring that role's action:

- importer: `awaiting_importer_proposal` and `returned_for_information`;
- supervisor: `awaiting_supervisor_review`.

The default importer queue must contain only those importer-actionable states. The default supervisor queue must contain only `awaiting_supervisor_review`. Completed, rejected, linked, superseded and otherwise non-actionable reviews may appear only through an explicit history view or filter and must not inflate the action badge.

A route that is reachable only by manually entering a UUID does not satisfy this contract.

## 4. Role-scoped read and evidence authorities

Where ordinary table RLS does not safely expose all facts required by the importer or supervisor queue/detail pages, implementation must add narrow `SECURITY DEFINER` read RPCs.

Those RPCs must:

- require `auth.uid()`;
- resolve the active operator/importer or active supervisor/admin staff identity;
- enforce importer tenancy through `operator_importers` for importer reads;
- expose only the receipt, disposition, evidence, proposal and linked-dispute facts needed by the page;
- never grant browser service-role access;
- revoke execution from `PUBLIC` and `anon` and grant only to `authenticated`;
- perform no writes and replace no lifecycle, reconciliation, dispute, refund, replacement or shipment authority.

Receipt evidence access must be authorised for the same review and role before a signed URL or file response is produced. Existing storage policies may be reused only when they already enforce that scope. Implementation must not broaden the `invoice-evidence` bucket globally or expose raw storage paths as proof of access. If existing storage RLS is insufficient, add a narrow server-side evidence authority that independently rechecks importer tenancy or active supervisor/admin status for the exact review and object path.

### 4.1 Technical evidence and role regression

Rollback-only database regression must create or reuse transaction-local identities for:

- an authorised importer operator;
- a different importer operator;
- a revoked importer operator;
- an active supervisor/admin;
- an ordinary non-supervisor staff user;
- one exact physical review and one exact evidence object path.

The regression must set authenticated JWT claims using the repository's established test pattern and prove both positive and negative behavior:

- authorised importer detail and evidence access succeeds;
- different-importer and revoked-importer access returns no review and no storage object;
- active supervisor/admin detail and evidence access succeeds;
- ordinary staff access returns no review and no storage object;
- unauthenticated and invalid-path access fails closed;
- default queues include only role-actionable states;
- the script ends in `ROLLBACK`.

Definition-text and ACL checks may supplement but must not replace those behavioral assertions.

## 5. Importer and supervisor UI completeness

The importer `Physical Receipt Exceptions` section must provide:

- a role-scoped actionable queue and count;
- a detail view with immutable receipt, affected disposition, quantity, condition note and authorised evidence facts;
- one or more whole-unit proposal rows for refund, replacement, hold/investigate or no action;
- exact quantity validation and split-proposal support;
- return-for-information note visibility and resubmission;
- submission only through `operator_submit_physical_receipt_proposal_v2`.

The supervisor `Physical Receipt Reviews` section must provide:

- a role-scoped actionable queue and count;
- a detail view with immutable receipt evidence and every active importer proposal row;
- an explicit decision for every active proposal row;
- decision-specific controls that cannot submit incompatible remedy types or liable-party values;
- return for information, reject, close no action, approve investigation and approve existing exception decisions;
- whole-unit fail-closed handling for every physical remedy quantity and specifically for downstream refund and replacement routes;
- supplier-cost mode for replacement decisions;
- display of every linked dispute after linkage;
- submission only through `staff_decide_physical_receipt_review_v1`.

The supervisor UI must never silently convert an incompatible importer proposal. In particular, `hold_investigate` or `no_action` must not default to refund or replacement when `approve_existing_exception` is selected. `Approve existing exception` is enabled only when every active proposal is already refund or replacement. Investigation and no-action routing must be explicit supervisor choices. A changed split must be returned to the importer.

After linkage, the existing importer and internal dispute routes remain authoritative.

## 6. Required regression coverage

Before merge, source, rollback-only database and browser regression must prove at minimum:

1. importer and supervisor navigation entries and count badges are present;
2. default queues contain only role-actionable reviews and history does not inflate badges;
3. unauthenticated and wrong-role access fails closed;
4. importer reads cannot cross importer tenancy or use revoked access;
5. evidence access is denied outside the exact authorised review and succeeds for authorised importer/supervisor users;
6. importer proposal payloads contain no supervisor-only fields;
7. split proposals cannot exceed the exact affected disposition quantity and fractional proposal quantities are rejected without rounding by direct v2 RPC invocation;
8. authenticated execution of v1 is revoked and direct v1 bypass is unavailable;
9. supervisor decisions cover every active proposal row and the UI prevents decision-incompatible combinations without silent remedy conversion;
10. fractional refund or replacement quantities are rejected without rounding;
11. return-for-information reopens the same review rather than creating another review;
12. multiple evidence references and all linked disputes are displayed;
13. existing dispute pages remain the operational route after linkage;
14. no service-role credential or elevated browser client is introduced;
15. browser regression signs in as importer, different importer, supervisor and ordinary staff and exercises the real routes;
16. database regressions end in `ROLLBACK`.

## 7. Documentation precedence correction

Any earlier Build 3 wording that describes independently editable `numeric(12,3)` clean and affected shipper fields, fractional physical-remedy entry, direct authenticated use of importer proposal v1, silent supervisor remedy conversion or unfiltered combined operational/history queues is superseded by this amendment. Exact numeric database provenance is preserved; physical-entry and physical-remedy UI quantities are whole-unit, clean quantity is derived, v2 is the authenticated importer proposal gateway, and the default queues are action-only.
