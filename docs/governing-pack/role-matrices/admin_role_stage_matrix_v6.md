# admin_role_stage_matrix_v6

## Page 1

ADMIN END-TO-END ROLE-STAGE MATRIX
Multi Tenant Platform Build - canonical admin flow across governance, escalation, financial control, disputes, and closure
Revision 6 - corrected so evidence capture and genuine operational progression can continue before platform funding match,
while final financial/control closure remains blocked until funding is recognized
Role definition
The admin is the control owner and escalation actor for the platform. In the current schema, most admin actions are representedthrough the generic staff model, but admin is not just a second supervisor. Admin governs non-routine judgement, masterconfiguration, high-risk approvals, liability decisions, financial-control release, accounting/VAT release, and historical audit integrity.
Locked architecture, schema, and control assumptions used here

Importer creates the order, uploads multiple retailer screenshots, and may later submit tracking and retailer invoice evidence ineither order.

Supervisor and admin are both staff for DVA upload, FX setup, statement review, funding reconciliation, and credit application;routine throughput belongs to supervisor unless escalated.

Statement belongs to the importer; DVA/card upload and reconciliation are staff-only actions.

Each importer operates in one currency. FX is set upstream and used to normalize local statement lines into GBP beforefunding reconciliation.

Plural screenshots are modeled through order_screenshots and dynamic post-purchase tracking throughorder_tracking_submissions. orders.screenshot_url remains legacy only.

Importer, not staff, is the primary user of the OCR reconciliation workspace in the normal path.

Correct lines may progress while unresolved lines become child exceptions. The parent order is only fully cleared onceprogressed lines plus resolved children reconcile back to the original submitted quantity and value.

Child-exception controls now exist at schema/control level through dispute_lines.conversation_status,dispute_lines.intended_remedy, dispute_messages.in_reply_to_message_id, dispute_messages.ai_input_context_json,dispute_messages.ai_model_used, ai_prompt_hash, and status_transitions rows for entity_type = dispute_line.

Refund progression is blocked until supervisor/admin approval exists. Replacement does not use the refund approval gate, butstill remains inside the child-exception status machine.

Retailer exception drafting must be status-aware, SOP-aware, remedy-aware, and conversation-aware.

Evidence capture and genuine operational progression do not have to wait for platform funding match. Late funding recognitionis handled as a control anomaly, not as a reason to stall real goods and evidence.

What remains blocked until funding is matched is final platform-funded confirmation, final parent full clearance/completion, finalrefund/payout/carried-credit settlement, and final accounting/VAT release.

If a retailer replacement is agreed, it should run as a replacement child order. The new invoice and invoice ref attach to thatchild order, not back to the original order.
Admin operating boundary

Admin does: govern high-risk funding and post-purchase exceptions; maintain master configuration and SOP artefacts; approveor execute non-routine credits, refunds, replacements, payouts, and liability decisions; own accounting/compliance readinessand historical audit integrity; preserve the rule that evidence capture and real operations may continue even while fundingmatch is still unresolved.

Admin does not: create importer orders in the normal path; upload retailer evidence on behalf of the importer in the normal path;act as shipper; routinely perform every daily queue item that belongs to supervisor throughput unless required by escalation orstaff absence; use missing funding match as an excuse to freeze evidence capture or real shipment activity.
Admin control principle on pre-funding evidence and operations

Allowed to continue before platform funding match: tracking submission, invoice upload, invoice ref capture, OCR/reconciliationwork, child-exception creation, AI retailer loop, ready-for-shipment handoff, and real shipper execution if goods are genuinelymoving.

Blocked until platform funding match: final platform-funded confirmation, final parent full clearance/completion, finalrefund/payout/carried-credit settlement, and final accounting/VAT release.

Admin therefore governs two parallel lanes: operational truth can continue to assemble, and financial/control closure waits untilfunding is recognized.

## Page 2

