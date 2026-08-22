# Supplier Goods AP Zero-Value Line Runtime Proof and Payload Correction Amendment v2

Status: governing corrective amendment

Effective scope: Supplier Goods AP final Sage purchase-invoice payload construction for explicitly present zero-value lines.

Authority: this v2 amendment is the governing authority for the zero-value-line correction described below. It supersedes only the conflicting zero-line omission language in `SUPPLIER_GOODS_AP_ZERO_VALUE_AND_PARTIAL_SUCCESS_RETRY_AMENDMENT_v1.md`. All non-conflicting v1 controls, including the exact-row retry lifecycle correction, remain authoritative and unchanged.

## 1. Proven fact

A controlled live Sage Business Cloud Accounting purchase-invoice test was completed on 22 August 2026 using the dedicated vendor `Goods To Ship API Zero Test` / `GTSZERO` and the existing Supplier Goods AP ledger/tax mappings.

The test payload contained:

- one normal £1 Supplier Goods AP control line; and
- one explicit £0 Supplier Goods AP line with `unit_price = 0`, `tax_amount = 0`, and `currency_tax_amount = 0`.

Observed Sage results:

```text
create purchase invoice: HTTP 201
read purchase invoice: HTTP 200
zero-value line retained by Sage: true
zero-value line unit_price: 0
zero-value line tax_amount: 0
control line retained by Sage: true
delete disposable purchase invoice: HTTP 204
cleanup complete: true
```

Therefore, Sage Business Cloud Accounting runtime acceptance of an explicit validated £0 purchase-invoice line is proven for the existing Supplier Goods AP payload shape.

No inference from documentation alone is required for this correction.

## 2. Correct governing rule

For Supplier Goods AP, an explicitly present numeric zero is a valid amount and must not be treated as missing.

After the existing Supplier Goods AP validations pass, a resolved line must not be omitted from `purchase_invoice.invoice_lines` solely because rounded gross, net and VAT are all `0.00`.

This rule applies regardless of whether the validated line represents a physical item, delivery or another resolved Supplier Goods AP line.

Monetary value must not be used as a semantic classifier for deciding whether a validated line is included in Sage.

## 3. Missing amount remains fail-closed

The existing distinction between a present numeric zero and a missing/invalid amount is protected.

The existing `firstPresentAmount()`-based Supplier Goods AP amount-presence logic must remain unchanged.

A line whose required amount is absent, null, blank or non-numeric must continue to fail with the existing missing-amount control.

No malformed or incomplete line may be converted into a zero-value line by this correction.

## 4. Exact authorised production code change

Target file:

`src/lib/sage/apPosting.ts`

The only authorised production-logic change for this amendment is to delete the existing Supplier Goods AP all-zero omission block:

```ts
if (
  config.lane === "supplier_goods_ap"
  && round2(grossAmount) === 0
  && round2(netAmount) === 0
  && round2(vatAmount) === 0
) {
  return null;
}
```

Nothing replaces this block.

The surrounding line-construction logic remains authoritative and unchanged.

After deletion, a validated all-zero Supplier Goods AP line proceeds through the existing `invoiceLine` construction and is sent to Sage with the existing ledger, tax-rate, quantity, unit-price and explicit tax fields.

## 5. Protected existing behaviour

This correction must not change any of the following:

- `firstPresentAmount()`;
- the approved Supplier Goods AP amount paths;
- description validation;
- ledger-account validation or selection;
- tax-rate validation or selection;
- explicit net/VAT/gross validation;
- `net + VAT = gross` reconciliation;
- source-total accumulation;
- Sage-net-total accumulation;
- header amount reconciliation;
- whole-invoice zero/net guards;
- positive Supplier Goods AP lines;
- negative Supplier Goods AP lines, including discounts;
- Supplier Goods AP retry eligibility or lifecycle;
- already-posted invoices or snapshots;
- Shipper AP;
- Customer Sales;
- supplier credit notes;
- OCR/source extraction;
- non-physical financial resolution;
- accounting coding or nominal accounts;
- VAT calculation or tax-rate mappings;
- Supplier Goods AP ready-row logic;
- freeze/snapshot semantics;
- request/response logging;
- idempotency;
- attachment behaviour;
- batch-status/count recomputation;
- Sage OAuth/business selection;
- SQL, migrations or database triggers;
- Accounting Command Centre behaviour.

No refactor, rename, formatting cleanup, helper rewrite or adjacent behaviour change is authorised.

## 6. Whole-zero invoice rule is out of scope

This amendment governs a zero-value line inside an otherwise valid Supplier Goods AP invoice.

It does not authorise any change to the existing whole-invoice guards, including the existing net-total guard or any upstream readiness rule for an invoice whose entire value is zero.

Those rules remain exactly as implemented unless separately governed in a future amendment.

## 7. Current v1 language superseded

The following v1 rule is no longer authoritative:

> an all-zero validated Supplier Goods AP line may be omitted from the final Sage API `invoice_lines` array.

Any v1 regression gate requiring an all-zero line to be absent from the final Sage payload is also superseded.

All other v1 retry, safety, lane-isolation, posted-record protection and fail-closed controls remain unchanged.

## 8. Mandatory regression gates

The production correction must not be merged unless all of the following are proven:

1. A validated Supplier Goods AP line with gross/net/VAT all `0.00` remains present in the outbound Sage `invoice_lines` payload.
2. A zero-value physical item is retained in the outbound Sage payload.
3. A zero-value delivery/non-physical line is retained in the outbound Sage payload.
4. A normal positive Supplier Goods AP line is unchanged.
5. A valid negative discount line is unchanged.
6. A line with zero VAT but non-zero net/gross is unchanged.
7. A missing/null/blank/non-numeric amount still fails the existing missing-amount control.
8. Existing explicit net/VAT/gross reconciliation remains unchanged.
9. Source/header totals remain unchanged.
10. Existing whole-invoice zero/net guards remain unchanged.
11. Shipper AP output and behaviour are unchanged.
12. Supplier Goods AP retry logic and lifecycle are unchanged.
13. No SQL, migration, trigger, mapping, OAuth, attachment or UI change is present.
14. TypeScript typecheck passes.
15. Production build passes.
16. Exact diff review confirms that the only production-logic modification in `src/lib/sage/apPosting.ts` is deletion of the governed all-zero omission block.

The existing trailing `filter((line): line is Row => line !== null)` may remain untouched if TypeScript accepts it. Its removal or refactor is not authorised by this amendment.

## 9. Temporary diagnostic cleanup

The temporary production diagnostic created solely to establish Sage runtime acceptance is not part of the permanent accounting architecture.

After the governed production correction is deployed and verified, the temporary diagnostic files under:

`app/internal/sage-zero-line-proof/`

must be removed in a separate cleanup change.

That cleanup must not be combined with or used to widen the production logic correction.

The dedicated Sage test vendor may remain as an inert test contact unless separately removed by an explicitly authorised operational action.

## 10. Scope lock

Implementation must follow this amendment exactly.

No scope creep is authorised.

The production correction is:

```text
delete the Supplier Goods AP all-zero omission block
replace it with nothing
change nothing else
```
