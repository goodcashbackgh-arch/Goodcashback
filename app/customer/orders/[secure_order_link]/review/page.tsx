import { createClient } from "@/utils/supabase/server";
import { submitCustomerHoldRequestAction } from "./actions";

type LineRow = {
  id: string;
  description?: string | null;
  size?: string | null;
  retailer_sku?: unknown;
  qty?: number | string | null;
  amount_inc_vat_gbp?: number | string | null;
};

type HoldRow = {
  id: string;
  requested_scope?: string | null;
  supplier_invoice_line_id?: string | null;
  status?: string | null;
  reason?: string | null;
  supervisor_review_note?: string | null;
};

type ReviewPayload = {
  order?: {
    id?: string | null;
    order_ref?: string | null;
    retailer_name?: string | null;
    total_qty_declared?: number | string | null;
  };
  tracking?: { id: string }[];
  lines?: LineRow[];
  holds?: HoldRow[];
};

function money(value: number | string | null | undefined) {
  const parsed = Number(value ?? 0);
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(Number.isFinite(parsed) ? parsed : 0);
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function safeText(value: unknown) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.toLowerCase() === "[object object]") return null;
  return trimmed;
}

function statusClass(status: string | null | undefined) {
  if (status === "supervisor_approved") return "bg-amber-100 text-amber-900 ring-amber-200";
  if (status === "requested") return "bg-sky-100 text-sky-900 ring-sky-200";
  if (status === "rejected") return "bg-rose-100 text-rose-900 ring-rose-200";
  if (["resolved", "converted_to_exception", "superseded"].includes(String(status ?? ""))) return "bg-emerald-100 text-emerald-900 ring-emerald-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function holdsForLine(holds: HoldRow[], lineId: string) {
  return holds.filter((hold) => hold.supplier_invoice_line_id === lineId);
}

function LineSummary({ line }: { line: LineRow }) {
  const size = safeText(line.size);
  const sku = safeText(line.retailer_sku);
  return (
    <div>
      <p className="font-black text-slate-950">{line.description ?? "Item"}</p>
      <p className="mt-1 text-sm text-slate-600">Qty {line.qty ?? "—"} · {money(line.amount_inc_vat_gbp)}</p>
      {size || sku ? <p className="mt-1 text-xs text-slate-500">{size ? `Size ${size}` : ""}{size && sku ? " · " : ""}{sku ? `SKU ${sku}` : ""}</p> : null}
    </div>
  );
}