Stage 1 - Access governance and exception-control surfaces
Role: Admin
Allowed action: Sign in to the internal control surface and view cross-queue dashboards spanning funding anomalies, importercompleteness, shipper performance, disputes, payouts, liabilities, accounting readiness, and historical reopen requests.
Resource(s) / system(s) used: Next.js / Vercel admin screens; Supabase role-gated reads via the staff model; Day 2 worklistsplus later admin queues and reports.
Data touched: Orders, funding views, DVA statements/lines, match suggestions, screenshots, tracking submissions, invoices,shipping quotes, liabilities, disputes, payouts, credit ledger, and audit/event histories.
Validation rules: Active staff only. Admin access is for governance and escalation, not casual editing of every object.
State transition: Admin becomes the escalation and final-control actor for the current issue or queue.
Next actor: Admin
Exception path: If staff access or role mapping is broken, no governance action should proceed until corrected.
Stage 2 - Maintain master configuration and policy context
Role: Admin
Allowed action: Create or maintain control parameters that shape downstream operations: countries/currencies, courier lookups,SOP versions, retailer SOPs, and other master records when changes affect multiple users or financial/compliance outcomes.
Resource(s) / system(s) used: Internal admin forms; Supabase master/configuration tables such as countries, currencies,couriers, sops, and retailer_sops.
Data touched: Configuration rows, SOP versions, retailer claims/escalation metadata, and active/inactive flags.
Validation rules: Changes must preserve one-importer-one-currency assumptions, valid courier/site mappings, and versioncontrol. New policy should not silently invalidate in-flight records.
State transition: Master data and SOP context become the approved baseline for routine users.
Next actor: Supervisor / importer / shipper depending on what changed.
Exception path: If a configuration change would break in-flight orders or historical interpretation, stage/version it rather thanhard-swap.
Stage 3 - Maintain and override FX context when risk warrants
Role: Admin
Allowed action: Approve, correct, or override FX rates and card markup assumptions when supervisor input is missing, disputed,or clearly wrong.
Resource(s) / system(s) used: Internal admin forms; Supabase fx_rates; country/currency controls; quote and settlement logic.
Data touched: Quote rate, quote card markup, settlement rate, settlement card markup, rate date, and staff trace.
Validation rules: Correct corridor, correct date, and correct quote-versus-settlement distinction. Overrides should be traceable andused only when confidence requires it.
State transition: FX context becomes approved and safe for quote visibility and DVA normalization.
Next actor: Supervisor for routine use; importer indirectly through quote display.
Exception path: If rate evidence is uncertain, hold the correction or flag it rather than letting suspect FX data propagate.
Stage 4 - Govern DVA/card statement intake standards
Role: Admin
Allowed action: Review or intervene when DVA/card statement upload, parser behavior, importer attribution, or source-bankassumptions are disputed or unstable.
Resource(s) / system(s) used: Internal staff screens; Supabase dva_statements and related parsing/error fields; storage foruploaded statement sources.
Data touched: Importer ownership, source bank, uploader, source file, period dates, parse status, and parse errors.
Validation rules: Importer never uploads DVA statements. Statement must belong to the correct importer. Intervene mainly whenownership, parse failure, or evidence sufficiency is unclear.
State transition: Statement intake is either validated for normal processing or explicitly held/corrected.
Next actor: Supervisor for routine line handling, or admin continues if the case remains ambiguous.

## Page 3

