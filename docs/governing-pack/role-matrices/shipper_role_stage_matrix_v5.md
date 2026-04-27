# shipper_role_stage_matrix_v5

## Page 1

SHIPPER END-TO-END ROLE-STAGE MATRIX
Multi Tenant Platform Build - canonical shipper flow from ready-for-shipment handoff through delivery in Ghana
Revision 5 - aligned to the live schema/control model, child-exception governance, and the AI-assisted retailer
exception architecture
Purpose.
This version supersedes earlier shipper documents. It keeps the explicit ready-for-shipment handoff,
makes clear that the shipper only handles the progressed subset, and shows where the shipper is not part of the
normal retailer AI loop but does enter the exception path when liability becomes shipper-side.
Role definition
The shipper is the downstream logistics actor.
The shipper does not create importer orders, does not upload
DVA/card statements, does not set FX, does not operate the importer OCR reconciliation workspace, and is not the
normal actor for retailer-facing AI drafted messages. The shipper receives the progressed subset only after the
internal ready-for-shipment handoff, monitors inbound parcels using the importer's courier/tracking context, handles
UK receipt/intake, booking, dispatch, shipment progression, POD, and delivery in Ghana, and participates in disputes
only where the facts point to shipper liability or shipper evidence.
Locked architecture, schema, and control assumptions used here

Importer creates the order, uploads multiple retailer screenshots, later submits tracking and/or retailer invoice
evidence in either order, and operates the OCR reconciliation workspace.

Supervisor and admin are staff for DVA upload, funding reconciliation, credit application, approval gates, and
governance.

Correct invoice lines may progress while unresolved lines become child exceptions. The parent order is only fully
cleared once progressed lines plus resolved children reconcile back to the original parent baseline.

The explicit ready-for-shipment handoff remains a distinct stage: funded and progressed work becomes shipper-
actionable only after internal purchasing/reconciliation has yielded a progressed subset ready for logistics.

The live schema already includes orders.shipper_id, shipping_quotes, shipping_quote_orders, couriers,
order_tracking_submissions, booking_ref, BOL/certificate/commercial invoice/POD fields, Ghana delivery markers,
disputes, and shipper_liabilities.

Retailer exception handling uses a server-side AI drafting service with SOP-aware prompts, but the normal retailer
communication loop is operated from the importer/operator side, not by the shipper.

Where a child exception remains open, the shipper must not absorb that unresolved quantity/value into shipment
allocation just because other lines progressed.
Shipper operating boundary
Boundary
Detail
Shipper does
See only their own shipper queue; use courier/tracking
context to anticipate inbound retailer parcels; receive
and intake the progressed subset; create/update
bookings; upload shipment evidence; dispatch; track
ETA/SLA; upload POD; mark Ghana delivery; respond
to disputes where liable_party = shipper; maintain
shipper-side evidence and liability responses.
Shipper does not
Create importer orders; upload DVA statements; fund
orders; edit OCR lines; create/delete manual exception
lines; select refund/replacement remedy for retailer-side
exceptions; bypass the ready-for-shipment handoff; act
as the normal retailer AI-communication user; approve

## Page 2

Boundary
Detail
refunds or accounting postings.
Key control
The shipper only handles the progressed subset. Open
child exceptions stay separate and must not be silently
mixed into shipment allocation or delivery completion.
Stage 1 - Shipper account presence and visibility scope
Role
Shipper / shipper user
Allowed action
Access the shipper portal and view only the
orders/shipments/disputes allocated to that shipper.
Resource(s) / system(s) used
Next.js/Vercel shipper portal; Supabase shipper-user
auth and RLS; orders.shipper_id and shipper-scoped
read policies.
Data touched
Shipper user auth mapping, shipper identity, shipper
queue visibility over orders, shipping quotes, and later
shipper-linked disputes/liabilities.
Validation rules
Shipper user must map to the correct shipper and see
only that shipper's data.
State transition
Shipper user becomes eligible to monitor shipper-
actionable work.
Next actor
Shipper
Exception path
If the shipper mapping is wrong, the user could see the
wrong queue or miss their own queue. Fix access
before live use.
Stage 2 - See the explicit ready-for-shipment handoff
Role
Shipper / shipper user
Allowed action
View only orders/line subsets that have already been
funded, reconciled, and explicitly marked ready for
shipment by the upstream internal process.
Resource(s) / system(s) used
Shipper portal; Supabase orders,
shipping_quote_orders, progress views/read models.
Data touched
orders.shipper_id, funded/progressed readiness
indicators, shipment allocation readiness, child-
exception visibility flags.
Validation rules
The shipper must not treat funded-but-not-progressed
work as actionable. The handoff is explicit: only the
progressed subset enters the shipper lane.
State transition
Work becomes shipper-actionable without waiting for all
child exceptions to close, provided the progressed
subset is clearly defined.
Next actor
Shipper
Exception path
If unresolved child quantity/value is mixed into the
actionable subset, the handoff is wrong and must be
corrected upstream.
Stage 3 - Use courier/tracking context to anticipate inbound retailer parcels
Role
Shipper / shipper user
Allowed action
Read the importer-submitted courier, tracking
reference, and tracking date to know which courier
site/template to use and when to expect parcel arrival at
the UK side.

