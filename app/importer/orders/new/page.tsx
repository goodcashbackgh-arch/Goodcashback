import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { createOrderAction } from "./actions";

export default async function NewOrderPage() {
  const supabase = await createClient();
  const [{data: categories},{data: retailers},{data: hubs}] = await Promise.all([
    supabase.from("markup_categories").select("id, category_name").order("category_name"),
    supabase.from("retailers").select("id, name").order("name"),
    supabase.from("hubs").select("id, name").order("name"),
  ]);

  return <main className="p-6 space-y-6">
    <Link href="/importer" className="text-sky-600">← Back</Link>
    <h1 className="text-2xl font-semibold">Create order</h1>
    <form action={createOrderAction} className="space-y-4 max-w-3xl">
      <input name="sop_version" defaultValue="v1" className="border p-2 w-full" placeholder="SOP version" />
      <select name="retailer_id" className="border p-2 w-full" required><option value="">Select retailer</option>{(retailers??[]).map((r)=> <option key={r.id} value={r.id}>{r.name}</option>)}</select>
      <select name="destination_hub_id" className="border p-2 w-full" required><option value="">Select hub</option>{(hubs??[]).map((h)=> <option key={h.id} value={h.id}>{h.name}</option>)}</select>
      {[0,1,2].map((i)=><div key={i} className="grid grid-cols-3 gap-2">
        <select name={`line_category_${i}`} className="border p-2"><option value="">Category</option>{(categories??[]).map((c)=> <option key={c.id} value={c.id}>{c.category_name}</option>)}</select>
        <input name={`line_qty_${i}`} type="number" min="0" className="border p-2" placeholder="Qty"/>
        <input name={`line_amount_${i}`} type="number" step="0.01" min="0" className="border p-2" placeholder="Amount GBP"/>
      </div>)}
      <input name="screenshot_url" className="border p-2 w-full" placeholder="Screenshot URL (optional)"/>
      <button className="rounded bg-sky-600 text-white px-4 py-2">Create order</button>
    </form>
  </main>
}