Exception path: Wrong importer attribution or bad parsing can poison every later funding action; stop the chain rather than allowdrift.
Stage 5 - Resolve non-routine funding anomalies without stalling operations
Role: Admin
Allowed action: Take over funding anomalies that routine supervisor handling cannot safely close: no suggestion appears, wrongstatement line is suspected, same-auth-ref explanations are weak, or an order remains open despite claimed payment.
Resource(s) / system(s) used: Internal Day 2 funding pages; Supabase funding views, statement lines, suggestions, and relatedfunctions.
Data touched: Order/payment refs, statement line auth refs, imported funding totals, gap remaining, suggestion records, andalready-captured evidence submitted while the funding anomaly remained open.
Validation rules: Same-auth-ref is workflow-enforced, not hard DB-enforced, so challenge explanations and push queries back tothe importer. Missing funding match must not freeze valid evidence capture or real shipment activity.
State transition: Case resolves into a valid reconciliation, rejection, hold-pending-evidence, or a governed anomaly state whileoperations continue.
Next actor: Supervisor for routine follow-through, or admin if still unresolved.
Exception path: If explanation is weak or contradictory, do not force funding through just to clear the queue.
Stage 6 - Approve or execute non-routine funding reconciliations and manual credits
Role: Admin
Allowed action: Approve or directly perform reconciliations/credit applications when the amounts, sequence, or commercialrationale are unusual.
Resource(s) / system(s) used: Internal Day 2 controls; Supabase reconciliation, importer credit ledger, funding events, orders.
Data touched: Reconciled GBP amounts, excess-credit rows, manual credit rows, threshold events, order funded state, and stafftrace fields.
Validation rules: Only inbound lines fund orders; statement importer must match order importer; same DVA line cannot bereconciled twice; overfunding must go to importer credit; applied credit cannot exceed available balance or order gap.
State transition: Order reaches funded state once, or a credit balance changes in a controlled way with traceable staff attribution.
Next actor: Importer sees result; supervisor continues normal operations downstream.
Exception path: If the action would create contradictory funded history or suspicious manual balances, stop and investigate ratherthan patch data.
Stage 7 - Govern operator/importer access and evidence integrity
Role: Admin
Allowed action: Resolve cases where operator/importer account mappings, screenshot ownership, or tracking/invoicesubmissions appear to come from the wrong entity or violate role boundaries.
Resource(s) / system(s) used: Internal admin screens; Supabase operators, importers, orders, screenshots, trackingsubmissions, invoices.
Data touched: Auth mappings, active flags, screenshot rows, tracking submissions, invoice submissions, and timestamps.
Validation rules: Importer may upload screenshots, tracking, and invoice evidence only for their own orders. Ensure operator-ownand staff-own boundaries remain clean.
State transition: Access/evidence ownership is validated or corrected before downstream progression continues.
Next actor: Importer or supervisor depending on what needs re-submission or re-checking.
Exception path: If evidence is linked to the wrong order or wrong importer, sever/correct the linkage before reconciliation orshipment decisions continue.
Stage 8 - Oversee dynamic post-purchase completeness before or after funding match
Role: Admin
Allowed action: Govern the case where tracking arrives before invoice, invoice arrives before tracking, or one branch is missingtoo long and creates operational risk, regardless of whether platform funding match has already happened.
Resource(s) / system(s) used: Importer dashboard observed indirectly, internal admin completeness views, Supabase trackingsubmissions, invoices, couriers.

## Page 4

