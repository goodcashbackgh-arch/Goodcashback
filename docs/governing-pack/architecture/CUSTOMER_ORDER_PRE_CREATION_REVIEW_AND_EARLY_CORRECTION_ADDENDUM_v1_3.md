# Customer Order Pre-Creation Review and Early Correction Addendum v1.3

Status: governing corrective amendment to v1, v1.1 and v1.2

## Authority

This amendment changes four customer-correction presentation/attachment points only:

1. replacement of the original attachment set may contain one or more images instead of being forced to match the previous row count, with the dedicated correction RPC independently verifying that the stored replacement objects are images and remain within the same 3.5 MB total ceiling;
2. replacement images must use the same browser-side optimisation approach already proven in the create-order form, copied into the correction path without refactoring or changing the working create-order implementation;
3. the collapsed `Correct order` control must remain clearly discoverable but visually subordinate to the primary order-status/payment content; and
4. after a successful correction the correction disclosure must collapse automatically, while remaining available if the order is still genuinely untouched. If an authoritative Save rejection proves processing has started, the correction control must hide immediately.

v1, v1.1 and v1.2 remain governing in every other respect. Where this amendment conflicts with the prior one-for-one screenshot row-count rule, v1.3 governs.

## Live authority checked before this amendment

Read-only live verification on 13 August 2026 established for `public.order_screenshots`:

- no foreign key references point to `order_screenshots`;
- no non-internal trigger is attached to `order_screenshots`;
- the live table has only the existing `Original order screenshot` note classification (65 rows at the time of the probe);
- the only functions whose stored definitions reference `order_screenshots` are the already-created `customer_correct_unprocessed_order_v1(...)` feature RPC and the existing importer create-order function;
- the existing customer, importer, reconciliation and internal-hold UI consumers iterate screenshot rows as a collection rather than assuming one fixed row.

A subsequent read-only live Storage probe established for the existing `order-screenshots` bucket:

- `file_size_limit` is currently `null`;
- `allowed_mime_types` is currently `null`; and
- recent `storage.objects.metadata` records expose stored-object `size` and `mimetype` values.

This evidence authorises controlled original-screenshot row-count replacement and correction-only stored-object validation inside the dedicated correction RPC. It does not authorise mutation of any downstream evidence row, any other consumer, the Storage bucket configuration, or the existing create-order upload path.

## 1. Replacement attachment set

When no replacement attachments are selected, existing original screenshot rows remain unchanged.

When replacement attachments are selected, they represent the complete corrected original attachment set and must satisfy:

```text
replacement image count >= 1
prepared replacement total <= 3.5 MB
all replacement files are images
```

The replacement count does not have to equal the previous original screenshot row count.

The RPC must still require at least one existing row whose note is exactly:

```text
Original order screenshot
```

This amendment does not extend screenshot correction to legacy orders with zero original screenshot rows.

### Controlled row-set replacement

After the existing full untouched-order gate, authenticated ownership checks, row lock, Storage object verification and canonical URL reconstruction have all passed, the RPC may change only rows whose note is exactly `Original order screenshot` as follows:

1. order existing original rows by `display_order, id`;
2. order the replacement canonical URLs by caller array ordinality;
3. preserve existing row IDs for overlapping positions, updating only `screenshot_url`, `uploaded_by_operator_id` and `display_order`;
4. if the replacement set is larger, insert only the additional `order_screenshots` rows required for the extra positions, with the same `order_id`, authenticated operator, contiguous `display_order` and note `Original order screenshot`;
5. if the replacement set is smaller, remove only surplus rows from the existing original-screenshot set;
6. finish with exactly the replacement count of original screenshot rows numbered contiguously from 1..n.

No row having any other note may be updated, inserted over, removed or reclassified.

Physical Storage remains non-destructive: superseded and orphaned Storage objects are not removed by this feature.

## 2. Storage security remains canonical and fail-closed

v1.2 canonical Storage persistence remains mandatory for every replacement position.

Every supplied replacement must:

- resolve to an actual object in the existing `order-screenshots` bucket;
- be under the authenticated importer/order `correction-*` namespace;
- discard any caller-supplied host/prefix as authority;
- use the trusted public Storage prefix derived consistently from the existing original screenshot rows; and
- persist only the canonical URL rebuilt from that trusted prefix plus the verified object name.

The live `order-screenshots` bucket does not currently impose a bucket-level MIME allow-list or file-size limit. Its `storage.objects.metadata` records the stored object's `mimetype` and `size`. Therefore, for correction replacement objects only, the dedicated RPC must independently fail closed unless every verified stored object reports an `image/*` MIME type and the combined stored-object size for the requested replacement set is no more than the same 3.5 MB ceiling used by the correction client (`3.5 * 1024 * 1024 = 3,670,016` bytes).

This server-side verification is a correction-RPC backstop only. It does not authorise changing the Storage bucket configuration, `OrderForm.tsx`, the customer create action, the importer create action, or any existing upload policy.

Variable row count must not weaken these controls.

## 3. Reuse the create-order image optimisation approach without touching it

The working create-order form is frozen and must not be refactored as part of this amendment.

The correction client may copy the proven browser-side image preparation behaviour from `app/importer/orders/new/OrderForm.tsx`, including its existing:

```text
MAX_ATTACHMENT_BYTES = 3.5 MB
TARGET_ATTACHMENT_BYTES = 3.1 MB
COMPRESSION_TRIGGER_BYTES = 700 KB
MAX_FILE_TARGET_BYTES = 900 KB
MIN_FILE_TARGET_BYTES = 300 KB
MAX_IMAGE_DIMENSIONS = [1800, 1500, 1200]
JPEG_QUALITIES = [0.86, 0.76, 0.66]
```

