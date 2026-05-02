import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

export default async function InternalReconciliationPage({ params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
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
  const totalQty = invoiceLines.reduce((sum, line) => sum + Number(line.qty ?? 0), 0);
  const totalValue = invoiceLines.reduce((sum, line) => sum + Number(line.amount_inc_vat_gbp ?? 0), 0);
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
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Declared qty</p><p className="text-2xl font-semibold">{order.total_qty_declared ?? 0}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Line qty</p><p className="text-2xl font-semibold">{totalQty}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Declared value</p><p className="text-2xl font-semibold">{gbp(order.order_total_gbp_declared)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Line value</p><p className="text-2xl font-semibold">{gbp(totalValue)}</p></div>
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
          <h2 className="text-xl font-semibold">Supplier invoice lines</h2>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full min-w-[900px] text-left text-sm">
              <thead className="bg-slate-100 text-xs uppercase text-slate-500">
                <tr>
                  <th className="p-3">Line</th>
                  <th className="p-3">Source</th>
                  <th className="p-3">Description</th>
                  <th className="p-3">SKU</th>
                  <th className="p-3">Size</th>
                  <th className="p-3">Qty</th>
                  <th className="p-3">Gross</th>
                  <th className="p-3">Progressed</th>
                  <th className="p-3">Next GL/VAT</th>
                </tr>
              </thead>
              <tbody>
                {invoiceLines.map((line) => (
                  <tr key={line.id} className="border-b">
                    <td className="p-3">{line.line_order}</td>
                    <td className="p-3">{line.line_source}</td>
                    <td className="p-3 font-medium">{line.description}</td>
                    <td className="p-3">{line.retailer_sku ?? "—"}</td>
                    <td className="p-3">{line.size ?? "—"}</td>
                    <td className="p-3">{line.qty ?? 0}</td>
                    <td className="p-3">{gbp(line.amount_inc_vat_gbp)}</td>
                    <td className="p-3">{isProgressed(line.eligible_for_invoice_yn) ? "Yes" : "No"}</td>
                    <td className="p-3 text-slate-500">coming next</td>
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