## Page 3

Resource(s) / system(s) used
Shipper portal; Supabase order_tracking_submissions;
couriers lookup with tracking URL template.
Data touched
order_tracking_submissions.courier_id, tracking_ref,
tracking_date, optional screenshot, active vs
superseded submission history.
Validation rules
Courier is mandatory. The shipper reads this context
but does not create the importer's tracking submission
in the normal flow.
State transition
Shipper gains parcel-anticipation visibility before or after
invoice timing.
Next actor
Shipper
Exception path
Wrong courier, wrong tracking ref, or stale superseded
submission makes the ETA unreliable and should be
corrected before relying on it.
Stage 4 - Receive and intake the progressed subset at the UK side
Role
Shipper / shipper user
Allowed action
Receive physical goods/parcels at the UK side and
record what arrived, in what condition, and whether the
progressed subset matches expectation.
Resource(s) / system(s) used
Shipper portal; evidence uploads; shipment/intake
screens; Supabase receipt-related status fields and
notes.
Data touched
Receipt status, intake notes, condition notes/images,
partial/damaged/not-arrived evidence.
Validation rules
Only the progressed subset should be handled. Intake
evidence must preserve auditability and not rewrite
upstream truth.
State transition
Goods move from expected inbound to received /
partially received / damaged / missing at the UK side.
Next actor
Shipper and internal staff
Exception path
If goods do not arrive or arrive damaged/partial, the
exception path begins immediately and later liability
may fall on retailer, shipper, or unknown depending on
the facts.
Stage 5 - Create or update the shipment booking
Role
Shipper / shipper user
Allowed action
Create the shipping booking/consignment and attach
the progressed orders/lines that are actually moving to
Ghana.
Resource(s) / system(s) used
Shipper portal; Supabase shipping_quotes and
shipping_quote_orders; courier lookup; internal
apportionment records.
Data touched
shipping_quotes.quote_gbp_total, booking_ref,
courier_id, status, shipping_quote_orders.order_id,
apportionment_pct, apportioned_shipping_gbp.
Validation rules
Only progressed/eligible quantity/value should be
attached. Open child exceptions must not be smuggled
into the shipment just because they belong to the same
parent order.
State transition
A booking exists and the shipment plan becomes
concrete and auditable.
Next actor
Shipper

## Page 4

Exception path
Wrong order allocation, wrong courier, or contamination
by unresolved child exceptions must be corrected
before dispatch.
Stage 6 - Upload shipment evidence and dispatch details
Role
Shipper / shipper user
Allowed action
Upload booking and dispatch artefacts, then move the
shipment from draft/confirmed into dispatched when it
really leaves the UK side.
Resource(s) / system(s) used
Shipper portal; Supabase shipping_quotes; storage;
image compression where images are uploaded.
Data touched
booking_ref, bol_url, cert_of_shipment_url,
commercial_invoice_url, dispatched_at, status,
estimated_ghana_arrival_at.
Validation rules
Evidence must be attached to the correct shipment.
Dispatch must not be stamped before actual dispatch.
State transition
Shipment becomes visible as in transit to Ghana.
Next actor
Shipper and importer (visibility); supervisor monitors
Exception path
Weak or missing evidence damages later dispute
defence. False dispatch stamping corrupts ETA/SLA
monitoring.
Stage 7 - In-transit monitoring and SLA discipline
Role
Shipper / shipper user
Allowed action
Maintain shipment progress while the consignment is
en route and keep ETA/SLA information current.
Resource(s) / system(s) used
Shipper portal; Supabase shipping_quotes status and
ETA fields; importer-facing tracking views consume the
result.
Data touched
shipping_quotes.status, estimated_ghana_arrival_at,
sla_dispatch_target_date, sla_breach_flag,
sla_breach_reason.
Validation rules
Transit status and SLA flags should reflect reality, not
cosmetic updates.
State transition
Shipment stays in dispatched/in-transit state until
delivery or a logistics exception emerges.
Next actor
Shipper
Exception path
If the shipment stalls or breaches SLA, the evidence
chain and later liability analysis become more
important, not less.
Stage 8 - Ghana delivery and proof of delivery
Role
Shipper / shipper user
Allowed action
Complete Ghana delivery and upload/maintain proof
that delivery occurred.
Resource(s) / system(s) used
Shipper portal; Supabase shipping_quotes; evidence
storage.
Data touched
pod_ghana_url, ghana_delivered_at, delivery status,
final proof/evidence notes.
Validation rules
Delivery should not be marked complete without POD.
POD is a core downstream artifact because the

## Page 5

