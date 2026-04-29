import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { addTrackingSubmissionAction } from "./actions";
type CategoryLine = { id: string; qty: number; amount_inc_vat_gbp: number; markup_categories: { name: string } | null };
type ScreenshotRow = { id: string; screenshot_url: string };
type TrackingRow = { id: string; tracking_ref: string; is_final_delivery_yn: boolean | null; couriers: { name: string } | null };

export default async function OrderOperationsPage({params}:{params: Promise<{order_id:string}>}) {
  const {order_id:orderId} = await params;
  const supabase = await createClient();
  const [{data:order},{data:lines},{data:screenshots},{data:tracking},{data:funding},{data:invoices},{data:couriers},{data:disputes}] = await Promise.all([
    supabase.from("orders").select("*").eq("id",orderId).maybeSingle(),
    supabase.from("order_category_lines").select("*, markup_categories(name)").eq("order_id",orderId),
    supabase.from("order_screenshots").select("*").eq("order_id",orderId).order("display_order"),
    supabase.from("order_tracking_submissions").select("*, couriers(name)").eq("order_id",orderId).order("submitted_at",{ascending:false}),
    supabase.from("order_funding_position_vw").select("*").eq("order_id",orderId).maybeSingle(),
    supabase.from("supplier_invoices").select("id, invoice_ref").eq("order_id",orderId),
    supabase.from("couriers").select("id, name").order("name"),
    supabase.from("disputes").select("id").eq("replacement_child_order_id",orderId).maybeSingle(),
  ]);
  if (!order) return <main className="p-6">Order not found.</main>;

  return <main className="p-6 space-y-6">
    <Link href="/importer" className="text-sky-600">← Back</Link>
    <h1 className="text-2xl font-semibold">Order operations: {order.order_ref ?? orderId}</h1>
    {order.order_type === "replacement_child" ? <div className="rounded border p-3 bg-amber-50">Replacement child order {order.parent_order_id ? <Link className="underline" href={`/importer/orders/${order.parent_order_id}/operations`}>View parent</Link>:null} {disputes?.id ? <Link className="underline ml-2" href={`/importer/exceptions/${disputes.id}`}>View dispute</Link>:null}</div> : null}
    <section><h2 className="font-semibold">Summary</h2><p>Qty: {order.total_qty_declared} | Declared GBP: {order.order_total_gbp_declared}</p></section>
    <section><h2 className="font-semibold">Funding status</h2><pre className="text-xs bg-slate-100 p-2 rounded">{JSON.stringify(funding ?? {}, null, 2)}</pre></section>
    <section><h2 className="font-semibold">Category lines</h2><ul>{((lines??[]) as CategoryLine[]).map((line)=><li key={line.id}>{line.markup_categories?.name}: qty {line.qty}, GBP {line.amount_inc_vat_gbp}</li>)}</ul></section>
    <section><h2 className="font-semibold">Screenshots</h2><ul>{((screenshots??[]) as ScreenshotRow[]).map((s)=><li key={s.id}><a href={s.screenshot_url} className="underline" target="_blank">{s.screenshot_url}</a></li>)}</ul></section>
    <section className="space-y-2"><h2 className="font-semibold">Tracking submissions</h2>
      <form action={addTrackingSubmissionAction} className="grid md:grid-cols-2 gap-2 max-w-3xl">
        <input type="hidden" name="order_id" value={orderId} />
        <select name="courier_id" required className="border p-2"><option value="">Courier</option>{(couriers??[]).map((c)=> <option key={c.id} value={c.id}>{c.name}</option>)}</select>
        <input name="tracking_ref" required className="border p-2" placeholder="Tracking ref"/>
        <input name="tracking_date" type="date" required className="border p-2"/>
        <input name="tracking_screenshot_url" className="border p-2" placeholder="Tracking URL / screenshot URL"/>
        <input name="note" className="border p-2" placeholder="Note"/>
        <label className="text-sm"><input type="checkbox" name="is_final_delivery_yn" className="mr-2"/>This completes delivery for this order</label>
        <button className="rounded bg-sky-600 text-white px-4 py-2 w-fit">Add tracking</button>
      </form>
      <ul>{((tracking??[]) as TrackingRow[]).map((t)=><li key={t.id}>{t.couriers?.name} - {t.tracking_ref} {t.is_final_delivery_yn ? "(Final delivery)" : ""}</li>)}</ul>
    </section>
    <section><h2 className="font-semibold">Invoice / evidence</h2><ul>{(invoices??[]).map((i)=> <li key={i.id}>{i.invoice_ref} <Link className="underline ml-2" href={`/importer/reconciliation/${orderId}`}>Open reconciliation</Link></li>)}</ul></section>
  </main>
}
