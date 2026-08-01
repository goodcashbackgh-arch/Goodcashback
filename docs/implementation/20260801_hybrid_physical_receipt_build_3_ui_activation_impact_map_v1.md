# Hybrid Physical Receipt Build 3 UI Activation Impact Map v1

Status: implementation boundary and audit record for Build 3

Governing authorities:

1. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`
2. `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`
3. `docs/implementation/20260801_hybrid_physical_receipt_build_2_impact_map_v1.md`

Verified repository and production baseline:

`main` at `979d1ab3119c8f98c54d49bd83de07b99cadc56f`

Production verification result:

`PASS — Build 1 and Build 2 are installed and protected authorities are unchanged`

Branch:

`agent/hybrid-receipt-build-3-ui-v1`

## 1. Purpose

Build 3 activates the already-deployed hybrid physical-receipt authorities through existing shipper, importer and internal staff application surfaces.

It is an application/UI build. It must not create another receipt authority, importer proposal authority, supervisor decision authority, dispute workflow, refund workflow, replacement workflow, shipment workflow, customer-sales workflow or reconciliation route.

Build 3 must call only these new write authorities:

- `shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)`;
- `operator_submit_physical_receipt_proposal_v1(uuid,jsonb,text)`;
- `staff_decide_physical_receipt_review_v1(uuid,text,jsonb,text,text)`.

## 2. Verified current application facts

### 2.1 Shipper action surface

`app/shipper/actions.ts` currently contains `recordPackageReceiptAction`.

Verified current behaviour:

- it accepts one package-level status from `received_clean`, `received_damaged`, `held_query` or `not_received`;
- it accepts one condition note;
- it accepts one evidence URL or one uploaded file;
- it uploads receipt evidence under `shipper-receipts/<tracking_submission_id>/...` in the existing `invoice-evidence` bucket;
- it calls legacy `shipper_record_package_receipt_v1(uuid,text,text,text)`;
- it redirects to `/shipper/package-receipts` and revalidates existing shipper routes.

Build 3 must preserve this action as the legacy path until the v2 UI is proven. It must not silently change the existing action to send guessed v2 payloads.

### 2.2 Existing operational routes to reuse

The current repository already has these governed route families:

- shipper package receipt and dashboard routes under `/shipper`;
- importer exception handling under `/importer/exceptions/[dispute_id]`;
- internal staff exception handling under `/internal/exceptions/[dispute_id]`;
- existing return, refund, replacement, shipment, customer-sales and accounting routes.

Build 3 may add physical-review entry points and links into those route families, but must not replace the existing dispute pages after a physical review is linked.

### 2.3 Evidence storage boundary

The existing shipper action uploads into the `invoice-evidence` bucket and uses the governed prefix `shipper-receipts/<tracking_submission_id>/...`.

Build 3 must reuse that bucket and prefix contract. The v2 RPC remains authoritative for validating evidence object paths. The UI must not treat a public URL as proof of storage provenance when the RPC requires the storage object path.

## 3. Build 3 scope

### 3.1 Shipper receipt entry

Add a v2 receipt form that:

- identifies the exact tracking submission and package;
- loads the effective supplier invoice lines and remaining receivable quantities;
- captures exact `numeric(12,3)` clean and affected quantities by line;
- supports governed affected dispositions;
- requires the line totals to balance before submission;
- supports multiple evidence files and factual notes;
- submits one immutable finalised receipt through `shipper_record_package_receipt_v2`;
- exposes correction only through the governed correction contract;
- shows idempotent retry and terminal-review errors without inventing a second receipt.

The old package-level v1 form must remain available or be explicitly feature-gated until the v2 route has passed production acceptance.

### 3.2 Importer physical review

Add an importer physical-review page or panel that:

- lists reviews visible through the importer's existing operator/importer access;
- shows finalised receipt facts and evidence read-only;
- shows exact affected quantity by disposition and supplier invoice line;
- accepts one or more proposed remedy rows using the deployed remedy types;
- preserves exact quantities and validates proposal totals before submission;
- captures a factual importer proposal note;
- calls only `operator_submit_physical_receipt_proposal_v1`;
- clearly distinguishes returned-for-information from a new review;
- never writes approved quantities, dispute links, supplier claim values, customer commercial values or replacement facts.

### 3.3 Supervisor initial decision

Add an internal staff physical-review page or panel that:

- lists reviews awaiting supervisor review;
- shows immutable receipt, evidence and importer proposal facts;
- requires an explicit decision for every active proposal row;
- supports return for information, approve existing exception route, hold/investigate and no-action decisions defined by the deployed RPC;
- warns that fractional refund or replacement quantities fail closed and must not be rounded;
- warns that a changed split requires return to the importer rather than creation of an unproposed split row;
- displays every linked dispute for mixed refund/replacement decisions;
- treats `physical_receipt_reviews.linked_dispute_id` as compatibility-only and reads the many-link table for the complete set;
- calls only `staff_decide_physical_receipt_review_v1`.

After linkage, users continue in the existing importer/internal dispute routes. Build 3 must not reproduce retailer conversations, refund evidence, return/collection, settlement or replacement-child controls.

## 4. Required reads

Build 3 may need additive read-only RPCs or views if current RLS does not safely expose the required receipt/review data to each role.

Any such read authority must:

- be role-specific and tenant-scoped;
- expose only facts required by the corresponding page;
- avoid service-role browser access;
- avoid direct ordinary-user writes to foundation tables;
- preserve existing importer and staff access rules;
- be added in a separately audited migration with rollback-only regression coverage.

The implementation must not bypass missing reads by using an elevated client in a browser or by broadening table policies globally.

## 5. Files permitted for the first implementation slice

Expected application files, subject to exact route audit:

- `app/shipper/actions.ts` — add a separate v2 action; preserve the v1 action;
- existing `/shipper/package-receipts` page/components or one additive v2 child route;
- importer action file and one additive physical-review route or component;
- internal staff action file and one additive physical-review route or component;
- narrowly scoped shared types/validation helpers;
- Build 3 source and browser regression files;
- additive read migration only if the audit proves one is required.

Files outside those boundaries require an explicit impact-map amendment before modification.

## 6. Protected application and database authorities

Build 3 must not replace or weaken:

- `shipper_record_package_receipt_v1`;
- `customer_review_cycle_candidates_v1`;
- `internal_materialize_customer_review_cycles_v1`;
- `customer_review_receipt_materialize_v1`;
- `shipper_tracking_review_state_v1`;
- shipment batching and effective-line authorities;
- customer-sales release authorities;
- refund and return authorities;
- `create_replacement_child_order`;
- `order_has_open_child_exceptions`;
- VAT, accounting-release and order-status authorities;
- `order_reconciliation_vw`;
- existing importer and internal dispute pages as the operational route after linkage.

## 7. Fail-closed UI rules

The UI must fail closed when:

- effective line quantities cannot be loaded;
- line totals do not balance exactly within the governed tolerance;
- evidence upload returns no governed object path;
- a receipt is no longer open for submission or correction;
- an importer proposal exceeds affected quantity;
- a supervisor payload omits an active proposal row;
- a refund/replacement quantity is fractional;
- the user lacks the required shipper, importer or staff role;
- an RPC contract differs from the audited signature.

Client-side validation is usability only. The deployed RPCs remain authoritative.

## 8. Regression requirements

Before merge, Build 3 must prove:

1. the v1 shipper action remains present and still calls only the v1 RPC;
2. the v2 shipper action calls only the v2 RPC and submits exact line dispositions and evidence object paths;
3. pending receipts cannot be presented as successfully recorded;
4. repeated submissions surface idempotent success or the governed conflict rather than duplicate facts;
5. importer UI cannot submit supervisor-only fields;
6. supervisor UI requires decisions for every active proposal row;
7. fractional refund/replacement input is rejected without rounding;
8. mixed refund/replacement linkage displays every linked dispute;
9. hold/investigate and no-action do not redirect into a fabricated dispute;
10. existing dispute, refund, replacement, return, shipment, customer-sales and reconciliation files are not replaced;
11. unauthenticated and wrong-role access fails closed;
12. no service-role credential or elevated browser client is introduced;
13. all new database regressions end in `ROLLBACK`;
14. production activation is separately gated after merge.

## 9. First implementation sequence

1. Complete exact route and action audit for shipper, importer and internal staff surfaces.
2. Add source regression that freezes the permitted file set and protected calls.
3. Implement the shipper v2 action and form as the first vertical slice.
4. Prove receipt submission, evidence provenance, exact balance, idempotency and correction behaviour.
5. Implement importer proposal UI.
6. Implement supervisor decision UI and complete multi-dispute display.
7. Run browser, role and rollback-only database regressions.
8. Merge only after final file-scope and production activation review.

Any missing contract, route or access fact stops implementation. Build 3 must not guess.