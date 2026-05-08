import Link from "next/link";
import { redirect } from "next/navigation";
import FlashQueryParamCleaner from "@/app/_components/FlashQueryParamCleaner";
import { createClient } from "@/utils/supabase/server";
import {
  addManualRefundDocumentLineAction,
  confirmRefundDocumentLinesAction,
  deleteManualRefundDocumentLineAction,
  requestSupervisorRefundDocumentResubmissionAction,
  updateRefundDocumentLineAction,
} from "./actions";

type SearchParams = { success?: string; error?: string };

type SubmissionRow = {
  id: string;
  dispute_id: string;
  original_supplier_invoice_id: string | null;
  document_mode: string | null;
  credit_note_ref: string | null;
  credit_note_date: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  variance_abs_gbp: number | null;
  credit_note_file_url: string | null;
  refund_proof_file_url: string | null;
  ocr_status: string | null;
  ocr_credit_note_ref: string | null;
  ocr_retailer_name: string | null;
  ocr_credit_note_date: string | null;
  ocr_credit_note_total_gbp: number | null;
  match_status: string | null;
  amount_balance_status: string | null;
  supplier_control_status: string | null;
  supplier_approval_status: string | null;
  supervisor_review_status: string | null;
  notes: string | null;
  submitted_at: string | null;
};

type RefundLine = {
  id: string;
  line_order: number;
  line_source: string;
  description: string | null;
  qty: number | null;
  amount_gbp: number | null;
  progressed_to_supplier_control_yn: boolean | null;
};

type DisputeLine = {
  id: string;
  qty_impact: number | null;
  amount_impact_gbp: number | null;
  supplier_invoice_lines: { description: string | null; line_order: number | null; line_source: string | null } | { description: string | null; line_order: number | null; line_source: string | null }[] | null;
};

