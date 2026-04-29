import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { createOrderAction } from "./actions";

export default async function NewOrderPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return <main className="p-6">Please sign in.</main>;

  const { data: operator } = await supabase.from("operators").select("id").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  const { data: operatorImporter } = operator
    ? await supabase.from("operator_importers").select("importer_id").eq("operator_id", operator.id).is("revoked_at", null).limit(1).maybeSingle()
    : { data: null };
  const { data: importer } = operatorImporter?.importer_id
    ? await supabase.from("importers").select("shipper_id").eq("id", operatorImporter.importer_id).maybeSingle()
    : { data: null };
  const { data: shipper } = importer?.shipper_id
    ? await supabase.from("shippers").select("id, legal_name, trading_name, primary_hub_id").eq("id", importer.shipper_id).maybeSingle()
    : { data: null };
  const { data: hub } = shipper?.primary_hub_id
    ? await supabase.from("hubs").select("id, name, city").eq("id", shipper.primary_hub_id).maybeSingle()
    : { data: null };
  const { data: retailers } = await supabase.from("retailers").select("id, name").order("name");

  return <main className="p-6 space-y-6">
    <Link href="/importer" className="text-sky-600">← Back</Link>
    <h1 className="text-2xl font-semibold">Create order</h1>
    <form action={createOrderAction} className="space-y-4 max-w-3xl" encType="multipart/form-data">
      <select name="retailer_id" className="border p-2 w-full" required><option value="">Select retailer</option>{(retailers ?? []).map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}</select>
      <div className="rounded border p-3 text-sm">
        <p><strong>Assigned shipper:</strong> {shipper?.trading_name ?? shipper?.legal_name ?? "Not assigned"}</p>
        <p><strong>Assigned destination hub/city:</strong> {hub ? `${hub.name}${hub.city ? ` (${hub.city})` : ""}` : "Not assigned"}</p>
      </div>
      <input name="screenshots" type="file" accept="image/*" multiple required className="border p-2 w-full" />
      <div className="grid grid-cols-2 gap-2">
        <input name="line_qty" type="number" min="1" step="1" className="border p-2" placeholder="Qty" required />
        <input name="line_amount" type="number" step="0.01" min="0.01" className="border p-2" placeholder="Total GBP" required />
      </div>
      <p className="text-sm text-slate-700">Grand total: auto-calculated from the goods row.</p>
      <div className="rounded border p-3 text-sm space-y-2">
        <p className="font-semibold">Product confirmation</p>
        <p>I confirm this order does not include children’s clothing, infant clothing, school uniform, or similar restricted items. If restricted items are found, the order may be rejected or refunded, and an admin charge may apply.</p>
        <label className="flex items-center gap-2"><input type="checkbox" name="product_confirmed" value="yes" required /> I confirm and accept</label>
      </div>
      <div className="rounded border p-3 text-sm space-y-1">
        <p className="font-semibold">Pro Forma Quote</p>
        <p>This estimate is based on the goods value you submitted. Shipping is not included at this stage.</p>
        <p>Shipping will be quoted separately after the goods are received, checked, and assessed by the shipper.</p>
      </div>
      <button className="rounded bg-sky-600 text-white px-4 py-2">Create order / Pro Forma Quote</button>
    </form>
  </main>;
}
