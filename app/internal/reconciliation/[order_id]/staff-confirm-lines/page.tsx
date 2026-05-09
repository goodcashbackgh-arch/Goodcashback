import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { supervisorProgressSupplierInvoiceLinesAction } from "../actions";

function isDone(v: string | null | undefined) {
  return ["y", "yes", "true", "1"].includes(String(v ?? "").toLowerCase());
}

function gbp(v: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number(v ?? 0));
}

export default async function Page({ params }: { params: Promise<{ order_id: string }> }) {
  const { order_id: orderId } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data: order } = await supabase
    .from("orders")
    .select("id, order_ref, total_qty_declared, order_total_gbp_declared")
    .eq("id", orderId)
    .maybeSingle();
  if (!order) redirect("/internal/supplier-draft-ready?error=Order+not+found");

  const { data: invoice } = await supabase
    .from("supplier_invoices")
    .select("id, invoice_ref, is_current_for_order, uploaded_at")
    .eq("order_id", orderId)
    .order("uploaded_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: lines } = invoice?.id
    ? await supabase
        .from("supplier_invoice_lines")
        .select("id, line_order, line_source, retailer_sku, description, qty, size, amount_inc_vat_gbp, eligible_for_invoice_yn")
        .eq("supplier_invoice_id", invoice.id)
        .order("line_order", { ascending: true })
    : { data: [] };

  const candidates = (lines ?? []).filter((line) => !isDone(line.eligible_for_invoice_yn));

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-4xl space-y-6">
        <section className="rounded-3xl border bg-white p-6 shadow-sm">
          <Link href={`/internal/reconciliation/${orderId}`} className="text-sm font-semibold text-sky-700">← Back to reconciliation</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-amber-600">Staff takeover</p>
          <h1 className="mt-2 text-3xl font-semibold">{order.order_ref ?? orderId}</h1>
          <p className="mt-2 text-sm text-slate-600">Invoice {invoice?.invoice_ref ?? "—"} · Declared {order.total_qty_declared ?? 0} / {gbp(order.order_total_gbp_declared)}</p>
          <p className="mt-1 text-sm text-slate-600">{staff.full_name} · {staff.role_type}</p>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-6 shadow-sm">
          <h2 className="text-xl font-semibold">Confirm clean invoice lines</h2>
          <p className="mt-2 text-sm text-amber-900">Use this only after checking the invoice against order evidence. Confirmed lines return to the normal accounting coding grid. This does not approve the invoice.</p>

          {!invoice ? <p className="mt-4 rounded-xl bg-white p-4 text-sm">No supplier invoice found.</p> : null}
          {invoice?.is_current_for_order ? <p className="mt-4 rounded-xl bg-white p-4 text-sm">This invoice is already current.</p> : null}
          {invoice && !invoice.is_current_for_order && candidates.length === 0 ? <p className="mt-4 rounded-xl bg-white p-4 text-sm">No unconfirmed lines remain.</p> : null}

          {invoice && !invoice.is_current_for_order && candidates.length > 0 ? (
            <form action={supervisorProgressSupplierInvoiceLinesAction} className="mt-5 space-y-4">
              <input type="hidden" name="order_id" value={orderId} />
              <input type="hidden" name="supplier_invoice_id" value={invoice.id} />
              <div className="space-y-3">
                {candidates.map((line) => (
                  <label key={line.id} className="flex gap-3 rounded-2xl border bg-white p-4 text-sm">
                    <input type="checkbox" name="line_ids" value={line.id} className="mt-1" />
                    <span>
                      <span className="block font-semibold">Line {line.line_order ?? "—"} · {line.line_source ?? "—"}</span>
                      <span className="block">{line.description || "No description"}</span>
                      <span className="block text-slate-600">Qty {line.qty ?? 0} · {gbp(line.amount_inc_vat_gbp)}{line.retailer_sku ? ` · SKU ${line.retailer_sku}` : ""}{line.size ? ` · Size ${line.size}` : ""}</span>
                    </span>
                  </label>
                ))}
              </div>
              <textarea name="progress_notes" rows={3} className="w-full rounded-xl border px-3 py-2 text-sm" placeholder="Staff confirmation note" />
              <button className="rounded-xl bg-amber-700 px-4 py-2 text-sm font-semibold text-white">Confirm selected lines</button>
            </form>
          ) : null}
        </section>
      </div>
    </main>
  );
}
