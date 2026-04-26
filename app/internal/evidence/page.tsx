import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

type DataRow = Record<string, unknown>;

type SourcePanel = {
  title: string;
  description: string;
  source: string;
  role: string;
  rows: DataRow[];
  error: string | null;
};

const panels = [
  {
    title: "Order state",
    description:
      "Top-level order state context used to anchor the staff evidence queue.",
    source: "order_state_vw",
    role: "Primary queue anchor",
  },
  {
    title: "Supplier invoices",
    description:
      "Invoice header rows submitted for supplier evidence and OCR staging.",
    source: "supplier_invoices",
    role: "Invoice evidence source",
  },
  {
    title: "Supplier invoice lines",
    description:
      "OCR and manual invoice line scope used for progressed subset and reconciliation signals.",
    source: "supplier_invoice_lines",
    role: "OCR/progressed source",
  },
  {
    title: "Tracking submissions",
    description:
      "Tracking-first or invoice-first submission rows to verify logistics evidence state.",
    source: "order_tracking_submissions",
    role: "Tracking evidence source",
  },
  {
    title: "Order reconciliation",
    description:
      "Progressed subset and unresolved/partial-progress diagnostics from reconciliation view.",
    source: "order_reconciliation_vw",
    role: "Progress diagnostics",
  },
] as const;

const preferredBySource: Record<string, string[]> = {
  order_state_vw: [
    "order_ref",
    "payment_auth_id",
    "status",
    "invoice_status",
    "tracking_status",
    "reconciliation_status",
    "updated_at",
    "created_at",
  ],
  supplier_invoices: [
    "order_ref",
    "invoice_number",
    "status",
    "invoice_status",
    "ocr_status",
    "submitted_at",
    "created_at",
  ],
  supplier_invoice_lines: [
    "order_ref",
    "invoice_id",
    "line_type",
    "line_status",
    "reconciliation_status",
    "progressed_yn",
    "created_at",
  ],
  order_tracking_submissions: [
    "order_ref",
    "tracking_number",
    "status",
    "tracking_status",
    "submitted_at",
    "created_at",
  ],
  order_reconciliation_vw: [
    "order_ref",
    "status",
    "invoice_status",
    "tracking_status",
    "ocr_status",
    "reconciliation_status",
    "partial_progress_yn",
    "unresolved_yn",
    "progressed_subset_yn",
    "updated_at",
  ],
};

function allColumns(rows: DataRow[]) {
  return Array.from(new Set(rows.flatMap((row) => Object.keys(row))));
}

function visibleColumns(source: string, rows: DataRow[]) {
  const present = new Set(allColumns(rows));
  const preferred = preferredBySource[source] ?? [];
  const selected = preferred.filter((key) => present.has(key));

  if (selected.length > 0) return selected.slice(0, 10);
  return Object.keys(rows[0] ?? {}).slice(0, 10);
}

function formatValue(value: unknown) {
  if (value === null || value === undefined) return "—";
  if (typeof value === "boolean") return value ? "Yes" : "No";
  if (typeof value === "number") return value.toLocaleString("en-GB");
  if (typeof value === "string") {
    if (value.length > 90) return `${value.slice(0, 87)}...`;
    return value;
  }
  return JSON.stringify(value);
}

function asString(value: unknown) {
  return typeof value === "string" ? value : "";
}

function asBoolean(value: unknown) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    return ["true", "t", "yes", "y", "1"].includes(normalized);
  }
  if (typeof value === "number") return value !== 0;
  return false;
}

function pickFirst(row: DataRow, candidates: string[]) {
  for (const key of candidates) {
    if (key in row && row[key] !== null && row[key] !== undefined && row[key] !== "") {
      return row[key];
    }
  }
  return null;
}

function resolveOrderKey(row: DataRow) {
  const orderId = asString(pickFirst(row, ["order_id", "parent_order_id"])) || "";
  const orderRef = asString(
    pickFirst(row, ["order_ref", "parent_order_ref", "supplier_order_ref"])
  );
  const paymentAuthId = asString(pickFirst(row, ["payment_auth_id", "auth_id_ref"]));

  if (orderId) return `id:${orderId}`;
  if (orderRef) return `ref:${orderRef}`;
  if (paymentAuthId) return `auth:${paymentAuthId}`;
  return "";
}

function chooseStatus(row: DataRow, candidates: string[]) {
  const value = pickFirst(row, candidates);
  return value === null ? "—" : formatValue(value);
}