Data touched: Courier, tracking ref/date, invoice ref, invoice PDF, and order-level completeness indicators.
Validation rules: Do not force tracking before invoice or invoice before tracking. Missing funding match does not invalidateevidence capture; it only blocks final financial/control closure.
State transition: Order moves into tracking-only, invoice-only, or both-received state with a governed next action, even if fundinganomaly is still open.
Next actor: Importer for missing evidence; supervisor for routine operational follow-through.
Exception path: If wrong courier was chosen, tracking becomes operationally ambiguous and correction may be required beforeshipper reliance or liability conclusions.
Stage 9 - Review importer OCR outputs and child-exception structure
Role: Admin
Allowed action: Review systemic OCR issues, challenge ambiguous importer edits, and govern whether unresolved lines arecorrectly split into child exceptions rather than quietly absorbed into the parent.
Resource(s) / system(s) used: Reconciliation surfaces; Supabase invoices, invoice lines, order_reconciliation_vw,disputes/dispute_lines; Mindee OCR output.
Data touched: OCR lines, manual lines, confirmation fields, parent-order baselines, and child exception records.
Validation rules: OCR lines are editable but not deletable. Only manual lines are deletable. Clean lines may progress whileunresolved lines become child exceptions. Parent only fully clears once progressed lines plus resolved children reconcile back tothe original baseline.
State transition: Admin either validates the child-exception structure or requires correction before later accounting or liabilityoutcomes rely on it.
Next actor: Supervisor for routine follow-up, importer if more evidence/editing is genuinely needed, or shipper if logistics isimpacted.
Exception path: If parent and child structures no longer reconcile to the original order baseline, hold final clearance and preventsilent drift.
Stage 10 - Preserve explicit ready-for-shipment handoff even while funding/control closure is stillpending
Role: Admin
Allowed action: Protect the explicit handoff where progressed subset value leaves internal purchasing/reconciliation and becomesshipper-executable, even if child exceptions remain open or funding match is still in anomaly handling.
Resource(s) / system(s) used: Internal shipping-readiness views; Supabase order progress views, shipping readiness markers,and child-exception status fields.
Data touched: Progressed subset visibility, child exception state, partial-clearance state, ready-for-shipment indicators, andfunding-anomaly flags still open.
Validation rules: This handoff must stay explicit. Progressed lines can move to shipper while unresolved children remain open.Late funding matching must not erase the handoff for genuine goods already moving, but final financial/control closure still waits.
State transition: Shipment-ready subset enters the shipping quote / shipper lane while child remedy lanes remain governedseparately.
Next actor: Shipper for progressed subset; supervisor/admin continue anomaly or exception oversight.
Exception path: If progressed subset and child exceptions are blurred together, shipment scope, cost allocation, and later liabilitybecome unreliable.
Stage 11 - Govern child remedy intent and enforce the refund gate
Role: Admin
Allowed action: Review or override child-level intended remedy and approve, reject, or query refund requests before anyretailer-facing refund communication progresses.
Resource(s) / system(s) used: Internal exception controls; Supabase intended_remedy, conversation_status, dispute/refundapproval fields, and status_transitions.
Data touched: Intended remedy, conversation status, refund approval fields, approval notes, and related evidence references.
Validation rules: Refund branch must remain blocked / greyed out until supervisor/admin approval exists. Replacement bypassesonly the refund-specific approval gate; it still remains inside the child-exception status machine.

## Page 5

