import Link from "next/link";
import { notFound } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import { saveRetailerUpdateAction, uploadOperatorCreditNoteEvidenceAction } from "./actions";

type SearchParams = {
  success?: string;
  error?: string;
};

type SupplierInvoiceOption = {
  id: string;
  invoice_ref: string | null;
  invoice_pdf_url: string | null;
  review_status?: string | null;
  uploaded_at?: string | null;
};

type PrefillLine = {
  description: string;
  qty: number;
  amount: number;
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
    return "Replacement accepted — child order created";
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

  return "Final outcome accepted — no further retailer update is available.";
}

function normaliseAbsNumber(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? Math.abs(parsed) : 0;
}

export default async function ImporterExceptionDetailPage({
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
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !dispute) notFound();

  const [{ data: order }, { data: lines }, { data: messages }, { data: supplierInvoices }] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, total_qty_declared, order_total_gbp_declared")
      .eq("id", dispute.order_id)
      .maybeSingle(),
    supabase
      .from("dispute_lines")
      .select("id, qty_impact, amount_impact_gbp, conversation_status, supplier_invoice_lines!inner(id, line_order, line_source, description)")
      .eq("dispute_id", disputeId)
      .order("created_at", { ascending: true }),
    supabase
      .from("dispute_messages")
      .select("id, message_type, counterparty, body, generated_by, created_at")
      .eq("dispute_id", disputeId)
      .order("created_at", { ascending: true }),
    supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, invoice_pdf_url, review_status, uploaded_at")
      .eq("order_id", dispute.order_id)
      .order("uploaded_at", { ascending: false }),
  ]);

  const activeStatus = (lines ?? []).find((line) => line.conversation_status)?.conversation_status ?? "retailer_contacted";
  const retailerOutcome = retailerOutcomeFromStatus(activeStatus);
  const isFinalOutcome = FINAL_OUTCOME_STATUSES.has(dispute.status ?? "");
  const isTerminalAcceptedState = dispute.status === "replaced" || dispute.status === "awaiting_refund_credit";
  const canUploadRefundEvidence = dispute.desired_outcome === "refund" && dispute.status === "awaiting_refund_credit";
  const hasRefundEvidence = (messages ?? []).some((message) => ["credit_note_evidence", "refund_evidence"].includes(message.message_type ?? ""));
  const invoiceOptions = (supplierInvoices ?? []) as SupplierInvoiceOption[];

  const prefillLines: PrefillLine[] = (lines ?? []).slice(0, 5).map((line) => {
    const sourceLine = Array.isArray(line.supplier_invoice_lines) ? line.supplier_invoice_lines[0] : line.supplier_invoice_lines;
    return {
      description: sourceLine?.description ?? "Refund line",
      qty: normaliseAbsNumber(line.qty_impact),
      amount: normaliseAbsNumber(line.amount_impact_gbp),
    };
  });

  while (prefillLines.length < 5) {
    prefillLines.push({ description: "", qty: 0, amount: 0 });
  }

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl space-y-6">
        <FlashQueryParamCleaner />
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/importer/reconciliation/${dispute.order_id}`} className="text-sm font-semibold text-sky-600">← Back to reconciliation</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Importer exception workflow</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Dispute {dispute.id}</h1>
          <p className="mt-2 text-sm text-slate-600">Parent order {order?.order_ref ?? dispute.order_id} · Outcome {dispute.desired_outcome} · Status {dispute.status}</p>
          <div className="mt-4 grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Declared qty</p><p className="mt-1 font-semibold">{order?.total_qty_declared ?? "—"}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Declared value</p><p className="mt-1 font-semibold">{gbp(order?.order_total_gbp_declared)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Dispute amount</p><p className="mt-1 font-semibold">{gbp(dispute.amount_impact_gbp)}</p></div>
            {dispute.desired_outcome === "refund" ? (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Refund approval</p><p className="mt-1 font-semibold">{dispute.refund_approved_at ? "Pursuit approved" : "Pending staff approval"}</p></div>
            ) : (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Dispute type</p><p className="mt-1 font-semibold">Replacement</p></div>
            )}
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

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Affected lines</h2>
          <div className="mt-4 space-y-2">
            {(lines ?? []).map((line) => {
              const sourceLine = Array.isArray(line.supplier_invoice_lines) ? line.supplier_invoice_lines[0] : line.supplier_invoice_lines;
              return (
                <article key={line.id} className="rounded-2xl border border-amber-300 bg-amber-50 p-3 text-sm">
                  <p className="font-semibold">Line {sourceLine?.line_order ?? "—"} · {sourceLine?.line_source ?? "—"}</p>
                  <p>{sourceLine?.description ?? "No description"}</p>
                  <p>Qty impact {line.qty_impact} · Amount impact {gbp(line.amount_impact_gbp)}</p>
                </article>
              );
            })}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Retailer update</h2>
          <p className="mt-2 text-sm text-slate-600">Paste the retailer response first. If the retailer accepts the refund, mark the outcome as accepted so the supervisor can review and accept the final outcome.</p>
          {!isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Current retailer outcome:</span> {retailerOutcome.replaceAll("_", " ")}</p> : null}
          {isTerminalAcceptedState ? (
            <p className="mt-3 text-sm text-slate-700">
              <span className="font-semibold">Active terminal state:</span> {finalOutcomeMessage(dispute)}
            </p>
          ) : null}
          {isFinalOutcome ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
              Retailer update is locked because the supervisor has accepted the final outcome. Upload refund evidence below where applicable.
            </p>
          ) : (
            <form action={saveRetailerUpdateAction} className="mt-4 space-y-3">
              <input type="hidden" name="dispute_id" value={dispute.id} />
              <label className="block space-y-1">
                <span className="text-sm font-medium text-slate-700">Retailer response</span>
                <textarea name="retailer_response" rows={5} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
              </label>
              <label className="block space-y-1">
                <span className="text-sm font-medium text-slate-700">Retailer outcome</span>
                <select name="retailer_outcome" defaultValue={retailerOutcome} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm">
                  <option value="still_waiting">Still waiting</option>
                  <option value="retailer_accepted">Retailer accepted refund / remedy</option>
                  <option value="retailer_disputed">Retailer disputed / rejected</option>
                  <option value="more_info_requested">More information requested</option>
                </select>
              </label>
              <button type="submit" className="rounded-xl bg-sky-700 px-4 py-2 text-sm font-semibold text-white">Save retailer update</button>
            </form>
          )}
        </section>

        {dispute.desired_outcome === "refund" ? (
          <section className="rounded-3xl border border-amber-200 bg-white p-6 shadow-sm">
            <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
              <div>
                <p className="text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Refund evidence after supervisor acceptance</p>
                <h2 className="mt-2 text-xl font-semibold">Upload refund / credit-note evidence</h2>
                <p className="mt-2 max-w-3xl text-sm text-slate-600">
                  This appears only after the supervisor accepts the final retailer refund outcome. Lines are prefilled from the exception and recorded as negative refund evidence for supervisor review and later DVA/Sage treatment.
                </p>
              </div>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${hasRefundEvidence ? "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200" : "bg-amber-50 text-amber-800 ring-1 ring-amber-200"}`}>
                {hasRefundEvidence ? "Evidence uploaded" : "No refund evidence yet"}
              </span>
            </div>

            {!canUploadRefundEvidence ? (
              <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
                Waiting for supervisor to accept the final retailer refund outcome. The operator should first paste the retailer response and mark the retailer outcome above.
              </p>
            ) : invoiceOptions.length === 0 ? (
              <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800">
                No supplier invoice is linked to this order yet, so refund evidence cannot be linked safely.
              </p>
            ) : (
              <form action={uploadOperatorCreditNoteEvidenceAction} encType="multipart/form-data" className="mt-6 space-y-5">
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
                    Refund document mode
                    <select name="document_mode" defaultValue="credit_note" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                      <option value="credit_note">Retailer refund with credit note</option>
                      <option value="refund_proof_no_credit_note">Retailer refund without credit note</option>
                      <option value="no_document">No document issued</option>
                    </select>
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Credit note ref, if issued
                    <input name="credit_note_ref" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="e.g. CN-12345" />
                  </label>
                </div>

                <div className="grid gap-4 md:grid-cols-3">
                  <label className="block text-sm font-semibold text-slate-700">
                    Credit note date optional
                    <input name="credit_note_date" type="date" className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Credit note file, if issued
                    <input name="credit_note_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">
                    Refund proof file, if no credit note
                    <input name="refund_proof_file" type="file" className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" />
                  </label>
                </div>

                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <h3 className="font-semibold">Refund evidence lines</h3>
                  <p className="mt-1 text-xs text-slate-500">Prefilled from the exception. Values are recorded as negative refund evidence. Edit only if the retailer refund differs.</p>
                  <div className="mt-4 space-y-3">
                    {prefillLines.map((line, index) => {
                      const lineNumber = index + 1;
                      return (
                        <div key={lineNumber} className="grid gap-3 md:grid-cols-[1fr_120px_160px]">
                          <input name={`line_${lineNumber}_description`} defaultValue={line.description} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder={`Line ${lineNumber} description`} />
                          <input name={`line_${lineNumber}_qty`} type="number" step="0.01" min="0" defaultValue={line.qty || ""} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Qty" />
                          <input name={`line_${lineNumber}_amount_gbp`} type="number" step="0.01" min="0" defaultValue={line.amount || ""} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Amount GBP" />
                        </div>
                      );
                    })}
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

                <button type="submit" className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white">
                  Upload refund evidence for supervisor review
                </button>
              </form>
            )}
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Conversation history</h2>
          <div className="mt-5 space-y-3">
            {(messages ?? []).map((message) => (
              <article key={message.id} className={`rounded-2xl border p-4 text-sm ${["credit_note_evidence", "refund_evidence"].includes(message.message_type ?? "") ? "border-amber-200 bg-amber-50" : "border-slate-200 bg-slate-50"}`}>
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
