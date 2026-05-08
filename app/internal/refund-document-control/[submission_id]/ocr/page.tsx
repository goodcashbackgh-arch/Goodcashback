import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type SearchParamsValue = Record<string, string | string[] | undefined>;

type SubmissionRow = {
  id: string;
  dispute_id: string | null;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  expected_credit_note_total_gbp: string | number | null;
  credit_note_file_url: string | null;
  ocr_status: string | null;
  ocr_credit_note_ref: string | null;
  ocr_retailer_name: string | null;
  ocr_credit_note_date: string | null;
  ocr_credit_note_total_gbp: string | number | null;
  match_status: string | null;
  amount_balance_status: string | null;
  supplier_control_status: string | null;
  supplier_approval_status: string | null;
  mindee_job_id: string | null;
  mindee_model_id: string | null;
  mindee_error_message: string | null;
  mindee_enqueued_at: string | null;
  mindee_result_saved_at: string | null;
};

type LineRow = {
  id: string;
  line_order: string | number | null;
  line_source: string | null;
  description: string | null;
  qty: string | number | null;
  amount_gbp: string | number | null;
};

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

function gbp(value: unknown) {
  const parsed = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number.isFinite(parsed) ? parsed : 0);
}

function statusClass(status: string | null | undefined) {
  const s = String(status ?? "");
  if (["matched_ready_to_release", "balanced", "completed", "not_released", "pending"].includes(s)) return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (["needs_supervisor_review", "variance", "blocked", "failed"].includes(s)) return "border-amber-200 bg-amber-50 text-amber-900";
  return "border-slate-200 bg-slate-100 text-slate-700";
}

function StatusPill({ label, value }: { label: string; value: string | null | undefined }) {
  return (
    <div className={`rounded-2xl border px-4 py-3 text-sm ${statusClass(value)}`}>
      <p className="text-xs font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 font-semibold">{value || "—"}</p>
    </div>
  );
}

