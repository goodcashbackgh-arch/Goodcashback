# Customer Shipping-Only Recharge Sage Ledger Addendum v1

**Status:** Governing corrective implementation contract  
**Implementation status:** Approved scope for this branch only  
**Scope:** Customer-sales Sage presentation and ledger resolution for shipping-only recharge lines  
**Authority:** This file is the build authority for this correction. No implementation may exceed it without explicit approval.

---

## 1. Objective

Correct one proven customer-sales accounting presentation case:

> Where an existing customer-sales release line contains no goods value and a positive approved shipping value, the line is a standalone customer shipping recharge. It must resolve to the existing Sage **Carriage on Sales (4910)** account through a dedicated production mapping and must be described as a shipping charge rather than as a second sale of the underlying goods.

The correction must preserve every unrelated working route.

---

## 2. Proven scenario

The live diagnostic evidence established a posted supplementary customer invoice with:

```text
goods_gbp    = 0.00
shipping_gbp = 24.00
charge_gbp   = 24.00
release_lines = 2
scenario      = PROVEN_SHIPPING_ONLY_SUPPLEMENTARY
```

The frozen Sage payload preserved the exact durable source IDs and values but resolved both lines to the product-sales ledger and retained the source product descriptions.

The existing Sage mapping table already contains:

```text
VAT_BOX6_CARRIAGE_ON_SALES_LEDGER
→ Carriage on Sales (4910)
```

That mapping was created for VAT-return reconstruction and is not to become the production posting contract directly.

---

## 3. Exact classification rule

The only new classification authorised by this addendum is line-level and value-based:

```text
shipping-only customer recharge:
  goods_amount_gbp = 0
  AND shipping_amount_gbp > 0
```

The classification must not depend on:

- invoice timing;
- whether the related goods invoice was posted earlier;
- invoice wording;
- item description;
- order status;
- shipment status;
- a hard-coded order, invoice, batch or line ID.

Every line not satisfying the exact rule remains on its existing customer-sales route unchanged.

---

## 4. Production Sage mapping

Add one production semantic mapping:

```text
CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER
```

It must resolve through `public.sage_mapping_settings` to the same mapped Sage account currently represented by the active `VAT_BOX6_CARRIAGE_ON_SALES_LEDGER` mapping:

```text
Carriage on Sales (4910)
```

The migration must not hard-code the Sage external UUID or nominal number into resolver logic. The new production mapping must be seeded from the existing active mapped carriage-on-sales row and must fail closed if that source mapping is missing or unusable.

Existing `EXPORT_SALE_INCOME_LEDGER` remains unchanged.

---

## 5. Sage resolver behaviour

For future/unposted customer-sales documents only:

### 5.1 Shipping-only line

Where:

```text
goods_amount_gbp = 0
AND shipping_amount_gbp > 0
```

that exact resolved line must:

- resolve `sage_ledger_account_id` and `sage_ledger_account_display` through `CUSTOMER_SHIPPING_RECHARGE_INCOME_LEDGER`;
- retain every existing semantic/presentation field unless explicitly named by this addendum;
- retain all durable source IDs and release values unchanged;
- retain the existing tax resolution unchanged;
- present the line description as:

```text
Shipping charge — {existing source item description}
```

No new `ledger_account_role`, `customer_gl_role`, `presentation`, line kind or other semantic vocabulary is authorised by this correction.

### 5.2 Every other customer-sales line

Every other line must remain exactly on the existing resolver behaviour, including the existing `EXPORT_SALE_INCOME_LEDGER` resolution.

Mixed documents are allowed to contain lines with different Sage ledger account IDs only where individual durable lines satisfy the exact rule above. No other line semantics are to change.

---

## 6. Historical and frozen-document boundary

The build must not rewrite, backfill or mutate:

- posted `sales_invoices`;
- existing posted Sage invoices;
- existing posted `sage_posting_snapshots`;
- historical release-ledger rows;
- historical commercial payloads.

