# Command Centres and Sage Cloud Accounting Contract v5

## Status

This contract supersedes `COMMAND_CENTRES_AND_SAGE_CLOUD_ACCOUNTING_CONTRACT_v4.md` for the command-centre model, Sage mapping model, posting-lane model, and route from platform readiness to Sage Cloud Accounting v3.1 posting.

Version 4 correctly locked the two-cockpit structure:

1. Supervisor Command Centre = operational source-of-truth cockpit from order to clean delivery and accounting handoff.
2. Accounting Command Centre = Sage/accounting cockpit from approved facts to Sage Cloud Accounting v3.1 posting.

Version 5 keeps that structure but corrects the accounting lane model:

- supplier/retailer goods AP is now an official Accounting Command Centre lane.
- customer/supplier/shipper Sage contact mapping is separate from GL/tax mapping.
- live posting batches must be lane-specific, not mixed AR/AP batches.
- AP uses one Sage purchase-invoice adapter pattern, but remains split by platform lane.

This is a controlled update, not permission to create page sprawl.

## Non-negotiable rule

- No Sage posting controls in the Supervisor Command Centre.
- No operational exception resolution inside the Accounting Command Centre.
- No new top-level accounting/control page unless it is a true audit/detail/diagnostic page and cannot be a tab/filter/modal inside one of the two command centres.
- Sage is an execution target, not the platform source of truth.
- All Sage posting must be server-side, batch-driven, idempotent, based on frozen/revalidated snapshots, and confirmed by Sage object ids before the platform marks anything posted.
- No mixed live posting batch across AR and AP.
- No mixed live posting batch across `supplier_goods_ap` and `shipper_ap` until both lanes have been proven separately.
- OCR/manual invoice extraction must not choose Sage contact ids, ledger ids, or tax ids directly.
- OCR/manual invoice extraction matches platform records first; saved Sage mappings supply the Sage ids.
- Accounting Command Centre must not accept fresh AP invoice uploads as a shortcut to Sage posting.
- Sage AP document attachment, where supported, may use only approved/current source invoice evidence already linked to the frozen AP snapshot.
- Supplier/retailer AP gross values are VAT-inclusive unless a source document is explicitly approved as VAT-exclusive.
- The Sage AP adapter must never treat a VAT-inclusive retailer gross value as a net value and then add VAT again.

## Two-cockpit model

### 1. Supervisor Command Centre

Primary route:

- `/internal/supervisor-command-centre`

Purpose:

The Supervisor Command Centre is the operational cockpit. It owns operational readiness into accounting. It does not post to Sage and must not duplicate Accounting Command Centre controls.

Minimum supervisor grid lanes:

- Order ref
- Importer
- Retailer
- Destination / country lane
- Shipper / batch
- Age / SLA
- Funding
- DVA/card
- Supplier goods invoice
- Exceptions / holds
- Operator/importer tasks
- Tracking / package
- Shipper receipt / allocation
- Customer confirmation / pro forma
- Customer sales / AR readiness
- Supplier goods AP readiness
- Shipper AP / shipping readiness
- Export evidence / delivery / POD
- Accounting handoff
- Next owner
- Next action

Lane statuses should be compact chips:

- clean
- in progress
- blocked
- waiting external
- ready for accounting
- not reached
- not applicable

### 2. Accounting Command Centre

Primary route:

- `/internal/accounting-command-centre`

Purpose:

The Accounting Command Centre is the Sage/accounting cockpit. It consumes approved readiness facts from Supervisor-controlled lanes.

It owns:

- Sage connection/OAuth state
- Sage business/tenant selection
- Sage party/contact mappings
- Sage GL/ledger/tax/bank mappings
- read-only Sage catalogue discovery
- snapshot freeze
- snapshot revalidation
- posting batch creation
- Sage Cloud Accounting v3.1 API posting
- posting failure/retry handling
- correction/reversal routes
- audit trail

It must not own:

- operational exception resolution
- shipper receipt approval
- DVA investigation workflow
- invoice OCR correction
- customer confirmation chasing
- manual operational status patching
- fresh AP invoice evidence upload for posting bypass

