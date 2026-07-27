# Shipper AP and Customer Shipping-Recharge Gate Separation Addendum v1

**Status:** Governing corrective implementation contract  
**Implementation status:** Contract only — implementation not yet authorised  
**Scope:** Shipper supplier-AP readiness versus customer shipping-recharge readiness  
**Authority:** This file is the build authority for this correction. No implementation may exceed it without explicit approval.

---

## 1. Objective

Deliver one platform-wide correction:

> An accepted shipper invoice may progress through the existing shipper-AP accounting route before its cost has been apportioned across customer orders. A customer invoice may include shipping only after the exact shipping apportionment has been approved.

The correction must preserve every unrelated working route and must not introduce a parallel mechanism, new status vocabulary, record-specific exception or UI workaround.

---

## 2. Explicit business rules

### 2.1 Goods-only customer invoices

A customer goods invoice does **not** require shipping apportionment.

The following remain permitted under all their existing gates:

- a goods-only main customer invoice;
- a goods-only supplementary customer invoice;
- a mixed customer invoice containing goods and already-approved apportioned shipping, where the current release route permits it.

A goods-only customer invoice must not be blocked merely because:

- the shipper invoice has not arrived;
- the shipper invoice has arrived but is not apportioned;
- shipper AP has not yet been frozen or posted.

### 2.2 Customer invoices containing shipping

Any customer invoice containing a shipping amount must continue to require:

- an accepted/current shipping document;
- an active approved shipping-cost apportionment;
- exact allocation to the relevant order and source scope;
- a positive remaining shipping delta not already customer-released;
- all existing release-ledger, duplicate, quantity, value, hold, exception, funding, VAT and Sage controls.

This applies to:

- shipping included in a mixed main invoice;
- shipping included in a mixed supplementary invoice;
- a shipping-only supplementary invoice.

A shipping-only first/main customer invoice remains prohibited.

A shipping-only supplementary remains permitted only after a non-void main exists and only for the exact approved remaining shipping delta.

### 2.3 Shipper AP

An accepted/current shipper invoice may enter the existing shipper-AP accounting route before customer/order apportionment is approved.

Shipper AP records the full amount owed to the shipper from the accepted shipping document. It does not determine:

- which customer bears the shipping cost;
- which order receives a shipping recharge;
- the amount of an individual customer recharge;
- customer-sales release membership;
- physical progression, review or shipment eligibility.

Approved apportionment remains the authority for customer recharge only.

---

## 3. Verified live defect

The live database proof established all of the following:

```text
readiness_explicitly_blocks_without_apportionment = true
sage_queue_depends_on_apportionment_route = true
freeze_rejects_non_ready_queue_rows = true
freeze_payload_reads_shipping_allocation_lines = false
freeze_payload_uses_full_shipping_document_amount = true
```

Therefore:

1. The current combined AP/recharge readiness route requires approved apportionment.
2. The canonical Sage-ready queue inherits that requirement for shipper AP.
3. The shipper-AP freeze function can consume only a ready canonical queue row.
4. The shipper-AP payload itself does not use allocation lines.
5. The shipper-AP payload posts the full accepted shipping-document amount as one purchase-invoice liability.

The first incorrect divergence is canonical shipper-AP queue admission.

The proven defect is the coupling of:

```text
shipper supplier-AP readiness
+
customer shipping-recharge readiness
```

The defect is not in document intake, OCR, allocation storage, customer release-ledger calculation, Mini-build 4, the existing frozen payload or the Sage adapter.

---

## 4. Required separation of truths

The platform must retain two independent readiness truths.

### 4.1 Shipper-AP readiness

Question:

> Is this accepted shipper invoice ready to be recognised and processed through the existing shipper purchase-invoice route?

This uses the shipping document's own approved facts and the existing accounting controls. It must not require customer/order shipping apportionment.

### 4.2 Customer shipping-recharge readiness

Question:

> Is this exact portion of shipping cost approved and available to charge to this customer?

This must continue to require approved apportionment and the exact remaining customer-release delta.

### 4.3 No implied cross-completion

Shipper AP becoming ready, frozen or posted must not:

- create a customer invoice;
- create, edit or approve an allocation;
- insert a customer-sales release-ledger row;
- mark customer shipping released;
- change goods progression;
- complete or expire a customer review cycle;
- clear a hold or exception;
- make a package shipment-eligible;
- complete an order.

Approved customer apportionment must not by itself mark shipper AP frozen or posted.

---

## 5. Active production routes to preserve

### 5.1 Shipper-AP route

```text
shipping document upload/evidence
→ shipping_documents
→ review and accepted_current
→ internal_ready_for_sage_queue_v2()
→ Accounting Command Centre grid/bulk candidate resolver
→ existing accounting server action
→ internal_freeze_shipper_ap_sage_batch_v1(uuid[], text)
→ sage_posting_snapshots
→ existing posting batch
→ existing Sage purchase-invoice posting and confirmation
```

The canonical public queue remains:

```text
public.internal_ready_for_sage_queue_v2()
```

The existing Accounting Command Centre buttons, actions, permissions and selection routes remain the only approved application route.

### 5.2 Customer shipping-recharge route

```text
accepted shipping document
→ approved shipping-cost allocation and exact allocation lines
→ existing customer-sales release-source resolver
→ exact remaining shipping delta
→ customer_sales_release_lines
→ existing customer draft route
→ existing customer-sales freeze, validation and Sage route
```

### 5.3 Mini-build 4 route

```text
exact supplier/tracking/received-clean eligibility
→ immutable customer review-cycle membership
→ existing review link and deadline
→ holds/exceptions
→ shipment candidate and direct-shipment enforcement
```

This correction must not enter, replace or weaken the Mini-build 4 route.

---

## 6. Affected platform population

The correction applies platform-wide to every current and future shipping document that is:

- active;
- reviewed and `accepted_current`;
- a qualifying shipper invoice/freight document for the existing shipper-AP lane;
- linked through its existing shipper and shipment-batch relationships;
- supported by its existing source document and amount;
- not already posted or locked by an existing active accounting snapshot or posting batch;
- otherwise capable of passing the existing shipper-AP freeze controls;
- but not yet covered by an active approved customer/order shipping apportionment.

No order, invoice, batch, shipping-document or test identifier may be embedded in the permanent implementation.

---

## 7. Mandatory implementation boundary

### 7.1 Approved build type

The approved implementation route is:

> One additive Supabase migration correcting only canonical shipper-AP queue admission.

No UI or application patch is authorised unless new evidence proves the existing application no longer consumes the canonical queue and freeze RPC as verified. If that occurs, stop before changing anything.

### 7.2 Preserve the canonical queue

The migration must use the repository's established preservation-and-composition pattern:

1. Assert the expected `internal_ready_for_sage_queue_v2()` function exists.
2. Assert its zero-argument signature and exact return shape.
3. Preserve the exact current canonical implementation under one private deterministic function name.
4. Recreate `internal_ready_for_sage_queue_v2()` with the same:
   - function name;
   - signature;
   - return columns, types and order;
   - language and volatility where applicable;
   - `SECURITY DEFINER` property;
   - `search_path`;
   - ownership/grants and caller compatibility.
5. Return every row from the preserved queue unchanged.
6. Add only missing qualifying shipper-AP rows excluded solely because apportionment is outstanding.
7. Deduplicate by the established exact identity:
   - `document_lane`;
   - `source_table`;
   - `source_id`.
8. Refuse migration if the current live signature or return shape differs from the expected canonical shape.

The migration must not reconstruct existing customer-sales, supplier-goods-AP, supplier-credit or working shipper-AP rows.

### 7.3 Preserve working apportioned rows

Where the preserved canonical queue already returns a shipper-AP row, the wrapper must return that exact existing row.

It must not:

- replace it;
- recalculate it;
- change its payload fields;
- duplicate it through the additive route.

### 7.4 Newly qualifying shipper-AP rows

A newly composed shipper-AP row must reuse the existing queue vocabulary and field semantics, including:

- `document_lane = 'shipper_ap'`;
- `source_table = 'shipping_documents'`;
- the existing shipping-document source ID;
- the established purchase-invoice intent type;
- shipment-batch and booking identity;
- shipper/counterparty identity;
- shipping-document reference, date, currency and full accepted amount;
- existing detail route and source-payload shape expected by freeze/revalidation.

