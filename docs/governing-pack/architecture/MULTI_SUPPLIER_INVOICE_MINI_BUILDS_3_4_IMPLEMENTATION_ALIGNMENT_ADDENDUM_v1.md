# Multi-Supplier-Invoice Mini-builds 3 and 4 Implementation Alignment Addendum v1

Status: governing corrective alignment for Mini-builds 3 and 4

Effective repository baseline: `main` at `eab6cb985fc40500b70cd2dccdd890c33b54ce1b`

Baseline date: 20 July 2026

## 1. Purpose

This addendum freezes the actual platform state after Mini-builds 1 and 2 and the subsequent reconciliation, progression, customer-review, shipment-gate, customer-hold, refund-evidence and dashboard patches.

It exists to ensure Mini-builds 3 and 4 extend the live merged controls rather than reconstructing an older planned shape and accidentally removing, duplicating or weakening behaviour added after the original four-build sequence was drafted.

It governs only the remaining work:

```text
Mini-build 3 — durable customer-sales release provenance
Mini-build 4 — immutable repeat-review membership and ledger-aware hold hardening
```

This addendum does not create another order, supplier-invoice, reconciliation, customer-review, customer-hold, exception, refund, return, shipment, customer-invoice, VAT or Sage workflow.

## 2. Authority and precedence

This addendum must be read with:

1. `docs/governing-pack/architecture/MULTI_SUPPLIER_INVOICE_ORDER_CONTROL_ADDENDUM_v1.md`
2. `docs/governing-pack/ui/CUSTOMER_HOLD_INTEGRITY_AND_EXCEPTION_BRIDGE_ADDENDUM_v1.md`
3. `docs/governing-pack/backend/Progressive_Commercial_Release_and_Replacement_Invoicing_Addendum_v1.md`
4. `docs/governing-pack/ui/EXCEPTION_REFUND_REPLACEMENT_ROUTE_CONTRACT.md`
5. `docs/governing-pack/ui/PHYSICAL_RETURN_TASK_BRIDGE_CONTRACT_v1.md`
6. `docs/governing-pack/ui/SHIPPER_CUSTOMER_HOLD_HARD_BLOCK_LATER_CONTRACT_v1.md`
7. the existing VAT, customer-sales Sage, supplier AP, supplier-credit, funding, DVA/card, cash-posting and tenant controls.

Where those documents conflict with the verified merged state or with the rules below, this later corrective alignment controls for Mini-builds 3 and 4.

In particular:

1. The durable customer-sales release ledger is mandatory. The older statement that a dedicated release table is optional is superseded for repeated releases and multi-supplier-invoice orders.
2. The shipper shipment-candidate and direct shipment-creation hard blocks are built. The older contract wording that describes those two controls as future/not built is superseded.
3. Mini-build 4 is not a clean-sheet implementation. Existing hold integrity, refund-exception conversion, the 24-hour review deadline, shipment enforcement and customer/shipper countdown surfaces are protected prerequisites.
4. Historical deployed migrations remain immutable. Every database correction must be additive.

## 3. Verified merged baseline

The following merged work is part of the protected starting point.

### 3.1 Customer-hold integrity and existing refund bridge

PR #108, merge commit `1039a4a43d2c36bf44a4f66a06dc084181020c7b`, implemented:

- one active hold per applicable order/package/line target;
- overlap protection between hold scopes;
- conversion of supervisor-approved exact line/package holds into the existing refund dispute route;
- reuse of compatible open refund disputes;
- preservation of progression, tracking, package, supplier-invoice and audit facts;
- customer review visibility of order-wide hold state.

PR #109, merge commit `cf96408515c0e007a0f773d92d843011733171c0`, completed the customer-review order-wide hold-state migration.

These controls must not be recreated in Mini-build 4. Mini-build 4 may only harden them with immutable review membership, exact package membership and Mini-build 3 release-ledger checks.

### 3.2 Multi-supplier foundation and portal integration

PR #111, merge commit `9582d6aa35851d875159b37c226efc7644934bb8`, delivered Mini-build 1:

- current supplier-document identity by normalised reference family;
- sibling-safe approval and rejection;
- irreversible-use rejection protection;
- order bundle line and summary read models.

