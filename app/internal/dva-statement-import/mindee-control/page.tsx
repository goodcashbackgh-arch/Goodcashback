import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return typeof value === "string" ? value : "";
}

function statusClass(status: string) {
  if (status === "completed") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (["queued", "processing", "enqueueing"].includes(status)) return "bg-sky-50 text-sky-700 ring-sky-200";
  if (["failed", "cancelled"].includes(status)) return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function batchStatusClass(status: string) {
  if (status === "voided" || status === "failed" || status === "error") return "bg-rose-50 text-rose-700 ring-rose-200";
  if (status === "committed") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function displayStatus(status: string) {
  if (status === "not_started") return "not started";
  return cleanUiText(status.replaceAll("_", " "));
}

function isHttpUrl(value: string) {
  return /^https?:\/\//i.test(value);
}

function isVoidedBatch(batch: Row) {
  return text(batch.status) === "voided" || Boolean(text(batch.voided_at) || text(batch.void_reason));
}

function isLockedBatch(batch: Row) {
  return isVoidedBatch(batch) || ["committed", "failed"].includes(text(batch.status));
}

function canStartMindee(batch: Row, jobId: string, ocrStatus: string) {
  const sourceUrl = text(batch.source_file_url);
  if (isLockedBatch(batch)) return false;
  if (jobId) return false;
  if (["queued", "processing", "completed"].includes(ocrStatus)) return false;
  if (!isHttpUrl(sourceUrl)) return false;
  return true;
}

function blockedReason(batch: Row, jobId: string, ocrStatus: string) {
  const status = text(batch.status);
  const sourceUrl = text(batch.source_file_url);
  if (isVoidedBatch(batch)) return "Batch is voided; document extraction/fetch/parse controls are disabled for audit-only imports.";
  if (jobId) return "Document extraction already has a processing job.";
  if (["queued", "processing", "completed"].includes(ocrStatus)) return `Document extraction status is ${displayStatus(ocrStatus)}.`;
  if (["committed", "failed"].includes(status)) return `Batch status is ${displayStatus(status)}; upload a fresh real PDF batch for document extraction.`;
  if (!isHttpUrl(sourceUrl)) return "No real uploaded file URL; likely a smoke/test batch.";
  return "Not ready for document extraction.";
}

export default async function DvaStatementMindeeControlPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importSuccess = cleanUiText(text(params.import_success));
  const importError = cleanUiText(text(params.import_error));
  const batchId = text(params.batch_id);
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("dva_statement_import_batches")
    .select("id, original_filename, source_file_url, source_bank, statement_period_from, statement_period_to, local_ccy, detected_file_type, parser_route, status, row_count, clean_count, error_count, duplicate_count, mindee_statement_job_id, mindee_statement_model_id, mindee_statement_ocr_status, mindee_statement_enqueued_at, mindee_statement_completed_at, mindee_statement_pages_consumed, mindee_statement_error_message, uploaded_at, voided_at, void_reason")
    .eq("detected_file_type", "pdf")
    .neq("status", "voided")
    .is("voided_at", null)
    .is("void_reason", null)
    .order("uploaded_at", { ascending: false })
    .limit(20);

  const batches = (data ?? []) as unknown as Row[];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-statement-import" className="text-sm font-semibold text-sky-600">← Back to statement import</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Payment statement extraction</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">PDF statement extraction control</h1>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">
            Starts, fetches, and stages document extraction for active real PDF statement batches. Voided and audit-only batches are hidden from this worklist.
          </p>
          {batchId ? <p className="mt-3 break-all text-xs text-slate-500">Latest batch: {batchId}</p> : null}
        </section>

        {importSuccess ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm font-semibold text-emerald-800">{importSuccess}</section>
        ) : null}
        {importError ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm font-semibold text-rose-900">{importError}</section>
        ) : null}
        {error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">Could not read PDF batches: {cleanUiText(error.message)}</section>
        ) : null}

        <section className="grid gap-4">
          {batches.length === 0 ? (
            <article className="rounded-3xl border border-slate-200 bg-white p-6 text-sm text-slate-600 shadow-sm">
              No active PDF statement batches need document extraction. Voided batches are available from the statement import page under “Voided / audit”.
            </article>
          ) : batches.map((batch) => {
            const ocrStatus = text(batch.mindee_statement_ocr_status) || "not_started";
            const jobId = text(batch.mindee_statement_job_id);
            const voided = isVoidedBatch(batch);
            const canStart = canStartMindee(batch, jobId, ocrStatus);
            const rowCount = Number(batch.row_count ?? 0);
            const canFetch = Boolean(jobId) && !voided;
            const canParse = ocrStatus === "completed" && rowCount === 0 && !voided;
            const localCcy = (text(batch.local_ccy) || "GBP").toUpperCase();
            return (
              <article key={text(batch.id)} className={`max-w-full overflow-hidden rounded-3xl border bg-white p-5 shadow-sm ${voided ? "border-rose-200 opacity-80" : "border-slate-200"}`}>
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0 flex-1">
                    <h2 className="break-words text-lg font-semibold [overflow-wrap:anywhere]">{text(batch.original_filename) || text(batch.id)}</h2>
                    <p className="mt-1 break-words text-sm text-slate-600">{text(batch.statement_period_from)} → {text(batch.statement_period_to)} · {text(batch.source_bank)} · {localCcy}</p>
                  </div>
                  <div className="flex shrink-0 flex-wrap gap-2">
                    <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${batchStatusClass(text(batch.status))}`}>{displayStatus(text(batch.status) || "unknown")}</span>
                    <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${statusClass(ocrStatus)}`}>{displayStatus(ocrStatus)}</span>
                  </div>
                </div>

                <div className="mt-4 grid gap-2 text-sm text-slate-700 sm:grid-cols-3">
                  <p>Rows: <span className="font-semibold">{rowCount}</span></p>
                  <p>Clean: <span className="font-semibold">{Number(batch.clean_count ?? 0)}</span></p>
                  <p>Errors: <span className="font-semibold">{Number(batch.error_count ?? 0)}</span></p>
                  <p>Duplicates: <span className="font-semibold">{Number(batch.duplicate_count ?? 0)}</span></p>
                  <p>Pages: <span className="font-semibold">{text(batch.mindee_statement_pages_consumed) || "—"}</span></p>
                  <p className="break-all">Processing ref: <span className="font-semibold">{jobId || "—"}</span></p>
                </div>

                {voided ? (
                  <p className="mt-3 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800">
                    Voided audit-only batch. Document extraction, fetch, and parse controls are disabled. Reason: {cleanUiText(text(batch.void_reason)) || "—"}
                  </p>
                ) : null}
                {text(batch.mindee_statement_error_message) ? <p className="mt-3 text-sm text-rose-700">{cleanUiText(text(batch.mindee_statement_error_message))}</p> : null}

                <div className="mt-5 grid max-w-full gap-3 sm:flex sm:flex-wrap">
                  {canStart ? (
                    <form action="/internal/dva-statement-import/mindee-start" method="post" className="w-full sm:w-auto">
                      <input type="hidden" name="import_batch_id" value={text(batch.id)} />
                      <button className="w-full rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white sm:w-auto" type="submit">Start document extraction</button>
                    </form>
                  ) : (
                    <span className="w-full break-words rounded-xl bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-500 ring-1 ring-slate-200 sm:w-auto">Document extraction blocked: {blockedReason(batch, jobId, ocrStatus)}</span>
                  )}

                  {canFetch ? (
                    <form action="/internal/dva-statement-import/mindee-fetch" method="post" className="w-full sm:w-auto">
                      <input type="hidden" name="import_batch_id" value={text(batch.id)} />
                      <button className="w-full rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white sm:w-auto" type="submit">Fetch extraction result</button>
                    </form>
                  ) : null}

                  {canParse ? (
                    <form action="/internal/dva-statement-import/mindee-parse-v3" method="post" className="grid w-full max-w-full gap-3 rounded-2xl border border-emerald-100 bg-emerald-50 p-3 sm:w-auto sm:grid-cols-[minmax(0,14rem)_auto] sm:items-end">
                      <input type="hidden" name="import_batch_id" value={text(batch.id)} />
                      <div className="min-w-0">
                        <label className="block text-xs font-semibold uppercase tracking-wide text-emerald-900">Manual base FX override</label>
                        <input
                          className="mt-1 w-full min-w-0 rounded-xl border border-emerald-200 bg-white px-3 py-2 text-sm"
                          name="manual_fx_rate"
                          type="number"
                          min="0.000001"
                          step="0.000001"
                          placeholder="Only if daily FX missing"
                        />
                        <p className="mt-1 max-w-xs text-xs font-medium text-emerald-900">
                          Optional. Leave blank to use daily FX by transaction date from /internal/fx-rates. Enter only to override missing daily base rates.
                        </p>
                      </div>
                      <button className="w-full rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white sm:w-auto" type="submit">Parse/stage extracted rows</button>
                    </form>
                  ) : null}

                  <Link className="w-full rounded-xl bg-white px-4 py-2 text-center text-sm font-semibold text-sky-700 ring-1 ring-sky-200 sm:w-auto" href="/internal/dva-statement-import">Import page</Link>
                </div>

                <p className="mt-4 break-all text-xs text-slate-500">Batch ID: {text(batch.id)}</p>
              </article>
            );
          })}
        </section>
      </div>
    </main>
  );
}
