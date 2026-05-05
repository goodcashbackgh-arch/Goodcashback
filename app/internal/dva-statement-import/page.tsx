import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { createRealStatementImportBatchAction, voidDvaStatementImportBatchAction } from "./actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const BATCH_PAGE_SIZE = 8;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function positivePage(value: unknown) {
  const parsed = Number(text(value) || "1");
  return Number.isInteger(parsed) && parsed > 0 ? parsed : 1;
}

function pageHref(baseParams: SearchParamsValue, key: string, value: number) {
  const params = new URLSearchParams();
  for (const [paramKey, paramValue] of Object.entries(baseParams)) {
    if (paramKey === key) continue;
    const firstValue = Array.isArray(paramValue) ? paramValue[0] : paramValue;
    if (firstValue) params.set(paramKey, firstValue);
  }
  params.set(key, String(value));
  return `/internal/dva-statement-import?${params.toString()}`;
}

function statusClass(status: string) {
  if (status === "committed") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (status === "clean" || status === "parsed_clean" || status === "ocr_or_parsing") return "bg-sky-50 text-sky-700 ring-sky-200";
  if (status === "duplicate_skipped") return "bg-slate-100 text-slate-700 ring-slate-200";
  if (status === "parsed_with_errors") return "bg-amber-50 text-amber-700 ring-amber-200";
  if (status === "voided" || status === "failed" || status === "error") return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function nextAction(batch: Row) {
  const fileType = text(batch.detected_file_type);
  const rowCount = num(batch.row_count);
  const status = text(batch.status);
  if (status === "committed") return "Committed — available for matching. Void only if this import was uploaded in error.";
  if (status === "failed") return "Failed — open detail or upload a corrected batch.";
  if (status === "voided") return "Voided — kept for audit trail only.";
  if (fileType === "pdf" && rowCount === 0) return "Run PDF OCR / parse rows, then review detail.";
  if (rowCount > 0) return "Open detail to review balance chain and staged rows.";
  return "Extract rows, then review detail.";
}

function PaginationControls({
  baseParams,
  pageKey,
  currentPage,
  totalCount,
  pageSize,
}: {
  baseParams: SearchParamsValue;
  pageKey: string;
  currentPage: number;
  totalCount: number;
  pageSize: number;
}) {
  const totalPages = Math.max(1, Math.ceil(totalCount / pageSize));
  const from = totalCount === 0 ? 0 : (currentPage - 1) * pageSize + 1;
  const to = Math.min(currentPage * pageSize, totalCount);

  return (
    <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
      <p>
        Showing <span className="font-semibold text-slate-950">{from}</span>–<span className="font-semibold text-slate-950">{to}</span> of <span className="font-semibold text-slate-950">{totalCount}</span>
      </p>
      <div className="flex items-center gap-2">
        {currentPage > 1 ? (
          <Link className="rounded-xl bg-white px-3 py-2 font-semibold text-sky-700 ring-1 ring-slate-200" href={pageHref(baseParams, pageKey, currentPage - 1)}>Previous</Link>
        ) : (
          <span className="rounded-xl bg-slate-100 px-3 py-2 font-semibold text-slate-400 ring-1 ring-slate-200">Previous</span>
        )}
        <span className="px-2 font-semibold text-slate-700">Page {currentPage} / {totalPages}</span>
        {currentPage < totalPages ? (
          <Link className="rounded-xl bg-white px-3 py-2 font-semibold text-sky-700 ring-1 ring-slate-200" href={pageHref(baseParams, pageKey, currentPage + 1)}>Next</Link>
        ) : (
          <span className="rounded-xl bg-slate-100 px-3 py-2 font-semibold text-slate-400 ring-1 ring-slate-200">Next</span>
        )}
      </div>
    </div>
  );
}

export default async function DvaStatementImportPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importSuccess = text(params.import_success);
  const importError = text(params.import_error);
  const batchId = text(params.batch_id);
  const batchPage = positivePage(params.batch_page);
  const batchFrom = (batchPage - 1) * BATCH_PAGE_SIZE;
  const supabase = await createClient();

  const [batchesResult, importersResult] = await Promise.all([
    supabase
      .from("dva_statement_import_batches")
      .select("id, importer_id, source_bank, statement_period_from, statement_period_to, local_ccy, source_file_url, original_filename, detected_file_type, parser_route, status, row_count, clean_count, error_count, duplicate_count, committed_count, uploaded_at, parsed_at, committed_at, voided_at, void_reason, notes", { count: "exact" })
      .order("uploaded_at", { ascending: false })
      .range(batchFrom, batchFrom + BATCH_PAGE_SIZE - 1),
    supabase
      .from("importers")
      .select("id, company_name, trading_name")
      .order("company_name", { ascending: true })
      .limit(200),
  ]);

  const batches = (batchesResult.data ?? []) as unknown as Row[];
  const importers = (importersResult.data ?? []) as unknown as Row[];
  const today = new Date().toISOString().slice(0, 10);
  const batchCount = batchesResult.count ?? batches.length;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <div className="mt-6 flex flex-wrap items-start justify-between gap-4">
            <div className="min-w-0 flex-1">
              <p className="text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card statement import</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight">Statement upload queue</h1>
              <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
                Upload statement files here. Each batch card opens a detail page for balance checks, staged rows, and reconciliation review.
              </p>
            </div>
            <Link className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" href="/internal/dva-statement-import/mindee-control">
              Open PDF Mindee control
            </Link>
          </div>
          <div className="mt-4 flex flex-wrap gap-2">
            <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-700 ring-1 ring-sky-200">Upload queue</span>
            <span className="rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200">Click card for detail</span>
            <span className="rounded-full bg-amber-50 px-3 py-1 text-sm font-semibold text-amber-700 ring-1 ring-amber-200">Staging before commit</span>
          </div>
        </section>

        {importSuccess ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm font-semibold text-emerald-800">
            {importSuccess}{batchId ? <span className="block pt-1 text-xs font-medium">Batch: {batchId}</span> : null}
          </section>
        ) : null}
        {importError ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">{importError}</section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Upload statement file</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Upload creates the batch. PDF OCR and row review happen after the batch exists.
          </p>
          <form action={createRealStatementImportBatchAction} className="mt-5 grid gap-4 md:grid-cols-4">
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Importer</label>
              <select className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="importer_id" required>
                <option value="">Select importer</option>
                {importers.map((importer) => (
                  <option key={text(importer.id)} value={text(importer.id)}>{text(importer.trading_name) || text(importer.company_name) || text(importer.id)}</option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Source bank/provider</label>
              <select className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="source_bank" defaultValue="other">
                <option value="other">Other</option>
                <option value="gcb">GCB</option>
                <option value="firstbank">FirstBank</option>
                <option value="zenith">Zenith</option>
              </select>
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Period from</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="statement_period_from" type="date" defaultValue={today} required />
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Period to</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="statement_period_to" type="date" defaultValue={today} required />
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Local currency</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm uppercase" name="local_ccy" defaultValue="GHS" maxLength={3} required />
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Default card markup %</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="default_card_markup_pct" type="number" min="0" step="0.001" defaultValue="0" />
            </div>
            <div className="md:col-span-2">
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Statement file</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="statement_file" type="file" accept=".pdf,.csv,.xlsx,.xls,.txt,text/plain,application/pdf,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" required />
            </div>
            <div className="md:col-span-2">
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">FX source context</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="fx_source_context" placeholder="e.g. Bank of Ghana daily settlement rate" />
            </div>
            <div className="md:col-span-2">
              <label className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Notes</label>
              <input className="mt-1 w-full rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" name="notes" placeholder="Optional internal upload note" />
            </div>
            <div className="md:col-span-4">
              <button className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" type="submit">Upload statement and create batch</button>
            </div>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Statement batches</h2>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Open a batch to see extracted header data, balance chain, staged rows, and reconciliation controls.
          </p>
          <div className="mt-4 grid gap-3">
            {batches.length === 0 ? (
              <p className="text-sm text-slate-500">No import batches yet.</p>
            ) : batches.map((batch) => {
              const id = text(batch.id);
              const status = text(batch.status) || "unknown";
              const detailHref = `/internal/dva-statement-import/${id}`;
              const mindeeHref = `/internal/dva-statement-import/mindee-control?batch_id=${id}`;
              const canVoid = status === "committed";

              return (
                <article key={id} className="rounded-2xl border border-slate-200 p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <h3 className="break-words font-semibold [overflow-wrap:anywhere]">{text(batch.original_filename) || id}</h3>
                      <p className="mt-1 break-words text-sm text-slate-600 [overflow-wrap:anywhere]">
                        {text(batch.statement_period_from)} → {text(batch.statement_period_to)} · {text(batch.source_bank)} · {text(batch.local_ccy)} · {text(batch.detected_file_type)} · {text(batch.parser_route)}
                      </p>
                    </div>
                    <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${statusClass(status)}`}>{status}</span>
                  </div>

                  <div className="mt-4 grid gap-3 text-sm text-slate-700 sm:grid-cols-5">
                    <p>Rows: <span className="font-semibold text-slate-950">{num(batch.row_count)}</span></p>
                    <p>Clean: <span className="font-semibold text-slate-950">{num(batch.clean_count)}</span></p>
                    <p>Errors: <span className="font-semibold text-slate-950">{num(batch.error_count)}</span></p>
                    <p>Duplicates: <span className="font-semibold text-slate-950">{num(batch.duplicate_count)}</span></p>
                    <p>Committed: <span className="font-semibold text-slate-950">{num(batch.committed_count)}</span></p>
                  </div>

                  {text(batch.void_reason) ? (
                    <p className="mt-3 rounded-2xl bg-rose-50 p-3 text-sm font-semibold text-rose-800 ring-1 ring-rose-200">Void reason: {text(batch.void_reason)}</p>
                  ) : null}

                  <div className="mt-4 flex flex-wrap items-center gap-3">
                    <Link className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" href={detailHref}>Open detail / reconcile</Link>
                    <Link className="rounded-xl bg-white px-4 py-2 text-sm font-semibold text-sky-700 ring-1 ring-sky-200" href={mindeeHref}>PDF OCR control</Link>
                    <p className="text-sm text-slate-600">{nextAction(batch)}</p>
                  </div>

                  {canVoid ? (
                    <form action={voidDvaStatementImportBatchAction} className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3">
                      <input type="hidden" name="import_batch_id" value={id} />
                      <label className="block text-xs font-semibold uppercase tracking-wide text-rose-700">Void import reason</label>
                      <div className="mt-2 flex flex-col gap-2 sm:flex-row">
                        <input
                          className="min-w-0 flex-1 rounded-xl border border-rose-200 bg-white px-3 py-2 text-sm text-slate-950"
                          name="void_reason"
                          placeholder="Required. Example: uploaded wrong bank statement."
                          minLength={8}
                          required
                        />
                        <button className="rounded-xl bg-rose-600 px-4 py-2 text-sm font-semibold text-white hover:bg-rose-700" type="submit">
                          Void import
                        </button>
                      </div>
                      <p className="mt-2 text-xs font-medium text-rose-700">
                        This removes unallocated lines from active matching. If any line has confirmed/held allocations, the database will block it until those allocations are reversed first.
                      </p>
                    </form>
                  ) : null}

                  <p className="mt-3 break-words text-xs text-slate-500 [overflow-wrap:anywhere]">Batch ID: {id}</p>
                </article>
              );
            })}
          </div>

          <PaginationControls baseParams={params} pageKey="batch_page" currentPage={batchPage} totalCount={batchCount} pageSize={BATCH_PAGE_SIZE} />
        </section>
      </div>
    </main>
  );
}
