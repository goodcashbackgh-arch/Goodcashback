import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;

type OrderRow = {
  id: string;
  order_ref: string | null;
  importer_id: string | null;
  retailer_id: string | null;
  status: string | null;
  order_type: string | null;
  parent_order_id: string | null;
  created_at: string | null;
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

type SupplierInvoiceRow = {
  id: string;
  order_id: string | null;
  invoice_ref: string | null;
  review_status: string | null;
  mindee_ocr_status?: string | null;
  mindee_statement_ocr_status?: string | null;
  ocr_invoice_total_gbp: number | string | null;
  reconciliation_gbp_total: number | string | null;
};

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

type DisputeLineRow = {
  dispute_id: string | null;
  conversation_status: string | null;
  resolved_at: string | null;
};

type MessageRow = {
  dispute_id: string | null;
  message_type: string | null;
  counterparty: string | null;
};

type AllocationRow = {
  importer_id: string | null;
  order_ref: string | null;
  dispute_id: string | null;
  allocation_type: string | null;
  allocation_status: string | null;
  allocated_gbp_amount: number | string | null;
};

type StatementSummaryRow = {
  importer_id: string | null;
  direction: string | null;
  match_status: string | null;
  confirmed_balanced_yn: boolean | string | null;
  confirmed_unallocated_gbp: number | string | null;
  supplier_invoice_allocated_gbp: number | string | null;
  retailer_refund_allocated_gbp: number | string | null;
  fx_card_or_fee_allocated_gbp: number | string | null;
  exception_or_hold_allocated_gbp: number | string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const TERMINAL_EXCEPTION_STATUSES = new Set(["awaiting_refund_credit", "refunded", "replaced", "closed", "resolved"]);
const FINALISH_EXCEPTION_STATUSES = new Set(["approved_refund", "awaiting_refund_credit", "refunded", "approved_replacement", "replaced", "closed", "resolved"]);
const EVIDENCE_READY_LINE_STATUSES = new Set(["retailer_response_received", "resolved_refund", "resolved_replacement", "resolved"]);

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

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
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

function lineEvidenceReady(lines: DisputeLineRow[]) {
  return lines.length > 0 && lines.every((line) => EVIDENCE_READY_LINE_STATUSES.has(text(line.conversation_status)) || Boolean(line.resolved_at));
}

function hasRetailerReply(messages: MessageRow[]) {
  return messages.some((message) => text(message.message_type) === "retailer_reply" || text(message.counterparty) === "retailer");
}

function disputeWarnings(dispute: DisputeRow, lines: DisputeLineRow[], messages: MessageRow[], childOrderExists: boolean) {
  const warnings: string[] = [];
  const status = text(dispute.status);
  const outcome = text(dispute.desired_outcome);
  const evidenceReady = lineEvidenceReady(lines);
  const retailerReply = hasRetailerReply(messages);

  if (FINALISH_EXCEPTION_STATUSES.has(status) && !evidenceReady) {
    warnings.push(`Header says ${pretty(status)}, but line retailer outcome evidence is not complete.`);
  }
  if (FINALISH_EXCEPTION_STATUSES.has(status) && !retailerReply && status !== "closed" && status !== "resolved") {
    warnings.push(`Header says ${pretty(status)}, but no retailer reply is logged.`);
  }
  if (status === "replaced" && !dispute.replacement_child_order_id) {
    warnings.push("Header says replaced, but no replacement child order id is linked.");
  }
  if (dispute.replacement_child_order_id && !childOrderExists) {
    warnings.push("Replacement child order id is present, but the child order was not found in the current order set.");
  }
  if (outcome === "refund" && status === "approved_refund") {
    warnings.push("Refund outcome is approved internally; this must not show the early approve-refund-pursuit action.");
  }
  return warnings;
}

function exceptionLane(disputes: DisputeRow[]) {
  if (disputes.length === 0) return "none";
  if (disputes.some((dispute) => !TERMINAL_EXCEPTION_STATUSES.has(text(dispute.status)) && !dispute.resolved_at)) return "open";
  if (disputes.some((dispute) => text(dispute.status) === "awaiting_refund_credit")) return "awaiting_refund_credit";
  return "complete_or_terminal";
}

function invoiceLane(invoices: SupplierInvoiceRow[]) {
  if (invoices.length === 0) return "invoice_missing";
  if (invoices.some((invoice) => ["needs_action", "pending_review", "duplicate_blocked", "rejected_resubmit_required"].includes(text(invoice.review_status)))) return "review_needed";
  if (invoices.some((invoice) => text(invoice.review_status) === "approved_current")) return "supplier_invoice_ready";
  return "invoice_uploaded";
}

function dvaLane(importerId: string | null, statementRows: StatementSummaryRow[], allocationRows: AllocationRow[], orderRef: string | null, disputes: DisputeRow[]) {
  const importerStatementRows = statementRows.filter((row) => !importerId || row.importer_id === importerId);
  const orderAllocations = allocationRows.filter((allocation) => allocation.order_ref === orderRef || disputes.some((dispute) => dispute.id === allocation.dispute_id));
  const openAmount = importerStatementRows.reduce((sum, row) => sum + num(row.confirmed_unallocated_gbp), 0);
  const hasBalanced = importerStatementRows.some((row) => bool(row.confirmed_balanced_yn));
  const hasAllocations = orderAllocations.length > 0;
  const hasRefundException = disputes.some((dispute) => text(dispute.desired_outcome) === "refund" && ["approved_refund", "awaiting_refund_credit"].includes(text(dispute.status)));
  const hasRefundAllocation = orderAllocations.some((allocation) => text(allocation.allocation_type) === "retailer_refund");

  if (hasRefundException && !hasRefundAllocation) return "refund_match_needed";
  if (hasAllocations && hasBalanced) return "balanced_or_part_explained";
  if (importerStatementRows.length > 0 && openAmount > 0) return "statement_imported_open_lines";
  if (importerStatementRows.length > 0) return "statement_imported";
  return "statement_missing_or_not_importer_scoped";
}

function deriveHeadline(invoiceStatus: string, exceptionStatus: string, dvaStatus: string, warnings: string[]) {
  if (warnings.length > 0) return "status_integrity_review";
  if (exceptionStatus === "open") return "commercial_exception_open";
  if (exceptionStatus === "awaiting_refund_credit") return "commercial_exception_awaiting_refund_credit";
  if (dvaStatus === "refund_match_needed") return "refund_statement_match_needed";
  if (invoiceStatus === "invoice_missing") return "awaiting_invoice_or_tracking";
  if (invoiceStatus === "review_needed") return "invoice_reconciliation";
  if (invoiceStatus === "supplier_invoice_ready") return "accounting_review_candidate";
  return "order_status_unclassified";
}

function nextActionFor(headline: string) {
  if (headline === "status_integrity_review") return { role: "supervisor", label: "Review status mismatch before further processing" };
  if (headline === "commercial_exception_open") return { role: "operator/supervisor", label: "Progress retailer exception evidence and supervisor outcome gates" };
  if (headline === "commercial_exception_awaiting_refund_credit") return { role: "supervisor", label: "Match refund credit / DVA IN line" };
  if (headline === "refund_statement_match_needed") return { role: "supervisor", label: "Match accepted refund to DVA/card IN line" };
  if (headline === "awaiting_invoice_or_tracking") return { role: "operator", label: "Upload supplier invoice / tracking evidence" };
  if (headline === "invoice_reconciliation") return { role: "operator/supervisor", label: "Complete invoice/OCR reconciliation or review" };
  if (headline === "accounting_review_candidate") return { role: "supervisor", label: "Review DVA/card, export evidence and accounting readiness" };
  return { role: "supervisor", label: "Review lane statuses" };
}

function lanePill(label: string, value: string) {
  return (
    <div className="rounded-xl bg-slate-50 p-3 ring-1 ring-slate-200">
      <p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">{label}</p>
      <p className="mt-1 text-sm font-extrabold text-slate-950">{pretty(value)}</p>
    </div>
  );
}

export default async function StatusControlPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importerId = firstParam(params.importer_id);
  const onlyWarnings = firstParam(params.only_warnings) === "true";
  const supabase = await createClient();

  const [importersResult, retailersResult] = await Promise.all([
    supabase.from("importers").select("id, company_name, trading_name").order("company_name", { ascending: true }).limit(200),
    supabase.from("retailers").select("id, name").limit(500),
  ]);

  const importers = (importersResult.data ?? []) as unknown as ImporterRow[];
  const selectedImporter = importers.find((importer) => importer.id === importerId);
  const retailers = (retailersResult.data ?? []) as unknown as RetailerRow[];
  const retailersById = new Map(retailers.map((retailer) => [retailer.id, retailer]));

  let orderQuery = supabase
    .from("orders")
    .select("id, order_ref, importer_id, retailer_id, status, order_type, parent_order_id, created_at")
    .order("created_at", { ascending: false })
    .limit(150);

  if (importerId) orderQuery = orderQuery.eq("importer_id", importerId);

  const { data: orderData, error: orderError } = await orderQuery;
  const orders = (orderData ?? []) as unknown as OrderRow[];
  const orderIds = new Set(orders.map((order) => order.id));
  const childOrderIds = new Set(orders.filter((order) => order.parent_order_id).map((order) => order.id));

  const [invoiceResult, disputeResult, disputeLineResult, messageResult, allocationResult, statementResult] = await Promise.all([
    supabase.from("supplier_invoices").select("id, order_id, invoice_ref, review_status, ocr_invoice_total_gbp, reconciliation_gbp_total").limit(1000),
    supabase.from("disputes").select("id, order_id, desired_outcome, status, amount_impact_gbp, refund_approved_at, replacement_child_order_id, resolved_at, raised_at").limit(1000),
    supabase.from("dispute_lines").select("dispute_id, conversation_status, resolved_at").limit(2000),
    supabase.from("dispute_messages").select("dispute_id, message_type, counterparty").limit(2000),
    supabase.from("dva_statement_line_allocation_detail_vw").select("importer_id, order_ref, dispute_id, allocation_type, allocation_status, allocated_gbp_amount").limit(2000),
    supabase.from("dva_statement_line_allocation_summary_vw").select("importer_id, direction, match_status, confirmed_balanced_yn, confirmed_unallocated_gbp, supplier_invoice_allocated_gbp, retailer_refund_allocated_gbp, fx_card_or_fee_allocated_gbp, exception_or_hold_allocated_gbp").limit(2000),
  ]);

  const invoicesByOrderId = groupBy((invoiceResult.data ?? []) as unknown as SupplierInvoiceRow[], (invoice) => invoice.order_id ?? "");
  const disputesByOrderId = groupBy(((disputeResult.data ?? []) as unknown as DisputeRow[]).filter((dispute) => !dispute.order_id || orderIds.has(dispute.order_id)), (dispute) => dispute.order_id ?? "");
  const linesByDisputeId = groupBy((disputeLineResult.data ?? []) as unknown as DisputeLineRow[], (line) => line.dispute_id ?? "");
  const messagesByDisputeId = groupBy((messageResult.data ?? []) as unknown as MessageRow[], (message) => message.dispute_id ?? "");
  const allocationRows = ((allocationResult.data ?? []) as unknown as AllocationRow[]).filter((allocation) => !importerId || allocation.importer_id === importerId);
  const statementRows = ((statementResult.data ?? []) as unknown as StatementSummaryRow[]).filter((row) => !importerId || row.importer_id === importerId);

  const cards = orders.map((order) => {
    const invoices = invoicesByOrderId.get(order.id) ?? [];
    const disputes = disputesByOrderId.get(order.id) ?? [];
    const warnings = disputes.flatMap((dispute) =>
      disputeWarnings(
        dispute,
        linesByDisputeId.get(dispute.id) ?? [],
        messagesByDisputeId.get(dispute.id) ?? [],
        dispute.replacement_child_order_id ? childOrderIds.has(dispute.replacement_child_order_id) : true,
      ),
    );
    const invoiceStatus = invoiceLane(invoices);
    const exceptionStatus = exceptionLane(disputes);
    const dvaStatus = dvaLane(order.importer_id, statementRows, allocationRows, order.order_ref, disputes);
    const headline = deriveHeadline(invoiceStatus, exceptionStatus, dvaStatus, warnings);
    const next = nextActionFor(headline);
    return {
      order,
      retailer: order.retailer_id ? retailersById.get(order.retailer_id) : undefined,
      invoices,
      disputes,
      invoiceStatus,
      exceptionStatus,
      dvaStatus,
      headline,
      next,
      warnings,
    };
  });

  const visibleCards = onlyWarnings ? cards.filter((card) => card.warnings.length > 0) : cards;
  const warningCount = cards.reduce((sum, card) => sum + card.warnings.length, 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.25em] text-sky-600">Status spine control</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight">Order status integrity control</h1>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            Read-only status spine across orders, invoice/OCR, commercial exceptions, DVA/card financial control and known missing lanes for shipper discrepancy/export evidence. This page is for finding contradictions before delivery, Sage or VAT readiness.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <Link href="/internal/dva-reconciliation/exception-actions" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Exception actions</Link>
            <Link href="/internal/dva-reconciliation/review-pack" className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700">DVA review pack</Link>
          </div>
        </section>

        <section className="grid gap-3 sm:grid-cols-3">
          <div className="rounded-2xl border border-slate-200 bg-white p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Orders reviewed</p>
            <p className="mt-2 text-2xl font-extrabold text-slate-950">{cards.length}</p>
          </div>
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-amber-700">Integrity warnings</p>
            <p className="mt-2 text-2xl font-extrabold text-amber-950">{warningCount}</p>
          </div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
            <p className="text-xs font-bold uppercase tracking-wide text-sky-700">Selected importer</p>
            <p className="mt-2 text-lg font-extrabold text-sky-950">{importerLabel(selectedImporter)}</p>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="grid gap-3 md:grid-cols-[1fr_auto_auto] md:items-end" action="/internal/status-control">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer
              <select name="importer_id" defaultValue={importerId} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="">All importers</option>
                {importers.map((importer) => (
                  <option key={importer.id} value={importer.id}>{importerLabel(importer)}</option>
                ))}
              </select>
            </label>
            <label className="flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold text-slate-700">
              <input type="checkbox" name="only_warnings" value="true" defaultChecked={onlyWarnings} />
              Only warnings
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply</button>
          </form>
        </section>

        {orderError ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">{orderError.message}</section>
        ) : null}
        {invoiceResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">Supplier invoice query: {invoiceResult.error.message}</section>
        ) : null}
        {disputeResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-800">Dispute query: {disputeResult.error.message}</section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">
            Showing {visibleCards.length} order status card(s)
          </div>
          {visibleCards.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No orders match this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {visibleCards.map((card) => (
                <article key={card.order.id} className="p-4">
                  <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p className="text-lg font-bold text-slate-950">{card.order.order_ref || card.order.id}</p>
                        <p className="mt-1 text-sm text-slate-600">{card.retailer?.name || "No retailer"} · Raw order status {pretty(card.order.status)} · Type {pretty(card.order.order_type)}</p>
                      </div>
                      <span className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${card.warnings.length > 0 ? "bg-amber-50 text-amber-800 ring-amber-200" : "bg-emerald-50 text-emerald-800 ring-emerald-200"}`}>
                        {pretty(card.headline)}
                      </span>
                    </div>

                    <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                      {lanePill("Invoice", card.invoiceStatus)}
                      {lanePill("Commercial exception", card.exceptionStatus)}
                      {lanePill("DVA/card", card.dvaStatus)}
                      {lanePill("Export evidence", "not_built_yet")}
                      {lanePill("Shipper discrepancy", "not_built_yet")}
                      {lanePill("Shipping/delivery", "not_built_yet")}
                      {lanePill("Accounting/VAT", card.warnings.length > 0 ? "blocked_by_status_warnings" : "not_ready_or_unchecked")}
                      {lanePill("Next owner", card.next.role)}
                    </div>

                    <div className="mt-4 rounded-xl bg-slate-50 p-3 text-sm text-slate-700">
                      <p className="font-bold text-slate-950">Next action</p>
                      <p className="mt-1">{card.next.label}</p>
                    </div>

                    {card.warnings.length > 0 ? (
                      <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
                        <p className="font-bold">Status integrity warnings</p>
                        <ul className="mt-2 list-disc space-y-1 pl-5">
                          {card.warnings.map((warning) => (
                            <li key={warning}>{warning}</li>
                          ))}
                        </ul>
                      </div>
                    ) : null}

                    {card.disputes.length > 0 ? (
                      <div className="mt-4 grid gap-2 lg:grid-cols-2">
                        {card.disputes.map((dispute) => (
                          <Link key={dispute.id} href={`/internal/exceptions/${dispute.id}`} className="rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm hover:bg-sky-50 hover:ring-1 hover:ring-sky-200">
                            <p className="font-bold text-slate-950">{pretty(dispute.desired_outcome)} · {pretty(dispute.status)}</p>
                            <p className="mt-1 text-slate-600">Impact {gbp(dispute.amount_impact_gbp)} · Open supervisor review</p>
                          </Link>
                        ))}
                      </div>
                    ) : null}
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
