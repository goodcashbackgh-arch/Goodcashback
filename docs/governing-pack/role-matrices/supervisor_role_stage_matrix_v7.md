# supervisor_role_stage_matrix_v7

## Page 1

SUPERVISOR END-TO-END ROLE-STAGE MATRIX
Multi Tenant Platform Build - canonical supervisor flow across funding, post-purchase oversight, retailer exception control,
shipment progression, disputes, and closure
Revision 7 - corrected so evidence capture and operational progression do not stall when platform funding
matching is late
This revision supersedes Revision 6. It keeps the live schema/control model already locked in and corrects the remaining
flow issue: post-purchase evidence capture, OCR work, child-exception handling, retailer communication, and shipper
handoff must be allowed to continue even when staff funding matching is still pending. What remains blocked until platform
funding is matched is final financial/control closure, not operational evidence capture.
Role definition
The supervisor is the primary day-to-day internal operations actor. In the current schema, most supervisor actions are
represented through the generic staff model. Routine queue handling belongs to the supervisor unless the matter is clearly
non-routine, high-risk, or policy-setting, in which case it escalates to admin.
The supervisor does not create importer orders, does not submit retailer evidence on behalf of the importer in the normal
path, and does not act as the shipper. The supervisor owns the operational control lane that sits between importer activity
and downstream shipper/accounting outcomes.
Locked architecture, schema, and control assumptions used here

Importer creates the order, uploads multiple retailer screenshots, and later submits tracking and/or retailer invoice
evidence in either order.

Supervisor and admin are both staff for DVA upload, FX setup, statement review, funding reconciliation, and credit
application.

Statement belongs to the importer; DVA/card statement upload and reconciliation are staff-only actions.

Each importer operates in one currency; FX is set upstream and used to normalize local statement lines into GBP
before funding reconciliation.

order_screenshots and order_tracking_submissions exist in the live database and canonical SQL source.
orders.screenshot_url remains legacy / backward-compat only.

Importer, not staff, is the primary user of the OCR reconciliation workspace in the normal path.

Correct lines may progress while unresolved lines become child exceptions. The explicit ready-for-shipment handoff
exists between progressed subset release and shipper execution.

Child-exception controls now exist at schema/control level through dispute_lines.conversation_status,
dispute_lines.intended_remedy, dispute_messages.in_reply_to_message_id,
dispute_messages.ai_input_context_json, dispute_messages.ai_model_used, dispute_messages.ai_prompt_hash,
and status_transitions rows for entity_type = dispute_line.

Refund progression is blocked until supervisor/admin approval exists. Replacement does not use the refund approval
gate.

AI retailer drafting must be status-aware, SOP-aware, remedy-aware, and conversation-aware.

Operationally funded but platform-unmatched orders are valid. If the retailer invoice exists or the goods are genuinely
moving, the supervisor must allow evidence capture and operational progression to continue while separately fixing the
missing DVA match.

What stays blocked until funding is matched is final control closure: no final full-clearance, no final
refund/payout/carried-credit settlement, and no final accounting/VAT release.
Supervisor operating boundary
Supervisor does: maintain FX context; upload and review DVA/card statements; generate and assess funding suggestions;
reconcile funding lines; create excess importer credit; apply importer credit to later orders; monitor evidence capture even
when platform funding is still pending; review importer OCR outputs and child exceptions; approve or reject refund

## Page 2

progression in routine cases; monitor the AI-assisted retailer communication loop; build/confirm shipping quote and ready-
for-shipment handoff; confirm hub receipt where required; monitor dispatch, ETA/SLA, Ghana delivery, disputes, liabilities,
credits, payouts, and downstream accounting readiness.
Supervisor does not: create importer orders in the normal flow; upload retailer screenshots, invoices, or tracking on behalf
of the importer in the normal flow; delete OCR source lines; bypass the refund gate; bypass the child-exception status
machine; act as the shipper; silently rewrite immutable funding history; convert unresolved child exceptions into false
parent clearance; or block evidence capture simply because DVA matching is late.
Parallel-lane control rule that the supervisor must enforce

Lane 1 - evidence and operations may continue: tracking submission, invoice upload, OCR work, child-exception
creation, AI retailer loop, ready-for-shipment handoff, and real shipper execution may continue where goods are
genuinely moving.

Lane 2 - financial/control closure waits: platform-funded confirmation, final full clearance, final refund/payout/carried-
credit settlement, and final accounting/VAT release remain blocked until funding is matched.

