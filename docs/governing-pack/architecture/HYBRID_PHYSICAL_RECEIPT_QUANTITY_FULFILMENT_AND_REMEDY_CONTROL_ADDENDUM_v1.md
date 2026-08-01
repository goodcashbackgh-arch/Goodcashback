# Hybrid Physical Receipt, Quantity Fulfilment and Remedy Control Addendum v1

Status: governing implementation contract and non-regression authority

Effective repository baseline: `main` at `9e8a6de600436a412b147e61bf125517417fb528`

Baseline date: 1 August 2026

Live-database preflight date: 1 August 2026

## 1. Purpose

This addendum governs the final production build that allows one tracked package allocation to contain both clean quantity and physically affected quantity without creating a second order-line, supplier-invoice, customer-review, shipment, exception, refund, replacement, customer-sales, VAT, Sage, supplier-payment or return workflow.

The required outcome is:

```text
clean quantity continues through the existing review, shipment and customer-sales routes;
only damaged, missing, wrong or held quantity enters controlled physical-exception review;
all quantities retain exact source provenance;
no quantity can be reviewed, held, shipped, released, refunded or replaced twice;
the existing complex upstream and downstream controls remain authoritative.
```

This is a surgical extension of the merged platform. It is not permission to redesign working areas.

The implementation must be robust enough that a future builder can implement from this addendum without relying on informal chat history. Where the repository, database, role matrices or governing pack differ from an assumption, the builder must stop, inspect the current authority and resolve the conflict explicitly. The builder must not guess.

## 2. Authority and precedence

This addendum must be read with the current governing pack, particularly:

1. `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`
2. `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_MINI_BUILDS_3_4_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1.md`
3. `docs/governing-pack/ui/EXCEPTION_REFUND_REPLACEMENT_ROUTE_CONTRACT.md`
4. `docs/governing-pack/ui/PHYSICAL_RETURN_TASK_BRIDGE_CONTRACT_v1.md`
5. `docs/governing-pack/backend/Progressive_Commercial_Release_and_Replacement_Invoicing_Addendum_v1.md`
6. the current VAT, export-evidence, supplier-AP, supplier-credit, customer-sales, Sage, DVA/card, funding, settlement, treasury and tenant-control addenda;
7. the current importer, supervisor, admin and shipper role matrices.

This later addendum controls only where earlier wording assumes that one package receipt or one supplier invoice line must be wholly clean or wholly affected.

It does not override:

- exact supplier-invoice identity;
- immutable customer-review membership;
- the fixed customer-review deadline;
- durable customer-sales release provenance;
- shipment evidence and shipping-cost allocation;
- supplier approval and supplier-payment gates;
- refund evidence and DVA/card matching;
- customer credit, payout and credit-note controls;
- VAT timing;
- Sage payload, freeze, validation, idempotency or posting controls;
- tenant isolation and current role permissions.

Historical deployed migrations remain immutable. Corrections must be additive migrations or explicit later replacements of live functions/views. Never edit an already-deployed migration to make production appear correct.

## 3. Verified baseline and fingerprints

The contract is based on repository `main` at the commit above and on live database definitions supplied during preflight.

Verified current fingerprints include:

```text
shipper_record_package_receipt_v1
27fb972b34258990cfa9d752cd2f927b

order_has_open_child_exceptions
8dbf93826e18a04b61d8fbc1d5b1922c

order_reconciliation_vw
4f71ebb1a3743d470687ecaee2f23a9a
```

These fingerprints are not permanent truth. Before changing a live object, the implementation migration must compare the current definition to the exact definition reviewed during implementation. If the object has changed, the migration must stop rather than overwrite newer work.

The verified live state at baseline is:

- `shipper_package_receipts` is a package-header record with one status, one note and one evidence URL;
- the installed receipt statuses are `received_clean`, `received_damaged`, `held_query` and `not_received`;
- `shipper_record_package_receipt_v1` records package-level facts only;
- `customer_review_cycle_candidates_v1` requires a latest whole-package `received_clean` receipt;
- `shipper_shipment_batch_candidates_v1` requires a latest whole-package `received_clean` receipt;
- `shipper_create_shipment_batch_v1` currently copies full allocation quantity and value into shipment membership;
- `internal_customer_sales_release_sources_v1` and `customer_sales_release_guard_v1` start from exact shipment provenance but still contain whole-package and whole-line blockers;
- `customer_hold_create_refund_exception_v2` converts approved customer line/tracking holds into the existing refund route and must not be repurposed into the new physical replacement route;
- replacement children exist with incomplete historical source provenance;
- `order_has_open_child_exceptions` can miss a directly linked unfinished replacement child;
- `order_reconciliation_vw` can expose negative unresolved quantity and amount when progressed evidence exceeds the order baseline;
- the proposed hybrid tables are not installed at baseline.

## 4. Final production decision

There is no feature flag, test-account switch, temporary user journey or later activation step.

The final production receipt page uses the v2 receipt route for all shippers immediately after the application deployment succeeds.

