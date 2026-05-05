import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

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
  dispute_id: string | null;
  message_type: string | null;
  counterparty: string | null;
};

type DisputeLineRow = {
  dispute_id: string | null;
  conversation_status: string | null;
  resolved_at: string | null;
};

type AllocationRow = {
  importer_id: string | null;
  order_ref: string | null;
  dispute_id: string | null;
  allocation_type: string | null;
  allocation_status: string | null;
  allocated_gbp_amount: number | string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const TERMINAL_STATUSES = new Set(["replaced", "awaiting_refund_credit", "refunded", "closed", "resolved"]);
const EVIDENCE_READY_STATUSES = new Set(["retailer_response_received", "resolved_refund", "resolved_replacement", "resolved", "closed_no_action"]);

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  return "";
}

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function importerLabel(importer?: ImporterRow) {
  return importer?.trading_name || importer?.company_name || importer?.id || "All importers";
}

function groupBy<T>(rows: T[], keyFn: (row: T) => string) {
  const grouped = new Map<string, T[]>();
  for (const row of rows) {
    const key = keyFn(row);
    if (!key) continue;
    grouped.set(key, [...(grouped.get(key) ?? []), row]);
  }
  return grouped;
}

function hasRetailerReply(messages: MessageRow[]) {
  return messages.some((message) => text(message.message_type) === "retailer_reply" || text(message.counterparty) === "retailer");
}

function retailerEvidenceReady(lines: DisputeLineRow[]) {
  const activeLines = lines.filter((line) => !line.resolved_at);
  return activeLines.length > 0 && activeLines.every((line) => EVIDENCE_READY_STATUSES.has(text(line.conversation_status)));
}

function classifyEligibility(dispute: DisputeRow, messages: MessageRow[], lines: DisputeLineRow[], allocations: AllocationRow[]) {
  const status = text(dispute.status);
  const outcome = text(dispute.desired_outcome);
  const retailerReply = hasRetailerReply(messages);
  const evidenceReady = retailerEvidenceReady(lines);
  const terminal = TERMINAL_STATUSES.has(status) || Boolean(dispute.resolved_at);
  const hasRefundAllocation = allocations.some((allocation) => text(allocation.allocation_type) === "retailer_refund");
  const hasSupplierChargeAllocation = allocations.some((allocation) => text(allocation.allocation_type) === "supplier_invoice");
  const hasExceptionHold = allocations.some((allocation) => ["exception_hold", "unmatched_hold"].includes(text(allocation.allocation_type)));
  const allocationTotal = allocations.reduce((sum, allocation) => sum + num(allocation.allocated_gbp_amount), 0);

  if (outcome === "refund") {
    if (["approved_refund", "awaiting_refund_credit"].includes(status) && !hasRefundAllocation) {
      return {
        label: "Needs refund IN match",
        tone: "amber",
        next: "Refund outcome is approved/awaiting credit. Match the incoming DVA/card refund line before Sage readiness can clear.",
        financialRoute: "refund_in_line_required",
        allocationTotal,
      };
    }

    if (hasRefundAllocation) {
      return {
        label: "Refund financially matched",
        tone: "emerald",
        next: "A refund allocation exists for this exception. Review amount and evidence before downstream credit/accounting release.",
        financialRoute: "refund_in_line_matched",
        allocationTotal,
      };
    }

    if (!dispute.refund_approved_at && ["raised", "under_review"].includes(status)) {
      return {
        label: "Eligible: approve refund pursuit",
        tone: "amber",
        next: "Supervisor may approve/refuse permission to pursue retailer refund. Retailer conversation must not begin before this approval.",
        financialRoute: "refund_pursuit_approval",
        allocationTotal,
      };
    }

    if (dispute.refund_approved_at && !retailerReply) {
      return {
        label: "Retailer evidence needed",
        tone: "sky",
        next: "Refund pursuit is approved. Importer/operator must log retailer conversation and reply.",
        financialRoute: "retailer_evidence_required",
        allocationTotal,
      };
    }

    if (retailerReply && evidenceReady && !terminal) {
      return {
        label: "Ready for refund outcome review",
        tone: "emerald",
        next: "Retailer evidence appears ready. Supervisor can review final refund outcome before settlement matching.",
        financialRoute: "refund_outcome_review",
        allocationTotal,
      };
    }
  }

  if (outcome === "replacement") {
    if (status === "replaced" && dispute.replacement_child_order_id) {
      return {
        label: "Replacement child linked",
        tone: "emerald",
        next: "Replacement child order exists. Child order should now follow the normal operational lanes.",
        financialRoute: "replacement_child_linked",
        allocationTotal,
      };
    }

    if (["approved_replacement", "replaced"].includes(status) && !dispute.replacement_child_order_id) {
      return {
        label: "Needs replacement child link",
        tone: "amber",
        next: "Replacement outcome is accepted/replaced but no replacement child order is linked.",
        financialRoute: "replacement_child_required",
        allocationTotal,
      };
    }

    if (hasSupplierChargeAllocation) {
      return {
        label: "Replacement charge matched",
        tone: "emerald",
        next: "Replacement appears charged and matched to a supplier/card allocation. Review if this was a charged replacement or repurchase.",
        financialRoute: "replacement_charge_matched",
        allocationTotal,
      };
    }

    if (hasExceptionHold) {
      return {
        label: "Replacement held / free pending review",
        tone: "sky",
        next: "Exception/hold allocation exists. Supervisor should decide whether this is a free replacement, no new charge, or a pending charge.",
        financialRoute: "replacement_hold_review",
        allocationTotal,
      };
    }

    if (retailerReply && evidenceReady && !terminal) {
      return {
        label: "Ready for replacement outcome review",
        tone: "emerald",
        next: "Retailer evidence appears ready. Supervisor can review final replacement outcome before creating/linking child order.",
        financialRoute: "replacement_outcome_review",
        allocationTotal,
      };
    }

    return {
      label: "Retailer evidence needed",
      tone: "sky",
      next: "Importer/operator must log retailer conversation and accepted replacement outcome before supervisor final acceptance.",
      financialRoute: "retailer_evidence_required",
      allocationTotal,
    };
  }

  return {
    label: "Outcome classification needed",
    tone: "amber",
    next: "Exception outcome is not clearly refund or replacement. Review before financial readiness.",
    financialRoute: "classification_required",
    allocationTotal,
  };
}

