# Hybrid Physical Receipt Exact Review and Shipment Routing Correction Addendum v1

Status: governing corrective amendment

This addendum is additive to:

- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`;
- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1_1.md`.

Where this correction is more specific about exact clean, affected, customer-review and shipment routing, it controls. Historical deployed migrations remain immutable. Implementation must use additive migrations and must preserve existing public endpoint signatures unless this addendum expressly says otherwise.

## 1. Production evidence requiring correction

The live diagnostic for order `SEED-REPL-0C7952EE44`, tracking package `SEEDTRK-0C7952EE44`, proved that the exact receipt data and the shared quantity-position authority are internally correct:

- latest receipt `570e1b73-8306-4203-ac06-f7a84e2de53e` is finalised v2 with compatibility header `received_damaged`;
- Product B allocation `129f543d-5d0a-4696-8535-810ccd128d45` is stored as clean quantity `1` and affected quantity `0`;
- Product A allocation `5dbd95c5-c0d0-489d-973d-fab4c9083160` is stored as damaged quantity `1` and clean quantity `0`;
- Product B has `review_available_qty = 1`, but no customer-review membership was materialised;
- Product A has `remedy_assigned_qty = 1` through the approved existing-exception route;
- both quantity-position rows are valid and have no position blocker;
- no quantity has been shipped;
- the physical review is correctly `approved_to_existing_exception` and linked to dispute `d7b32314-603e-49bf-83d1-1a01e2e4d29f`.

The diagnostic also proved that the operational functions remain wired to pre-hybrid whole-package assumptions:

- `customer_review_cycle_candidates_v1(uuid)` still reads raw allocated quantity, does not use the exact quantity-position authority and still requires a whole-package `received_clean` header;
- `shipper_shipment_batch_candidates_v1()` still reads raw allocated quantity, uses the old line-hold filter only and requires a whole-package `received_clean` header;
- `shipper_create_shipment_batch_v1(...)` still reads raw allocated quantity, uses the old line-hold filter only and requires a whole-package `received_clean` header;
- `shipper_package_contents_preview_v1(uuid)` still exposes raw allocated quantity and does not read exact current routing.

The defect is therefore operational wiring, not corrupted receipt data, corrupted remedy data or an invalid quantity position.

## 2. Corrected governing outcome

One tracking package may contain exact quantities in different routes at the same time.

The required routing is:

```text
finalised exact physical receipt
        |
        +-- originally clean quantity
        |       -> existing customer-review cycle
        |       -> customer hold, if approved: diverted
        |       -> otherwise, after the existing review gate: shipment eligible
        |
        +-- affected quantity
                -> physical receipt review
                -> supervisor exact decision
                     |
                     +-- allow shipment / treat as clean
                     |       -> existing customer-review cycle
                     |       -> customer hold, if approved: diverted
                     |       -> otherwise, after the existing review gate: shipment eligible
                     |
                     +-- refund
                     |       -> diverted to existing refund/dispute route
                     |
                     +-- replacement
                     |       -> diverted to existing replacement/dispute route
                     |
                     +-- hold / investigate
                             -> diverted pending investigation
```

Originally clean quantity must continue independently. It must not wait for resolution of a different affected quantity in the same package.

Only exact quantity that has completed the applicable existing customer-review gate, is not actively held and has not already been shipped may enter shipment membership.

## 3. Physical fact and routing decision are separate

The immutable shipper receipt remains the physical audit record. A supervisor decision must not rewrite or delete the original clean, damaged, missing, wrong or held disposition row.

A supervisor may, however, authorise an affected quantity to proceed operationally as clean for customer review and shipment. This is a downstream routing decision, not a rewrite of the shipper's historical evidence.

The platform must therefore retain both facts:

```text
reported physical disposition
supervisor-approved downstream route
```

No receipt correction, second receipt, duplicate supplier invoice line or duplicate tracking allocation is required merely because the supervisor allows shipment.

## 4. Exact supervisor decision semantics

### 4.1 Allow shipment / treat as clean