The correction path must prepare the selected images before upload, use the prepared files rather than the raw input files, and fail closed if the prepared total still exceeds 3.5 MB.

GIF/SVG/non-optimisable behaviour must follow the existing create-order optimiser rather than inventing a second compression policy.

No change to `OrderForm.tsx`, the customer create action or importer create action is authorised by v1.3.

## 4. Correction control presentation and post-Save behaviour

The correction control remains on the customer order operations route only.

### Collapsed state

When eligible and collapsed, `Correct order` must be a small neutral/outlined disclosure control that is easy to find but visually subordinate to the order's primary status, payment and journey content. It must not present as a dominant full-width action banner.

### Expanded state

Opening the disclosure may show the existing correction fields:

```text
Quantity
Goods value
Replace original attachments (optional)
```

Attachment guidance must make clear that selecting replacement attachments replaces the complete original attachment set and that one or more images may be selected.

### Successful Save

After a successful RPC response:

1. canonical quantity/value state is refreshed as already authorised;
2. replacement-file preparation state is cleared;
3. the correction disclosure closes automatically;
4. the `Correct order` disclosure remains available only if the order remains eligible.

A successful correction by itself does not make the order processed, so the control may remain available in collapsed form until a genuine blocker appears.

### Blocked state

The existing database RPC remains the final authority. The advisory client continues to hide the control on the customer-readable blockers it can establish.

No polling, realtime subscription, service-role read, new eligibility RPC or new background check is authorised.

If Save is rejected with the authoritative `processing has started` or downstream-evidence blocker, the client must immediately clear its local eligibility state so the `Correct order` control disappears without requiring a manual refresh.

A later normal route refresh must continue to re-evaluate the existing advisory visibility checks.

## 5. Migration boundary

The v1 migration has already been executed and must not be edited/re-run as the deployment mechanism for this amendment.

Exactly one new corrective migration is authorised. It may only:

- require the existing `public.customer_correct_unprocessed_order_v1(uuid,integer,numeric,text[])` function to exist;
- replace that feature-owned function with the v1.3 variable original-screenshot row-set logic;
- preserve its existing `SECURITY DEFINER` and fixed `search_path = public, pg_temp` posture;
- preserve the existing execute privilege posture; and
- notify PostgREST schema reload if consistent with project convention.

It must not:

```text
ALTER any table
create a new lifecycle status
change any existing non-feature function
change any trigger
change any RLS policy
backfill data
change funding/credit/tracking/invoice/reconciliation/shipping/Sage/VAT/accounting logic
physically remove Storage objects
change customer/importer create-order actions
```

The only authorised row removal is tightly scoped to surplus `order_screenshots` rows for the currently corrected order where `note = 'Original order screenshot'`, after the full untouched-order gate and screenshot-row lock. No order row may be removed.

## 6. Authorised source delta

Only these source/runtime changes are authorised by v1.3:

- `app/customer/orders/[order_id]/operations/CustomerOrderCorrectionControl.tsx`: copied create-order image preparation, variable replacement guidance/validation, subtle disclosure styling, automatic collapse after successful Save, and immediate local hide after authoritative processing/downstream rejection;
- `supabase/migrations/<new-v1.3-corrective-migration>.sql`: feature-RPC replacement implementing variable original-screenshot row-set replacement while preserving all existing ownership, untouched-order, quote-economics and canonical Storage controls;
- `docs/testing/20260813_customer_order_review_early_correction_regression_v1.mjs`: extend source regression for v1.3 controls;
- this governing v1.3 amendment.

`app/customer/orders/[order_id]/operations/uploadCorrectionScreenshots.ts` may continue uploading the prepared files unchanged. No change to that helper is required unless a compile-only adjustment is necessary to accept the already-prepared files; no upload policy expansion is authorised.

No other runtime file is authorised to change.

## 7. Required regression additions

Before merge, prove at minimum:

1. one original screenshot may be replaced by two or more prepared replacement images;
2. multiple originals may be replaced by one prepared replacement image;
3. zero replacement images is not accepted as a requested attachment replacement, while selecting no replacement at all leaves screenshots unchanged;
4. overlapping original row IDs are preserved by position;
5. additional positions create only `Original order screenshot` rows with contiguous display order;
6. surplus removal affects only `Original order screenshot` rows for the corrected order;
7. non-original screenshot/evidence rows still block correction and are never mutated;
8. canonical Storage verification/prefix reconstruction remains mandatory for every replacement;
9. physical Storage removal remains absent;
10. correction uses prepared/optimised files and enforces the same 3.5 MB total ceiling as create order;
11. `OrderForm.tsx` and the existing create-order actions remain unchanged under v1.3;
12. successful Save closes the correction disclosure;
13. the collapsed control is subordinate/non-dominant in presentation;
14. authoritative processing/downstream rejection hides the local correction control;
15. every existing funding/credit/tracking/invoice/reconciliation/shipping/Sage/VAT/accounting non-regression assertion from v1-v1.2 remains in force.

## Acceptance

The customer experience is:

```text
Untouched order
→ subtle Correct order disclosure
→ correct quantity/value and optionally replace the complete original attachment set with 1+ automatically prepared images
→ Save
→ canonical order refreshes and correction panel collapses
→ correction remains available only while the order is still genuinely untouched
→ once processing blocks correction, the control is hidden/rejected fail-closed
```

No broader order editing, order removal, downstream reversal or working-flow refactor is authorised.
