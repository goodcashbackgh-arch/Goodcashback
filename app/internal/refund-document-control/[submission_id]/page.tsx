import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import {
  addRefundDocumentAccountingAdjustmentLineAction,
  approveRefundDocumentCurrentAction,
  deleteRefundDocumentAccountingAdjustmentLineAction,
  releaseRefundDocumentLinesAction,
  saveAllRefundDocumentLineAccountingCodesAction,
} from "./actions";

type SearchParams = { success?: string; error?: string };

type Submission = {
  id: string;
  dispute_id: string;
  original_supplier_invoice_id: string | null;
  document_mode: string;
  credit_note_ref: string | null;
  expected_credit_note_total_gbp: number | null;
  captured_refund_amount_abs_gbp: number | null;
  expected_exception_amount_abs_gbp: number | null;
  variance_abs_gbp: number | null;
  amount_balance_status: string | null;
  evidence_control_status: string | null;
  supplier_readiness_route: string | null;
  supplier_approval_status: string | null;
  supervisor_review_status: string | null;
  ocr_status?: string | null;
  match_status?: string | null;
  supplier_control_status?: string | null;
  ocr_credit_note_ref?: string | null;
  ocr_retailer_name?: string | null;
  ocr_credit_note_total_gbp?: number | null;
  notes: string | null;
};

type RefundLine = {
  id: string;
  line_order: number;
  line_source: string;
  description: string;
  qty: number | null;
  amount_gbp: number | null;
  progressed_to_supplier_control_yn: boolean | null;
};

type LineCode = {
  refund_document_line_id: string;
  description_override: string | null;
  sku_override: string | null;
  size_override: string | null;
  sage_ledger_account_id: string | null;
  nominal_code: string | null;
  tax_rate_id: string | null;
  tax_rate_label: string | null;
  vat_rate_percent: number | null;
  net_amount_gbp: number | null;
  vat_amount_gbp: number | null;
  gross_amount_gbp: number | null;
  admin_review_required_yn: boolean | null;
  review_reason: string | null;
};

type AdjustmentLine = {
  id: string;
  description: string;
  sku: string | null;
  size: string | null;
  sage_ledger_account_id: string | null;
  nominal_code: string | null;
  tax_rate_id: string | null;
  tax_rate_label: string | null;
  vat_rate_percent: number | null;
  net_amount_gbp: number | null;
  vat_amount_gbp: number | null;
  gross_amount_gbp: number | null;
};

type Totals = {
  accepted_document_gross_gbp: number | null;
  total_coded_net_gbp: number | null;
  total_coded_vat_gbp: number | null;
  total_coded_gross_gbp: number | null;
  adjustment_gross_gbp: number | null;
  progressed_line_count: number | null;
  coded_line_count: number | null;
  adjustment_line_count: number | null;
  all_progressed_lines_coded_yn: boolean | null;
  gross_reconciled_to_document_yn: boolean | null;
  gross_variance_gbp: number | null;
};

type Dispute = { id: string; order_id: string; status: string | null; desired_outcome: string | null; amount_impact_gbp: number | null };
type OrderRow = { id: string; order_ref: string | null; retailers: { name: string | null } | { name: string | null }[] | null; importers: { company_name: string | null } | { company_name: string | null }[] | null };
type SupplierInvoice = { id: string; invoice_ref: string | null; ocr_invoice_ref: string | null; ocr_invoice_total_gbp: number | null; ocr_retailer_name: string | null };

