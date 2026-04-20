# APP ENFORCED RULES

## Rule 1 — Funding completion
Backend/domain code must:
- sum valid order_funding lines
- add applied importer credit
- ignore exception-held lines
- if threshold reached:
  - stamp funded_at
  - move order to funded

## Rule 2 — Credit note before payout/reusable credit
Backend/domain code must block payout or reusable credit if:
- customer has already been invoiced
- and linked customer credit note does not exist
