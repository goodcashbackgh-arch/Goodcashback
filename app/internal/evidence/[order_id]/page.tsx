import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type DataRow = Record<string, unknown>;

type SourceState<T> = {
  source: string;
  data: T;
  error: string | null;
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

function statusSummary(recon: DataRow | null) {
  const qtyUnresolved = asNumber(pickFirst(recon, ["qty_unresolved"])) ?? 0;
  const amtUnresolved = asNumber(pickFirst(recon, ["amount_unresolved_gbp", "amount_unresolved"])) ?? 0;
  const qtyProgressed = asNumber(pickFirst(recon, ["qty_progressed", "qty_progressed_invoiceable"])) ?? 0;
  const amtProgressed =
    asNumber(pickFirst(recon, ["amount_progressed_gbp", "amount_progressed_invoiceable_gbp"])) ?? 0;

  if (qtyUnresolved <= 0 && amtUnresolved <= 0 && (qtyProgressed > 0 || amtProgressed > 0)) {
    return "Fully progressed";
  }

  if (qtyProgressed > 0 || amtProgressed > 0) {
    return "Partially progressed";
  }

  return "Unresolved";
}

export default async function InternalEvidenceDetailPage({
  params,
}: {
  params: Promise<{ order_id: string }>;
}) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();

  const [orderState, invoices, invoiceLines, tracking, reconciliationRows] = await Promise.all([
    readOrderState(supabase, orderId),
    readRowsByOrderId(supabase, "supplier_invoices", orderId),
    readRowsByOrderId(supabase, "supplier_invoice_lines", orderId),
    readRowsByOrderId(supabase, "order_tracking_submissions", orderId),
    readRowsByOrderId(supabase, "order_reconciliation_vw", orderId),
  ]);

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
    { source: invoices.source, rows: invoices.data, error: invoices.error },
    { source: invoiceLines.source, rows: invoiceLines.data, error: invoiceLines.error },
    { source: tracking.source, rows: tracking.data, error: tracking.error },
    { source: reconciliationRows.source, rows: reconciliationRows.data, error: reconciliationRows.error },
  ];

  const warnings = sourceDiagnostics.filter((source) => source.error);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-6xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/evidence" className="text-sm font-semibold text-sky-600">
            ← Back to evidence queue
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Evidence detail</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Order {orderId}</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">
            Read-only detail sourced from order state, invoices, invoice lines, tracking submissions,
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
          <h2 className="text-xl font-semibold">Header</h2>
          <div className="mt-4 grid gap-4 sm:grid-cols-3">
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">order_ref</p>
              <p className="mt-1 font-medium text-slate-900">
                {formatValue(pickFirst(orderState.data, ["order_ref", "parent_order_ref", "supplier_order_ref"]))}
              </p>
            </div>
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">lifecycle_status</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(pickFirst(orderState.data, ["lifecycle_status"]))}</p>
            </div>
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">operational_bucket</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(pickFirst(orderState.data, ["operational_bucket"]))}</p>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Funding / lifecycle context</h2>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">funding_overlay</p>
              <p className="mt-1 font-medium text-slate-900">{formatValue(pickFirst(orderState.data, ["funding_overlay"]))}</p>
            </div>
            <div>
              <p className="text-xs uppercase tracking-wide text-slate-500">shipment_readiness_overlay</p>
              <p className="mt-1 font-medium text-slate-900">
                {formatValue(pickFirst(orderState.data, ["shipment_readiness_overlay"]))}
              </p>
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Invoice section</h2>
          {invoices.data.length === 0 ? (
            <p className="mt-4 text-sm text-slate-600">No supplier invoices for this order.</p>
          ) : (
            <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">invoice_ref</th>
                    <th className="px-4 py-3 font-semibold">uploaded_at</th>
                    <th className="px-4 py-3 font-semibold">ocr_service_used</th>
                    <th className="px-4 py-3 font-semibold">reconciliation_confirmed_at</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {invoices.data.map((invoice, index) => (
                    <tr key={`${asString(pickFirst(invoice, ["id", "supplier_invoice_id", "invoice_id"])) || "invoice"}-${index}`}>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["invoice_ref", "invoice_number"]))}</td>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["uploaded_at", "created_at"]))}</td>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["ocr_service_used"]))}</td>
                      <td className="px-4 py-3">{formatValue(pickFirst(invoice, ["reconciliation_confirmed_at"]))}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Invoice lines section</h2>
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
                            <th className="px-4 py-3 font-semibold">qty</th>
                            <th className="px-4 py-3 font-semibold">amount</th>
                            <th className="px-4 py-3 font-semibold">eligible_for_invoice_yn</th>
                            <th className="px-4 py-3 font-semibold">line_source</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-slate-100 bg-white">
                          {lines.map((line, index) => {
                            const eligible = asBoolean(pickFirst(line, ["eligible_for_invoice_yn"]));
                            return (
                              <tr key={`${invoiceId}-${index}`}>
                                <td className="px-4 py-3">{formatValue(pickFirst(line, ["qty", "quantity"]))}</td>
                                <td className="px-4 py-3">
                                  {formatMoney(asNumber(pickFirst(line, ["amount", "line_amount_gbp", "amount_gbp"])))}
                                </td>
                                <td className="px-4 py-3">{formatValue(eligible)}</td>
                                <td className="px-4 py-3">
                                  {formatValue(pickFirst(line, ["line_source", "source", "entry_source"]))}
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
          <h2 className="text-xl font-semibold">Reconciliation section</h2>
          <div className="mt-4 grid gap-4 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">qty target / progressed / unresolved</p>
              <p className="mt-2 text-sm leading-6 text-slate-800">
                {formatValue(pickFirst(reconciliation, ["qty_target", "qty_target_invoiceable"]))} /{" "}
                {formatValue(pickFirst(reconciliation, ["qty_progressed", "qty_progressed_invoiceable"]))} /{" "}
                {formatValue(pickFirst(reconciliation, ["qty_unresolved"]))}
              </p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
              <p className="text-xs uppercase tracking-wide text-slate-500">amount target / progressed / unresolved</p>
              <p className="mt-2 text-sm leading-6 text-slate-800">
                {formatMoney(asNumber(pickFirst(reconciliation, ["amount_target_gbp", "amount_target_invoiceable_gbp"])))} /{" "}
                {formatMoney(
                  asNumber(pickFirst(reconciliation, ["amount_progressed_gbp", "amount_progressed_invoiceable_gbp"]))
                )} /{" "}
                {formatMoney(asNumber(pickFirst(reconciliation, ["amount_unresolved_gbp", "amount_unresolved"])))}
              </p>
            </div>
            <div className="rounded-2xl border border-slate-200 p-4">
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
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Status summary</h2>
          <p className="mt-3 inline-flex rounded-xl bg-sky-50 px-3 py-2 text-sm font-semibold text-sky-900">
            {statusSummary(reconciliation)}
          </p>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <details>
            <summary className="cursor-pointer text-xl font-semibold">Diagnostics (collapsed)</summary>
            <div className="mt-4 space-y-4">
              {sourceDiagnostics.map((source) => (
                <div key={source.source} className="rounded-2xl border border-slate-200 p-4">
                  <p className="text-sm font-semibold text-slate-900">{source.source}</p>
                  <p className="mt-1 text-xs text-slate-600">Rows: {source.rows.length.toLocaleString("en-GB")}</p>
                  <p className="mt-1 text-xs text-slate-600">
                    Error: {source.error ? source.error : "None"}
                  </p>
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
