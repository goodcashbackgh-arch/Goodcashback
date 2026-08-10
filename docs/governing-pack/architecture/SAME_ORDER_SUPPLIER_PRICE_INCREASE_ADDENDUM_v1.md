# Same-Order Supplier Price Increase Addendum v1

Status: governing corrective addendum

## Purpose

Allow an active supervisor/admin to increase the accepted GBP value of an existing **original** order when the platform's existing `order_bundle_limit_breach` proves that active supplier invoice totals exceed the accepted order value.

Example:

```text
order value                         £720.00
customer funding                    £720.00
supplier purchases already made     £600.00
active supplier invoice bundle      £740.00
extra customer funding required      £20.00
```

Governed result:

```text
order value £720.00 -> £740.00
funding remains £720.00
funding gap becomes £20.00
funded_at clears through existing funding logic
ordinary DVA top-up adds £20.00
existing supplier-payment proof then supports the remaining £140.00
```

## Working-part non-regression lock

Existing completed platform sections are frozen both **definitionally and behaviourally**.

This addendum does not authorise modification, replacement, weakening, extension or behavioural reinterpretation of an existing working function, view, trigger, server action, route or financial workflow except at the exact four interception points expressly authorised below.

Outside those exact conditions, existing behaviour must remain unchanged.

The only authorised behavioural interventions are:

1. on a literal original order, preserve an existing open `order_bundle_limit_breach` during header Save while the governed supplier bundle still exceeds the order value;
2. on a literal original order, prevent supplier approval from committing while that same live breach remains;
3. on a literal original order, ensure a `source='supervisor_entered'` supplier-financial-summary INSERT or total UPDATE cannot create an unflagged bundle breach;
4. before the dedicated same-order price-increase RPC changes the order, fail closed if any active participating financial-summary amount disagrees with the platform's current accepted invoice gross for that same invoice.

Everything else is frozen. In particular, do not change or behaviourally extend:

```text
public.staff_save_supplier_invoice_header_review(...)
public.staff_approve_supplier_invoice_current(...)
public.flag_order_bundle_limit_after_summary_v1()
public.order_funding_total_gbp(...)
public.order_funding_gap_gbp(...)
public.recompute_order_platform_funded(...)
public.sync_order_overfunding_credit(...)
public.internal_supplier_payment_readiness_v1(...)
public.internal_supplier_payment_bundle_source_v1(...)
public.staff_reconcile_dva_line_to_order(...)
public.staff_progress_supplier_invoice_lines(...)
```

Do not change Build 4, DVA, supplier-payment allocation, Sage, VAT, accounting release, shipping, tracking, replacement-child, free-replacement, customer-review or settlement architecture.

The natural downstream consequence of a legitimate order-value increase — changed funding gap, `funded_at` recomputation, later DVA top-up and existing supplier-payment/reconciliation calculations — is not authority to modify those downstream systems.

Any regression showing behaviour outside the four authorised interventions is a build failure. Stop rather than patch a frozen subsystem.

## Existing breach flag remains authoritative

Entitlement to the new action requires:

```text
supplier_invoice_review_flags.flag_type = 'order_bundle_limit_breach'
status IN ('open','under_review')
```

A raw numerical `supplier bundle > order value` condition alone is **not** an entitlement.

The monetary bundle authority remains:

```text
SUM(supplier_invoice_financial_summary.invoice_total_gbp)
```

for invoices on the order excluding:

```text
rejected_resubmit_required
duplicate_blocked
superseded
```

Do not substitute OCR gross, accounting accepted gross or a new commercial-total hierarchy as the amount used to change the order.

## Supplier Invoice Review behaviour

`/internal/invoice-review` remains an exceptions queue.

The existing open bundle breach is already a serious flag in `supplier_invoice_match_decision_vw`; therefore it keeps the invoice in the existing review lane. No custom queue-retention model or order-level review anchor is authorised.

The existing retailer/ref/total routing remains unchanged.

## Save correction remains unchanged

`public.staff_save_supplier_invoice_header_review(...)` must remain unchanged.

A narrow `BEFORE UPDATE` protection on `supplier_invoice_review_flags` may intervene only for an existing open/under-review `order_bundle_limit_breach` on a literal original order.

Required behaviour:

1. resolve `OLD.order_id` to `orders.order_type`;
2. if `order_type IS DISTINCT FROM 'original'`, return `NEW` immediately and preserve pre-existing behaviour;
3. acquire the existing `order_bundle_limit:<order_id>` advisory lock;
4. recalculate the same active financial-summary bundle;
5. if the bundle no longer exceeds the order value, allow normal resolution;
6. if the bundle still exceeds the order value and the invoice remains pending/blocked, preserve only this flag's prior open/under-review status and resolution fields while allowing the surrounding Save to complete;
7. if the bundle still exceeds the order value and the invoice has already moved to an approved/current or accounting-unblocked state in the same transaction, raise an exception so the supplier-approval transaction rolls back.

