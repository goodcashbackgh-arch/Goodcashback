import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { approveOrderValueAdjustmentAction, rejectOrderValueAdjustmentAction } from "./actions";

type SearchParams = { success?: string; error?: string };

type AdjustmentRow = {
  id: string;
  order_id: string;
  supplier_invoice_id: string | null;
  adjustment_type: string;
  amount_gbp: number;
  approval_status: string;
  requires_supervisor_approval: boolean;
  notes: string | null;
  created_at: string;
  orders: { order_ref: string | null; order_total_gbp_declared: number | null; importers: { company_name: string | null } | null } | null;
  supplier_invoices: { invoice_ref: string | null; invoice_pdf_url: string | null } | null;
};

function gbp(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "GBP",
    minimumFractionDigits: 2,
  }).format(Number(value ?? 0));
}

function label(type: string) {
  if (type === "retailer_delivery") return "Retailer delivery";
  if (type === "retailer_discount") return "Retailer discount";
  return type;
}

export default async function InternalAdjustmentsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const qp = await searchParams;
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data, error } = await supabase
    .from("order_value_adjustments")
    .select("id, order_id, supplier_invoice_id, adjustment_type, amount_gbp, approval_status, requires_supervisor_approval, notes, created_at, orders(order_ref, order_total_gbp_declared, importers(company_name)), supplier_invoices(invoice_ref, invoice_pdf_url)")
    .eq("approval_status", "pending_supervisor")
    .order("created_at", { ascending: true });

  const adjustments = (data ?? []) as unknown as AdjustmentRow[];

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto flex max-w-7xl flex-col gap-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal" className="text-sm font-semibold text-sky-600">← Back to internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Supervisor queue</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">Delivery / discount adjustments</h1>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-slate-600">
            Review pending retailer discounts and over-limit delivery charges before final invoice drafting. These are financial adjustments only; they do not change progressed item-line reconciliation or shipper-visible goods.
          </p>
          <p className="mt-2 text-sm text-slate-600">Signed in as: {staff.full_name} · {staff.role_type}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        {error ? (
          <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5 text-sm text-rose-800">Failed to load adjustments: {error.message}</section>
        ) : adjustments.length === 0 ? (
          <section className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm text-emerald-800">No pending adjustments.</section>
        ) : (
          <section className="grid gap-4">
            {adjustments.map((adjustment) => (
              <article key={adjustment.id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div>
                    <h2 className="text-xl font-semibold">{label(adjustment.adjustment_type)} · {gbp(adjustment.amount_gbp)}</h2>
                    <p className="mt-1 text-sm text-slate-600">Order {adjustment.orders?.order_ref ?? adjustment.order_id}</p>
                    <p className="text-sm text-slate-600">Importer: {adjustment.orders?.importers?.company_name ?? "—"}</p>
                    <p className="text-sm text-slate-600">Original goods amount: {gbp(adjustment.orders?.order_total_gbp_declared)}</p>
                    <p className="text-sm text-slate-600">Invoice ref: {adjustment.supplier_invoices?.invoice_ref ?? "—"}</p>
                    {adjustment.notes ? <p className="mt-2 rounded-xl bg-slate-50 px-3 py-2 text-sm text-slate-700">{adjustment.notes}</p> : null}
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Link href={`/internal/evidence/${adjustment.order_id}`} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-semibold text-slate-800 hover:bg-slate-50">Open staff order detail</Link>
                    <Link href={`/internal/evidence/${adjustment.order_id}#reconciliation`} className="rounded-xl border border-sky-300 bg-sky-50 px-3 py-2 text-sm font-semibold text-sky-800 hover:bg-sky-100">Open staff reconciliation detail</Link>
                    {adjustment.supplier_invoices?.invoice_pdf_url ? <a href={adjustment.supplier_invoices.invoice_pdf_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-900 px-3 py-2 text-sm font-semibold text-white">Open invoice</a> : null}
                  </div>
                </div>
                <div className="mt-4 grid gap-3 md:grid-cols-[auto_1fr_auto] md:items-end">
                  <form action={approveOrderValueAdjustmentAction}>
                    <input type="hidden" name="adjustment_id" value={adjustment.id} />
                    <button className="rounded-xl bg-emerald-700 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-600">Approve</button>
                  </form>
                  <form action={rejectOrderValueAdjustmentAction} className="grid gap-2 md:grid-cols-[1fr_auto]">
                    <input type="hidden" name="adjustment_id" value={adjustment.id} />
                    <input name="note" className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Optional rejection note" />
                    <button className="rounded-xl border border-rose-300 bg-rose-50 px-4 py-2 text-sm font-semibold text-rose-800 hover:bg-rose-100">Reject</button>
                  </form>
                </div>
              </article>
            ))}
          </section>
        )}
      </div>
    </main>
  );
}