## Official accounting document lanes

Accounting Command Centre must use these posting lanes.

### 1. `customer_sales`

Purpose:

- Customer/importer sales invoice posting.

Sage object:

- Sales invoice.

Required mapping:

- platform importer/customer -> Sage customer contact id.
- customer sales ledger/nominal account id.
- customer sales VAT/tax rate id.
- currency from connected Sage business or approved payload.

### 2. `supplier_goods_ap`

Purpose:

- Retailer/supplier goods purchase invoice posting.

Sage object:

- Purchase invoice.

Source examples:

- approved supplier invoice from supplier reconciliation / supplier draft-ready.
- clean/coded supplier invoice lines.
- approved supplier credit/refund treatment where relevant.

Required mapping:

- platform retailer/supplier -> Sage supplier contact id.
- supplier goods AP / COGS / purchases ledger account id.
- supplier goods AP VAT/tax rate id.
- invoice reference/idempotency rule.

This lane is mandatory before retailer/supplier invoices can be posted to Sage. It must not be hidden inside `shipper_ap`.

### 3. `shipper_ap`

Purpose:

- Shipper/logistics/freight AP purchase invoice posting.

Sage object:

- Purchase invoice.

Required mapping:

- platform shipper -> Sage supplier contact id.
- freight/delivery/carriage AP ledger account id.
- shipper AP VAT/tax rate id.
- invoice reference/idempotency rule.

### AP adapter rule

`supplier_goods_ap` and `shipper_ap` are both AP and may share the same server-side Sage adapter function, for example `createSagePurchaseInvoice()`.

But they must remain separate platform lanes and separate posting batches until both are proven independently.

### AP VAT-inclusive amount rule

Retailer/supplier invoices in `supplier_goods_ap` are treated as VAT-inclusive gross invoices unless the approved source document explicitly proves a VAT-exclusive treatment.

The platform must preserve all three values in frozen AP snapshots and Sage payload validation:

- gross amount including VAT;
- net amount excluding VAT;
- VAT amount.

The default calculation for UK 20% VAT is:

```text
net = round(gross / 1.20, 2)
vat = round(gross - net, 2)
gross = net + vat
```

Example:

```text
Retailer invoice gross: £199.99
VAT rate: 20%
Net: £166.66
VAT: £33.33
Gross: £199.99
```

The Sage AP adapter must post the purchase invoice so Sage records the economic invoice as £199.99 gross, not £199.99 net plus extra VAT.

Dry-run validation for `supplier_goods_ap` must fail or block if:

- gross, net and VAT do not reconcile within permitted rounding tolerance;
- the Sage payload builder cannot clearly represent the purchase invoice as VAT-inclusive or as a net-plus-tax payload that still totals to the approved gross;
- the AP tax-rate mapping is missing;
- the frozen payload omits net/VAT/gross fields.

### AP invoice source evidence and Sage attachment rule

AP posting must distinguish between two different concepts:

1. Source invoice evidence upload.
2. Sage posting attachment.

Source invoice evidence upload belongs upstream in the operational lanes:

- Retailer/supplier goods AP invoice evidence is uploaded through the importer/operator supplier invoice flow and stored against `supplier_invoices`.
- Shipper AP/freight invoice evidence is uploaded through the shipper document/shipping-control flow and stored against the relevant shipping/shipper document record.

Accounting Command Centre must not accept a fresh AP invoice upload as a shortcut to posting.

At posting time, Accounting Command Centre may only use approved/current source invoice evidence already linked to the frozen AP snapshot.

For AP posting batches, each row must show:

- source invoice/document file
- source invoice/document approval state
- OCR/review state where applicable
- coding/apportionment approval state
- attachment-to-Sage state
- Sage object id after posting
- attachment upload result/error where supported

If Sage file attachment is supported for the target Sage purchase-invoice document, the posting adapter may attach the approved source invoice file to the created Sage AP document only after Sage returns the confirmed purchase-invoice object id.

