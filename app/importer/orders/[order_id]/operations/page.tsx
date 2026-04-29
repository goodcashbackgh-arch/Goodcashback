import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { addTrackingSubmissionAction, submitInvoiceEvidenceAction } from "./actions";

type ScreenshotRow = { id: string; screenshot_url: string };
type TrackingRow = { id: string; tracking_ref: string; is_final_delivery_yn: boolean | null; couriers: { name: string } | null };

export default async function OrderOperationsPage({params,searchParams}:{params: Promise<{order_id:string}>, searchParams: Promise<{success?:string;order_ref?:string;auth_ref?:string;error?:string}>}) {
  const {order_id:orderId} = await params;
  const qp = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return <main className="p-6">Please sign in.</main>;
  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!operator) return <main className="p-6">Operator account required.</main>;

  const [{data:order},{data:screenshots},{data:tracking},{data:funding},{data:invoices},{data:couriers}] = await Promise.all([
    supabase.from("orders").select("*").eq("id",orderId).maybeSingle(),
    supabase.from("order_screenshots").select("*").eq("order_id",orderId).order("display_order"),
    supabase.from("order_tracking_submissions").select("*, couriers(name)").eq("order_id",orderId).order("submitted_at",{ascending:false}),
    supabase.from("order_funding_position_vw").select("*").eq("order_id",orderId).maybeSingle(),
    supabase.from("supplier_invoices").select("id, invoice_ref").eq("order_id",orderId),
    supabase.from("couriers").select("id, name").order("name"),
  ]);

  if (!order) return <main className="p-6">Order not found.</main>;
  const finalTrackingExists = ((tracking ?? []) as TrackingRow[]).some((t) => t.is_final_delivery_yn);

  return <main className="p-6 space-y-6">
    <Link href="/importer" className="text-sky-600">← Back</Link>
    <h1 className="text-2xl font-semibold">Order operations: {order.order_ref ?? orderId}</h1>

    {qp.error && <div className="rounded border border-red-300 bg-red-50 p-3 text-sm text-red-700">{qp.error}</div>}
    {qp.success && <div className="rounded border border-emerald-300 bg-emerald-50 p-3 text-sm">
      <p className="font-semibold">{qp.success}</p>
      <p>This estimate is based on the goods value you submitted. Shipping is not included at this stage.</p>
    </div>}

    <section><h2 className="font-semibold">Summary</h2><p>Qty: {order.total_qty_declared} | GBP: {order.order_total_gbp_declared}</p></section>

    <section><h2 className="font-semibold">Funding</h2><pre className="text-xs bg-slate-100 p-2 rounded overflow-x-auto">{JSON.stringify(funding ?? {}, null, 2)}</pre></section>

    <section>
      <h2 className="font-semibold">Screenshots</h2>
      <div className="flex gap-3 flex-wrap">
        {((screenshots??[]) as ScreenshotRow[]).map((s)=> (
          <a key={s.id} href={s.screenshot_url} target="_blank" className="block rounded border bg-white p-1">
            <img src={s.screenshot_url} alt="Order screenshot" style={{ width: 160, height: 120, objectFit: "contain" }} />
          </a>
        ))}
      </div>
    </section>

    <section id="tracking" className="space-y-2 rounded border p-4">
      <h2 className="font-semibold">Tracking</h2>
      {finalTrackingExists ? <p className="text-sm text-amber-700">Final delivery has already been marked. Add more tracking only if this was done in error.</p> : null}
      <form action={addTrackingSubmissionAction} className="grid gap-2 md:grid-cols-2">
        <input type="hidden" name="order_id" value={orderId} />
        <select name="courier_id" required className="border p-2">
          <option value="">Courier</option>
          {(couriers??[]).map(c=> <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
        <input name="tracking_ref" required className="border p-2" placeholder="Tracking ref"/>
        <input name="tracking_date" type="date" required className="border p-2"/>
        <input name="tracking_screenshot_url" className="border p-2" placeholder="Tracking URL / evidence link"/>
        <input name="note" className="border p-2" placeholder="Note"/>
        <label className="text-sm flex items-center gap-2"><input type="checkbox" name="is_final_delivery_yn"/>This completes delivery for this order</label>
        <button className="bg-sky-600 text-white px-4 py-2 rounded w-fit">Add tracking</button>
      </form>
      <ul className="space-y-1 text-sm">
        {((tracking??[]) as TrackingRow[]).map(t=> (
          <li key={t.id} className="rounded bg-slate-50 p-2">{t.couriers?.name ?? "Courier"} — {t.tracking_ref} {t.is_final_delivery_yn ? "(Final delivery)" : ""}</li>
        ))}
      </ul>
    </section>

    <section id="invoice" className="space-y-2 rounded border p-4">
      <h2 className="font-semibold">Invoice / evidence</h2>
      <form action={submitInvoiceEvidenceAction} className="grid gap-2 md:grid-cols-3">
        <input type="hidden" name="order_id" value={orderId} />
        <input name="invoice_ref" placeholder="Invoice ref" className="border p-2" required />
        <input name="invoice_file" type="file" accept=".pdf,image/*,.png,.jpg,.jpeg,.webp" className="border p-2" required />
        <button className="bg-green-600 text-white px-4 py-2 rounded w-fit">Upload invoice</button>
      </form>
      <ul className="space-y-1 text-sm">
        {(invoices??[]).map(i=> (
          <li key={i.id} className="rounded bg-slate-50 p-2">{i.invoice_ref} <Link className="ml-2 text-sky-700 underline" href={`/importer/reconciliation/${orderId}`}>Reconcile</Link></li>
        ))}
      </ul>
    </section>
  </main>
}