PR #113, merge commit `aed844eed73d39c22bd88ae0c1845bec2fa38ad5`, delivered Mini-build 2:

- additional genuine supplier-invoice uploads through the existing upload route;
- exact-invoice supervisor and importer navigation;
- multi-invoice delivery-allocation loading;
- one physical supplier-payment OUT allocated across exact approved invoices without invented bank rows or customer-funding splits.

Mini-builds 3 and 4 must consume those exact supplier invoice and line identities. They must not revert to latest-invoice, one-current-invoice-per-order or order-wide reconstructed identity.

### 3.3 Exact reconciliation and aggregate totals

PR #114, merge commit `5d212381836845adf2ed0f387933948c539968c8`, established:

- exact `supplier_invoice_id` routing for reconciliation actions;
- persistence of the selected invoice through line actions;
- invoice-specific financial checking;
- aggregate order-baseline totals across every active supplier invoice;
- preservation of manual-line, progression, non-physical and existing exception controls.

PR #115, merge commit `e9e6d80935437bcb94d8e21b8508150038a76a3d`, restored bulk-selection controls on the rewritten reconciliation page.

Mini-builds 3 and 4 must not replace or bypass those page/action contracts.

### 3.4 Formal supplier credit-note controls

PR #112, merge commit `b5ff7b9a80bb853c1e76e03666920cbcbbc7048c`, requires dates for formal supplier credit notes and blocks undated formal credit notes from release, approval and Sage readiness while retaining controlled legacy remediation.

PR #119, merge commit `8d3077bc329ac98e1bc5dc82809e906ec7ef1293`, restored editable submitted/OCR header cards, the existing correction RPC, correction reasons and existing approval/Sage guards.

Mini-builds 3 and 4 must not weaken supplier refund, supplier-credit or header-correction controls.

### 3.5 Atomic progression and status stability

PR #117, merge commit `232041300a2253d5e72717fd2ffecafb3c0a1861`, established:

- set-based operator bulk progression;
- preservation of `partially_progressed` during later reconciliation updates;
- no forbidden backward transition from `partially_progressed` to `reconciling`;
- movement to `ready_for_shipment` only through the existing explicit supervisor/admin handoff.

This is a permanent protected invariant.

No Mini-build 3 or Mini-build 4 migration, trigger, draft routine, review routine, hold conversion or status recomputation may:

- send a partially progressed order back to `reconciling`;
- invent a replacement status transition;
- mark partial customer release as whole-order completion;
- use customer-invoice creation to rewrite supplier-line progression.

### 3.6 Existing 24-hour review and shipment hard block

PR #116, merge commit `88669064658cda6877adb03d2abcdc5db47b84d0`, established the live control:

- the review window starts from the existing latest `received_clean` package-receipt timestamp;
- the existing customer review link is reused;
- the review deadline is stored in and read from `customer_order_review_links.expires_at`;
- package shipment candidates exclude the applicable package during the 24-hour window;
- direct `shipper_create_shipment_batch_v1(...)` calls enforce the same gate;
- requested or supervisor-approved order/package/line holds continue blocking the applicable package after the deadline;
- exact tracking/package identity is retained for new line holds;
- packages already inside a shipment cannot receive a new deadline-based hold;
- legacy untimed review links preserve their earlier compatibility behaviour.

PR #118, merge commit `453b46d5df854503990fb1604a34db2ffa26887f`, aligned the shipper dashboard with the same shipment-candidate RPC:

- `Add to shipment` appears only when the exact package is returned by the existing candidate RPC;
- the same remaining review time is displayed in its place;
- the UI refreshes at deadline;
- an active hold remains `Shipment blocked` after the deadline;
- dashboard ready counts use the same candidate truth.

PR #120, merge commit `eab6cb985fc40500b70cd2dccdd890c33b54ce1b`, added the customer order-card countdown:

- it reuses the existing customer review path;
- it reuses the existing `expires_at` deadline;
- it does not create a second receipt, clock, review, hold or shipment rule;
- the badge disappears after expiry.

The candidate-list prevention and direct-RPC rejection described as future work in `SHIPPER_CUSTOMER_HOLD_HARD_BLOCK_LATER_CONTRACT_v1.md` are therefore built and protected.

