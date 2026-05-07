import Link from "next/link";
import { notFound, redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { confirmRefundEvidenceOperatorReviewAction } from "./actions";

type SearchParams = { success?: string; error?: string };

type MessageRow = {
  id: string;
  dispute_id: string;
  message_type: string | null;
  body: string | null;
  created_at: string | null;
  generated_by: string | null;
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
  order_ref: string | null;
  importer_id: string;
  retailers: { name: string | null } | { name: string | null }[] | null;
  importers: { company_name: string | null } | { company_name: string | null }[] | null;
};

type SupplierInvoiceRow = {
  id: string;
  invoice_ref: string | null;
  ocr_invoice_ref: string | null;
  ocr_invoice_total_gbp: number | null;
  ocr_retailer_name: string | null;
  invoice_pdf_url: string | null;
};

type DisputeLineRow = {
  id: string;
  qty_impact: number | null;
  amount_impact_gbp: number | null;
  supplier_invoice_lines: { description: string | null; line_order: number | null } | { description: string | null; line_order: number | null }[] | null;
};

function firstRelated<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function bodyValue(body: string | null | undefined, key: string) {
  const line = (body ?? "").split("\n").find((row) => row.startsWith(`${key}:`));
  return line ? line.slice(key.length + 1).trim() : "";
}

function bodyLines(body: string | null | undefined, marker: string) {
  return (body ?? "").split("\n").filter((line) => line.trim().startsWith(marker));
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function yesNo(value: boolean) {
  return value ? "Yes" : "No";
}

function tone(value: boolean) {
  return value ? "border-emerald-200 bg-emerald-50 text-emerald-800" : "border-rose-200 bg-rose-50 text-rose-800";
}

function normalise(value: string | null | undefined) {
  return String(value ?? "").trim().toLowerCase();
}

function amountNumber(value: string | null | undefined) {
  const parsed = Number(String(value ?? "").replace(/,/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

export default async function RefundEvidenceReviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ evidence_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { evidence_id: evidenceId } = await params;
  const qp = (await searchParams) ?? {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!operator) redirect("/auth/check");

  const { data: evidence, error: evidenceError } = await supabase
    .from("dispute_messages")
    .select("id, dispute_id, message_type, body, created_at, generated_by")
    .eq("id", evidenceId)
    .maybeSingle();

  if (evidenceError || !evidence) notFound();
  if (!["credit_note_evidence", "refund_evidence"].includes(String(evidence.message_type))) notFound();

  const typedEvidence = evidence as MessageRow;

  const { data: dispute, error: disputeError } = await supabase
    .from("disputes")
    .select("id, order_id, desired_outcome, status, amount_impact_gbp")
    .eq("id", typedEvidence.dispute_id)
    .maybeSingle();

  if (disputeError || !dispute) notFound();
  const typedDispute = dispute as DisputeRow;

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, order_ref, importer_id, retailers(name), importers(company_name)")
    .eq("id", typedDispute.order_id)
    .maybeSingle();

  if (orderError || !order) notFound();
  const typedOrder = order as unknown as OrderRow;

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", typedOrder.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();

  if (!access) redirect("/importer");

  const originalSupplierInvoiceId = bodyValue(typedEvidence.body, "original_supplier_invoice_id");
  const { data: supplierInvoice } = originalSupplierInvoiceId
    ? await supabase
        .from("supplier_invoices")
        .select("id, invoice_ref, ocr_invoice_ref, ocr_invoice_total_gbp, ocr_retailer_name, invoice_pdf_url")
        .eq("id", originalSupplierInvoiceId)
        .maybeSingle()
    : { data: null };

  const { data: disputeLinesRaw } = await supabase
    .from("dispute_lines")
    .select("id, qty_impact, amount_impact_gbp, supplier_invoice_lines(description, line_order)")
    .eq("dispute_id", typedDispute.id)
    .order("created_at", { ascending: true });

  const { data: operatorReviewRaw } = await supabase
    .from("dispute_messages")
    .select("id, dispute_id, message_type, body, created_at, generated_by")
    .eq("dispute_id", typedDispute.id)
    .eq("message_type", "refund_evidence_operator_review")
    .order("created_at", { ascending: false })
    .limit(20);

  const existingReview = ((operatorReviewRaw ?? []) as MessageRow[]).find((message) => String(message.body ?? "").includes(`source_evidence_message_id: ${evidenceId}`));
  const typedInvoice = supplierInvoice as SupplierInvoiceRow | null;
  const disputeLines = (disputeLinesRaw ?? []) as unknown as DisputeLineRow[];

  const retailer = firstRelated(typedOrder.retailers)?.name ?? "—";
  const importer = firstRelated(typedOrder.importers)?.company_name ?? "—";
  const documentMode = bodyValue(typedEvidence.body, "document_mode") || "—";
  const evidenceRef = bodyValue(typedEvidence.body, "credit_note_ref") || bodyValue(typedEvidence.body, "refund_proof_file_url") || "—";
  const expectedExceptionAmount = amountNumber(bodyValue(typedEvidence.body, "expected_exception_amount_abs_gbp")) || Number(typedDispute.amount_impact_gbp ?? 0);
  const capturedAmount = amountNumber(bodyValue(typedEvidence.body, "captured_refund_amount_abs_gbp"));
  const variance = amountNumber(bodyValue(typedEvidence.body, "variance_abs_gbp"));
  const controlStatus = bodyValue(typedEvidence.body, "evidence_control_status") || "—";
  const readinessRoute = bodyValue(typedEvidence.body, "supplier_readiness_route") || "—";
  const originalInvoiceRef = bodyValue(typedEvidence.body, "original_supplier_invoice_ref") || typedInvoice?.invoice_ref || "—";
  const amountMatches = variance <= 0.01;
  const linkedInvoiceMatches = !typedInvoice || !originalSupplierInvoiceId ? false : typedInvoice.id === originalSupplierInvoiceId;
  const retailerEvidenceName = bodyValue(typedEvidence.body, "ocr_retailer_name") || bodyValue(typedEvidence.body, "retailer_name") || "";
  const retailerMatches = retailerEvidenceName ? normalise(retailerEvidenceName).includes(normalise(retailer)) || normalise(retailer).includes(normalise(retailerEvidenceName)) : true;
  const lineItems = bodyLines(typedEvidence.body, "-");
  const hasLinesOrAdjustments = lineItems.length > 0 || capturedAmount > 0;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href={`/importer/exceptions/${typedDispute.id}`} className="text-sm font-semibold text-sky-600">← Back to refund exception</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Credit note / refund document review</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Review refund evidence before supplier control</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Check the refund document or refund adjustment against the original supplier invoice and exception amount. Clean evidence can be released to supplier-draft-ready for supervisor current approval.
          </p>
          {qp.success ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800">{qp.error}</p> : null}
          {existingReview ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">Operator review already recorded: {bodyValue(existingReview.body, "review_decision") || "reviewed"}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Order</p><p className="mt-2 font-semibold">{typedOrder.order_ref ?? typedOrder.id}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Importer</p><p className="mt-2 font-semibold">{importer}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Retailer</p><p className="mt-2 font-semibold">{retailer}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Exception amount</p><p className="mt-2 font-semibold">{gbp(expectedExceptionAmount)}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Reconciled evidence view</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase text-slate-500">Document mode</p><p className="mt-1 font-semibold">{documentMode.replaceAll("_", " ")}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase text-slate-500">Evidence ref/source</p><p className="mt-1 break-words font-semibold">{evidenceRef}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase text-slate-500">Original supplier invoice</p><p className="mt-1 font-semibold">{originalInvoiceRef}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase text-slate-500">Captured refund amount</p><p className="mt-1 font-semibold">{gbp(capturedAmount)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase text-slate-500">Variance</p><p className="mt-1 font-semibold">{gbp(variance)}</p></div>
            <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase text-slate-500">Readiness route</p><p className="mt-1 break-words font-semibold">{readinessRoute}</p></div>
          </div>

          <div className="mt-5 grid gap-3 md:grid-cols-4">
            <div className={`rounded-2xl border p-4 text-sm font-semibold ${tone(linkedInvoiceMatches)}`}>Original invoice linked: {yesNo(linkedInvoiceMatches)}</div>
            <div className={`rounded-2xl border p-4 text-sm font-semibold ${tone(retailerMatches)}`}>Retailer match: {yesNo(retailerMatches)}</div>
            <div className={`rounded-2xl border p-4 text-sm font-semibold ${tone(amountMatches)}`}>Amount match: {yesNo(amountMatches)}</div>
            <div className={`rounded-2xl border p-4 text-sm font-semibold ${tone(hasLinesOrAdjustments)}`}>Lines/adjustment captured: {yesNo(hasLinesOrAdjustments)}</div>
          </div>

          <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4">
            <p className="text-sm font-semibold">Control status</p>
            <p className="mt-1 text-sm text-slate-700">{controlStatus.replaceAll("_", " ")}</p>
          </div>
        </section>

        <section className="grid gap-5 lg:grid-cols-2">
          <div className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Exception lines</h2>
            <div className="mt-4 space-y-3">
              {disputeLines.map((line) => {
                const sourceLine = firstRelated(line.supplier_invoice_lines);
                return (
                  <div key={line.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                    <p className="font-semibold">Line {sourceLine?.line_order ?? "—"}: {sourceLine?.description ?? "Refund line"}</p>
                    <p className="mt-1 text-slate-600">Qty impact {line.qty_impact ?? "—"} · Amount impact {gbp(line.amount_impact_gbp)}</p>
                  </div>
                );
              })}
              {disputeLines.length === 0 ? <p className="text-sm text-slate-600">No dispute lines found.</p> : null}
            </div>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 className="text-xl font-semibold">Captured refund evidence lines</h2>
            <div className="mt-4 space-y-2 text-sm text-slate-700">
              {lineItems.map((line, index) => <p key={index} className="rounded-xl border border-slate-200 bg-slate-50 p-3">{line}</p>)}
              {lineItems.length === 0 ? <p>No line detail captured in the evidence body. Check captured amount and notes before confirming.</p> : null}
            </div>
            {typedInvoice?.invoice_pdf_url ? <Link href={typedInvoice.invoice_pdf_url} className="mt-4 inline-block text-sm font-semibold text-sky-600">Open original invoice evidence →</Link> : null}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Operator final check</h2>
          <p className="mt-2 text-sm text-slate-600">Confirm only when the evidence is clean enough to go to the supervisor current-approval queue. If it is not clean, mark it for supervisor review.</p>
          <form action={confirmRefundEvidenceOperatorReviewAction} className="mt-5 space-y-4">
            <input type="hidden" name="evidence_id" value={typedEvidence.id} />
            <input type="hidden" name="dispute_id" value={typedDispute.id} />
            <label className="block text-sm font-semibold text-slate-700">
              Review decision
              <select name="review_decision" defaultValue={amountMatches && linkedInvoiceMatches && retailerMatches ? "confirmed_clean" : "needs_supervisor_review"} className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm">
                <option value="confirmed_clean">Confirm clean and release to supplier current-control queue</option>
                <option value="needs_supervisor_review">Needs supervisor review</option>
              </select>
            </label>
            <label className="block text-sm font-semibold text-slate-700">
              Notes optional
              <textarea name="notes" rows={3} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Explain any variance, missing OCR, or confirmation received from retailer." />
            </label>
            <button disabled={Boolean(existingReview)} type="submit" className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:opacity-50">Save operator review decision</button>
          </form>
        </section>
      </div>
    </main>
  );
}
