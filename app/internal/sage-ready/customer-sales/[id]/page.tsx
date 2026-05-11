import Link from "next/link";
import { redirect, notFound } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

function n(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(n(value));
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

export default async function CustomerSalesSageReadyDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const { data: invoice, error } = await supabase
    .from("sales_invoices")
    .select("id, order_id, invoice_type, amount_gbp, vat_code, sage_status, sage_invoice_id, sage_posted_at, consideration_received_date, sage_invoice_date, zero_rating_deadline_date, zero_rating_status, line_items_json, created_at, orders(order_ref, importers(company_name, trading_name))")
    .eq("id", id)
    .maybeSingle();

  if (error) throw new Error(error.message);
  if (!invoice) notFound();

  const payload = (invoice.line_items_json ?? {}) as any;
  const lines = Array.isArray(payload.lines) ? payload.lines : [];
  const header = payload.sage_header ?? {};
  const tax = payload.tax_resolution ?? {};
  const draftControl = payload.draft_control ?? {};
  const order = Array.isArray((invoice as any).orders) ? (invoice as any).orders[0] : (invoice as any).orders;
  const importer = Array.isArray(order?.importers) ? order.importers[0] : order?.importers;
  const isLegacyMarkedPosted = invoice.sage_status === "posted" && !invoice.sage_invoice_id && !invoice.sage_posted_at;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-5xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap gap-3 text-sm font-semibold text-sky-700">
            <Link href="/internal/sage-ready">← Ready for Sage queue</Link>
            <Link href="/internal/shipping-control/customer-invoice-release">Customer invoice release queue</Link>
          </div>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Goodcashback Internal</p>
          <h1 className="mt-2 text-2xl font-semibold tracking-tight sm:text-3xl">Customer sales invoice draft detail</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">Read-only inspection of the internal sales invoice row before any Sage posting action is built. This page does not post to Sage or mark anything posted.</p>
          {isLegacyMarkedPosted ? <p className="mt-4 rounded-xl border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">This legacy/test row is internally marked posted, but has no Sage confirmation id or posted timestamp.</p> : null}
        </section>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice type</p><p className="mt-1 text-xl font-semibold">{friendly(invoice.invoice_type)}</p></div>
          <div className="rounded-3xl border border-emerald-200 bg-emerald-50 p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-emerald-700">Amount</p><p className="mt-1 text-xl font-semibold">{money(invoice.amount_gbp)}</p></div>
          <div className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-xs uppercase tracking-wide text-slate-500">Sage status</p><p className="mt-1 text-xl font-semibold">{friendly(invoice.sage_status)}</p></div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Header basis</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-2">
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Sage reference</p><p className="mt-1 font-semibold">{header.reference ?? order?.order_ref ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Sage notes</p><p className="mt-1 font-semibold">{header.notes ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Order ref</p><p className="mt-1 font-semibold">{order?.order_ref ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Customer/importer</p><p className="mt-1 font-semibold">{importer?.trading_name || importer?.company_name || "—"}</p></div>
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Line payload</h2>
          <p className="mt-2 text-sm text-slate-600">This is the bundled customer-facing sale line shape stored in sales_invoices.line_items_json.</p>
          <div className="mt-4 space-y-3">
            {lines.length === 0 ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">No line payload found.</p> : null}
            {lines.map((line: any, index: number) => (
              <div key={`${index}-${line.description ?? "line"}`} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                <p className="font-semibold">{line.description ?? `Line ${index + 1}`}</p>
                <div className="mt-3 grid grid-cols-2 gap-2 text-sm md:grid-cols-4">
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Qty</p><p className="mt-1 font-semibold">{line.quantity ?? line.released_qty ?? "—"}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Unit</p><p className="mt-1 font-semibold">{money(line.unit_price_gbp)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Total</p><p className="mt-1 font-semibold">{money(line.total_line_amount_gbp)}</p></div>
                  <div className="rounded-xl bg-white p-3"><p className="text-xs uppercase tracking-wide text-slate-500">Ledger role</p><p className="mt-1 font-semibold">{friendly(line.ledger_account_role)}</p></div>
                </div>
              </div>
            ))}
          </div>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <h2 className="text-xl font-semibold">Tax and posting control</h2>
          <div className="mt-4 grid gap-3 md:grid-cols-2">
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Display VAT treatment</p><p className="mt-1 font-semibold">{tax.display_vat_code ?? invoice.vat_code ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Sage tax rate id</p><p className="mt-1 font-semibold">{tax.sage_tax_rate_id ?? "Not resolved"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Sage invoice id</p><p className="mt-1 font-semibold">{invoice.sage_invoice_id ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Sage posted at</p><p className="mt-1 font-semibold">{invoice.sage_posted_at ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Zero-rating deadline</p><p className="mt-1 font-semibold">{invoice.zero_rating_deadline_date ?? "—"}</p></div>
            <div className="rounded-2xl bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Draft control</p><p className="mt-1 font-semibold">{draftControl.status ?? "—"}</p></div>
          </div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
          <h2 className="font-semibold">Control rule</h2>
          <p className="mt-2">This detail page is inspection-only. Sage posting, tax-rate mapping, idempotency keys, API response capture and posted-status updates remain separate controlled builds.</p>
        </section>
      </div>
    </main>
  );
}
