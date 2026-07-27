# Shipper AP and Customer Shipping-Recharge Gate Separation Addendum v1.1

**Status:** Governing corrective implementation contract  
**Implementation status:** Contract clarified from live evidence — rebuilt files require review before execution  
**Scope:** Shipper supplier-AP readiness versus customer shipping-recharge readiness  
**Authority:** This file is the build authority for this correction. No implementation may exceed it without explicit approval.  
**v1.1 clarification:** Adds the verified live function ACL, authoritative effective-line source, queue persistence through freeze/revalidation, terminal posted-state suppression, and mandatory non-vacuous transactional regression proof.

---

## 1. Objective

Deliver one platform-wide correction:

> An accepted shipper invoice may progress through the existing shipper-AP accounting route before its cost has been apportioned across customer orders. A customer invoice may include shipping only after the exact shipping apportionment has been approved.

The correction must preserve every unrelated working route and must not introduce a parallel mechanism, new status vocabulary, record-specific exception or UI workaround.

The implementation must be rebuilt from:

1. this addendum;
2. the current live database definition and catalogue evidence;
3. the latest repository authorities on the target branch after refreshing from current `main`;
4. rollback-safe regression proof.

A previously attempted or disabled migration is not an implementation authority.

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

## 3. Verified live evidence

### 3.1 Verified business-route defect

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

### 3.2 Verified live canonical-function catalogue state

Immediately before the corrected build, the live canonical function was proven as:

```text
function: public.internal_ready_for_sage_queue_v2()
owner: postgres
language: sql
volatility: volatile (v)
parallel: unsafe (u)
security definer: true
search_path: public, pg_temp
```

Its exact return shape was proven as:

```text
TABLE(
  queue_row_id text,
  document_lane text,
  document_type text,
  source_table text,
  source_id uuid,
  order_id uuid,
  order_ref text,
  shipment_batch_id uuid,
  booking_ref text,
  counterparty_name text,
  amount_gbp numeric,
  currency_code text,
  invoice_type text,
  sage_status text,
  sage_invoice_id text,
  sage_posted_at timestamp with time zone,
  readiness_status text,
  blocker text,
  reference_text text,
  notes_text text,
  detail_href text,
  source_payload jsonb
)
```

Its exact live explicit ACL was proven as:

```text
{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
```

Its effective caller state was proven as:

```text
anon: false
authenticated: true
postgres: true
service_role: true
```

The live `public` schema default function ACL for owner `postgres` was proven as:

```text
{postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
```

This means a newly created function owned by `postgres` automatically receives `anon` EXECUTE unless the migration explicitly removes it.

The corrected migration must not infer or approximate these privileges. It must prove this exact starting state or stop.

### 3.3 Verified authoritative effective-line route

The current shipping AP/recharge route derives effective shipment membership through:

```text
public.shipper_shipment_batch_effective_lines_v1(uuid)
```

Any additive shipper-AP row that needs order or shipment-line context must use this existing authority. It must not reconstruct effective membership by joining shipment packages, tracking submissions or order rows directly.

### 3.4 Verified freeze, revalidation and posted-state dependency

The existing shipper-AP freeze function reads its source from:

```text
public.internal_ready_for_sage_queue_v2()
```

The existing snapshot revalidation function re-reads non-customer source rows, including `shipper_ap`, from the same canonical queue while the snapshot is not posted.

The Accounting Command Centre hides active frozen/not-posted snapshots from the live-ready work queue, but a terminally posted snapshot is represented through posted lifecycle history and no longer needs source revalidation.

Therefore:

- a qualifying additive shipper-AP row must remain resolvable after freeze and during not-posted snapshot/batch processing;
- active frozen/not-posted snapshot or batch state is not a reason to remove the source row from the canonical queue;
- once the exact shipper-AP source has a terminal posted snapshot or posted batch row, the additive route must not re-admit it as live ready work.