The normal supervisor UI must provide an explicit action labelled substantially:

`Allow shipment — treat as clean`

To minimise schema and authority changes, this action must reuse the existing exact `no_action` remedy-allocation path and the existing `close_no_action` supervisor decision internally:

- every affected proposal row remains explicitly quantity-decided;
- `approved_remedy_type = 'no_action'`;
- `approved_remedy_qty` is a positive whole unit and may not exceed the proposed quantity or source disposition quantity;
- allocation status becomes `closed_no_action`;
- review status becomes `closed_no_action`;
- the exact approved no-action quantity becomes supervisor-released clean routing quantity;
- the original disposition row remains unchanged.

The ambiguous bare `reject` action must not be the normal shipment-release action because the current reject path accepts no exact allocation payload and therefore cannot prove which quantity was released. It may remain for backward compatibility, but it must be removed from the normal supervisor decision UI or clearly separated from the exact allow-shipment action. It must not create shipment eligibility.

### 4.2 Refund and replacement

Approved refund and replacement quantities remain diverted and continue through the existing linked dispute, retailer conversation, return/collection, refund or replacement-child routes.

They do not become customer-review or shipment candidates.

### 4.3 Hold / investigate

Approved hold/investigate quantity remains diverted while the investigation is open. No affected quantity may enter customer review or shipment merely because a proposal exists.

### 4.4 Return for information

Returned-for-information quantity remains diverted. The same review is resubmitted through the existing importer proposal path.

## 5. Exact routing quantity authority

`internal_tracking_allocation_fulfilment_position_v1(uuid,uuid,uuid)` remains the single private exact quantity authority used for cumulative review, hold, shipment, release and remedy controls.

Its public signature and returned columns must remain unchanged.

Its internal calculation must be extended with exact supervisor release quantity:

```text
supervisor_released_clean_qty
  = sum approved_remedy_qty
    where approved_remedy_type = 'no_action'
      and allocation status = 'closed_no_action'
```

The exact row must belong to the same:

- physical receipt review;
- receipt-line disposition;
- tracking-line allocation;
- supplier invoice line.

The internal routing bases become:

```text
routing_clean_qty
  = physical_clean_qty + supervisor_released_clean_qty

routing_affected_qty
  = physical_exception_qty - supervisor_released_clean_qty
```

Required fail-closed controls:

- supervisor-released clean quantity may not be negative;
- it may not exceed the exact physical exception quantity;
- review, active hold, shipment and customer release may not exceed routing clean quantity;
- refund, replacement and investigation allocations remain within physical exception quantity;
- the raw physical balance remains `physical clean + physical exception = allocated quantity`;
- existing no-double-review, no-double-shipment and no-double-release controls remain active.

The returned `physical_clean_qty` and `physical_exception_qty` continue to describe the immutable receipt facts. Only `review_available_qty`, `shipment_available_qty` and the internal cumulative validations use the routing-clean basis.

## 6. Existing customer-review lane

### 6.1 Candidate authority

Keep the existing function name and return contract:

`customer_review_cycle_candidates_v1(uuid)`

Replace only its internal eligibility and quantity source.

For v2 exact receipts it must use the scoped exact quantity position and emit a candidate only when:

```text
position_valid_yn = true
review_available_qty > 0
```

Its exact candidate quantity must be:

```text
review_qty = review_available_qty
```

It must not require the package compatibility header to equal `received_clean`, and it must not use raw `qty_allocated` as the review quantity.

Existing supplier-invoice approval, eligible-line, value-apportionment, tenant and other customer-review prerequisites remain unchanged.

The existing value fields must be apportioned to the exact review quantity using the existing allocation values and exact allocation quantity. No full-line value may be attached to a partial review quantity.

### 6.2 Review-cycle materialisation

The existing `internal_materialize_customer_review_cycles_v1(uuid,uuid)` remains authoritative.

Materialisation must be invoked after:

1. successful finalisation of a v2 physical receipt containing any originally clean quantity; and
2. a supervisor `Allow shipment — treat as clean` decision that creates newly review-available quantity.