`shipper_record_package_receipt_v1` remains available for compatibility with older callers and historical operation. It is not the normal production UI route after this build.

The deployment is one coordinated release but may use the safe operational order:

1. deploy backward-compatible database additions and function replacements;
2. verify database assertions;
3. deploy the application that calls v2.

This is not a staged business rollout. It is deployment ordering that ensures the old application can continue operating if the application deployment is delayed or rolled back.

## 5. Non-negotiable single-source rules

### 5.1 One physical receipt history

`shipper_package_receipts` remains the package receipt header and historical event family.

The new line-disposition and evidence records extend that receipt. They do not create another unrelated receipt workflow.

Each v2 submission is a complete immutable snapshot for the applicable package allocations. Corrections create a later complete snapshot with an auditable correction reason; they do not silently edit old facts.

### 5.2 One review system and one deadline

The existing customer review links, review-cycle memberships, materialiser and `customer_order_review_links.expires_at` remain authoritative.

Do not create a separate physical-receipt customer review, another timer, another deadline, another review membership table or a client-calculated shipment eligibility rule.

### 5.3 One shipment system

The existing shipment candidate, batch, package membership, immutable line membership, effective-line read model, shipping-document, shipping-cost allocation, BOL, export-evidence and groupage routes remain authoritative.

Do not create a damaged-goods shipment table or a second shipment action.

### 5.4 One exception and retailer route

The new physical receipt review is a triage and route-approval bridge only.

Once approved into retailer action, the existing dispute, retailer conversation, refund evidence, replacement-child, return/collection and supervisor final-outcome routes are authoritative.

Do not create a second retailer conversation, refund process or replacement operations page.

### 5.5 One customer-sales and Sage route

The existing durable `customer_sales_release_lines`, main/supplementary customer invoice model, customer credit-note route, Sage snapshot, payload, validation and posting controls remain authoritative.

Do not create a replacement-only customer invoice route or another Sage posting route.

### 5.6 One supplier/AP truth

The original supplier invoice remains the evidence of the original purchase and supplier liability.

A supplier refund or supplier credit note adjusts supplier/AP truth through the existing controlled route.

A replacement child carries its own supplier evidence and supplier/AP cost, which may be zero, charged or pending evidence.

Customer commercial entitlement is separate from supplier cost.

## 6. Role flow

### 6.1 Shipper

The shipper uses the existing `/shipper/package-receipts` area, upgraded in place.

The page displays each exact package allocation and defaults every allocated unit to clean.

For the normal all-clean package, the shipper confirms receipt without opening exception detail.

When something is wrong, the shipper expands only the affected line and records exact affected quantity, disposition, factual condition note and one or more evidence files or supported evidence references.

Allowed affected dispositions are damaged, missing, wrong and held/query. The remaining quantity stays clean automatically.

The shipper records physical facts only. The shipper does not decide liability, refund versus replacement, customer settlement, supplier claim value, customer commercial value, VAT, Sage or accounting treatment.

The database rejects a receipt unless every allocation balances exactly:

```text
clean + damaged + missing + wrong + held = allocated quantity
```

No disposition may be negative. No affected quantity may exceed its exact tracking allocation.

### 6.2 Automatic quantity separation

After v2 receipt submission:

- clean quantity becomes eligible for the existing customer-review process;
- affected quantity becomes unavailable for clean review, shipment and customer release;
- the package header stores a compatibility summary only;
- line disposition is the authority for v2 eligibility;
- evidence remains linked to the receipt and, where supplied, the exact affected disposition.

No supplier invoice line, tracking allocation or order line is duplicated to represent the split.

### 6.3 Importer physical-receipt section

The importer dashboard gains a `Physical Receipt Exceptions` section, not a separate exception system.

The section lists affected receipts awaiting importer input. Its detail view shows order, retailer and tracking identity; exact supplier invoice and line identity; allocated, clean and affected quantities; shipper note and evidence; disposition type; clean quantity continuing separately; current review and next action.

The importer proposes one or more routes for the affected quantity:

- refund;
- replacement;
- hold/investigate;
- no action with reason.

For several affected units, the importer may split the proposal, for example one refund and one replacement.

The database must enforce:

```text
sum of proposed active remedy quantities <= affected quantity
```

The importer proposal is not authority to contact the retailer or complete the remedy.

### 6.4 Supervisor physical-receipt section

The existing supervisor/internal area gains a `Physical Receipt Reviews` queue and detail view.

This is a new section in the existing supervisor area, not a new operational system.

The supervisor can approve the proposed route and quantity, reduce or correct the approved quantity, change the proposed route, reject, return for more evidence or approve no action with reason.

The initial supervisor decision authorises which retailer route may be pursued. It does not mean that the retailer has agreed, the refund has been received or the replacement has been completed.

### 6.5 Existing retailer-facing route

After initial supervisor approval, the case is created in or linked to the existing exception/retailer-conversation route.

The current role matrix and current application permissions decide which importer/operator user executes retailer contact. This addendum does not broaden retailer-contact permissions merely because a UI route is named `/importer/...`.