State transition: Refund child moves to refund_pending_approval and, if approved, to retailer_draft_ready. Replacement canmove from remedy_selected to retailer_draft_ready without the refund gate.
Next actor: Importer once an allowed retailer-contact state exists; supervisor for routine monitoring.
Exception path: If evidence is weak or liability is unclear, refuse progression, request more information, or redirect to anotheroutcome.
Stage 12 - Govern the AI-assisted retailer communication loop
Role: Admin
Allowed action: Oversee the loop where the importer uses AI-generated drafts in the retailer account and pastes retailer repliesback into the platform until the child reaches a governed outcome.
Resource(s) / system(s) used: Exception communication UI; server-side AI drafting service; retailer_sops; Supabasedispute_messages threading/audit fields; conversation_status.
Data touched: Conversation status, intended remedy, prior message chain, pasted retailer reply, generated next draft, SOPversion used, AI audit context, and thread linkage.
Validation rules: AI drafting must be status-aware, SOP-aware, remedy-aware, and conversation-aware. Admin governs the loopbut the importer/operator remains the normal sender using the retailer account. Message threading and AI audit fields must remainintact.
State transition: Child moves through retailer_draft_ready, retailer_contacted, retailer_response_received, ai_next_draft_ready,and awaiting_retailer_resolution until the outcome is clear.
Next actor: Importer continues the loop; supervisor monitors routine compliance; admin intervenes on non-routine risk.
Exception path: Wrong pasted reply, wrong retailer account, wrong SOP, or bypass of the status machine should halt progressionuntil corrected.
Stage 13 - Determine liability across retailer, shipper, importer, and platform
Role: Admin
Allowed action: Take final view on who bears loss when something goes wrong after progression: retailer, shipper, importer, orplatform.
Resource(s) / system(s) used: Internal disputes screens; Supabase disputes, shipper_liabilities, evidence links, shipment andreceipt records, retailer SOP context.
Data touched: Liable party, amount impact, shipper liability rows, evidence pointers, comments, and decision timestamps.
Validation rules: Liability should not be assigned casually. Reconcile receipt evidence, booking/POD evidence, importersubmissions, retailer-side facts, and any funding anomaly context before deciding.
State transition: Liability outcome becomes the basis for refund, replacement, credit, or further investigation.
Next actor: Supervisor for routine execution or shipper/importer if additional evidence is required.
Exception path: If evidence is incomplete or contradictory, hold the liability decision rather than converting uncertainty into a falsefinancial outcome.
Stage 14 - Approve final financial outcomes, including replacement child-order continuation
Role: Admin
Allowed action: Approve and govern the non-routine commercial outcome: refund, replacement child order, carried-forward credit,payout, or explicit hold / no action yet.
Resource(s) / system(s) used: Internal dispute and payout screens; Supabase disputes, payout_requests,importer_credit_ledger, replacement child-order references; downstream Sage accounting logic.
Data touched: Refund approvals, payout status, importer credit rows, replacement_child_order_id, notes, and related financialimpacts.
Validation rules: Carried credit, refund, and payout are not interchangeable without rationale. If replacement is chosen, it shouldrun as a replacement child order, and the new retailer invoice + invoice ref should attach to that child order rather than the originalorder.
State transition: Case resolves into the approved outcome and becomes ready for routine execution or accounting handoff oncefunding/control requirements are satisfied.
Next actor: Supervisor or finance/accounting execution layer; importer sees the resulting status.
Exception path: If the selected outcome would create VAT/accounting ambiguity or unfairly shift liability, rework the decisionbefore execution.

## Page 6

Stage 15 - Own accounting, Sage, and VAT/compliance release gate
Role: Admin
Allowed action: Review whether the operational outcome is safe to hand into accounting postings, Sage integration, VATworkings, and audit evidence packages.
Resource(s) / system(s) used: Internal accounting views, posting matrix, Sage Cloud API adapters, VAT workings, OCR outputs,dispute/refund/credit records, immutable event history.
Data touched: Posting-relevant order status, funding events, supplier invoice status, shipper liabilities, refund/credit decisions,payout outcomes, replacement child orders, and VAT timing context.
Validation rules: Operational truth should be stable before posting. Ensure refunds, credits, liabilities, and child exceptions arerepresented consistently enough for downstream accounting and VAT treatment. No final accounting/VAT release until fundingmatch is recognized.
State transition: Case becomes approved for standard accounting/compliance processing or is held for correction.
Next actor: Finance/accounting systems flow or supervisor for operational cleanup.
Exception path: If the operational record cannot support a defendable accounting/VAT position, do not release it into Sage/VATprocessing.
Stage 16 - Historical audit, reopen, and control improvement
Role: Admin
Allowed action: Review historical cases, reopen when justified, and improve platform controls when patterns show repeatedfailure or ambiguity.
Resource(s) / system(s) used: Historical read surfaces; Supabase immutable event history, disputes, funding records,screenshots, tracking submissions, invoices, AI message history, and SOP/version tables.
Data touched: Historical funding events, liability decisions, payout outcomes, parent/child exception records, AI-message audittrail, and SOP/version changes.
Validation rules: Historical truth should not be silently rewritten. Reopen should be controlled and justified. Control improvementsshould target the workflow, not erase history.
State transition: Case is either archived with audit confidence, reopened through a controlled path, or used to trigger aprocess/policy improvement.
Next actor: No active next actor in the steady happy path; otherwise supervisor/importer/shipper may receive follow-up tasks.
Exception path: If repeated edge cases cluster around the same control gap - for example auth mismatch handling, wrong courierselection, funding mismatch stalling assumptions, or child-exception leakage - improve the workflow rather than rely on ad hocjudgement forever.
Admin happy-path summary
- Admin maintains the master controls and steps into live orders when risk, ambiguity, or financial exposure is above routinesupervisor handling.
- Routine DVA funding, quote maintenance, and shipment progression can flow under supervisor ownership while admin remainsthe escalation lane.
- Evidence capture and genuine operations can continue even if platform funding match is late; admin governs the anomaly withoutfreezing the real-world flow.
- Admin becomes active when same-auth-ref explanations are weak, liability is disputed, refund/credit/payout decisions arenon-routine, or accounting/VAT readiness is not defensible.
- Admin ensures parent/child exception structures reconcile back to original order baselines before final financial outcomes rely onthem.
Admin exception-path summary
- Weak payment explanation or auth mismatch: admin challenges, queries importer, and blocks forced reconciliation until justified.
- Tracking and invoice arrive in different order: admin preserves dynamic completeness without imposing false sequence rules.
- Funding not yet matched but invoice/tracking exists: admin treats that as a funding anomaly, not as a reason to block OCR,shipment readiness, or genuine shipper execution.
- Wrong courier selected: admin requires correction before shipper reliance or liability conclusions.
- OCR/manual line structure drifts away from the parent baseline: admin blocks final clearance and requires correction.

