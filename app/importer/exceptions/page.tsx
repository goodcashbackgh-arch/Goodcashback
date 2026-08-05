import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type OrderRelation = { order_ref: string | null } | { order_ref: string | null }[] | null;

type DisputeRow = {
  id: string;
  order_id: string;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | null;
  replacement_child_order_id: string | null;
  orders: OrderRelation;
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

type ReplacementRouteRow = {
  dispute_id: string;
  route_status: string;
  successor_tracking_submission_id: string | null;
  successor_tracking_line_allocation_id: string | null;
};

type ReceiptRow = {
  tracking_submission_id: string;
  receipt_status: string;
};

type MembershipRow = {
  tracking_line_allocation_id: string;
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

function terminalStatusMessage(
  dispute: Pick<DisputeRow, "id" | "status" | "replacement_child_order_id">,
  routeByDisputeId: Map<string, ReplacementRouteRow>,
  latestReceiptByTrackingId: Map<string, string>,
  allocationIdsInShipment: Set<string>,
) {
  if (dispute.status === "replaced") {
    if (dispute.replacement_child_order_id) return "Replacement accepted — child order created";
    const route = routeByDisputeId.get(dispute.id);
    if (
      route?.route_status === "tracking_allocated"
      && route.successor_tracking_submission_id
      && route.successor_tracking_line_allocation_id
    ) {
      if (allocationIdsInShipment.has(route.successor_tracking_line_allocation_id)) {
        return "Replacement received clean — added to shipment";
      }
      if (latestReceiptByTrackingId.get(route.successor_tracking_submission_id) === "received_clean") {
        return "Replacement received clean — shipment eligible";
      }
      return "Successor tracking allocated — awaiting replacement receipt";
    }
    return "Replacement accepted — awaiting successor tracking";
  }
  if (dispute.status === "awaiting_refund_credit") return "Refund accepted — awaiting refund credit processing";
  return null;
}

function orderRef(value: OrderRelation, fallback: string) {
  const order = Array.isArray(value) ? value[0] : value;
  return order?.order_ref || fallback;
}

function disputeRef(id: string) {
  return `DSP-${id.slice(0, 8).toUpperCase()}`;
}

export default async function ImporterExceptionsPage() {
  const supabase = await createClient();

  const { data: disputes, error } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, replacement_child_order_id, orders!disputes_order_id_fkey(order_ref)")
    .in("desired_outcome", ["refund", "replacement"])
    .neq("status", "closed")
    .order("raised_at", { ascending: false });

  const disputeRows = (disputes ?? []) as DisputeRow[];
  const disputeIds = disputeRows.map((row) => row.id);

  const [{ data: disputeLines }, { data: retailerReplies }, { data: replacementRoutes }] = disputeIds.length
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
        supabase
          .from("physical_replacement_same_order_routes")
          .select("dispute_id, route_status, successor_tracking_submission_id, successor_tracking_line_allocation_id")
          .in("dispute_id", disputeIds),
      ])
    : [{ data: [] }, { data: [] }, { data: [] }];

  const routeRows = (replacementRoutes ?? []) as ReplacementRouteRow[];
  const successorTrackingIds = [...new Set(routeRows.map((route) => route.successor_tracking_submission_id).filter((id): id is string => Boolean(id)))];
  const successorAllocationIds = [...new Set(routeRows.map((route) => route.successor_tracking_line_allocation_id).filter((id): id is string => Boolean(id)))];

  const [{ data: receiptRows }, { data: membershipRows }] = await Promise.all([
    successorTrackingIds.length
      ? supabase
          .from("shipper_package_receipts")
          .select("tracking_submission_id, receipt_status, recorded_at")
          .in("tracking_submission_id", successorTrackingIds)
          .order("recorded_at", { ascending: false })
      : Promise.resolve({ data: [] }),
    successorAllocationIds.length
      ? supabase
          .from("shipper_shipment_batch_line_memberships")
          .select("tracking_line_allocation_id")
          .in("tracking_line_allocation_id", successorAllocationIds)
          .eq("active", true)
      : Promise.resolve({ data: [] }),
  ]);

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

  const routeByDisputeId = new Map<string, ReplacementRouteRow>();
  for (const route of routeRows) routeByDisputeId.set(route.dispute_id, route);

  const latestReceiptByTrackingId = new Map<string, string>();
  for (const receipt of (receiptRows ?? []) as ReceiptRow[]) {
    if (!latestReceiptByTrackingId.has(receipt.tracking_submission_id)) {
      latestReceiptByTrackingId.set(receipt.tracking_submission_id, receipt.receipt_status);
    }
  }

  const allocationIdsInShipment = new Set(
    ((membershipRows ?? []) as MembershipRow[]).map((row) => row.tracking_line_allocation_id),
  );

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
                  <th className="p-3">Dispute ref</th>
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
                  const terminalMessage = terminalStatusMessage(dispute, routeByDisputeId, latestReceiptByTrackingId, allocationIdsInShipment);

                  return (
                    <tr key={dispute.id} className="border-t border-slate-200">
                      <td className="p-3 font-semibold">{disputeRef(dispute.id)}</td>
                      <td className="p-3 font-medium">{orderRef(dispute.orders, dispute.order_id)}</td>
                      <td className="p-3">{dispute.desired_outcome ?? "—"}</td>
                      <td className="p-3">{retailerPosition}</td>
                      <td className="p-3">{terminalMessage ?? `${dispute.status ?? "—"} · ${retailerOutcome}`}</td>
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
