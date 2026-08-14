# Customer Order Pre-Creation Review and Early Correction Addendum v1

Status: governing additive corrective addendum

## Purpose

Add two tightly bounded customer protections without changing the established order lifecycle or any working downstream flow:

1. a customer-only **Review order** step before the existing create-order action runs; and
2. a customer-only **Correct order** action that can change only the original order quantity, declared GBP amount and original order screenshots while the order is still genuinely untouched.

This addendum is subordinate to and must be read with:

- `docs/governing-pack/ui/CREATE_ORDER_MVP_CONTRACT.md`
- `docs/governing-pack/ui/ORDER_OPERATIONS_MVP_CONTRACT.md`
- `docs/governing-pack/CHANGE_CONTROL_AND_DEPLOYMENT_PROTOCOL.md`
- `docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md` for the established rule that stored quote economics are preserved rather than repriced at a new FX rate.

Where this addendum authorises a narrow interception point, it governs that point only. Everything else remains frozen.

## Working-part non-regression lock

Existing order creation, customer credit auto-application, funding, tracking, supplier invoice, evidence, reconciliation, shipment, customer hold, replacement, settlement, Sage, VAT and accounting-release behaviour is frozen both definitionally and behaviourally.

This addendum does not authorise modification, replacement, weakening, refactoring or behavioural reinterpretation of any existing working function, trigger, RLS policy, route, server action or financial workflow except for the exact additive seams listed below.

In particular, do not modify:

```text
app/customer/orders/new/actions.ts
public.customer_apply_available_credit_to_order_v1(uuid)
public.enforce_order_locks()
public.trg_lock_quote_snapshot_on_order_submit()
existing funding RPCs/triggers
existing tracking RPCs/triggers
existing supplier invoice RPCs/triggers
existing reconciliation RPCs/views
existing shipment/receipt flows
existing customer-hold flows
existing Sage/VAT/accounting flows
existing RLS policies
```

Any regression outside the authorised seams is a build failure. Stop rather than patch a frozen subsystem.

## Authorised seams

Only the following changes are authorised:

1. customer opt-in review behaviour in the existing shared create-order form;
2. the customer create page enabling that review behaviour;
3. an isolated customer order-correction UI on the customer order operations route;
4. an authenticated customer client control that may perform customer-readable eligibility checks, upload replacement images to the existing bucket and call only the dedicated correction RPC for database mutation;
5. one additive transactional correction RPC/migration;
6. focused regression coverage for this feature.

No generic Edit Order or Delete Order capability is authorised.

---

## 1. Pre-creation review

### Customer-only isolation

The shared form `app/importer/orders/new/OrderForm.tsx` may gain one optional prop:

```text
reviewBeforeSubmit?: boolean
```

Default must be `false`.

Only `app/customer/orders/new/page.tsx` may enable it.

Importer behaviour must therefore remain unchanged by default.

### Review behaviour

When `reviewBeforeSubmit` is false, the existing submit behaviour and wording remain unchanged.

When `reviewBeforeSubmit` is true, the first valid submit must:

1. run the same browser validity checks already used by the form;
2. require attachment preparation to have completed successfully;
3. require at least one prepared file;
4. perform no server action;
5. perform no upload;
6. create no database row;
7. show an inline review summary with retailer, quantity, declared GBP amount, destination and attachment count.

Customer buttons:

```text
Back & edit
Confirm & create order
```

`Back & edit` must preserve the mounted form, uncontrolled values and prepared files.

`Confirm & create order` must rebuild `FormData` from the still-mounted form, replace raw screenshot input values with the existing prepared files, and invoke the existing supplied `action(formData)` exactly once.

Do not store `FormData` in React state.

Do not unmount the form fields during review.

Do not edit `app/customer/orders/new/actions.ts` as part of this feature.

---

## 2. Correctable fields

A successful post-creation correction may change only:

```text
orders.total_qty_declared
orders.order_total_gbp_declared
orders.quote_total_ghs   -- derived automatically, never customer-entered
order_screenshots.screenshot_url for existing rows whose note = 'Original order screenshot'
order_screenshots.uploaded_by_operator_id for those same rows
```

The customer directly edits only:

```text
quantity
declared GBP amount
original order screenshots
```

The following are frozen and must not change:

```text
order id
order_ref
payment_auth_id
importer_id
operator_id
shipper_id
retailer_id
destination_hub_id
order_type
status
funded_at
content_locked_at
tracking_locked_at
quote_fx_rate
quote_card_markup_pct
quote_fx_rate_locked
quote_card_markup_pct_locked
quote_rate_date_locked
quote_rate_locked_at
tracking data
supplier invoice data
funding data
reconciliation data
shipment data
Sage/VAT/accounting data
order_screenshots row ids/count/display order/note
```

---

## 3. Correction eligibility: genuinely untouched only

UI visibility is advisory only. The database RPC is the final authority and must re-check every condition in the same transaction immediately before mutation.

An order is correctable only when all of the following are true:

```text
orders.order_type = 'original'
orders.status = 'pending_dva_funding'
orders.content_locked_at IS NULL
orders.tracking_locked_at IS NULL
orders.funded_at IS NULL
orders.completed_at IS NULL
orders.accounting_release_ready_at IS NULL
orders.vat_release_approved_at IS NULL
orders.vat_return_period IS NULL
```

and there is zero downstream activity in every verified authoritative early-processing lane below:

```text
order_funding_events
order_tracking_submissions
supplier_invoices
dva_reconciliation
dva_statement_line_allocations
order_evidence_queries
order_value_adjustments
customer_order_review_links
customer_pre_shipment_hold_requests
shipper_shipment_batch_packages
shipper_package_receipts
sales_invoices
shipping_quote_orders
```

and there is no replacement child whose `parent_order_id` is the order being corrected.

### Screenshot exception

The original create-order screenshots are not downstream processing and therefore do not block correction.

However, correction must fail closed if any `order_screenshots` row for the order has a note that is distinct from:

```text
Original order screenshot
```

This prevents a later evidence use of that table from being silently changed.

There must be at least one existing original screenshot row before screenshot replacement is allowed.

### Lock-field interpretation

`content_locked_at` and `tracking_locked_at` are additional fail-closed checks only.

They are not sufficient authority by themselves because live data shows historical/progressed rows where these timestamps are not consistently populated. Actual downstream child-table existence is authoritative.

### Status interpretation

`status = 'pending_dva_funding'` is necessary but not sufficient.

Live data contains `pending_dva_funding` orders with funding/credit events, so the child-table checks are mandatory.

---

## 4. Transaction and ownership authority

Add one function only:

```text
public.customer_correct_unprocessed_order_v1(
  p_order_id uuid,
  p_total_qty_declared integer,
  p_order_total_gbp_declared numeric,
  p_replacement_screenshot_urls text[] default null
)
```

The RPC must:

1. require `auth.uid()`;
2. resolve an active operator and active `operator_importers` assignment using the existing customer RPC pattern;
3. load the order `FOR UPDATE`;
4. require order importer and operator ownership to match the authenticated assignment;
5. re-check the complete untouched-order gate after the row lock;
6. reject rather than repair/reverse any downstream activity;
7. update only the explicitly authorised fields;
8. create no funding event and invoke no funding mutation RPC;
9. leave all existing triggers active, including `public.enforce_order_locks()` and the existing audit trigger.

Use:

```text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
```

Permissions:

```text
PUBLIC         no execute
anon           no execute
authenticated  execute
service_role   execute if consistent with existing project migration convention
```

No RLS policy change is authorised.

The browser is never database authority. Even if a customer calls the RPC directly, the RPC must independently derive identity/ownership and fail closed against the full live gate.

---

## 5. Validation

The RPC must require:

```text
p_total_qty_declared > 0
p_order_total_gbp_declared > 0
```

GBP amount is rounded to two decimals server-side.

