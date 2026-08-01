# Hybrid Physical Receipt Build 2 Impact Map v1

Status: implementation boundary for Build 2

Governing authority:

`docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`

Build baseline:

`main` at `f5bcbfd1fca5855826905bebdd6ea4eb4891a6f4`

Branch:

`agent/hybrid-receipt-build-2-v1`

## 1. Purpose

Build 2 adds the atomic v2 receipt write authority and the controlled importer/supervisor physical-triage bridge over the foundation merged by PR #212.

It does not activate the final production shipper UI, replace existing review/shipment/customer-sales functions, complete a retailer refund, create a replacement child, alter parent closure, or replace reconciliation.

The Build 2 outcome is:

```text
shipper v2 receipt facts can be recorded atomically;
affected quantity creates one physical receipt review header;
importer proposals reserve exact affected quantity;
supervisor initial decisions approve, change, return, reject or close the route;
approved retailer action links to the existing dispute route;
no physical triage record independently claims retailer or remedy completion.
```

## 2. Existing authorities reused

Build 2 must reuse rather than duplicate:

- `shipper_package_receipts` as the receipt header and history family;
- `shipper_package_receipt_line_dispositions` for exact clean/affected quantity;
- `shipper_package_receipt_evidence` for multiple immutable evidence references;
- `physical_receipt_reviews` for importer proposal and supervisor initial route approval;
- `physical_exception_remedy_allocations` for proposed and approved affected-quantity splits;
- `operator_importers` and `operators` for importer access;
- `staff` and `is_active_staff()` for supervisor authority;
- `disputes` and `dispute_lines` for the existing retailer-facing exception route;
- `/importer/exceptions/[dispute_id]` and `/internal/exceptions/[dispute_id]` after linkage.

Build 2 must not create:

- another receipt header;
- another customer review timer or membership;
- another shipment route;
- another retailer conversation;
- another refund process;
- another replacement operations page;
- another customer invoice or Sage route.

## 3. Ordered database work

### 3.1 Atomic receipt RPC

Add:

`shipper_record_package_receipt_v2(uuid,uuid,jsonb,jsonb,uuid,text)`

The exact final signature may be refined only if repository/live type inspection proves a conflict. Its governed meaning is:

- tracking submission identity;
- idempotent receipt submission identity;
- complete allocation-disposition payload;
- evidence metadata payload using the private v2 object prefix `shipper-receipts/<shipper_id>/<tracking_submission_id>/`;
- optional immediate predecessor for correction;
- required correction reason when correcting.

The RPC must:

1. authenticate one active shipper user;
2. lock the package/tracking identity and exact positive allocations;
3. verify the shipper owns the package and identities agree;
4. canonicalise and fingerprint the complete payload;
5. return the existing receipt on an identical retry;
6. reject a changed retry using the same submission identity;
7. insert one pending v2 header;
8. insert exactly aggregated positive disposition rows;
9. insert evidence metadata without publicising storage objects;
10. require every positive allocation to be present and exactly balanced;
11. require factual notes and evidence for affected quantity;
12. set the compatibility header status from the exact snapshot;
13. finalise the receipt inside the same transaction;
14. create one `physical_receipt_reviews` row only when affected quantity exists;
15. leave an all-clean receipt without a physical review;
16. supersede an older open physical review only through the existing correction controls;
17. return receipt and review identities.

No pending v2 receipt may commit.

### 3.2 Importer proposal RPC

Add one transaction authority for submitting or replacing the active importer proposal while the review is in an importer-owned state.

Required behaviour:

- active operator with unrevoked access to the review importer;
- row lock on review, affected dispositions and existing proposal rows;
- status limited to `awaiting_importer_proposal` or `returned_for_information`;
- proposal payload contains only source disposition, remedy type, exact proposed quantity and importer factual note where required;
- no supervisor approval facts, dispute linkage, supplier claim, customer-commercial amount, supplier-cost mode or replacement-child facts may be supplied by the importer;
- active proposed quantity per affected disposition cannot exceed the exact affected quantity;
- split proposals are allowed;
- prior non-terminal proposal rows use only an existing audited cancellation or reroute transition; no invented `superseded` remedy status is allowed;
- review advances to `awaiting_supervisor_review` atomically.