function toneClass(tone: string) {
  if (tone === "emerald") return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (tone === "amber") return "border-amber-200 bg-amber-50 text-amber-800";
  if (tone === "sky") return "border-sky-200 bg-sky-50 text-sky-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

export default async function ExceptionEligibilityPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importerId = firstParam(params.importer_id);
  const routeFilter = firstParam(params.route) || "all";
  const supabase = await createClient();

  const [importersResult, retailersResult] = await Promise.all([
    supabase.from("importers").select("id, company_name, trading_name").order("company_name", { ascending: true }).limit(200),
    supabase.from("retailers").select("id, name").limit(500),
  ]);

  const importers = (importersResult.data ?? []) as unknown as ImporterRow[];
  const selectedImporter = importers.find((importer) => importer.id === importerId);
  const retailersById = new Map(((retailersResult.data ?? []) as unknown as RetailerRow[]).map((retailer) => [retailer.id, retailer]));

  let ordersQuery = supabase.from("orders").select("id, order_ref, importer_id, retailer_id, status").order("created_at", { ascending: false }).limit(750);
  if (importerId) ordersQuery = ordersQuery.eq("importer_id", importerId);

  const { data: orderData, error: orderError } = await ordersQuery;
  const orders = (orderData ?? []) as unknown as OrderRow[];
  const ordersById = new Map(orders.map((order) => [order.id, order]));
  const orderIds = new Set(orders.map((order) => order.id));

  const [disputesResult, messagesResult, linesResult, allocationsResult] = await Promise.all([
    supabase.from("disputes").select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id, resolved_at, raised_at").order("raised_at", { ascending: false }).limit(750),
    supabase.from("dispute_messages").select("dispute_id, message_type, counterparty").limit(2000),
    supabase.from("dispute_lines").select("dispute_id, conversation_status, resolved_at").limit(2000),
    supabase.from("dva_statement_line_allocation_detail_vw").select("importer_id, order_ref, dispute_id, allocation_type, allocation_status, allocated_gbp_amount").limit(2000),
  ]);

  const disputes = ((disputesResult.data ?? []) as unknown as DisputeRow[]).filter((dispute) => dispute.order_id && orderIds.has(dispute.order_id));
  const messagesByDisputeId = groupBy((messagesResult.data ?? []) as unknown as MessageRow[], (message) => message.dispute_id ?? "");
  const linesByDisputeId = groupBy((linesResult.data ?? []) as unknown as DisputeLineRow[], (line) => line.dispute_id ?? "");
  const allocationsByDisputeId = groupBy((allocationsResult.data ?? []) as unknown as AllocationRow[], (allocation) => allocation.dispute_id ?? "");

  const cards = disputes.map((dispute) => {
    const order = dispute.order_id ? ordersById.get(dispute.order_id) : undefined;
    const retailer = order?.retailer_id ? retailersById.get(order.retailer_id) : undefined;
    const eligibility = classifyEligibility(
      dispute,
      messagesByDisputeId.get(dispute.id) ?? [],
      linesByDisputeId.get(dispute.id) ?? [],
      allocationsByDisputeId.get(dispute.id) ?? [],
    );
    return { dispute, order, retailer, eligibility };
  }).filter((card) => routeFilter === "all" || card.eligibility.financialRoute === routeFilter || text(card.dispute.desired_outcome) === routeFilter);

  const refundNeedCount = cards.filter((card) => card.eligibility.financialRoute === "refund_in_line_required").length;
  const replacementNeedCount = cards.filter((card) => ["replacement_child_required", "replacement_hold_review"].includes(card.eligibility.financialRoute)).length;
  const readyReviewCount = cards.filter((card) => card.eligibility.financialRoute.endsWith("_outcome_review")).length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-reconciliation/exception-actions" className="text-sm font-semibold text-sky-600">← Back to exception action centre</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.25em] text-sky-600">Exception financial eligibility</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight">Refund / replacement financial outcome labels</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            Read-only classifier before adding write actions. It shows whether each exception needs refund IN-line matching, replacement child linking, retailer evidence, a financial hold review, or final supervisor outcome review.
          </p>
        </section>

        <section className="grid gap-3 sm:grid-cols-3">
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-amber-700">Refund IN match needed</p><p className="mt-2 text-2xl font-extrabold text-amber-950">{refundNeedCount}</p></div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-sky-700">Replacement review needed</p><p className="mt-2 text-2xl font-extrabold text-sky-950">{replacementNeedCount}</p></div>
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-bold uppercase tracking-wide text-emerald-700">Outcome review ready</p><p className="mt-2 text-2xl font-extrabold text-emerald-950">{readyReviewCount}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="grid gap-3 md:grid-cols-[1fr_1fr_auto] md:items-end" action="/internal/dva-reconciliation/exception-actions/eligibility">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer
              <select name="importer_id" defaultValue={importerId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="">All importers</option>
                {importers.map((importer) => <option key={importer.id} value={importer.id}>{importerLabel(importer)}</option>)}
              </select>
            </label>
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Route
              <select name="route" defaultValue={routeFilter} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="all">All</option>
                <option value="refund">Refund cases</option>
                <option value="replacement">Replacement cases</option>
                <option value="refund_in_line_required">Needs refund IN match</option>
                <option value="replacement_child_required">Needs replacement child link</option>
                <option value="replacement_hold_review">Replacement hold/free review</option>
              </select>
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        {orderError || disputesResult.error || allocationsResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">
            {orderError?.message || disputesResult.error?.message || allocationsResult.error?.message}
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">Showing {cards.length} exception eligibility card(s) for {importerLabel(selectedImporter)}</div>
          {cards.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No exception cases match this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {cards.map(({ dispute, order, retailer, eligibility }) => (
                <article key={dispute.id} className="p-4">
                  <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-extrabold text-slate-950">{order?.order_ref || dispute.id.slice(0, 8)} · {pretty(dispute.desired_outcome)}</p>
                        <p className="mt-1 text-sm text-slate-600">{retailer?.name || "No retailer"} · Impact {gbp(dispute.amount_impact_gbp)} · Status {pretty(dispute.status)}</p>
                      </div>
                      <span className={`rounded-full border px-3 py-1 text-xs font-bold ${toneClass(eligibility.tone)}`}>{eligibility.label}</span>
                    </div>

                    <div className="mt-4 rounded-xl bg-slate-50 p-3 text-sm leading-6 text-slate-700 ring-1 ring-slate-200">
                      {eligibility.next}
                    </div>

                    <div className="mt-4 grid gap-3 sm:grid-cols-3">
                      <div className="rounded-xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Financial route</p><p className="mt-1 font-bold text-slate-950">{pretty(eligibility.financialRoute)}</p></div>
                      <div className="rounded-xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Linked allocations</p><p className="mt-1 font-bold text-slate-950">{gbp(eligibility.allocationTotal)}</p></div>
                      <div className="rounded-xl border border-slate-200 bg-white p-3"><p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Review</p><Link href={`/internal/exceptions/${dispute.id}`} className="mt-1 inline-block font-bold text-sky-700">Open supervisor review</Link></div>
                    </div>
                  </div>
                </article>
              ))}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
