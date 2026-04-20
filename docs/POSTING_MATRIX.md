# POSTING MATRIX

| Business Event | Internal Source | Sage Outcome | Notes |
|---|---|---|---|
| Customer funding confirmed | DVA reconciliation | AR receipt / prepayment | Created when funding becomes valid |
| Released subset billed | Sales invoice intent | AR invoice | Only released subset |
| Post-invoice refund approved | Credit note intent | AR credit note | Must exist before payout/reusable credit |
| Prepayment application | Prepayment application intent | Apply receipt to invoice | Can be partial |
| FX difference | Funding / settlement difference | FX journal | Exact route to confirm |
| Shipper liability settlement | Shipper liability | Offset or settlement entry | Exact route to confirm |