This gives:

```text
original-order Save + live breach -> Save succeeds, breach stays open
original-order supplier approval + live breach -> approval rolls back
non-original order -> this new protection does nothing
```

The same advisory lock serialises Save against the governed supervisor-summary breach checks.

## Supervisor financial-summary INSERT/UPDATE hole

The established operator-upload bundle trigger remains unchanged and remains responsible for its existing `source='operator_entered'` INSERT path.

The existing supervisor adjustment workflow uses an upsert into `supplier_invoice_financial_summary`. Normally that becomes an UPDATE of the unique invoice summary row, but if the row is absent it can become an INSERT with `source='supervisor_entered'`.

The branch companion must therefore cover only the exact supervisor seam:

```text
AFTER INSERT where NEW.source = 'supervisor_entered'
AFTER UPDATE OF invoice_total_gbp where NEW.source = 'supervisor_entered'
```

All other summary writes retain existing behaviour.

For UPDATE, do nothing if `NEW.invoice_total_gbp IS NOT DISTINCT FROM OLD.invoice_total_gbp`.

For both events:

1. act only for literal `orders.order_type = 'original'`;
2. ignore retired invoice versions using the same exclusions as the existing bundle trigger;
3. acquire the existing `order_bundle_limit:<order_id>` advisory lock;
4. recalculate the same active financial-summary bundle;
5. if the bundle does not exceed the current order value by more than £0.01, do nothing;
6. if an open/under-review `order_bundle_limit_breach` already exists for the changed invoice, do nothing;
7. otherwise create that existing flag using only genuine operator provenance;
8. allowed provenance is `NEW.entered_by_operator_id`, `OLD.entered_by_operator_id` for UPDATE, or a genuine existing review-flag `raised_by_operator_id` for that invoice/order;
9. never substitute staff identity, auth identity, a constant or invented operator identity;
10. if a breach must be created but genuine operator provenance is unavailable, raise an exception and roll back the supervisor summary write;
11. change no invoice status, order value, funding, progression or accounting state.

This companion does not replace or broaden the established operator-upload trigger.

## Dedicated UI action

On an invoice card with a genuine open bundle breach, and only for literal `order_type = 'original'`, show:

```text
Current order value
Current active supplier bundle
Additional funding required
[Approve order price increase]
```

The UI may display the same financial-summary bundle but cannot submit a monetary amount.

The server action sends only:

```text
order_id
supplier_invoice_id
optional review note
```

Do not modify existing Save, Reject, Exclude, OCR or reconciliation actions.

## Dedicated RPC

Add only:

```text
public.staff_approve_order_supplier_price_increase_v1(
  p_order_id uuid,
  p_supplier_invoice_id uuid,
  p_review_notes text default null
)
```

It must:

1. require an authenticated active `admin` or `supervisor`;
2. require literal `orders.order_type = 'original'` — NULL or any other type fails closed;
3. require the exact open/under-review `order_bundle_limit_breach` for the supplied invoice/order;
4. require that invoice to remain an active invoice on that order;
5. lock existing summary rows for the order deterministically, then supplier-invoice rows deterministically, then the exact open breach flag, then the existing `order_bundle_limit:<order_id>` advisory lock, then the order row;
6. before mutation, validate every active participating invoice summary against the platform's existing `supplier_invoice_accounting_coding_totals_vw.accepted_invoice_gross_gbp` projection;
7. where accepted gross is present, require `ABS(financial_summary.invoice_total_gbp - accepted_invoice_gross_gbp) <= 0.01` invoice by invoice;
8. do not allow discrepancies on separate invoices to cancel at order-total level;
9. if any participating invoice differs by more than £0.01, raise and make no mutation; the existing invoice/adjustment workflow must reconcile the totals first;
10. use accepted gross only as a consistency validator — never as the amount used to change the order and never as a second monetary authority;
11. never automatically rewrite `supplier_invoice_financial_summary`, the invoice header, OCR fields or accounting values;
12. derive the new amount server-side solely from the same active `supplier_invoice_financial_summary.invoice_total_gbp` bundle after all invoice-by-invoice consistency checks pass;
13. accept no browser-supplied amount;
14. only increase; no decrease or no-op;
15. respect `content_locked_at` and never bypass `public.enforce_order_locks()`;
16. fail after completed/terminal, accounting-release-ready or VAT-release/reporting boundaries;
17. fail closed for non-zero `markup_applied_gbp` in v1;
18. fail closed for funding-authority disagreement, funding-reversal history, existing order-sourced overfunding credit or active pending/confirmed funding-surplus state;
19. preserve stored quote economics by proportionately changing `quote_total_ghs` using the old stored effective GBP→GHS ratio; fetch no new FX rate and change no locked FX/card fields;
20. update only the order GBP total, proportionately derived `quote_total_ghs`, and normal `updated_at`/audit effects;
21. create no funding event;
22. call existing `recompute_order_platform_funded(order_id)`;
23. call existing `sync_order_overfunding_credit(order_id)` only after the fail-closed safety checks above;
24. do not lock funding rows merely for this amendment; if concurrent funding changes make before/after postconditions inconsistent, fail/rollback and retry rather than introducing a DVA lock-order dependency;
25. verify funding-event count is unchanged and resulting funding position matches the expected new gap;
26. resolve only open/under-review `order_bundle_limit_breach` flags for the order after the new baseline is committed;
27. leave unrelated review flags untouched.