type MessageRow = {
  id: string;
  message_type: string | null;
  body: string | null;
  generated_by: string | null;
  created_at: string | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function signedGbp(value: number) {
  if (Math.abs(value) < 0.005) return gbp(0);
  return `${value > 0 ? "+" : ""}${gbp(value)}`;
}

function statusLabel(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function modeLabel(value: string | null | undefined) {
  if (value === "credit_note") return "Credit note issued";
  if (value === "refund_proof_no_credit_note") return "Refund proof, no credit note";
  if (value === "no_document") return "No document issued";
  return statusLabel(value);
}

function badgeClass(value: string | null | undefined) {
  const status = String(value ?? "");
  if (["completed", "balanced", "matched_ready_to_release", "accepted"].includes(status)) return "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200";
  if (["needs_supervisor_review", "pending", "pending_ocr", "blocked", "not_released", "not_required"].includes(status)) return "bg-amber-50 text-amber-800 ring-1 ring-amber-200";
  if (["failed", "rejected", "variance"].includes(status)) return "bg-rose-50 text-rose-800 ring-1 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-1 ring-slate-200";
}

function firstLine(value: DisputeLine["supplier_invoice_lines"]) {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function canOperatorEdit(submission: SubmissionRow, lines: RefundLine[]) {
  const blockedByControl = lines.some((line) => line.progressed_to_supplier_control_yn) || !["blocked", "not_released", "pending", "pending_ocr", "needs_operator_review", "needs_supervisor_review", null].includes(submission.supplier_control_status);
  const blockedByApproval = !["blocked", "pending", "not_started", null].includes(submission.supplier_approval_status);
  return !blockedByControl && !blockedByApproval;
}

export default async function OperatorRefundDocumentReviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ dispute_id: string; submission_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { dispute_id: disputeId, submission_id: submissionId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) redirect("/auth/check");

  const { data: disputeRaw, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp, orders!inner(importer_id, order_ref, order_total_gbp_declared, total_qty_declared)")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !disputeRaw) redirect("/importer");
  const dispute = disputeRaw as unknown as { id: string; order_id: string; desired_outcome: string | null; status: string | null; amount_impact_gbp: number | null; orders: { importer_id: string; order_ref: string | null; order_total_gbp_declared: number | null; total_qty_declared: number | null } | { importer_id: string; order_ref: string | null; order_total_gbp_declared: number | null; total_qty_declared: number | null }[] };
  const order = Array.isArray(dispute.orders) ? dispute.orders[0] : dispute.orders;

  const { data: importerAccess } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .maybeSingle();

  if (!importerAccess) redirect("/importer");

  const { data: submissionRaw, error: submissionError } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, original_supplier_invoice_id, document_mode, credit_note_ref, credit_note_date, expected_credit_note_total_gbp, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, credit_note_file_url, refund_proof_file_url, ocr_status, ocr_credit_note_ref, ocr_retailer_name, ocr_credit_note_date, ocr_credit_note_total_gbp, match_status, amount_balance_status, supplier_control_status, supplier_approval_status, supervisor_review_status, notes, submitted_at")
    .eq("id", submissionId)
    .eq("dispute_id", disputeId)
    .maybeSingle();

  if (submissionError || !submissionRaw) redirect(`/importer/exceptions/${disputeId}?error=Refund+document+submission+not+found`);
  const submission = submissionRaw as SubmissionRow;

  const [{ data: linesRaw }, { data: disputeLinesRaw }, { data: messagesRaw }] = await Promise.all([
    supabase
      .from("dispute_refund_document_lines")
      .select("id, line_order, line_source, description, qty, amount_gbp, progressed_to_supplier_control_yn")
      .eq("refund_evidence_submission_id", submissionId)
      .order("line_order", { ascending: true }),
    supabase
      .from("dispute_lines")
      .select("id, qty_impact, amount_impact_gbp, supplier_invoice_lines(line_order, line_source, description)")
      .eq("dispute_id", disputeId),
    supabase
      .from("dispute_messages")
      .select("id, message_type, body, generated_by, created_at")
      .eq("dispute_id", disputeId)
      .in("message_type", ["refund_document_operator_review_request", "refund_document_operator_confirmed"])
      .order("created_at", { ascending: false }),
  ]);

  const lines = (linesRaw ?? []) as RefundLine[];
  const disputeLines = (disputeLinesRaw ?? []) as DisputeLine[];
  const messages = (messagesRaw ?? []) as MessageRow[];
  const expectedTotal = Number(submission.expected_credit_note_total_gbp ?? submission.captured_refund_amount_abs_gbp ?? submission.expected_exception_amount_abs_gbp ?? 0);
  const lineTotal = Math.round(lines.reduce((sum, line) => sum + Number(line.amount_gbp ?? 0), 0) * 100) / 100;
  const variance = Math.round((lineTotal - expectedTotal) * 100) / 100;
  const amountBalanced = Math.abs(variance) <= 0.01;
  const editable = canOperatorEdit(submission, lines);
  const alreadyConfirmed = messages.some((message) => message.message_type === "refund_document_operator_confirmed");
  const canConfirm = editable && lines.length > 0 && amountBalanced;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <FlashQueryParamCleaner />

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold">
            <Link href={`/importer/exceptions/${disputeId}`} className="text-sky-700 underline underline-offset-2">← Back to exception</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Operator refund document review</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Review refund document lines</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Confirm the commercial truth of the refund/credit document before staff release, code, approve, or send anything toward Sage readiness. This page does not release, code VAT/nominals, approve supplier control, or post to Sage.
          </p>
          <p className="mt-2 text-sm text-slate-600">Order {order.order_ref ?? dispute.order_id} · Signed in as {operator.full_name}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6">
          <p className="text-sm font-semibold uppercase tracking-[0.2em] text-sky-700">Next action</p>
          <h2 className="mt-2 text-xl font-semibold">{amountBalanced ? "Lines balance to the submitted refund document" : "Review or correct the refund document lines"}</h2>
          <p className="mt-2 text-sm text-slate-700">
            Expected total {gbp(expectedTotal)} · current line total {gbp(lineTotal)} · variance {signedGbp(variance)}.
          </p>
          <div className="mt-4 flex flex-wrap gap-3">
            <form action={confirmRefundDocumentLinesAction} className="flex flex-col gap-3 rounded-2xl border border-sky-200 bg-white p-3">
              <input type="hidden" name="dispute_id" value={disputeId} />
              <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
              <textarea name="notes" rows={2} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Optional confirmation notes" />
              <button type="submit" disabled={!canConfirm || alreadyConfirmed} className="rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">
                {alreadyConfirmed ? "Already confirmed" : "Confirm OCR/refund document lines are correct"}
              </button>
            </form>
            <form action={requestSupervisorRefundDocumentResubmissionAction} className="flex flex-col gap-3 rounded-2xl border border-amber-200 bg-white p-3">
              <input type="hidden" name="dispute_id" value={disputeId} />
              <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
              <textarea name="reason" rows={2} required className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Explain why supervisor should reject, hold or ask for resubmission" />
              <button type="submit" disabled={!editable} className="rounded-xl border border-amber-300 bg-amber-50 px-5 py-3 text-sm font-semibold text-amber-900 disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-400">Ask supervisor to review / request resubmission</button>
            </form>
          </div>
          {!editable ? <p className="mt-3 rounded-xl border border-amber-200 bg-white p-3 text-sm text-amber-900">This document has moved into supplier control or approval. Operator commercial edits are locked.</p> : null}
        </section>

        <section className="grid gap-4 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Submitted refund document</h2>
            <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
              <div><dt className="text-slate-500">Mode</dt><dd className="font-semibold">{modeLabel(submission.document_mode)}</dd></div>
              <div><dt className="text-slate-500">Ref</dt><dd className="font-semibold">{submission.credit_note_ref ?? "—"}</dd></div>
              <div><dt className="text-slate-500">Date</dt><dd className="font-semibold">{submission.credit_note_date ?? "—"}</dd></div>
              <div><dt className="text-slate-500">Expected amount</dt><dd className="font-semibold">{gbp(expectedTotal)}</dd></div>
              <div><dt className="text-slate-500">OCR status</dt><dd><span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(submission.ocr_status)}`}>{statusLabel(submission.ocr_status)}</span></dd></div>
              <div><dt className="text-slate-500">Match</dt><dd><span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(submission.match_status)}`}>{statusLabel(submission.match_status)}</span></dd></div>
              <div><dt className="text-slate-500">Amount balance</dt><dd><span className={`rounded-full px-2 py-1 text-xs font-semibold ${badgeClass(submission.amount_balance_status)}`}>{statusLabel(submission.amount_balance_status)}</span></dd></div>
              <div><dt className="text-slate-500">Supplier control</dt><dd>{statusLabel(submission.supplier_control_status)}</dd></div>
            </dl>
            <div className="mt-4 flex flex-wrap gap-3 text-sm font-semibold">
              {submission.credit_note_file_url ? <a href={submission.credit_note_file_url} target="_blank" className="text-sky-700 underline">Open credit note file</a> : null}
              {submission.refund_proof_file_url ? <a href={submission.refund_proof_file_url} target="_blank" className="text-sky-700 underline">Open refund proof</a> : null}
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Exception baseline</h2>
            <p className="mt-2 text-sm text-slate-600">Use this to compare the refund document to the disputed lines.</p>
            <div className="mt-4 space-y-3">
              {disputeLines.map((line) => {
                const source = firstLine(line.supplier_invoice_lines);
                return (
                  <div key={line.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm">
                    <p className="font-semibold">{source?.description ?? "Disputed line"}</p>
                    <p className="text-slate-600">Qty impact {line.qty_impact ?? "—"} · Amount impact {gbp(line.amount_impact_gbp)}</p>
                  </div>
                );
              })}
              {disputeLines.length === 0 ? <p className="text-sm text-slate-600">No dispute baseline lines found.</p> : null}
            </div>
          </article>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.2em] text-slate-500">OCR / refund document lines</p>
              <h2 className="mt-1 text-xl font-semibold">Review and correct lines</h2>
              <p className="mt-2 text-sm text-slate-600">OCR-extracted lines are editable but not deletable. Manual lines can be added/deleted before supplier control release.</p>
            </div>
            <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${amountBalanced ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>{amountBalanced ? "Balanced" : "Variance needs review"}</span>
          </div>

          <div className="mt-5 space-y-4">
            {lines.map((line) => (
              <article key={line.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <form action={updateRefundDocumentLineAction} className="grid gap-3 md:grid-cols-[1fr_100px_140px_auto] md:items-end">
                  <input type="hidden" name="dispute_id" value={disputeId} />
                  <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
                  <input type="hidden" name="line_id" value={line.id} />
                  <label className="block text-sm font-semibold text-slate-700">
                    Description · line {line.line_order} · {line.line_source}
                    <input name="description" defaultValue={line.description ?? ""} disabled={!editable || Boolean(line.progressed_to_supplier_control_yn)} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" />
                  </label>
                  <label className="block text-sm font-semibold text-slate-700">Qty<input name="qty" type="number" step="0.01" min="0" defaultValue={line.qty ?? 1} disabled={!editable || Boolean(line.progressed_to_supplier_control_yn)} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
                  <label className="block text-sm font-semibold text-slate-700">Amount GBP<input name="amount_gbp" type="number" step="0.01" min="0" defaultValue={line.amount_gbp ?? 0} disabled={!editable || Boolean(line.progressed_to_supplier_control_yn)} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
                  <button type="submit" disabled={!editable || Boolean(line.progressed_to_supplier_control_yn)} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Save</button>
                </form>
                {line.line_source === "manually_added" ? (
                  <form action={deleteManualRefundDocumentLineAction} className="mt-3">
                    <input type="hidden" name="dispute_id" value={disputeId} />
                    <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
                    <input type="hidden" name="line_id" value={line.id} />
                    <button type="submit" disabled={!editable || Boolean(line.progressed_to_supplier_control_yn)} className="text-sm font-semibold text-rose-700 underline disabled:cursor-not-allowed disabled:text-slate-400">Delete manual line</button>
                  </form>
                ) : null}
              </article>
            ))}
            {lines.length === 0 ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">No refund document lines exist yet. Ask supervisor to OCR/fetch the credit note, or add a manual line if this is a no-credit-note/no-document case.</p> : null}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Add manual correction line</h2>
          <p className="mt-2 text-sm text-slate-600">Use only if OCR missed part of the refund document or the retailer did not issue a formal line-level credit note.</p>
          <form action={addManualRefundDocumentLineAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_100px_140px_auto] md:items-end">
            <input type="hidden" name="dispute_id" value={disputeId} />
            <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
            <label className="block text-sm font-semibold text-slate-700">Description<input name="description" required disabled={!editable} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
            <label className="block text-sm font-semibold text-slate-700">Qty<input name="qty" type="number" step="0.01" min="0" defaultValue="1" disabled={!editable} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
            <label className="block text-sm font-semibold text-slate-700">Amount GBP<input name="amount_gbp" type="number" step="0.01" min="0" required disabled={!editable} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
            <button type="submit" disabled={!editable} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Add line</button>
          </form>
        </section>

        {messages.length > 0 ? (
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <h2 className="text-xl font-semibold">Operator review history</h2>
            <div className="mt-4 space-y-3">
              {messages.map((message) => (
                <article key={message.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                  <p className="font-semibold">{message.message_type} · {message.generated_by}</p>
                  <p className="mt-2 whitespace-pre-wrap">{message.body}</p>
                  <p className="mt-2 text-xs text-slate-500">{message.created_at}</p>
                </article>
              ))}
            </div>
          </section>
        ) : null}
      </div>
    </main>
  );
}