The existing retailer-facing user contacts the retailer, records communications, uploads retailer evidence, records the retailer response, uses the existing return/collection bridge where applicable and submits the retailer outcome for final supervisor approval.

The supervisor approves or rejects the final retailer outcome.

Only after final approval may the refund route complete or the replacement child be created.

### 6.6 Refund outcome

The refund route reuses the existing dispute, refund evidence, supplier credit/refund, return/collection, DVA/card refund-IN, customer credit, payout and customer credit-note controls.

The system must keep separate:

1. supplier-side recovery from the retailer;
2. customer-side settlement to the importer/customer.

The same affected quantity must not result in more than one completed customer settlement outcome.

A supplier credit note or retailer refund does not itself prove a customer payout, customer credit or customer credit note.

### 6.7 Replacement outcome

A final-approved replacement creates one replacement child order through the hardened existing replacement function.

The child must retain exact provenance to parent order, source dispute line, source physical receipt, source receipt line disposition, source tracking submission, source tracking line allocation, source supplier invoice line, approved replacement remedy allocation and approved replacement quantity.

The child then follows the existing normal order operations: supplier evidence or invoice; OCR/manual review where applicable; reconciliation; tracking; package receipt; customer review; shipment; customer commercial release where entitlement remains; supplier AP and shipping AP.

A replacement child is an operational fulfilment path, not automatically a new customer purchase.

A free replacement may have zero supplier cost and positive fulfilment quantity. It must not create an additional customer charge where the parent entitlement was already released.

A charged repurchase may create supplier/AP cost on the child. It still must not exceed the customer commercial entitlement of the parent unless a separate expressly authorised customer charge exists outside this addendum.

Replacement of a replacement remains disallowed as an automatic route. A failed replacement requires manual supervisor resolution rather than an uncontrolled child chain.

### 6.8 Shipper return action

Where the retailer requires return or collection, reuse the existing shipper return-action route and supervisor proof review.

Do not create a second physical return task family.

### 6.9 Shipment and customer release

Only exact clean, reviewed, unheld and not-already-shipped quantity enters shipment membership.

Only exact effective shipment quantity that is not already released enters customer-sales release.

Affected quantity cannot leak into shipment or billing because a package header later appears clean.

### 6.10 Finance, VAT and completion

Existing finance users continue using the current supplier AP, shipping AP, customer sales, refund, credit, payout, VAT and Sage routes.

Parent VAT release, accounting release and final completion remain blocked while any applicable condition remains open, including unresolved payout, unresolved shipper liability, unresolved physical remedy, unfinished replacement child, cancelled replacement whose remedy has not been rerouted or explicitly closed, incomplete export evidence or existing accounting/settlement blockers.

## 7. Required additive data structures

Exact final column types and foreign-key names must be checked against the live schema before implementation. The structures below are the governed minimum meaning.

### 7.1 `shipper_package_receipt_line_dispositions`

One row represents one quantity disposition within one exact tracking allocation in one receipt snapshot.

Minimum identity:

```text
id
receipt_id
tracking_submission_id
tracking_line_allocation_id
supplier_invoice_line_id
disposition_type
quantity
condition_note
created_at
```

Allowed dispositions:

```text
clean
damaged
missing
wrong
held
```

Required controls:

- foreign keys to the receipt, tracking submission, exact allocation and supplier invoice line;
- allocation/order/tracking identities must agree;
- quantity must be positive;
- cumulative disposition quantity per receipt and allocation must equal the allocation quantity;
- one receipt cannot contain duplicate ambiguous rows for the same allocation and disposition unless explicitly aggregated;
- rows are immutable after finalisation;
- later correction uses a later receipt snapshot;
- direct writes must be denied to ordinary users; the v2 RPC is the write authority.

### 7.2 `shipper_package_receipt_evidence`

Supports several evidence records for one receipt and optional exact disposition linkage.

Minimum meaning:

```text
id
receipt_id
line_disposition_id nullable
storage object path or current compatible evidence reference
original filename
content type
display order
uploaded by shipper user
created_at
```

Required controls:

- evidence linked to a disposition must belong to the same receipt;
- evidence rows must not be silently overwritten;
- existing storage-bucket and tenant access rules must not be weakened;
- no new public access is introduced merely for convenience;
- failure after upload must trigger best-effort cleanup and orphan cleanup;
- evidence additions after submission, if allowed, must be audited and must not rewrite the original receipt facts.

### 7.3 `physical_receipt_reviews`

This is a triage/control header, not a second retailer-remedy state machine.

Minimum meaning:

```text
id
receipt_id
order_id
tracking_submission_id
status
importer proposal submitted at/by
supervisor initial decision at/by
decision note
linked dispute id nullable
created_at
updated_at
```

Permitted states must be narrowly limited to the physical triage journey, such as:

```text
awaiting_importer_proposal
awaiting_supervisor_review
returned_for_information
approved_to_existing_exception
rejected
closed_no_action
```

Once linked to an existing dispute, the dispute and existing outcome route are authoritative. The physical review must not independently claim that a retailer refund was received or a replacement completed.

