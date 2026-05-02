import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { saveSupplierLineAccountingCodeAction } from "./actions";

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

type Screenshot = {
  id: string;
  screenshot_url: string;
  display_order: number | null;
  note: string | null;
};

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

function first<T>(value: T | T[] | null | undefined): T | null {
  if (!value) return null;
  return Array.isArray(value) ? value[0] ?? null : value;
}

function isProgressed(value: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes(String(value ?? "").toLowerCase());
}

function splitGross(grossValue: unknown, rateValue: unknown) {
  const gross = Number(grossValue ?? 0);
  const rate = Number(rateValue ?? 20);
  const net = Math.round((gross / (1 + rate / 100)) * 100) / 100;
  const vat = Math.round((gross - net) * 100) / 100;
  return { net, vat, gross, rate };
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
  const { data: codingRows } = lineIds.length
    ? await supabase
        .from("supplier_invoice_line_accounting_coding_vw")
        .select("supplier_invoice_line_id, posting_description, posting_sku, posting_size, sage_ledger_account_id, nominal_code, tax_rate_id, tax_rate_label, vat_rate_percent, net_amount_gbp, vat_amount_gbp, gross_amount_gbp, admin_review_required_yn, review_reason, coded_yn")
        .in("supplier_invoice_line_id", lineIds)
    : { data: [] as AccountingCode[] };

  const codingByLineId = new Map<string, AccountingCode>();
  for (const row of (codingRows ?? []) as AccountingCode[]) codingByLineId.set(row.supplier_invoice_line_id, row);

  const totalQty = invoiceLines.reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const totalValue = invoiceLines.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
  const codedGrossTotal = invoiceLines.reduce((sum, line) => sum + Number(codingByLineId.get(line.id)?.gross_amount_gbp ?? 0), 0);
  const screenshotsList = (screenshots ?? []) as Screenshot[];
  const retailer = first(order.retailers as { name: string | null } | { name: string | null }[] | null)?.name ?? "—";
  const importer = first(order.importers as { company_name: string | null } | { company_name: string | null }[] | null)?.company_name ?? "—";

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border bg-white p-6 shadow-sm">
          <Link href="/internal/supplier-draft-ready" className="text-sm font-semibold text-sky-700">← Back to supplier draft ready</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Supervisor reconciliation check</p>
          <h1 className="mt-2 text-3xl font-semibold">{order.order_ref ?? orderId}</h1>
          <p className="mt-2 text-sm text-slate-600">{staff.full_name} · {staff.role_type}</p>
          <p className="mt-2 text-sm text-slate-600">Importer: {importer} · Retailer: {retailer}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-5">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Declared qty</p><p className="text-2xl font-semibold">{order.total_qty_declared ?? 0}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Line qty</p><p className="text-2xl font-semibold">{totalQty}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">OCR gross</p><p className="text-2xl font-semibold">{gbp(invoice?.ocr_invoice_total_gbp ?? order.order_total_gbp_declared)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Line gross</p><p className="text-2xl font-semibold">{gbp(totalValue)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Coded gross</p><p className="text-2xl font-semibold">{gbp(codedGrossTotal)}</p></div>
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <article className="rounded-3xl border bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">Uploaded supplier invoice</h2>
            {invoice ? (
              <div className="mt-4 space-y-3 text-sm">
                <p>Operator ref: <strong>{invoice.invoice_ref}</strong></p>
                <p>OCR ref: <strong>{invoice.ocr_invoice_ref ?? "—"}</strong></p>
                <p>OCR retailer: <strong>{invoice.ocr_retailer_name ?? "—"}</strong></p>
                <p>OCR total: <strong>{invoice.ocr_invoice_total_gbp === null ? "—" : gbp(invoice.ocr_invoice_total_gbp)}</strong></p>
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
                  <a href={screenshot.screenshot_url} target="_blank" rel="noreferrer" className="mt-2 inline-block text-sm font-semibold text-sky-700 underline">Open full size</a>
                </details>
              ))}
            </div>
          </article>
        </section>

        <section className="rounded-3xl border bg-white p-5 shadow-sm">
          <h2 className="text-xl font-semibold">Supplier invoice line accounting coding</h2>
          <p className="mt-2 text-sm text-slate-600">Gross is locked to the approved OCR/reconciled line amount. VAT changes recalculate net and VAT; total still matches approved gross.</p>
          <div className="mt-4 space-y-4">
            {invoiceLines.map((line) => {
              const coding = codingByLineId.get(line.id);
              const gross = Number(line.amount_inc_vat_gbp ?? 0);
              const rate = coding?.vat_rate_percent ?? 20;
              const preview = splitGross(gross, rate);
              const progressed = isProgressed(line.eligible_for_invoice_yn);
              const formId = `coding-${line.id}`;
              return (
                <article key={line.id} className="rounded-2xl border bg-slate-50 p-4">
                  <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                    <h3 className="font-semibold">Line {line.line_order} · {line.line_source}</h3>
                    <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${progressed ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-900"}`}>{progressed ? "Progressed" : "Not progressed"}</span>
                  </div>

                  <div className="grid gap-3 lg:grid-cols-12">
                    <label className="space-y-1 text-sm lg:col-span-4"><span className="text-xs uppercase text-slate-500">Description override</span><input form={formId} name="description_override" defaultValue={coding?.posting_description ?? line.description} className="w-full rounded-xl border px-3 py-2" /></label>
                    <label className="space-y-1 text-sm lg:col-span-2"><span className="text-xs uppercase text-slate-500">SKU</span><input form={formId} name="sku_override" defaultValue={coding?.posting_sku ?? line.retailer_sku ?? ""} className="w-full rounded-xl border px-3 py-2" /></label>
                    <label className="space-y-1 text-sm lg:col-span-1"><span className="text-xs uppercase text-slate-500">Size</span><input form={formId} name="size_override" defaultValue={coding?.posting_size ?? line.size ?? ""} className="w-full rounded-xl border px-3 py-2" /></label>
                    <label className="space-y-1 text-sm lg:col-span-2"><span className="text-xs uppercase text-slate-500">Nominal / GL</span><input form={formId} name="nominal_code" defaultValue={coding?.nominal_code ?? ""} placeholder="e.g. 5000" className="w-full rounded-xl border px-3 py-2" /></label>
                    <label className="space-y-1 text-sm lg:col-span-3"><span className="text-xs uppercase text-slate-500">Sage ledger account id</span><input form={formId} name="sage_ledger_account_id" defaultValue={coding?.sage_ledger_account_id ?? ""} placeholder="Later from Sage sync" className="w-full rounded-xl border px-3 py-2" /></label>

                    <label className="space-y-1 text-sm lg:col-span-2"><span className="text-xs uppercase text-slate-500">VAT classification</span><select form={formId} name="vat_rate_percent" defaultValue={String(rate)} className="w-full rounded-xl border px-3 py-2"><option value="20">20% standard</option><option value="5">5% reduced</option><option value="0">0% zero/exempt</option></select></label>
                    <input form={formId} type="hidden" name="tax_rate_label" value={rate === 20 ? "20% standard" : rate === 5 ? "5% reduced" : "0% zero/exempt"} />
                    <input form={formId} type="hidden" name="tax_rate_id" value={rate === 20 ? "STANDARD_20" : rate === 5 ? "REDUCED_5" : "ZERO_0"} />
                    <div className="rounded-xl border bg-white p-3 text-sm lg:col-span-2"><p className="text-xs uppercase text-slate-500">Net</p><p className="font-semibold">{gbp(coding?.net_amount_gbp ?? preview.net)}</p></div>
                    <div className="rounded-xl border bg-white p-3 text-sm lg:col-span-2"><p className="text-xs uppercase text-slate-500">VAT</p><p className="font-semibold">{gbp(coding?.vat_amount_gbp ?? preview.vat)}</p></div>
                    <div className="rounded-xl border bg-white p-3 text-sm lg:col-span-2"><p className="text-xs uppercase text-slate-500">Gross locked</p><p className="font-semibold">{gbp(gross)}</p></div>
                    <label className="space-y-1 text-sm lg:col-span-2"><span className="text-xs uppercase text-slate-500">Review flag</span><div className="rounded-xl border bg-white px-3 py-2"><input form={formId} type="checkbox" name="admin_review_required_yn" defaultChecked={Boolean(coding?.admin_review_required_yn)} /> <span>Admin review</span></div></label>
                    <label className="space-y-1 text-sm lg:col-span-10"><span className="text-xs uppercase text-slate-500">Review reason</span><input form={formId} name="review_reason" defaultValue={coding?.review_reason ?? ""} placeholder="Reason if coding changes need admin attention" className="w-full rounded-xl border px-3 py-2" /></label>
                    <form id={formId} action={saveSupplierLineAccountingCodeAction} className="lg:col-span-12">
                      <input type="hidden" name="order_id" value={orderId} />
                      <input type="hidden" name="supplier_invoice_line_id" value={line.id} />
                      <button disabled={!progressed} className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white disabled:cursor-not-allowed disabled:bg-slate-400">Save coding</button>
                      <span className="ml-3 text-sm text-slate-600">{coding?.coded_yn ? "Coded" : "Not coded yet"}</span>
                    </form>
                  </div>
                </article>
              );
            })}
          </div>
        </section>
      </div>
    </main>
  );
}
