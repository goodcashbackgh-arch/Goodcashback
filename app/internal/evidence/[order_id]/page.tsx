import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import {
  cancelOrderEvidenceQueryAction,
  closeOrderEvidenceQueryAction,
  createOrderEvidenceQueryAction,
} from "./actions";

type DataRow = Record<string, unknown>;

type SourceState<T> = {
  source: string;
  data: T;
  error: string | null;
};

type PhysicalLineSummary = {
  physicalTargetQty: number;
  physicalProgressedQty: number;
  physicalUnresolvedQty: number;
  physicalTargetAmount: number;
  physicalProgressedAmount: number;
  physicalUnresolvedAmount: number;
  parkedLineCount: number;
  parkedAmount: number;
  status: string;
};

function asString(value: unknown) {
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value === "string") {
    const parsed = Number(value.replace(/,/g, "").trim());
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function asBoolean(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "t", "yes", "y", "1"].includes(normalized)) return true;
    if (["false", "f", "no", "n", "0"].includes(normalized)) return false;
  }
  return null;
}

function formatValue(value: unknown) {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number") return value.toLocaleString("en-GB");
  return String(value);
}

function formatMoney(value: number | null) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value ?? 0);
}

function pickFirst(row: DataRow | null | undefined, candidates: string[]) {
  if (!row) return null;
  for (const key of candidates) {
    const value = row[key];
    if (value !== null && value !== undefined && value !== "") return value;
  }
  return null;
}

function getColumns(rows: DataRow[]) {
  return Array.from(new Set(rows.flatMap((row) => Object.keys(row)))).sort();
}

function lineQty(line: DataRow) {
  return asNumber(pickFirst(line, ["qty", "quantity", "qty_confirmed"])) ?? 0;
}

function lineAmount(line: DataRow) {
  return (
    asNumber(
      pickFirst(line, [
        "amount_inc_vat_gbp",
        "amount_confirmed",
        "amount",
        "line_amount_gbp",
        "amount_gbp",
        "total_price",
      ])
    ) ?? 0
  );
}

function lineConfirmedAmount(line: DataRow) {
  return asNumber(pickFirst(line, ["amount_confirmed", "amount_inc_vat_gbp", "amount", "line_amount_gbp", "amount_gbp"]));
}

function isPhysicalInvoiceLine(line: DataRow) {
  return asBoolean(pickFirst(line, ["eligible_for_invoice_yn"])) === true;
}

function isProgressedPhysicalLine(line: DataRow) {
  if (!isPhysicalInvoiceLine(line)) return false;
  return pickFirst(line, ["qty_confirmed"]) !== null && pickFirst(line, ["amount_confirmed"]) !== null;
}

function buildPhysicalLineSummary(lines: DataRow[]): PhysicalLineSummary {
  const physicalLines = lines.filter(isPhysicalInvoiceLine);
  const progressedPhysicalLines = physicalLines.filter(isProgressedPhysicalLine);
  const parkedLines = lines.filter((line) => !isPhysicalInvoiceLine(line));

  const physicalTargetQty = physicalLines.reduce((total, line) => total + lineQty(line), 0);
  const physicalProgressedQty = progressedPhysicalLines.reduce(
    (total, line) => total + (asNumber(pickFirst(line, ["qty_confirmed"])) ?? lineQty(line)),
    0
  );
  const physicalTargetAmount = physicalLines.reduce((total, line) => total + lineAmount(line), 0);
  const physicalProgressedAmount = progressedPhysicalLines.reduce(
    (total, line) => total + (lineConfirmedAmount(line) ?? 0),
    0
  );
  const physicalUnresolvedQty = Math.max(physicalTargetQty - physicalProgressedQty, 0);
  const physicalUnresolvedAmount = Math.max(physicalTargetAmount - physicalProgressedAmount, 0);
  const parkedAmount = parkedLines.reduce((total, line) => total + lineAmount(line), 0);

  let status = "No physical goods lines";
  if (physicalLines.length > 0 && physicalUnresolvedQty <= 0 && physicalUnresolvedAmount <= 0) {
    status = "Physical goods progressed";
  } else if (physicalProgressedQty > 0 || physicalProgressedAmount > 0) {
    status = "Physical goods partially progressed";
  } else if (physicalLines.length > 0) {
    status = "Physical goods unresolved";
  }

  return {
    physicalTargetQty,
    physicalProgressedQty,
    physicalUnresolvedQty,
    physicalTargetAmount,
    physicalProgressedAmount,
    physicalUnresolvedAmount,
    parkedLineCount: parkedLines.length,
    parkedAmount,
    status,
  };
}

