import Link from "next/link";
import { notFound } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import { saveRetailerUpdateAction } from "./actions";

type SearchParams = {
  success?: string;
  error?: string;
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

  const [{ data: order }, { data: lines }, { data: messages }] = await Promise.all([
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
  ]);

  const activeStatus = (lines ?? []).find((line) => line.conversation_status)?.conversation_status ?? "retailer_contacted";
  const retailerOutcome = retailerOutcomeFromStatus(activeStatus);
  const isFinalOutcome = FINAL_OUTCOME_STATUSES.has(dispute.status ?? "");
  const isTerminalAcceptedState = dispute.status === "replaced" || dispute.status === "awaiting_refund_credit";

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
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3"><p className="text-xs uppercase text-slate-500">Refund approval</p><p className="mt-1 font-semibold">{dispute.refund_approved_at ? "Approved" : "Pending staff approval"}</p></div>
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
          <p className="mt-2 text-sm text-slate-600">Save retailer response and outcome in one atomic update.</p>
          {!isTerminalAcceptedState ? <p className="mt-3 text-sm text-slate-700"><span className="font-semibold">Current retailer outcome:</span> {retailerOutcome.replaceAll("_", " ")}</p> : null}
          {isTerminalAcceptedState ? (
            <p className="mt-3 text-sm text-slate-700">
              <span className="font-semibold">Active terminal state:</span> {finalOutcomeMessage(dispute)}
            </p>
          ) : null}
          {isFinalOutcome ? (
            <p className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
              Retailer updates are locked because the final outcome has already been accepted.
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
                  <option value="still_waiting">still_waiting</option>
                  <option value="retailer_accepted">retailer_accepted</option>
                  <option value="retailer_disputed">retailer_disputed</option>
                  <option value="more_info_requested">more_info_requested</option>
                </select>
              </label>
              <button type="submit" className="rounded-xl bg-sky-700 px-4 py-2 text-sm font-semibold text-white">Save retailer update</button>
            </form>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Conversation history</h2>
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
