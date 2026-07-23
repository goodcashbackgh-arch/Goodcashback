import Link from "next/link";
import { notFound } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import {
  acceptFinalRefundOutcomeAction,
  acceptReplacementOutcomeAction,
  approveRefundPursuitAction,
  reviewRefundEvidenceAction,
  reviewReturnCollectionEvidenceAction,
} from "./actions";

type SearchParams = { success?: string; error?: string };

type SupplierInvoiceOption = {
  id: string;
  invoice_ref: string | null;
  invoice_pdf_url: string | null;
  uploaded_at: string | null;
  review_status?: string | null;
};

type MessageRow = {
  id: string;
  message_type: string | null;
  counterparty: string | null;
  body: string | null;
  generated_by: string | null;
  created_at: string | null;
};

type RefundEvidenceSubmissionRow = {
  id: string;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  variance_abs_gbp: number | null;
  credit_note_file_url: string | null;
  refund_proof_file_url: string | null;
  ocr_status: string | null;
  match_status: string | null;
  amount_balance_status: string | null;
  supplier_control_status: string | null;
  supplier_approval_status: string | null;
  supervisor_review_status: string | null;
  notes: string | null;
  submitted_at: string | null;
};

type ReturnTrackingSubmissionRow = {
  id: string;
  courier_id: string | null;
  couriers?: { name?: string | null } | { name?: string | null }[] | null;
  tracking_ref: string | null;
  tracking_date: string | null;
  tracking_evidence_url: string | null;
  retailer_return_instructions_file_url: string | null;
  return_label_file_url: string | null;
  return_proof_file_url: string | null;
  submitted_at: string | null;
  is_final_return_yn: boolean | null;
  review_status: string | null;
  note: string | null;
};

const FINAL_OUTCOME_STATUSES = new Set(["approved_replacement", "replaced", "awaiting_refund_credit", "refunded", "closed"]);

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes((value ?? "").trim().toLowerCase());
}

function retailerOutcomeFromStatus(status: string | null | undefined) {
  switch (status) {
    case "retailer_response_received":
      return "retailer_accepted";
    case "awaiting_retailer_resolution":
      return "retailer_disputed";
    case "retailer_draft_ready":
      return "more_info_requested";
    case "retailer_contacted":
    default:
      return "still_waiting";
  }
}

