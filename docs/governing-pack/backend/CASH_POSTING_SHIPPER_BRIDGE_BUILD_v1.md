# Cash Posting Shipper Bridge Build v1

Status: build note.

The cash OUT Sage poster already supports `shipper_invoice_payment` through the same vendor-payment route as supplier OUT.

Required bridge shape for shipper cash rows:

- `source_type = shipper_ap_cash_bridge`
- `posting_category = shipper_invoice_payment`
- `counterparty_type = shipper`
- confirmed shipper AP source id
- DVA/card statement line id
- Sage shipper supplier contact id
- DVA cash Sage bank account id
- posted Sage purchase invoice id from the shipper AP snapshot
- amount from the confirmed DVA/card allocation or shipper AP cash bridge

Sage posting route:

```text
POST /contact_payments
transaction_type_id = VENDOR_PAYMENT
allocated_artefacts[] -> posted Sage shipper purchase invoice id
```

Do not force shipper AP through `supplier_invoice_id`.
