# Customer Order Pre-Creation Review and Early Correction Addendum v1.2

Status: governing corrective amendment to v1 and v1.1

## Authority

This amendment changes two control points only: customer review confirmation single-submit protection and canonical persistence of already-authorised replacement screenshot objects. v1 and v1.1 remain governing in every other respect.

Where v1.1 section 4 says Storage verification remains unchanged, this v1.2 amendment supersedes only the persistence detail described below. All existing bucket, namespace, upload, row-identity/count and non-destruction rules remain unchanged.

## 1. Single-submit confirmation requirement

The customer-only `Confirm & create order` action must have a synchronous client-side one-shot guard in addition to React transition/pending UI state.

The guard must:

1. be checked and set synchronously before the existing customer create action is invoked from the review confirmation;
2. prevent a second rapid Confirm click from invoking the create action again before React has rerendered its pending state;
3. apply only to the customer review-confirm path;
4. leave the importer/default submit path behaviour unchanged;
5. reset only if the final create action returns control without navigation because of an error, if that behaviour is explicitly supported by the existing action. No new retry/error lifecycle is authorised here.

The existing server action remains unchanged and remains the sole create-order authority.

## 2. Canonical replacement screenshot persistence

The correction RPC must continue to verify every replacement screenshot object against `storage.objects` in the existing `order-screenshots` bucket under the authenticated importer/order correction namespace.

Object-existence verification does not make a caller-supplied URL prefix trustworthy. Therefore, after object verification, the RPC must not persist the caller-supplied URL string verbatim.

For screenshot replacement, the RPC must:

1. derive the trusted public Storage URL prefix from the existing original screenshot rows for the same order;
2. require that prefix to be present and consistent across the original screenshot set;
3. extract and verify each replacement object name against `storage.objects` and the authenticated importer/order correction namespace;
4. rebuild each replacement screenshot URL from the trusted existing prefix plus the verified object name; and
5. persist only those rebuilt canonical URLs into the existing original screenshot rows.

A caller-supplied arbitrary host or URL prefix must never become authoritative merely because its suffix names a real Storage object.

The one-for-one row mapping, row IDs/count/display order/note, existing bucket, upload helper, client upload behaviour and physical Storage non-destruction rules remain unchanged.

## Authorised build delta

Only these source changes are authorised by v1.2:

- add one review-confirm synchronous ref guard in `app/importer/orders/new/OrderForm.tsx`;
- harden `supabase/migrations/20260813124500_customer_order_early_correction_v1.sql` so verified replacement object names are persisted using the trusted existing original-screenshot Storage prefix rather than the caller URL prefix;
- extend `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs` to assert the one-shot guard, its restriction to the review-confirm path, canonical URL reconstruction and absence of verbatim caller-prefix persistence.

No importer submission change, server-action change, lifecycle change, funding/credit change, tracking change, supplier-invoice change, reconciliation change, shipping change, Sage/VAT/accounting change, table/schema change, existing-function replacement, trigger change, RLS change, new bucket, screenshot-processing/upload-helper change or physical Storage cleanup is authorised.

## Acceptance

- A double-click or two rapid invocations of `Confirm & create order` can invoke the existing customer create action at most once, while the importer/default submission path remains exactly as before.
- A direct authenticated RPC caller may provide a normal Supabase public URL or valid correction object path for verification, but the database may store only the canonical URL reconstructed from the trusted existing original-screenshot prefix and the verified Storage object name.
