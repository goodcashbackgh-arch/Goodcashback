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


type EvidenceQueryRow = {
  order_id: string | null;
  status: string | null;
  query_type: string | null;
  created_at: string | null;
};

type EvidenceQuerySummary = {
  openCount: number;
  latestOpenQueryType: string;
  latestAnsweredQueryType: string;
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
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
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

function asNumber(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }
  if (typeof value === "string") {
    const normalized = value.trim().replace(/,/g, "");
    if (!normalized) return null;
    const parsed = Number(normalized);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function pickFirst(row: DataRow, candidates: string[]) {
  for (const key of candidates) {
    if (key in row && row[key] !== null && row[key] !== undefined && row[key] !== "") {
      return row[key];
    }
  }
  return null;
}

function parseDate(value: unknown): number | null {
  if (value instanceof Date) {
    const ms = value.getTime();
    return Number.isFinite(ms) ? ms : null;
  }
  if (typeof value === "string" || typeof value === "number") {
    const ms = new Date(value).getTime();
    return Number.isFinite(ms) ? ms : null;
  }
  return null;
}

function resolveMatchingOrderKey(row: DataRow) {
  return resolveOrderKey(row).trim();
}

function toOrderIdKey(value: unknown) {
  const orderId = asString(value).trim();
  return orderId ? `id:${orderId}` : "";
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

function resolveOrderId(row: DataRow) {
  return asString(pickFirst(row, ["id", "order_id", "parent_order_id"])).trim();
}

function resolveCanonicalOrderStateKey(row: DataRow) {
  return toOrderIdKey(pickFirst(row, ["id"]));
}

function resolveTrackingSubmissionOrderIdKey(row: DataRow) {
  return toOrderIdKey(pickFirst(row, ["order_id"]));
}

function resolveSupplierInvoiceOrderKey(row: DataRow) {
  return toOrderIdKey(pickFirst(row, ["order_id"]));
}

function resolveInvoiceId(row: DataRow) {
  return asString(pickFirst(row, ["id", "supplier_invoice_id", "invoice_id"])).trim();
}

function toBooleanLabel(value: boolean | null) {
  if (value === null) return "Unknown";
  return value ? "Yes" : "No";
}

function readBoolean(row: DataRow, candidates: string[]): boolean | null {
  for (const key of candidates) {
    if (key in row && row[key] !== null && row[key] !== undefined && row[key] !== "") {
      return asBoolean(row[key]);
    }
  }
  return null;
}

function chooseStatus(row: DataRow, candidates: string[]) {
  const value = pickFirst(row, candidates);
  return value === null ? "—" : formatValue(value);
}

function formatProgressAmount(value: number) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
}

function upsertTrackingSummary(
  map: Map<
    string,
    { count: number; latestTrackingRef: string; latestTrackingDate: unknown; latestSortMs: number }
  >,
  key: string,
  row: DataRow
) {
  if (!key) return;

  const current = map.get(key) ?? {
    count: 0,
    latestTrackingRef: "",
    latestTrackingDate: null,
    latestSortMs: Number.NEGATIVE_INFINITY,
  };
  current.count += 1;

  const sortValue =
    parseDate(pickFirst(row, ["tracking_date", "submitted_at", "created_at", "updated_at"])) ??
    Number.NEGATIVE_INFINITY;
  if (sortValue >= current.latestSortMs) {
    current.latestSortMs = sortValue;
    current.latestTrackingRef = asString(
      pickFirst(row, [
        "tracking_ref",
        "tracking_number",
        "carrier_tracking_number",
        "tracking_code",
      ])
    ).trim();
    current.latestTrackingDate = pickFirst(row, [
      "tracking_date",
      "submitted_at",
      "created_at",
      "updated_at",
    ]);
  }

  map.set(key, current);
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

  const [{
    data: { user },
  }, results, evidenceQueriesResult] = await Promise.all([
    supabase.auth.getUser(),
    Promise.all(
      panels.map(async (panel) => ({
        ...panel,
        ...(await readPanel(supabase, panel.source)),
      }))
    ),
    supabase
      .from("order_evidence_queries")
      .select("order_id, status, query_type, created_at")
      .order("created_at", { ascending: false }),
  ]);

  const bySource = new Map(results.map((result) => [result.source, result]));

  const orderState = bySource.get("order_state_vw");
  const supplierInvoices = bySource.get("supplier_invoices");
  const supplierInvoiceLines = bySource.get("supplier_invoice_lines");
  const trackingSubmissions = bySource.get("order_tracking_submissions");
  const reconciliation = bySource.get("order_reconciliation_vw");

  const invoiceSummaryByOrderKey = new Map<
    string,
    {
      count: number;
      latestInvoiceRef: string;
      latestUploadedAt: unknown;
      latestOcrServiceUsed: string;
      latestOcrExtractedAt: unknown;
      latestReconciliationConfirmedAt: unknown;
      latestSortMs: number;
    }
  >();
  const invoiceToOrderKey = new Map<string, string>();
  for (const row of supplierInvoices?.rows ?? []) {
    const orderKey = resolveSupplierInvoiceOrderKey(row);
    if (!orderKey) continue;
    const current = invoiceSummaryByOrderKey.get(orderKey) ?? {
      count: 0,
      latestInvoiceRef: "",
      latestUploadedAt: null,
      latestOcrServiceUsed: "",
      latestOcrExtractedAt: null,
      latestReconciliationConfirmedAt: null,
      latestSortMs: Number.NEGATIVE_INFINITY,
    };
    current.count += 1;

    const sortValue =
      parseDate(
        pickFirst(row, ["uploaded_at", "submitted_at", "created_at", "updated_at"])
      ) ?? Number.NEGATIVE_INFINITY;
    if (sortValue >= current.latestSortMs) {
      current.latestSortMs = sortValue;
      current.latestInvoiceRef = asString(
        pickFirst(row, ["invoice_ref", "invoice_number", "invoice_id"])
      ).trim();
      current.latestUploadedAt = pickFirst(row, ["uploaded_at", "submitted_at", "created_at"]);
      current.latestOcrServiceUsed = asString(pickFirst(row, ["ocr_service_used"])).trim();
      current.latestOcrExtractedAt = pickFirst(row, ["ocr_extracted_at"]);
      current.latestReconciliationConfirmedAt = pickFirst(row, ["reconciliation_confirmed_at"]);
    }
    invoiceSummaryByOrderKey.set(orderKey, current);

    const invoiceId = resolveInvoiceId(row);
    if (invoiceId) invoiceToOrderKey.set(invoiceId, orderKey);
  }

  const lineSummaryByOrderKey = new Map<
    string,
    { lineCount: number; eligibleCount: number; ocrCount: number; manualCount: number }
  >();
  for (const row of supplierInvoiceLines?.rows ?? []) {
    const supplierInvoiceId = asString(pickFirst(row, ["supplier_invoice_id", "invoice_id"])).trim();
    const orderKey = supplierInvoiceId ? invoiceToOrderKey.get(supplierInvoiceId) ?? "" : "";
    if (!orderKey) continue;

    const current = lineSummaryByOrderKey.get(orderKey) ?? {
      lineCount: 0,
      eligibleCount: 0,
      ocrCount: 0,
      manualCount: 0,
    };
    current.lineCount += 1;
    const eligibleForInvoice = readBoolean(row, ["eligible_for_invoice_yn"]);
    if (eligibleForInvoice === true) current.eligibleCount += 1;

    const lineSource = asString(pickFirst(row, ["line_source", "source"])).trim().toLowerCase();
    if (lineSource.includes("ocr")) current.ocrCount += 1;
    if (lineSource.includes("manual")) current.manualCount += 1;

    lineSummaryByOrderKey.set(orderKey, current);
  }

  const trackingSummaryByOrderIdKey = new Map<
    string,
    { count: number; latestTrackingRef: string; latestTrackingDate: unknown; latestSortMs: number }
  >();
  const trackingSummaryByFallbackKey = new Map<
    string,
    { count: number; latestTrackingRef: string; latestTrackingDate: unknown; latestSortMs: number }
  >();
  for (const row of trackingSubmissions?.rows ?? []) {
    const trackingOrderIdKey = resolveTrackingSubmissionOrderIdKey(row);
    if (trackingOrderIdKey) {
      upsertTrackingSummary(trackingSummaryByOrderIdKey, trackingOrderIdKey, row);
      continue;
    }

    const fallbackOrderKey = resolveMatchingOrderKey(row);
    upsertTrackingSummary(trackingSummaryByFallbackKey, fallbackOrderKey, row);
  }

  const reconciliationByOrderId = new Map<string, DataRow>();
  for (const row of reconciliation?.rows ?? []) {
    const orderId = asString(pickFirst(row, ["order_id"])).trim();
    if (!orderId) continue;
    if (!reconciliationByOrderId.has(orderId)) reconciliationByOrderId.set(orderId, row);
  }

  const evidenceQuerySummaryByOrderId = new Map<string, EvidenceQuerySummary>();
  const evidenceQueriesError = evidenceQueriesResult.error?.message ?? null;
  const evidenceQueries = (evidenceQueriesResult.data ?? []) as EvidenceQueryRow[];

  for (const query of evidenceQueries) {
    const orderId = asString(query.order_id).trim();
    if (!orderId) continue;

    const current = evidenceQuerySummaryByOrderId.get(orderId) ?? {
      openCount: 0,
      latestOpenQueryType: "",
      latestAnsweredQueryType: "",
    };

    const normalizedStatus = asString(query.status).trim().toLowerCase();
    const normalizedQueryType = asString(query.query_type).trim();
    if (normalizedStatus === "open") {
      current.openCount += 1;
      if (!current.latestOpenQueryType) current.latestOpenQueryType = normalizedQueryType;
    } else if (normalizedStatus === "answered" && !current.latestAnsweredQueryType) {
      current.latestAnsweredQueryType = normalizedQueryType;
    }

    evidenceQuerySummaryByOrderId.set(orderId, current);
  }

  const hasLoggedInSession = Boolean(user);

  const queueRows = (orderState?.rows ?? []).map((row, index) => {
    const key = resolveOrderKey(row);
    const orderId = resolveOrderId(row);
    const orderKey = resolveMatchingOrderKey(row);
    const canonicalOrderKey = resolveCanonicalOrderStateKey(row);
    const recon = orderId ? reconciliationByOrderId.get(orderId) : undefined;
    const hasReconciliation = Boolean(recon);

    const progressedQty = asNumber(recon?.qty_progressed_invoiceable) ?? 0;
    const progressedAmount = asNumber(recon?.amount_progressed_invoiceable_gbp) ?? 0;
    const unresolvedQty = asNumber(recon?.qty_unresolved) ?? 0;
    const unresolvedAmount = asNumber(recon?.amount_unresolved_gbp) ?? 0;

    const unresolved = hasReconciliation
      ? unresolvedQty > 0 || unresolvedAmount > 0
      : null;

    const progressedSubset = hasReconciliation
      ? progressedQty > 0 || progressedAmount > 0
      : null;

    const partialProgress =
      hasReconciliation && progressedSubset !== null && unresolved !== null
        ? progressedSubset && unresolved
        : null;

    const invoiceableSubsetReleased =
      readBoolean(row, ["invoiceable_subset_released_yn"]) ??
      readBoolean(recon ?? {}, ["invoiceable_subset_released_yn"]) ??
      null;

    const invoiceSummary = canonicalOrderKey
      ? invoiceSummaryByOrderKey.get(canonicalOrderKey)
      : undefined;
    const lineSummary = canonicalOrderKey ? lineSummaryByOrderKey.get(canonicalOrderKey) : undefined;
    const trackingSummary =
      (canonicalOrderKey ? trackingSummaryByOrderIdKey.get(canonicalOrderKey) : undefined) ??
      (orderKey ? trackingSummaryByFallbackKey.get(orderKey) : undefined);
    const evidenceQuerySummary = orderId
      ? evidenceQuerySummaryByOrderId.get(orderId)
      : undefined;
    const latestEvidenceQueryLabel =
      (evidenceQuerySummary?.openCount ?? 0) > 0
        ? evidenceQuerySummary?.latestOpenQueryType || "open"
        : evidenceQuerySummary?.latestAnsweredQueryType
          ? `answered: ${evidenceQuerySummary.latestAnsweredQueryType}`
          : "—";

    return {
      key: key || `fallback-${index}`,
      orderId,
      orderRef: chooseStatus(row, ["order_ref", "parent_order_ref", "supplier_order_ref"]),
      paymentAuthId: chooseStatus(row, ["payment_auth_id", "auth_id_ref"]),
      orderStatus: chooseStatus(row, ["status", "order_status"]),
      lifecycleStatus: chooseStatus(row, ["lifecycle_status"]),
      fundingOverlay: chooseStatus(row, ["funding_overlay"]),
      shipmentReadinessOverlay: chooseStatus(row, ["shipment_readiness_overlay"]),
      operationalBucket: chooseStatus(row, ["operational_bucket"]),
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
      progressedQty,
      progressedAmount,
      unresolvedQty,
      unresolvedAmount,
      invoiceableSubsetReleased,
      invoiceRows: invoiceSummary?.count ?? 0,
      latestInvoiceRef: invoiceSummary?.latestInvoiceRef || "Unknown",
      latestInvoiceUploadedAt: formatValue(invoiceSummary?.latestUploadedAt),
      latestInvoiceOcrService: invoiceSummary?.latestOcrServiceUsed || "Unknown",
      latestInvoiceOcrExtractedAt: formatValue(invoiceSummary?.latestOcrExtractedAt),
      latestInvoiceReconciliationConfirmedAt: formatValue(
        invoiceSummary?.latestReconciliationConfirmedAt
      ),
      trackingRows: trackingSummary?.count ?? 0,
      latestTrackingRef: trackingSummary?.latestTrackingRef || "Unknown",
      latestTrackingDate: formatValue(trackingSummary?.latestTrackingDate),
      lineRows: lineSummary?.lineCount ?? 0,
      eligibleLineRows: lineSummary?.eligibleCount ?? 0,
      ocrLineRows: lineSummary?.ocrCount ?? 0,
      manualLineRows: lineSummary?.manualCount ?? 0,
      openEvidenceQueries: evidenceQuerySummary?.openCount ?? 0,
      latestEvidenceQueryLabel,
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
            Queue rows are anchored from{" "}
            <code className="mx-1 rounded bg-slate-100 px-1 py-0.5">order_state_vw</code> and
            augmented with status and count indicators when matching keys are available.
          </p>
          {!hasLoggedInSession ? (
            <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">
              Evidence query indicators are shown for authenticated staff sessions only.
            </p>
          ) : null}
          {evidenceQueriesError ? (
            <p className="mt-3 rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">
              Could not load <code>order_evidence_queries</code>: {evidenceQueriesError}
            </p>
          ) : null}

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
                    <th className="px-4 py-3 font-semibold">Lifecycle status</th>
                    <th className="px-4 py-3 font-semibold">Invoice count</th>
                    <th className="px-4 py-3 font-semibold">Tracking count</th>
                    <th className="px-4 py-3 font-semibold">Open queries</th>
                    <th className="px-4 py-3 font-semibold">Invoice lines count</th>
                    <th className="px-4 py-3 font-semibold">Progressed amount</th>
                    <th className="px-4 py-3 font-semibold">Unresolved amount</th>
                    <th className="px-4 py-3 font-semibold">Invoiceable subset released</th>
                    <th className="px-4 py-3 font-semibold">Operational bucket</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100 bg-white">
                  {queueRows.map((row) => (
                    <tr key={row.key} className="align-top">
                      <td className="px-4 py-3 font-medium text-slate-900">
                        {row.orderId ? (
                          <Link href={`/internal/evidence/${row.orderId}`} className="text-sky-700 hover:text-sky-800 hover:underline">
                            {row.orderRef}
                          </Link>
                        ) : (
                          <div>{row.orderRef}</div>
                        )}
                        <details className="mt-2 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-700">
                          <summary className="cursor-pointer font-semibold text-slate-900">
                            Show details
                          </summary>
                          <div className="mt-2 grid gap-1">
                            <div>Latest invoice ref: {row.latestInvoiceRef}</div>
                            <div>OCR service: {row.latestInvoiceOcrService}</div>
                            <div>Latest tracking ref: {row.latestTrackingRef}</div>
                            <div>Latest tracking date: {row.latestTrackingDate}</div>
                            <div>Latest query: {row.latestEvidenceQueryLabel}</div>
                            <div>Eligible invoice lines: {row.eligibleLineRows}</div>
                            <div>OCR lines: {row.ocrLineRows}</div>
                            <div>Manual lines: {row.manualLineRows}</div>
                          </div>
                        </details>
                      </td>
                      <td className="px-4 py-3 text-slate-700">{row.lifecycleStatus}</td>
                      <td className="px-4 py-3 text-slate-700">{row.invoiceRows.toLocaleString("en-GB")}</td>
                      <td className="px-4 py-3 text-slate-700">{row.trackingRows.toLocaleString("en-GB")}</td>
                      <td className="px-4 py-3 text-slate-700">
                        <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-1 text-xs font-semibold text-slate-800">
                          {row.openEvidenceQueries > 0 ? `${row.openEvidenceQueries.toLocaleString("en-GB")} open` : "0"}
                        </span>
                        <div className="mt-1 text-xs text-slate-500">{row.latestEvidenceQueryLabel}</div>
                      </td>
                      <td className="px-4 py-3 text-slate-700">{row.lineRows.toLocaleString("en-GB")}</td>
                      <td className="px-4 py-3 text-slate-700">{formatProgressAmount(row.progressedAmount)}</td>
                      <td className="px-4 py-3 text-slate-700">{formatProgressAmount(row.unresolvedAmount)}</td>
                      <td className="px-4 py-3 text-slate-700">
                        {toBooleanLabel(row.invoiceableSubsetReleased)}
                      </td>
                      <td className="px-4 py-3 text-slate-700">{row.operationalBucket}</td>
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
