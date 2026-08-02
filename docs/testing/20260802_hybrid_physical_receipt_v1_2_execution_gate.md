# Hybrid Physical Receipt v1.2 — Execution Gate

Status: governed implementation checkpoint

Authority: `docs/governing-pack/architecture/HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_2.md`

This checkpoint does not replace the addendum. It records the exact remaining execution sequence and stop conditions for the implementation branch.

## Current branch scope

The branch currently contains only the governed v1.2 scope:

- replacement original-item return adapters using the existing return-action tables;
- exact one-pending shipper confirmation invariant;
- exact guarded GBP 60 repair;
- importer, shipper and supervisor UI wiring for replacement original-item returns;
- source-contract regression;
- read-only live preflight and post-deploy verification.

The protected supervisor bridge monetary and dispute-partition repair is intentionally not finalized until the mandatory live preflight output is captured and reviewed.

## Mandatory execution order

1. Run `docs/testing/20260802_hybrid_physical_receipt_v1_2_live_preflight.sql` against the target live database.
2. Save the complete output, including function definitions, MD5 values, owners, ACLs, security mode, trigger bindings, pending-confirmation state and the exact GBP 60 provenance chain.
3. Compare the output with the locked addendum and repository baseline.
4. Stop on any mismatch, ambiguity or missing prerequisite.
5. Finalize the supervisor bridge migration against the verified installed definition only.
6. Run database regressions for commercial-value apportionment, refund partitioning, replacement partitioning, concurrency and security.
7. Apply the exact GBP 60 repair migration and verify all three values are GBP 60.
8. Apply the replacement-return adapter migration.
9. Run source regression:

   ```bash
   node docs/testing/20260802_hybrid_physical_receipt_v1_2_source_regression.mjs
   ```

10. Run the repository type check and production build using the package scripts defined by the repository.
11. Complete authenticated browser acceptance for importer, shipper and supervisor flows.
12. Run `docs/testing/20260802_hybrid_physical_receipt_v1_2_postdeploy_verification.sql`.
13. Re-capture protected-object fingerprints and compare them with the approved preflight output.
14. Merge only when every gate passes.

## Non-negotiable stop conditions

Stop immediately if any of the following is observed:

- the installed supervisor v1 or v2 function differs from the captured definition;
- function owner, ACL, `SECURITY DEFINER`, `search_path`, trigger binding or configuration differs;
- tracking allocation or supplier invoice provenance is ambiguous;
- commercial value is missing, zero or non-positive for an approved refund/replacement allocation;
- quantity reconciliation fails;
- the exact GBP 60 repair record is neither in the reviewed broken state nor the exact repaired state;
- duplicate pending shipper confirmations exist;
- missing-item replacement data appears in the return-action workflow;
- protected refund, DVA/card, settlement, VAT, accounting, Sage/AP, funding, RLS or role behavior changes;
- source files drift from the locked UI/RPC contracts;
- type check, production build, database regressions or browser acceptance fails.

## Protected boundaries

Do not change:

- `staff_decide_physical_receipt_review_v2` gateway signature or contract;
- `staff_accept_replacement_outcome_v1`;
- `create_replacement_child_order_v2`;
- existing refund return/evidence v1 authorities;
- DVA/card, settlement, VAT, accounting, Sage/AP or funding behavior;
- RLS policies, role matrix or direct table grants unless separately proven and governed;
- immutable historical migrations.

## Completion definition

The work is complete only when the implementation matches the addendum exactly, the live fingerprints match the approved preflight, all regressions pass, the exact GBP 60 record is repaired, and authenticated browser acceptance confirms the importer, shipper and supervisor flows without protected-workflow regressions.