The supervisor must therefore manage late funding as an anomaly queue, not as a reason to stall the entire order
lifecycle.
Child exception control model relevant to the supervisor

child_exception_created

remedy_selected

refund_pending_approval

retailer_draft_ready

retailer_contacted

retailer_response_received

ai_next_draft_ready

awaiting_retailer_resolution

resolved_refund

resolved_replacement

resolved_credit

closed_no_action
The supervisor must use these statuses as control points, not as loose labels. The status machine exists so refund gating,
retailer communication, and final resolution are auditable and sequence-safe.
Stage 1 - Access the internal operations queue
Role:
Supervisor
Allowed action:
Sign in to the internal operations surface and view the live queues for funding, evidence capture,
OCR/child exceptions, shipment progression, disputes, liabilities, payouts, and accounting readiness.
Resource(s) / system(s) used:
Next.js/Vercel internal screens such as Day 2 funding control and later supervisor
worklists; Supabase role-gated data access through staff policies.
Data touched:
Orders, funding views, DVA statements/lines, match suggestions, supplier invoices,
order_tracking_submissions, order_screenshots, shipping quotes, disputes, payout requests, and related status views.
Validation rules:
Must be active staff. Supervisor uses staff-level permissions but should operate within routine policy and
escalate unusual cases.
State transition:
Supervisor becomes the operational actor for the queue.
Next actor:
Supervisor

## Page 3

Exception path:
If access is broken or role mapping is wrong, no operational control should proceed until corrected.
Stage 2 - Maintain FX context
Role:
Supervisor
Allowed action:
Enter or maintain quote and settlement FX rates and card markup assumptions for the importer corridor.
Resource(s) / system(s) used:
Internal forms; Supabase fx_rates; country/currency configuration.
Data touched:
fx_rates.quote_rate, quote_card_markup_pct, settlement_rate, settlement_card_markup_pct, rate_date,
entered_by_staff_id.
Validation rules:
Correct country, correct date, correct quote-versus-settlement distinction, and single-currency context
per importer.
State transition:
FX context becomes available for quote display and later DVA normalization.
Next actor:
Importer for quote visibility; supervisor/admin staff for later statement handling.
Exception path:
Missing or wrong FX rates should block or visibly warn against downstream funding reconciliation.
Stage 3 - Upload importer DVA/card statements
Role:
Supervisor
Allowed action:
Upload a DVA/card statement for the correct importer and statement period.
Resource(s) / system(s) used:
Internal upload UI; Supabase dva_statements; storage for source statement file.
Data touched:
dva_statements.importer_id, source_bank, uploaded_by_staff_id, csv_url, statement_period_from,
statement_period_to, parse_status.
Validation rules:
Statement must be attached to the correct importer. Importer never uploads DVA statements. Source
bank must be valid and uploader must be staff.
State transition:
Statement becomes the parent for DVA lines.
Next actor:
Supervisor
Exception path:
Wrong importer selection poisons all later matching; fix ownership before reconciliation.
Stage 4 - Review parsed DVA lines and generate suggestions
Role:
Supervisor
Allowed action:
Review parsed statement lines, confirm local-currency normalization, and generate or assess likely order
matches.
Resource(s) / system(s) used:
Internal Day 2 DVA review worklist; Supabase dva_statement_lines, match_suggestions,
order_funding_position_vw, day2_dva_review_worklist_vw.
Data touched:
statement_date, amount_local_ccy, local_ccy, fx_rate_applied, amount_gbp_equivalent, auth_id_ref,
match_status, suggested match rows, variance values.
Validation rules:
Only inbound lines can fund orders. Suggestions must stay within the same importer and use
auth/amount/date logic.

## Page 4