## 4. Protected single-source rules

### 4.1 One review deadline

There is one authoritative deadline:

```text
customer_order_review_links.expires_at
```

It is derived through the existing clean-receipt gate from the existing receipt timestamp.

Customer cards, the review route and the shipper dashboard must continue to consume that same deadline.

Mini-build 4 must not add:

- another timer column;
- another independently calculated 24-hour clock;
- another review-link family;
- a client-only shipment-eligibility decision.

### 4.2 One shipment eligibility truth

Shipment eligibility remains enforced through the existing shipment-candidate and shipment-creation controls.

The UI is a projection of that backend truth. It is not the control.

Mini-build 4 must not build a second candidate function, a second shipment action or a separate hold-only shipment gate.

### 4.3 One customer-hold and exception route

The existing customer hold table, supervisor workbench, refund dispute, operator retailer route, shipper return action, refund evidence, DVA/card refund-IN and Sage controls remain the route.

Mini-build 4 must patch exact provenance into that route. It must not create a parallel customer-hold-refund workflow.

### 4.4 One customer-sales draft and Sage route

Mini-build 3 must patch the existing customer-sales preview/draft/freeze/validation/posting path.

It must not create:

- a second customer-invoice draft function family;
- a second customer-sales workbench;
- a second Sage posting route;
- a replacement VAT calculation route.

## 5. Documentation conflicts resolved by this addendum

### 5.1 Durable release membership is mandatory

The earlier Progressive Commercial Release addendum allowed `line_items_json` to act as the Phase 1 source and described a dedicated release table as future hardening.

That position is no longer sufficient because the platform now requires:

- several active supplier invoices on one order;
- repeated supplementary customer invoices;
- quantity-aware partial releases;
- immutable customer review membership;
- exact already-released checks for hold/refund conversion;
- exact customer credit-note attribution.

The durable ledger is therefore mandatory before Mini-build 4 can be considered complete.

Customer invoice JSON may mirror durable membership for display or Sage payload compatibility, but JSON is not the authority for whether a source quantity has already been released.

### 5.2 Shipper hard block is an existing control

The following are existing controls, not Mini-build 4 deliverables:

```text
shipper_shipment_batch_candidates_v1() excludes blocked packages
shipper_create_shipment_batch_v1(...) rejects blocked packages defensively
```

Mini-build 4 must regression-protect these controls and integrate immutable membership with them. It must not rebuild them.

### 5.3 Mini-build 4 is partially implemented

Already implemented:

- hold target integrity;
- overlap protection;
- progressed-line/package conversion to the existing refund dispute;
- package shipment hard block during the review period and active holds;
- one shared review deadline;
- customer countdown;
- shipper countdown/action replacement.

Still remaining:

- durable review-cycle membership;
- ledger-backed already-customer-released checks;
- exact legacy/current review membership migration rules;
- definitive repeated review-cycle eligibility;
- quantity-aware package/line hold interaction with repeated releases;
- exact customer-credit treatment where affected value has already been released;
- final hold-worklist closure hardening where current live objects do not already provide it.

## 6. Mini-build 3 — remaining governed scope

### 6.1 Durable release ledger

Add an additive durable structure named:

```text
customer_sales_release_lines
```

or an equivalent name only where an existing exact structure already provides the same authority.

Every active membership must retain at least:

```text
sales_invoice_id
sales_invoice_type
order_id
commercial_parent_order_id
supplier_invoice_id
supplier_invoice_line_id
tracking_submission_id
tracking_line_allocation_id
released_qty
goods_amount_gbp
delivery_share_gbp
discount_share_gbp
shipping_amount_gbp
release_status
membership_fingerprint
created_at
created_by
reversed_at
reversed_by
reversal_reason
```

The ledger must preserve exact source identity even when:

- several supplier invoices contribute to one customer sales invoice;
- one package contains lines from several supplier invoices;
- one tracking allocation is released in more than one quantity tranche;
- a replacement child supplies value later released on the commercial parent;
- one order has one main and several supplementary customer invoices.

### 6.2 Quantity and value protection

Within one database transaction and under appropriate source/order locking:

