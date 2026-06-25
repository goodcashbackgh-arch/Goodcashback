# Completion Loyalty Sufficient-IN Pot Release Addendum v1

Status: locked addendum to the completion-loyalty bulk funding-pot contract.

This addendum updates the narrow bulk-release rule for matching one same-importer DVA/card IN line to a grouped loyalty funding pot.

It supersedes only the previous exact-IN-only bulk release assumption in:

1. `docs/governing-pack/ui/COMPLETION_LOYALTY_BULK_FUNDING_POT_AND_POSTING_CLARIFICATION_v1.md`
2. `docs/governing-pack/ui/COMPLETION_LOYALTY_MULTI_REWARD_OUT_RESERVATION_ADDENDUM_v1.md`
3. `supabase/migrations/20260625_harden_bulk_loyalty_pot_release_backend_gate_v1.sql`

All other accounting, VAT, Sage, customer-credit, and residual-control boundaries remain unchanged.

---

## 1. Accounting conclusion

Completion loyalty is a GBP credit entitlement. The loyalty funding-pairing step is a cash-backing control, not an FX recognition step.

Therefore, a DVA/card IN line does not need to exactly equal the selected loyalty pot total before bulk release, provided the IN line has enough remaining GBP-equivalent value to cover the selected same-importer loyalty pot.

The same principle already applies to the main-bank OUT side: the selected loyalty rewards may consume part of the OUT line, and any difference remains on the statement line for separate allocation/review. The IN side should be treated the same way.

---

## 2. Locked rule

For same-importer bulk loyalty release:

```text
Destination DVA/card IN remaining >= selected loyalty pot total
```

not:

```text
Destination DVA/card IN remaining must exactly equal selected loyalty pot total
```

The release consumes only:

```text
sum(selected main_bank_completion_loyalty_funding_matches.matched_gbp_amount)
```

Any excess on the DVA/card IN line remains as unconsumed statement-line balance.

---

## 3. No loyalty FX posting

The excess between DVA/card IN remaining and selected loyalty pot total is not automatically:

```text
- loyalty FX;
- bank fee;
- card fee;
- supplier FX;
- shipper FX;
- Sage posting variance.
```

It remains on the DVA/card statement line as available/unallocated balance until later consumed by another valid allocation or separately reviewed under the existing residual controls.

Actual FX/card/payment differences continue to be recognised only in the normal DVA/card or main-bank residual workflows when supplier, retailer refund, shipper, bank-fee, or other payment evidence creates a real variance.

---

## 4. Controls that must remain

The sufficient-IN relaxation must not weaken these controls:

```text
- selected rewards must all belong to one importer;
- selected rewards must all share one source main-bank OUT line;
- selected loyalty matches must be unpaired staged OUT rows;
- destination IN must belong to the same importer;
- destination IN must be an importer DVA/card/virtual-card account line;
- destination IN must be direction IN;
- destination IN remaining must be at least the selected loyalty pot total;
- selected source OUT must not be over-allocated after shipper, residual, and loyalty consumption;
- released credit remains one credit lot per reward/order for audit and future customer application.
```

---

## 5. UI rule

The bulk-pot UI may enable bulk release for:

```text
Exact pot
Strong pot where there is one same-importer sufficient IN candidate
```

The UI should keep review/multiple-candidate situations disabled or manual-review only.

Button and helper wording should avoid saying exact-only once sufficient-IN release is supported.

Suggested wording:

```text
Release selected IN for pot
```

and:

```text
Staff must review/select the same-importer DVA/card IN before grouped release. Exact and single strong sufficient-IN pots are bulk-enabled. Any excess remains on the DVA/card line; no loyalty FX is posted.
```

---

## 6. Example

```text
Main-bank OUT: £313.33
Selected loyalty rewards: £300.00
DVA/card IN remaining: £313.33
```

Allowed result:

```text
£300.00 loyalty pot released
£13.33 remains unconsumed on the OUT/IN statement lines, subject to later normal allocation/review
£0.00 loyalty FX posted
```

The applied-loyalty customer settlement lane remains unchanged. It still starts only when a released loyalty credit is later applied to an order and creates `order_funding_events.credit_applied`.

---

## 7. No-impact boundary

This addendum must not change:

```text
- applied-loyalty Sage materialisation;
- applied-loyalty Sage batch posting;
- VAT timing;
- customer sales invoice posting;
- supplier payment reconciliation;
- shipper AP matching/posting;
- DVA/card residual posting categories;
- main-bank residual posting categories;
- order funding threshold logic.
```