If Sage attachment is unavailable or fails, the platform must still retain the invoice evidence internally and record the Sage posting reference, attachment failure reason and retry status.

The Sage posting itself must not be marked failed solely because optional document attachment failed, unless the tenant has explicitly configured Sage attachment as mandatory for that AP lane.

## Sage party mapping versus GL/tax mapping

### Party/contact mapping

Party mapping answers:

- Which Sage contact does this platform party post to?

Required party mappings:

- importer/customer -> Sage customer contact id.
- retailer/supplier -> Sage supplier contact id.
- shipper -> Sage supplier contact id.

Suggested canonical object:

- `sage_party_mappings`

Minimum fields:

- id
- platform_party_type: `importer_customer`, `retailer_supplier`, `shipper`
- platform_party_id
- platform_party_display_name
- sage_connection_id
- sage_business_id / sage_business_row_id
- sage_contact_id
- sage_contact_display_name
- sage_contact_reference
- sage_contact_type: `customer`, `supplier`, or `customer_supplier` where Sage supports it
- active
- verified_at
- verified_by_staff_id
- notes
- created_at
- updated_at

### GL/tax/bank mapping

GL/tax/bank mapping answers:

- Which Sage nominal/ledger/tax/bank object should this posting lane use?

Required mapping groups:

- `customer_sales`
  - sales income ledger id
  - customer sales VAT/tax rate id
- `supplier_goods_ap`
  - goods AP / COGS / purchases ledger id
  - supplier goods AP VAT/tax rate id
- `shipper_ap`
  - freight/delivery/carriage ledger id
  - shipper AP VAT/tax rate id
- later receipt/payment/credit flows
  - bank account id
  - credit note ledger/tax mappings
  - FX/residual mappings

Hard distinction:

- Sage contact ids are not GLs.
- VAT/tax rate ids are not VAT ledger/control accounts.
- Bank account ids are not always the same as nominal ledger ids and must be handled according to the Sage endpoint being used.

## OCR and supplier matching rule

OCR extracts invoice facts only:

- supplier name
- invoice reference
- invoice date
- totals
- VAT/tax amounts where present
- lines/descriptions
- document type

OCR must not decide Sage posting ids.

The correct chain is:

1. OCR/manual extraction identifies the platform source document.
2. Platform matching resolves the known retailer/supplier/shipper/customer record already set up in the database.
3. Sage party mapping supplies the Sage contact id.
4. Sage GL/tax mapping supplies ledger and tax ids.
5. Payload resolver builds the frozen Sage payload.
6. Dry-run validates it.
7. Posting adapter posts only after validation and final revalidation.

## Batch model

### Batch separation rule

Live posting batches must be lane-specific:

- Customer sales batch = `customer_sales` rows only.
- Supplier goods AP batch = `supplier_goods_ap` rows only.
- Shipper AP batch = `shipper_ap` rows only.

Existing historical mixed local batches can remain as audit/history. They must not be used as the model for live posting.

### Accounting Command Centre batch actions

Accounting Command Centre should expose separate actions/filters:

- Create customer sales batch.
- Create supplier goods AP batch.
- Create shipper AP batch.

The page may also show aggregate history, but posting controls must not imply one mixed AR/AP post.

### Batch detail grids

A `customer_sales` batch detail must show an AR payload grid:

- platform customer/importer
- Sage customer contact id/display
- invoice date
- due date
- reference
- sales ledger id/display
- tax rate id/display
- line description
- quantity
- unit price
- net/VAT/gross where applicable
- currency
- payload hash
- idempotency key
- Sage object id after posting

A `supplier_goods_ap` batch detail must show an AP goods payload grid:

- platform retailer/supplier
- Sage supplier contact id/display
- supplier invoice ref
- invoice date
- goods AP / COGS ledger id/display
- tax rate id/display
- line description
- quantity
- unit price / line amount
- net/VAT/gross where applicable
- source supplier invoice id
- source supplier invoice file/evidence link
- source supplier invoice approval state
- VAT-inclusive gross control status
- Sage attachment state/result where supported
- payload hash
- idempotency key
- Sage object id after posting