### 7.4 `physical_exception_remedy_allocations`

Represents the approved split of affected quantity by remedy and retains provenance.

Minimum meaning:

```text
id
physical_receipt_review_id
receipt_line_disposition_id
tracking_line_allocation_id
supplier_invoice_line_id
dispute_line_id nullable
remedy_type
remedy_qty
supplier_claim_amount_gbp nullable
customer_commercial_value_gbp nullable
supplier_cost_mode nullable
replacement_child_order_id nullable
replacement_child_tracking_allocation_id nullable
status
approved by/at
created_at
updated_at
```

Minimum remedy types:

```text
refund
replacement
hold_investigate
no_action
```

Minimum supplier cost modes:

```text
free_replacement
charged_repurchase
pending_supplier_evidence
not_applicable
```

Required controls:

- remedy quantity is positive;
- cumulative active/completed remedy quantity cannot exceed source affected quantity;
- refund and replacement may coexist only as separate exact allocations;
- a remedy allocation cannot attach to a different source allocation or line;
- one replacement allocation can produce at most one active replacement child;
- cancellation does not silently complete the remedy;
- completed refund/replacement provenance is immutable.

### 7.5 Receipt version/finalisation marker

The implementation must provide an unambiguous way to distinguish a legacy header-only receipt from a complete finalised v2 receipt.

This may be an additive version/finalisation column on the receipt header or an equivalent proven mechanism.

A v2 receipt must not become authoritative until all line dispositions have been inserted and validated in the same database transaction.

## 8. Shared quantity-position authority

Add one reusable read model, expected name:

```text
tracking_allocation_fulfilment_position_v1
```

It must calculate the state of each exact `order_tracking_line_allocations.id`.

Minimum outputs:

```text
order_id
tracking_submission_id
tracking_line_allocation_id
supplier_invoice_line_id
allocated_qty
physical_clean_qty
physical_exception_qty
reviewed_qty
active_hold_qty
shipped_qty
customer_released_qty
remedy_assigned_qty
review_available_qty
shipment_available_qty
remedy_available_qty
position_valid_yn
position_blocker
source_receipt_id
source_receipt_model
```

The model must recognise:

- finalised v2 receipt: use exact dispositions;
- legacy latest `received_clean`: treat full allocation as clean, preserving current behaviour;
- legacy damaged/held/not-received without exact quantities: fail closed;
- no receipt: no physical clean availability.

The position is a sequence of cumulative milestones, not a set of independent buckets that can always be added together.

At minimum:

```text
physical_clean_qty + physical_exception_qty = allocated_qty
reviewed_qty <= physical_clean_qty
non-void shipped_qty <= physical clean quantity permitted after exact holds
active customer release qty <= effective shipped qty
active/completed remedy qty <= physical_exception_qty
```

Availability must be derived only when the source position is valid.

Do not use `GREATEST(..., 0)` or similar clipping to conceal a broken invariant. Where a consumed quantity exceeds its cap, `position_valid_yn` must be false, availability must fail closed, `position_blocker` must identify the anomaly and an operational diagnostic must be available.

For compatibility, an outward function may return zero availability, but the anomaly must remain explicit and must block automatic progression.

The helper must avoid double subtraction where the same quantity has moved through review, shipment and release. It must use cumulative position and exact provenance, not add all milestone totals as though they were disjoint.

## 9. Atomic v2 receipt RPC and application action

Add:

```text
shipper_record_package_receipt_v2
```

The exact signature may use structured JSON, but it must receive enough information to prove one package/tracking submission, one complete set of allocation dispositions, notes, evidence references and idempotency/submission identity.

Required behaviour:

1. authenticate `auth.uid()`;
2. resolve one active shipper user and shipper;
3. verify the package is current, not superseded and belongs to that shipper;
4. lock the tracking submission and exact allocations;
5. validate every supplied allocation identity;
6. validate complete quantity balance;
7. reject unknown, omitted or duplicate allocation data;
8. insert one receipt header;
9. insert all line dispositions;
10. insert evidence metadata;
11. mark the receipt finalised only after all validation succeeds;
12. materialise the existing customer review cycle for positive clean quantity;
13. create the physical triage header when affected quantity is positive;
14. return the receipt ID;
15. be idempotent for a retry with the same submission ID and same payload;
16. reject a retry that reuses the submission ID with different facts.

Storage uploads are not part of a PostgreSQL transaction. The server action must therefore use a deterministic receipt/submission ID or pending upload path, call the RPC, delete newly uploaded objects on failure where possible and provide orphan cleanup. The database remains the authority for which evidence belongs to a successful receipt.

The existing application action in `app/shipper/actions.ts` must be changed surgically. Other shipper actions in that file must not be rewritten.

The existing receipt page is upgraded in place. It must not disturb return actions, shipping-document upload or unrelated shipper controls.

## 10. Legacy compatibility

### 10.1 Existing clean receipts

A legacy latest `received_clean` receipt continues to make the full exact allocation clean, subject to the existing review, hold, shipment and release gates.