### 3.3 Supervisor initial decision RPC

Add one transaction authority for the initial route decision.

Required outcomes:

- return for information;
- reject;
- close no action with reason;
- approve hold/investigate;
- approve no action with reason;
- approve refund/replacement quantities into the existing exception route.

Required controls:

- active staff only;
- review and remedy rows locked;
- input applies only while `awaiting_supervisor_review`;
- approved quantities may be reduced, split or rerouted but cannot exceed source affected quantity;
- every approved route has positive exact quantity;
- replacement approval requires an explicit supplier-cost mode;
- no retailer refund receipt or replacement completion may be recorded here;
- decision note is mandatory;
- final approved quantity is stored separately from importer proposal;
- refund/replacement approval creates or links the governed existing `disputes`/`dispute_lines` records using verified live identities;
- review advances to `approved_to_existing_exception` only when `linked_dispute_id` exists;
- remedy rows advance no further than `linked_to_exception` in Build 2.

## 4. Application work allowed in Build 2

Build 2 may add server actions and read pages for:

- importer `Physical Receipt Exceptions` queue/detail;
- supervisor/internal `Physical Receipt Reviews` queue/detail;
- calling importer proposal and supervisor initial-decision RPCs;
- redirecting approved linked cases to the existing exception pages.

Build 2 must preserve the current shipper `recordPackageReceiptAction` and normal v1 UI route. The production shipper page cuts over to v2 only in the coordinated application build required by the governing addendum.

Evidence upload helpers may be prepared for multiple private storage object paths, but no storage access policy may be weakened and no public URL may become the new authority.

## 5. Explicit Build 2 exclusions

Build 2 does not:

- modify customer-review candidate or materialisation functions;
- modify shipment candidate, creation, membership or effective-line functions;
- modify customer-sales release functions;
- create a replacement child;
- complete, cancel or reroute a replacement child;
- complete supplier refund or customer settlement;
- alter supplier AP, shipping AP, VAT or Sage posting;
- replace `order_has_open_child_exceptions`;
- replace `order_reconciliation_vw`;
- activate the v2 shipper UI;
- add a feature flag, pilot account or staged business rollout.

## 6. Required regression gates

Build 2 regression must prove:

1. v1 receipt function fingerprint and execute contract remain unchanged;
2. identical v2 retries return the same receipt and create no duplicate facts;
3. changed retries fail closed;
4. all-clean exact receipt creates no physical review;
5. mixed clean/affected receipt creates exactly one review;
6. every allocation balances exactly;
7. affected quantity requires note and evidence;
8. evidence cannot cross receipts or shipper users;
9. importer access is tenant scoped;
10. importer proposal cannot write approval, dispute, supplier, customer-commercial or replacement facts;
11. proposal splits cannot exceed affected quantity;
12. supervisor decision is staff-only and note-required;
13. approved quantities cannot exceed affected quantity;
14. replacement approval requires explicit supplier-cost mode;
15. approval cannot mark retailer outcome or remedy completion;
16. linked retailer cases use existing disputes and dispute lines;
17. terminal review/remedy provenance remains immutable;
18. corrections supersede the old review without rewriting old receipt facts;
19. no Build 3, Build 4 or unrelated application file changes enter the branch;
20. all new migrations are additive and ordered after the merged foundation.

## 7. Stop conditions

Implementation must stop rather than guess when:

- the live `disputes` or `dispute_lines` shape differs from the reviewed repository authority;
- no existing function safely creates the required retailer exception identity;
- current role matrices do not allow the proposed caller to contact the retailer;
- storage metadata cannot be written without weakening bucket access;
- a required protected function/view fingerprint has changed;
- exact source allocation, supplier line or importer identity cannot be proven;
- an existing open retailer exception makes automatic linkage ambiguous.

Any such conflict requires an explicit additive compatibility migration or a revised governing decision before implementation continues.