State transition:
Line becomes suggested, ready for reconciliation, or held for investigation.
Next actor:
Supervisor
Exception path:
No suggestion, wrong suggestion, or ambiguous auth mismatch pushes the case into investigation.
Stage 5 - Reconcile funding to orders
Role:
Supervisor
Allowed action:
Accept a suggested order match or manually reconcile the DVA line to the right order.
Resource(s) / system(s) used:
accept_order_match_suggestion_and_reconcile, confirm_reconciliation_to_order,
check_and_stamp_order_funding, internal Day 2 UI, Supabase funding tables/views.
Data touched:
dva_reconciliation, dva_statement_lines.match_status, orders.funded_at/status, order_funding_events,
importer_credit_ledger when overfunding exists.
Validation rules:
Line must be inbound; statement importer must match order importer; auth ref must match
payment_auth_id; same line cannot be reconciled twice; only gap amount funds the order; excess becomes importer credit.
State transition:
Order funding position increases and, if threshold is met, the order becomes funded exactly once.
Next actor:
Importer waits for funded state; supervisor may continue with credit handling.
Exception path:
Duplicate line usage, wrong auth, wrong importer, or already-funded target order must all block the
action.
Stage 6 - Apply importer credit to later orders
Role:
Supervisor
Allowed action:
Apply available importer credit to an unfunded later order when standard rules allow it.
Resource(s) / system(s) used:
apply_importer_credit_to_order, importer_balance_vw, importer_credit_ledger, internal
Day 2 worklist.
Data touched:
importer_credit_ledger debit rows, order funding views, order_funding_events, orders.funded_at/status.
Validation rules:
Available credit must exist; order must still have a gap; application cannot exceed remaining gap.
State transition:
Later order funding increases or reaches funded state; available importer credit decreases.
Next actor:
Importer sees the funded outcome.
Exception path:
No credit, wrong order, or already-funded order should block the application.
Stage 7 - Investigate open funding anomalies without stalling the evidence lane
Role:
Supervisor
Allowed action:
Investigate when an importer says payment was made but the order remains open, or when a statement
line cannot be cleanly applied, while allowing real evidence capture and operational work to continue in parallel.
Resource(s) / system(s) used:
Internal Day 2 worklists; Supabase orders, DVA lines, match suggestions, reconciliation
rows, funding event history, importer credit ledger, evidence-completeness views.

## Page 5

Data touched:
Funding views, raw statement refs, auth refs, prior reconciliations, threshold events, credit balances,
invoice/tracking completeness markers.
Validation rules:
Do not bend the rules. Trace importer, auth, FX, and event history. Same-auth-ref remains workflow-
enforced, not casually bypassed. Do not freeze invoice/tracking/OCR progress just because matching is late.
State transition:
Issue resolves into correct funding recognition, a held exception, or escalation to admin while the
evidence lane remains visible and active.
Next actor:
Supervisor or admin depending on severity.
Exception path:
If policy interpretation or history is unclear, escalate rather than improvising.
Stage 8 - Monitor evidence capture and operational completeness even when funding is
still pending
Role:
Supervisor
Allowed action:
Monitor whether the importer has supplied tracking details, invoice details, or both, even where platform
funding matching is still pending.
Resource(s) / system(s) used:
Importer dashboard summaries; Supabase order_tracking_submissions,
supplier_invoices, orders, couriers.
Data touched:
courier_id, tracking_ref, tracking_date, invoice_ref, invoice_pdf_url, order status/read models.
Validation rules:
Tracking and invoice may arrive in either order. Supervisor must not force an artificial sequence. Courier
is mandatory. Tracking submissions are historical child rows, not silent parent overwrites. Funding-match delay is not a
reason to block evidence capture.
State transition:
Order moves into tracking-only, invoice-only, or both-received operational states whether or not platform
matching is already complete.
Next actor:
Importer remains primary actor for evidence capture; supervisor monitors readiness and separately pursues
funding recognition.
Exception path:
Wrong courier or missing invoice delays later work; supervisor can query the importer but should not
falsify the evidence trail.
Stage 9 - Review importer reconciliation outputs and unresolved children in the same
parallel model
Role:
Supervisor
Allowed action:
Review what the importer has done in the OCR reconciliation workspace and manage the consequences
of unresolved lines, even where funding matching is still being cleaned up in parallel.
Resource(s) / system(s) used:
Supabase supplier_invoices, supplier_invoice_lines, order_reconciliation views,
disputes/dispute_lines, internal oversight screens; Mindee OCR output as surfaced data.
Data touched:
OCR lines, manual lines, progressed subset flags, child exception records, parent-order baseline.
Validation rules:
Importer is the primary workspace user. OCR lines are editable but not deletable; only manual lines may
be deleted. Correct lines may progress while unresolved lines stay child exceptions. Parent is not fully cleared until
progressed lines plus resolved children reconcile to the original baseline.
State transition:
Progressed subset is ready for explicit ready-for-shipment handoff; child exceptions stay governed.

## Page 6

