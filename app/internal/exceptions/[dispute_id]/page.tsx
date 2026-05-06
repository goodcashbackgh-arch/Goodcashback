import Link from "next/link";
import { notFound } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import {
  acceptFinalRefundOutcomeAction,
  acceptReplacementOutcomeAction,
  approveRefundPursuitAction,
  reviewRefundEvidenceAction,
} from "./actions";

type SearchParams = {
  success?: string;
  error?: string;
};

type SupplierInvoiceOption = {
  id: string;
  invoice_ref: string | null;
  invoice_pdf_url: string | null;
  uploaded_at: string | null;
  review_status?: string | null;
};

const FINAL_OUTCOME_STATUSES = new Set([
  "approved_replacement",
  "replaced",
  "awaiting_refund_credit",
  "refunded",
  "closed",
]);

function gbp(value: number | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
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
  if (dispute.desired_outcome === "replacement" && dispute.status === "replaced") {
    return "Replacement accepted — child order created.";
  }

  if (dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit") {
    return "Refund accepted — awaiting refund credit processing";
  }

  if (dispute.status === "refunded") {
    return "Refund processed — awaiting closure.";
  }

  if (dispute.status === "closed") {
    return "Exception closed.";
  }

  return "Final outcome accepted.";
}

function messageIsRefundEvidence(message: { message_type: string | null }) {
  return ["credit_note_evidence", "refund_evidence"].includes(message.message_type ?? "");
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

  const [{ data: order }, { data: screenshots }, { data: supplierInvoices }, { data: messages }, { data: disputeLines }] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, total_qty_declared, order_total_gbp_declared")
      .eq("id", dispute.order_id)
      .maybeSingle(),
    supabase
      .from("order_screenshots")
      .select("id, screenshot_url, display_order, uploaded_at")
      .eq("order_id", dispute.order_id)
      .order("display_order", { ascending: true })
      .order("uploaded_at", { ascending: true }),
    supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, invoice_pdf_url, review_status, uploaded_at")
      .eq("order_id", dispute.order_id)
      .order("uploaded_at", { ascending: false }),
    supabase
      .from("dispute_messages")
      .select("id, message_type, counterparty, body, generated_by, created_at")
      .eq("dispute_id", disputeId)
      .order("created_at", { ascending: true }),
    supabase
      .from("dispute_lines")
      .select("id, supplier_invoice_line_id, qty_impact, amount_impact_gbp, conversation_status, resolved_at")
      .eq("dispute_id", disputeId),
  ]);

  const invoiceOptions = (supplierInvoices ?? []) as SupplierInvoiceOption[];
  const invoice = invoiceOptions[0] ?? null;

  const { data: allInvoiceLines } = invoice
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, line_order, line_source, description, qty, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] };

  const messageRows = messages ?? [];
  const progressedCount = (allInvoiceLines ?? []).filter((line) => isProgressed(line.eligible_for_invoice_yn)).length;
  const unresolvedCount = (allInvoiceLines ?? []).filter((line) => !isProgressed(line.eligible_for_invoice_yn)).length;
  const activeConversationStatus = (disputeLines ?? []).find((line) => line.resolved_at === null)?.conversation_status ?? null;
  const retailerOutcomeLabel = retailerOutcomeFromStatus(activeConversationStatus);
  const hasRetailerReply = messageRows.some((message) => message.message_type === "retailer_reply" && message.counterparty === "retailer");
  const refundEvidenceMessages = messageRows.filter(messageIsRefundEvidence);
  const latestRefundEvidence = refundEvidenceMessages[refundEvidenceMessages.length - 1] ?? null;
  const hasRefundEvidenceReview = messageRows.some((message) => message.message_type === "refund_evidence_review");
  const canAcceptOutcome = hasRetailerReply && retailerOutcomeLabel === "retailer_accepted";
  const isFinalOutcome = FINAL_OUTCOME_STATUSES.has(dispute.status ?? "");
  const isTerminalAcceptedState = dispute.status === "replaced" || dispute.status === "awaiting_refund_credit";

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
              {latestRefundEvidence ? <p className="mt-1">Refund evidence uploaded by operator and awaiting/requiring supervisor review.</p> : null}
            </div>
          ) : null}
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Source context</h2>
            <p className="mt-2 text-sm text-slate-600">Parent order evidence used by importer reconciliation.</p>
            <div className="mt-4 space-y-2 text-sm">
              <p><span className="font-semibold">Latest supplier invoice:</span> {invoice?.invoice_ref ?? "—"}</p>
              {invoice?.invoice_pdf_url ? <a href={invoice.invoice_pdf_url} target="_blank" className="text-sky-700 underline">Open latest supplier invoice PDF</a> : null}
              <p className="text-xs text-slate-500">Supplier invoice records available for this order: {invoiceOptions.length}</p>
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Supervisor actions</h2>
            {!isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Retailer outcome:</span> {retailerOutcomeLabel.replaceAll("_", " ")}</p> : null}
            {isTerminalAcceptedState ? (
              <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Active terminal state:</span> {finalOutcomeMessage(dispute)}</p>
            ) : null}
            {isFinalOutcome ? (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                Final retailer outcome has been accepted. Continue with refund evidence review and DVA/card refund matching where applicable.
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
          <section className="rounded-3xl border border-amber-200 bg-white p-6 shadow-sm">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Refund evidence review</p>
                <h2 className="mt-2 text-xl font-semibold">Supervisor review of operator evidence</h2>
                <p className="mt-2 max-w-3xl text-sm text-slate-600">
                  Review the operator-uploaded refund/credit-note evidence. This does not clear the money position; DVA/card refund IN must still be matched separately.
                </p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${latestRefundEvidence ? "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200" : "bg-amber-50 text-amber-800 ring-1 ring-amber-200"}`}>
                {latestRefundEvidence ? "Evidence uploaded" : "Waiting for operator evidence"}
              </span>
            </div>

            {latestRefundEvidence ? (
              <div className="mt-5 space-y-4">
                <article className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm">
                  <p className="font-semibold">Latest refund evidence · {latestRefundEvidence.message_type} · {latestRefundEvidence.generated_by}</p>
                  <p className="mt-2 whitespace-pre-wrap">{latestRefundEvidence.body}</p>
                  <p className="mt-2 text-xs text-slate-500">{latestRefundEvidence.created_at}</p>
                </article>

                {hasRefundEvidenceReview ? (
                  <p className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900">
                    A supervisor refund evidence review already exists in the conversation log. Add a new review only if the operator uploads corrected evidence or the decision changes.
                  </p>
                ) : null}

                <form action={reviewRefundEvidenceAction} className="space-y-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <label className="block text-sm font-semibold text-slate-700">
                    Review decision
                    <select name="review_decision" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" defaultValue="accepted">
                      <option value="accepted">Accept evidence for DVA refund matching</option>
                      <option value="hold">Hold / ask operator for clarification</option>
                      <option value="rejected">Reject evidence</option>
                    </select>
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Review notes optional
                    <textarea name="review_notes" rows={4} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Evidence balances to exception / variance needs explanation / wrong document uploaded" />
                  </label>
                  <button type="submit" className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white">
                    Save refund evidence review
                  </button>
                </form>
              </div>
            ) : (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                Operator evidence has not been uploaded yet. Ask the operator to open the exception and upload credit note / refund proof / no-document explanation.
              </p>
            )}
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Conversation log</h2>
          <div className="mt-5 space-y-3">
            {messageRows.map((message) => (
              <article key={message.id} className={`rounded-2xl border p-4 text-sm ${["credit_note_evidence", "refund_evidence", "refund_evidence_review"].includes(message.message_type ?? "") ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-slate-50"}`}>
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