### Stale-summary example

If the financial summary is £140 but the current accepted invoice gross is £135:

```text
summary          £140
accepted gross   £135
difference         £5
```

The price RPC must stop. It must not choose £140, £135, the higher amount, the lower amount or an average.

Once the established correction path makes the summary agree at £135, a £600 prior bundle plus £135 derives a new order value of £735 and an additional funding requirement of £15.

## Existing downstream result

No new funding mechanism is created.

For the clean example:

```text
£720 order + £720 funding
-> approve price £740
-> £20 funding gap / funded_at NULL
-> normal £20 DVA top-up
-> £740 funded / funded_at restored
-> existing supplier-payment provenance sees £740 - £600 = £140 available
```

Build 4 already reads `orders.order_total_gbp_declared`; it follows the amended value naturally. No Build 4 patch is authorised.

The order-value change itself is not a VAT funding/sales event. The later genuine top-up follows existing VAT treatment.

## Sequential increase

A later genuine supervisor/operator summary change taking the bundle from £740 to £750 must produce or retain a fresh open bundle breach. The same governed action may then approve £740 -> £750 once the participating summaries pass the same accepted-gross consistency checks.

## Required regression

Before merge, prove at minimum:

1. existing header-save RPC unchanged;
2. existing supplier-approval RPC unchanged;
3. existing operator bundle INSERT trigger/function unchanged;
4. shared approval-readiness helper unchanged;
5. normal non-breach review routing unchanged;
6. non-original/replacement orders are behaviourally unaffected by the new breach-protection trigger;
7. NULL/unknown order type is not eligible for price amendment;
8. original-order Save can complete while a live bundle breach remains open;
9. direct supplier approval cannot commit while that original-order live breach exists;
10. concurrent Save/supervisor-summary paths serialize on the existing bundle lock so no live breach is silently lost;
11. supervisor-entered summary UPDATE can create the existing breach with genuine provenance;
12. supervisor-entered summary INSERT can also create that breach when genuine provenance exists;
13. a breaching supervisor INSERT/UPDATE with no genuine operator provenance rolls back rather than creating false audit attribution;
14. non-breaching supervisor summary writes remain unaffected;
15. raw over-limit data without a genuine open breach flag cannot call the price RPC;
16. browser cannot supply the new total;
17. summary £140 / accepted gross £140 passes the consistency gate;
18. summary £140 / accepted gross £135 blocks amendment with zero mutation;
19. two invoice-level discrepancies that cancel at order-total level still block;
20. after established correction makes the summary £135, the server derives £735 rather than £740;
21. clean £720 -> £740 amendment preserves quote economics and creates no funding event;
22. recompute produces the £20 gap and clears `funded_at`;
23. only bundle-breach flags resolve after amendment;
24. normal £20 DVA top-up restores full funding;
25. existing supplier-payment source then supports £140 after prior £600;
26. Build 4 target follows the amended order total without Build 4 code changes;
27. later sequential breach/amendment remains possible;
28. content lock, terminal boundaries, funding drift, reversal, markup, overfunding and surplus cases fail without mutation;
29. protected DVA, supplier-payment, Build 4, VAT, Sage, replacement/free-replacement and existing invoice-review authorities retain their existing definitions and behaviour outside these exact four interventions.

## Scope lock

Authorised changed-file/runtime scope remains limited to:

- this addendum;
- the one existing branch migration containing the narrow breach-protection trigger, narrow supervisor-summary companion and dedicated price RPC;
- `app/internal/invoice-review/page.tsx` already added for the flag-gated card/read-only display;
- the dedicated `price-actions.ts` already added for the new RPC;
- focused regression files.

For the three corrective gaps above, no further runtime change is authorised to `page.tsx`, `price-actions.ts`, `app/internal/adjustments/actions.ts`, any existing invoice-review server action, DVA, Build 4, supplier payment, VAT, Sage, replacement/free-replacement, shipping, tracking, settlement or customer-review code.

No new commercial read model, no global supplier-approval transition trigger, no shared readiness rewrite, no existing RPC replacement, no new funding mechanism and no superseded/no-op migration files are authorised.
