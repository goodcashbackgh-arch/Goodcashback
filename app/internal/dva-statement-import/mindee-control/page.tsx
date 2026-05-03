import Link from "next/link";
import { createClient } from "@/utils/supabase/server";

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

function isHttpUrl(value: string) {
  return /^https?:\/\//i.test(value);
}

function canStartMindee(batch: Row, jobId: string, ocrStatus: string) {
  const status = text(batch.status);
  const sourceUrl = text(batch.source_file_url);
  if (jobId) return false;
  if (["queued", "processing", "completed"].includes(ocrStatus)) return false;
  if (["committed", "voided", "failed"].includes(status)) return false;
  if (!isHttpUrl(sourceUrl)) return false;
  return true;
}

function blockedReason(batch: Row, jobId: string, ocrStatus: string) {
  const status = text(batch.status);
  const sourceUrl = text(batch.source_file_url);
  if (jobId) return "OCR already has a Mindee job.";
  if (["queued", "processing", "completed"].includes(ocrStatus)) return `OCR status is ${ocrStatus}.`;
  if (["committed", "voided", "failed"].includes(status)) return `Batch status is ${status}; upload a fresh real PDF batch for OCR.`;
  if (!isHttpUrl(sourceUrl)) return "No real uploaded file URL; likely a smoke/test batch.";
  return "Not ready for OCR.";
}

export default async function DvaStatementMindeeControlPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const params = searchParams ? await Promise.resolve(searchParams) : {};
  const importSuccess = text(params.import_success);
  const importError = text(params.import_error);
  const batchId = text(params.batch_id);
  const supabase = await createClient();

  const { data, error } = await supabase
    .from("dva_statement_import_batches")
    .select("id, original_filename, source_file_url, source_bank, statement_period_from, statement_period_to, local_ccy, detected_file_type, parser_route, status, row_count, clean_count, error_count, duplicate_count, mindee_statement_job_id, mindee_statement_model_id, mindee_statement_ocr_status, mindee_statement_enqueued_at, mindee_statement_completed_at, mindee_statement_pages_consumed, mindee_statement_error_message, uploaded_at")
    .eq("detected_file_type", "pdf")
    .order("uploaded_at", { ascending: false })
    .limit(20);

  const batches = (data ?? []) as unknown as Row[];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-statement-import" className="text-sm font-semibold text-sky-600">← Back to statement import</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card statement OCR</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">PDF Mindee control</h1>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">
            Starts, fetches, and stages Mindee V2 OCR for real PDF statement batches using MINDEE_STATEMENT_MODEL_ID only. Smoke/test or already-committed batches are blocked.
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
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">Could not read PDF batches: {error.message}</section>
        ) : null}

        <section className="grid gap-4">
          {batches.length === 0 ? (
            <article className="rounded-3xl border border-slate-200 bg-white p-6 text-sm text-slate-600 shadow-sm">No PDF statement batches visible yet.</article>
          ) : batches.map((batch) => {
            const ocrStatus = text(batch.mindee_statement_ocr_status) || "not_started";
            const jobId = text(batch.mindee_statement_job_id);
            const canStart = canStartMindee(batch, jobId, ocrStatus);
            const rowCount = Number(batch.row_count ?? 0);
            const canParse = ocrStatus === "completed" && rowCount === 0;
            return (
              <article key={text(batch.id)} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <h2 className="text-lg font-semibold">{text(batch.original_filename) || text(batch.id)}</h2>
                    <p className="mt-1 text-sm text-slate-600">{text(batch.statement_period_from)} → {text(batch.statement_period_to)} · {text(batch.source_bank)} · {text(batch.local_ccy)} · {text(batch.status)}</p>
                  </div>
                  <span className={`rounded-full px-3 py-1 text-sm font-semibold ring-1 ${statusClass(ocrStatus)}`}>{ocrStatus}</span>
                </div>

                <div className="mt-4 grid gap-2 text-sm text-slate-700 sm:grid-cols-3">
                  <p>Rows: <span className="font-semibold">{rowCount}</span></p>
                  <p>Clean: <span className="font-semibold">{Number(batch.clean_count ?? 0)}</span></p>
                  <p>Errors: <span className="font-semibold">{Number(batch.error_count ?? 0)}</span></p>
                  <p>Duplicates: <span className="font-semibold">{Number(batch.duplicate_count ?? 0)}</span></p>
                  <p>Pages: <span className="font-semibold">{text(batch.mindee_statement_pages_consumed) || "—"}</span></p>
                  <p className="break-all">Job: <span className="font-semibold">{jobId || "—"}</span></p>
                </div>

                {text(batch.mindee_statement_error_message) ? <p className="mt-3 text-sm text-rose-700">{text(batch.mindee_statement_error_message)}</p> : null}

                <div className="mt-5 flex flex-wrap gap-3">
                  {canStart ? (
                    <form action="/internal/dva-statement-import/mindee-start" method="post">
                      <input type="hidden" name="import_batch_id" value={text(batch.id)} />
                      <button className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" type="submit">Start Mindee OCR</button>
                    </form>
                  ) : (
                    <span className="rounded-xl bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-500 ring-1 ring-slate-200">OCR blocked: {blockedReason(batch, jobId, ocrStatus)}</span>
                  )}

                  {jobId ? (
                    <form action="/internal/dva-statement-import/mindee-fetch" method="post">
                      <input type="hidden" name="import_batch_id" value={text(batch.id)} />
                      <button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white" type="submit">Fetch OCR result</button>
                    </form>
                  ) : null}

                  {canParse ? (
                    <form action="/internal/dva-statement-import/mindee-parse" method="post" className="flex flex-wrap items-end gap-3 rounded-2xl border border-emerald-100 bg-emerald-50 p-3">
                      <input type="hidden" name="import_batch_id" value={text(batch.id)} />
                      <div>
                        <label className="block text-xs font-semibold uppercase tracking-wide text-emerald-900">FX rate</label>
                        <input className="mt-1 w-36 rounded-xl border border-emerald-200 bg-white px-3 py-2 text-sm" name="manual_fx_rate" type="number" min="0.000001" step="0.000001" placeholder={text(batch.local_ccy) === "GBP" ? "1" : "e.g. 19.2"} />
                      </div>
                      <button className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white" type="submit">Parse/stage Mindee rows</button>
                    </form>
                  ) : null}

                  <Link className="rounded-xl bg-white px-4 py-2 text-sm font-semibold text-sky-700 ring-1 ring-sky-200" href="/internal/dva-statement-import">Import page</Link>
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