importer confirms receipt or disputes from this state.
State transition
Shipment reaches delivered state and triggers importer
receipt confirmation/discrepancy options.
Next actor
Importer
Exception path
If POD is missing or weak, Ghana delivery may be
disputed later even if the shipper believes delivery
occurred.
Stage 9 - Support discrepancy handling where the issue becomes shipper-side
Role
Shipper / shipper user
Allowed action
Respond to disputes only where the facts implicate the
shipper - for example UK-side damage, in-transit loss,
Ghana delivery failure, or weak POD/booking evidence.
Resource(s) / system(s) used
Shipper portal; Supabase disputes, dispute_lines,
dispute_messages, dispute_notes, dispute_images,
shipper_liabilities.
Data touched
liable_party = shipper, shipper responses, evidence
uploads, notes, settlement method fields.
Validation rules
The shipper is not the normal retailer AI loop actor. The
shipper enters the exception path when the issue
becomes shipper liability or requires shipper
evidence/response.
State transition
Dispute moves toward accepted, disputed, partial,
offset, cash refund, write-off, or further investigation.
Next actor
Supervisor/Admin for final governance and accounting
outcome
Exception path
If the shipper response is weak or evidence is poor,
staff may resolve conservatively and book liabilities or
write-offs with weaker operational support.
Stage 10 - Historical visibility and controlled closure
Role
Shipper / shipper user
Allowed action
Review completed shipments, historical POD/evidence,
and any liabilities or closed disputes tied to that shipper.
Resource(s) / system(s) used
Shipper portal history pages; Supabase historical reads
over shipping_quotes, disputes, shipper_liabilities.
Data touched
Closed booking records, POD references, dispute
outcomes, liability settlements.
Validation rules
Historical truth should not be silently rewritten. Closure
must remain traceable from booking through POD and
any later dispute resolution.
State transition
Shipment leaves active work and becomes historical
unless reopened through a controlled exception path.
Next actor
No active actor in the happy path
Exception path
If a post-delivery issue emerges later, staff reopen
through controlled dispute handling rather than editing
history directly.
Shipper happy-path summary

Shipper user is onboarded and sees only their own shipper queue.

Only funded and progressed work enters the shipper lane. The ready-for-shipment handoff is explicit.

## Page 6


Importer-submitted courier/tracking context helps the shipper anticipate inbound parcels.

Shipper receives the progressed subset, creates the booking, uploads dispatch evidence, monitors ETA/SLA, and
completes POD/delivery in Ghana.

Importer then confirms receipt or raises a discrepancy from the delivered state.
Shipper exception-path summary

Wrong courier/tracking context makes parcel monitoring unreliable and should be corrected before reliance.

Partial receipt or damage at the UK side can start the exception path early, even before Ghana delivery.

Already-progressed lines can still move while unresolved child exceptions stay open separately.

The shipper is not the normal retailer AI actor. Retailer communication remains on the importer/operator side unless
the issue becomes shipper liability.

If goods are damaged, missing, or not properly delivered in Ghana, the shipper may become a liable party and
shipper_liabilities becomes the formal recovery lane.
Order-to-Ghana validation checks for the shipper lane
Simulation A - Tracking first, then invoice, then shipment
Importer submits courier + tracking first, giving the shipper early visibility of inbound parcels. Invoice arrives later,
importer reconciles and progresses the correct lines, then the shipper receives only that progressed subset, books
shipment, dispatches, and uploads POD in Ghana. Validation result: passes.
Simulation B - Invoice first, then tracking, then shipment
Invoice exists before tracking. Importer reconciles and progresses correct lines first. Tracking arrives later. The
shipper still uses the later courier context for parcel awareness while proceeding with booking and shipment once the
progressed subset is operationally ready. Validation result: passes.
Simulation C - Progressed subset ships while refund child waits for approval
Four clean lines progress and become shipper-actionable. One child exception is set to refund and sits in
refund_pending_approval, blocked from retailer refund progression. The shipper still handles only the progressed
subset and must not absorb the blocked child into shipment allocation. Validation result: passes and confirms the
explicit handoff/control boundary.
Simulation D - Ghana-side damage with shipper liability
Shipment is delivered in Ghana but damage is alleged. The issue becomes shipper-side, the shipper responds with
evidence and a liability stance, and recovery/settlement is tracked separately from the already-progressed shipment
history. Validation result: passes.
Shipper resource map by node
Node
Primary resource(s)
Shipper queue and portal
Next.js/Vercel shipper portal; Supabase shipper-scoped
RLS/data access.
Ready-for-shipment handoff
Orders/progress views; shipping_quote_orders; explicit
progressed-subset visibility.
Tracking awareness
order_tracking_submissions; couriers lookup and
tracking URL template.
Booking and dispatch
shipping_quotes; booking_ref;
BOL/certificate/commercial invoice evidence URLs.
Transit / ETA / SLA
shipping_quotes ETA/SLA fields; importer-facing
tracking consumes the result.

## Page 7

Node
Primary resource(s)
Ghana delivery / POD
shipping_quotes POD and delivery fields; storage for
proof artifacts.
Shipper-side dispute / liability
disputes, dispute_messages/notes/images,
shipper_liabilities.
Not the normal retailer AI loop
Retailer SOP + AI drafting service exist, but normal
retailer comms sit with importer/operator unless the
matter becomes shipper liability or evidence response.
Internal working document - canonical shipper role matrix for the Multi Tenant Platform Build (Revision 5)

## Page 8
