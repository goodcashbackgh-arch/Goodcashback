# Shipper Customer Hold Hard Block Later Contract v1

Status: Later control enhancement. **Not built.**

Purpose: record the future hard-block required to prevent shippers from batching, consolidating, dispatching, or evidencing goods that are subject to an active customer hold or required customer pre-shipment approval. This contract deliberately preserves the current MVP control as an interim SOP/audit control and prevents the gap being forgotten.

## 1) Current built control

The current platform already supports the following MVP controls:

1. Customer can access a secure review link.
2. Customer can request a pre-shipment hold at order, package/tracking, or item/line level depending on what data exists.
3. Supervisor can approve, reject, resolve, or supersede the hold.
4. When supervisor approves the hold, the shipper can see an operational set-aside / do-not-ship instruction on the shipper side.
5. Customer sales invoice draft creation is blocked/skipped while an active customer hold exists.
6. The shipper instruction is intended to be supported by an SOP.

This current control is acceptable for a manual pilot with selected shippers, because the shipper is clearly instructed not to ship held goods and an audit trail exists.

## 2) Current known gap

The current platform does **not** yet hard-block shipper shipment batching for active customer holds.

Specifically, this is not yet built:

1. Active held orders/packages/items are not automatically excluded from `shipper_shipment_batch_candidates_v1()`.
2. `shipper_create_shipment_batch_v1(...)` does not yet raise a defensive error when a shipper selects a held order/package/item.
3. The shipper can therefore still batch a held package if they ignore or miss the visible set-aside instruction.

This is an accepted interim gap only while the business operates under manual SOP control.

## 3) Required future hard block

When this later control is built, the platform must enforce two layers:

### 3.1 Candidate-list prevention

`shipper_shipment_batch_candidates_v1()` must exclude packages/tracking refs/orders where an active customer hold applies.

A package/order/line must be treated as held when there is an active row in `customer_pre_shipment_hold_requests` with status in:

```text
requested
supervisor_approved
```

The candidate-list exclusion must cover all three scopes:

1. `order` scope — exclude every package/tracking ref for that order.
2. `tracking` scope — exclude that specific tracking/package ref.
3. `line` scope — exclude the affected package/tracking ref where the line is allocated to a package; where package-line mapping is unclear, block conservatively at order/package level until supervisor resolves the ambiguity.

### 3.2 RPC defensive rejection

`shipper_create_shipment_batch_v1(...)` must independently reject any selected tracking ref/package/order that is subject to an active hold.

This is required even if the UI already hides the package, because API/RPC enforcement is the real control.

Suggested error text:

```text
This order/package/item is under customer hold or awaiting supervisor clearance and cannot be added to a shipment batch.
```

## 4) What must not change

This future patch must not redesign the customer review flow.

It must not change:

1. Customer review link creation.
2. Customer hold submission.
3. Supervisor hold approval/rejection/resolution/supersession.
4. Existing invoice/Sage hold blockers.
5. Existing exception/refund/replacement/no-charge routes.
6. Existing shipment batches already created before the hard block is introduced, unless a separate migration/review explicitly handles historical batches.

## 5) Relationship to final invoice / credit-note avoidance

The platform strategy is to minimise avoidable customer sale credits by allowing customer review and hold before final customer sale documents are released and before physical shipment is completed.

Current MVP:

```text
Visible shipper hold instruction + SOP + invoice/Sage block
```

Future scaled control:

```text
Visible shipper hold instruction + SOP + invoice/Sage block + shipper batching hard block
```

## 6) SOP wording for interim control

Until the hard block is built, the SOP must state:

```text
Any order, package, tracking ref, or item shown in Customer Holds must not be batched, consolidated, dispatched, or included in shipment evidence until the hold is cleared by supervisor/admin.
```

The shipper should be treated as operationally responsible if they ship goods that were clearly shown as held.

## 7) Build acceptance tests for later

When implemented, tests must prove:

1. Order-level approved hold removes every package for that order from shipment candidates.
2. Tracking-level approved hold removes only that package/tracking ref unless ambiguity requires broader block.
3. Line-level approved hold blocks the affected allocated package or conservatively blocks the package/order where mapping is unclear.
4. Rejected/resolved/superseded holds do not block shipment candidates.
5. `shipper_create_shipment_batch_v1(...)` rejects held packages even if called directly with UUIDs.
6. Customer invoice draft creation continues to remain blocked while active holds exist.
7. Existing clean, unheld packages still flow normally.

## 8) Implementation status

Not built as at this contract version.

Do not represent this as an existing hard control in UI copy, investor materials, HMRC explanations, SOPs, or internal handovers. Describe current control as:

```text
Visible set-aside instruction with SOP and audit trail; system hard-block planned for later scale.
```
