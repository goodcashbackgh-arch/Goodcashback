import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type DisputeRow = {
  id: string;
  order_id: string;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | null;
  orders: { order_ref: string | null }[] | null;
};

type DisputeLineRow = {
  dispute_id: string;
  conversation_status: string | null;
  resolved_at: string | null;
};

type DisputeMessageRow = {
  dispute_id: string;
  message_type: string | null;
  counterparty: string | null;
  body: string | null;
  created_at: string | null;
};

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

function previewText(value: string | null | undefined, max = 84) {
  const text = (value ?? "").trim();
  if (!text) return "—";
  if (text.length <= max) return text;
  return `${text.slice(0, max - 1)}…`;
}

export default async function ImporterExceptionsPage() {
  const supabase = await createClient();

  const { data: disputes, error } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, orders!disputes_order_id_fkey(order_ref)")
    .in("desired_outcome", ["refund", "replacement"])
    .neq("status", "closed")
    .order("raised_at", { ascending: false });

  const disputeRows = (disputes ?? []) as DisputeRow[];
  const disputeIds = disputeRows.map((row) => row.id);

  const [{ data: disputeLines }, { data: retailerReplies }] = disputeIds.length
    ? await Promise.all([
        supabase
          .from("dispute_lines")
          .select("dispute_id, conversation_status, resolved_at")
          .in("dispute_id", disputeIds),
        supabase
          .from("dispute_messages")
          .select("dispute_id, message_type, counterparty, body, created_at")
          .in("dispute_id", disputeIds)
          .eq("message_type", "retailer_reply")
          .eq("counterparty", "retailer")
          .order("created_at", { ascending: false }),
      ])
    : [{ data: [] }, { data: [] }];

  const activeLineStatusByDispute = new Map<string, string | null>();
  for (const line of (disputeLines ?? []) as DisputeLineRow[]) {
    if (line.resolved_at !== null) continue;
    if (!activeLineStatusByDispute.has(line.dispute_id)) {
      activeLineStatusByDispute.set(line.dispute_id, line.conversation_status);
    }
  }

  const latestRetailerReplyByDispute = new Map<string, string>();
  for (const message of (retailerReplies ?? []) as DisputeMessageRow[]) {
    if (!latestRetailerReplyByDispute.has(message.dispute_id)) {
      latestRetailerReplyByDispute.set(message.dispute_id, previewText(message.body));
    }
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <div className="mx-auto max-w-7xl space-y-6">
        <header className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/importer" className="text-sm font-semibold text-sky-600">← Back to importer dashboard</Link>
          <h1 className="mt-3 text-3xl font-semibold tracking-tight">Importer Exceptions</h1>
          <p className="mt-2 text-sm text-slate-600">Active refund and replacement exception cases.</p>
        </header>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          {error ? <p className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">Failed to load disputes: {error.message}</p> : null}

          <div className="overflow-x-auto">
            <table className="min-w-full text-sm">
              <thead className="bg-slate-50 text-left">
                <tr>
                  <th className="p-3">Order ref</th>
                  <th className="p-3">Outcome</th>
                  <th className="p-3">Retailer position</th>
                  <th className="p-3">Status</th>
                  <th className="p-3">Amount</th>
                  <th className="p-3">Open</th>
                </tr>
              </thead>
              <tbody>
                {disputeRows.map((dispute) => {
                  const lineStatus = activeLineStatusByDispute.get(dispute.id) ?? null;
                  const retailerOutcome = retailerOutcomeFromStatus(lineStatus);
                  const retailerPosition = latestRetailerReplyByDispute.get(dispute.id) ?? "No retailer reply yet";

                  return (
                    <tr key={dispute.id} className="border-t border-slate-200">
                      <td className="p-3 font-medium">{dispute.orders?.[0]?.order_ref ?? dispute.order_id}</td>
                      <td className="p-3">{dispute.desired_outcome ?? "—"}</td>
                      <td className="p-3">{retailerPosition}</td>
                      <td className="p-3">{dispute.status ?? "—"} · {retailerOutcome}</td>
                      <td className="p-3">{gbp(dispute.amount_impact_gbp)}</td>
                      <td className="p-3">
                        <Link href={`/importer/exceptions/${dispute.id}`} className="font-semibold text-sky-700 underline">Open</Link>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {disputeRows.length === 0 ? <p className="mt-4 text-sm text-slate-600">No active refund/replacement cases.</p> : null}
        </section>
      </div>
    </main>
  );
}