A `shipper_ap` batch detail must show an AP logistics payload grid:

- platform shipper
- Sage supplier contact id/display
- shipper invoice ref
- invoice date
- freight/delivery/carriage ledger id/display
- tax rate id/display
- shipment batch / shipping document reference
- apportionment summary where relevant
- net/VAT/gross where applicable
- source shipper invoice/document file/evidence link
- source shipper invoice/document approval state
- Sage attachment state/result where supported
- payload hash
- idempotency key
- Sage object id after posting

## Process graph and handoff

The system is a controlled process graph, not a rigid straight line.

- Linear only where a true dependency exists.
- Parallel where lanes can progress independently.
- Exceptions route the item back into the correct lane, not always back to the whole order.
- Customer sales, supplier goods AP, and shipper AP can split.
- A main customer goods invoice may become accounting-ready before supplier goods AP or shipper AP is ready.
- Supplier goods AP follows when supplier invoice reconciliation/coding/current approval is controlled.
- Shipper AP follows when shipper invoice/receipt, apportionment and shipping evidence are controlled.

Supervisor sees accounting status as read-only handoff outcome:

- awaiting accounting
- frozen
- validated
- ready to post
- posted
- failed
- correction required

## Accounting Command Centre sections

Accounting Command Centre sections/tabs:

1. Live ready
2. Frozen snapshots
3. Posting batches
4. Sage connection/settings
5. Sage party mappings
6. Sage GL/tax/bank mappings
7. Read-only Sage catalogue discovery
8. Posting results/failures
9. Corrections/reversals

`/internal/sage-mapping` may remain as a diagnostic or settings detail page, but it must not become a third daily command centre. Daily control stays in Accounting Command Centre.

## Sage Cloud Accounting v3.1 build path from current state

### Phase 1 — v5 contract lock

- Lock this v5 contract.
- Treat v4 as superseded for the accounting lane model.
- Keep the two command centres.

### Phase 2 — Sage catalogue discovery hardening

- Keep the read-only Sage API catalogue check.
- Use it to inspect contacts, ledger accounts, tax rates, bank accounts, and currencies where available.
- Treat `/currencies` failure as non-blocking where the connected Sage business currency is known and the payload is GBP.
- Do not save mappings automatically from catalogue discovery.

### Phase 3 — Sage party mapping

Add DB and UI for:

- importer/customer -> Sage customer contact
- retailer/supplier -> Sage supplier contact
- shipper -> Sage supplier contact

Admin must be able to view platform parties and select/save exact Sage contact ids returned by catalogue discovery.

### Phase 4 — GL/tax mapping completion

Complete mappings for:

- `customer_sales`
- `supplier_goods_ap`
- `shipper_ap`

The mapping UI must make the distinction between:

- Sage contact
- Sage ledger account
- Sage tax rate
- Sage bank account

### Phase 5 — Add `supplier_goods_ap` to Accounting Command Centre live-ready queue

Add supplier/retailer goods invoices from supplier reconciliation / supplier draft-ready into Accounting Command Centre when:

- supplier invoice is approved current.
- relevant lines are coded/progressed/clean.
- duplicate/exception/credit-note blockers are cleared or routed.
- retailer/supplier platform party is resolved.
- Sage supplier contact mapping exists.
- supplier goods AP ledger mapping exists.
- supplier goods AP tax mapping exists.
- approved source invoice evidence exists and is linked to the source supplier invoice record.
- VAT-inclusive gross has been split into reconciled net/VAT/gross amounts for the approved VAT rate.

### Phase 6 — Lane-specific freeze and revalidation

Frozen snapshots must preserve:

- lane
- source document id
- source party id
- source invoice/document evidence reference where applicable
- Sage contact mapping snapshot
- Sage GL/tax mapping snapshot
- payload facts
- VAT-inclusive control facts where applicable, including net, VAT, gross, VAT rate and rounding tolerance
- idempotency key
- mapping configured_at/verified_at values