No browser-side materialisation and no new customer-review endpoint are permitted.

Originally clean quantity uses the finalised receipt time as its review-cycle anchor.

Supervisor-released clean quantity must enter the existing review-cycle system when the supervisor decision is recorded. If there is an active compatible review link for the order, the exact new membership is added to that link. If there is no active link, the existing materialiser creates the normal review cycle using the release decision time as the eligibility anchor for only the newly released quantity.

This remains the existing customer-review system; it is not a separate physical-receipt customer review.

### 6.3 Customer hold result

If the customer selects an exact quantity to hold and the existing supervisor hold approval is granted:

- only the approved hold quantity is diverted;
- remaining reviewed clean quantity continues toward shipment;
- existing hold membership, hold status and conflict controls remain authoritative.

## 7. Shipment candidate authority

Keep the existing function name and return contract:

`shipper_shipment_batch_candidates_v1()`

Replace only its internal eligibility and quantity/value aggregation.

A package is a shipment candidate when it contains at least one exact allocation row satisfying:

```text
position_valid_yn = true
shipment_available_qty > 0
```

It must not require the whole package compatibility header to equal `received_clean`.

Candidate totals must be:

```text
allocated_qty
  = sum shipment_available_qty

allocated_net_value_gbp
  = sum exact net value apportioned to shipment_available_qty
```

The existing shipper identity, importer grouping, active review state, existing active batch membership and ordering controls remain unchanged.

A package with one diverted unit and one shipment-ready unit appears once as a candidate with quantity `1`, not quantity `2`.

## 8. Shipment creation authority

Keep the existing RPC signature:

`shipper_create_shipment_batch_v1(uuid,uuid[],text,timestamptz,timestamptz,integer,text,text,text)`

Within the existing order and tracking locks, the function must re-read the exact quantity position for every selected package.

It may create a package membership only when at least one allocation has:

```text
position_valid_yn = true
shipment_available_qty > 0
```

Each immutable line membership must snapshot:

```text
qty_in_shipment = shipment_available_qty
```

The corresponding net value must be apportioned to the exact shipment quantity.

It must never copy full `order_tracking_line_allocations.qty_allocated` for a partially eligible allocation or mixed package.

If exact position changes between candidate display and batch creation, creation must use the re-read position and fail closed if no quantity remains.

Existing batch, package, line-membership, evidence, BOL, freight, AP/recharge, voiding and downstream customer-sales authorities remain unchanged.

## 9. Shipper routing reads and UI

### 9.1 Package routing read

`shipper_package_contents_preview_v1(uuid)` currently exposes original allocated quantity and must no longer be treated as the current routing authority.

Implementation may either replace its body while preserving its signature or add one narrow authenticated routing read and update only the package-contents page.

The routing read must expose, per exact allocation:

- original allocated quantity;
- reported clean quantity;
- reported affected quantity;
- supervisor-released clean quantity;
- awaiting customer-review quantity;
- shipment-eligible quantity;
- diverted quantity;
- item description and existing non-commercial identifiers.

No commercial values, VAT, margin, funding, DVA/card or Sage information may be exposed to the shipper.

### 9.2 Required page states

The package-contents page must not classify all non-shipment-ready clean quantity as diverted.

It must distinguish at least:

```text
Shipment eligible
Awaiting customer review
Diverted from shipment
```

For the controlled live case before customer review is materialised, the truthful display is:

```text
Shipment eligible: 0
Awaiting customer review: 1
Diverted from shipment: 1
```

After Product B completes customer review with no approved hold:

```text
Shipment eligible: 1
Awaiting customer review: 0
Diverted from shipment: 1
```

### 9.3 Terminal exact receipt display

When a v2 receipt is final and correction is not permitted, the page must show the immutable recorded snapshot rather than rendering a new blank entry form whose client defaults make every line appear clean.

For the controlled case it must show:

```text
Product A — damaged 1 — Damaged - ripped
Product B — clean 1
```

The existing correction authority and terminal-state rules remain unchanged.