async function readPanel(
  supabase: Awaited<ReturnType<typeof createClient>>,
  source: string
): Promise<Omit<SourcePanel, "title" | "description" | "role">> {
  const { data, error } = await supabase.from(source).select("*").limit(50);

  return {
    source,
    rows: (data ?? []) as DataRow[],
    error: error?.message ?? null,
  };
}

export default async function InternalEvidencePage() {
  const supabase = await createClient();

  const results = await Promise.all(
    panels.map(async (panel) => ({
      ...panel,
      ...(await readPanel(supabase, panel.source)),
    }))
  );

  const bySource = new Map(results.map((result) => [result.source, result]));

  const orderState = bySource.get("order_state_vw");
  const supplierInvoices = bySource.get("supplier_invoices");
  const supplierInvoiceLines = bySource.get("supplier_invoice_lines");
  const trackingSubmissions = bySource.get("order_tracking_submissions");
  const reconciliation = bySource.get("order_reconciliation_vw");

  const invoiceCountByOrder = new Map<string, number>();
  for (const row of supplierInvoices?.rows ?? []) {
    const key = resolveOrderKey(row);
    if (!key) continue;
    invoiceCountByOrder.set(key, (invoiceCountByOrder.get(key) ?? 0) + 1);
  }

  const lineCountByOrder = new Map<string, number>();
  for (const row of supplierInvoiceLines?.rows ?? []) {
    const key = resolveOrderKey(row);
    if (!key) continue;
    lineCountByOrder.set(key, (lineCountByOrder.get(key) ?? 0) + 1);
  }

  const trackingCountByOrder = new Map<string, number>();
  for (const row of trackingSubmissions?.rows ?? []) {
    const key = resolveOrderKey(row);
    if (!key) continue;
    trackingCountByOrder.set(key, (trackingCountByOrder.get(key) ?? 0) + 1);
  }

  const reconciliationByOrder = new Map<string, DataRow>();
  for (const row of reconciliation?.rows ?? []) {
    const key = resolveOrderKey(row);
    if (!key) continue;
    if (!reconciliationByOrder.has(key)) reconciliationByOrder.set(key, row);
  }

  const queueRows = (orderState?.rows ?? []).map((row, index) => {
    const key = resolveOrderKey(row);
    const recon = key ? reconciliationByOrder.get(key) : undefined;

    const unresolved =
      asBoolean(pickFirst(row, ["unresolved_yn", "has_unresolved_yn"])) ||
      asBoolean(
        pickFirst(recon ?? {}, ["unresolved_yn", "has_unresolved_yn", "unresolved_lines_yn"])
      );

    const partialProgress =
      asBoolean(pickFirst(row, ["partial_progress_yn", "partial_progressed_yn"])) ||
      asBoolean(
        pickFirst(recon ?? {}, ["partial_progress_yn", "partial_progressed_yn", "partially_progressed_yn"])
      );

    const progressedSubset =
      asBoolean(pickFirst(row, ["progressed_subset_yn", "stable_progressed_subset_yn"])) ||
      asBoolean(
        pickFirst(recon ?? {}, ["progressed_subset_yn", "stable_progressed_subset_yn"])
      );

    return {
      key: key || `fallback-${index}`,
      orderRef: chooseStatus(row, ["order_ref", "parent_order_ref", "supplier_order_ref"]),
      paymentAuthId: chooseStatus(row, ["payment_auth_id", "auth_id_ref"]),
      orderStatus: chooseStatus(row, ["status", "order_status"]),
      invoiceStatus: chooseStatus(
        { ...recon, ...row },
        ["invoice_status", "supplier_invoice_status", "invoice_evidence_status"]
      ),
      trackingStatus: chooseStatus(
        { ...recon, ...row },
        ["tracking_status", "shipment_tracking_status", "tracking_evidence_status"]
      ),
      ocrStatus: chooseStatus(
        { ...recon, ...row },
        ["ocr_status", "reconciliation_status", "ocr_reconciliation_status"]
      ),
      progressedSubset,
      partialProgress,
      unresolved,
      invoiceRows: key ? invoiceCountByOrder.get(key) ?? 0 : 0,
      trackingRows: key ? trackingCountByOrder.get(key) ?? 0 : 0,
      lineRows: key ? lineCountByOrder.get(key) ?? 0 : 0,
    };
  });

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">
            ← Back to internal dashboard
          </Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">
            Day 3 evidence workflow
          </p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Evidence / OCR queue</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Read-only internal review shell for invoice-first and tracking-first evidence flow,
            OCR/reconciliation progress, and progressed subset diagnostics.
          </p>
        </section>

        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-5">
          {results.map((panel) => (
            <div
              key={panel.source}
              className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"
            >
              <p className="text-sm text-slate-500">{panel.title}</p>
              <p className="mt-2 text-3xl font-semibold">{panel.error ? "—" : panel.rows.length}</p>
              <p className="mt-3 text-xs leading-5 text-slate-500">Source: {panel.source}</p>
            </div>
          ))}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Evidence/OCR queue</h2>
          <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
            Queue rows are anchored from <code className="mx-1 rounded bg-slate-100 px-1 py-0.5">order_state_vw</code>
            and augmented with status and count indicators when matching keys are available.
          </p>

          {orderState?.error ? (
            <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
              Queue unavailable because order state source could not be read: {orderState.error}
            </div>
          ) : queueRows.length === 0 ? (
            <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
              No order rows returned from order_state_vw.
            </div>
          ) : (
            <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
              <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-3 font-semibold">Order</th>
                    <th className="px-4 py-3 font-semibold">Auth</th>
                    <th className="px-4 py-3 font-semibold">Order status</th>
                    <th className="px-4 py-3 font-semibold">Invoice status</th>
                    <th className="px-4 py-3 font-semibold">Tracking status</th>
                    <th className="px-4 py-3 font-semibold">OCR/Reconciliation</th>
                    <th className="px-4 py-3 font-semibold">Progress indicators</th>
                    <th className="px-4 py-3 font-semibold">Source rows</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {queueRows.map((row) => (
                    <tr key={row.key}>
                      <td className="px-4 py-3 align-top font-medium text-slate-900">{row.orderRef}</td>
                      <td className="px-4 py-3 align-top text-slate-700">{row.paymentAuthId}</td>
                      <td className="px-4 py-3 align-top text-slate-700">{row.orderStatus}</td>
                      <td className="px-4 py-3 align-top text-slate-700">{row.invoiceStatus}</td>
                      <td className="px-4 py-3 align-top text-slate-700">{row.trackingStatus}</td>
                      <td className="px-4 py-3 align-top text-slate-700">{row.ocrStatus}</td>
                      <td className="px-4 py-3 align-top text-xs text-slate-700">
                        <div>Progressed subset: {row.progressedSubset ? "Yes" : "No"}</div>
                        <div>Partial progress: {row.partialProgress ? "Yes" : "No"}</div>
                        <div>Unresolved: {row.unresolved ? "Yes" : "No"}</div>
                      </td>
                      <td className="px-4 py-3 align-top text-xs text-slate-700">
                        <div>Invoices: {row.invoiceRows}</div>
                        <div>Tracking: {row.trackingRows}</div>
                        <div>Invoice lines: {row.lineRows}</div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        {results.map((panel) => {
          const columns = visibleColumns(panel.source, panel.rows);
          const available = allColumns(panel.rows);

          return (
            <section
              key={panel.source}
              className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm"
            >
              <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
                <div>
                  <h2 className="text-xl font-semibold">{panel.title}</h2>
                  <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-600">{panel.description}</p>
                  <div className="mt-2 flex flex-wrap gap-2 text-xs text-slate-500">
                    <span>Source: {panel.source}</span>
                    <span>•</span>
                    <span>{panel.role}</span>
                  </div>
                </div>
                <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-600">
                  {panel.error ? "Unavailable" : `${panel.rows.length} rows`}
                </span>
              </div>

              {panel.error ? (
                <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
                  Could not read this source yet: {panel.error}
                </div>
              ) : panel.rows.length === 0 ? (
                <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
                  No rows returned. This can be correct if there is no current work in this queue.
                </div>
              ) : (
                <>
                  <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
                    <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
                      <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          {columns.map((column) => (
                            <th key={column} className="px-4 py-3 font-semibold">
                              {column.replaceAll("_", " ")}
                            </th>
                          ))}
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100 bg-white">
                        {panel.rows.map((row, index) => (
                          <tr key={`${panel.source}-${index}`}>
                            {columns.map((column) => (
                              <td key={column} className="max-w-xs px-4 py-3 align-top text-slate-700">
                                {formatValue(row[column])}
                              </td>
                            ))}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>

                  <details className="mt-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">
                    <summary className="cursor-pointer font-semibold text-slate-900">
                      Show available columns for {panel.source}
                    </summary>
                    <p className="mt-3 leading-6">{available.join(", ")}</p>
                  </details>
                </>
              )}
            </section>
          );
        })}

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Evidence queue boundaries</h2>
          <p className="mt-2">
            This shell is read-only for staff review. It does not add upload flows, OCR integration,
            reconciliation mutation actions, or exception/refund/replacement controls.
          </p>
        </section>
      </div>
    </main>
  );
}
