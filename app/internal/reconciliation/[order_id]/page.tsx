import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import AccountingGridCalculator from "./AccountingGridCalculator";
import ManualAdjustmentRows from "./ManualAdjustmentRows";
import { saveAllSupplierLineAccountingCodesAction } from "./actions";

type SearchParams = { success?: string; error?: string };

type Line = {
  id: string;
  line_order: number;
  line_source: string;
  retailer_sku: string | null;
  description: string;
  qty: number | null;
  size: string | null;
  amount_inc_vat_gbp: number | null;
  eligible_for_invoice_yn: string | null;
};

type NonPhysicalResolution = {
  supplier_invoice_line_id: string;
  financial_type: string;
  amount_gbp: number | null;
  qty_reported: number | null;
  notes: string | null;
  resolved_at: string | null;
};

type AccountingCode = {
  supplier_invoice_line_id: string;
  posting_description: string | null;
  posting_sku: string | null;
  posting_size: string | null;
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
  coded_yn: boolean | null;
};

type AdjustmentLine = {
  id: string;
  description: string;
  qty: number | null;
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
  accepted_invoice_gross_gbp: number | null;
  total_coded_net_gbp: number | null;
  total_coded_vat_gbp: number | null;
  total_coded_gross_gbp: number | null;
  adjustment_gross_gbp: number | null;
  progressed_line_count: number | null;
  coded_line_count: number | null;
  adjustment_line_count: number | null;
  all_progressed_lines_coded_yn: boolean | null;
  gross_reconciled_to_invoice_yn: boolean | null;
  gross_variance_gbp: number | null;
  accepted_invoice_net_gbp: number | null;
  accepted_invoice_vat_gbp: number | null;
  net_reconciled_to_invoice_yn: boolean | null;
  vat_reconciled_to_invoice_yn: boolean | null;
  net_variance_gbp: number | null;
  vat_variance_gbp: number | null;
};

type Screenshot = { id: string; screenshot_url: string; display_order: number | null; note: string | null };

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

function first<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes(String(value ?? "").toLowerCase());
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