function statusPillClass(tone: string) {
  const normalized = tone.toLowerCase();
  if (normalized.includes("complete") || normalized.includes("progressed") || normalized.includes("approved")) {
    return "bg-emerald-50 text-emerald-900";
  }
  if (normalized.includes("partial") || normalized.includes("pending") || normalized.includes("review")) {
    return "bg-amber-50 text-amber-900";
  }
  if (normalized.includes("blocked") || normalized.includes("exception") || normalized.includes("unresolved")) {
    return "bg-rose-50 text-rose-900";
  }
  return "bg-sky-50 text-sky-900";
}

async function readOrderState(
  supabase: Awaited<ReturnType<typeof createClient>>,
  orderId: string
): Promise<SourceState<DataRow | null>> {
  const byId = await supabase.from("order_state_vw").select("*").eq("id", orderId).maybeSingle();
  if (!byId.error) {
    return { source: "order_state_vw", data: (byId.data as DataRow | null) ?? null, error: null };
  }

  const byOrderId = await supabase
    .from("order_state_vw")
    .select("*")
    .eq("order_id", orderId)
    .maybeSingle();

  if (byOrderId.error) {
    return {
      source: "order_state_vw",
      data: null,
      error: `${byId.error.message} | Fallback: ${byOrderId.error.message}`,
    };
  }

  return { source: "order_state_vw", data: (byOrderId.data as DataRow | null) ?? null, error: null };
}

async function readRowsByOrderId(
  supabase: Awaited<ReturnType<typeof createClient>>,
  source: string,
  orderId: string
): Promise<SourceState<DataRow[]>> {
  const { data, error } = await supabase.from(source).select("*").eq("order_id", orderId);
  return { source, data: (data ?? []) as DataRow[], error: error?.message ?? null };
}

async function readInvoiceLinesByInvoiceIds(
  supabase: Awaited<ReturnType<typeof createClient>>,
  invoiceIds: string[]
): Promise<SourceState<DataRow[]>> {
  if (invoiceIds.length === 0) {
    return { source: "supplier_invoice_lines", data: [], error: null };
  }

  const { data, error } = await supabase
    .from("supplier_invoice_lines")
    .select("*")
    .in("supplier_invoice_id", invoiceIds);

  return {
    source: "supplier_invoice_lines",
    data: (data ?? []) as DataRow[],
    error: error?.message ?? null,
  };
}

async function readRpcRowByOrderId(
  supabase: Awaited<ReturnType<typeof createClient>>,
  functionName: string,
  orderId: string
): Promise<SourceState<DataRow | null>> {
  const { data, error } = await (supabase as any).rpc(functionName).eq("order_id", orderId).maybeSingle();
  return { source: functionName, data: (data ?? null) as DataRow | null, error: error?.message ?? null };
}