Revalidation must fail or block if mapping changed after freeze and requires reapproval.

### Phase 7 — Lane-specific posting batch creation

Add batch creation actions:

- Create customer sales batch.
- Create supplier goods AP batch.
- Create shipper AP batch.

Rules:

- Revalidate before batch creation.
- Include only `ok_to_post` snapshots.
- Exclude blocked/stale rows.
- Warnings excluded unless explicitly included.
- Lock rows to batch.
- No mixed live posting batch across lanes.

### Phase 8 — Lane-specific dry-run payload validation

Dry-run must validate per lane:

`customer_sales`:

- active Sage connection
- selected Sage business
- Sage customer contact id exists/resolves
- sales ledger mapping exists
- tax rate mapping exists
- required invoice fields present
- amounts balance
- reference/idempotency key valid
- no duplicate posted idempotency key

`supplier_goods_ap`:

- active Sage connection
- selected Sage business
- Sage supplier contact id exists/resolves
- goods AP ledger mapping exists
- AP tax rate mapping exists
- approved/coded supplier invoice source still valid
- source supplier invoice evidence still available internally
- gross, net and VAT amounts reconcile within permitted rounding tolerance
- VAT-inclusive retailer gross is not treated as Sage net input unless the adapter explicitly converts it back to a Sage-safe net/tax payload that totals to the approved gross
- amounts balance
- supplier invoice reference/idempotency key valid
- no duplicate posted idempotency key

`shipper_ap`:

- active Sage connection
- selected Sage business
- Sage supplier contact id exists/resolves
- freight/delivery ledger mapping exists
- AP tax rate mapping exists
- approved shipper AP source still valid
- source shipper invoice/document evidence still available internally
- apportionment/source summary present where needed
- amounts balance
- shipper invoice reference/idempotency key valid
- no duplicate posted idempotency key

### Phase 9 — Actual Sage posting order

Only after dry-run is proven:

1. Post `customer_sales` first.
2. Post `supplier_goods_ap` second.
3. Post `shipper_ap` third.

Reason:

- Customer sales proves AR posting and customer contact mapping.
- Supplier goods AP is the missing goods purchase invoice lane and must be proven before treating the accounting picture as complete.
- Shipper AP is also AP, but logistics/apportionment/evidence controls are separate and should be proven after goods AP.

### Phase 10 — Shared Sage AP adapter

`createSagePurchaseInvoice()` may serve both:

- `supplier_goods_ap`
- `shipper_ap`

But payload builder and validation must remain lane-specific.

If Sage attachment support is implemented, AP attachment handling may be shared behind the adapter, but it must still receive lane-specific source evidence metadata from the frozen snapshot.

The shared AP adapter must receive explicit net, VAT, gross and VAT-rate inputs. It must not infer VAT treatment only from the line gross field name or from Sage tax-rate mapping.

### Phase 11 — Failure, retry and correction

Inside Accounting Command Centre -> Posting results/failures:

Actions:

- Retry failed only.
- Retry attachment only where the Sage AP posting succeeded but optional attachment failed.
- Open failure detail.
- Mark terminal.
- Create correction route.
- Export failure CSV.

Correction rules:

- Posted snapshots are immutable.
- Do not edit posted payloads.
- Do not overwrite Sage ids.
- Corrections require a new correction snapshot.
- Credit note/reversal links back to original.

### Phase 12 — Later cash, payment, credit and allocation flows

Only after invoice posting is proven:

- customer receipts
- supplier payments
- bank allocations
- contact allocations
- credit notes
- refunds
- FX/card residuals
- VAT adjustments

Cash/payment/allocation flows are more dangerous than invoice posting and must not be rushed.

## Implementation discipline

Before each build step:

1. Check this v5 contract.
2. Check existing governing pack / matrices / role contracts.
3. Check live DB schema/functions/views/RLS.
4. Check current repo files.
5. Patch surgically.
6. Confirm Vercel deployment READY.
7. Test exact target order/document/batch.

No guessing. If the contract, DB or repo does not confirm an assumption, inspect first.