export default async function InternalReconciliationPage({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string }>;
  searchParams?: Promise<SearchParams>;
}) {
  const { order_id: orderId } = await params;
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

  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, order_ref, total_qty_declared, order_total_gbp_declared, screenshot_url, retailers(name), importers(company_name)")
    .eq("id", orderId)
    .maybeSingle();

  if (orderError || !order) redirect("/internal?error=Order+not+found");

  const { data: invoice } = await supabase
    .from("supplier_invoices")
    .select("id, invoice_ref, invoice_pdf_url, uploaded_at, ocr_invoice_ref, ocr_retailer_name, ocr_invoice_total_gbp, ocr_extracted_at, review_status, is_current_for_order, blocked_from_sage_yn")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: screenshots } = await supabase
    .from("order_screenshots")
    .select("id, screenshot_url, display_order, note")
    .eq("order_id", orderId)
    .order("display_order", { ascending: true });

  const { data: lines } = invoice?.id
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] as Line[] };

  const invoiceLines = (lines ?? []) as Line[];
  const lineIds = invoiceLines.map((line) => line.id);

  const { data: nonPhysicalRows } = invoice?.id && lineIds.length
    ? await supabase
        .from("supplier_invoice_line_resolutions")
        .select("supplier_invoice_line_id, financial_type, amount_gbp, qty_reported, notes, resolved_at")
        .eq("supplier_invoice_id", invoice.id)
        .eq("resolution_type", "non_physical_financial")
        .eq("active", true)
        .in("supplier_invoice_line_id", lineIds)
    : { data: [] as NonPhysicalResolution[] };

  const nonPhysicalByLineId = new Map<string, NonPhysicalResolution>();
  for (const row of (nonPhysicalRows ?? []) as NonPhysicalResolution[]) {
    nonPhysicalByLineId.set(row.supplier_invoice_line_id, row);
  }

  const codableLines = invoiceLines.filter((line) => isProgressed(line.eligible_for_invoice_yn) || nonPhysicalByLineId.has(line.id));

  const { data: codingRows } = lineIds.length
    ? await supabase
        .from("supplier_invoice_line_accounting_coding_vw")
        .select("supplier_invoice_line_id, posting_description, posting_sku, posting_size, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp, admin_review_required_yn, review_reason, coded_yn")
        .in("supplier_invoice_line_id", lineIds)
    : { data: [] as AccountingCode[] };

  const { data: adjustmentRows } = invoice?.id
    ? await supabase
        .from("supplier_invoice_accounting_adjustment_lines")
        .select("id, description, qty, sku, size, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp")
        .eq("supplier_invoice_id", invoice.id)
        .order("created_at", { ascending: true })
    : { data: [] as AdjustmentLine[] };

  const { data: totalsRow } = invoice?.id
    ? await supabase
        .from("supplier_invoice_accounting_coding_totals_vw")
        .select("accepted_invoice_gross_gbp, total_coded_net_gbp, total_coded_vat_gbp, total_coded_gross_gbp, adjustment_gross_gbp, progressed_line_count, coded_line_count, adjustment_line_count, all_progressed_lines_coded_yn, gross_reconciled_to_invoice_yn, gross_variance_gbp, accepted_invoice_net_gbp, accepted_invoice_vat_gbp, net_reconciled_to_invoice_yn, vat_reconciled_to_invoice_yn, net_variance_gbp, vat_variance_gbp")
        .eq("supplier_invoice_id", invoice.id)
        .maybeSingle()
    : { data: null as Totals | null };

  const codingByLineId = new Map<string, AccountingCode>();
  for (const row of (codingRows ?? []) as AccountingCode[]) codingByLineId.set(row.supplier_invoice_line_id, row);

  const adjustments = (adjustmentRows ?? []) as AdjustmentLine[];
  const screenshotsList = (screenshots ?? []) as Screenshot[];
  const retailer = first(order.retailers as { name: string | null } | { name: string | null }[] | null)?.name ?? "—";
  const importer = first(order.importers as { company_name: string | null } | { company_name: string | null }[] | null)?.company_name ?? "—";
  const invoiceNet = num(totalsRow?.accepted_invoice_net_gbp);
  const invoiceVat = num(totalsRow?.accepted_invoice_vat_gbp);
  const acceptedGross = num(totalsRow?.accepted_invoice_gross_gbp ?? invoice?.ocr_invoice_total_gbp ?? order.order_total_gbp_declared);
  const codedNet = num(totalsRow?.total_coded_net_gbp);
  const codedVat = num(totalsRow?.total_coded_vat_gbp);
  const codedGross = num(totalsRow?.total_coded_gross_gbp);
  const netVariance = num(totalsRow?.net_variance_gbp ?? codedNet - invoiceNet);
  const vatVariance = num(totalsRow?.vat_variance_gbp ?? codedVat - invoiceVat);
  const grossVariance = num(totalsRow?.gross_variance_gbp ?? codedGross - acceptedGross);
  const vatStatusOk = Math.abs(netVariance) <= 0.01 && Math.abs(vatVariance) <= 0.01 && Math.abs(grossVariance) <= 0.01;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <AccountingGridCalculator />
      <div className="mx-auto flex max-w-[1500px] flex-col gap-6">
        <section className="rounded-3xl border bg-white p-6 shadow-sm">
          <Link href="/internal/supplier-draft-ready" className="text-sm font-semibold text-sky-700">← Back to supplier draft ready</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Supervisor reconciliation check</p>
          <h1 className="mt-2 text-3xl font-semibold">{order.order_ref ?? orderId}</h1>
          <p className="mt-2 text-sm text-slate-600">{staff.full_name} · {staff.role_type}</p>
          <p className="mt-2 text-sm text-slate-600">Importer: {importer} · Retailer: {retailer}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-6">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice net</p><p className="text-2xl font-semibold">{gbp(invoiceNet)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice VAT</p><p className="text-2xl font-semibold">{gbp(invoiceVat)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Invoice gross</p><p className="text-2xl font-semibold">{gbp(acceptedGross)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Coded net</p><p className="text-2xl font-semibold">{gbp(codedNet)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Coded VAT</p><p className="text-2xl font-semibold">{gbp(codedVat)}</p></div>
          <div className={`rounded-2xl border p-4 ${vatStatusOk ? "bg-emerald-50" : "bg-amber-50"}`}><p className="text-xs uppercase text-slate-500">Net/VAT/Gross status</p><p className="text-2xl font-semibold">{vatStatusOk ? "OK" : "Check"}</p></div>
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Uploaded supplier invoice</h2>
            {invoice ? (
              <div className="mt-4 space-y-2 text-sm">
                <p>Operator/OCR ref: <strong>{invoice.invoice_ref} / {invoice.ocr_invoice_ref ?? "—"}</strong></p>
                <p>OCR retailer: <strong>{invoice.ocr_retailer_name ?? "—"}</strong></p>
                <p>Invoice OCR net/VAT/gross: <strong>{gbp(invoiceNet)} / {gbp(invoiceVat)} / {gbp(acceptedGross)}</strong></p>
                <p>Status: <strong>{invoice.review_status}</strong> · current: <strong>{invoice.is_current_for_order ? "yes" : "no"}</strong> · Sage blocked: <strong>{invoice.blocked_from_sage_yn ? "yes" : "no"}</strong></p>
                <a href={invoice.invoice_pdf_url} target="_blank" rel="noreferrer" className="inline-flex rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Open invoice</a>
              </div>
            ) : <p className="mt-4 text-sm text-slate-600">No invoice found.</p>}
          </article>

          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Order screenshots</h2>
            <div className="mt-4 space-y-3">
              {screenshotsList.length === 0 ? <p className="text-sm text-slate-600">No screenshots attached.</p> : null}
              {screenshotsList.map((screenshot, index) => (
                <details key={screenshot.id} className="rounded-2xl border bg-slate-50 p-3">
                  <summary className="cursor-pointer text-sm font-semibold">Screenshot {screenshot.display_order ?? index + 1}</summary>
                  {screenshot.note ? <p className="mt-2 text-sm text-slate-600">{screenshot.note}</p> : null}
                  <img src={screenshot.screenshot_url} alt="Order screenshot" className="mt-3 max-h-[70vh] w-full rounded-xl border object-contain" />
                </details>
              ))}
            </div>
          </article>
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="text-xl font-semibold">Supplier invoice accounting grid</h2>
              <p className="mt-2 text-sm text-slate-600">Save all is atomic: invoice net, VAT and gross must reconcile individually. Progressed product lines and parked non-physical financial lines are codable.</p>
            </div>
            {invoice ? (
              <form id="save-all-coding" action={saveAllSupplierLineAccountingCodesAction}>
                <input type="hidden" name="order_id" value={orderId} />
                <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
                <button disabled={codableLines.length === 0} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white disabled:bg-slate-400">Save all coding lines</button>
              </form>
            ) : null}
          </div>

          <div className="mt-4 rounded-2xl border bg-slate-50 p-3">
            <div className="grid gap-3 md:grid-cols-4">
              <label className="text-xs font-semibold uppercase text-slate-500">Default nominal/GL<input data-bulk-nominal className="mt-1 w-full rounded-lg border px-2 py-2 text-sm normal-case text-slate-900" placeholder="e.g. 5000" /></label>
              <label className="text-xs font-semibold uppercase text-slate-500">Default Sage ledger id<input data-bulk-sage-ledger className="mt-1 w-full rounded-lg border px-2 py-2 text-sm normal-case text-slate-900" placeholder="from Sage sync later" /></label>
              <label className="text-xs font-semibold uppercase text-slate-500">Default VAT class<select data-bulk-vat-rate defaultValue="20" className="mt-1 w-full rounded-lg border px-2 py-2 text-sm normal-case text-slate-900"><option value="20">20% standard</option><option value="5">5% reduced</option><option value="0">0%</option></select></label>
              <div className="flex items-end"><button type="button" data-apply-bulk-defaults className="w-full rounded-lg bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Apply to all lines</button></div>
            </div>
          </div>

          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[1500px] text-left text-xs">
              <thead className="bg-slate-100 uppercase text-slate-500">
                <tr>
                  <th className="p-2">Line</th>
                  <th className="p-2">Description</th>
                  <th className="p-2">SKU</th>
                  <th className="p-2">Size</th>
                  <th className="p-2">Qty</th>
                  <th className="p-2">Nominal/GL</th>
                  <th className="p-2">Sage ledger id</th>
                  <th className="p-2">VAT class</th>
                  <th className="p-2">Net</th>
                  <th className="p-2">VAT</th>
                  <th className="p-2">Gross</th>
                  <th className="p-2">Review</th>
                  <th className="p-2">Status</th>
                </tr>
              </thead>
              <tbody>
                {invoiceLines.map((line) => {
                  const coding = codingByLineId.get(line.id);
                  const gross = num(line.amount_inc_vat_gbp);
                  const rate = coding?.vat_rate_percent ?? 20;
                  const preview = splitGross(gross, rate);
                  const progressed = isProgressed(line.eligible_for_invoice_yn);
                  const nonPhysicalResolution = nonPhysicalByLineId.get(line.id);
                  const nonPhysicalCodable = Boolean(nonPhysicalResolution);
                  const codable = progressed || nonPhysicalCodable;
                  const saveForm = codable ? "save-all-coding" : undefined;
                  const rowStatus = nonPhysicalCodable ? `financial: ${nonPhysicalResolution?.financial_type ?? "non-physical"}` : progressed ? "progressed" : "blocked";
                  return (
                    <tr key={line.id} data-accounting-row data-gross={moneyInput(gross)} className="border-b align-top">
                      <td className="p-2">{line.line_order}<br /><span className={nonPhysicalCodable ? "text-sky-600" : "text-slate-400"}>{rowStatus}</span>{codable ? <input form="save-all-coding" type="hidden" name="line_ids" value={line.id} /> : null}</td>
                      <td className="p-2"><input form={saveForm} name={`description_override_${line.id}`} defaultValue={coding?.posting_description ?? line.description} disabled={!codable} className="w-72 rounded-lg border px-2 py-1 disabled:bg-slate-100" /></td>
                      <td className="p-2"><input form={saveForm} name={`sku_override_${line.id}`} defaultValue={coding?.posting_sku ?? line.retailer_sku ?? ""} disabled={!codable} className="w-28 rounded-lg border px-2 py-1 disabled:bg-slate-100" /></td>
                      <td className="p-2"><input form={saveForm} name={`size_override_${line.id}`} defaultValue={coding?.posting_size ?? line.size ?? ""} disabled={!codable} className="w-20 rounded-lg border px-2 py-1 disabled:bg-slate-100" /></td>
                      <td className="p-2">{line.qty ?? 0}</td>
                      <td className="p-2"><input data-nominal form={saveForm} name={`nominal_code_${line.id}`} defaultValue={coding?.nominal_code ?? ""} disabled={!codable} className="w-24 rounded-lg border px-2 py-1 disabled:bg-slate-100" placeholder="5000" /></td>
                      <td className="p-2"><input data-sage-ledger form={saveForm} name={`sage_ledger_account_id_${line.id}`} defaultValue={coding?.sage_ledger_account_id ?? ""} disabled={!codable} className="w-36 rounded-lg border px-2 py-1 disabled:bg-slate-100" /></td>
                      <td className="p-2">
                        <select form={saveForm} name={`vat_rate_percent_${line.id}`} data-vat-rate defaultValue={String(rate)} disabled={!codable} className="w-32 rounded-lg border px-2 py-1 disabled:bg-slate-100">
                          <option value="20">20% std</option>
                          <option value="5">5% reduced</option>
                          <option value="0">0%</option>
                        </select>
                        <input data-tax-label form={saveForm} type="hidden" name={`tax_rate_label_${line.id}`} value={taxLabel(rate)} />
                        <input data-tax-id form={saveForm} type="hidden" name={`tax_rate_id_${line.id}`} value={taxId(rate)} />
                      </td>
                      <td className="p-2"><input form={saveForm} data-net name={`net_amount_gbp_${line.id}`} type="number" step="0.01" defaultValue={moneyInput(coding?.net_amount_gbp ?? preview.net)} disabled={!codable} className="w-24 rounded-lg border px-2 py-1 disabled:bg-slate-100" /></td>
                      <td className="p-2"><input form={saveForm} data-vat name={`vat_amount_gbp_${line.id}`} type="number" step="0.01" defaultValue={moneyInput(coding?.vat_amount_gbp ?? preview.vat)} disabled={!codable} className="w-24 rounded-lg border px-2 py-1 disabled:bg-slate-100" /></td>
                      <td className="p-2 font-semibold">{gbp(gross)}</td>
                      <td className="p-2"><input form={saveForm} type="checkbox" name={`admin_review_required_yn_${line.id}`} defaultChecked={Boolean(coding?.admin_review_required_yn)} disabled={!codable} /> <input form={saveForm} name={`review_reason_${line.id}`} defaultValue={coding?.review_reason ?? ""} disabled={!codable} className="mt-1 w-32 rounded-lg border px-2 py-1 disabled:bg-slate-100" placeholder="reason" /></td>
                      <td className="p-2">{coding?.coded_yn ? "coded" : codable ? "not coded" : "blocked"}</td>
                    </tr>
                  );
                })}

                {invoice ? <ManualAdjustmentRows orderId={orderId} invoiceId={invoice.id} adjustments={adjustments} /> : null}
              </tbody>
              <tfoot className="bg-slate-900 text-white">
                <tr>
                  <td className="p-2 font-semibold" colSpan={8}>Invoice OCR</td>
                  <td className="p-2 font-semibold">{gbp(invoiceNet)}</td>
                  <td className="p-2 font-semibold">{gbp(invoiceVat)}</td>
                  <td className="p-2 font-semibold">{gbp(acceptedGross)}</td>
                  <td className="p-2" colSpan={2}>Source: Mindee OCR header totals</td>
                </tr>
                <tr className="bg-slate-800">
                  <td className="p-2 font-semibold" colSpan={8}>Coded lines</td>
                  <td className="p-2 font-semibold">{gbp(codedNet)}</td>
                  <td className="p-2 font-semibold">{gbp(codedVat)}</td>
                  <td className="p-2 font-semibold">{gbp(codedGross)}</td>
                  <td className="p-2" colSpan={2}>Includes manual adjustment lines</td>
                </tr>
                <tr className={vatStatusOk ? "bg-emerald-900" : "bg-amber-900"}>
                  <td className="p-2 font-semibold" colSpan={8}>Variance</td>
                  <td className="p-2 font-semibold">{gbp(netVariance)}</td>
                  <td className="p-2 font-semibold">{gbp(vatVariance)}</td>
                  <td className="p-2 font-semibold">{gbp(grossVariance)}</td>
                  <td className="p-2" colSpan={2}>{vatStatusOk ? "Ready" : "Must reconcile before Sage draft"}</td>
                </tr>
              </tfoot>
            </table>
          </div>
        </section>
      </div>
    </main>
  );
}
