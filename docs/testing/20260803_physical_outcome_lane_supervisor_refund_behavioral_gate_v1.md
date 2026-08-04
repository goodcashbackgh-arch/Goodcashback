# Physical outcome lane supervisor refund behavioral gate v1

Date: 2026-08-03

## Result

`NO_CANDIDATE`

The live candidate finder returned no order/dispute graph satisfying all of the existing refund settlement-credit authority prerequisites:

- open refund dispute;
- exact linked physical refund remedy;
- review/dispute refund identity link;
- order settlement status `credit_due`;
- credit-due amount matching the dispute amount within GBP 0.01;
- active supervisor/admin with an authenticated user.

## Interpretation

This is a live-data gate, not an installation failure.

The grouped supervisor authority is installed and its refund delegation, security mode, grants, exact-coverage guard, lane-status logic, and delegated authority fingerprints passed the installation postflight. A live end-to-end refund behavioral exercise cannot be performed without fabricating or altering financial settlement state.

## Decision

Do not synthesize, mutate, or force settlement-accounting state merely to create a behavioral candidate.

Proceed with implementation while retaining this item as an explicit deferred live behavioral gate. Re-run `physical_outcome_lane_supervisor_refund_candidate_v1` when a genuine `credit_due` order with an exact matching open physical refund dispute exists.

## Required future evidence

When a candidate exists, the rollback-only behavioral test must prove:

1. every unresolved physical item in each affected dispute is selected;
2. the grouped authority delegates to `staff_close_refund_exception_as_settlement_credit_v1`;
3. the dispute closes through the existing settlement-credit path;
4. exact decision-item audit rows are written;
5. the lane becomes `partially_resolved` or `resolved` from cumulative exact coverage;
6. an identical replay returns the stored result without duplicate financial or audit effects;
7. the transaction rolls back completely.
