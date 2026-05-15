import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { commitDvaStatementImportBatchAction, resetDvaStatementImportBatchAction } from "../actions";
import StatementBalanceCheckCard from "../StatementBalanceCheckCard";

type Row = Record<string, unknown>;

type PageParams = {
  batch_id?: string;
};

type SearchParamsValue = Record<string, string | string[] | undefined>;

const ROW_PAGE_SIZE = 10;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

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

function pageHref(batchId: string, currentParams: SearchParamsValue, nextPage: number) {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(currentParams)) {
    if (key === "row_page") continue;
    const firstValue = Array.isArray(value) ? value[0] : value;
    if (firstValue) params.set(key, firstValue);
  }
  params.set("row_page", String(nextPage));
  return `/internal/dva-statement-import/${batchId}?${params.toString()}#staged-statement-rows`;
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function statusClass(status: string) {
  if (status === "committed") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (status === "clean" || status === "parsed_clean") return "bg-sky-50 text-sky-700 ring-sky-200";
  if (status === "duplicate_skipped") return "bg-slate-100 text-slate-700 ring-slate-200";
  if (status === "parsed_with_errors") return "bg-amber-50 text-amber-700 ring-amber-200";
  if (status === "voided" || status === "failed" || status === "error") return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function displayRowDate(row: Row) {
  return text(row.transaction_date) || text(row.statement_date) || "—";
}

function getObject(value: unknown) {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function getByPath(root: unknown, path: string[]) {
  let current = root;
  for (const key of path) {
    const obj = getObject(current);
    if (!obj) return null;
    current = obj[key];
  }
  return current ?? null;
}

function correctionText(row: Row) {
  const note = text(getByPath(row.raw_json, ["_goodcashback_balance_check", "correction_note"]));
  return note;
}

function PaginationControls({
  batchId,
  currentParams,
  currentPage,
  totalCount,
}: {
  batchId: string;
  currentParams: SearchParamsValue;
  currentPage: number;
  totalCount: number;
}) {
  const totalPages = Math.max(1, Math.ceil(totalCount / ROW_PAGE_SIZE));
  const from = totalCount === 0 ? 0 : (currentPage - 1) * ROW_PAGE_SIZE + 1;
  const to = Math.min(currentPage * ROW_PAGE_SIZE, totalCount);

  return (
    <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
      <p>
        Showing <span className="font-semibold text-slate-950">{from}</span>–<span className="font-semibold text-slate-950">{to}</span> of <span className="font-semibold text-slate-950">{totalCount}</span>
      </p>
      <div className="flex items-center gap-2">
        {currentPage > 1 ? (
          <Link className="rounded-xl bg-white px-3 py-2 font-semibold text-sky-700 ring-1 ring-slate-200" href={pageHref(batchId, currentParams, currentPage - 1)}>Previous</Link>
        ) : (
          <span className="rounded-xl bg-slate-100 px-3 py-2 font-semibold text-slate-400 ring-1 ring-slate-200">Previous</span>
        )}
        <span className="px-2 font-semibold text-slate-700">Page {currentPage} / {totalPages}</span>
        {currentPage < totalPages ? (
          <Link className="rounded-xl bg-white px-3 py-2 font-semibold text-sky-700 ring-1 ring-slate-200" href={pageHref(batchId, currentParams, currentPage + 1)}>Next</Link>
        ) : (
          <span className="rounded-xl bg-slate-100 px-3 py-2 font-semibold text-slate-400 ring-1 ring-slate-200">Next</span>
        )}
      </div>
    </div>
  );
}

export default async function DvaStatementImportDetailPage({
  params,
  searchParams,
}: {
  params: PageParams | Promise<PageParams>;
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const resolvedParams = await Promise.resolve(params);
  const currentSearchParams = searchParams ? await Promise.resolve(searchParams) : {};
  const batchId = text(resolvedParams.batch_id);
  if (!batchId) notFound();

  const rowPage = positivePage(currentSearchParams.row_page);
  const rowFrom = (rowPage - 1) * ROW_PAGE_SIZE;
  const commitSuccess = text(currentSearchParams.commit_success);
  const commitError = text(currentSearchParams.commit_error);
  const resetSuccess = text(currentSearchParams.reset_success);
  const resetError = text(currentSearchParams.reset_error);

  const supabase = await createClient();
  const [batchResult, rowsResult] = await Promise.all([
    supabase
      .from("dva_statement_import_batches")
      .select("id, importer_id, source_bank, statement_period_from, statement_period_to, local_ccy, original_filename, detected_file_type, parser_route, status, row_count, clean_count, error_count, duplicate_count, committed_count, uploaded_at, parsed_at, committed_at, notes")
      .eq("id", batchId)
      .maybeSingle(),
    supabase
      .from("dva_statement_import_rows")
      .select("id, source_row_number, source_page_number, statement_date, transaction_date, direction, transaction_type_candidate, amount_local_ccy, balance_after_local_ccy, local_ccy, fx_rate_applied, amount_gbp_equivalent, card_last4, merchant_raw, merchant_normalised, bank_reference, auth_or_settlement_ref, parser_confidence, parse_status, error_code, error_message, raw_json, committed_dva_statement_line_id, created_at", { count: "exact" })
      .eq("import_batch_id", batchId)
      .order("source_row_number", { ascending: true })
      .range(rowFrom, rowFrom + ROW_PAGE_SIZE - 1),
  ]);

  const batch = batchResult.data as Row | null;
  if (!batch) notFound();
  const rows = (rowsResult.data ?? []) as unknown as Row[];
  const rowCount = rowsResult.count ?? rows.length;
  const batchStatus = text(batch.status);
  const committedCount = num(batch.committed_count);
  const cleanCount = num(batch.clean_count);
  const errorCount = num(batch.error_count);
  const canCommit = cleanCount > 0 && committedCount === 0 && errorCount === 0 && !["committed", "voided", "failed"].includes(batchStatus);
  const canReset = rowCount > 0 && committedCount === 0 && !["committed", "voided", "failed"].includes(batchStatus);
  const canOpenMatchingWorkbench = batchStatus === "committed" || committedCount > 0 || Boolean(commitSuccess);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div className="min-w-0 flex-1">
              <Link href="/internal/dva-statement-import" className="text-sm font-semibold text-sky-600">← Back to statement import</Link>
              <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Statement detail / reconciliation</p>
              <h1 className="mt-2 max-w-full break-words text-2xl font-semibold tracking-tight [overflow-wrap:anywhere] sm:text-3xl">{text(batch.original_filename) || batchId}</h1>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Review extracted header, balance chain, staged rows, corrections, and references before committing this statement batch.
              </p>
            </div>
            <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${statusClass(batchStatus)}`}>{batchStatus}</span>
          </div>

          <div className="mt-5 grid gap-3 text-sm text-slate-700 sm:grid-cols-2 lg:grid-cols-5">
            <p><span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Period entered</span><span className="font-semibold">{text(batch.statement_period_from)} → {text(batch.statement_period_to)}</span></p>
            <p><span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Source</span><span className="font-semibold">{text(batch.source_bank)} · {text(batch.local_ccy)}</span></p>
            <p><span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Rows</span><span className="font-semibold">{num(batch.row_count)} rows · {cleanCount} clean</span></p>
            <p><span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Errors / duplicates</span><span className="font-semibold">{errorCount} errors · {num(batch.duplicate_count)} duplicates</span></p>
            <p><span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">Committed</span><span className="font-semibold">{committedCount}</span></p>
          </div>

          <p className="mt-4 break-all text-xs text-slate-500">Batch ID: {batchId}</p>
        </section>

        {(commitSuccess || commitError || resetSuccess || resetError) ? (
          <section className={`rounded-3xl border p-5 text-sm font-semibold leading-6 ${(commitSuccess || resetSuccess) ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-rose-200 bg-rose-50 text-rose-900"}`}>
            {commitSuccess || commitError || resetSuccess || resetError}
          </section>
        ) : null}

        <StatementBalanceCheckCard importBatchId={batchId} />

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.18em] text-sky-500">Next control step</p>
              <h2 className="mt-2 text-xl font-semibold">Commit clean rows</h2>
              <p className="mt-2 max-w-4xl text-sm leading-6 text-slate-600">
                Commit turns reviewed staged rows into live DVA/card statement lines. Only committed lines should move into funding, invoice, refund, fee, or exception matching.
              </p>
            </div>
            {canOpenMatchingWorkbench ? (
              <Link className="rounded-2xl bg-slate-950 px-4 py-3 text-sm font-semibold text-white" href="/internal/dva-reconciliation">
                Open DVA/card control hub →
              </Link>
            ) : null}
          </div>

          <div className="mt-5 grid gap-4 lg:grid-cols-2">
            {canCommit ? (
              <form action={commitDvaStatementImportBatchAction} className="rounded-2xl border border-sky-200 bg-sky-50 p-4">
                <input type="hidden" name="import_batch_id" value={batchId} />
                <label className="block text-sm font-semibold text-sky-950">Commit note</label>
                <input className="mt-2 w-full rounded-xl border border-sky-200 bg-white px-3 py-2 text-sm" name="notes" defaultValue="Reviewed balance chain and staged rows; commit clean statement lines." />
                <button className="mt-3 rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" type="submit">
                  Commit clean rows
                </button>
              </form>
            ) : (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm leading-6 text-slate-600">
                {canOpenMatchingWorkbench
                  ? "This batch already has committed statement lines. Continue in the DVA/card control hub."
                  : "Commit is disabled until the batch has clean rows, no parse errors, and no previous commit."}
              </div>
            )}

            {canReset ? (
              <form action={resetDvaStatementImportBatchAction} className="rounded-2xl border border-amber-200 bg-amber-50 p-4">
                <input type="hidden" name="import_batch_id" value={batchId} />
                <label className="block text-sm font-semibold text-amber-950">Reset staged rows before commit</label>
                <input className="mt-2 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" name="reset_reason" defaultValue="Fix FX rates and re-parse before commit." />
                <p className="mt-2 text-xs leading-5 text-amber-900">Pre-commit only. Keeps the uploaded PDF and Mindee OCR result, but deletes staged rows so this batch can be parsed again.</p>
                <button className="mt-3 rounded-xl bg-amber-600 px-4 py-2 text-sm font-semibold text-white" type="submit">
                  Reset staged rows
                </button>
              </form>
            ) : null}
          </div>
        </section>

        <section id="staged-statement-rows" className="scroll-mt-6 rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">Staged statement rows</h2>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                Full transaction review before commit. Pagination keeps large statements usable.
              </p>
            </div>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-sm font-semibold text-slate-700 ring-1 ring-slate-200">{rowCount} row(s)</span>
          </div>

          <div className="mt-5 grid gap-3">
            {rows.length === 0 ? (
              <p className="text-sm text-slate-500">No staged rows for this batch yet.</p>
            ) : rows.map((row) => {
              const correction = correctionText(row);
              return (
                <article key={text(row.id)} className="rounded-2xl border border-slate-200 p-4">
                  <div className="flex flex-wrap items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <h3 className="break-words font-semibold [overflow-wrap:anywhere]">Row {text(row.source_row_number)} · {text(row.merchant_raw) || "Unidentified transaction"}</h3>
                      <p className="mt-1 text-sm text-slate-600">{displayRowDate(row)} · {text(row.direction)} · {text(row.transaction_type_candidate)}</p>
                    </div>
                    <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${statusClass(text(row.parse_status))}`}>{text(row.parse_status)}</span>
                  </div>
                  <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-5">
                    <p>Local: <span className="font-semibold">{num(row.amount_local_ccy).toLocaleString("en-GB")} {text(row.local_ccy)}</span></p>
                    <p>Balance after: <span className="font-semibold">{num(row.balance_after_local_ccy).toLocaleString("en-GB")} {text(row.local_ccy)}</span></p>
                    <p>GBP: <span className="font-semibold">{gbp(row.amount_gbp_equivalent)}</span></p>
                    <p>Card: <span className="font-semibold">{text(row.card_last4) || "—"}</span></p>
                    <p>Ref: <span className="break-words font-semibold [overflow-wrap:anywhere]">{text(row.bank_reference) || text(row.auth_or_settlement_ref) || "—"}</span></p>
                  </div>
                  {correction ? <p className="mt-3 rounded-xl bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800 ring-1 ring-amber-200">{correction}</p> : null}
                  {text(row.statement_date) && text(row.transaction_date) && text(row.statement_date) !== text(row.transaction_date) ? (
                    <p className="mt-2 text-xs text-slate-500">Statement date: {text(row.statement_date)}</p>
                  ) : null}
                  {text(row.error_message) ? <p className="mt-3 text-sm text-rose-700">{text(row.error_code)}: {text(row.error_message)}</p> : null}
                </article>
              );
            })}
          </div>

          <PaginationControls batchId={batchId} currentParams={currentSearchParams} currentPage={rowPage} totalCount={rowCount} />
        </section>
      </div>
    </main>
  );
}