This behaviour must be proven by regression comparison.

### 10.2 Existing non-clean receipts

A legacy damaged, held or not-received receipt without reliable line quantities remains blocked for automatic clean progression.

The system must not guess the affected quantity.

Staff may use a controlled remediation route to create a complete v2 correction where evidence supports it.

### 10.3 Existing v1 callers

`shipper_record_package_receipt_v1` retains its current signature and grants.

It must continue working for ordinary legacy callers where no finalised v2 receipt exists for that package context.

It must not be converted blindly into v2 by treating a package-level damaged status as though every unit were damaged.

After a finalised v2 receipt exists, a later v1 call must not silently supersede the exact v2 facts. It must either be rejected with a clear compatibility message or pass through an explicitly proven correction rule.

### 10.4 Existing data is not rewritten speculatively

Do not mass-backfill affected quantities, remedy source links or replacement provenance where the source is ambiguous.

Backfill only relationships that are uniquely proven.

Uncertain legacy rows fail closed for automatic completion and remain visible for staff remediation.

## 11. Existing functions: protected contracts and surgical changes

All replacements must preserve, unless an explicit contract migration proves otherwise, function name, identity arguments, return type, return column names/order/types, security mode, search path, grants, application call contract and existing unrelated gates.

### 11.1 `customer_review_cycle_candidates_v1`

Preserve exact tracking allocation identity, supplier invoice/current approval gates, previous review/release subtraction, proportional goods/delivery/discount allocation, legacy timed-link protection, no duplicate review membership, return shape and fingerprint purpose.

Change only the source eligibility:

- use `review_available_qty` from the shared position;
- do not require the entire package header to be `received_clean`;
- do not let an exception on one quantity block separate clean quantity;
- retain exact active hold controls;
- emit only positive valid quantity.

The value calculation remains proportional to the exact allocation quantity.

### 11.2 `customer_review_receipt_materialize_v1`

Final safe rule:

- retain the existing trigger behaviour for legacy v1 `received_clean` receipts;
- do not make the header trigger depend on v2 line rows that may not yet exist at header-insert time;
- `shipper_record_package_receipt_v2` must explicitly call the existing materialiser after all v2 line rows are inserted and validated.

Only modify this trigger function if implementation proves a minimal extension is necessary and trigger ordering is safe. Earlier discussion treated it as automatically unavoidable; this final contract narrows that position to avoid an unnecessary trigger rewrite.

Do not replace `internal_materialize_customer_review_cycles_v1`.

### 11.3 `shipper_shipment_batch_candidates_v1`

Preserve authentication and shipper-user resolution, shipper/importer ownership, tracking identity, current review-window truth, existing return columns and ordering and active-batch/hold protections where they remain exact.

Change:

- candidate quantity/value comes from valid `shipment_available_qty`;
- package header status is display/compatibility data, not the v2 quantity authority;
- the candidate exists when at least one exact allocation has positive shipment availability;
- value is prorated by exact eligible quantity.

Any current package-level active membership restriction that prevents a later eligible partial shipment must be replaced carefully by cumulative exact-quantity protection, after inspecting current constraints.

### 11.4 `shipper_create_shipment_batch_v1`

Preserve signature and return UUID, authentication, shipper/importer ownership, booking and shipment metadata, review-window enforcement, current shipment tables, immutable line membership and downstream effective-line authority.

Change the membership snapshot from full allocation quantity/value to exact current shipment-available quantity/value.

Required concurrency controls:

- advisory/order and tracking locks as currently used;
- row lock exact allocations or an equivalent serialisation lock;
- recalculate availability inside the transaction;
- reject zero or invalid position;
- insert immutable membership;
- cumulative non-void shipment quantity cannot exceed clean shipment entitlement.

A second batch may use later remaining eligible quantity, but no quantity may be present in two active/effective batches.

Do not weaken direct RPC enforcement because the UI candidate page appears correct.

### 11.5 `internal_customer_sales_release_sources_v1`

Preserve the staff gate, immutable effective shipment lines as source, exact shipment batch/tracking allocation/supplier-line provenance, commercial parent mapping, supplier approval/current checks, shipping-cost allocation, previous durable release subtraction, main/supplementary invoice determination and blocker output contract.

Replace whole-package/whole-line assumptions:

- do not require a whole-package `received_clean` header for a v2 effective clean shipment;
- do not block all quantity because another quantity on the same supplier line has an open physical exception or terminal refund;
- calculate remaining releasable quantity from exact effective shipment membership minus active release membership and exact conflicts.

For replacement children, customer charge is limited by remaining parent commercial entitlement. Supplier child cost is not the customer charge authority.

### 11.6 `customer_sales_release_guard_v1`

Preserve every existing strong guard: immutable release provenance, restricted reversal after Sage state, sales invoice identity, exact tracking allocation identity, exact supplier invoice and line identity, commercial parent identity, supplier approval/current status, effective shipment membership, cumulative quantity and value caps and delivery/discount caps.

Replace only overly broad physical assumptions: package-wide clean check, any-dispute-on-line blocker and terminal-refund-on-line blocker.

