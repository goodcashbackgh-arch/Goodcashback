import Link from "next/link";
import { notFound } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import {
  acceptFinalRefundOutcomeAction,
  acceptReplacementOutcomeAction,
  approveRefundPursuitAction,
} from "./actions";
import { recordExceptionEvidenceAction } from "./return-evidence-actions";

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

  const progressedCount = (allInvoiceLines ?? []).filter((line) => isProgressed(line.eligible_for_invoice_yn)).length;
  const unresolvedCount = (allInvoiceLines ?? []).filter((line) => !isProgressed(line.eligible_for_invoice_yn)).length;
  const activeConversationStatus = (disputeLines ?? []).find((line) => line.resolved_at === null)?.conversation_status ?? null;
  const retailerOutcomeLabel = retailerOutcomeFromStatus(activeConversationStatus);
  const hasRetailerReply = (messages ?? []).some((message) => message.message_type === "retailer_reply" && message.counterparty === "retailer");
  const hasCreditNoteEvidence = (messages ?? []).some((message) => message.message_type === "credit_note_evidence");
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
                Final outcome already accepted. No further supervisor action is required.
              </p>
            ) : dispute.desired_outcome === "refund" ? (
              <div className="mt-4 space-y-3">
                <form action={approveRefundPursuitAction}>
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <button type="submit" disabled={Boolean(dispute.refund_approved_at)} className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Approve refund pursuit</button>
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

        {dispute.desired_outcome === "refund" ? (
          <section className="rounded-3xl border border-amber-200 bg-white p-6 shadow-sm">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Physical refund / credit note evidence</p>
                <h2 className="mt-2 text-2xl font-semibold">Upload supplier credit note evidence</h2>
                <p className="mt-2 max-w-3xl text-sm text-slate-600">
                  Use this when the supplier invoice charged the item but the UK intake/refund path creates a supplier credit note. This links the credit note to the original order, supplier invoice and exception for later Sage supplier credit-note handling. It does not create a customer sales invoice line.
                </p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${hasCreditNoteEvidence ? "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200" : "bg-amber-50 text-amber-800 ring-1 ring-amber-200"}`}>
                {hasCreditNoteEvidence ? "Credit note evidence recorded" : "Credit note evidence not recorded"}
              </span>
            </div>

            <form action={recordExceptionEvidenceAction} encType="multipart/form-data" className="mt-6 space-y-5">
              <input type="hidden" name="dispute_id" value={dispute.id} />
              <input type="hidden" name="original_order_id" value={order?.id ?? dispute.order_id} />

              <div className="grid gap-4 lg:grid-cols-3">
                <label className="block text-sm font-semibold text-slate-700">
                  Original supplier invoice
                  <select name="original_supplier_invoice_id" required className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                    {invoiceOptions.map((option) => (
                      <option key={option.id} value={option.id}>
                        {option.invoice_ref ?? option.id} {option.review_status ? `· ${option.review_status}` : ""}
                      </option>
                    ))}
                  </select>
                </label>
                <label className="block text-sm font-semibold text-slate-700">
                  Credit note ref
                  <input name="credit_note_ref" required className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="e.g. CN-12345" />
                </label>
                <label className="block text-sm font-semibold text-slate-700">
                  Credit note date
                  <input name="credit_note_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
                </label>
              </div>

              <label className="block text-sm font-semibold text-slate-700">
                Credit note file
                <input name="credit_note_file" type="file" required className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
              </label>

              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <h3 className="font-semibold">Credit note lines</h3>
                <p className="mt-1 text-xs text-slate-500">Enter positive values; the system records them as negative credit-note quantities and amounts.</p>
                <div className="mt-4 space-y-3">
                  {[1, 2, 3, 4, 5].map((lineNumber) => (
                    <div key={lineNumber} className="grid gap-3 md:grid-cols-[1fr_120px_160px]">
                      <input name={`line_${lineNumber}_description`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder={`Line ${lineNumber} description`} />
                      <input name={`line_${lineNumber}_qty`} type="number" step="0.01" min="0" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Qty" />
                      <input name={`line_${lineNumber}_amount_gbp`} type="number" step="0.01" min="0" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Amount GBP" />
                    </div>
                  ))}
                </div>
              </div>

              <div className="grid gap-4 md:grid-cols-2">
                <label className="block text-sm font-semibold text-slate-700">
                  Delivery refund / adjustment GBP optional
                  <input name="delivery_adjustment_gbp" type="number" step="0.01" min="0" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="0.00" />
                </label>
                <label className="block text-sm font-semibold text-slate-700">
                  Discount adjustment GBP optional
                  <input name="discount_adjustment_gbp" type="number" step="0.01" min="0" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="0.00" />
                </label>
              </div>

              <div className="rounded-2xl border border-slate-200 bg-white p-4">
                <h3 className="font-semibold">Return / collection evidence optional</h3>
                <p className="mt-1 text-xs text-slate-500">Retailer collection, label and proof are optional because retailers handle returns differently.</p>
                <div className="mt-4 grid gap-4 md:grid-cols-3">
                  <label className="block text-sm font-semibold text-slate-700">
                    Return required
                    <select name="return_required" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                      <option value="unknown">Unknown</option>
                      <option value="no">No</option>
                      <option value="yes">Yes</option>
                    </select>
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Collection date optional
                    <input name="collection_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Return tracking ref optional
                    <input name="return_tracking_ref" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
                  </label>
                </div>
                <div className="mt-4 grid gap-4 md:grid-cols-2">
                  <label className="block text-sm font-semibold text-slate-700">
                    Return label upload optional
                    <input name="return_label_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Return proof upload optional
                    <input name="return_proof_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
                  </label>
                </div>
              </div>

              <label className="block text-sm font-semibold text-slate-700">
                Notes optional
                <textarea name="notes" rows={4} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Retailer confirmed refund / collection / credit note details" />
              </label>

              <button type="submit" disabled={invoiceOptions.length === 0} className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">
                Upload credit note evidence
              </button>
            </form>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Conversation log</h2>
          <div className="mt-5 space-y-3">
            {(messages ?? []).map((message) => (
              <article key={message.id} className={`rounded-2xl border p-4 text-sm ${message.message_type === "credit_note_evidence" ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-slate-50"}`}>
                <p className="font-semibold">{message.message_type} · {message.counterparty} · generated_by {message.generated_by}</p>
                <p className="mt-1 whitespace-pre-wrap">{message.body}</p>
                <p className="mt-2 text-xs text-slate-500">{message.created_at}</p>
              </article>
            ))}
            {(messages ?? []).length === 0 ? <p className="text-sm text-slate-600">No conversation messages yet.</p> : null}
          </div>
        </section>
      </div>
    </main>
  );
}
