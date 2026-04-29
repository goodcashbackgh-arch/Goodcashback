"use client";

import { useMemo, useState } from "react";

type Option = { id: string; name: string };
type Hub = { id: string; name: string; city?: string | null };
type Category = { id: string; category_name: string };

export default function OrderForm({
  retailers,
  hubs,
  categories,
  defaultHubId,
  defaultCategoryId,
  emptyMessages,
  action,
}: {
  retailers: Option[];
  hubs: Hub[];
  categories: Category[];
  defaultHubId: string;
  defaultCategoryId: string;
  emptyMessages: string[];
  action: (formData: FormData) => void;
}) {
  const [rows, setRows] = useState([{ key: crypto.randomUUID(), categoryId: defaultCategoryId, qty: "", amount: "" }]);

  const totals = useMemo(() => {
    return rows.reduce(
      (acc, row) => ({
        qty: acc.qty + (Number(row.qty) > 0 ? Number(row.qty) : 0),
        amount: acc.amount + (Number(row.amount) > 0 ? Number(row.amount) : 0),
      }),
      { qty: 0, amount: 0 },
    );
  }, [rows]);

  return (
    <form action={action} className="space-y-4 max-w-3xl" encType="multipart/form-data">
      {emptyMessages.length > 0 && <div className="rounded border border-amber-500 bg-amber-50 p-3 text-sm">{emptyMessages.join(" ")}</div>}
      <select name="retailer_id" className="border p-2 w-full" required disabled={retailers.length === 0}>
        <option value="">Select retailer</option>
        {retailers.map((r) => (
          <option key={r.id} value={r.id}>{r.name}</option>
        ))}
      </select>

      <select name="destination_hub_id" className="border p-2 w-full" required defaultValue={defaultHubId} disabled={hubs.length === 0 || hubs.length === 1}>
        <option value="">Select destination hub</option>
        {hubs.map((h) => (
          <option key={h.id} value={h.id}>{h.name}{h.city ? ` (${h.city})` : ""}</option>
        ))}
      </select>

      <input name="screenshots" type="file" accept="image/*" multiple required className="border p-2 w-full" />

      <div className="space-y-2">
        {rows.map((row) => (
          <div key={row.key} className="grid grid-cols-12 gap-2 items-center">
            <select className="border p-2 col-span-5" value={row.categoryId} required disabled={categories.length === 0}
              onChange={(e) => setRows((prev) => prev.map((r) => (r.key === row.key ? { ...r, categoryId: e.target.value } : r)))}>
              <option value="">Select category</option>
              {categories.map((c) => <option key={c.id} value={c.id}>{c.category_name}</option>)}
            </select>
            <input className="border p-2 col-span-2" type="number" min="1" step="1" placeholder="Qty" value={row.qty} required
              onChange={(e) => setRows((prev) => prev.map((r) => (r.key === row.key ? { ...r, qty: e.target.value } : r)))} />
            <input className="border p-2 col-span-3" type="number" min="0.01" step="0.01" placeholder="Amount GBP" value={row.amount} required
              onChange={(e) => setRows((prev) => prev.map((r) => (r.key === row.key ? { ...r, amount: e.target.value } : r)))} />
            <button type="button" className="col-span-2 border rounded p-2" disabled={rows.length === 1}
              onClick={() => setRows((prev) => prev.filter((r) => r.key !== row.key))}>Remove</button>
            <input type="hidden" name="line_category_id" value={row.categoryId} />
            <input type="hidden" name="line_qty" value={row.qty} />
            <input type="hidden" name="line_amount" value={row.amount} />
          </div>
        ))}
      </div>
      <button type="button" className="border rounded p-2" onClick={() => setRows((prev) => [...prev, { key: crypto.randomUUID(), categoryId: defaultCategoryId, qty: "", amount: "" }])}>Add category row</button>

      <p className="text-sm text-slate-700">Grand total: Qty {totals.qty} | GBP {totals.amount.toFixed(2)}</p>

      <div className="rounded border p-3 text-sm space-y-2">
        <p className="font-semibold">Product confirmation</p>
        <p>I confirm this order does not include children’s clothing, infant clothing, school uniform, or similar restricted items. If restricted items are found, the order may be rejected or refunded, and an admin charge may apply.</p>
        <label className="flex items-center gap-2"><input type="checkbox" name="product_confirmed" value="yes" required /> I confirm and accept</label>
      </div>

      <div className="rounded border p-3 text-sm space-y-1">
        <p className="font-semibold">Goods Pro Forma Estimate</p>
        <p>This estimate is based on the goods value you submitted. Shipping is excluded at this stage.</p>
        <p>Shipping will be quoted separately after the goods are received and checked by the shipper.</p>
      </div>
      <button className="rounded bg-sky-600 text-white px-4 py-2">Create order / Goods Pro Forma Estimate</button>
    </form>
  );
}