If `p_replacement_screenshot_urls` is non-null:

1. every URL must be non-empty;
2. the array count must equal the current count of original screenshot rows;
3. the existing original screenshot count must be greater than zero.

This one-for-one rule is deliberate: it lets the customer correct the original attachment set without changing screenshot row identities/count or forcing changes into existing screenshot consumers.

If quantity and amount are unchanged and no replacement screenshots are supplied, the RPC returns a no-op result without mutation.

---

## 6. Quote economics

A customer correction must never fetch a new FX rate and must never change any stored or locked FX/markup field.

Only when the declared GBP amount actually changes, require the existing order to have:

```text
old order_total_gbp_declared > 0
old quote_total_ghs IS NOT NULL
old quote_total_ghs > 0
```

Preserve the order's actual stored economics:

```text
effective stored ratio = old quote_total_ghs / old order_total_gbp_declared
new quote_total_ghs = ROUND(new GBP amount * effective stored ratio, 2)
```

If only quantity or screenshots change, leave `quote_total_ghs` unchanged.

Do not reconstruct the quote from current `fx_rates` and do not rewrite locked quote fields.

The RPC does not update `status`, so the existing quote snapshot trigger remains untouched and is not repurposed for correction.

---

## 7. Screenshot replacement: one-for-one, non-destructive

Existing creation classification remains authoritative:

```text
note = 'Original order screenshot'
```

If replacement screenshot URLs are null, screenshot rows remain untouched.

If replacement screenshot URLs are supplied, the RPC must atomically:

1. lock the existing original screenshot rows in stable `display_order, id` order;
2. require the replacement URL count to equal the locked original row count;
3. map replacement URL 1..n to existing screenshot row 1..n;
4. update only `screenshot_url` and `uploaded_by_operator_id` on those existing rows;
5. preserve each row's `id`, `order_id`, `display_order` and `note`.

The correction RPC must not remove or add screenshot rows.

No other screenshot/evidence row may be changed.

### Storage non-destruction rule

The authenticated customer client control may upload new replacement files to the existing `order-screenshots` bucket before calling the RPC, using the same user-scoped Supabase session as the existing authenticated application.

No service-role credential may be exposed to the browser.

This v1 build must not remove physical Storage objects, either old superseded files or newly uploaded orphan files after a failed race. Superseded/orphaned files may remain unreferenced. This is deliberate fail-safe behaviour and avoids adding destructive storage cleanup to this feature.

No new bucket is authorised.

---

## 8. Customer correction UI

The customer operations route may mount one isolated authenticated client correction control.

The control may use customer-readable facts to hide itself when the order is obviously no longer eligible. This UI check is advisory and may be narrower than the full database gate; any uncertainty or read error must fail closed where practical.

The RPC remains the sole authoritative eligibility check at Save and must check every table listed in section 3.

When the customer-readable UI eligibility check passes, show:

```text
Correct order
```

Editable controls:

```text
Quantity
Goods value
Replace original attachments (optional)
```

The UI must display the current original attachment count.

If no new attachments are selected, existing original screenshot rows remain unchanged.

If new attachments are selected, the customer must select exactly the same number of files as the current original attachment count. This replaces the displayed original attachment set one-for-one while preserving existing row identity and count.

If the RPC rejects because processing started after page load or because a downstream lane not visible to the customer UI has activity, show:

```text
This order can no longer be corrected because processing has started.
```

Do not expose a Delete Order button.

---

## 9. Authenticated client correction control

The isolated client control may use the existing browser Supabase client for exactly three purposes:

1. read customer-owned order/funding/tracking/invoice/screenshot facts for advisory visibility;
2. upload optional replacement image files to the existing `order-screenshots` bucket under the current order/importer namespace;
3. invoke only `customer_correct_unprocessed_order_v1` for database mutation.

Before upload it must validate:

```text
quantity is a positive integer
declared GBP amount > 0
replacement files are images
replacement file count = existing original screenshot count
total replacement attachment size <= existing 3.5 MB create-order ceiling
```

