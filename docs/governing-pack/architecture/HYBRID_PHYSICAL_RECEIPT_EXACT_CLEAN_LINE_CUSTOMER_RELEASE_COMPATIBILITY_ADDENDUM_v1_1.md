# Hybrid Physical Receipt Exact Clean-Line Customer Release Compatibility Addendum v1.1

**Status:** governing corrective amendment

**Effective date:** 6 August 2026

**Supersedes:** section 4, section 9.2, Mini Build 3 guard wording, non-scope guard wording and rollback wording in `HYBRID_PHYSICAL_RECEIPT_EXACT_CLEAN_LINE_CUSTOMER_RELEASE_COMPATIBILITY_ADDENDUM_v1.md` where this amendment is more specific.

## 1. Authenticated acceptance finding

The v1 migration and rollback-only regression passed. Authenticated staff queue and preview then proved:

```text
J040826 is ready
one line only
quantity 1
goods £10
shipping £0
supplementary route
exact release-ledger payload identity
```

Attempting draft creation failed with:

```text
Package is not currently received clean
```

Source inspection confirms this exception is raised by `public.customer_sales_release_guard_v1()` when the draft creator inserts the durable `customer_sales_release_lines` row.

The draft creator is not defective and must remain unchanged. The trigger guard is a fourth independent package-clean gate that was not included in the original three-object boundary.

## 2. Corrected smallest patch boundary

The complete platform compatibility correction is four database objects:

1. private proof helper `internal_customer_sales_release_exact_clean_proof_v1(uuid,uuid)`;
2. resolver receipt predicate in `internal_customer_sales_release_sources_v1(uuid)`;
3. queue batch-admission predicate in `internal_customer_invoice_release_queue_v1()`;
4. release-ledger insert receipt predicate in `customer_sales_release_guard_v1()`.

Because the first migration has already been installed for acceptance testing, the fourth change must be delivered as a separate additive follow-up migration. The installed migration must not be rewritten.

## 3. Release guard compatibility rule

The guard's existing fully clean route remains unchanged.

Only this predicate may change:

```sql
IF v_receipt IS DISTINCT FROM 'received_clean'
   AND (
     NEW.source_shipment_batch_id IS NULL
     OR NOT public.internal_customer_sales_release_exact_clean_proof_v1(
       NEW.source_shipment_batch_id,
       NEW.tracking_line_allocation_id
     )
   )
THEN
  RAISE EXCEPTION 'Package is not currently received clean';
END IF;
```

This permits a mixed-package ledger insert only when:

- the row carries an exact source shipment batch;
- the exact allocation is an immutable effective shipment member;
- the receipt source is `v2_exact`;
- the exact fulfilment position remains valid;
- clean quantity covers shipped quantity;
- shipped quantity covers the exact shipment membership.

A null batch ID, legacy fallback, invalid exact position, missing membership or quantity mismatch retains the existing exception unchanged.

## 4. Guard behaviour that must remain unchanged

No other statement in `customer_sales_release_guard_v1()` may change, including:

- sales invoice identity and lock;
- release provenance immutability;
- void and reversal rules;
- exact tracking-allocation identity;
- commercial parent identity;
- supplier approval and line progression;
- exact effective shipment membership lookup;
- hold checks;
- unresolved exception checks;
- terminal refund exclusion;
- cumulative quantity and value limits;
- delivery and discount limits;
- existing exception messages;
- trigger binding, owner, grants and security attributes.

The existing effective-line lookup immediately after receipt qualification remains mandatory and unchanged.

## 5. Fingerprint authority

The follow-up migration must require the exact live starting guard fingerprint:

```text
customer_sales_release_guard_v1()
d50b362d97a46f36a07acdb237231b46
```

The guard is now intentionally replaced and is removed from the unchanged-fingerprint list.

All other protected fingerprints from v1 remain unchanged, including the draft creator:

```text
internal_customer_invoice_release_create_drafts_v1(uuid[])
2e75a619e3cc3cc2fc364d3cb5a85cc3
```

## 6. Required follow-up regression

Rollback-only proof must confirm:

1. the helper remains private;
2. the guard contains the exact helper-based alternative and retains the original exception text;
3. the guard still contains effective shipment membership, hold, exception, terminal refund and cumulative quantity/value controls;
4. `J040826` has exactly one proven effective line, quantity `1`, goods `£10`;
5. the four diverted allocations fail proof;
6. all protected non-guard fingerprints remain unchanged;
7. authenticated draft creation succeeds exactly once after installation;
8. one active release-ledger membership is created for allocation `9dd8c47c-9dd9-4191-910b-41095f15feee`;
9. refresh or retry produces no duplicate draft or active release membership.

## 7. Rollback

The compensating rollback for this follow-up migration restores the exact prior guard definition with fingerprint `d50b362d97a46f36a07acdb237231b46`.

It must not drop the helper or roll back the resolver and queue corrections unless the complete v1 compatibility patch is also being rolled back.

## 8. Acceptance statement

Queue discovery, preview calculation and durable ledger insertion must enforce one identical exact-clean proof boundary. A mixed package may create a customer-sales draft only for a currently valid exact clean immutable shipment membership. Every unproven line remains blocked by the existing package-clean exception.