export default async function CustomerOrderReviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ secure_order_link: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { secure_order_link: secureToken } = await params;
  const query = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data, error } = await (supabase as any).rpc("customer_pre_shipment_hold_review_v1", {
    p_secure_token: secureToken,
  });

  if (error) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-10 text-slate-950">
        <section className="mx-auto max-w-2xl rounded-3xl border border-rose-200 bg-white p-6 shadow-sm">
          <p className="text-sm font-semibold uppercase tracking-[0.2em] text-rose-500">Goodcashback</p>
          <h1 className="mt-2 text-2xl font-semibold">This review link is not available</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">{error.message}</p>
        </section>
      </main>
    );
  }

  const payload = (data ?? {}) as ReviewPayload;
  const order = payload.order ?? {};
  const lines = payload.lines ?? [];
  const holds = payload.holds ?? [];
  const orderHolds = holds.filter((hold) => hold.requested_scope === "order");

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 text-slate-950 md:p-6">
      <div className="mx-auto max-w-5xl space-y-5">
        <header className="overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
          <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
          <div className="p-5 md:p-7">
            <p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Goodcashback customer review</p>
            <h1 className="mt-2 text-3xl font-black tracking-tight md:text-5xl">Review before shipment</h1>
            <p className="mt-2 text-sm text-slate-600">Order {order.order_ref ?? order.id ?? "—"} · {order.retailer_name ?? "Retailer"}</p>
            <p className="mt-4 max-w-3xl text-sm leading-6 text-slate-700">
              Review the items recorded for this order. If you no longer want an item, request a hold before shipment. Internal retailer invoices and retailer-to-warehouse tracking are intentionally hidden.
            </p>
            {query.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-800">{query.success}</p> : null}
            {query.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800">{query.error}</p> : null}
          </div>
        </header>

        <section className="grid gap-4 md:grid-cols-3">
          <div className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm font-semibold text-slate-500">Order qty</p><p className="mt-2 text-3xl font-black">{order.total_qty_declared ?? lines.length}</p></div>
          <div className="rounded-[1.5rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm"><p className="text-sm font-semibold text-cyan-700">Items shown</p><p className="mt-2 text-3xl font-black text-cyan-950">{lines.length}</p></div>
          <div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-5 shadow-sm"><p className="text-sm font-semibold text-amber-700">Hold requests</p><p className="mt-2 text-3xl font-black text-amber-950">{holds.length}</p></div>
        </section>

        <section className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-black">Hold the whole order</h2>
          <p className="mt-1 text-sm text-slate-600">Use this only if the full order should pause before shipment.</p>
          <form action={submitCustomerHoldRequestAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_auto]">
            <input type="hidden" name="secure_token" value={secureToken} />
            <input type="hidden" name="requested_scope" value="order" />
            <input name="reason" required className="rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Reason, e.g. please pause this order before shipping" />
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-black text-white">Request order hold</button>
          </form>
          {orderHolds.length > 0 ? <div className="mt-3 flex flex-wrap gap-2">{orderHolds.map((hold) => <span key={hold.id} className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${statusClass(hold.status)}`}>{friendly(hold.status)}</span>)}</div> : null}
        </section>

        <section className="overflow-hidden rounded-[1.75rem] border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 bg-slate-50/70 p-5">
            <h2 className="text-xl font-black">Items in this review</h2>
            <p className="mt-1 text-sm text-slate-600">Select only items you no longer want shipped or included in the final invoice.</p>
          </div>
          <div className="grid gap-4 p-5">
            {lines.length === 0 ? <p className="rounded-xl bg-slate-50 p-4 text-sm text-slate-600">No item lines are available for review yet.</p> : null}
            {lines.map((line) => {
              const lineHolds = holdsForLine(holds, line.id);
              return (
                <article key={line.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                    <LineSummary line={line} />
                    <div className="flex flex-wrap gap-2">
                      {lineHolds.length === 0 ? <span className="rounded-full bg-emerald-50 px-3 py-1 text-xs font-bold text-emerald-700 ring-1 ring-emerald-200">No hold requested</span> : null}
                      {lineHolds.map((hold) => <span key={hold.id} className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${statusClass(hold.status)}`}>{friendly(hold.status)}</span>)}
                    </div>
                  </div>
                  <form action={submitCustomerHoldRequestAction} className="mt-4 grid gap-3 md:grid-cols-[1fr_auto]">
                    <input type="hidden" name="secure_token" value={secureToken} />
                    <input type="hidden" name="requested_scope" value="line" />
                    <input type="hidden" name="supplier_invoice_line_id" value={line.id} />
                    <input name="reason" required className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm" placeholder="Reason, e.g. I no longer want this item" />
                    <button className="rounded-xl bg-sky-600 px-4 py-2 text-sm font-black text-white">Request hold</button>
                  </form>
                </article>
              );
            })}
          </div>
        </section>

        <section className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-black">Hold request history</h2>
          {holds.length === 0 ? <p className="mt-3 rounded-xl bg-slate-50 p-4 text-sm text-slate-600">No hold requests submitted through this link yet.</p> : null}
          <div className="mt-4 grid gap-3">
            {holds.map((hold) => (
              <article key={hold.id} className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="font-black">{friendly(hold.requested_scope)} hold</p>
                  <span className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${statusClass(hold.status)}`}>{friendly(hold.status)}</span>
                </div>
                <p className="mt-2 text-slate-700">{hold.reason}</p>
                {hold.supervisor_review_note ? <p className="mt-2 rounded-xl bg-white p-3 text-slate-700"><span className="font-semibold">Review note:</span> {hold.supervisor_review_note}</p> : null}
              </article>
            ))}
          </div>
        </section>
      </div>
    </main>
  );
}