Existing grid, bulk-candidate, freeze, snapshot and posting controls remain responsible for duplicate selection and in-flight locking. The canonical queue must itself prevent terminally posted additive sources from reappearing as ready.

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
→ internal_revalidate_sage_posting_snapshots_v1(uuid[])
→ existing Sage purchase-invoice posting and confirmation
```

The canonical public queue remains:

```text
public.internal_ready_for_sage_queue_v2()
```

The source row must remain resolvable through freeze and not-posted revalidation. It must not be suppressed merely because an active frozen/not-posted snapshot or posting-batch row exists.

After terminal posting, the same additive source must not reappear as a live-ready shipper-AP row.

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
- a qualifying `shipper_invoice` source for the existing shipper-AP lane;
- linked through its existing shipper and shipment-batch relationships;
- supported by its existing source document and positive canonical amount;
- otherwise capable of passing the existing shipper-AP freeze controls;
- not yet terminally posted through the exact shipper-AP source identity;
- but not yet covered by an active approved customer/order shipping apportionment.

The canonical admission rule must not exclude such a row solely because it has entered an approved frozen/not-posted snapshot or active posting batch. The row is still required by snapshot revalidation.

The canonical admission rule must exclude an additive source with an exact terminal posted snapshot or posted posting-batch row so it cannot reappear as live-ready work.

No order, invoice, batch, shipping-document or test identifier may be embedded in the permanent implementation.

---

## 7. Mandatory implementation boundary

### 7.1 Approved build type

The approved implementation route is:

> One additive Supabase migration correcting only canonical shipper-AP queue admission.

No UI or application patch is authorised unless new evidence proves the existing application no longer consumes the canonical queue and freeze RPC as verified. If that occurs, stop before changing anything.

The implementation branch must be refreshed against current `main` before the migration is rebuilt. If the latest repository or live definition changes any verified route, stop and re-review the contract.

### 7.2 Preserve the canonical queue

The migration must use the repository's established preservation-and-composition pattern:

1. Assert the expected `internal_ready_for_sage_queue_v2()` function exists.
2. Assert its zero-argument signature and exact return shape.
3. Assert the exact verified owner, language, volatility, parallel mode, security mode and `search_path`.
4. Assert the exact verified live explicit ACL and effective caller state.
5. Preserve the exact current canonical implementation under one private deterministic function name.
6. Recreate `internal_ready_for_sage_queue_v2()` with the same name, signature, shape, execution properties, owner and ACL.
7. Return every row from the preserved queue unchanged.
8. Add only missing qualifying shipper-AP rows excluded solely because apportionment is outstanding.
9. Deduplicate by `document_lane`, `source_table`, and `source_id`.
10. Refuse migration if any live signature, property, ACL or route differs from the verified contract.

The migration must not reconstruct existing customer-sales, supplier-goods-AP, supplier-credit or working shipper-AP rows.

### 7.3 Exact ACL restoration

Because the verified default function ACL automatically grants `anon`, the migration must explicitly neutralise default grants before restoring the canonical caller set.

After replacement, all of the following must be true:

```text
owner = postgres
raw explicit proacl = {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
anon EXECUTE = false
authenticated EXECUTE = true
service_role EXECUTE = true
postgres EXECUTE = true
```

The migration must verify exact explicit ACL semantics, grantor state and effective access.

The private preserved function must not be executable by `PUBLIC`, `anon`, `authenticated`, or `service_role`. Owner access for `postgres` may remain.

### 7.4 Preserve working apportioned rows

Where the preserved canonical queue already returns a shipper-AP row, the wrapper must return that exact existing row. It must not replace, recalculate, mutate or duplicate it.

### 7.5 Newly qualifying shipper-AP rows

A newly composed shipper-AP row must reuse the existing queue vocabulary and field semantics, including:

- `document_lane = 'shipper_ap'`;
- `source_table = 'shipping_documents'`;
- the existing shipping-document source ID;
- the established purchase-invoice intent type;
- shipment-batch and booking identity;
- shipper/counterparty identity;
- shipping-document reference, date, currency and full accepted amount;
- existing detail route and source-payload shape expected by freeze/revalidation.

The AP amount must use:

```text
COALESCE(extracted_total_amount, total_amount)
```

Reference, date and currency must use the established OCR-first resolution already used by the shipping route.

The row must not be calculated from allocation lines, customer invoice values, order goods totals or a manually supplied amount.

Where order-reference context is populated, it must be derived through:

```text
public.shipper_shipment_batch_effective_lines_v1(shipment_batch_id)
```

It must not be reconstructed through direct package/tracking/order joins.

### 7.6 Queue persistence and terminal suppression

The additive source row must not be suppressed solely by:

- an active frozen/not-posted `sage_posting_snapshots` row;
- an active not-posted `sage_posting_batch_rows` row;
- a non-cancelled in-flight posting batch.

This is required so `internal_revalidate_sage_posting_snapshots_v1(uuid[])` can resolve the current source row after freeze.

The additive source row must be suppressed when the exact lane/source identity has either:

- an active snapshot with `sage_posting_status = 'posted'`; or
- a posting-batch row with `posting_status = 'posted'`.

The wrapper remains a source-truth resolver. It must not duplicate in-flight lock controls, but it must not re-admit terminally posted work.

### 7.7 Fail-closed admission

The additive route must not produce a ready shipper-AP row for a document that is:

- inactive;
- rejected, void, superseded or not accepted/current;
- not a qualifying `shipper_invoice` source;
- missing required shipper or shipment relationships;
- zero or negative;
- already represented by an existing canonical queue row;
- already terminally posted under the exact shipper-AP source identity.

The existing freeze function remains responsible for authenticated accounting-admin access, ready-row validation, shipper Sage contact, source file, freight ledger, AP tax mapping, snapshot creation and idempotency.

### 7.8 Existing functions that must not be weakened

Do not relax, replace or bypass:

```text
shipper_shipment_batch_effective_lines_v1(uuid)
internal_shipping_ap_recharge_readiness_preview_v1(uuid)
internal_customer_sales_release_sources_v1(uuid)
internal_customer_invoice_release_create_drafts_v1(uuid[])
internal_freeze_shipper_ap_sage_batch_v1(uuid[], text)
internal_revalidate_sage_posting_snapshots_v1(uuid[])
```

The canonical queue wrapper is the only authorised production-object correction unless new evidence triggers a stop condition.

---

## 8. Absolute scope freeze

The patch must make **no changes** to UI, actions, permissions, document intake, OCR, review, shipping allocation, customer invoice types, customer release-ledger calculations, quantities, amounts, rounding, VAT, order progression, tracking, receipt, shipment gates, Mini-build 4, holds, disputes, refunds, funding, banking, supplier-goods AP, supplier-credit, freeze payload construction, snapshot revalidation logic, Sage adapters, posted records, existing snapshots, posting batches or historical source rows.

Do not add a page, button, action, status, parallel queue, second resolver, record-specific exception, historical repair or backfill.

---

## 9. Mini-build 3 compatibility

`customer_sales_release_lines` remains the authority for customer-released value.

The patch must not read from or write to that ledger to decide shipper-AP readiness.

Shipper AP freezing or posting does not count as customer release.

Goods-only and repeated supplementary releases continue under their existing controls. Shipping value may enter customer release only through the existing approved-apportionment and exact remaining-delta route.

---

## 10. Mini-build 4 compatibility

The patch must not read from or write to Mini-build 4 membership to determine shipper-AP readiness.

The following remain unchanged and authoritative:

```text
customer_order_review_links
customer_review_cycle_memberships
customer_review_cycle_legacy_issues
internal_materialize_customer_review_cycles_v1(uuid, uuid)
shipper_tracking_review_state_v1(uuid, uuid)
shipper_shipment_batch_candidates_v1()
shipper_create_shipment_batch_v1(...)
```

Freezing or posting shipper AP must not create or change review cycles, memberships, deadlines, holds, shipment candidates or shipment batches.

---

## 11. Permitted repository changes

Only the following files are authorised:

1. This governing addendum.
2. One additive Supabase migration.
3. One transaction-based regression SQL file.
4. One governing-pack index entry only if required.

No other file may be changed without explicit approval. Historical deployed migrations must not be edited. No overlay migration or extra repair file is authorised.

---

## 12. Regression contract

Regression must be non-vacuous and transactional. It must not report `PASS` merely because no qualifying unapportioned document exists.

### 12.1 Canonical function and ACL preservation

Regression must prove exact signature, shape, owner, execution properties, ACL, effective caller access, private preserved-function restrictions, unchanged existing rows and no duplicate identities.

### 12.2 Existing approved-apportionment working flow

An existing approved-apportionment shipper-AP row must remain exactly unchanged and win over the additive route.

### 12.3 Controlled accepted but unapportioned flow

Regression must dynamically identify or transactionally establish one qualifying accepted/current shipper invoice with a positive canonical amount, valid relationships, required source evidence/contact/mappings, no approved apportionment and no hard-coded production ID.

It must prove exactly one additive row, authoritative effective-line order context, full OCR-first amount, unchanged allocations and no customer release.

### 12.4 Freeze, persistence, revalidation and idempotency proof

Regression must call the existing freeze route inside the rollback transaction and prove:

- one full-amount AP line;
- no allocation or customer invoice creation;
- source-row persistence after freeze;
- `ok_to_post` revalidation;
- repeated-freeze idempotency;
- one active economic liability snapshot;
- no live Sage call and no posted-state mutation.

### 12.5 Customer-invoice protection

Without approved apportionment, customer shipping remains zero or blocked while goods-only behaviour remains unchanged.

### 12.6 Mini-build 4 and protected-data proof

Review, membership, hold and shipment data must retain exact fingerprints through the transactional proof.

### 12.7 Other accounting and lifecycle rows

Customer sales, supplier-goods AP, supplier credit, existing shipper AP, already-frozen rows, posted rows and active-batch rows must retain their prior behaviour. No terminally posted additive shipper source may appear as live ready.

### 12.8 Full rollback

All proof snapshots and batches must roll back. Protected-data fingerprints must be unchanged before rollback.

---

## 13. Stop conditions

Stop before applying if:

- the branch is not current with `main`;
- live function properties or ACL differ;
- the effective-line route is missing or changed incompatibly;
- freeze no longer uses the canonical queue/full document amount;
- revalidation no longer reads not-posted shipper AP from the canonical queue;
- customer recharge no longer requires approved apportionment;
- existing rows would change;
- frozen/not-posted rows would disappear;
- terminally posted additive rows would reappear;
- more than one production object or any UI/app change is required;
- regression cannot prove a real rollback-safe freeze/revalidation cycle.

---

## 14. Merge gate

Do not merge until the final three-file diff is reviewed line by line, the branch is current with `main`, ACL and `anon = false` are proven, Supabase migration and non-vacuous regression pass, frozen rows remain revalidatable, posted rows do not reappear, customer shipping remains blocked without apportionment, and all unrelated routes remain unchanged.

---

## 15. Acceptance rule

```text
Accepted, not-posted shipper invoice
→ may enter the existing shipper-AP route without apportionment
→ remains resolvable while frozen/not posted for revalidation
→ does not reappear after terminal posting

Goods-only customer invoice
→ remains independent of shipping apportionment

Customer invoice containing shipping
→ remains blocked until exact apportionment is approved

Canonical queue permissions
→ postgres/authenticated/service_role only
→ anon remains unable to execute

All UI, actions, Mini-build 4, shipment, holds, funding, VAT,
freeze payload, revalidation and Sage posting routes
→ remain unchanged
```

This addendum authorises no other change.