The AP amount must be the full accepted shipping-document amount.

It must not be calculated from:

- shipping allocation lines;
- customer invoice values;
- order goods totals;
- a manually supplied amount.

### 7.5 Fail-closed admission

The additive route must not produce a ready shipper-AP row for a document that is:

- inactive;
- rejected, void, superseded or not accepted/current;
- not a qualifying shipper invoice/freight source;
- missing required shipper or shipment relationships;
- zero or negative where the current AP lane requires a positive purchase invoice;
- already represented by an existing canonical queue row;
- already locked by an active non-cancelled snapshot or posting batch under existing controls.

The existing freeze function remains responsible for its current downstream controls, including:

- authenticated accounting-admin access;
- a ready canonical queue row;
- shipper Sage supplier contact;
- shipping-document source file;
- freight ledger mapping;
- shipper-AP tax mapping;
- frozen-snapshot and idempotency protection.

### 7.6 Existing functions that must not be weakened

Do not relax, replace or bypass:

```text
internal_shipping_ap_recharge_readiness_preview_v1(uuid)
internal_customer_sales_release_sources_v1(uuid)
internal_customer_invoice_release_create_drafts_v1(uuid[])
internal_freeze_shipper_ap_sage_batch_v1(uuid[], text)
internal_revalidate_sage_posting_snapshots_v1(uuid[])
```

The combined shipping AP/recharge preview may remain for allocation and customer-recharge workflows.

The canonical queue wrapper is the only authorised production-object correction unless new evidence triggers a stop condition.

---

## 8. Absolute scope freeze

The patch must make **no changes** to:

- buttons or available actions;
- button enablement or disablement;
- individual or bulk selection behaviour;
- UI wording, layout, styling or navigation;
- role permissions or accounting-admin boundaries;
- document upload, OCR or review;
- shipping-document acceptance rules;
- shipping allocation creation, editing or approval;
- customer main/supplementary document types;
- customer invoice controls other than continuing to consume the unchanged approved-apportionment truth;
- goods-only customer invoicing;
- customer-sales release-ledger calculations;
- quantities, amounts, signs or rounding;
- VAT treatment;
- order progression or statuses;
- tracking, physical receipt or shipment gates;
- customer review links, deadlines or memberships;
- Mini-build 4 functions, triggers or tables;
- holds, disputes, returns, refunds or credit notes;
- funding, DVA/card, loyalty, banking or treasury;
- supplier-goods AP or supplier-credit lanes;
- shipper-AP freeze payload construction;
- Sage adapters or API calls;
- posted Sage records;
- existing snapshots, posting batches or historical source rows.

Do not add:

- a page;
- a button;
- an action;
- a status;
- a parallel queue;
- a second AP resolver;
- a second customer-recharge resolver;
- a record-specific exception;
- a historical repair or backfill.

---

## 9. Mini-build 3 compatibility

`customer_sales_release_lines` remains the authority for customer-released value.

The patch must not read from or write to that ledger to decide shipper-AP readiness.

Shipper AP freezing or posting does not count as customer release.

Goods-only and repeated supplementary releases continue under their existing exact source, quantity, value, hold, exception, funding and accounting controls.

Shipping value may enter customer release only through the existing approved-apportionment and exact remaining-delta route.

---

## 10. Mini-build 4 compatibility

The patch must not read from or write to Mini-build 4 membership to determine shipper-AP readiness.

The following remain unchanged and authoritative for customer review and shipment eligibility:

```text
customer_order_review_links
customer_review_cycle_memberships
customer_review_cycle_legacy_issues
internal_materialize_customer_review_cycles_v1(uuid, uuid)
shipper_tracking_review_state_v1(uuid, uuid)
shipper_shipment_batch_candidates_v1()
shipper_create_shipment_batch_v1(...)
```

Freezing or posting shipper AP must not:

- create a review cycle;
- add, expire or change review membership;
- alter `expires_at`;
- change hold state;
- change shipment-candidate results;
- create a shipment batch.

---

## 11. Permitted repository changes

Only the following files are authorised for the implementation:

1. This governing addendum.
2. One additive Supabase migration.
3. One transaction-based regression SQL file.
4. One governing-pack index entry only if required for discoverability.