export default async function RefundCreditNoteOcrPage({
  params,
  searchParams,
}: {
  params: { submission_id: string } | Promise<{ submission_id: string }>;
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const resolvedParams = await Promise.resolve(params);
  const resolvedSearchParams = searchParams ? await Promise.resolve(searchParams) : {};
  const submissionId = resolvedParams.submission_id;
  const success = firstParam(resolvedSearchParams.success);
  const error = firstParam(resolvedSearchParams.error);

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: submissionRaw, error: submissionError } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, document_mode, credit_note_ref, credit_note_date, expected_credit_note_total_gbp, credit_note_file_url, ocr_status, ocr_credit_note_ref, ocr_retailer_name, ocr_credit_note_date, ocr_credit_note_total_gbp, match_status, amount_balance_status, supplier_control_status, supplier_approval_status, mindee_job_id, mindee_model_id, mindee_error_message, mindee_enqueued_at, mindee_result_saved_at")
    .eq("id", submissionId)
    .maybeSingle();

  if (submissionError || !submissionRaw) {
    return (
      <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
        <div className="mx-auto max-w-4xl rounded-3xl border border-rose-200 bg-rose-50 p-6 text-rose-900">
          <h1 className="text-2xl font-semibold">Credit-note OCR control unavailable</h1>
          <p className="mt-2 text-sm">{submissionError?.message ?? "Refund evidence submission not found."}</p>
        </div>
      </main>
    );
  }

  const submission = submissionRaw as SubmissionRow;
  const { data: linesRaw } = await supabase
    .from("dispute_refund_document_lines")
    .select("id, line_order, line_source, description, qty, amount_gbp")
    .eq("refund_evidence_submission_id", submissionId)
    .order("line_order", { ascending: true });

  const lines = (linesRaw ?? []) as LineRow[];
  const canStart = submission.document_mode === "credit_note" && Boolean(submission.credit_note_file_url) && !submission.mindee_job_id;
  const canFetch = submission.document_mode === "credit_note" && Boolean(submission.mindee_job_id);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-6xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap gap-3 text-sm font-semibold">
            <Link href={`/internal/refund-document-control/${submissionId}`} className="text-sky-700 underline underline-offset-2">← Back to refund document control</Link>
            {submission.dispute_id ? <Link href={`/internal/exceptions/${submission.dispute_id}`} className="text-sky-700 underline underline-offset-2">Open internal exception</Link> : null}
            <Link href="/internal/refund-document-control" className="text-slate-600 underline underline-offset-2">Open refund document queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Credit-note OCR only</p>
          <div className="mt-3 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight">Credit-note OCR extraction</h1>
              <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
                This page is only for starting Mindee OCR and safely fetching the OCR result for a submitted credit note. It does not release lines, code VAT/nominals, approve supplier credit control, or post to Sage.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}</div>
            </div>
          </div>
        </section>

        {success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{success}</div> : null}
        {error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{error}</div> : null}

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm">
          <p className="text-sm font-semibold uppercase tracking-[0.2em] text-sky-700">Next action</p>
          <div className="mt-3 flex flex-wrap gap-3">
            <Link href={`/internal/refund-document-control/${submissionId}`} className="rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white">Go to release / coding / approval control</Link>
            {submission.dispute_id ? <Link href={`/internal/exceptions/${submission.dispute_id}`} className="rounded-xl border border-sky-300 bg-white px-5 py-3 text-sm font-semibold text-sky-800">Back to exception review</Link> : null}
          </div>
          <p className="mt-3 text-sm text-slate-600">After OCR is completed or already stored, continue in the refund document control page. Do not hunt for the URL manually.</p>
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <StatusPill label="OCR status" value={submission.ocr_status} />
          <StatusPill label="Match status" value={submission.match_status} />
          <StatusPill label="Amount balance" value={submission.amount_balance_status} />
        </section>

        <section className="grid gap-5 lg:grid-cols-2">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-lg font-semibold">Submitted credit note evidence</h2>
            <dl className="mt-4 space-y-3 text-sm">
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Document mode</dt><dd className="font-medium">{submission.document_mode ?? "—"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Submitted ref</dt><dd className="font-medium">{submission.credit_note_ref ?? "—"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Submitted date</dt><dd className="font-medium">{submission.credit_note_date ?? "—"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Expected total</dt><dd className="font-medium">{gbp(submission.expected_credit_note_total_gbp)}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Credit-note file</dt><dd className="font-medium">{submission.credit_note_file_url ? <a href={submission.credit_note_file_url} className="text-sky-700 underline" target="_blank">Open file</a> : "—"}</dd></div>
            </dl>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-lg font-semibold">OCR result</h2>
            <dl className="mt-4 space-y-3 text-sm">
              <div className="flex justify-between gap-4"><dt className="text-slate-500">OCR ref</dt><dd className="font-medium">{submission.ocr_credit_note_ref ?? "—"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">OCR retailer</dt><dd className="font-medium">{submission.ocr_retailer_name ?? "—"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">OCR date</dt><dd className="font-medium">{submission.ocr_credit_note_date ?? "—"}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">OCR total</dt><dd className="font-medium">{gbp(submission.ocr_credit_note_total_gbp)}</dd></div>
              <div className="flex justify-between gap-4"><dt className="text-slate-500">Mindee job</dt><dd className="font-mono text-xs">{submission.mindee_job_id ?? "—"}</dd></div>
            </dl>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-lg font-semibold">OCR actions</h2>
          <div className="mt-4 flex flex-wrap gap-3">
            <form action="/internal/refund-document-control/credit-note-ocr-start" method="post">
              <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
              <button disabled={!canStart} className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Start credit-note OCR</button>
            </form>
            <form action="/internal/refund-document-control/credit-note-ocr-fetch" method="post">
              <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
              <button disabled={!canFetch} className="rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Safe fetch OCR result</button>
            </form>
            <Link href={`/internal/refund-document-control/${submissionId}`} className="rounded-xl border border-slate-300 bg-white px-5 py-3 text-sm font-semibold text-slate-700">Back to control page</Link>
          </div>
          <p className="mt-3 text-xs text-slate-500">Start OCR consumes a Mindee page. Safe fetch does not re-upload the document; it only reads the existing Mindee job result. Release, coding and approval remain in the supplier credit/refund document control lane.</p>
          {submission.mindee_error_message ? <p className="mt-3 rounded-xl bg-rose-50 p-3 text-sm text-rose-800">{submission.mindee_error_message}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-lg font-semibold">OCR extracted refund document lines</h2>
          <p className="mt-1 text-xs text-slate-500">These are extracted lines only. Release, coding and approval are handled outside this OCR page.</p>
          <div className="mt-4 overflow-x-auto">
            <table className="min-w-full text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Line</th><th className="p-3">Source</th><th className="p-3">Description</th><th className="p-3 text-right">Qty</th><th className="p-3 text-right">Amount</th></tr></thead>
              <tbody>
                {lines.length === 0 ? <tr><td colSpan={5} className="p-4 text-slate-500">No OCR extracted refund document lines yet.</td></tr> : null}
                {lines.map((line) => (
                  <tr key={line.id} className="border-t">
                    <td className="p-3">{line.line_order}</td>
                    <td className="p-3">{line.line_source}</td>
                    <td className="p-3 font-medium">{line.description}</td>
                    <td className="p-3 text-right">{line.qty}</td>
                    <td className="p-3 text-right font-semibold">{gbp(line.amount_gbp)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