The replacement checks must prove that the proposed exact release quantity is part of effective clean shipment membership and does not exceed remaining customer entitlement.

Add a commercial-parent cumulative cap across original and replacement sources so a replacement cannot create double customer billing.

### 11.7 `customer_sales_release_financial_guard_v1`

Preserve cumulative delivery share, cumulative discount share, exact batch shipping allocation, active release rules and source/commercial parent identity.

Prefer changing the exact hold/conflict helper rather than rewriting this trigger if that safely preserves the trigger body.

Any hold check must answer whether the proposed exact release overlaps held quantity. It must not block unrelated clean quantity merely because the supplier invoice line has an active partial hold.

### 11.8 `order_has_open_child_exceptions`

Preserve the existing conversation-status test and extend the function so it also returns true when:

- a replacement child of the parent is not successfully complete/archived under the accepted lifecycle rule;
- an approved physical remedy remains unfinished;
- a cancelled replacement has not been rerouted or explicitly closed;
- a legacy child is linked through dispute fields even when `replacement_source_dispute_line_id` is null.

This central repair allows existing callers such as VAT release, accounting release and status recomputation to inherit correct blocking without separate rewrites.

A dependency scan must identify every completion, archive, VAT and accounting writer. No writer may bypass the direct child/remedy check.

### 11.9 `create_replacement_child_order`

Keep the current public signature for existing callers.

Implement one hardened transactional core and route the existing function through it where appropriate.

For a physical-origin remedy, the core must lock parent/dispute line/remedy allocation, validate final supervisor approval and exact approved quantity, ensure refund plus replacement does not exceed affected quantity, prevent duplicate child creation, write exact source provenance, distinguish supplier cost mode from customer commercial value, create the child and links atomically, preserve current order-operation compatibility and avoid treating child creation as child completion.

A partial unique index on non-null `orders.replacement_source_dispute_line_id` is required if live duplicates do not prevent it. A separate uniqueness rule must bind one physical replacement allocation to at most one active child.

Historical children with null source must be backfilled only when the source is uniquely proven.

### 11.10 `order_reconciliation_vw`

Preserve the exact public column names and compatible types:

```text
order_id
qty_target
qty_progressed_invoiceable
qty_resolved_noninvoiceable
qty_unresolved
amount_target_gbp
amount_progressed_invoiceable_gbp
amount_resolved_noninvoiceable_gbp
amount_unresolved_gbp
invoiceable_subset_released_yn
whole_order_cleared_yn
last_refreshed_at
```

Repair source selection, not just displayed arithmetic.

The replacement must consume the current authoritative/current supplier invoice identity; exclude superseded, rejected and duplicate supplier evidence according to existing controls; keep original and replacement-child supplier/AP reconciliation separate; avoid subtracting a post-progression physical remedy as though the supplier line never progressed; identify over-progression explicitly; never declare whole-order clearance when progressed or resolved totals exceed the baseline; and avoid concealing anomalies with clipping alone.

Because the public shape cannot safely gain arbitrary columns, expose anomaly detail through an additive diagnostic view/table such as `order_reconciliation_anomalies_v1`.

A candidate/shadow definition may be used during implementation comparison, but the final corrected public view is installed in the same production release. There is no later feature switch.

The known regression case must be included in tests:

```text
DAY3-TRACK-1d7cfa66
target qty 1 / progressed qty 3
target £100 / progressed £155
```

The final behaviour must identify the source anomaly and must not treat negative unresolved values as valid lifecycle truth.

## 12. Functions and systems that must remain intact

The implementation must preserve unless current dependency inspection proves a narrowly required patch:

```text
internal_materialize_customer_review_cycles_v1
customer_review_cycle_cumulative_qty_guard_v1
customer_review_cycle_component_guard_v1
customer_review_cycle_membership_immutable_guard_v1
shipper_tracking_review_state_v1
shipper_shipment_batch_effective_lines_v1
customer_sales_release_total_guard_v1
customer_sales_invoice_release_identity_guard_v1
approve_vat_release
mark_order_accounting_release_ready
recompute_order_status
```

Also preserve current supplier invoice upload/OCR/manual line/reconciliation pages; exact-invoice routing and multi-supplier support; progression and `partially_progressed` lifecycle stability; customer-review links/deadlines/memberships; customer hold records and customer-hold refund conversion; shipment batches/documents/cost allocations/export evidence; durable customer-sales release membership; main/supplementary/credit-note customer invoices; Sage snapshots/payloads/freeze/validation/idempotency/posting; supplier AP/payment readiness and allocations; refund evidence/supplier credit notes/DVA-card refund matching; importer/operator retailer-conversation pages; replacement child normal operations; shipper return actions and supervisor proof review; tenant and role boundaries.

## 13. UI and route contract

### 13.1 Shipper

Upgrade `/shipper/package-receipts`. Do not create a second receipt page.

Normal all-clean submission remains quick. Affected line controls remain collapsed until needed.

Show clear totals: allocated, clean, affected and remaining to classify.