## Page 7

- Goods lost or damaged after progression: admin determines liability and chooses defensible refund/replacement/credit/payoutoutcome.
- Accounting/VAT impact unclear: admin holds release into Sage/compliance processing until operational truth is stable andfunding control is closed.
Order-to-closure simulation checks
- Simulation A - same-auth-ref exception needs governance: statement line arrives with a plausible but weak auth explanation;admin reviews evidence and either approves a controlled reconciliation or rejects it and pushes the question back to the importer.
- Simulation B - invoice and tracking arrive before funding match closes: importer captures invoice, invoice ref, and tracking; OCRand ready-for-shipment preparation continue; admin keeps final financial/control closure blocked until funding is recognized.
- Simulation C - tracking before invoice with later OCR child exception: admin does not force false sequence or false clearance.Correct lines may progress, but the parent only fully clears after the child outcome reconciles back.
- Simulation D - shipper damage with disputed liability: admin reviews importer evidence, shipper evidence, booking/POD records,and retailer context, then assigns liable_party and chooses the commercial remedy aligned to both evidence and downstreamaccounting treatment.
- Simulation E - refund versus carried credit versus payout versus replacement child order: admin decides whether the fair andoperationally clean outcome is refund, carried-forward credit, payout, or replacement child order and keeps the chosen pathtraceable.
Admin resource map by node
Governance / exception queue: Next.js / Vercel admin screens; Supabase staff-gated data access.
FX and control maintenance: Supabase fx_rates, countries/currencies, SOP and retailer SOP tables.
Funding governance: order_funding_position_vw, dva_statements, dva_statement_lines, match_suggestions,importer_credit_ledger, order_funding_events.
Dynamic post-purchase completeness: order_tracking_submissions, couriers, supplier_invoices, order_screenshots.
OCR / child-exception governance: Mindee OCR output through supplier_invoice_lines, order_reconciliation_vw,disputes/dispute_lines.
Retailer communication governance: Server-side AI drafting service; retailer_sops; dispute_messages threading;ai_input_context_json; ai_model_used; ai_prompt_hash; refund gate and status-transition logic.
Shipping / liability governance: shipping_quotes, shipment evidence, shipper_liabilities, POD / booking references,ready-for-shipment handoff views.
Financial outcomes: disputes, payout_requests, importer_credit_ledger, replacement child orders, downstream Sage Cloud APIreadiness.
Audit and control improvement: immutable histories, SOP versions, retailer SOPs, GitHub/docs as delivery artefacts rather thanruntime actor tools.
Internal working document - canonical admin role matrix for the Multi Tenant Platform Build (Revision 6).

## Page 8
