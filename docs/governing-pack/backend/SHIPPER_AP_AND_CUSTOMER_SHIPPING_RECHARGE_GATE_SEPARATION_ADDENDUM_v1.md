# Shipper AP and Customer Shipping-Recharge Gate Separation Addendum v1.1

**Status:** Governing corrective implementation contract  
**Implementation status:** Contract clarified from live evidence — rebuilt files require review before execution  
**Scope:** Shipper supplier-AP readiness versus customer shipping-recharge readiness  
**Authority:** This file is the build authority for this correction. No implementation may exceed it without explicit approval.  
**v1.1 clarification:** Adds the verified live function ACL, authoritative effective-line source, queue persistence through freeze/revalidation, and mandatory non-vacuous transactional regression proof.

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

### 3.4 Verified freeze and revalidation dependency

The existing shipper-AP freeze function reads its source from:

```text
public.internal_ready_for_sage_queue_v2()
```

The existing snapshot revalidation function also re-reads non-customer source rows, including `shipper_ap`, from:

```text
public.internal_ready_for_sage_queue_v2()
```

Therefore a qualifying additive shipper-AP row must remain resolvable after freeze and while an active posting batch or approved frozen snapshot exists. Snapshot/batch locking is not a reason to remove the source row from the canonical queue.

Existing grid, bulk-candidate, freeze, snapshot and posting controls remain responsible for preventing duplicate selection, freezing or posting.

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

The source row must remain resolvable through freeze and revalidation. The queue wrapper must not suppress an otherwise qualifying additive shipper-AP row solely because an active snapshot or posting-batch row exists.

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
- but not yet covered by an active approved customer/order shipping apportionment.

The canonical admission rule must not exclude such a row solely because it has subsequently entered an approved frozen snapshot or active posting batch. The row is still required by snapshot revalidation.

Existing downstream controls remain responsible for already-frozen, in-batch and posted-state behaviour.

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
6. Recreate `internal_ready_for_sage_queue_v2()` with the same:
   - function name;
   - signature;
   - return columns, types and order;
   - language;
   - volatility;
   - parallel mode;
   - `SECURITY DEFINER` property;
   - `search_path`;
   - owner;
   - explicit ACL and effective caller compatibility.
7. Return every row from the preserved queue unchanged.
8. Add only missing qualifying shipper-AP rows excluded solely because apportionment is outstanding.
9. Deduplicate by the established exact identity:
   - `document_lane`;
   - `source_table`;
   - `source_id`.
10. Refuse migration if any live signature, property, ACL or route differs from the verified contract.

The migration must not reconstruct existing customer-sales, supplier-goods-AP, supplier-credit or working shipper-AP rows.

### 7.3 Exact ACL restoration

Because the verified default function ACL automatically grants `anon`, creating the replacement canonical function is not enough.

The migration must explicitly neutralise default grants on the replacement function before restoring the canonical caller set.

After replacement, all of the following must be true:

```text
owner = postgres
raw explicit proacl = {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
anon EXECUTE = false
authenticated EXECUTE = true
service_role EXECUTE = true
postgres EXECUTE = true
```

The migration must verify both:

- the exact explicit `proacl` semantics, including grantor and grant-option state;
- effective EXECUTE access for `anon`, `authenticated`, `service_role` and `postgres`.

The private preserved function must not be executable by:

```text
PUBLIC
anon
authenticated
service_role
```

Owner access for `postgres` may remain.

A grant comparison that ignores automatic default privileges, owner privileges, grantors or effective access is not sufficient.

### 7.4 Preserve working apportioned rows

Where the preserved canonical queue already returns a shipper-AP row, the wrapper must return that exact existing row.

It must not:

- replace it;
- recalculate it;
- change its payload fields;
- duplicate it through the additive route.

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

The AP amount must be the full accepted shipping-document amount, using the established OCR-first resolution:

```text
COALESCE(extracted_total_amount, total_amount)
```

Reference, date and currency must use the established OCR-first resolution already used by the shipping route.

The row must not be calculated from:

- shipping allocation lines;
- customer invoice values;
- order goods totals;
- a manually supplied amount.

