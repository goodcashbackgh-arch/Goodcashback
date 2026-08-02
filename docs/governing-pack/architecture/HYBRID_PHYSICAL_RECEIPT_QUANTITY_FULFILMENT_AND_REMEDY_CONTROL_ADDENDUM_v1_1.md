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

Every importer physical-remedy proposal and every supervisor physical-remedy decision quantity is a positive whole unit. This applies to refund, replacement, hold/investigate and no-action rows.

The importer may split several affected units across several remedy rows, but every row quantity must be an integer and the sum for one source disposition must not exceed that disposition's affected quantity.

The supervisor may reduce an individual proposed quantity but may not invent a different split. A changed split must be returned to the importer for a replacement proposal on the same review.

Database numeric columns remain unchanged. Browser and server-action checks are usability controls only; the authenticated database write boundary must reject every fractional quantity exactly and must never round it into validity.

### 2.1 Importer authenticated write boundary

Implementation must:

1. preserve `operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)` as the internal atomic proposal implementation;
2. expose `operator_submit_physical_receipt_proposal_v2(uuid,jsonb,text)` as the authenticated `SECURITY DEFINER` gateway;
3. reject unknown fields, unknown remedy types, null quantities, non-positive quantities and every value for which `quantity <> trunc(quantity)`;
4. invoke v1 only after the full payload passes validation;
5. revoke direct `authenticated`, `anon` and `PUBLIC` execution of v1;
6. grant authenticated execution only to v2;
7. preflight that the v2 owner retains the internal privilege needed to invoke v1;
8. update application submission to call v2 only.

A tolerance comparison such as `abs(quantity - round(quantity)) > 0.0005` is prohibited at this physical whole-unit boundary because it admits fractional `numeric` values.

### 2.2 Supervisor authenticated write boundary

Implementation must not rewrite the large atomic supervisor decision authority merely to add boundary validation.

It must:

1. preserve `staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)` as the internal atomic decision implementation;
2. add `staff_decide_physical_receipt_review_v2(uuid,text,jsonb,text,text)` as the authenticated `SECURITY DEFINER` gateway;
3. reject unknown allocation fields, null identities, null or non-positive quantities and every value for which `approved_remedy_qty <> trunc(approved_remedy_qty)` before invoking v1;
4. apply that exact whole-unit rule to refund, replacement, hold/investigate and no-action decisions alike;
5. revoke direct `authenticated`, `anon` and `PUBLIC` execution of supervisor v1;
6. grant authenticated execution only to supervisor v2;
7. preflight that the v2 owner retains the internal privilege needed to invoke v1;
8. update the application decision action to call supervisor v2 only.

These gateways must not modify or weaken physical-remedy guards, review guards, status transitions, dispute authorities, replacement authorities, refund authorities or reconciliation authorities.

## 3. Required operational navigation, queues and workload badges

The importer workspace must expose `Physical Receipt Exceptions`. The internal supervisor workspace must expose `Physical Receipt Reviews`.

Each entry point must show a role-scoped action count:

- importer: `awaiting_importer_proposal` and `returned_for_information`;
- supervisor: `awaiting_supervisor_review`.

Default queues contain only those actionable states. Completed, rejected, linked, superseded and otherwise non-actionable reviews may appear only through an explicit history view or filter and must not inflate action badges.

## 4. Role-scoped reads and exact evidence access

Narrow `SECURITY DEFINER` read RPCs may be used where ordinary table RLS cannot safely expose the required queue and detail facts.

They must:

- require `auth.uid()`;
- resolve an active operator/importer or active supervisor/admin identity;
- enforce importer tenancy through non-revoked `operator_importers` rows;
- expose only required receipt, disposition, evidence, proposal and linked-dispute facts;
- revoke execution from `PUBLIC` and `anon` and grant only to `authenticated`;
- perform no writes;
- introduce no browser service-role client.

Evidence access must bind the exact `storage.objects.name` to an evidence row, receipt, review and currently authorised role. The `invoice-evidence` bucket must not be broadened globally, and a raw object path is not proof of access.

## 5. Importer and supervisor UI completeness