1. Active released quantity for a tracking allocation and source line must not exceed the exact allocated/eligible quantity.
2. Active released value must not exceed the recomputed eligible source value and allocated delivery/discount/shipping shares.
3. A client-provided amount is not authoritative. The server must recompute from existing approved sources.
4. The same exact membership retry must return/reuse the same draft or result.
5. Concurrent attempts must not create duplicate active membership or duplicate customer documents.
6. Partial quantity release must not block later release of the verified remaining quantity.
7. A void/supersede action must not silently free membership. Any reversal must be explicit, audited and compatible with Sage/document state.

### 6.3 Existing preview and draft path

The existing customer-sales preview must preserve and submit the exact source IDs already produced by the current route.

The existing draft routine must be patched to:

- validate those IDs against live active supplier invoices and exact tracking allocations;
- recompute eligibility server-side;
- create the sales document and ledger membership atomically;
- derive a deterministic membership fingerprint;
- return the existing draft on an identical retry;
- fail closed where supplied source membership has changed or is ambiguous.

No release may be inferred solely from:

- line description;
- amount equality;
- order total;
- latest supplier invoice;
- dynamic order-wide JSON;
- the existence of one prior customer invoice.

### 6.4 Main and repeated supplementary documents

The existing document types remain:

```text
main
supplementary
credit_note
```

Rules:

1. The first non-void release for the commercial parent is `main`.
2. The existing one-non-void-main uniqueness remains.
3. Every later newly eligible release is `supplementary`.
4. More than one supplementary is permitted.
5. Supplementaries link to the original main where the existing schema supports it.
6. A shipping-only supplementary route remains compatible.
7. Partial release is not whole-order completion.

### 6.5 Replacement-child boundary

A replacement child remains a separate operational fulfilment order.

For customer-sales release:

- if the affected commercial value was already released, the replacement is fulfilment correction and does not create a second customer sale by default;
- if the value was not previously released, the later stable replacement-child source may create a supplementary release against the commercial parent;
- exact child supplier/tracking source IDs must remain in the ledger;
- no new funding event is created for the replacement child merely because it becomes releasable.

### 6.6 Release eligibility

A source quantity may enter Mini-build 3 release only when it is:

- on an active supplier invoice;
- exact to a supplier invoice line;
- progressed/eligible under the existing progression truth;
- confirmed for quantity and value;
- allocated to known tracking/package scope where the current release path requires it;
- received at the existing warehouse/shipping checkpoint required by the current customer-sales route;
- outside an active requested or supervisor-approved hold scope;
- outside an unresolved blocking exception/return scope;
- not already actively released in the durable ledger;
- supported by the existing funding and accounting prerequisites.

### 6.7 Legacy customer-sales documents

Existing non-void customer sales documents must be handled conservatively.

Backfill durable membership only where exact source IDs and quantities can be proven from existing structured records or frozen payloads.

Do not backfill by guessing from descriptions, totals, retailer names or likely matches.

Where exact legacy membership cannot be proven:

- retain the historical document;
- record/report the unresolved legacy provenance;
- block release of potentially overlapping source quantity until reviewed or corrected;
- do not silently mark the whole order released;
- do not fabricate source membership.

### 6.8 Sage and VAT boundary

Mini-build 3 must retain the existing:

- customer-sales freeze;
- validation;
- queue/batch creation;
- idempotency;
- request/response logging;
- confirmed-posted state transition;
- prepayment-first VAT timing;
- Box 6 anti-duplication controls;
- export evidence and zero-rating controls.

The release ledger provides source provenance. It does not itself post to Sage or create VAT reporting rows outside the existing route.

### 6.9 Status boundary

Mini-build 3 must not:

- regress `partially_progressed` to `reconciling`;
- move an order to `ready_for_shipment` outside the current explicit handoff;
- mark the parent complete because one release succeeded;
- change supplier invoice progression while creating a customer document;
- make one successful sibling invoice clear another sibling's blockers.

## 7. Mini-build 3 minimum regression proof

Mini-build 3 is not complete until transaction-based regression proves at least:

1. Existing one-invoice, one-release order remains compatible.
2. First exact stable release creates one `main` document and exact ledger membership.
3. Three later newly eligible releases create three separate supplementaries.
4. One customer invoice may contain exact lines from several active supplier invoices.
5. One package containing lines from several supplier invoices retains each original source.
6. Identical retry returns/reuses the existing draft/result.
7. Concurrent identical calls do not create duplicate documents or membership.
8. Concurrent overlapping quantity calls cannot over-release a tracking allocation.
9. A partial quantity release leaves only the verified remainder eligible.
10. Active hold scope excludes the exact held source without blocking clean unrelated source.
11. Unresolved exception/return scope remains excluded.
12. Retired supplier-invoice versions cannot be released.
13. Replacement value already released does not create another customer sale.
14. Previously unreleased replacement-child value may create a supplementary on the commercial parent.
15. Void/supersede does not silently free membership.
16. Ambiguous legacy provenance fails closed without invented membership.
17. Existing customer-sales Sage freeze and posting route still works.
18. Sage is not marked posted without a confirmed Sage response.
19. VAT Box 6 is not duplicated by main or supplementary release.
20. `partially_progressed` remains stable and is not sent back to `reconciling`.
21. Exact reconciliation selection, aggregate bundle totals and existing exception controls remain unchanged.
22. No supplier AP, supplier-credit, funding, loyalty, cash-posting or tenant rule changes.

## 8. Mini-build 4 — remaining governed scope

Mini-build 4 begins only after Mini-build 3 is merged and the durable release ledger is the authoritative already-released source.

### 8.1 Reuse the existing review link and deadline

Continue to use:

```text
customer_order_review_links
customer_order_review_links.expires_at
```

The existing link remains the secure route and deadline record.

Mini-build 4 adds immutable exact membership behind that link. It does not replace the link or deadline.

### 8.2 Immutable review-cycle membership

Add an additive durable structure such as:

```text
customer_review_cycle_membership
```

Each membership must retain at least:

```text
review_link_id
review_cycle_id
order_id
supplier_invoice_id
supplier_invoice_line_id
tracking_submission_id
tracking_line_allocation_id
package_or_tracking_identity
review_qty
review_value_gbp
membership_status
created_at
```

Membership is frozen when the review cycle is created.

An old link must never dynamically acquire:

- a later supplier invoice;
- a later supplier invoice line;
- a later tracking allocation;
- a later received-clean package;
- a source quantity that became eligible after link creation.

### 8.3 Newly eligible review membership

A source quantity may enter a new review cycle only when it is:

- on an active supplier invoice;
- progressed under the current progression truth;
- allocated to exact known tracking/package scope;
- received clean;
- not actively released in `customer_sales_release_lines`;
- not under an active requested or supervisor-approved hold;
- not linked to an unresolved blocking exception/return action;
- not already assigned to another active review cycle;
- not already reviewed/released beyond the remaining exact quantity.

A later supplier invoice or later received-clean package creates a later cycle containing only newly eligible source membership.

Creating a later cycle must not reopen, rewrite or expand an earlier cycle.

### 8.4 Existing active and legacy review links

Migration/backfill must preserve the current review link and its existing `expires_at`.

For an existing active timed link:

- materialise only the exact source membership provable from current structured review/tracking records at migration time;
- do not change the receipt timestamp or deadline;
- do not create another countdown;
- do not broaden the link after migration.

For legacy untimed links:

- preserve the compatibility behaviour already protected by PR #116;
- materialise exact membership only where it can be proven;
- do not invent a 24-hour deadline retrospectively.

If exact existing membership is ambiguous, fail closed. Keep the applicable shipment/release scope blocked for review rather than guessing.

### 8.5 Countdown and expiry behaviour

The customer and shipper displays continue to read the same existing deadline.

At expiry:

- the countdown disappears or refreshes through the existing UI behaviour;
- a clean, unheld package may become a shipment candidate through the existing backend function;
- an active hold or another existing blocker continues to exclude it;
- expiry does not automatically approve a hold, close an exception, release a customer invoice or create a shipment.

### 8.6 Hold scope and exact package membership

Hold scopes remain:

```text
order
tracking/package
line
```

Rules:

