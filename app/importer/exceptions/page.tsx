import Link from "next/link";
import { customerImporterTerminology } from "@/lib/ui/customerImporterTerminology";
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

type ReplacementProgressRow = {
  dispute_id: string;
  progress_status: string;
  active_shipment_booking_ref: string | null;
};

type PageSearchParams = Promise<{
  q?: string | string[];
  outcome?: string | string[];
  status?: string | string[];
}>;

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
  progressByDisputeId: Map<string, ReplacementProgressRow>,
) {
  if (dispute.status === "replaced") {
    if (dispute.replacement_child_order_id) return "Replacement accepted — child order created";

    const progress = progressByDisputeId.get(dispute.id);
    if (progress?.progress_status === "added_to_shipment") {
      return `Replacement received clean — added to ${progress.active_shipment_booking_ref ?? "shipment"}`;
    }
    if (progress?.progress_status === "shipment_eligible") {
      return "Replacement received clean — shipment eligible";
    }
    if (progress?.progress_status === "awaiting_replacement_receipt") {
      return "Successor tracking allocated — awaiting replacement receipt";
    }

    const route = routeByDisputeId.get(dispute.id);
    if (
      route?.route_status === "tracking_allocated"
      && route.successor_tracking_submission_id
      && route.successor_tracking_line_allocation_id
    ) {
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

export default async function ImporterExceptionsPage({
  searchParams,
}: {
  searchParams: PageSearchParams;
}) {
  const params = await searchParams;
  const supabase = await createClient();

  const { data: disputes, error } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, replacement_child_order_id, orders!disputes_order_id_fkey(order_ref)")
    .in("desired_outcome", ["refund", "replacement"])
    .neq("status", "closed")
    .order("raised_at", { ascending: false });

  const disputeRows = (disputes ?? []) as DisputeRow[];
  const disputeIds = disputeRows.map((row) => row.id);

  const [{ data: disputeLines }, { data: retailerReplies }, { data: replacementRoutes }, { data: replacementProgress }] = disputeIds.length
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
        supabase.rpc("importer_same_order_replacement_progress_v1", {
          p_dispute_ids: disputeIds,
        }),
      ])
    : [{ data: [] }, { data: [] }, { data: [] }, { data: [] }];

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
  for (const route of (replacementRoutes ?? []) as ReplacementRouteRow[]) {
    routeByDisputeId.set(route.dispute_id, route);
  }

  const progressByDisputeId = new Map<string, ReplacementProgressRow>();
  for (const progress of (replacementProgress ?? []) as ReplacementProgressRow[]) {
    if (!progressByDisputeId.has(progress.dispute_id)) {
      progressByDisputeId.set(progress.dispute_id, progress);
    }
  }

  const firstParam = (value: string | string[] | undefined) => Array.isArray(value) ? (value[0] ?? "") : (value ?? "");
  const searchQuery = firstParam(params.q).trim().toLowerCase();
  const outcomeParam = firstParam(params.outcome).trim().toLowerCase();
  const statusParam = firstParam(params.status).trim().toLowerCase();
  const selectedOutcome = outcomeParam === "refund" || outcomeParam === "replacement" ? outcomeParam : "all";
  const allowedStatuses = new Set([
    "all",
    "waiting_retailer",
    "retailer_follow_up",
    "waiting_supervisor",
    "refund_processing",
    "replacement_tracking",
    "replacement_delivery",
    "replacement_shipment_ready",
    "replacement_shipped",
  ]);
  const selectedStatus = allowedStatuses.has(statusParam) ? statusParam : "all";
  const exceptionCount = disputeRows.length;
  const replacementWaitingCount = ((replacementRoutes ?? []) as ReplacementRouteRow[])
    .filter((route) => route.route_status === "approved_waiting_tracking")
    .length;

  const workStatusForDispute = (dispute: DisputeRow) => {
    const progress = progressByDisputeId.get(dispute.id);
    if (progress?.progress_status === "added_to_shipment") return "replacement_shipped";
    if (progress?.progress_status === "shipment_eligible") return "replacement_shipment_ready";
    if (progress?.progress_status === "awaiting_replacement_receipt") return "replacement_delivery";

    const route = routeByDisputeId.get(dispute.id);
    if (
      route?.route_status === "tracking_allocated"
      && route.successor_tracking_submission_id
      && route.successor_tracking_line_allocation_id
    ) {
      return "replacement_delivery";
    }
    if (route?.route_status === "approved_waiting_tracking") return "replacement_tracking";
    if (dispute.status === "awaiting_refund_credit") return "refund_processing";

    if (terminalStatusMessage(dispute, routeByDisputeId, progressByDisputeId)) return null;

    const lineStatus = activeLineStatusByDispute.get(dispute.id) ?? null;
    const retailerOutcome = retailerOutcomeFromStatus(lineStatus);
    if (retailerOutcome === "retailer_accepted") return "waiting_supervisor";
    if (retailerOutcome === "retailer_disputed" || retailerOutcome === "more_info_requested") return "retailer_follow_up";
    return "waiting_retailer";
  };

  const filteredDisputeRows = disputeRows.filter((dispute) => {
    const matchesSearch = !searchQuery
      || disputeRef(dispute.id).toLowerCase().includes(searchQuery)
      || orderRef(dispute.orders, dispute.order_id).toLowerCase().includes(searchQuery);
    const matchesOutcome = selectedOutcome === "all" || dispute.desired_outcome === selectedOutcome;
    const workStatus = workStatusForDispute(dispute);
    const matchesStatus = selectedStatus === "all" || workStatus === selectedStatus;
    return matchesSearch && matchesOutcome && matchesStatus;
  });

  return (
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <div className="mx-auto max-w-7xl space-y-6">
        <header className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/importer" className="text-sm font-semibold text-sky-600">← Back to importer dashboard</Link>
          <h1 className="mt-3 text-3xl font-semibold tracking-tight">Importer Exceptions</h1>
          <p className="mt-2 text-sm text-slate-600">Active refund and replacement exception cases.</p>
        </header>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <p className="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">Work queues</p>
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <Link href="#importer-exception-cases" className="flex min-h-11 items-center justify-between rounded-2xl border border-slate-200 bg-white px-4 py-3 text-sm font-semibold text-slate-800">
              <span>Exception cases</span>
              <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs">{exceptionCount}</span>
            </Link>
            <Link href="/importer#replacement-tracking" className="flex min-h-11 items-center justify-between rounded-2xl border border-sky-200 bg-sky-50 px-4 py-3 text-sm font-semibold text-sky-800">
              <span>Replacement tracking</span>
              <span className="flex items-center gap-2">
                <span className="rounded-full bg-white px-2.5 py-1 text-xs">{replacementWaitingCount}</span>
                <span aria-hidden="true">→</span>
              </span>
            </Link>
          </div>
          {replacementWaitingCount > 0 ? <p className="mt-2 text-xs text-slate-500">Successor tracking requires assignment in the importer workspace.</p> : null}

          <form method="get" className="mt-5 grid gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(0,1fr)_minmax(0,1.4fr)_auto] lg:items-end">
            <label className="block text-sm font-medium text-slate-700">
              Search
              <input
                type="search"
                name="q"
                defaultValue={firstParam(params.q)}
                placeholder="Order or dispute reference"
                className="mt-1 block w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500"
              />
            </label>
            <label className="block text-sm font-medium text-slate-700">
              Outcome
              <select name="outcome" defaultValue={selectedOutcome} className="mt-1 block w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500">
                <option value="all">All outcomes</option>
                <option value="refund">Refund</option>
                <option value="replacement">Replacement</option>
              </select>
            </label>
            <label className="block text-sm font-medium text-slate-700">
              Work status
              <select name="status" defaultValue={selectedStatus} className="mt-1 block w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm text-slate-950 shadow-sm outline-none focus:border-sky-500">
                <option value="all">All statuses</option>
                <option value="waiting_retailer">Waiting for retailer</option>
                <option value="retailer_follow_up">Retailer follow-up required</option>
                <option value="waiting_supervisor">Waiting for supervisor</option>
                <option value="refund_processing">Refund processing</option>
                <option value="replacement_tracking">Replacement tracking needed</option>
                <option value="replacement_delivery">Waiting for replacement delivery</option>
                <option value="replacement_shipment_ready">Replacement ready for shipment</option>
                <option value="replacement_shipped">Replacement added to shipment</option>
              </select>
            </label>
            <div className="flex gap-2 lg:pb-0">
              <button type="submit" className="min-h-10 flex-1 rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white lg:flex-none">Apply filters</button>
              <Link href="/importer/exceptions" className="min-h-10 flex-1 rounded-xl border border-slate-300 bg-white px-4 py-2 text-center text-sm font-semibold text-slate-700 lg:flex-none">Reset</Link>
            </div>
          </form>
        </section>

        <section id="importer-exception-cases" className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          {error ? <p className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">Failed to load disputes: {customerImporterTerminology(error.message)}</p> : null}

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
                {filteredDisputeRows.map((dispute) => {
                  const lineStatus = activeLineStatusByDispute.get(dispute.id) ?? null;
                  const retailerOutcome = retailerOutcomeFromStatus(lineStatus);
                  const retailerPosition = latestRetailerReplyByDispute.get(dispute.id) ?? "No retailer reply yet";
                  const terminalMessage = terminalStatusMessage(dispute, routeByDisputeId, progressByDisputeId);

                  return (
                    <tr key={dispute.id} className="border-t border-slate-200">
                      <td className="p-3 font-semibold">{disputeRef(dispute.id)}</td>
                      <td className="p-3 font-medium">{orderRef(dispute.orders, dispute.order_id)}</td>
                      <td className="p-3">{customerImporterTerminology(dispute.desired_outcome ?? "—")}</td>
                      <td className="p-3">{retailerPosition}</td>
                      <td className="p-3">{customerImporterTerminology(terminalMessage ?? `${dispute.status ?? "—"} · ${retailerOutcome}`)}</td>
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
          {disputeRows.length > 0 && filteredDisputeRows.length === 0 ? (
            <p className="mt-4 text-sm text-slate-600">No exception cases match these filters. <Link href="/importer/exceptions" className="font-semibold text-sky-700 underline">Reset filters</Link></p>
          ) : null}
        </section>
      </div>
    </main>
  );
}