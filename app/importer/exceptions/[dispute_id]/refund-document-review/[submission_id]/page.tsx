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
  supplier_invoice_lines:
    | { description: string | null; line_order: number | null; line_source: string | null }
    | { description: string | null; line_order: number | null; line_source: string | null }[]
    | null;
};

type MessageRow = {
  id: string;
  message_type: string | null;
  body: string | null;
  generated_by: string | null;
  created_at: string | null;
};

type DisputeRow = {
  id: string;
  order_id: string;
  desired_outcome: string | null;
  status: string | null;
  amount_impact_gbp: number | null;
};

type OrderRow = {
  id: string;
  importer_id: string | null;
  order_ref: string | null;
  order_total_gbp_declared: number | null;
  total_qty_declared: number | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function signedGbp(value: number) {
  if (Math.abs(value) < 0.005) return gbp(0);
  return `${value > 0 ? "+" : ""}${gbp(value)}`;
}

function signedNumber(value: number) {
  if (Math.abs(value) < 0.005) return "0";
  return `${value > 0 ? "+" : ""}${value}`;
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
  if (["completed", "balanced", "matched_ready_to_release", "accepted", "confirmed"].includes(status)) return "bg-emerald-50 text-emerald-800 ring-1 ring-emerald-200";
  if (["needs_supervisor_review", "pending", "pending_ocr", "blocked", "not_released", "not_required"].includes(status)) return "bg-amber-50 text-amber-800 ring-1 ring-amber-200";
  if (["failed", "rejected", "variance"].includes(status)) return "bg-rose-50 text-rose-800 ring-1 ring-rose-200";
  return "bg-slate-100 text-slate-700 ring-1 ring-slate-200";
}

function firstLine(value: DisputeLine["supplier_invoice_lines"]) {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function canOperatorEdit(submission: SubmissionRow, lines: RefundLine[]) {
  const blockedByControl =
    lines.some((line) => line.progressed_to_supplier_control_yn) ||
    !["blocked", "not_released", "pending", "pending_ocr", "needs_operator_review", "needs_supervisor_review", null].includes(submission.supplier_control_status);
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

  const {
    data: { user },
  } = await supabase.auth.getUser();
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
    .select("id, order_id, desired_outcome, status, amount_impact_gbp")
    .eq("id", disputeId)
    .maybeSingle();

  if (disputeError || !disputeRaw) redirect(`/importer/exceptions/${disputeId}?error=Refund+document+review+could+not+load+the+source+exception`);
  const dispute = disputeRaw as DisputeRow;

  const { data: orderRaw } = await supabase
    .from("orders")
    .select("id, importer_id, order_ref, order_total_gbp_declared, total_qty_declared")
    .eq("id", dispute.order_id)
    .maybeSingle();

  const order = orderRaw as OrderRow | null;

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
  const expectedTotal = Number(submission.expected_credit_note_total_gbp ?? submission.captured_refund_amount_abs_gbp ?? submission.expected_exception_amount_abs_gbp ?? dispute.amount_impact_gbp ?? 0);
  const baselineQty = disputeLines.reduce((sum, line) => sum + Math.abs(Number(line.qty_impact ?? 0)), 0);
  const baselineAmount = expectedTotal;
  const lineQtyTotal = lines.reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const lineAmountTotal = Math.round(lines.reduce((sum, line) => sum + Number(line.amount_gbp ?? 0), 0) * 100) / 100;
  const qtyVariance = lineQtyTotal - baselineQty;
  const amountVariance = Math.round((lineAmountTotal - baselineAmount) * 100) / 100;
  const qtyMatched = Math.abs(qtyVariance) < 0.005 || baselineQty === 0;
  const amountMatched = Math.abs(amountVariance) <= 0.01;
  const lineSetBalanced = amountMatched && (qtyMatched || submission.document_mode !== "credit_note");
  const editable = canOperatorEdit(submission, lines);
  const alreadyConfirmed = messages.some((message) => message.message_type === "refund_document_operator_confirmed");
  const canConfirm = editable && lines.length > 0 && amountMatched;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <FlashQueryParamCleaner />

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href={`/importer/exceptions/${disputeId}`} className="text-sm font-semibold text-sky-600">← Back to exact exception</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Refund document reconciliation</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Exception {disputeId.slice(0, 8)} · Order {order?.order_ref ?? dispute.order_id}</h1>
          <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
            Same review pattern as invoice reconciliation: compare the submitted refund document against the exception baseline, review OCR/manual lines, correct commercial line issues, then confirm. Accounting release, VAT coding, approval and Sage readiness stay in the internal refund document control lane.
          </p>
          <p className="mt-2 text-sm text-slate-600">Signed in as: {operator.full_name}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Baseline check</p>
              <h2 className="mt-1 text-xl font-semibold">Exception baseline vs refund document lines</h2>
            </div>
            <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${lineSetBalanced ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>
              {lineSetBalanced ? "Refund value accounted for" : "Variance needs review"}
            </span>
          </div>
          <div className="mt-5 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Exception qty impact</p><p className="mt-1 text-2xl font-semibold">{baselineQty}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Refund document-line qty</p><p className="mt-1 text-2xl font-semibold">{lineQtyTotal}</p></div>
            <div className={`rounded-2xl border p-4 ${qtyMatched ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Qty variance</p><p className="mt-1 text-2xl font-semibold">{signedNumber(qtyVariance)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Expected refund value</p><p className="mt-1 text-2xl font-semibold">{gbp(baselineAmount)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Refund document-line value</p><p className="mt-1 text-2xl font-semibold">{gbp(lineAmountTotal)}</p></div>
            <div className={`rounded-2xl border p-4 ${amountMatched ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Value variance</p><p className="mt-1 text-2xl font-semibold">{signedGbp(amountVariance)}</p></div>
          </div>
        </section>

        <section className="grid gap-4 lg:grid-cols-2">
          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Source evidence</p>
            <h2 className="mt-1 text-xl font-semibold">Submitted refund document</h2>
            <dl className="mt-4 grid gap-3 text-sm sm:grid-cols-2">
              <div><dt className="text-slate-500">Mode</dt><dd className="font-semibold">{modeLabel(submission.document_mode)}</dd></div>
              <div><dt className="text-slate-500">Operator ref</dt><dd className="font-semibold">{submission.credit_note_ref ?? "—"}</dd></div>
              <div><dt className="text-slate-500">Document date</dt><dd className="font-semibold">{submission.credit_note_date ?? "—"}</dd></div>
              <div><dt className="text-slate-500">Expected total</dt><dd className="font-semibold">{gbp(expectedTotal)}</dd></div>
              <div><dt className="text-slate-500">OCR ref</dt><dd className="font-semibold">{submission.ocr_credit_note_ref ?? "—"}</dd></div>
              <div><dt className="text-slate-500">OCR retailer</dt><dd className="font-semibold">{submission.ocr_retailer_name ?? "—"}</dd></div>
              <div><dt className="text-slate-500">OCR date</dt><dd className="font-semibold">{submission.ocr_credit_note_date ?? "—"}</dd></div>
              <div><dt className="text-slate-500">OCR total</dt><dd className="font-semibold">{gbp(submission.ocr_credit_note_total_gbp)}</dd></div>
            </dl>
            <div className="mt-4 flex flex-wrap gap-3 text-sm font-semibold">
              {submission.credit_note_file_url ? <a href={submission.credit_note_file_url} target="_blank" className="text-sky-700 underline">Open credit note file</a> : null}
              {submission.refund_proof_file_url ? <a href={submission.refund_proof_file_url} target="_blank" className="text-sky-700 underline">Open refund proof</a> : null}
            </div>
          </article>

          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Affected lines</p>
            <h2 className="mt-1 text-xl font-semibold">Exception baseline lines</h2>
            <p className="mt-2 text-sm text-slate-600">These are the original disputed lines the refund document is meant to resolve.</p>
            <div className="mt-4 space-y-3">
              {disputeLines.map((line) => {
                const source = firstLine(line.supplier_invoice_lines);
                return (
                  <div key={line.id} className="rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm">
                    <p className="font-semibold">Line {source?.line_order ?? "—"} · {source?.line_source ?? "—"}</p>
                    <p>{source?.description ?? "Disputed line"}</p>
                    <p className="mt-1 text-slate-700">Qty impact {line.qty_impact ?? "—"} · Amount impact {gbp(line.amount_impact_gbp)}</p>
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
              <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Line reconciliation</p>
              <h2 className="mt-1 text-xl font-semibold">Refund document lines</h2>
              <p className="mt-2 text-sm text-slate-600">Same concept as invoice OCR reconciliation: review OCR/manual lines and save corrections before confirmation. OCR lines are editable but not deletable. Manual correction lines can be added/deleted before supplier control release.</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(submission.ocr_status)}`}>OCR {statusLabel(submission.ocr_status)}</span>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(submission.match_status)}`}>Match {statusLabel(submission.match_status)}</span>
              <span className={`rounded-full px-3 py-1 text-xs font-semibold ${badgeClass(submission.amount_balance_status)}`}>Amount {statusLabel(submission.amount_balance_status)}</span>
            </div>
          </div>

          <div className="mt-5 space-y-4">
            {lines.map((line) => {
              const locked = !editable || Boolean(line.progressed_to_supplier_control_yn);
              return (
                <article key={line.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <form action={updateRefundDocumentLineAction} className="grid gap-3 md:grid-cols-[1fr_110px_160px_auto] md:items-end">
                    <input type="hidden" name="dispute_id" value={disputeId} />
                    <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
                    <input type="hidden" name="line_id" value={line.id} />
                    <label className="block text-sm font-semibold text-slate-700">
                      Line {line.line_order} · {line.line_source}
                      <input name="description" defaultValue={line.description ?? ""} disabled={locked} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" />
                    </label>
                    <label className="block text-sm font-semibold text-slate-700">Qty<input name="qty" type="number" step="0.01" min="0" defaultValue={line.qty ?? 1} disabled={locked} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
                    <label className="block text-sm font-semibold text-slate-700">Amount GBP<input name="amount_gbp" type="number" step="0.01" min="0" defaultValue={line.amount_gbp ?? 0} disabled={locked} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
                    <button type="submit" disabled={locked} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Save line</button>
                  </form>
                  <div className="mt-3 flex flex-wrap items-center gap-3 text-xs text-slate-600">
                    <span>{line.progressed_to_supplier_control_yn ? "Released to supplier control" : "Not released to supplier control"}</span>
                    {line.line_source === "manually_added" ? (
                      <form action={deleteManualRefundDocumentLineAction}>
                        <input type="hidden" name="dispute_id" value={disputeId} />
                        <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
                        <input type="hidden" name="line_id" value={line.id} />
                        <button type="submit" disabled={locked} className="font-semibold text-rose-700 underline disabled:cursor-not-allowed disabled:text-slate-400">Delete manual line</button>
                      </form>
                    ) : null}
                  </div>
                </article>
              );
            })}
            {lines.length === 0 ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">No refund document lines exist yet. Ask supervisor to run/fetch OCR for a credit note, or add manual lines if this is a no-credit-note/no-document case.</p> : null}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Manual line</p>
          <h2 className="mt-1 text-xl font-semibold">Add manual correction line</h2>
          <p className="mt-2 text-sm text-slate-600">Use this only when OCR missed a refund line or the retailer provided refund proof/no-document evidence without clean line extraction.</p>
          <form action={addManualRefundDocumentLineAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_110px_160px_auto] md:items-end">
            <input type="hidden" name="dispute_id" value={disputeId} />
            <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
            <label className="block text-sm font-semibold text-slate-700">Description<input name="description" required disabled={!editable} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
            <label className="block text-sm font-semibold text-slate-700">Qty<input name="qty" type="number" step="0.01" min="0" defaultValue="1" disabled={!editable} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
            <label className="block text-sm font-semibold text-slate-700">Amount GBP<input name="amount_gbp" type="number" step="0.01" min="0" required disabled={!editable} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-100" /></label>
            <button type="submit" disabled={!editable} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Add line</button>
          </form>
        </section>

        <section className="rounded-3xl border border-sky-200 bg-sky-50 p-5 shadow-sm sm:p-6">
          <p className="text-sm font-medium uppercase tracking-[0.16em] text-sky-700">Progression / exception path</p>
          <h2 className="mt-1 text-xl font-semibold">Confirm or request supervisor review</h2>
          <p className="mt-2 text-sm text-slate-700">If the refund document lines now match the exception value, confirm them. If the document is wrong, incomplete or needs resubmission, ask supervisor to review.</p>
          <div className="mt-4 grid gap-3 lg:grid-cols-2">
            <form action={confirmRefundDocumentLinesAction} className="space-y-3 rounded-2xl border border-sky-200 bg-white p-4">
              <input type="hidden" name="dispute_id" value={disputeId} />
              <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
              <textarea name="notes" rows={3} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Optional confirmation notes" />
              <button type="submit" disabled={!canConfirm || alreadyConfirmed} className="w-full rounded-xl bg-sky-700 px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">
                {alreadyConfirmed ? "Already confirmed" : "Confirm refund document lines"}
              </button>
              {!amountMatched ? <p className="text-xs text-amber-800">Cannot confirm until refund document value matches the expected value, or supervisor accepts the variance.</p> : null}
            </form>
            <form action={requestSupervisorRefundDocumentResubmissionAction} className="space-y-3 rounded-2xl border border-amber-200 bg-white p-4">
              <input type="hidden" name="dispute_id" value={disputeId} />
              <input type="hidden" name="refund_evidence_submission_id" value={submissionId} />
              <textarea name="reason" rows={3} required className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Explain what is wrong: missing line, bad OCR, wrong document, needs resubmission, etc." />
              <button type="submit" disabled={!editable} className="w-full rounded-xl border border-amber-300 bg-amber-50 px-5 py-3 text-sm font-semibold text-amber-900 disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-400">Ask supervisor to review / request resubmission</button>
            </form>
          </div>
          {!editable ? <p className="mt-3 rounded-xl border border-amber-200 bg-white p-3 text-sm text-amber-900">This document has moved into supplier control or approval. Operator commercial edits are locked.</p> : null}
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
