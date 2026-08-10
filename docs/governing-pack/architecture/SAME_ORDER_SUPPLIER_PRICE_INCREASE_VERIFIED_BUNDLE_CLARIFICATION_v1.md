# Same-Order Supplier Price Increase — Superseded Draft Clarification

Status: **superseded / non-governing**

This file is retained only because it was created on the isolated development branch before the scope review.

Its former proposal to make a separately reconstructed “verified live supplier bundle” the commercial authority is **withdrawn**.

The governing source is now only:

```text
docs/governing-pack/architecture/SAME_ORDER_SUPPLIER_PRICE_INCREASE_ADDENDUM_v1.md
```

The corrected governing design preserves:

- the existing `order_bundle_limit_breach` flag as the entitlement/control authority;
- the existing `supplier_invoice_financial_summary.invoice_total_gbp` bundle arithmetic;
- the existing Supplier Invoice Review routing through the serious open flag;
- the existing header-save RPC unchanged;
- the existing supplier-approval RPC and shared readiness helper unchanged.

No “verified bundle” read model, custom review anchor, accepted-gross replacement hierarchy or global supplier-approval transition trigger is authorised by this file.