function first<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function num(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function moneyInput(value: unknown) {
  return num(value).toFixed(2);
}

function splitGross(grossValue: unknown, rateValue: unknown) {
  const gross = num(grossValue);
  const rate = num(rateValue || 20);
  const net = Math.round((gross / (1 + rate / 100)) * 100) / 100;
  const vat = Math.round((gross - net) * 100) / 100;
  return { net, vat };
}

function taxLabel(rate: unknown) {
  const n = num(rate);
  if (n === 20) return "20% standard";
  if (n === 5) return "5% reduced";
  return "0% zero/exempt";
}

function taxId(rate: unknown) {
  const n = num(rate);
  if (n === 20) return "STANDARD_20";
  if (n === 5) return "REDUCED_5";
  return "ZERO_0";
}

function statusLabel(value: string | null | undefined) {
  return String(value ?? "—").replaceAll("_", " ");
}

export default async function RefundDocumentControlPage({
  params,
  searchParams,
}: {
  params: Promise<{ submission_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { submission_id: submissionId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: submissionRaw, error: submissionError } = await supabase
    .from("dispute_refund_evidence_submissions")
    .select("id, dispute_id, original_supplier_invoice_id, document_mode, credit_note_ref, expected_credit_note_total_gbp, captured_refund_amount_abs_gbp, expected_exception_amount_abs_gbp, variance_abs_gbp, amount_balance_status, evidence_control_status, supplier_readiness_route, supplier_approval_status, supervisor_review_status, ocr_status, match_status, supplier_control_status, ocr_credit_note_ref, ocr_retailer_name, ocr_credit_note_total_gbp, notes")
    .eq("id", submissionId)
    .maybeSingle();

  if (submissionError || !submissionRaw) redirect(`/internal/supplier-draft-ready?error=${encodeURIComponent(submissionError?.message ?? "Refund evidence submission not found")}`);
  const submission = submissionRaw as Submission;

  const { data: disputeRaw } = await supabase
    .from("disputes")
    .select("id, order_id, status, desired_outcome, amount_impact_gbp")
    .eq("id", submission.dispute_id)
    .maybeSingle();

  if (!disputeRaw) redirect("/internal/supplier-draft-ready?error=Dispute+not+found");
  const dispute = disputeRaw as Dispute;

  const { data: orderRaw } = await supabase
    .from("orders")
    .select("id, order_ref, retailers(name), importers(company_name)")
    .eq("id", dispute.order_id)
    .maybeSingle();

  const order = orderRaw as unknown as OrderRow | null;

  const { data: invoiceRaw } = submission.original_supplier_invoice_id
    ? await supabase
        .from("supplier_invoices")
        .select("id, invoice_ref, ocr_invoice_ref, ocr_invoice_total_gbp, ocr_retailer_name")
        .eq("id", submission.original_supplier_invoice_id)
        .maybeSingle()
    : { data: null };

  const invoice = invoiceRaw as SupplierInvoice | null;

  const { data: linesRaw } = await supabase
    .from("dispute_refund_document_lines")
    .select("id, line_order, line_source, description, qty, amount_gbp, progressed_to_supplier_control_yn")
    .eq("refund_evidence_submission_id", submissionId)
    .order("line_order", { ascending: true });

  const lines = (linesRaw ?? []) as RefundLine[];
  const lineIds = lines.map((line) => line.id);
  const progressedLines = lines.filter((line) => line.progressed_to_supplier_control_yn);

  const { data: codeRowsRaw } = lineIds.length
    ? await supabase
        .from("dispute_refund_document_line_accounting_codes")
        .select("refund_document_line_id, description_override, sku_override, size_override, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp, admin_review_required_yn, review_reason")
        .in("refund_document_line_id", lineIds)
    : { data: [] as LineCode[] };

  const { data: adjustmentRowsRaw } = await supabase
    .from("dispute_refund_document_accounting_adjustment_lines")
    .select("id, description, sku, size, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp")
    .eq("refund_evidence_submission_id", submissionId)
    .order("created_at", { ascending: true });

  const { data: totalsRaw } = await supabase
    .from("dispute_refund_document_accounting_totals_vw")
    .select("accepted_document_gross_gbp, total_coded_net_gbp, total_coded_vat_gbp, total_coded_gross_gbp, adjustment_gross_gbp, progressed_line_count, coded_line_count, adjustment_line_count, all_progressed_lines_coded_yn, gross_reconciled_to_document_yn, gross_variance_gbp")
    .eq("refund_evidence_submission_id", submissionId)
    .maybeSingle();

  const codeByLineId = new Map<string, LineCode>();
  for (const row of (codeRowsRaw ?? []) as LineCode[]) codeByLineId.set(row.refund_document_line_id, row);

  const adjustments = (adjustmentRowsRaw ?? []) as AdjustmentLine[];
  const totals = totalsRaw as Totals | null;
  const retailer = first(order?.retailers)?.name ?? "—";
  const importer = first(order?.importers)?.company_name ?? "—";
  const acceptedGross = num(totals?.accepted_document_gross_gbp ?? submission.ocr_credit_note_total_gbp ?? submission.expected_credit_note_total_gbp ?? submission.captured_refund_amount_abs_gbp ?? submission.expected_exception_amount_abs_gbp);
  const codedNet = num(totals?.total_coded_net_gbp);
  const codedVat = num(totals?.total_coded_vat_gbp);
  const codedGross = num(totals?.total_coded_gross_gbp);
  const grossVariance = num(totals?.gross_variance_gbp ?? codedGross - acceptedGross);
  const grossOk = Math.abs(grossVariance) <= 0.01;
  const canApprove = Boolean(totals?.all_progressed_lines_coded_yn && totals?.gross_reconciled_to_document_yn && num(totals?.progressed_line_count) > 0);

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-[1500px] flex-col gap-6">
        <section className="rounded-3xl border bg-white p-6 shadow-sm">
          <Link href="/internal/supplier-draft-ready" className="text-sm font-semibold text-sky-700">← Back to supplier draft ready</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Supplier credit / refund document control</p>
          <h1 className="mt-2 text-3xl font-semibold">{order?.order_ref ?? dispute.order_id}</h1>
          <p className="mt-2 text-sm text-slate-600">{staff.full_name} · {staff.role_type}</p>
          <p className="mt-2 text-sm text-slate-600">Importer: {importer} · Retailer: {retailer}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-6">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Document mode</p><p className="text-lg font-semibold capitalize">{statusLabel(submission.document_mode)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Accepted gross</p><p className="text-2xl font-semibold">{gbp(acceptedGross)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Coded net</p><p className="text-2xl font-semibold">{gbp(codedNet)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Coded VAT</p><p className="text-2xl font-semibold">{gbp(codedVat)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Coded gross</p><p className="text-2xl font-semibold">{gbp(codedGross)}</p></div>
          <div className={`rounded-2xl border p-4 ${grossOk ? "bg-emerald-50" : "bg-amber-50"}`}><p className="text-xs uppercase text-slate-500">Gross status</p><p className="text-2xl font-semibold">{grossOk ? "OK" : "Check"}</p></div>
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Refund document header</h2>
            <div className="mt-4 space-y-2 text-sm">
              <p>Credit note/operator ref: <strong>{submission.credit_note_ref ?? "—"}</strong></p>
              <p>OCR ref: <strong>{submission.ocr_credit_note_ref ?? "—"}</strong></p>
              <p>OCR retailer: <strong>{submission.ocr_retailer_name ?? "—"}</strong></p>
              <p>OCR gross: <strong>{gbp(submission.ocr_credit_note_total_gbp)}</strong></p>
              <p>Match status: <strong>{statusLabel(submission.match_status)}</strong></p>
              <p>Supplier control status: <strong>{statusLabel(submission.supplier_control_status)}</strong></p>
              <p>Supplier approval status: <strong>{statusLabel(submission.supplier_approval_status)}</strong></p>
            </div>
          </article>

          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Original supplier invoice link</h2>
            <div className="mt-4 space-y-2 text-sm">
              <p>Invoice ref: <strong>{invoice?.invoice_ref ?? "—"}</strong></p>
              <p>OCR invoice ref: <strong>{invoice?.ocr_invoice_ref ?? "—"}</strong></p>
              <p>OCR retailer: <strong>{invoice?.ocr_retailer_name ?? "—"}</strong></p>
              <p>OCR total: <strong>{gbp(invoice?.ocr_invoice_total_gbp)}</strong></p>
            </div>
          </article>
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold">Release refund document lines to supplier control</h2>
          <p className="mt-2 text-sm text-slate-600">Release only the clean credit/refund lines that should be coded as a supplier credit/adjustment. This mirrors progressing supplier invoice lines before coding.</p>
          {lines.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">No structured refund document lines exist yet. The next operator upload/OCR sync must populate dispute_refund_document_lines before this control page can be used.</p>
          ) : (
            <form action={releaseRefundDocumentLinesAction} className="mt-4 space-y-4">
              <input type="hidden" name="refund_evidence_submission_id" value={submission.id} />
              <div className="overflow-x-auto rounded-2xl border">
                <table className="min-w-full text-left text-sm">
                  <thead className="bg-slate-100 text-xs uppercase text-slate-500">
                    <tr>
                      <th className="p-3">Release</th><th className="p-3">Line</th><th className="p-3">Source</th><th className="p-3">Description</th><th className="p-3">Qty</th><th className="p-3">Gross</th><th className="p-3">Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {lines.map((line) => (
                      <tr key={line.id} className="border-t">
                        <td className="p-3"><input type="checkbox" name="line_ids" value={line.id} defaultChecked={Boolean(line.progressed_to_supplier_control_yn)} /></td>
                        <td className="p-3">{line.line_order}</td>
                        <td className="p-3">{statusLabel(line.line_source)}</td>
                        <td className="p-3 font-medium">{line.description}</td>
                        <td className="p-3">{line.qty ?? "—"}</td>
                        <td className="p-3 font-semibold">{gbp(line.amount_gbp)}</td>
                        <td className="p-3">{line.progressed_to_supplier_control_yn ? "Released" : "Not released"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
              <label className="block text-sm font-semibold text-slate-700">
                Release notes optional
                <textarea name="notes" rows={2} className="mt-2 w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" />
              </label>
              <button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Release selected lines</button>
            </form>
          )}
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Refund document accounting coding</h2>
              <p className="mt-2 text-sm text-slate-600">Code released refund document lines to Sage GL/tax treatment. Gross is locked to the accepted refund/credit line amount.</p>
            </div>
            <div className="text-sm text-slate-600">Released {progressedLines.length} · Coded {totals?.coded_line_count ?? 0}</div>
          </div>

          {progressedLines.length === 0 ? (
            <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">Release at least one refund document line before coding.</p>
          ) : (
            <form action={saveAllRefundDocumentLineAccountingCodesAction} className="mt-5 overflow-x-auto rounded-2xl border">
              <input type="hidden" name="refund_evidence_submission_id" value={submission.id} />
              <table className="min-w-[1400px] text-left text-sm">
                <thead className="bg-slate-100 text-xs uppercase text-slate-500">
                  <tr>
                    <th className="p-2">Line</th><th className="p-2">Description</th><th className="p-2">SKU</th><th className="p-2">Size</th><th className="p-2">Gross</th><th className="p-2">Nominal</th><th className="p-2">Sage ledger</th><th className="p-2">VAT rate</th><th className="p-2">Net</th><th className="p-2">VAT</th><th className="p-2">Review?</th><th className="p-2">Reason</th>
                  </tr>
                </thead>
                <tbody>
                  {progressedLines.map((line) => {
                    const code = codeByLineId.get(line.id);
                    const rate = code?.vat_rate_percent ?? 20;
                    const split = splitGross(code?.gross_amount_gbp ?? line.amount_gbp, rate);
                    return (
                      <tr key={line.id} className="border-t align-top">
                        <td className="p-2">{line.line_order}<input type="hidden" name="line_ids" value={line.id} /></td>
                        <td className="p-2"><input name={`description_override_${line.id}`} defaultValue={code?.description_override ?? line.description} className="w-72 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2"><input name={`sku_override_${line.id}`} defaultValue={code?.sku_override ?? ""} className="w-28 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2"><input name={`size_override_${line.id}`} defaultValue={code?.size_override ?? ""} className="w-20 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2 font-semibold">{gbp(line.amount_gbp)}</td>
                        <td className="p-2"><input name={`nominal_code_${line.id}`} defaultValue={code?.nominal_code ?? ""} className="w-24 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2"><input name={`sage_ledger_account_id_${line.id}`} defaultValue={code?.sage_ledger_account_id ?? ""} className="w-36 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2">
                          <select name={`vat_rate_percent_${line.id}`} defaultValue={String(rate)} className="w-32 rounded-lg border px-2 py-1">
                            <option value="20">20% std</option><option value="5">5% reduced</option><option value="0">0%</option>
                          </select>
                          <input type="hidden" name={`tax_rate_label_${line.id}`} value={code?.tax_rate_label ?? taxLabel(rate)} />
                          <input type="hidden" name={`tax_rate_id_${line.id}`} value={code?.tax_rate_id ?? taxId(rate)} />
                        </td>
                        <td className="p-2"><input name={`net_amount_gbp_${line.id}`} type="number" step="0.01" defaultValue={moneyInput(code?.net_amount_gbp ?? split.net)} className="w-24 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2"><input name={`vat_amount_gbp_${line.id}`} type="number" step="0.01" defaultValue={moneyInput(code?.vat_amount_gbp ?? split.vat)} className="w-24 rounded-lg border px-2 py-1" /></td>
                        <td className="p-2 text-center"><input type="checkbox" name={`admin_review_required_yn_${line.id}`} defaultChecked={Boolean(code?.admin_review_required_yn)} /></td>
                        <td className="p-2"><input name={`review_reason_${line.id}`} defaultValue={code?.review_reason ?? ""} className="w-56 rounded-lg border px-2 py-1" /></td>
                      </tr>
                    );
                  })}

                  {adjustments.map((line) => (
                    <tr key={line.id} className="border-t bg-amber-50 align-top">
                      <td className="p-2">Adj</td><td className="p-2">{line.description}</td><td className="p-2">{line.sku ?? "—"}</td><td className="p-2">{line.size ?? "—"}</td><td className="p-2 font-semibold">{gbp(line.gross_amount_gbp)}</td><td className="p-2">{line.nominal_code ?? "—"}</td><td className="p-2">{line.sage_ledger_account_id ?? "—"}</td><td className="p-2">{line.tax_rate_label ?? `${line.vat_rate_percent ?? 0}%`}</td><td className="p-2">{gbp(line.net_amount_gbp)}</td><td className="p-2">{gbp(line.vat_amount_gbp)}</td><td className="p-2">manual</td>
                      <td className="p-2"><form action={deleteRefundDocumentAccountingAdjustmentLineAction}><input type="hidden" name="refund_evidence_submission_id" value={submission.id} /><input type="hidden" name="adjustment_line_id" value={line.id} /><button className="rounded-lg border border-rose-300 bg-rose-50 px-3 py-1 font-semibold text-rose-800">Delete</button></form></td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div className="flex justify-end border-t bg-slate-50 p-4"><button className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Save all refund document coding</button></div>
            </form>
          )}
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold">Manual accounting adjustment row</h2>
          <form action={addRefundDocumentAccountingAdjustmentLineAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_110px_90px_110px_140px_120px_120px_auto]">
            <input type="hidden" name="refund_evidence_submission_id" value={submission.id} />
            <input name="description" className="rounded-lg border px-2 py-2 text-sm" placeholder="Rounding / adjustment" />
            <input name="sku" className="rounded-lg border px-2 py-2 text-sm" placeholder="SKU" />
            <input name="size" className="rounded-lg border px-2 py-2 text-sm" placeholder="Size" />
            <input name="nominal_code" className="rounded-lg border px-2 py-2 text-sm" placeholder="Nominal" />
            <input name="sage_ledger_account_id" className="rounded-lg border px-2 py-2 text-sm" placeholder="Sage ledger" />
            <select name="vat_rate_percent" defaultValue="20" className="rounded-lg border px-2 py-2 text-sm"><option value="20">20%</option><option value="5">5%</option><option value="0">0%</option></select>
            <input name="net_amount_gbp" type="number" step="0.01" className="rounded-lg border px-2 py-2 text-sm" placeholder="Net" />
            <div className="flex gap-2"><input name="vat_amount_gbp" type="number" step="0.01" className="w-24 rounded-lg border px-2 py-2 text-sm" placeholder="VAT" /><input type="hidden" name="tax_rate_label" value="manual" /><input type="hidden" name="tax_rate_id" value="manual" /><button className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Add</button></div>
          </form>
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Approve current</h2>
              <p className="mt-1 text-sm text-slate-600">Approval is blocked unless all released lines are coded and gross reconciles to the accepted refund document amount.</p>
              <p className="mt-2 text-sm">Variance: <strong>{gbp(grossVariance)}</strong> · Ready: <strong>{canApprove ? "Yes" : "No"}</strong></p>
            </div>
            <form action={approveRefundDocumentCurrentAction} className="flex flex-col gap-2 md:w-[420px]">
              <input type="hidden" name="refund_evidence_submission_id" value={submission.id} />
              <textarea name="review_notes" rows={2} className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Approval notes" />
              <button disabled={!canApprove} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-300">Approve refund document current</button>
            </form>
          </div>
        </section>
      </div>
    </main>
  );
}
