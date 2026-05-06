# Exception refund / replacement route contract v1

## Purpose

This contract prevents drift between invoice/commercial exceptions, physical-goods exceptions, replacement/repurchase child orders, refund/credit-note evidence, and DVA/card refund matching.

It applies to multi-tenant and multi-jurisdiction corridors. Do not hardcode country names such as Ghana into exception source or status logic. Use generic source/stage labels and let the tenant/corridor provide country context.

## Non-negotiable principle

Exception source decides where the journey starts.
Supervisor controls whether the operator is allowed to act.
Operator acts only after supervisor approval/push.
Supervisor approves or rejects the final retailer outcome.

## Role boundary

### Operator

Operators may:

- Raise invoice/commercial exceptions from OCR/manual invoice reconciliation lines.
- Contact the retailer only after supervisor approval/push.
- Upload retailer replies, credit notes, return/collection evidence, refund evidence, replacement evidence, invoice evidence and tracking where the approved path requires it.
- Continue normal invoice/tracking/reconciliation work for approved replacement/repurchase child orders.

Operators must not:

- Final-approve refund, replacement, not-charged, repurchase, credit-note, or financial outcome decisions.
- Create a replacement/repurchase child order without supervisor approval.
- Bypass supervisor review on physical-goods issues raised by importer or shipper.

### Supervisor / staff

Supervisors may:

- Review exception initiation and source evidence.
- Check DVA/card/bank/statement context where relevant.
- Approve, reject, hold, query, or push an exception to the operator.
- Approve final retailer outcome.
- Approve replacement/repurchase child-order creation.
- Confirm no refund expected / not charged / credit decision.
- Review credit-note evidence and decide whether it supports the exception route.

Supervisors must not normally upload retailer credit notes or retailer operational evidence. That is the operator execution lane after approval/push. Supervisor upload should be exceptional/admin-only, not the normal path.

### Importer / end customer

The importer/end customer is separate from the operator role.

Importers may:

- Review final pro forma / final item position.
- Select/query items they dispute or want refunded/replaced.

Importer selections do not directly become operator action. They go to supervisor first.

### Shipper / warehouse

Shippers may:

- Raise physical intake/delivery discrepancies from the shipper lane.

Shipper-raised physical exceptions go to supervisor first. Supervisor reviews/checks and only then pushes the approved path to the operator.

## Source classes

Use generic source/stage labels:

- `invoice_reconciliation`
- `importer_final_review`
- `shipper_origin_intake`
- `shipper_destination_delivery`
- `manual_supervisor_review`

Do not use country-specific source names such as `ghana_delivery_issue`.

## Route families

### 1. Invoice/commercial exception initiated by operator

Start:

- Operator is reconciling OCR/manual supplier invoice lines.
- OCR/manual lines can be turned into exception cases.

Flow:

1. Operator raises exception from reconciliation line.
2. Supervisor reviews the exception.
3. For invoice/commercial exceptions, supervisor checks DVA/card/bank/statement context where relevant.
4. Supervisor approves, rejects, holds, or queries.
5. If approved, exception is pushed to operator to contact retailer.
6. Operator records retailer response and uploads retailer evidence/outcome.
7. Supervisor approves or rejects final outcome.
8. Route continues depending on outcome: refund/credit note, replacement/repurchase child order, not charged/no refund expected, or closure.

### 2. Physical exception initiated by importer final review

Start:

- Final pro forma / final item position is presented to importer/end customer.
- Importer selects item(s) requiring refund/replacement/query.

Flow:

1. Importer selection creates/queues a physical/commercial exception for supervisor review.
2. Supervisor reviews and approves/rejects/holds.
3. If approved, supervisor pushes to operator.
4. Operator contacts retailer and records response/evidence.
5. Supervisor approves or rejects final retailer outcome.
6. Route continues depending on outcome: refund/credit note, replacement/repurchase child order, not charged/no refund expected, or closure.

### 3. Physical exception initiated by shipper/warehouse

Start:

- Shipper/warehouse raises discrepancy at origin intake or destination delivery stage.

Flow:

1. Shipper raises discrepancy.
2. Supervisor reviews/checks evidence and operational context.
3. Supervisor approves/rejects/holds/query.
4. If approved, supervisor pushes to operator.
5. Operator contacts retailer and records response/evidence.
6. Supervisor approves or rejects final retailer outcome.
7. Route continues depending on outcome: refund/credit note, replacement/repurchase child order, not charged/no refund expected, or closure.

## Outcome routes

### Replacement / repurchase: new goods coming in

Use when new goods are expected to come in.

Flow:

1. Supervisor approves replacement/repurchase.
2. System creates `orders.order_type = 'replacement_child'`.
3. Child order links to parent order via `orders.parent_order_id`.
4. Dispute links to child order via `disputes.replacement_child_order_id` where applicable.
5. Operator uses the normal order operations lane for the child order:
   - upload replacement/repurchase invoice/evidence;
   - add tracking;
   - Mindee/OCR where applicable;
   - invoice reconciliation;
   - DVA/card OUT matching if charged.
6. Do not create a duplicate replacement-only invoice/tracking page inside the exception page.

Important: parent dispute status `replaced` means the replacement route was accepted and child order created. It does not mean the child order is financially/operationally complete.

### Refund / supplier credit note: money coming back

Use when the original supplier invoice charged the item and retailer issues refund/credit note or accepts refund route.

Flow:

1. Supervisor approves the route and pushes to operator where operator action is required.
2. Operator contacts retailer.
3. Operator uploads credit note/evidence on the operator exception lane, not the supervisor lane.
4. Operator captures:
   - credit note reference;
   - credit note file upload;
   - negative quantity and negative amount lines;
   - optional delivery/discount adjustments;
   - optional return/collection evidence.
5. Evidence must link to:
   - original order;
   - original supplier invoice;
   - dispute/exception;
   - affected lines where available.
6. Supervisor reviews and approves/rejects/holds credit-note evidence.
7. Refund IN is later matched in DVA/card workspace to the refund exception.
8. Sage supplier credit-note payload comes later from structured credit-note data, not from casual notes.

For MVP, credit-note evidence may be stored as structured evidence messages only if no credit-note table exists yet. Before Sage automation, create structured supplier credit note and supplier credit note line tables or equivalent structured source.

### Not charged / no refund expected

Use when the retailer did not charge for the item or the item is missing from supplier invoice and no refund IN is expected.

Flow:

1. Supervisor reviews DVA/card/bank/statement and invoice context where relevant.
2. Supervisor closes as not charged / no refund expected, or makes a credit decision.
3. No refund IN should be awaited.
4. If new goods still need to be bought, supervisor may approve repurchase and create a replacement/repurchase child order.

## Status integrity

Statuses must reflect control gates, not merely UI convenience.

Minimum gate logic:

- Initiated by source event.
- Awaiting supervisor review.
- Supervisor approved/pushed to operator, or rejected/held.
- Operator action in progress.
- Retailer outcome received.
- Supervisor final outcome approved/rejected.
- Child order created for replacement/repurchase, or credit-note/refund path awaiting evidence/refund IN, or not-charged closure.

Do not let operator-uploaded evidence equal supervisor approval.
Do not let parent `replaced` equal child order completion.
Do not let refund accepted equal refund IN matched.
Do not treat importer funding IN and retailer refund IN as the same money type.

## Page placement

### Operator/importer pages

Operator pages handle execution after supervisor approval/push:

- upload credit note/evidence;
- upload return/collection evidence;
- upload invoice/evidence for child order;
- add tracking;
- contact retailer and record retailer response.

### Internal/supervisor pages

Internal pages handle control:

- review exception source;
- approve/reject/hold/query;
- push to operator;
- approve/reject final retailer outcome;
- review credit-note evidence;
- approve child order creation;
- control DVA/card refund match readiness.

## Build discipline

Before coding:

1. Check governing pack/contracts/matrices.
2. Check live DB/Supabase objects and constraints if schema/status/RPC assumptions matter.
3. Check current repo file.
4. Patch surgically.
5. Avoid duplicate flows.
6. Reuse existing order operations, invoice upload, tracking, Mindee/OCR, reconciliation and DVA/card workspace where possible.
7. Confirm deployment READY.
8. Test the exact order/dispute/invoice/statement line.