export default async function InternalEvidenceDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string }>;
  searchParams?: Promise<{
    query_success?: string;
    query_error?: string;
  }>;
}) {
  const { order_id: orderId } = await params;
  const queryParams = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const [orderState, canonicalStatus, canonicalProgress, invoices, tracking, reconciliationRows] = await Promise.all([
    readOrderState(supabase, orderId),
    readRpcRowByOrderId(supabase, "internal_platform_order_status_v1", orderId),
    readRpcRowByOrderId(supabase, "internal_platform_order_progress_v1", orderId),
    readRowsByOrderId(supabase, "supplier_invoices", orderId),
    readRowsByOrderId(supabase, "order_tracking_submissions", orderId),
    readRowsByOrderId(supabase, "order_reconciliation_vw", orderId),
  ]);

  const invoiceIds = invoices.data
    .map((invoice) => asString(pickFirst(invoice, ["id", "supplier_invoice_id", "invoice_id"])).trim())
    .filter((invoiceId) => invoiceId.length > 0);

  const invoiceLines = await readInvoiceLinesByInvoiceIds(supabase, invoiceIds);
  const physicalLineSummary = buildPhysicalLineSummary(invoiceLines.data);

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: staff } = user
    ? await supabase
        .from("staff")
        .select("id, role_type")
        .eq("auth_user_id", user.id)
        .eq("active", true)
        .maybeSingle()
    : { data: null };
  const canCreateEvidenceQuery = ["admin", "supervisor"].includes(String(staff?.role_type));
  const { data: evidenceQueries, error: evidenceQueriesError } = await supabase
    .from("order_evidence_queries")
    .select(
      "id, query_type, message, status, supplier_invoice_id, supplier_invoice_line_id, order_tracking_submission_id, answer_text, created_at"
    )
    .eq("order_id", orderId)
    .order("created_at", { ascending: false });

  const reconciliation = reconciliationRows.data[0] ?? null;

  const invoicesById = new Map<string, DataRow>();
  for (const invoice of invoices.data) {
    const invoiceId = asString(pickFirst(invoice, ["id", "supplier_invoice_id", "invoice_id"])).trim();
    if (invoiceId) invoicesById.set(invoiceId, invoice);
  }

  const linesByInvoice = new Map<string, DataRow[]>();
  for (const line of invoiceLines.data) {
    const invoiceId = asString(pickFirst(line, ["supplier_invoice_id", "invoice_id"])) || "unmapped";
    const current = linesByInvoice.get(invoiceId) ?? [];
    current.push(line);
    linesByInvoice.set(invoiceId, current);
  }

  const sourceDiagnostics = [
    { source: orderState.source, rows: orderState.data ? [orderState.data] : [], error: orderState.error },
    { source: canonicalStatus.source, rows: canonicalStatus.data ? [canonicalStatus.data] : [], error: canonicalStatus.error },
    { source: canonicalProgress.source, rows: canonicalProgress.data ? [canonicalProgress.data] : [], error: canonicalProgress.error },
    { source: invoices.source, rows: invoices.data, error: invoices.error },
    { source: invoiceLines.source, rows: invoiceLines.data, error: invoiceLines.error },
    { source: tracking.source, rows: tracking.data, error: tracking.error },
    { source: reconciliationRows.source, rows: reconciliationRows.data, error: reconciliationRows.error },
  ];

  const warnings = sourceDiagnostics.filter((source) => source.error);
  const orderRef = pickFirst(canonicalStatus.data, ["order_ref"]) ?? pickFirst(orderState.data, ["order_ref", "parent_order_ref", "supplier_order_ref"]);
  const statusSummary = asString(pickFirst(canonicalStatus.data, ["current_stage_label", "current_stage"])) || physicalLineSummary.status;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-6xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/evidence" className="text-sm font-semibold text-sky-600">
            ← Back to evidence queue
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Evidence detail</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Order {formatValue(orderRef)}</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Read-only detail sourced from canonical operational status, invoices, invoice lines, tracking submissions,
            and reconciliation diagnostics.
          </p>
        </section>

        {warnings.length > 0 ? (
          <section className="rounded-3xl border border-amber-300 bg-amber-50 p-5 text-sm text-amber-900 shadow-sm">
            <h2 className="text-base font-semibold">Data source warnings</h2>
            <ul className="mt-3 list-disc space-y-1 pl-5">
              {warnings.map((warning) => (
                <li key={warning.source}>
                  {warning.source}: {warning.error}
                </li>
              ))}
            </ul>
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Canonical status</h2>
          <div className="mt-4 grid gap-4 sm:grid-cols-3">
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">order_ref</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(orderRef)}</p>
            </div>
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">current_stage</p>
              <p className="mt-1 font-medium text-slate-900">
                {formatValue(pickFirst(canonicalStatus.data, ["current_stage", "current_stage_label"]))}
              </p>
            </div>
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">next_action</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(pickFirst(canonicalStatus.data, ["next_action"]))}</p>
            </div>
          </div>
          <div className="mt-4 grid gap-4 sm:grid-cols-4">
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">supplier</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(pickFirst(canonicalStatus.data, ["supplier_state"]))}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">tracking</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(pickFirst(canonicalStatus.data, ["tracking_state"]))}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">shipment/export/pod</p>
              <p className="mt-1 font-medium text-slate-900">
                {formatValue(pickFirst(canonicalStatus.data, ["shipment_state"]))} / {formatValue(pickFirst(canonicalStatus.data, ["export_evidence_state"]))} / {formatValue(pickFirst(canonicalStatus.data, ["pod_delivery_state"]))}
              </p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">gates</p>
              <p className="mt-1 font-medium text-slate-900">
                {formatValue(pickFirst(canonicalProgress.data, ["gate_complete_count"]))} / {formatValue(pickFirst(canonicalProgress.data, ["gate_total"]))}
              </p>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Supplier invoice approval gate</h2>
          {invoices.data.length === 0 ? (
            <p className="mt-4 text-sm text-slate-600">No supplier invoices for this order.</p>
          ) : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">invoice_ref</th>
                    <th className="px-4 py-3 font-semibold">review_status</th>
                    <th className="px-4 py-3 font-semibold">blocked_from_sage</th>
                    <th className="px-4 py-3 font-semibold">current_for_order</th>
                    <th className="px-4 py-3 font-semibold">reviewed_at</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {invoices.data.map((invoice, index) => (
                    <tr key={`${asString(pickFirst(invoice, ["id", "supplier_invoice_id", "invoice_id"])) || "invoice"}-${index}`}>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["invoice_ref", "invoice_number"]))}</td>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["review_status"]))}</td>
                      <td className="px-4 py-3">{formatValue(asBoolean(pickFirst(invoice, ["blocked_from_sage_yn"])))}</td>
                      <td className="px-4 py-3">{formatValue(asBoolean(pickFirst(invoice, ["is_current_for_order"])))}</td>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["reviewed_at"]))}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Invoice lines section</h2>
          <p className="mt-2 text-sm text-slate-600">
            Physical goods lines are shown separately from parked non-physical rows such as delivery, fees, or zero-value informational rows.
          </p>
          {linesByInvoice.size === 0 ? (
            <p className="mt-4 text-sm text-slate-600">No supplier invoice lines for this order.</p>
          ) : (
            <div className="mt-4 flex flex-col gap-4">
              {Array.from(linesByInvoice.entries()).map(([invoiceId, lines]) => {
                const invoice = invoicesById.get(invoiceId);
                return (
                  <div key={invoiceId} className="rounded-2xl border border-slate-200">
                    <div className="border-b border-slate-200 bg-slate-50 px-4 py-3 text-sm">
                      <span className="font-semibold">Invoice:</span>{" "}
                      {formatValue(pickFirst(invoice, ["invoice_ref", "invoice_number"]) ?? invoiceId)}
                    </div>
                    <div className="overflow-x-auto">
                      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                        <thead className="bg-white text-xs uppercase tracking-wide text-slate-500">
                          <tr>
                            <th className="px-4 py-3 font-semibold">description</th>
                            <th className="px-4 py-3 font-semibold">qty</th>
                            <th className="px-4 py-3 font-semibold">amount_inc_vat</th>
                            <th className="px-4 py-3 font-semibold">amount_confirmed</th>
                            <th className="px-4 py-3 font-semibold">eligible</th>
                            <th className="px-4 py-3 font-semibold">line_state</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-slate-100 bg-white">
                          {lines.map((line, index) => {
                            const eligible = asBoolean(pickFirst(line, ["eligible_for_invoice_yn"]));
                            const progressed = isProgressedPhysicalLine(line);
                            return (
                              <tr key={`${invoiceId}-${index}`}>
                                <td className="px-4 py-3">{formatValue(pickFirst(line, ["description", "line_description"]))}</td>
                                <td className="px-4 py-3">{formatValue(pickFirst(line, ["qty", "quantity"]))}</td>
                                <td className="px-4 py-3">{formatMoney(asNumber(pickFirst(line, ["amount_inc_vat_gbp", "amount", "line_amount_gbp", "amount_gbp"])))}</td>
                                <td className="px-4 py-3">{formatMoney(asNumber(pickFirst(line, ["amount_confirmed"])))}</td>
                                <td className="px-4 py-3">{formatValue(eligible)}</td>
                                <td className="px-4 py-3">
                                  {eligible ? (progressed ? "Physical progressed" : "Physical unresolved") : "Parked non-physical"}
                                </td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Tracking section</h2>
          {tracking.data.length === 0 ? (
            <p className="mt-4 text-sm text-slate-600">No tracking submissions for this order.</p>
          ) : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">tracking_ref</th>
                    <th className="px-4 py-3 font-semibold">tracking_date</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {tracking.data.map((row, index) => (
                    <tr key={`${asString(pickFirst(row, ["id"])) || "tracking"}-${index}`}>
                      <td className="px-4 py-3">{formatValue(pickFirst(row, ["tracking_ref", "tracking_number"]))}</td>
                      <td className="px-4 py-3">{formatValue(pickFirst(row, ["tracking_date", "created_at"]))}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Physical goods reconciliation</h2>
          <div className="mt-4 grid gap-4 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">physical qty target / progressed / unresolved</p>
              <p className="mt-2 text-sm leading-6 text-slate-800">
                {physicalLineSummary.physicalTargetQty} / {physicalLineSummary.physicalProgressedQty} / {physicalLineSummary.physicalUnresolvedQty}
              </p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">physical amount target / progressed / unresolved</p>
              <p className="mt-2 text-sm leading-6 text-slate-800">
                {formatMoney(physicalLineSummary.physicalTargetAmount)} / {formatMoney(physicalLineSummary.physicalProgressedAmount)} / {formatMoney(physicalLineSummary.physicalUnresolvedAmount)}
              </p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">parked non-physical rows / amount</p>
              <p className="mt-2 text-sm font-medium text-slate-900">
                {physicalLineSummary.parkedLineCount} / {formatMoney(physicalLineSummary.parkedAmount)}
              </p>
            </div>
          </div>
          <details className="mt-4 rounded-2xl border border-slate-200 p-4">
            <summary className="cursor-pointer text-sm font-semibold text-slate-700">Legacy reconciliation view</summary>
            <div className="mt-4 grid gap-4 md:grid-cols-3">
              <div>
                <p className="text-xs uppercase tracking-wide text-slate-500">legacy qty target / progressed / unresolved</p>
                <p className="mt-2 text-sm leading-6 text-slate-800">
                  {formatValue(pickFirst(reconciliation, ["qty_target", "qty_target_invoiceable"]))} /{" "}
                  {formatValue(pickFirst(reconciliation, ["qty_progressed", "qty_progressed_invoiceable"]))} /{" "}
                  {formatValue(pickFirst(reconciliation, ["qty_unresolved"]))}
                </p>
              </div>
              <div>
                <p className="text-xs uppercase tracking-wide text-slate-500">legacy amount target / progressed / unresolved</p>
                <p className="mt-2 text-sm leading-6 text-slate-800">
                  {formatMoney(asNumber(pickFirst(reconciliation, ["amount_target_gbp", "amount_target_invoiceable_gbp"])))} /{" "}
                  {formatMoney(asNumber(pickFirst(reconciliation, ["amount_progressed_gbp", "amount_progressed_invoiceable_gbp"])))} /{" "}
                  {formatMoney(asNumber(pickFirst(reconciliation, ["amount_unresolved_gbp", "amount_unresolved"]))) }
                </p>
              </div>
              <div>
                <p className="text-xs uppercase tracking-wide text-slate-500">invoiceable_subset_released_yn</p>
                <p className="mt-2 text-sm font-medium text-slate-900">
                  {formatValue(
                    asBoolean(
                      pickFirst(reconciliation, ["invoiceable_subset_released_yn"]) ??
                        pickFirst(orderState.data, ["invoiceable_subset_released_yn"])
                    )
                  )}
                </p>
              </div>
            </div>
          </details>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Status summary</h2>
          <p className={`mt-3 inline-flex rounded-xl px-3 py-2 text-sm font-semibold ${statusPillClass(statusSummary)}`}>
            {statusSummary}
          </p>
          <p className="mt-3 inline-flex rounded-xl bg-emerald-50 px-3 py-2 text-sm font-semibold text-emerald-900">
            {physicalLineSummary.status}
          </p>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Query Importer</h2>
          {canCreateEvidenceQuery ? (
            <form action={createOrderEvidenceQueryAction} className="mt-4 space-y-4">
              <input type="hidden" name="order_id" value={orderId} />
              <div>
                <label htmlFor="query_type" className="text-xs uppercase tracking-wide text-slate-500">
                  query_type
                </label>
                <select
                  id="query_type"
                  name="query_type"
                  required
                  className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                  defaultValue="missing_invoice"
                >
                  <option value="missing_invoice">missing_invoice</option>
                  <option value="missing_tracking">missing_tracking</option>
                  <option value="ocr_unclear">ocr_unclear</option>
                  <option value="invoice_total_mismatch">invoice_total_mismatch</option>
                  <option value="line_clarification">line_clarification</option>
                  <option value="general_evidence_question">general_evidence_question</option>
                </select>
              </div>
              <div>
                <label htmlFor="message" className="text-xs uppercase tracking-wide text-slate-500">
                  message
                </label>
                <textarea
                  id="message"
                  name="message"
                  required
                  rows={4}
                  className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                />
              </div>
              <div className="grid gap-4 md:grid-cols-3">
                <div>
                  <label htmlFor="supplier_invoice_id" className="text-xs uppercase tracking-wide text-slate-500">
                    supplier_invoice_id (optional)
                  </label>
                  <select
                    id="supplier_invoice_id"
                    name="supplier_invoice_id"
                    className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                    defaultValue=""
                  >
                    <option value="">None</option>
                    {invoices.data.map((invoice) => {
                      const invoiceId = asString(pickFirst(invoice, ["id", "supplier_invoice_id", "invoice_id"]));
                      if (!invoiceId) return null;
                      const invoiceLabel = asString(pickFirst(invoice, ["invoice_ref", "invoice_number"])) || invoiceId;
                      return (
                        <option key={invoiceId} value={invoiceId}>
                          {invoiceLabel}
                        </option>
                      );
                    })}
                  </select>
                </div>
                <div>
                  <label htmlFor="supplier_invoice_line_id" className="text-xs uppercase tracking-wide text-slate-500">
                    supplier_invoice_line_id (optional)
                  </label>
                  <select
                    id="supplier_invoice_line_id"
                    name="supplier_invoice_line_id"
                    className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                    defaultValue=""
                  >
                    <option value="">None</option>
                    {invoiceLines.data.map((line) => {
                      const lineId = asString(pickFirst(line, ["id", "supplier_invoice_line_id", "line_id"]));
                      if (!lineId) return null;
                      const lineLabel =
                        asString(pickFirst(line, ["description", "supplier_invoice_line_ref", "line_ref", "sku"])) || lineId;
                      return (
                        <option key={lineId} value={lineId}>
                          {lineLabel}
                        </option>
                      );
                    })}
                  </select>
                </div>
                <div>
                  <label
                    htmlFor="order_tracking_submission_id"
                    className="text-xs uppercase tracking-wide text-slate-500"
                  >
                    order_tracking_submission_id (optional)
                  </label>
                  <select
                    id="order_tracking_submission_id"
                    name="order_tracking_submission_id"
                    className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm"
                    defaultValue=""
                  >
                    <option value="">None</option>
                    {tracking.data.map((row) => {
                      const trackingId = asString(pickFirst(row, ["id", "order_tracking_submission_id"]));
                      if (!trackingId) return null;
                      const trackingLabel = asString(pickFirst(row, ["tracking_ref", "tracking_number"])) || trackingId;
                      return (
                        <option key={trackingId} value={trackingId}>
                          {trackingLabel}
                        </option>
                      );
                    })}
                  </select>
                </div>
              </div>
              <button
                type="submit"
                className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white hover:bg-sky-500"
              >
                Create evidence query
              </button>
            </form>
          ) : (
            <p className="mt-4 text-sm text-slate-600">Staff admin/supervisor role is required to create queries.</p>
          )}

          {queryParams.query_success ? (
            <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
              {queryParams.query_success}
            </p>
          ) : null}
          {queryParams.query_error ? (
            <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">
              {queryParams.query_error}
            </p>
          ) : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Evidence queries</h2>
          {evidenceQueriesError ? (
            <p className="mt-4 text-sm text-rose-700">Failed to load evidence queries: {evidenceQueriesError.message}</p>
          ) : evidenceQueries && evidenceQueries.length > 0 ? (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">created_at</th>
                    <th className="px-4 py-3 font-semibold">query_type</th>
                    <th className="px-4 py-3 font-semibold">status</th>
                    <th className="px-4 py-3 font-semibold">message</th>
                    <th className="px-4 py-3 font-semibold">context</th>
                    <th className="px-4 py-3 font-semibold">answer</th>
                    <th className="px-4 py-3 font-semibold">action</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {evidenceQueries.map((query) => {
                    const status = asString(query.status).toLowerCase();
                    const queryId = asString(query.id);
                    return (
                      <tr key={queryId}>
                        <td className="px-4 py-3">{formatValue(query.created_at)}</td>
                        <td className="px-4 py-3">{formatValue(query.query_type)}</td>
                        <td className="px-4 py-3">{formatValue(query.status)}</td>
                        <td className="max-w-md px-4 py-3">{formatValue(query.message)}</td>
                        <td className="px-4 py-3">
                          <div className="space-y-1 text-xs text-slate-600">
                            <p>invoice: {formatValue(query.supplier_invoice_id)}</p>
                            <p>line: {formatValue(query.supplier_invoice_line_id)}</p>
                            <p>tracking: {formatValue(query.order_tracking_submission_id)}</p>
                          </div>
                        </td>
                        <td className="max-w-sm px-4 py-3">{formatValue(query.answer_text)}</td>
                        <td className="px-4 py-3">
                          {status === "answered" || status === "open" ? (
                            <form action={closeOrderEvidenceQueryAction} className="space-y-2">
                              <input type="hidden" name="order_id" value={orderId} />
                              <input type="hidden" name="query_id" value={queryId} />
                              <input
                                type="text"
                                name="notes"
                                placeholder="Optional closure reason"
                                className="w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
                              />
                              <button
                                type="submit"
                                className="rounded-lg bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-500"
                              >
                                Close query
                              </button>
                            </form>
                          ) : null}
                          {status === "open" ? (
                            <form action={cancelOrderEvidenceQueryAction} className="space-y-2">
                              <input type="hidden" name="order_id" value={orderId} />
                              <input type="hidden" name="query_id" value={queryId} />
                              <input
                                type="text"
                                name="notes"
                                placeholder="Optional cancellation note"
                                className="w-full rounded-lg border border-slate-300 px-2 py-1 text-xs"
                              />
                              <button
                                type="submit"
                                className="rounded-lg bg-rose-600 px-3 py-1 text-xs font-semibold text-white hover:bg-rose-500"
                              >
                                Cancel query
                              </button>
                            </form>
                          ) : null}
                          {status !== "answered" && status !== "open" ? (
                            <span className="text-xs text-slate-500">—</span>
                          ) : null}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="mt-4 text-sm text-slate-600">No evidence queries for this order.</p>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <details>
            <summary className="cursor-pointer text-xl font-semibold">Diagnostics (collapsed)</summary>
            <div className="mt-4 space-y-4">
              {sourceDiagnostics.map((source) => (
                <div key={source.source} className="rounded-2xl border border-slate-200 p-4">
                  <p className="text-sm font-semibold text-slate-900">{source.source}</p>
                  <p className="mt-1 text-xs text-slate-600">Rows: {source.rows.length.toLocaleString("en-GB")}</p>
                  <p className="mt-1 text-xs text-slate-600">Error: {source.error ? source.error : "None"}</p>
                  <p className="mt-2 break-all text-xs text-slate-500">
                    Available columns: {getColumns(source.rows).join(", ") || "No columns returned"}
                  </p>
                </div>
              ))}
            </div>
          </details>
        </section>
      </div>
    </main>
  );
}