Where order-reference context is populated, it must be derived through:

```text
public.shipper_shipment_batch_effective_lines_v1(shipment_batch_id)
```

It must not be reconstructed through direct package/tracking/order joins.

### 7.6 Queue persistence through freeze and revalidation

The additive source row must not be suppressed solely by:

- an active `sage_posting_snapshots` row;
- an approved frozen snapshot;
- an active `sage_posting_batch_rows` row;
- a non-cancelled posting batch.

The reason is mandatory revalidation compatibility: `internal_revalidate_sage_posting_snapshots_v1(uuid[])` must be able to resolve the current shipper-AP source row after freeze.

The wrapper must remain a source-truth resolver. It must not duplicate the existing grid/bulk/freeze/posting lock controls.

### 7.7 Fail-closed admission

The additive route must not produce a ready shipper-AP row for a document that is:

- inactive;
- rejected, void, superseded or not accepted/current;
- not a qualifying `shipper_invoice` source;
- missing required shipper or shipment relationships;
- zero or negative where the current AP lane requires a positive purchase invoice;
- already represented by an existing canonical queue row.

The existing freeze function remains responsible for its current downstream controls, including:

- authenticated accounting-admin access;
- a ready canonical queue row;
- shipper Sage supplier contact;
- shipping-document source file;
- freight ledger mapping;
- shipper-AP tax mapping;
- frozen-snapshot and idempotency protection.

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
- snapshot revalidation logic;
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

The disabled migration and existing regression may be salvaged only by replacing their contents in the same authorised paths. No overlay migration or extra repair file is authorised.

---

## 12. Regression contract

The implementation is incomplete until regression proves all of the following.

The regression must be non-vacuous. It must not report `PASS` merely because no live unapportioned document exists.

### 12.1 Canonical function and ACL preservation

- `internal_ready_for_sage_queue_v2()` retains its exact signature and return shape.
- Owner, language, volatility, parallel mode, security mode and `search_path` match the verified live state.
- Exact explicit ACL semantics match the verified live state.
- Effective EXECUTE access is exactly:
  - `anon = false`;
  - `authenticated = true`;
  - `service_role = true`;
  - `postgres = true`.
- The private preserved function is not executable by application roles.
- Every existing preserved queue row is unchanged.
- No existing row is duplicated.

### 12.2 Existing approved-apportionment working flow

For an existing accepted and approved-apportioned shipping document:

- exactly one shipper-AP queue row remains;
- amount, currency, reference, shipment batch, booking ref and counterparty remain unchanged;
- the preserved row wins over the additive route;
- the existing frozen payload continues to use the full shipping-document amount;
- no allocation, customer invoice or release-ledger row is created.

### 12.3 Controlled accepted but unapportioned flow

Inside one transaction, regression must establish or identify a controlled accepted/current shipper document with:

- a positive canonical shipping-document amount;
- valid shipper and shipment-batch relationships;
- source evidence and the existing mappings/contact needed for freeze proof;
- no active approved shipping apportionment;
- no hard-coded production record ID.

The regression must then prove:

- exactly one additive shipper-AP queue row appears;
- it uses the full OCR-first accepted shipping-document amount;
- order-reference context, where present, comes from the authoritative effective-line route;
- no shipping allocation is created, changed or approved;
- no customer invoice or customer-sales release row is created;
- repeated queue reads do not duplicate it.

A zero qualifying-row count is a regression failure unless the regression creates its own controlled qualifying fixture.

### 12.4 Freeze, persistence, revalidation and idempotency proof

Using the controlled unapportioned source inside the same rollback transaction, regression must call the existing freeze route and prove:

- the row freezes through `internal_freeze_shipper_ap_sage_batch_v1(uuid[], text)` when all existing downstream controls pass;
- the frozen payload uses the exact queue/document amount as one full shipper-AP line;
- no allocation or customer invoice is created;
- the canonical additive row remains resolvable after freeze;
- `internal_revalidate_sage_posting_snapshots_v1(uuid[])` returns `ok_to_post` for that snapshot;
- repeating freeze follows the existing idempotency behaviour and does not create a second active economic liability;
- active snapshot/batch state does not remove the source row required by revalidation.