Next actor:
Shipper for progressed subset; supervisor/admin for unresolved child handling.
Exception path:
If importer output no longer reconciles to the parent baseline, hold partial clearance visibly and query the
importer or escalate.
Stage 10 - Preserve remedy intent and the explicit ready-for-shipment handoff
Role:
Supervisor
Allowed action:
Review each child exception after importer selects intended remedy, and explicitly preserve the handoff
between progressed subset release and shipper execution.
Resource(s) / system(s) used:
Internal exception oversight screens; Supabase dispute_lines.intended_remedy,
conversation_status, order progress views, shipping readiness views.
Data touched:
Child intended remedy, conversation_status, parent-order partial clearance state, progressed subset
shipment readiness.
Validation rules:
This stage exists so the ready-for-shipment node is explicit. Progressed lines can move to shipper even
while refund/replacement children remain open. Remedy intent must be traceable at child level.
State transition:
Progressed subset enters ready-for-shipment / shipping-quote lane. Child exceptions enter governed
remedy lanes.
Next actor:
Shipper for progressed subset; supervisor continues child remedy oversight.
Exception path:
If progressed subset and child exceptions are blurred together, shipment scope and later liability become
unreliable.
Stage 11 - Enforce the refund approval gate
Role:
Supervisor
Allowed action:
Approve, reject, or query refund requests before any retailer-facing refund communication progresses.
Resource(s) / system(s) used:
Internal approval controls; Supabase dispute_lines.conversation_status, dispute/refund
approval fields, status_transitions.
Data touched:
refund_approved_by_staff_id, refund_approved_at, child conversation_status, approval notes.
Validation rules:
Refund branch must remain blocked / greyed out until supervisor/admin approval exists. Replacement
bypasses the refund gate. No retailer-facing refund progression should occur as if approved before the gate is passed.
State transition:
Refund child moves to refund_pending_approval, then retailer_draft_ready once approved. If not
approved, it stays blocked or returns for rework.
Next actor:
Importer once an allowed retailer-contact state exists.
Exception path:
If evidence is weak or liability is unclear, supervisor should refuse progression and escalate or request
more information.
Stage 12 - Govern the AI-assisted retailer communication loop
Role:
Supervisor
Allowed action:
Oversee the retailer communication loop where the importer uses AI-generated drafts and pastes retailer
replies back into the system.

## Page 7

Resource(s) / system(s) used:
Next.js/Vercel exception communication UI; server-side AI drafting service; retailer_sops;
Supabase dispute_messages with in_reply_to_message_id, ai_input_context_json, ai_model_used, ai_prompt_hash;
dispute_lines.conversation_status.
Data touched:
Conversation status, intended remedy, prior message chain, pasted retailer reply, generated next draft,
SOP version used, AI audit context.
Validation rules:
AI drafting must be status-aware, SOP-aware, remedy-aware, and conversation-aware. The supervisor
governs the loop but the importer/operator remains the normal sender using the retailer account. Message threading and AI
audit fields must remain intact.
State transition:
Child moves through retailer_draft_ready, retailer_contacted, retailer_response_received,
ai_next_draft_ready, and awaiting_retailer_resolution until outcome is clear.
Next actor:
Importer continues the loop; supervisor monitors compliance and intervenes where needed.
Exception path:
Wrong pasted reply, wrong retailer account, wrong SOP, or bypass of the status machine should halt
progression until corrected.
Stage 13 - Determine liability and child outcome
Role:
Supervisor
Allowed action:
Review disputes raised by the importer, classify the issue, determine likely liable party, and govern the
operational outcome for the child exception.
Resource(s) / system(s) used:
Supabase disputes, dispute_lines, dispute_images, dispute_notes, dispute_messages;
internal review UI; retailer/shipper communication channels; AI-generated drafts where used.
Data touched:
issue_type, liable_party, amount_impact_gbp, intended_remedy, conversation_status, resolution_method,
comments, reviewed_by_staff_id, refund approval fields.
Validation rules:
Dispute detail must be sufficient and tied to the correct parent/child context. Liability should not be
guessed. Distinguish retailer, shipper, and unknown liability. Keep intended remedy separate from realised outcome.
State transition:
Child moves toward resolved_refund, resolved_replacement, resolved_credit, or closed_no_action.
Next actor:
Supervisor continues standard handling or escalates to admin for unusual cases.
Exception path:
Weak evidence, late reporting, or unclear liability should pause decisioning rather than force a premature
outcome.
Stage 14 - Manage shipper liability where applicable
Role:
Supervisor
Allowed action:
If the shipper is liable, create and manage the shipper liability record and pursue the selected settlement
path.
Resource(s) / system(s) used:
shipper_liabilities, shipping_quotes, internal settlement screens, shipper communication
workflow.
Data touched:
amount_gbp, shipper_response, settlement_method, offset_against_shipping_quote_id, notes, resolved_at.
Validation rules:
Only use shipper liability when liable_party really is shipper. Keep settlement method explicit: offset next
invoice, cash refund, or write-off.
State transition:
Liability is accepted, disputed, partial, or resolved.