For an unposted document with an existing frozen snapshot, existing revalidation/fingerprint controls remain authoritative. The correction must not bypass or weaken those controls.

---

## 7. Fail-closed requirements

A shipping-only line must not silently fall back to the product-sales ledger if the new production carriage mapping is missing, inactive or blank.

For an unposted customer-sales document containing a shipping-only line, missing production carriage mapping must produce a blocked Sage-resolution state using the existing blocker/status framework. No new application status vocabulary is authorised.

---

## 8. Absolute scope freeze

This build must make **no changes** to:

- shipping-document intake, OCR, acceptance or review;
- shipping-cost allocation or apportionment calculations;
- customer-sales release-source calculation;
- `customer_sales_release_lines` membership, quantities, values or fingerprints;
- main versus supplementary invoice selection;
- invoice amount calculation;
- goods, delivery or discount calculations;
- VAT/tax treatment or zero-rating rules;
- customer funding or payment-date resolution;
- holds, disputes, refunds, credit notes or replacements;
- shipment eligibility, tracking or Mini-build 4;
- supplier AP or shipper AP;
- Carriage on Purchases (5100);
- Sage contacts;
- Sage adapters/API calls;
- posting/freeze permissions;
- posting batch creation;
- UI pages, buttons, navigation, styling or labels;
- order statuses or audience statuses;
- historical repair/backfill.

Do not add a second release resolver, second posting route, new queue, new invoice type, new status, new line semantic vocabulary, or record-specific exception.

---

## 9. Approved implementation shape

The authorised build is limited to:

1. one additive Supabase migration;
2. one new production mapping row in `sage_mapping_settings`, sourced from the existing active carriage-on-sales mapping;
3. one preservation/wrapper correction to the canonical `internal_resolved_customer_sales_sage_payload_v1(uuid)` route;
4. rebinding only the already-known direct dependants of the canonical resolver where PostgreSQL rename dependency behaviour requires it;
5. an explicit migration guard that stops if any unexpected public function dependant is discovered instead of recreating it;
6. one regression SQL file covering the exact scope above.

The known direct dependant allowlist for this migration is limited to:

```text
internal_ready_for_sage_queue_v2
internal_freeze_customer_sales_sage_batch_v1
internal_revalidate_sage_posting_snapshots_v1
```

A known dependant may be absent in a particular schema version; absence does not authorise any substitute. Any additional dependant is a stop condition.

No application/UI file change is authorised.

---

## 10. Stop conditions

Stop implementation rather than expanding scope if any of the following is found:

- the canonical customer-sales Sage resolver signature differs from `internal_resolved_customer_sales_sage_payload_v1(uuid)`;
- the existing active carriage-on-sales mapping cannot be resolved;
- durable resolved lines do not expose `goods_amount_gbp` and `shipping_amount_gbp`;
- the Sage posting route does not consume line-level `sage_ledger_account_id` from the resolved payload;
- any public function outside the explicit dependant allowlist refers directly to the canonical resolver;
- implementing the correction would require modifying release membership, invoice amounts, VAT rules, Sage adapter code or UI.

Any such condition requires a new diagnostic and explicit approval before further work.

---

## 11. Acceptance criteria

The build passes only if all of the following are proven:

1. shipping-only customer lines are assigned the production carriage-on-sales Sage ledger mapping;
2. those lines present as `Shipping charge — {item}`;
3. no existing line semantic/presentation field is changed other than the description and Sage ledger account ID/display explicitly authorised above;
4. their goods/shipping/customer-charge amounts remain economically unchanged;
5. their durable source IDs remain unchanged;
6. goods-only lines remain on the existing export-sales ledger;
7. lines with positive goods remain on the existing export-sales ledger even where shipping is also positive;
8. tax resolution is unchanged;
9. posted historical snapshots remain untouched;
10. missing shipping-recharge mapping blocks rather than falling back;
11. dependency rebinding is restricted to the explicit allowlist and stops on unknown dependants;
12. no object outside this addendum's approved implementation shape is changed.