## 10. Controlled recovery for the observed order

No receipt or physical-review row should be rewritten for the controlled live order.

After the corrected candidate authority and materialisation trigger are installed, run the existing materialiser for only the affected order:

```sql
SELECT public.internal_materialize_customer_review_cycles_v1(
  '8c882f9d-aadc-4a6a-b50c-d013d1abffd7'::uuid,
  NULL::uuid
);
```

Expected result:

- one exact customer-review membership for Product B quantity `1`;
- no customer-review membership for Product A;
- Product A remains linked to the approved replacement dispute;
- no shipment membership is created by recovery;
- after the existing customer-review gate, Product B becomes shipment candidate quantity `1`.

The recovery must be run only after the corrective migration is installed and verified.

## 11. Frozen implementation scope

The corrective build may change only:

1. the private exact quantity-position function body;
2. `customer_review_cycle_candidates_v1(uuid)`;
3. the v2 receipt finalisation path only to invoke existing review materialisation;
4. the supervisor close-no-action path only to invoke existing review materialisation after an exact allow-shipment decision;
5. `shipper_shipment_batch_candidates_v1()`;
6. `shipper_create_shipment_batch_v1(...)`;
7. one narrow shipper routing read;
8. the shipper package-contents page;
9. the terminal exact-receipt display;
10. corrective source and rollback-only SQL regressions.

The build must not redesign or replace:

- receipt tables or immutable disposition history;
- importer proposal flow;
- refund or replacement dispute creation;
- retailer conversation;
- return/collection tasks;
- replacement-child creation;
- customer hold tables or decision authority;
- shipment batch schema;
- customer-sales release schema;
- supplier AP, shipping AP, VAT, Sage, funding, payout, credit or accounting authorities;
- tenant or role permissions.

## 12. Required regression proof

One rollback-only behavioral regression must prove all of the following using exact quantities:

1. mixed receipt: clean `1`, damaged `1`;
2. originally clean quantity produces customer-review candidate `1` despite package header `received_damaged`;
3. affected quantity does not enter customer review before supervisor decision;
4. approved replacement keeps affected quantity diverted;
5. approved refund keeps affected quantity diverted;
6. approved investigation keeps affected quantity diverted;
7. `Allow shipment — treat as clean` on an exact no-action allocation releases only that approved quantity into customer review;
8. customer-approved hold diverts only held quantity and leaves remaining reviewed clean quantity available;
9. shipment candidate totals use exact `shipment_available_qty`;
10. shipment creation snapshots exact quantity and exact apportioned value;
11. full package quantity cannot leak into shipment;
12. repeated candidate, materialisation and shipment calls are idempotent or fail closed under existing rules;
13. original disposition rows remain unchanged;
14. refund, replacement, hold, customer-sales, AP, VAT and Sage protected authority fingerprints remain unchanged;
15. all test writes roll back.

A source regression must additionally reject:

- package-header `received_clean` as the v2 exact review or shipment authority;
- raw `qty_allocated` as the quantity inserted into a partial shipment membership;
- browser-side clean/diverted arithmetic as an authority;
- use of bare quantity-free `reject` as shipment release;
- mutation of finalised receipt disposition rows.

## 13. Acceptance order

Acceptance must run in this order:

1. confirm current live definitions and fingerprints of every function to be replaced;
2. apply the additive corrective migration in a transactionally controlled environment;
3. run the rollback-only exact-routing regression;
4. run existing customer-review, shipment, hold and hybrid receipt regressions;
5. deploy the narrow UI changes;
6. verify the controlled live order before recovery;
7. run the one-order materialisation recovery;
8. confirm Product B membership quantity `1` and Product A exclusion;
9. complete customer review and verify shipment candidate quantity `1`;
10. create a controlled shipment batch and verify exactly one Product B line membership quantity `1`;
11. verify Product A remains diverted and linked to its existing dispute;
12. perform final diff, grant, fingerprint and migration-history review before merge.

No readiness claim is permitted from source inspection alone. Database behavior must be proved.