function finalOutcomeMessage(dispute: { desired_outcome: string | null; status: string | null; replacement_child_order_id?: string | null }) {
  if (dispute.desired_outcome === "replacement" && dispute.status === "replaced") return "Replacement accepted — child order created.";
  if (dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit") return "Refund accepted — awaiting refund credit processing.";
  if (dispute.status === "refunded") return "Refund processed — awaiting closure.";
  if (dispute.status === "closed") return "Exception closed.";
  return "Final outcome accepted.";
}

function messageIsRefundEvidence(message: MessageRow) {
  return ["credit_note_evidence", "refund_evidence"].includes(message.message_type ?? "");
}

function evidenceNeedsSupervisorReview(body: string | null | undefined) {
  const text = body ?? "";
  return (
    text.includes("variance_supervisor_review_required") ||
    text.includes("no_document_supervisor_review_required") ||
    text.includes("supplier_refund_adjustment_review_required")
  );
}

function evidenceStatusLabel(body: string | null | undefined) {
  const text = body ?? "";
  if (text.includes("credit_note_uploaded_pending_ocr_compare")) return "Credit note uploaded — pending OCR/compare";
  if (text.includes("refund_adjustment_ready_no_credit_note")) return "No-credit-note refund adjustment ready";
  if (evidenceNeedsSupervisorReview(text)) return "Supervisor review needed";
  if (text.includes("balanced_to_exception")) return "Balanced to exception";
  return "Evidence uploaded";
}

function returnEvidenceStatusLabel(body: string | null | undefined) {
  const text = body ?? "";
  if (text.includes("is_final_return_yn: true")) return "Final return/collection submitted";
  if (text.includes("tracking_ref: —") && text.includes("return_label_file_url: —") && text.includes("return_proof_file_url: —")) return "Return instructions / note only";
  return "Return/collection evidence submitted";
}

function friendlyStatus(value: string | null | undefined) {
  if (!value) return "Pending";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function documentModeLabel(value: string | null | undefined) {
  if (value === "credit_note") return "Credit note issued";
  if (value === "refund_proof_no_credit_note") return "Refund proof, no credit note";
  if (value === "no_document") return "No document issued";
  return friendlyStatus(value);
}

function structuredRefundEvidenceStatus(row: RefundEvidenceSubmissionRow | null) {
  if (!row) return "Waiting for operator evidence";
  if (row.document_mode === "credit_note") {
    if (row.ocr_status === "completed" && row.amount_balance_status === "balanced") return "Credit note OCR completed — balanced";
    if (row.ocr_status === "completed") return "Credit note OCR completed";
    return "Credit note submitted — pending OCR";
  }
  if (row.document_mode === "refund_proof_no_credit_note") return "Refund proof submitted";
  if (row.document_mode === "no_document") return "No-document evidence submitted";
  return "Refund evidence submitted";
}

function structuredEvidenceNeedsSupervisorReview(row: RefundEvidenceSubmissionRow | null) {
  if (!row) return false;
  return row.document_mode === "no_document" || row.supervisor_review_status === "pending_review" || row.amount_balance_status === "variance" || row.match_status === "needs_supervisor_review";
}

function returnTrackingLabel(row: ReturnTrackingSubmissionRow | null) {
  if (!row) return "No return evidence yet";
  if (row.is_final_return_yn) return "Final return/collection submitted";
  if (row.tracking_ref || row.return_label_file_url || row.return_proof_file_url) return "Return/collection evidence submitted";
  return "Return instructions / note only";
}

function courierName(row: ReturnTrackingSubmissionRow) {
  const courier = Array.isArray(row.couriers) ? row.couriers[0] : row.couriers;
  return courier?.name ?? row.courier_id ?? "Not provided";
}

export default async function InternalExceptionDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ dispute_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { dispute_id: disputeId } = await params;
  const query = (await searchParams) ?? {};
  const supabase = await createClient();

  const { data: dispute, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id, resolved_at")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) notFound();

  const [
    { data: order },
    { data: supplierInvoices },
    { data: messages },
    { data: disputeLines },
    { data: refundEvidenceSubmissionsRaw },
    { data: returnTrackingSubmissionsRaw },
  ] = await Promise.all([
    supabase.from("orders").select("id, order_ref, total_qty_declared, order_total_gbp_declared").eq("id", dispute.order_id).maybeSingle(),
    supabase.from("supplier_invoices").select("id, invoice_ref, invoice_pdf_url, review_status, uploaded_at").eq("order_id", dispute.order_id).order("uploaded_at", { ascending: false }),
    supabase.from("dispute_messages").select("id, message_type, counterparty, body, generated_by, created_at").eq("dispute_id", disputeId).order("created_at", { ascending: true }),
    supabase.from("dispute_lines").select("id, supplier_invoice_line_id, qty_impact, amount_impact_gbp, conversation_status, resolved_at").eq("dispute_id", disputeId),
    supabase
      .from("dispute_refund_evidence_submissions")
      .select("id, document_mode, credit_note_ref, credit_note_date, expected_credit_note_total_gbp, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, credit_note_file_url, refund_proof_file_url, ocr_status, match_status, amount_balance_status, supplier_control_status, supplier_approval_status, supervisor_review_status, notes, submitted_at")
      .eq("dispute_id", disputeId)
      .order("submitted_at", { ascending: false }),
    supabase
      .from("dispute_return_tracking_submissions")
      .select("id, courier_id, tracking_ref, tracking_date, tracking_evidence_url, retailer_return_instructions_file_url, return_label_file_url, return_proof_file_url, submitted_at, is_final_return_yn, review_status, note, couriers(name)")
      .eq("dispute_id", disputeId)
      .order("submitted_at", { ascending: false }),
  ]);

  const activeDisputeLine =
  (disputeLines ?? []).find(
    (line) => line.resolved_at === null && line.supplier_invoice_line_id
  ) ?? null;

const { data: linkedInvoiceLine } =
  activeDisputeLine?.supplier_invoice_line_id
    ? await supabase
        .from("supplier_invoice_lines")
       .select(`
  id,
  description,
  supplier_invoices (
    id,
    invoice_ref,
    invoice_pdf_url,
    uploaded_at,
    review_status
  )
`)
        .eq("id", activeDisputeLine.supplier_invoice_line_id)
        .maybeSingle()
    : { data: null };

const linkedInvoice = Array.isArray(linkedInvoiceLine?.supplier_invoices)
  ? linkedInvoiceLine.supplier_invoices[0]
  : linkedInvoiceLine?.supplier_invoices;

const invoiceOptions = (supplierInvoices ?? []) as SupplierInvoiceOption[];

const invoice = linkedInvoice ?? invoiceOptions[0] ?? null;
  const { data: allInvoiceLines } = invoice
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, line_order, line_source, description, qty, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] };

  const messageRows = (messages ?? []) as MessageRow[];
  const refundEvidenceSubmissions = (refundEvidenceSubmissionsRaw ?? []) as RefundEvidenceSubmissionRow[];
  const latestStructuredRefundEvidence = refundEvidenceSubmissions[0] ?? null;
  const returnTrackingSubmissions = (returnTrackingSubmissionsRaw ?? []) as ReturnTrackingSubmissionRow[];
  const latestReturnTracking = returnTrackingSubmissions[0] ?? null;
  const progressedCount = (allInvoiceLines ?? []).filter((line) => isProgressed(line.eligible_for_invoice_yn)).length;
  const unresolvedCount = (allInvoiceLines ?? []).filter((line) => !isProgressed(line.eligible_for_invoice_yn)).length;
  const activeConversationStatus = (disputeLines ?? []).find((line) => line.resolved_at === null)?.conversation_status ?? null;
  const retailerOutcomeLabel = retailerOutcomeFromStatus(activeConversationStatus);
  const hasRetailerReply = messageRows.some((message) => message.message_type === "retailer_reply" && message.counterparty === "retailer");
  const refundEvidenceMessages = messageRows.filter(messageIsRefundEvidence);
  const latestRefundEvidence = refundEvidenceMessages[refundEvidenceMessages.length - 1] ?? null;
  const latestEvidenceNeedsReview = latestStructuredRefundEvidence ? structuredEvidenceNeedsSupervisorReview(latestStructuredRefundEvidence) : evidenceNeedsSupervisorReview(latestRefundEvidence?.body);
  const hasRefundEvidenceReview = messageRows.some((message) => message.message_type === "refund_evidence_review") || Boolean(latestStructuredRefundEvidence?.supervisor_review_status && latestStructuredRefundEvidence.supervisor_review_status !== "not_required");
  const returnEvidenceMessages = messageRows.filter((message) => message.message_type === "return_collection_evidence");
  const latestReturnEvidence = returnEvidenceMessages[returnEvidenceMessages.length - 1] ?? null;
  const hasReturnEvidenceReview = messageRows.some((message) => message.message_type === "return_collection_evidence_review") || Boolean(latestReturnTracking?.review_status && latestReturnTracking.review_status !== "pending_review");
  const canAcceptOutcome = hasRetailerReply && retailerOutcomeLabel === "retailer_accepted";
  const isFinalOutcome = FINAL_OUTCOME_STATUSES.has(dispute.status ?? "");
  const isTerminalAcceptedState = dispute.status === "replaced" || dispute.status === "awaiting_refund_credit";
  const hasAnyRefundEvidence = Boolean(latestStructuredRefundEvidence || latestRefundEvidence);
  const refundEvidenceBadgeLabel = latestStructuredRefundEvidence ? structuredRefundEvidenceStatus(latestStructuredRefundEvidence) : latestRefundEvidence ? evidenceStatusLabel(latestRefundEvidence.body) : "Waiting for operator evidence";

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-7xl space-y-6">
        <FlashQueryParamCleaner />
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/exceptions" className="text-sm font-semibold text-sky-600">← Back to child exceptions</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Internal exception review</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Dispute {dispute.id}</h1>
          <p className="mt-2 text-sm text-slate-600">Order {order?.order_ref ?? dispute.order_id} · Outcome {dispute.desired_outcome} · Status {dispute.status}</p>
          <div className="mt-4 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Declared qty</p><p className="mt-1 font-semibold">{order?.total_qty_declared ?? "—"}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Declared value</p><p className="mt-1 font-semibold">{gbp(order?.order_total_gbp_declared)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Progressed lines</p><p className="mt-1 font-semibold">{progressedCount}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Unresolved lines</p><p className="mt-1 font-semibold">{unresolvedCount}</p></div>
          </div>
          {query.success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">{query.success}</p> : null}
          {query.error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{query.error}</p> : null}
          {isFinalOutcome ? (
            <div className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
              <p className="font-semibold">{finalOutcomeMessage(dispute)}</p>
              {dispute.replacement_child_order_id ? <p className="mt-1">Replacement child order: {dispute.replacement_child_order_id}</p> : null}
              {hasAnyRefundEvidence ? <p className="mt-1">Refund evidence status: {refundEvidenceBadgeLabel}</p> : null}
              {latestReturnTracking ? <p className="mt-1">Return evidence status: {returnTrackingLabel(latestReturnTracking)}</p> : latestReturnEvidence ? <p className="mt-1">Return evidence status: {returnEvidenceStatusLabel(latestReturnEvidence.body)}</p> : null}
            </div>
          ) : null}
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Source context</h2>
            <p className="mt-2 text-sm text-slate-600">Parent order and supplier invoice context.</p>
            <div className="mt-4 space-y-2 text-sm">
              <p>
  <span className="font-semibold">
    Exception-linked supplier invoice:
  </span>{" "}
  {invoice?.invoice_ref ?? "—"}
</p>

{linkedInvoiceLine?.description ? (
  <p>
    <span className="font-semibold">Affected item:</span>{" "}
    {linkedInvoiceLine.description}
  </p>
) : null}

{invoice?.invoice_pdf_url ? (
  <a
    href={invoice.invoice_pdf_url}
    target="_blank"
    rel="noopener noreferrer"
    className="text-sky-700 underline"
  >
    Open exception-linked supplier invoice PDF
  </a>
) : null}
              <p className="text-xs text-slate-500">Supplier invoice records available for this order: {invoiceOptions.length}</p>
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Supervisor actions</h2>
            {!isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Retailer outcome:</span> {retailerOutcomeLabel.replaceAll("_", " ")}</p> : null}
            {isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Active terminal state:</span> {finalOutcomeMessage(dispute)}</p> : null}
            {isFinalOutcome ? (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                Final retailer outcome has been accepted. Structured refund evidence now routes through the refund document control lane. Return/collection evidence remains operational evidence and can be accepted, held or rejected separately.
              </p>
            ) : dispute.desired_outcome === "refund" ? (
              <div className="mt-4 space-y-3">
                <form action={approveRefundPursuitAction}>
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <button type="submit" disabled={Boolean(dispute.refund_approved_at)} className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Approve refund pursuit / push to operator</button>
                </form>
                <form action={acceptFinalRefundOutcomeAction}>
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <button type="submit" disabled={!canAcceptOutcome} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Accept final refund outcome</button>
                </form>
              </div>
            ) : (
              <form action={acceptReplacementOutcomeAction} className="mt-4">
                <input type="hidden" name="dispute_id" value={dispute.id} />
                <button type="submit" disabled={Boolean(dispute.replacement_child_order_id) || !canAcceptOutcome} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Accept replacement outcome</button>
              </form>
            )}
            {dispute.replacement_child_order_id ? <p className="mt-3 text-sm text-slate-700">Replacement child order: {dispute.replacement_child_order_id}</p> : null}
          </article>
        </section>

        {dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit" ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <p className="text-sm font-medium uppercase tracking-[0.2em] text-slate-500">Return / collection evidence</p>
                <h2 className="mt-2 text-xl font-semibold">Supervisor review of return tracking and uploads</h2>
                <p className="mt-2 max-w-3xl text-sm text-slate-600">
                  Review courier/tracking details, retailer instructions, labels and proof. This is operational evidence and does not approve the supplier refund/credit-note value.
                </p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${latestReturnTracking || latestReturnEvidence ? "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200" : "bg-slate-100 text-slate-700 ring-1 ring-slate-200"}`}>
                {latestReturnTracking ? returnTrackingLabel(latestReturnTracking) : latestReturnEvidence ? returnEvidenceStatusLabel(latestReturnEvidence.body) : "No return evidence yet"}
              </span>
            </div>

            {latestReturnTracking ? (
              <div className="mt-5 space-y-4">
                <article className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                  <p className="font-semibold">Latest structured return evidence · {friendlyStatus(latestReturnTracking.review_status)}</p>
                  <div className="mt-2 space-y-1 text-slate-700">
                    <p>Courier: {courierName(latestReturnTracking)}</p>
                    <p>Tracking ref: {latestReturnTracking.tracking_ref ?? "—"}</p>
                    <p>Tracking date: {latestReturnTracking.tracking_date ?? "—"}</p>
                    {latestReturnTracking.tracking_evidence_url ? <p><a href={latestReturnTracking.tracking_evidence_url} target="_blank" className="text-sky-700 underline">Open tracking/evidence link</a></p> : null}
                    {latestReturnTracking.retailer_return_instructions_file_url ? <p><a href={latestReturnTracking.retailer_return_instructions_file_url} target="_blank" className="text-sky-700 underline">Open retailer instructions</a></p> : null}
                    {latestReturnTracking.return_label_file_url ? <p><a href={latestReturnTracking.return_label_file_url} target="_blank" className="text-sky-700 underline">Open return label</a></p> : null}
                    {latestReturnTracking.return_proof_file_url ? <p><a href={latestReturnTracking.return_proof_file_url} target="_blank" className="text-sky-700 underline">Open return proof</a></p> : null}
                    <p>Final return/collection: {latestReturnTracking.is_final_return_yn ? "Yes" : "No"}</p>
                    <p>Note: {latestReturnTracking.note || "No note."}</p>
                  </div>
                  <p className="mt-2 text-xs text-slate-500">{latestReturnTracking.submitted_at}</p>
                </article>

                {hasReturnEvidenceReview ? (
                  <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
                    A supervisor return/collection evidence review already exists. Add a new review only if the operator submits corrected or additional evidence.
                  </p>
                ) : null}

                <form action={reviewReturnCollectionEvidenceAction} className="space-y-3 rounded-2xl border border-slate-200 bg-white p-4">
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <input type="hidden" name="return_tracking_submission_id" value={latestReturnTracking.id} />
                  <label className="block text-sm font-semibold text-slate-700">
                    Review decision
                    <select name="review_decision" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" defaultValue="accepted">
                      <option value="accepted">Accept return/collection evidence</option>
                      <option value="hold">Hold / ask operator to resubmit</option>
                      <option value="rejected">Reject return/collection evidence</option>
                    </select>
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Review notes
                    <textarea name="review_notes" rows={4} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Accepted / missing tracking ref / wrong label / ask operator to upload proof" />
                  </label>
                  <button type="submit" className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white">Save return evidence review</button>
                </form>
              </div>
            ) : latestReturnEvidence ? (
              <div className="mt-5 space-y-4">
                <article className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                  <p className="font-semibold">Legacy return evidence · {latestReturnEvidence.generated_by}</p>
                  <p className="mt-2 whitespace-pre-wrap">{latestReturnEvidence.body}</p>
                  <p className="mt-2 text-xs text-slate-500">{latestReturnEvidence.created_at}</p>
                </article>
              </div>
            ) : (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">Operator return/collection evidence has not been uploaded yet.</p>
            )}
          </section>
        ) : null}

        {dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit" ? (
          <section className="rounded-3xl border border-amber-200 bg-white p-6 shadow-sm">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Refund evidence status</p>
                <h2 className="mt-2 text-xl font-semibold">Structured refund document / credit note control</h2>
                <p className="mt-2 max-w-3xl text-sm text-slate-600">
                  Credit notes, refund proof and no-document evidence are controlled in the supplier credit/refund document lane. DVA/card refund IN matching still clears the money position.
                </p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${hasAnyRefundEvidence ? "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200" : "bg-amber-50 text-amber-800 ring-1 ring-amber-200"}`}>
                {refundEvidenceBadgeLabel}
              </span>
            </div>

            {latestStructuredRefundEvidence ? (
              <div className="mt-5 space-y-4">
                <article className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm">
                  <p className="font-semibold">Latest structured refund evidence · {documentModeLabel(latestStructuredRefundEvidence.document_mode)}</p>
                  <div className="mt-2 grid gap-2 text-slate-800 sm:grid-cols-2 lg:grid-cols-3">
                    <p>Ref: {latestStructuredRefundEvidence.credit_note_ref ?? "—"}</p>
                    <p>Date: {latestStructuredRefundEvidence.credit_note_date ?? "—"}</p>
                    <p>Expected total: {gbp(latestStructuredRefundEvidence.expected_credit_note_total_gbp ?? latestStructuredRefundEvidence.captured_refund_amount_abs_gbp ?? latestStructuredRefundEvidence.expected_exception_amount_abs_gbp)}</p>
                    <p>OCR: {friendlyStatus(latestStructuredRefundEvidence.ocr_status)}</p>
                    <p>Match: {friendlyStatus(latestStructuredRefundEvidence.match_status)}</p>
                    <p>Amount: {friendlyStatus(latestStructuredRefundEvidence.amount_balance_status)}</p>
                    <p>Control: {friendlyStatus(latestStructuredRefundEvidence.supplier_control_status)}</p>
                    <p>Approval: {friendlyStatus(latestStructuredRefundEvidence.supplier_approval_status)}</p>
                    <p>Review: {friendlyStatus(latestStructuredRefundEvidence.supervisor_review_status)}</p>
                  </div>
                  <div className="mt-3 flex flex-wrap gap-3 text-sm">
                    {latestStructuredRefundEvidence.credit_note_file_url ? <a href={latestStructuredRefundEvidence.credit_note_file_url} target="_blank" className="font-semibold text-sky-700 underline">Open credit note file</a> : null}
                    {latestStructuredRefundEvidence.refund_proof_file_url ? <a href={latestStructuredRefundEvidence.refund_proof_file_url} target="_blank" className="font-semibold text-sky-700 underline">Open refund proof</a> : null}
                    <Link href={`/internal/refund-document-control/${latestStructuredRefundEvidence.id}`} className="font-semibold text-sky-700 underline">Open refund document control</Link>
                    {latestStructuredRefundEvidence.document_mode === "credit_note" ? <Link href={`/internal/refund-document-control/${latestStructuredRefundEvidence.id}/ocr`} className="font-semibold text-sky-700 underline">Open credit-note OCR</Link> : null}
                  </div>
                  {latestStructuredRefundEvidence.notes ? <p className="mt-3 text-slate-700">Notes: {latestStructuredRefundEvidence.notes}</p> : null}
                  <p className="mt-2 text-xs text-slate-500">Submitted {latestStructuredRefundEvidence.submitted_at}</p>
                </article>

                {latestEvidenceNeedsReview ? (
                  <p className="rounded-2xl border border-amber-200 bg-white p-4 text-sm text-amber-900">
                    This structured evidence needs review/control in the refund document lane. Use the control/OCR links above rather than treating it as missing operator evidence.
                  </p>
                ) : (
                  <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
                    Structured refund evidence exists. Continue via supplier credit/refund document control and DVA/card refund matching.
                  </p>
                )}
              </div>
            ) : latestRefundEvidence ? (
              <div className="mt-5 space-y-4">
                <article className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm">
                  <p className="font-semibold">Latest legacy refund evidence · {latestRefundEvidence.message_type} · {latestRefundEvidence.generated_by}</p>
                  <p className="mt-2 whitespace-pre-wrap">{latestRefundEvidence.body}</p>
                  <p className="mt-2 text-xs text-slate-500">{latestRefundEvidence.created_at}</p>
                </article>

                {!latestEvidenceNeedsReview ? (
                  <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
                    No manual evidence review is required for this status. Continue via supplier readiness and DVA/card refund matching.
                  </p>
                ) : (
                  <form action={reviewRefundEvidenceAction} className="space-y-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
                    <input type="hidden" name="dispute_id" value={dispute.id} />
                    {hasRefundEvidenceReview ? <p className="rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">A supervisor review already exists. Add another only if the decision changed.</p> : null}
                    <label className="block text-sm font-semibold text-slate-700">
                      Review decision
                      <select name="review_decision" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" defaultValue="hold">
                        <option value="accepted">Accept variance/no-document evidence</option>
                        <option value="hold">Hold / ask operator for clarification</option>
                        <option value="rejected">Reject evidence</option>
                      </select>
                    </label>
                    <label className="block text-sm font-semibold text-slate-700">
                      Review notes
                      <textarea name="review_notes" rows={4} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Explain why variance/no-document evidence is accepted or held." />
                    </label>
                    <button type="submit" className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white">Save exception evidence review</button>
                  </form>
                )}
              </div>
            ) : (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">Operator refund document / credit note evidence has not been uploaded yet.</p>
            )}
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Conversation log</h2>
          <div className="mt-5 space-y-3">
            {messageRows.map((message) => (
              <article key={message.id} className={`rounded-2xl border p-4 text-sm ${["credit_note_evidence", "refund_evidence", "refund_evidence_review", "return_collection_evidence", "return_collection_evidence_review"].includes(message.message_type ?? "") ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-slate-50"}`}>
                <p className="font-semibold">{message.message_type} · {message.counterparty} · generated_by {message.generated_by}</p>
                <p className="mt-1 whitespace-pre-wrap">{message.body}</p>
                <p className="mt-2 text-xs text-slate-500">{message.created_at}</p>
              </article>
            ))}
            {messageRows.length === 0 ? <p className="text-sm text-slate-600">No conversation messages yet.</p> : null}
          </div>
        </section>
      </div>
    </main>
  );
}