It must pass only:

```text
order id
quantity
declared GBP amount
replacement screenshot public URLs or null
```

to the RPC.

It must not directly mutate `orders`, `order_screenshots`, funding, tracking, invoice, reconciliation, shipment, Sage or VAT tables.

It must not call any other mutation RPC.

After successful RPC completion it may refresh the current route so canonical data is re-read.

If uploads succeed but the RPC later fails its race/gate check, the new Storage objects may remain orphaned; the existing order and screenshot rows must remain unchanged by the failed RPC transaction.

The create-form image optimiser is not duplicated here; replacement uploads must remain within the same existing total attachment-size ceiling. Adding a second image-processing implementation is out of scope.

---

## 10. Migration boundary

Exactly one additive migration is authorised for the database change.

It may only:

- create `public.customer_correct_unprocessed_order_v1(...)`;
- set its fixed search path/security posture;
- revoke/grant execute permissions;
- notify PostgREST schema reload if consistent with project convention.

It must not:

```text
ALTER any table
ADD a lifecycle status
DROP/REPLACE any existing function
ALTER any trigger
ALTER any RLS policy
backfill/update existing order data
change any financial/reconciliation/shipping/accounting object
remove or add order_screenshots rows
```

---

## 11. Required regression

Before merge, prove at minimum:

1. customer review performs zero DB writes/uploads;
2. Back & edit preserves values/prepared attachments;
3. Confirm & create invokes the existing creation action once;
4. importer create-order behaviour remains unchanged;
5. existing auto-credit behaviour remains unchanged;
6. an untouched original order can correct quantity;
7. an untouched original order can correct GBP amount;
8. an untouched original order can correct both;
9. an untouched original order can replace original screenshots one-for-one;
10. screenshot replacement preserves row IDs, row count, display order and note;
11. screenshot count mismatch fails without DB mutation;
12. amount correction changes `quote_total_ghs` proportionately while all FX/markup lock fields remain unchanged;
13. quantity-only/screenshot-only correction leaves `quote_total_ghs` unchanged;
14. status/order_ref/payment_auth_id remain unchanged;
15. funded/credit-applied orders fail;
16. tracked orders fail;
17. supplier-invoice orders fail;
18. reconciliation/DVA-allocation orders fail;
19. downstream evidence/query/adjustment/review-link/hold orders fail;
20. shipment/package/receipt/shipping-quote orders fail;
21. sales-invoice/accounting/VAT/completed orders fail;
22. replacement children and parent orders with replacement children fail;
23. non-original orders fail;
24. a race where processing begins before Save fails rather than overwriting progressed data;
25. existing `public.enforce_order_locks()` remains unchanged and active;
26. no funding/tracking/invoice/reconciliation/shipping/Sage/VAT rows are created or modified by correction;
27. no physical Storage removal is introduced;
28. no service-role credential is introduced into client code;
29. client code performs no direct database table mutation;
30. RPC rejection remains authoritative even if the advisory UI briefly appears for a newly progressed order.

---

## 12. Scope-creep prohibitions

This addendum does not authorise:

```text
hard order deletion
generic order editing
retailer/shipper/hub changes
order_ref/payment_auth changes
status/lifecycle changes
funding or credit reversal
tracking correction/deletion
supplier invoice correction/deletion
reconciliation correction
hold/exception creation
replacement workflow changes
shipment/shipping changes
Sage/VAT/accounting changes
RLS changes
lock-trigger changes
historical lock-field repair
physical Storage cleanup/removal
changing order_screenshots row count/identity/display order/note
service-role use in browser/client code
client-side direct database table mutation
shared-form refactoring unrelated to review
importer review-before-create unless separately approved
```

## Acceptance rule

The build is acceptable only when an untouched customer order can be reviewed before creation and can later correct only quantity, declared GBP amount and original screenshots, while every established upstream/downstream path continues behaving exactly as before.

Any regression outside this narrow path is a build failure, not authority to patch a frozen subsystem.
