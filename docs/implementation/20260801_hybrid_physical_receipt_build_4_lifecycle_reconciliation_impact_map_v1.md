# Hybrid Physical Receipt Build 4 — Lifecycle and Reconciliation Impact Map v1

## Governing authority

- `HYBRID_PHYSICAL_RECEIPT_QUANTITY_FULFILMENT_AND_REMEDY_CONTROL_ADDENDUM_v1.md`
- `HYBRID_PHYSICAL_RECEIPT_IMPLEMENTATION_ALIGNMENT_ADDENDUM_v1_1.md`
- `HYBRID_PHYSICAL_RECEIPT_BUILD_4_LIFECYCLE_AND_RECONCILIATION_ALIGNMENT_ADDENDUM_v1.md`

## Frozen change surface

### Migration 1 — lifecycle and reconciliation

`20260801210000_hybrid_physical_receipt_build_4_lifecycle_reconciliation_v1.sql`

- drift-stops the reviewed live replacement, blocker and reconciliation authorities;
- hardens `create_replacement_child_order` for exact physical-remedy provenance;
- strengthens `order_has_open_child_exceptions` for unresolved remedies and unfinished or improperly cancelled children;
- preserves the exact public columns of `order_reconciliation_vw`;
- applies one identical invoice-authority predicate in canonical reconciliation and anomaly classification:
  - `is_current_for_order = true`;
  - approved or corrected-approved review status;
  - not blocked from Sage;
  - not superseded;
- adds `order_reconciliation_anomalies_v1` for non-authoritative evidence and over-progression.

### Migration 2 — atomic replacement acceptance

`20260801213000_hybrid_physical_receipt_build_4_atomic_replacement_acceptance_fix_v1.sql`

- adds `staff_accept_replacement_outcome_v1`;
- performs permitted dispute transitions, child creation, line resolution, linkage and final replacement status in one transaction;
- physical path: exactly one remedy-linked source line and exact `replacement_source_dispute_line_id`;
- legacy path: multiple manual lines may aggregate into one child, child single-source ID remains null, and the complete source-line set is retained in escalation evidence;
- rejects mixed physical and legacy lines;
- preserves replacement-of-replacement prohibition;
- grants execution to authenticated and service-role callers, not anon.

### Application alignment

`app/internal/exceptions/[dispute_id]/actions.ts`

- removes direct child-order insertion;
- removes separate status mutations around child creation;
- calls `staff_accept_replacement_outcome_v1` once;
- preserves existing read-only retailer-response feedback, staff guard and revalidation destinations.

## Protected authorities

Build 4 does not replace or weaken:

- `approve_vat_release`;
- `mark_order_accounting_release_ready`;
- `recompute_order_status`;
- physical-remedy allocation, sequence and terminal-immutability guards;
- order transition and content-lock guards.

No status-transition row, parent declared quantity/value, UI label, navigation, customer-review, shipment, VAT, Sage, refund, payout or AP authority is changed.

## Required regression evidence

Before merge:

1. approved but non-current eligible evidence is excluded canonically and exposed as non-authoritative;
2. physical one-line replacement succeeds with exact provenance;
3. physical multi-line replacement fails with no surviving writes;
4. legacy multi-line replacement succeeds with aggregate value/quantity, null single-source ID and complete source-set evidence;
5. deliberate post-transition failure proves total rollback;
6. unfinished and improperly cancelled children block the parent;
7. reconciliation public columns and protected fingerprints remain unchanged.

## Deployment order

1. apply migration 1;
2. apply migration 2;
3. run database regressions;
4. deploy the application;
5. run source regression and one controlled physical and legacy acceptance test;
6. verify protected fingerprints and role behaviour.