Prevent submission client-side for convenience and database-side for authority.

### 13.2 Importer

Add a dashboard section and read/write detail convenience route, expected shape:

```text
/importer/physical-receipts
/importer/physical-receipts/[review_id]
```

These pages write the physical review/remedy proposal records only.

After supervisor initial approval, link to the existing exception route, expected existing shape:

```text
/importer/exceptions/[dispute_id]
```

Do not duplicate retailer evidence, communication or final outcome controls.

### 13.3 Supervisor

Add a section and detail convenience route in the existing internal area, expected shape:

```text
/internal/physical-receipts
/internal/physical-receipts/[review_id]
```

The queue shows awaiting review, returned for information and approved/linked states.

The detail page shows evidence, exact quantities, importer proposal and decision controls.

It must link to the existing internal exception detail after conversion.

### 13.4 No dead ends

Every page must show current state, action available now, who is expected to act next, link to the continuing route and closed state when no further action is required.

## 14. Security, RLS, audit and evidence

Before implementation, inspect current grants, RLS and storage policies.

Required role boundaries:

- shipper can write physical receipt facts only for its own current packages;
- importer can see its own affected receipts and submit proposals;
- supervisor/staff can review and route according to current staff permission helpers;
- retailer-facing execution remains with the existing authorised role;
- no role gains VAT, Sage, DVA/card, supplier coding or payment permissions through this build.

Use existing active-user helpers and tenant identities. Do not hardcode a country or tenant.

Every significant write must be auditable: receipt snapshot, correction reason, importer proposal, supervisor initial decision, dispute linkage, final outcome, remedy allocation, child creation and remedy cancellation/reroute.

`SECURITY DEFINER` functions must use a safe explicit `search_path` and perform their own ownership/role checks.

## 15. Concurrency and database enforcement

UI validation is not authority.

Database controls must serialise and reject:

- two receipt submissions using the same idempotency key with different facts;
- review membership beyond clean quantity;
- two shipment batches consuming the same clean quantity;
- two remedy decisions consuming the same affected quantity;
- duplicate replacement child creation;
- customer release beyond effective shipment membership;
- customer release beyond parent commercial entitlement;
- correction that would reduce clean quantity below already-reviewed, shipped or released quantity;
- correction that would reduce affected quantity below already-approved/completed remedy quantity.

Use row locks, advisory locks and cumulative guards consistently with current platform conventions.

## 16. Migration and deployment structure

Use one coordinated production release containing several focused migrations, not one oversized migration.

Recommended order:

1. foundation: additive columns/tables, constraints, indexes, RLS/grants and quantity-position read model;
2. receipt and physical-review workflow: v2 receipt RPC, importer proposal, supervisor initial review and remedy allocation;
3. compatibility: review candidate, shipment candidate, shipment creation and sales release source/guards;
4. lifecycle and reconciliation: replacement hardening, child/remedy completion blocking, reconciliation replacement and anomaly read model;
5. verification: assertions and regression tests without retained test transactions.

Database changes must be backward compatible with the old application during the short deployment window.

The application is then deployed to call v2 for normal receipt submissions.

There is no feature flag to turn on later.

## 17. Preflight and anti-overwrite controls

Before writing migrations:

1. fetch current repository `main`;
2. inspect every target file and live definition;
3. inspect dependencies, overloads, return types, grants, policies and constraints;
4. record expected definition fingerprints;
5. abort if production differs;
6. do not change unrelated code in large mixed files.

For `CREATE OR REPLACE FUNCTION`, preserve the exact signature and return contract. Where PostgreSQL cannot replace a return type safely, use an additive version and explicit controlled caller migration rather than drop-cascade.

Never use `DROP ... CASCADE` as a convenience.

## 18. Regression and acceptance tests

The release is not complete until automated tests prove all of the following.

### 18.1 Legacy

1. A legacy clean receipt behaves identically before and after.
2. Existing review links and deadlines remain unchanged.
3. Existing shipments and release memberships remain unchanged.
4. Legacy uncertain non-clean receipts fail closed.
5. Existing v1 caller still records an ordinary legacy receipt.
6. A v1 write cannot silently override a finalised v2 receipt.

### 18.2 Receipt

7. All-clean v2 receipt creates full clean position and no physical exception.
8. Three units with two clean and one damaged balance exactly.
9. Multiple supplier lines balance independently.
10. Damaged, missing, wrong and held quantities remain distinct.
11. Several evidence files link correctly.
12. Invalid, omitted, duplicate, negative or over-allocated quantities are rejected.
13. Retried identical submission is idempotent.
14. Retried changed payload is rejected.
15. Correction cannot invalidate irreversible downstream use.

### 18.3 Review

16. Only clean quantity materialises into the existing review cycle.
17. Review membership is created once.
18. Existing fixed deadline is used.
19. Review quantity cannot exceed clean quantity.
20. A partial physical exception does not block unrelated clean quantity.
21. Exact customer holds still block their applicable quantity.

### 18.4 Shipment