The importer section must provide an actionable queue and badge, exact immutable receipt facts, authorised evidence, whole-unit split proposal rows, return-for-information notes and submission only through `operator_submit_physical_receipt_proposal_v2`.

The supervisor section must provide an actionable queue and badge, immutable receipt and authorised evidence, every active importer proposal row, explicit decision-specific controls, supplier-cost mode for replacement, every linked dispute and submission only through `staff_decide_physical_receipt_review_v2`.

The supervisor UI must never silently convert an incompatible proposal. `Approve existing exception` is available only when every active proposal is already refund or replacement. Homogeneous hold proposals may default to investigation, homogeneous no-action proposals may default to close/no-action, and incompatible mixed proposals default to return for information. Selecting investigation or no action must display that every listed proposal will be routed accordingly. A changed split must be returned to the importer.

After linkage, the existing importer and internal dispute routes remain authoritative.

## 6. Mandatory implementation artefacts

The implementation is incomplete unless the branch contains all of the following:

1. exact importer v2 gateway migration;
2. exact supervisor v2 gateway migration;
3. importer application call to importer v2 only;
4. supervisor application call to supervisor v2 only;
5. source regression that rejects tolerance-based whole-unit checks and direct application use of either v1 authority;
6. rollback-only behavioral SQL regression covering gateway privileges, exact quantity rejection, role/tenant reads and real storage RLS;
7. an executable authenticated browser acceptance harness or a repository-native executable browser specification with explicit required environment variables and fail-closed setup;
8. PR migration order and acceptance gates aligned with this addendum.

A source-text test does not replace behavioral database or browser proof.

## 7. Required behavioral database proof

One rollback-only operational authority regression must use authenticated JWT claims and prove:

- authorised importer detail and exact evidence access succeeds;
- different-importer and revoked-importer access returns no review and no storage object;
- active supervisor/admin detail and exact evidence access succeeds;
- ordinary staff access returns no review and no storage object;
- unauthenticated, blank and invalid evidence paths fail closed;
- authenticated direct execution of importer and supervisor v1 is unavailable;
- authenticated execution of both v2 gateways is available;
- importer v2 rejects `0`, negative values, `1.0004`, `1.5` and other fractional values without mutation;
- importer v2 accepts valid integer rows and preserves v1 atomic behavior;
- supervisor v2 rejects fractional refund, replacement, investigation and no-action allocations without mutation;
- valid supervisor v2 calls preserve v1 locking, transition, linkage and rollback behavior;
- default queue results contain only role-actionable states;
- the script ends in `ROLLBACK`.

Definition, ACL and policy-text checks may supplement but must not replace those assertions.

## 8. Required authenticated browser proof

The executable browser acceptance must use real authenticated role sessions and prove:

1. importer badge and action-only queue;
2. authorised importer detail and evidence opening;
3. different-importer direct review denial;
4. whole-unit split proposal submission through importer v2;
5. supervisor badge and exact active proposal display;
6. return-for-information on the same review ID and importer resubmission;
7. explicit compatible supervisor decision through supervisor v2;
8. no silent remedy conversion;
9. linked-dispute display and navigation;
10. ordinary staff direct supervisor-route denial;
11. fractional browser input cannot submit successfully.

Credentials, cookies and storage-state files must not be committed. The harness must fail with a clear message when required test accounts or fixture IDs are absent.

## 9. Acceptance order

Acceptance must run in this order:

1. apply the ordered migrations;
2. run source regressions;
3. run the rollback-only operational authority behavioral regression;
4. run existing Build 4 database regressions;
5. run authenticated browser acceptance;
6. verify protected authority fingerprints and grants;
7. perform a final diff review.

No readiness or merge claim is permitted unless every stage passes.

## 10. Documentation precedence correction

Any earlier wording that permits tolerance-based physical whole-unit validation, direct authenticated use of either v1 write authority, silent supervisor remedy conversion, independently editable clean quantity or combined action/history queues is superseded by this amendment. Exact numeric database provenance is preserved; physical-entry and physical-remedy quantities are exact whole units, clean quantity is derived, v2 gateways are the authenticated write boundaries, and default queues are action-only.