1. Order hold blocks every customer release and shipment inclusion for the order while active.
2. Tracking/package hold blocks only that exact package/tracking scope where membership is known.
3. Line hold blocks the exact source line and affected quantity.
4. Known package membership must be materialised into exact supplier invoice lines and quantities.
5. A package spanning several supplier invoices preserves each source separately.
6. Unknown, incomplete or over-allocated package membership fails closed for refund conversion.
7. Clean unrelated source remains eligible under its normal gates.

### 8.7 Ledger-aware hold-to-exception bridge

The existing PR #108 bridge remains the route.

Patch its already-released control to use Mini-build 3 durable membership.

For each affected quantity:

- if not customer-released, the approved exact hold may create/reuse the existing refund dispute;
- if already customer-released, do not silently treat it as unreleased or simply exclude it;
- retain the supplier refund and physical return exception route;
- route the released customer value to a customer credit note against the exact affected customer sales invoice;
- where the affected source spans a main and one or more supplementaries, create a separate customer credit note for each affected original customer sales invoice.

The bridge must preserve:

- `eligible_for_invoice_yn` and progression truth;
- confirmed quantity and value;
- supplier invoice identity;
- tracking allocation;
- package membership;
- receipt evidence;
- shipment evidence;
- progression timestamp;
- source evidence;
- audit timestamps.

### 8.8 Existing shipment hard block remains authoritative

Mini-build 4 must regression-protect, not replace:

```text
shipper_shipment_batch_candidates_v1()
shipper_create_shipment_batch_v1(...)
```

The candidate function and direct RPC must continue to enforce:

- the active 24-hour review window;
- requested and supervisor-approved order holds;
- requested and supervisor-approved tracking/package holds;
- requested and supervisor-approved line holds at the applicable package scope;
- conservative blocking where exact package mapping is unresolved.

The shipper dashboard must continue to use the candidate function as its source.

### 8.9 Hold lifecycle and shipper worklist closure

Audit history remains immutable.

An active set-aside instruction must stop qualifying for the active shipper worklist after the existing approved terminal state, including where applicable:

- supervisor rejection;
- supersession by a narrower approved hold;
- explicit supervisor clearance;
- approved cancellation;
- accepted physical return/collection proof;
- permanent approved removal from shipment scope;
- another approved terminal exception outcome that clears the physical hold.

Physical return acceptance does not by itself prove:

- refund money received;
- supplier credit approved;
- customer credit posted;
- Sage posting completed;
- financial exception closure.

### 8.10 Role and data boundary

Customer reviews only frozen membership and requests holds.

Operator/importer continues the existing retailer and evidence route after supervisor approval.

Supervisor controls approval, narrowing, exception decisions and proof review.

Shipper sees only physical package/item truth, set-aside state, return instructions and proof actions.

Shipper must not receive supplier/customer invoice values, VAT, DVA/card, funding, supplier-credit or Sage data.

## 9. Mini-build 4 minimum regression proof

Mini-build 4 is not complete until transaction-based and portal regression proves at least:

1. Existing timed review link retains its original path and `expires_at`.
2. Customer order-card and shipper countdown use the same deadline.
3. No second deadline/timer record is created.
4. Old review link does not acquire later supplier lines.
5. Later review contains only newly eligible exact membership.
6. Existing legacy untimed links retain compatibility behaviour.
7. Ambiguous legacy membership fails closed without guessed rows.
8. Exact membership from several supplier invoices may coexist in one review cycle.
9. Line hold excludes only the exact affected line/quantity.
10. Package hold excludes the exact known package.
11. Known package spanning several supplier invoices materialises each source line.
12. Unknown/incomplete package membership fails closed for refund conversion.
13. Progressed, tracked, received-clean approved held line reuses the existing refund dispute route.
14. Unprogressed held line continues to use the same existing route.
15. Compatible existing dispute is reused rather than duplicated.
16. Progression, tracking, package, receipt and audit evidence remain unchanged after conversion.
17. Mini-build 3 ledger prevents silent conversion of already-released quantity.
18. Already-released value routes to exact customer credit-note treatment.
19. Main and supplementary affected documents receive separate customer credit notes where required.
20. Supplier refund/credit evidence remains separated by original supplier invoice.
21. Retailer refund IN remains matched once and cannot exceed the physical source transaction.
22. During the 24-hour window, the package is absent from shipment candidates.
23. Direct shipment creation rejects the blocked package.
24. After expiry, active hold continues blocking the package.
25. Customer card timer disappears/refreshes through the existing behaviour at expiry.
26. Shipper `Add to shipment` remains hidden until the backend candidate function returns the package.
27. Existing clean, unheld packages still flow normally.
28. Package already in a shipment is not retroactively assigned a new deadline-based hold.
29. Accepted physical return removes the active set-aside instruction without deleting history.
30. Physical return acceptance does not falsely mark refund/accounting complete.
31. No financial values are exposed to shipper pages.
32. Existing exact reconciliation, bulk progression, credit-note, funding, VAT and Sage controls remain unchanged.
33. `partially_progressed` never regresses to `reconciling`.