## Page 8

Next actor:
Supervisor or admin depending on complexity.
Exception path:
If the shipper disputes or partially accepts liability, escalate and keep the importer outcome separate from
the still-open recovery path.
Stage 15 - Execute standard replacement, credit, payout, or completed refund outcomes
only when final funding control is satisfied
Role:
Supervisor
Allowed action:
Drive the standard operational outcome for the importer once a dispute is resolved: replacement child
order, carried credit, payout request processing, or completed refund path.
Resource(s) / system(s) used:
disputes, dispute_lines, importer_credit_ledger, payout_requests, orders (replacement
child), internal operational UI.
Data touched:
replacement_child_order_id, importer credit ledger entries, payout request amount/local
currency/method/status/proof, approved_by_staff_id, paid_at, completed refund state.
Validation rules:
Outcome must follow the chosen and approved path. Credit and payout should not both be created for
the same amount without a governed reason. Replacement child orders must remain linked and traceable. Final refund /
payout / carried-credit settlement should not be treated as fully complete until funding control is matched.
State transition:
Importer sees carried credit, payout, replacement, refund completion, or closure once the financial/control
gate is satisfied.
Next actor:
Importer for visibility; admin only if thresholds/policy require escalation.
Exception path:
Non-standard payout behavior, sensitive manual adjustments, or ambiguous double-settlement risk
should escalate.
Stage 16 - Support downstream accounting and compliance readiness only after funding
control and operational truth are both stable
Role:
Supervisor
Allowed action:
Ensure the operational evidence needed for sales invoices, Sage postings, and VAT treatment is
complete and internally coherent.
Resource(s) / system(s) used:
sales_invoices, sage_postings, vat_return_adjustments, vat_return_workings, Sage Cloud
API integration layer, internal compliance dashboards.
Data touched:
Export evidence dates, zero-rating status, posted_by_staff_id/generated_by_staff_id fields, idempotent
posting queue/status records.
Validation rules:
Operational truth and child outcomes should be stable before posting. Missing export or shipment
evidence damages VAT/compliance outcomes. Final accounting/VAT release should not proceed until funding match and
operational evidence are both coherent.
State transition:
Operational record is ready for downstream accounting/compliance processing and later archive.
Next actor:
System/admin/finance process, then historical closure.
Exception path:
Missing evidence, failed postings, or VAT timing anomalies should be escalated rather than buried.

## Page 9

Stage 17 - Historical review and controlled reopen
Role:
Supervisor
Allowed action:
Review historical cases, answer operational questions, and reopen through a controlled exception path
where genuinely required.
Resource(s) / system(s) used:
Historical Supabase reads, audit_log, funding event history, dispute history, message
history, shipment evidence history.
Data touched:
Immutable event history, prior reconciliations, archived shipment/dispute outcomes, AI-message audit trail.
Validation rules:
Do not rewrite prior truth. Use audit and event history to explain what happened. Reopen only through
governed exception handling.
State transition:
Case remains closed or re-enters a controlled exception path.
Next actor:
Supervisor, admin, or no active actor.
Exception path:
If the past record is unclear, trace event history rather than patching data casually.
Supervisor happy-path summary

Supervisor enters the internal queue, maintains FX context, uploads the importer's DVA statement, and reconciles
funding correctly where statement evidence supports it.

If staff funding matching is late, supervisor allows invoice/tracking capture, OCR work, child-exception handling, and
real shipper progression to continue rather than stalling the order.

Importer performs OCR reconciliation work; supervisor reviews outputs and ensures clean lines can progress while
child exceptions stay governed.

Supervisor preserves the explicit ready-for-shipment handoff so progressed subset moves to shipper while child
remedy lanes remain open.

If a child exception requires refund, supervisor/admin approval is obtained before any retailer-facing refund loop can
progress.

Importer uses AI-generated retailer drafts and pastes retailer replies back; supervisor governs status progression,
approvals, and audit integrity.

Supervisor creates or confirms shipping quote/apportionment, confirms hub receipt where required, tracks dispatch
and Ghana progression, and keeps evidence complete.

