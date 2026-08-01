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

## 2. Required operational navigation and workload badges

The importer workspace must expose a visible `Physical Receipt Exceptions` entry point. The internal supervisor workspace must expose a visible `Physical Receipt Reviews` entry point.

Each entry point must show a role-scoped count badge for work currently requiring that role's action:

- importer: `awaiting_importer_proposal` and `returned_for_information`;
- supervisor: `awaiting_supervisor_review`.

A route that is reachable only by manually entering a UUID does not satisfy this contract.

## 3. Role-scoped read authorities

Where ordinary table RLS does not safely expose all facts required by the importer or supervisor queue/detail pages, implementation must add narrow `SECURITY DEFINER` read RPCs.

Those RPCs must:

- require `auth.uid()`;
- resolve the active operator/importer or active supervisor/admin staff identity;
- enforce importer tenancy through `operator_importers` for importer reads;
- expose only the receipt, disposition, evidence, proposal and linked-dispute facts needed by the page;
- never grant browser service-role access;
- revoke execution from `PUBLIC` and `anon` and grant only to `authenticated`;
- perform no writes and replace no lifecycle, reconciliation, dispute, refund, replacement or shipment authority.

## 4. Importer and supervisor UI completeness

The importer `Physical Receipt Exceptions` section must provide:

- a role-scoped queue and count;
- a detail view with immutable receipt, affected disposition, quantity, condition note and evidence facts;
- one or more proposal rows for refund, replacement, hold/investigate or no action;
- exact quantity validation and split-proposal support;
- return-for-information note visibility and resubmission;
- submission only through `operator_submit_physical_receipt_proposal_v1`.

The supervisor `Physical Receipt Reviews` section must provide:

- a role-scoped queue and count;
- a detail view with immutable receipt evidence and every active importer proposal row;
- an explicit decision for every active proposal row;
- return for information, reject, close no action, approve investigation and approve existing exception decisions;
- whole-unit fail-closed handling for refund and replacement;
- supplier-cost mode for replacement decisions;
- display of every linked dispute after linkage;
- submission only through `staff_decide_physical_receipt_review_v1`.

After linkage, the existing importer and internal dispute routes remain authoritative.

## 5. Required regression coverage

Before merge, source and browser regression must prove at minimum:

1. importer and supervisor navigation entries and count badges are present;
2. unauthenticated and wrong-role access fails closed;
3. importer reads cannot cross importer tenancy;
4. importer proposal payloads contain no supervisor-only fields;
5. split proposals cannot exceed the exact affected disposition quantity;
6. supervisor decisions cover every active proposal row;
7. fractional refund or replacement quantities are rejected without rounding;
8. return-for-information reopens the same review rather than creating another review;
9. multiple evidence references and all linked disputes are displayed;
10. existing dispute pages remain the operational route after linkage;
11. no service-role credential or elevated browser client is introduced;
12. database regressions end in `ROLLBACK`.

## 6. Documentation precedence correction

Any earlier Build 3 wording that describes independently editable `numeric(12,3)` clean and affected shipper fields is superseded by section 1 of this amendment. Exact numeric database provenance is preserved; the physical-entry UI is whole-unit and clean quantity is derived.