## 10. Explicit non-goals

Mini-builds 3 and 4 must not:

- alter original order creation;
- restore one-current-supplier-invoice-per-order assumptions;
- use latest supplier invoice as order truth;
- rewrite exact reconciliation selection;
- replace aggregate multi-invoice totals;
- remove existing exception controls;
- replace bulk-selection behaviour;
- regress `partially_progressed` to `reconciling`;
- create another 24-hour clock;
- create another customer review route;
- create another shipment candidate or shipment creation route;
- create another customer-hold workbench;
- create another exception/refund/return route;
- unprogress held supplier lines;
- erase tracking, package, receipt or audit evidence;
- infer released source solely from JSON, description or value;
- create duplicate customer invoices on retry or concurrency;
- invent customer credit notes spanning several original sales invoices through one `linked_invoice_id`;
- expose financial/accounting data to shippers;
- change funding provenance, loyalty, supplier AP, supplier credit, cash posting, VAT or Sage except to consume exact new provenance;
- edit or delete historical deployed migrations.

## 11. Implementation and release sequence

The required sequence is:

1. Merge this contract alignment before implementation.
2. Rebase/create the Mini-build 3 implementation branch from the merged contract baseline.
3. Inspect the exact live Supabase tables, constraints, functions, triggers, views, grants and existing customer-sales preview/draft/freeze routines.
4. Stop if live drift invalidates the additive plan.
5. Implement Mini-build 3 through bounded additive migrations and surgical patches to the existing customer-sales route.
6. Run lint/build, transaction SQL regression and affected-role portal smoke tests.
7. Merge Mini-build 3 only after all exit criteria pass.
8. Create Mini-build 4 from the merged Mini-build 3 baseline.
9. Reinspect live review-link, receipt, shipment-candidate, shipment-creation, hold, dispute, return and customer-credit functions.
10. Implement only the remaining immutable membership and ledger-aware hardening.
11. Run the complete Mini-build 4 and cross-build regression matrix.
12. Merge only after every affected existing control remains proven.

## 12. Migration and deployment discipline

Each mini-build must have:

- its own implementation branch;
- bounded commits;
- additive migrations only;
- prerequisite assertions;
- explicit function-signature and table-column checks;
- transaction-based SQL regression;
- portal smoke tests for customer, importer/operator, supervisor/admin and shipper where affected;
- no live Sage posting during regression;
- no merge while required CI or deployment checks fail.

Do not modify a deployed migration to make the repository appear aligned with live Supabase. Use a new compensating migration.

## 13. Acceptance rule

Mini-builds 3 and 4 are complete only when the platform can prove from durable exact records:

```text
which supplier invoice and line supplied each quantity
which tracking/package allocation carried it
which immutable customer review cycle contained it
which review deadline governed that cycle
which exact quantity the customer held
which quantity was excluded, returned or refunded
which customer sales document released each quantity
which quantity remains unreleased
which customer credit note corrected already-released value
which supplier credit document belongs to each original supplier invoice
which physical money transaction was matched once
which Sage document was confirmed posted
and which operational or financial blocker remains open
```

No release, review, hold, shipment, refund, credit or posting status may be inferred solely from the latest supplier invoice, dynamic order-wide JSON, a client countdown, one successful sibling document or the existence of one customer invoice.
