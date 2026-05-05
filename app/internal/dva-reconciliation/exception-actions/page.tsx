import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

type DisputeRow = {
  id: string;
  order_id: string | null;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | string | null;
  refund_approved_at: string | null;
  replacement_child_order_id: string | null;
  resolved_at: string | null;
  raised_at: string | null;
};

type OrderRow = {
  id: string;
  order_ref: string | null;
  importer_id: string | null;
  retailer_id: string | null;
  status: string | null;
};

type ImporterRow = {
  id: string;
  company_name: string | null;
  trading_name: string | null;
};

type RetailerRow = {
  id: string;
  name: string | null;
};

type MessageRow = {
  dispute_id: string;
  message_type: string | null;
  counterparty: string | null;
};

type DisputeLineRow = {
  dispute_id: string;
  conversation_status: string | null;
  resolved_at: string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const TERMINAL_STATUSES = new Set(["replaced", "awaiting_refund_credit", "refunded", "closed"]);

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function gbp(value: unknown) {
  const amount = typeof value === "number" ? value : Number(value ?? 0);
  return gbpFormatter.format(Number.isFinite(amount) ? amount : 0);
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function importerLabel(importer?: ImporterRow) {
  return importer?.trading_name || importer?.company_name || importer?.id || "All importers";
}

function actionState(dispute: DisputeRow, messages: MessageRow[], lines: DisputeLineRow[]) {
  const status = text(dispute.status);
  const outcome = text(dispute.desired_outcome);
  const terminal = TERMINAL_STATUSES.has(status) || Boolean(dispute.resolved_at);
  const hasRetailerReply = messages.some((message) => message.message_type === "retailer_reply" && message.counterparty === "retailer");
  const activeLines = lines.filter((line) => !line.resolved_at);
  const retailerAccepted = activeLines.length > 0 && activeLines.every((line) => line.conversation_status === "retailer_response_received");
  const canAcceptFinal = hasRetailerReply && retailerAccepted && !terminal;

  if (terminal) {
    if (status === "replaced") return { label: "Complete", tone: "emerald", next: "Replacement accepted and child order created." };
    if (status === "awaiting_refund_credit") return { label: "Awaiting refund credit", tone: "emerald", next: "Final refund outcome accepted. Match/process refund credit downstream." };
    return { label: "Closed", tone: "slate", next: "No supervisor action required." };
  }

  if (outcome === "refund" && !dispute.refund_approved_at) {
    return { label: "Approve refund pursuit", tone: "amber", next: "Open review and approve/refuse permission for importer to pursue retailer refund." };
  }

  if (canAcceptFinal && outcome === "refund") {
    return { label: "Accept refund outcome", tone: "emerald", next: "Retailer reply and accepted outcome are present. Open review to accept final refund outcome." };
  }

  if (canAcceptFinal && outcome === "replacement") {
    return { label: "Accept replacement", tone: "emerald", next: "Retailer reply and accepted outcome are present. Open review to create/accept replacement child order." };
  }

  if (outcome === "refund" && dispute.refund_approved_at) {
    return { label: "Awaiting retailer outcome", tone: "sky", next: "Refund pursuit approved. Importer/operator must log retailer reply and mark accepted outcome before final acceptance." };
  }

  return { label: "Retailer evidence needed", tone: "sky", next: "Importer/operator must log retailer conversation and update the outcome before supervisor final acceptance." };
}

function toneClass(tone: string) {
  if (tone === "emerald") return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (tone === "amber") return "border-amber-200 bg-amber-50 text-amber-800";
  if (tone === "sky") return "border-sky-200 bg-sky-50 text-sky-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

export default async function DvaExceptionActionCentrePage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importerId = firstParam(params.importer_id);
  const statusFilter = firstParam(params.status) || "open";
  const supabase = await createClient();

  const [importersResult, retailersResult] = await Promise.all([
    supabase.from("importers").select("id, company_name, trading_name").order("company_name", { ascending: true }).limit(200),
    supabase.from("retailers").select("id, name").limit(500),
  ]);

  const importers = (importersResult.data ?? []) as unknown as ImporterRow[];
  const selectedImporter = importers.find((importer) => importer.id === importerId);
  const retailersById = new Map(((retailersResult.data ?? []) as unknown as RetailerRow[]).map((retailer) => [retailer.id, retailer]));

  let ordersQuery = supabase
    .from("orders")
    .select("id, order_ref, importer_id, retailer_id, status")
    .order("created_at", { ascending: false })
    .limit(750);
  if (importerId) ordersQuery = ordersQuery.eq("importer_id", importerId);

  const { data: orderData } = await ordersQuery;
  const orders = (orderData ?? []) as unknown as OrderRow[];
  const ordersById = new Map(orders.map((order) => [order.id, order]));
  const orderIds = new Set(orders.map((order) => order.id));

  const [disputesResult, messagesResult, linesResult] = await Promise.all([
    supabase
      .from("disputes")
      .select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id, resolved_at, raised_at")
      .order("raised_at", { ascending: false })
      .limit(750),
    supabase
      .from("dispute_messages")
      .select("dispute_id, message_type, counterparty")
      .limit(2000),
    supabase
      .from("dispute_lines")
      .select("dispute_id, conversation_status, resolved_at")
      .limit(2000),
  ]);

  const allDisputes = ((disputesResult.data ?? []) as unknown as DisputeRow[]).filter((dispute) => {
    if (!dispute.order_id || !orderIds.has(dispute.order_id)) return false;
    const terminal = TERMINAL_STATUSES.has(text(dispute.status)) || Boolean(dispute.resolved_at);
    if (statusFilter === "open") return !terminal;
    if (statusFilter === "terminal") return terminal;
    if (statusFilter === "refund") return text(dispute.desired_outcome) === "refund";
    if (statusFilter === "replacement") return text(dispute.desired_outcome) === "replacement";
    return true;
  });

  const messages = (messagesResult.data ?? []) as unknown as MessageRow[];
  const lines = (linesResult.data ?? []) as unknown as DisputeLineRow[];
  const messagesByDisputeId = new Map<string, MessageRow[]>();
  const linesByDisputeId = new Map<string, DisputeLineRow[]>();

  for (const message of messages) {
    const id = message.dispute_id;
    messagesByDisputeId.set(id, [...(messagesByDisputeId.get(id) ?? []), message]);
  }

  for (const line of lines) {
    const id = line.dispute_id;
    linesByDisputeId.set(id, [...(linesByDisputeId.get(id) ?? []), line]);
  }

  const cards = allDisputes.map((dispute) => {
    const order = dispute.order_id ? ordersById.get(dispute.order_id) : undefined;
    const retailer = order?.retailer_id ? retailersById.get(order.retailer_id) : undefined;
    const state = actionState(dispute, messagesByDisputeId.get(dispute.id) ?? [], linesByDisputeId.get(dispute.id) ?? []);
    return { dispute, order, retailer, state };
  });

  const openCount = cards.filter((card) => !TERMINAL_STATUSES.has(text(card.dispute.status)) && !card.dispute.resolved_at).length;
  const refundCount = cards.filter((card) => text(card.dispute.desired_outcome) === "refund").length;
  const replacementCount = cards.filter((card) => text(card.dispute.desired_outcome) === "replacement").length;
  const readyActionCount = cards.filter((card) => card.state.label === "Approve refund pursuit" || card.state.label === "Accept refund outcome" || card.state.label === "Accept replacement").length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-reconciliation/review-pack" className="text-sm font-semibold text-sky-600">← Back to review pack</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.25em] text-sky-600">DVA/card exception actions</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight">Exception Action Centre</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            Supervisor queue for refund and replacement exception outcomes. This page does not invent new write logic; it routes each case into the existing internal exception review where governed approval and final outcome actions already live.
          </p>
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-amber-700">Open cases</p>
            <p className="mt-2 text-2xl font-extrabold text-amber-950">{openCount}</p>
          </div>
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-emerald-700">Action ready</p>
            <p className="mt-2 text-2xl font-extrabold text-emerald-950">{readyActionCount}</p>
          </div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-sky-700">Refund cases</p>
            <p className="mt-2 text-2xl font-extrabold text-sky-950">{refundCount}</p>
          </div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-sky-700">Replacement cases</p>
            <p className="mt-2 text-2xl font-extrabold text-sky-950">{replacementCount}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="grid gap-3 md:grid-cols-[1fr_auto_auto] md:items-end" action="/internal/dva-reconciliation/exception-actions">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer
              <select name="importer_id" defaultValue={importerId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="">All importers</option>
                {importers.map((importer) => (
                  <option key={importer.id} value={importer.id}>{importerLabel(importer)}</option>
                ))}
              </select>
            </label>
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Queue
              <select name="status" defaultValue={statusFilter} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="open">Open cases</option>
                <option value="refund">Refund cases</option>
                <option value="replacement">Replacement cases</option>
                <option value="terminal">Terminal / completed</option>
                <option value="all">All</option>
              </select>
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        {disputesResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">{disputesResult.error.message}</section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">
            Showing {cards.length} exception case(s) for {importerLabel(selectedImporter)}
          </div>

          {cards.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No exception cases match this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {cards.map(({ dispute, order, retailer, state }) => (
                <article key={dispute.id} className="grid gap-4 p-4 lg:grid-cols-[1fr_auto] lg:items-center">
                  <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-bold text-slate-950">{order?.order_ref || dispute.order_id || "No order"} · {pretty(dispute.desired_outcome)}</p>
                        <p className="mt-1 text-sm text-slate-600">{retailer?.name || "No retailer"} · Impact {gbp(dispute.amount_impact_gbp)} · Status {pretty(dispute.status)}</p>
                      </div>
                      <span className={`rounded-full border px-3 py-1 text-xs font-bold ${toneClass(state.tone)}`}>{state.label}</span>
                    </div>
                    <p className="mt-3 rounded-xl bg-slate-50 p-3 text-sm text-slate-600">{state.next}</p>
                  </div>
                  <Link href={`/internal/exceptions/${dispute.id}`} className="rounded-xl bg-slate-950 px-4 py-3 text-center text-sm font-semibold text-white shadow-sm hover:bg-slate-800">
                    Open supervisor action review
                  </Link>
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