22. Candidate quantity equals remaining eligible clean quantity.
23. Direct shipment RPC enforces the same truth.
24. Immutable shipment membership stores exact quantity/value.
25. Two concurrent shipment requests cannot duplicate quantity.
26. Later remaining eligible quantity can use a later batch without reusing prior quantity.
27. Existing shipping documents and effective-line read model still work.

### 18.5 Importer and supervisor

28. Affected receipt appears in importer Physical Receipt Exceptions.
29. Importer can split affected quantity between refund and replacement.
30. Proposal total cannot exceed affected quantity.
31. Supervisor can approve, alter, reject or request evidence.
32. Initial approval links into the existing exception route.
33. No duplicate retailer workflow is created.
34. Initial route approval and final retailer-outcome approval remain separate.

### 18.6 Refund

35. Approved refund uses existing evidence and retailer route.
36. Supplier recovery remains separate from customer settlement.
37. One quantity cannot receive both duplicate payout and credit.
38. Refund plus replacement cannot exceed affected quantity.
39. Return action, refund-IN and Sage gates remain intact.

### 18.7 Replacement

40. One approved allocation creates one child.
41. Exact source provenance is written.
42. Free replacement has zero supplier cost without creating an extra customer charge.
43. Charged repurchase creates child supplier/AP cost without duplicating customer entitlement.
44. Pending supplier evidence remains blocked appropriately.
45. Unfinished child blocks parent VAT/accounting/completion.
46. Child creation does not equal child completion.
47. Cancelled child reopens/reroutes or continues blocking.
48. Replacement of replacement is not created automatically.
49. Legacy child with uncertain provenance fails closed for automatic closure.

### 18.8 Customer sales and accounting

50. Release quantity cannot exceed effective shipment membership.
51. A partial line dispute does not block separate clean shipped quantity.
52. Original plus replacement customer release cannot exceed parent entitlement.
53. Existing main/supplementary invoice logic remains.
54. Sage-posted provenance remains immutable.
55. Supplier AP, customer sales and VAT truths remain separate.

### 18.9 Reconciliation and lifecycle

56. The known negative regression case is diagnosed and not treated as cleared.
57. Over-progression is explicit.
58. Normal existing orders compare correctly to the prior view.
59. `partially_progressed` is not sent backwards.
60. All completion/VAT/accounting writers respect unfinished child/remedy state.

### 18.10 Security and operations

61. Cross-tenant reads/writes fail.
62. Shipper cannot choose remedy or financial values.
63. Importer cannot final-approve.
64. Retailer-facing user cannot bypass supervisor approval.
65. Evidence access is no broader than current policy.
66. Every queue has a next action and no dead-end page.
67. Type checking, linting, build and existing regression suites pass.

## 19. Rollback and failure behaviour

The additive database foundation and retained v1 contract ensure the old application remains operable before the v2 application deployment.

If the application deployment fails, the old application may continue using v1 for packages without finalised v2 history.

Do not roll back database quantity protections after v2 data has been written merely to restore old all-or-nothing assumptions.

If a critical issue is found after v2 use begins, stop new v2 submissions through an operational deployment rollback or access control approved by staff, retain recorded facts, repair forward with an additive migration, do not delete or reinterpret v2 receipt history and keep clean/affected quantities fail closed until repaired.

Rollback plans must not require deleting customer releases, shipments, invoices, Sage records or evidence.

## 20. Explicitly prohibited shortcuts

Do not:

- change a damaged package header back to clean merely to release clean units;
- duplicate supplier invoice lines or order lines to split quantities;
- clone OCR lines as manual lines;
- store full allocation quantity in a partial shipment snapshot;
- rely on page validation without database guards;
- create a second damaged-goods module;
- create a second review deadline;
- create a second shipment or refund route;
- treat dispute `resolved_replacement` as child completion;
- treat refund approval as refund-IN receipt;
- treat supplier credit as customer settlement;
- calculate customer charge from replacement supplier cost;
- let replacement child create a fresh customer/VAT event by default;
- guess legacy quantities or provenance;
- hide reconciliation anomalies with `GREATEST`;
- use feature flags or require later code activation;
- use `DROP CASCADE`;
- overwrite a live function whose fingerprint differs from the reviewed baseline.

## 21. Definition of done

The build is complete only when:

- the upgraded receipt page is the normal production route for all shippers;
- all-clean remains fast;
- clean and affected quantities separate exactly;
- importer and supervisor sections are connected to the existing exception route;
- refund and replacement reuse existing operations;
- exact quantity provenance survives through review, shipment, release and remedy;
- replacement children retain exact source and block parent closure while unfinished;
- legacy clean operation remains compatible;
- unclear legacy data fails closed;
- the reconciliation anomaly is repaired transparently;
- all protected upstream and downstream regression suites pass;
- no temporary workflow, feature flag or later activation remains.

The governing principle is:

```text
Preserve the working machinery.
Add exact quantity truth at the physical receipt boundary.
Route clean quantity through the existing machinery.
Route only affected quantity through the existing controlled exception machinery.
Never guess, duplicate, bypass or weaken downstream authority.
```
