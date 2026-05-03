import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { createRealStatementImportBatchAction, createStageCommitSmokeImportAction } from "./actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return typeof value === "string" ? value : "";
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

function statusClass(status: string) {
  if (status === "committed") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (status === "parsed_clean") return "bg-sky-50 text-sky-700 ring-sky-200";
  if (status === "parsed_with_errors") return "bg-amber-50 text-amber-700 ring-amber-200";
  if (status === "voided" || status === "failed") return "bg-rose-50 text-rose-700 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
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
  const supabase = await createClient();

  const [batchesResult, rowsResult, latestInvoiceResult, importersResult] = await Promise.all([
    supabase
      .from("dva_statement_import_batches")
      .select("id, importer_id, source_bank, statement_period_from, statement_period_to, local_ccy, source_file_url, original_filename, detected_file_type, parser_route, status, row_count, clean_count, error_count, duplicate_count, committed_count, uploaded_at, parsed_at, committed_at, voided_at, void_reason, notes")
      .order("uploaded_at", { ascending: false })
      .limit(20),
    supabase
      .from("dva_statement_import_rows")
      .select("id, import_batch_id, source_row_number, source_page_number, statement_date, transaction_date, direction, transaction_type_candidate, amount_local_ccy, local_ccy, amount_gbp_equivalent, card_last4, merchant_raw, merchant_normalised, bank_reference, auth_or_settlement_ref, parser_confidence, parse_status, error_code, error_message, committed_dva_statement_line_id, created_at")
      .order("created_at", { ascending: false })
      .limit(30),
    supabase
      .from("supplier_invoices")
      .select("id, invoice_ref, order_id")
      .eq("id", "09ed41d2-4a3f-44fa-b292-ed1bdcd92735")
      .maybeSingle(),
    supabase
      .from("importers")
      .select("id, company_name, trading_name")
      .order("company_name", { ascending: true })
      .limit(200),
  ]);

  const batches = (batchesResult.data ?? []) as unknown as Row[];
  const rows = (rowsResult.data ?? []) as unknown as Row[];
  const latestInvoice = latestInvoiceResult.data as Row | null;
  const importers = (importersResult.data ?? []) as unknown as Row[];
  const today = new Date().toISOString().slice(0, 10);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">DVA/card statement import</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Statement upload and extraction workbench</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Staff upload DVA/card/bank statements here. The current step stores the source file, detects the file type, and creates the import batch. Extraction/staging is the next action attached to the batch.
          </p>
          <div className="mt-4 flex flex-wrap gap-2">
            <span className="rounded-full bg-sky-50 px-3 py-1 text-sm font-semibold text-sky-700 ring-1 ring-sky-200">PDF-first</span>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-sm font-semibold text-slate-700 ring-1 ring-slate-200">CSV/XLSX fallback</span>
            <span className="rounded-full bg-emerald-50 px-3 py-1 text-sm font-semibold text-emerald-700 ring-1 ring-emerald-200">Staging before commit</span>
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
            This creates the controlled import batch only. It does not yet consume OCR pages or commit statement rows.
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
              <button className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-semibold text-white" type="submit">Upload statement and create import batch</button>
            </div>
          </form>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-950">
          <h2 className="font-semibold">Temporary smoke-test control</h2>
          <p className="mt-2">This remains available only to prove the create → stage → commit RPC chain. Use the upload form above for real statement files.</p>
          <form action={createStageCommitSmokeImportAction} className="mt-4 grid gap-4 md:grid-cols-4">
            <input type="hidden" name="base_supplier_invoice_id" value="09ed41d2-4a3f-44fa-b292-ed1bdcd92735" />
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-amber-900">Base invoice</label>
              <input className="mt-1 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" readOnly value={text(latestInvoice?.invoice_ref) || "4004164248"} />
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-amber-900">Amount GBP</label>
              <input className="mt-1 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" name="amount_gbp" type="number" min="0.01" step="0.01" defaultValue="44.44" />
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-amber-900">Merchant</label>
              <input className="mt-1 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" name="merchant" defaultValue="SharkNinja Leeds GB" />
            </div>
            <div>
              <label className="block text-xs font-semibold uppercase tracking-wide text-amber-900">Normalised</label>
              <input className="mt-1 w-full rounded-xl border border-amber-200 bg-white px-3 py-2 text-sm" name="merchant_normalised" defaultValue="sharkninja" />
            </div>
            <div className="md:col-span-4">
              <button className="rounded-xl bg-amber-600 px-4 py-2 text-sm font-semibold text-white" type="submit">Create → stage → commit smoke import</button>
              <Link href="/internal/dva-reconciliation" className="ml-4 inline-flex text-sm font-semibold text-sky-600">Open DVA reconciliation →</Link>
            </div>
          </form>
        </section>

        {batchesResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">
            Could not read import batches: {batchesResult.error.message}
          </section>
        ) : null}
        {rowsResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">
            Could not read import rows: {rowsResult.error.message}
          </section>
        ) : null}
        {importersResult.error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-900">
            Could not read importers: {importersResult.error.message}
          </section>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Upload/import history</h2>
          <div className="mt-5 grid gap-4">
            {batches.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No statement import batches visible yet.</div>
            ) : batches.map((batch) => (
              <article key={text(batch.id)} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="font-semibold text-slate-950">{text(batch.original_filename) || text(batch.source_file_url)}</p>
                    <p className="mt-1 text-xs text-slate-500">{text(batch.statement_period_from)} → {text(batch.statement_period_to)} · {text(batch.source_bank)} · {text(batch.local_ccy)} · {text(batch.detected_file_type)} → {text(batch.parser_route)}</p>
                  </div>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(text(batch.status))}`}>{text(batch.status)}</span>
                </div>
                <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-5">
                  <p>Rows: <span className="font-semibold">{num(batch.row_count)}</span></p>
                  <p>Clean: <span className="font-semibold">{num(batch.clean_count)}</span></p>
                  <p>Errors: <span className="font-semibold">{num(batch.error_count)}</span></p>
                  <p>Duplicates: <span className="font-semibold">{num(batch.duplicate_count)}</span></p>
                  <p>Committed: <span className="font-semibold">{num(batch.committed_count)}</span></p>
                </div>
                <p className="mt-3 break-all text-xs text-slate-500">Batch ID: {text(batch.id)}</p>
              </article>
            ))}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Recent staged rows</h2>
          <div className="mt-5 grid gap-4">
            {rows.length === 0 ? (
              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No staged rows visible yet.</div>
            ) : rows.map((row) => (
              <article key={text(row.id)} className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="font-semibold text-slate-950">Row {num(row.source_row_number)} · {text(row.merchant_raw) || "—"}</p>
                    <p className="mt-1 text-xs text-slate-500">{text(row.statement_date)} · {text(row.direction)} · {text(row.transaction_type_candidate)}</p>
                  </div>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(text(row.parse_status) === "committed" ? "committed" : text(row.parse_status))}`}>{text(row.parse_status)}</span>
                </div>
                <div className="mt-3 grid gap-2 text-sm text-slate-700 sm:grid-cols-4">
                  <p>Local: <span className="font-semibold">{num(row.amount_local_ccy).toLocaleString("en-GB")} {text(row.local_ccy)}</span></p>
                  <p>GBP: <span className="font-semibold">{gbp(row.amount_gbp_equivalent)}</span></p>
                  <p>Card: <span className="font-semibold">{text(row.card_last4) || "—"}</span></p>
                  <p>Ref: <span className="font-semibold">{text(row.auth_or_settlement_ref) || text(row.bank_reference) || "—"}</span></p>
                </div>
                {text(row.error_message) ? <p className="mt-3 text-sm text-rose-700">{text(row.error_code)}: {text(row.error_message)}</p> : null}
                {text(row.committed_dva_statement_line_id) ? <p className="mt-3 break-all text-xs text-slate-500">Committed line: {text(row.committed_dva_statement_line_id)}</p> : null}
              </article>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}