### 12.5 Customer-invoice protection

Without approved shipping apportionment:

- goods-only customer invoices retain their current behaviour;
- no customer invoice may include the unapportioned shipping amount;
- no shipping-only supplementary may be created;
- the existing customer release-source and draft functions retain their existing shipping blocker or zero-shipping result.

After approved apportionment:

- only the exact approved remaining shipping delta becomes eligible;
- all cumulative quantity, value and duplicate-release controls remain effective.

### 12.6 Mini-build 4 protection

Before and after the migration and transactional freeze proof:

- review-link IDs remain unchanged;
- `expires_at` remains unchanged;
- membership IDs, counts, statuses and fingerprints remain unchanged;
- legacy review issues remain unchanged;
- hold results remain unchanged;
- shipment-candidate results remain unchanged;
- direct shipment creation retains the same review and hold enforcement.

### 12.7 Other accounting lanes

Representative results remain unchanged for:

- customer sales;
- supplier-goods AP;
- supplier credit;
- existing apportioned shipper AP;
- already-frozen shipper AP;
- posted rows;
- sources represented in active posting batches.

### 12.8 No live Sage call and full rollback

Regression must not call Sage or mark any source posted.

All controlled proof rows, snapshots and batches created for regression must roll back.

Regression must prove protected table contents or fingerprints are unchanged before rollback, not merely compare counts.

---

## 13. Stop conditions

Stop before implementing or applying the migration if any of the following is found:

- the implementation branch has not been refreshed against current `main`;
- the live canonical queue signature, return shape, owner, execution properties or ACL differ from the verified state;
- the live default function ACL differs from the verified state;
- a later deployed definition no longer uses `internal_ready_for_sage_queue_v2()` as the shipper-AP source;
- the authoritative `shipper_shipment_batch_effective_lines_v1(uuid)` route is missing or has changed incompatibly;
- the current freeze payload derives its AP amount from allocation lines;
- snapshot revalidation no longer re-reads shipper AP through the canonical queue;
- customer shipping recharge no longer consumes approved apportionment;
- the proposed wrapper would change an existing canonical row;
- the proposed wrapper removes a qualifying source row solely because it is frozen or in an active batch;
- Mini-build 4 or shipment eligibility directly depends on shipper-AP queue status;
- more than one production database object must be changed to achieve the correction;
- any application or UI change appears necessary;
- the regression cannot prove a real controlled unapportioned freeze and revalidation cycle transactionally.

Any stop condition requires a new evidence-led scope decision and explicit approval.

---

## 14. Merge gate

Do not merge until:

- the migration and regression are reviewed line by line against this addendum;
- the final diff contains only authorised files;
- the branch has been refreshed against current `main`;
- no proof-record identifier is hard-coded;
- migration ordering and prerequisite guards are verified;
- the exact live ACL is preserved, including `anon = false`;
- CI and Vercel pass where applicable;
- Supabase regression passes with a non-zero controlled unapportioned proof;
- the approved-apportionment working flow is unchanged;
- the unapportioned AP freeze and revalidation flow passes;
- the source row remains resolvable after freeze;
- customer shipping remains blocked without approved apportionment;
- Mini-build 4, shipment, holds, funding, VAT and other accounting lanes retain their previous behaviour.

---

## 15. Acceptance rule

The permanent correction is accepted only when the platform proves exactly this:

```text
Accepted shipper invoice
→ may progress through the existing shipper-AP accounting route
→ without waiting for customer/order shipping apportionment
→ remains resolvable after freeze for canonical snapshot revalidation

Goods-only customer invoice
→ may progress under its existing goods controls
→ without shipping apportionment

Customer invoice containing shipping
→ remains blocked until exact shipping apportionment is approved

Canonical queue permissions
→ remain postgres/authenticated/service_role only
→ anon remains unable to execute

Buttons, actions, permissions, Mini-build 4, shipment, holds,
funding, VAT, Sage payloads and all other workflows
→ remain unchanged
```

This addendum authorises no other change.
