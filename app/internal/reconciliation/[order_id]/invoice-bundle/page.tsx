import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

const retiredStatuses = new Set(["rejected_resubmit_required", "duplicate_blocked", "superseded"]);

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(value ?? 0));
}

export default async function SupervisorInvoiceBundlePage({ params }: { params: Promise<{ order_id: string }> }) {
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

  const [{ data: order }, { data: invoices }, { data: bundleSummary }] = await Promise.all([
    supabase.from("orders").select("id, order_ref, total_qty_declared, order_total_gbp_declared, retailers(name), importers(company_name)").eq("id", orderId).maybeSingle(),
    supabase.from("supplier_invoices").select("id, invoice_ref, ocr_invoice_ref, review_status, uploaded_at, ocr_invoice_total_gbp, blocked_from_sage_yn").eq("order_id", orderId).order("uploaded_at", { ascending: true }),
    supabase.from("order_supplier_invoice_bundle_summary_v1").select("*").eq("order_id", orderId).maybeSingle(),
  ]);

  if (!order) redirect("/internal?error=Order+not+found");
  const activeInvoices = (invoices ?? []).filter((invoice) => !retiredStatuses.has(String(invoice.review_status ?? "pending_review")));
  const invoiceIds = activeInvoices.map((invoice) => invoice.id);

  const { data: lineRows } = invoiceIds.length
    ? await supabase
        .from("supplier_invoice_lines")
        .select("supplier_invoice_id, eligible_for_invoice_yn")
        .in("supplier_invoice_id", invoiceIds)
    : { data: [] as Array<{ supplier_invoice_id: string; eligible_for_invoice_yn: string | null }> };

  const counts = new Map<string, { total: number; progressed: number }>();
  for (const row of lineRows ?? []) {
    const current = counts.get(row.supplier_invoice_id) ?? { total: 0, progressed: 0 };
    current.total += 1;
    if (["y", "yes", "true", "1"].includes(String(row.eligible_for_invoice_yn ?? "").toLowerCase())) current.progressed += 1;
    counts.set(row.supplier_invoice_id, current);
  }

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/supplier-draft-ready" className="text-sm font-semibold text-sky-700">← Back to supplier draft ready</Link>
          <p className="mt-6 text-sm font-semibold uppercase tracking-[0.2em] text-sky-600">Supervisor invoice bundle</p>
          <h1 className="mt-2 text-3xl font-semibold">Order {order.order_ref ?? orderId}</h1>
          <p className="mt-3 text-sm text-slate-600">Review each legal supplier invoice independently while controlling the order collectively.</p>
          <p className="mt-2 text-sm text-slate-500">{staff.full_name} · {staff.role_type}</p>
        </section>

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Active invoices</p><p className="mt-1 text-2xl font-semibold">{activeInvoices.length}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Declared order qty</p><p className="mt-1 text-2xl font-semibold">{Number(order.total_qty_declared ?? 0)}</p></div>
          <div className="rounded-2xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">Declared order value</p><p className="mt-1 text-2xl font-semibold">{gbp(order.order_total_gbp_declared)}</p></div>
          <div className={`rounded-2xl border p-4 ${bundleSummary?.baseline_accounted_for_yn ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase text-slate-500">Bundle baseline</p><p className="mt-1 text-xl font-semibold">{bundleSummary?.baseline_accounted_for_yn ? "Accounted" : "Open"}</p></div>
        </section>

        <section className="space-y-4">
          {activeInvoices.map((invoice) => {
            const count = counts.get(invoice.id) ?? { total: 0, progressed: 0 };
            return (
              <article key={invoice.id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                  <div>
                    <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Supplier invoice</p>
                    <h2 className="mt-1 text-xl font-semibold">{invoice.ocr_invoice_ref || invoice.invoice_ref}</h2>
                    <p className="mt-2 text-sm text-slate-600">Status {invoice.review_status ?? "pending_review"} · uploaded {invoice.uploaded_at ?? "—"}</p>
                    <p className="mt-1 text-sm text-slate-600">OCR total {gbp(invoice.ocr_invoice_total_gbp)} · lines {count.total} · progressed {count.progressed}</p>
                    <p className="mt-1 text-xs text-slate-500">Sage blocked: {invoice.blocked_from_sage_yn ? "Yes" : "No"}</p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Link href={`/internal/reconciliation/${orderId}/invoice-bundle/${invoice.id}`} className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Open exact invoice</Link>
                    <Link href="/internal/invoice-review" className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-800">Document review queue</Link>
                  </div>
                </div>
              </article>
            );
          })}
          {activeInvoices.length === 0 ? <p className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">No active supplier invoices are available for this order.</p> : null}
        </section>
      </div>
    </main>
  );
}
