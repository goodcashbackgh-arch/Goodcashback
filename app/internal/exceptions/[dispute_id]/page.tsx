import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  acceptFinalRefundOutcomeAction,
  acceptReplacementOutcomeAction,
  addDisputeInternalNoteAction,
  approveRefundPursuitAction,
} from "./actions";

type SearchParams = {
  success?: string;
  error?: string;
};

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

  const [{ data: order }, { data: screenshots }, { data: invoice }, { data: messages }, { data: disputeLines }] = await Promise.all([
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
      .select("id, invoice_ref, invoice_pdf_url, uploaded_at")
      .eq("order_id", dispute.order_id)
      .order("uploaded_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
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

  const { data: allInvoiceLines } = invoice
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, line_order, line_source, description, qty, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] };

  const disputeLineIdSet = new Set((disputeLines ?? []).map((line) => line.supplier_invoice_line_id));
  const progressedCount = (allInvoiceLines ?? []).filter((line) => isProgressed(line.eligible_for_invoice_yn)).length;
  const unresolvedCount = (allInvoiceLines ?? []).filter((line) => !isProgressed(line.eligible_for_invoice_yn)).length;
  const activeConversationStatus = (disputeLines ?? []).find((line) => line.resolved_at === null)?.conversation_status ?? null;
  const retailerOutcomeLabel = retailerOutcomeFromStatus(activeConversationStatus);
  const hasRetailerReply = (messages ?? []).some((message) => message.message_type === "retailer_reply" && message.counterparty === "retailer");
  const canAcceptOutcome = hasRetailerReply && retailerOutcomeLabel === "retailer_accepted";

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-7xl space-y-6">
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
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Source context</h2>
            <p className="mt-2 text-sm text-slate-600">Parent order evidence used by importer reconciliation.</p>
            <div className="mt-4 text-sm">
              <p><span className="font-semibold">Supplier invoice:</span> {invoice?.invoice_ref ?? "—"}</p>
              {invoice?.invoice_pdf_url ? <a href={invoice.invoice_pdf_url} target="_blank" className="text-sky-700 underline">Open supplier invoice PDF</a> : null}
            </div>
            <h3 className="mt-5 text-sm font-semibold uppercase tracking-wide text-slate-500">Original screenshots</h3>
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              {(screenshots ?? []).map((shot) => (
                <a key={shot.id} href={shot.screenshot_url} target="_blank" className="block rounded-xl border border-slate-200 p-2 text-xs text-sky-700 underline">Screenshot #{shot.display_order ?? "—"}</a>
              ))}
              {(screenshots ?? []).length === 0 ? <p className="text-sm text-slate-500">No screenshots attached.</p> : null}
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Supervisor actions</h2>
            <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Retailer outcome:</span> {retailerOutcomeLabel.replaceAll("_", " ")}</p>
            <p className="mt-1 text-xs text-slate-500">Final outcome acceptance requires at least one retailer reply and retailer outcome = accepted.</p>
            {dispute.desired_outcome === "refund" ? (
              <div className="mt-4 space-y-3">
                <form action={approveRefundPursuitAction}>
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <button type="submit" disabled={Boolean(dispute.refund_approved_at)} className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Approve refund pursuit</button>
                </form>
                <form action={acceptFinalRefundOutcomeAction}>
                  <input type="hidden" name="dispute_id" value={dispute.id} />
                  <button type="submit" disabled={!canAcceptOutcome} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600 disabled:cursor-not-allowed disabled:bg-slate-300">Accept final refund outcome</button>
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

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Invoice lines (dispute lines highlighted)</h2>
          <div className="mt-4 space-y-2">
            {(allInvoiceLines ?? []).map((line) => {
              const inDispute = disputeLineIdSet.has(line.id);
              return (
                <article key={line.id} className={`rounded-2xl border p-3 text-sm ${inDispute ? "border-amber-300 bg-amber-50" : "border-slate-200 bg-slate-50"}`}>
                  <p className="font-semibold">Line {line.line_order} · {line.line_source}</p>
                  <p>{line.description}</p>
                  <p>Qty {line.qty} · Amount {gbp(line.amount_inc_vat_gbp)} · {isProgressed(line.eligible_for_invoice_yn) ? "Progressed" : "Unresolved"}</p>
                  {inDispute ? <p className="mt-1 text-xs font-semibold text-amber-900">In this dispute</p> : null}
                </article>
              );
            })}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Conversation log</h2>
          <div className="mt-4 max-w-xl">
            <form action={addDisputeInternalNoteAction} className="space-y-2 rounded-2xl border border-slate-200 bg-slate-50 p-4">
              <input type="hidden" name="dispute_id" value={dispute.id} />
              <h3 className="text-sm font-semibold">Add note (internal)</h3>
              <textarea name="body" required rows={4} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
              <button type="submit" className="rounded-xl bg-sky-700 px-4 py-2 text-sm font-semibold text-white">Save note</button>
            </form>
          </div>

          <div className="mt-5 space-y-3">
            {(messages ?? []).map((message) => (
              <article key={message.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
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