No other file may be changed without stopping and obtaining explicit approval.

Historical deployed migrations must not be edited.

---

## 12. Regression contract

The implementation is incomplete until regression proves all of the following.

### 12.1 Canonical function preservation

- `internal_ready_for_sage_queue_v2()` retains its exact signature and return shape.
- Security mode, `search_path`, ownership/grants and caller compatibility are preserved.
- Every existing preserved queue row is unchanged.
- No existing row is duplicated.

### 12.2 Existing approved-apportionment working flow

For an existing accepted and approved-apportioned shipping document:

- exactly one shipper-AP queue row remains;
- amount, currency, reference, shipment batch, booking ref and counterparty remain unchanged;
- the preserved row wins over the additive route;
- the existing frozen payload continues to use the full shipping-document amount;
- no allocation, customer invoice or release-ledger row is created.

### 12.3 Accepted but unapportioned flow

For a controlled accepted/current shipper document with no active approved apportionment:

- exactly one shipper-AP queue row appears;
- it uses the full accepted shipping-document amount;
- it can enter the existing freeze route only when all existing freeze controls pass;
- no allocation is created, changed or approved;
- no customer invoice or customer-sales release row is created;
- repeated queue reads do not duplicate it;
- repeated freeze follows existing idempotency protection.

### 12.4 Customer-invoice protection

Without approved shipping apportionment:

- goods-only customer invoices retain their current behaviour;
- no customer invoice may include the unapportioned shipping amount;
- no shipping-only supplementary may be created;
- the existing customer release-source and draft functions retain their existing shipping blocker or zero-shipping result.

After approved apportionment:

- only the exact approved remaining shipping delta becomes eligible;
- all cumulative quantity, value and duplicate-release controls remain effective.

### 12.5 Mini-build 4 protection

Before and after the migration:

- review-link IDs remain unchanged;
- `expires_at` remains unchanged;
- membership IDs, counts, statuses and fingerprints remain unchanged;
- legacy review issues remain unchanged;
- hold results remain unchanged;
- shipment-candidate results remain unchanged;
- direct shipment creation retains the same review and hold enforcement.

### 12.6 Other accounting lanes

Representative results remain unchanged for:

- customer sales;
- supplier-goods AP;
- supplier credit;
- existing shipper AP;
- already-frozen rows;
- posted rows;
- sources locked in active posting batches.

### 12.7 No live Sage call

Regression must not call Sage or mark any source posted.

Any controlled proof data must run transactionally and roll back.

---

## 13. Stop conditions

Stop before implementing or applying the migration if any of the following is found:

- the live canonical queue signature or return shape differs from the expected shape;
- a later deployed definition no longer uses `internal_ready_for_sage_queue_v2()` as the shipper-AP source;
- the current freeze payload derives its AP amount from allocation lines;
- customer shipping recharge no longer consumes approved apportionment;
- the proposed wrapper would change an existing canonical row;
- Mini-build 4 or shipment eligibility directly depends on shipper-AP queue status;
- more than one production database object must be changed to achieve the correction;
- any application or UI change appears necessary.

Any stop condition requires a new evidence-led scope decision and explicit approval.

---

## 14. Merge gate

Do not merge until:

- the migration and regression are reviewed against this addendum;
- the final diff contains only authorised files;
- no proof-record identifier is hard-coded;
- migration ordering and prerequisite guards are verified;
- CI and Vercel pass where applicable;
- Supabase regression passes;
- the approved-apportionment working flow is unchanged;
- the unapportioned AP flow passes;
- customer shipping remains blocked without approved apportionment;
- Mini-build 4, shipment, holds, funding, VAT and other accounting lanes retain their previous behaviour.

---

## 15. Acceptance rule

The permanent correction is accepted only when the platform proves exactly this:

```text
Accepted shipper invoice
→ may progress through the existing shipper-AP accounting route
→ without waiting for customer/order shipping apportionment

Goods-only customer invoice
→ may progress under its existing goods controls
→ without shipping apportionment

Customer invoice containing shipping
→ remains blocked until exact shipping apportionment is approved

Buttons, actions, permissions, Mini-build 4, shipment, holds,
funding, VAT, Sage payloads and all other workflows
→ remain unchanged
```

This addendum authorises no other change.