Final financial/control closure and accounting/VAT release wait until funding matching and operational truth are both
coherent.
Supervisor exception-path summary

Payment made but order still open: investigate statement ownership, auth match, FX normalization, and prior
reconciliation history without blocking real evidence capture.

Overfunding: create importer credit rather than overstating the order; later apply that credit to another order if valid.

Tracking before invoice or invoice before tracking: both are valid; supervisor should not force a rigid sequence.

Importer OCR output incomplete or mismatched: progressed lines may move, unresolved lines stay as child
exceptions, and the parent remains only partially cleared until final reconciliation is complete.

Refund selected: keep the refund lane blocked until supervisor/admin approval exists.

AI retailer loop: every draft must be status-aware, SOP-aware, remedy-aware, and tied to threaded message history
plus AI audit fields.

Ghana damage or non-delivery: review dispute, determine liability, create shipper liability if applicable, and drive
refund/replacement/credit/payout without collapsing the audit trail.

## Page 10

Supervisor end-to-end simulation checks

Simulation A - Exact funding and smooth Ghana delivery: importer creates order; supervisor funds exactly once;
importer submits tracking first, then invoice; OCR cleanly progresses all lines; supervisor confirms ready-for-shipment
handoff, quote/apportionment, hub receipt, dispatch, and POD; importer confirms receipt in Ghana.

Simulation B - Overfunding and later credit reuse: supervisor reconciles a DVA line that exceeds the remaining gap;
only the gap funds the order; excess becomes importer credit; later supervisor applies that credit to another open
order.

Simulation C - Progressed subset ships while refund child waits for approval: importer submits tracking before invoice;
invoice later arrives; four good lines progress and one child enters refund_pending_approval; supervisor keeps the
refund lane blocked but preserves the ready-for-shipment handoff for the four progressed lines; shipper handles only
the progressed subset; parent remains partially cleared until the child later reconciles.

Simulation D - Approved refund with AI retailer loop: child exception is reviewed and refund is approved; child moves
from refund_pending_approval to retailer_draft_ready; importer uses the AI-generated retailer draft, sends it via the
retailer account, then pastes the retailer reply back; AI generates the next draft using SOP, current status, intended
remedy, prior thread, and audit context until the child reaches resolved_refund or another explicit resolved status.

Simulation E - Evidence exists before funding match: retailer invoice and tracking are already present because the
goods were genuinely purchased; importer completes OCR work and progressed subset becomes shipment-eligible;
supervisor still pursues the missing DVA match in parallel and blocks only final financial/control closure until matched.

Simulation F - Ghana damage with shipper liability: shipment is dispatched and later delivered in Ghana; importer
raises a damage dispute; supervisor determines liable_party = shipper, creates a shipper_liabilities record, and
separates importer outcome from shipper recovery.
Supervisor resource map by node

Internal queue and worklists: Next.js/Vercel internal pages such as Day 2 funding control and later supervisor worklists;
Supabase role-gated reads and writes through staff policies.

FX context: Supabase fx_rates and configuration lookups.

Funding controls: dva_statements, dva_statement_lines, match_suggestions, dva_reconciliation,
importer_credit_ledger, order_funding_position_vw, and order_funding_events.

Evidence capture / completeness oversight: order_tracking_submissions, couriers, supplier_invoices,
order_screenshots, dashboard completeness views, and late-funding anomaly views.

OCR / child-exception oversight: Mindee OCR output surfaced through supplier_invoices and supplier_invoice_lines;
order_reconciliation views; dispute_lines.intended_remedy; dispute_lines.conversation_status.

Retailer exception communication control: server-side AI drafting service; retailer_sops; dispute_messages threading;
ai_input_context_json; ai_model_used; ai_prompt_hash; approval and status-transition logic.

Shipping execution oversight: shipping_quotes, shipping_quote_orders, shipper evidence URLs, ready-for-shipment
handoff, dispatch/ETA/POD fields.

Disputes and liabilities: disputes, dispute_lines, dispute_images/notes/messages, shipper_liabilities, payout_requests.

Accounting / compliance handoff: sales_invoices, sage_postings, VAT workings/adjustments, Sage Cloud API
integration.

Platform delivery (not runtime supervisor tool): GitHub and Vercel deployment lifecycle; relevant to the product, not a
runtime supervisor-operated workflow node.
Internal working document - canonical supervisor role matrix for the Multi Tenant Platform Build (Revision 7).

## Page 11
