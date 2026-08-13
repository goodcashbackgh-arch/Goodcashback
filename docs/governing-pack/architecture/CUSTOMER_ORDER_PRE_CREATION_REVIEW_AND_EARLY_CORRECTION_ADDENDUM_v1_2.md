# Customer Order Pre-Creation Review and Early Correction Addendum v1.2

Status: governing corrective amendment to v1 and v1.1

## Authority

This amendment changes one review-control point only. v1 and v1.1 remain governing in every other respect.

## Single-submit confirmation requirement

The customer-only `Confirm & create order` action must have a synchronous client-side one-shot guard in addition to React transition/pending UI state.

The guard must:

1. be checked and set synchronously before the existing customer create action is invoked from the review confirmation;
2. prevent a second rapid Confirm click from invoking the create action again before React has rerendered its pending state;
3. apply only to the customer review-confirm path;
4. leave the importer/default submit path behaviour unchanged;
5. reset only if the final create action returns control without navigation because of an error, if that behaviour is explicitly supported by the existing action. No new retry/error lifecycle is authorised here.

The existing server action remains unchanged and remains the sole create-order authority.

## Authorised build delta

Only these source changes are authorised by v1.2:

- add one review-confirm synchronous ref guard in `app/importer/orders/new/OrderForm.tsx`;
- extend `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs` to assert that guard exists and is restricted to the review-confirm path.

No importer submission change, server-action change, database change, lifecycle change, funding/credit change, screenshot-processing change, or downstream subsystem change is authorised.

## Acceptance

A double-click or two rapid invocations of `Confirm & create order` can invoke the existing customer create action at most once, while the importer/default submission path remains exactly as before.