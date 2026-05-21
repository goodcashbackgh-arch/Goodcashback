import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type ScreenshotRow = { id: string; screenshot_url: string };
type ReviewLinkRow = { customer_review_path: string | null };

function money(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function localAmount(value: unknown, code = "Local") {
  return `${code} ${new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value ?? 0))}`;
}

function friendly(value: string | null | undefined) {
  if (!value) return "—";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function chip(ok: boolean) {
  return ok
    ? "rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-800 ring-1 ring-emerald-200"
    : "rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800 ring-1 ring-amber-200";
}

export default async function CustomerOrderOperationsPage({
  params,
  searchParams,
}: {
  params: Promise<{ order_id: string }>;
  searchParams?: Promise<{ success?: string; error?: string }>;
}) {
  const { order_id: orderId } = await params;
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: operator } = await supabase
    .from("operators")
    .select("id, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!operator) redirect("/auth/check");

  const { data: order } = await supabase
    .from("orders")
    .select("*, importers(id, company_name, trading_name, countries(currencies(code))), retailers(name)")
    .eq("id", orderId)
    .maybeSingle();
  if (!order) redirect("/customer");

  const { data: access } = await supabase
    .from("operator_importers")
    .select("id")
    .eq("operator_id", operator.id)
    .eq("importer_id", order.importer_id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!access) redirect("/customer");

  const [fundingRes, screenshotsRes, stateRes, reviewRes] = await Promise.all([
    supabase.from("order_funding_position_vw").select("*").eq("order_id", orderId).maybeSingle(),
    supabase.from("order_screenshots").select("id, screenshot_url").eq("order_id", orderId).order("display_order"),
    supabase.from("order_state_vw").select("lifecycle_status").eq("id", orderId).maybeSingle(),
    (supabase as any).rpc("customer_active_order_review_link_v1", { p_order_id: orderId }).maybeSingle(),
  ]);

  const funding = fundingRes.data;
  const screenshots = (screenshotsRes.data ?? []) as ScreenshotRow[];
  const state = stateRes.data;
  const reviewLink = reviewRes.data as ReviewLinkRow | null;
  const reviewHref = reviewLink?.customer_review_path ?? null;
  const thresholdMet = Boolean(funding?.threshold_met_yn);
  const currencyCode = order.importers?.countries?.currencies?.code ?? "Local";

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 text-slate-950 md:p-6">
      <Link href="/customer" className="font-black text-sky-700">← Customer dashboard</Link>

      <header className="mt-5 overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
        <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
        <div className="p-5 md:p-7">
          <p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Customer order</p>
          <h1 className="mt-2 text-3xl font-black tracking-tight md:text-5xl">{order.order_ref ?? orderId}</h1>
          <p className="mt-2 text-sm text-slate-600">{order.retailers?.name ?? "Retailer"} · {order.importers?.trading_name ?? order.importers?.company_name ?? "Customer"}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-800">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-800">{qp.error}</p> : null}
        </div>
      </header>

      <section className={reviewHref ? "mt-5 rounded-[1.75rem] border border-sky-200 bg-sky-50 p-5 shadow-sm" : "mt-5 rounded-[1.75rem] border border-amber-200 bg-amber-50 p-5 shadow-sm"}>
        <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
          <div>
            <h2 className="text-xl font-black">Review before shipment</h2>
            <p className="mt-1 text-sm text-slate-700">
              {reviewHref ? "Open this to request a hold for items you no longer want before shipment." : "No active customer review link is visible for this order yet."}
            </p>
          </div>
          {reviewHref ? <Link href={reviewHref} className="rounded-2xl bg-sky-600 px-5 py-3 text-center text-sm font-black text-white">Open review page</Link> : null}
        </div>
      </section>

      <section className="mt-5 grid gap-4 md:grid-cols-4">
        <div className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm font-semibold text-slate-500">Status</p><p className="mt-2 text-xl font-black">{friendly(state?.lifecycle_status ?? order.status)}</p></div>
        <div className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><p className="text-sm font-semibold text-slate-500">Funding</p><p className="mt-2"><span className={chip(thresholdMet)}>{thresholdMet ? "Funded" : friendly(funding?.status)}</span></p></div>
        <div className="rounded-[1.5rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm"><p className="text-sm font-semibold text-cyan-700">Goods GBP</p><p className="mt-2 text-xl font-black text-cyan-950">{money(order.order_total_gbp_declared)}</p></div>
        <div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-5 shadow-sm"><p className="text-sm font-semibold text-amber-700">Pro forma local</p><p className="mt-2 text-xl font-black text-amber-950">{localAmount(order.quote_total_ghs, currencyCode)}</p></div>
      </section>

      <section className="mt-5 grid gap-4 lg:grid-cols-2">
        <div className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-black">Funding details</h2>
          <div className="mt-4 grid gap-2 text-sm md:grid-cols-2">
            <p>Threshold: <span className="font-black">{money(funding?.purchase_funding_threshold_gbp ?? order.order_total_gbp_declared)}</span></p>
            <p>Confirmed DVA: <span className="font-black">{money(funding?.confirmed_dva_funding_gbp)}</span></p>
            <p>Applied credit: <span className="font-black">{money(funding?.applied_credit_gbp)}</span></p>
            <p>Gap: <span className="font-black">{money(funding?.gap_remaining_gbp)}</span></p>
          </div>
        </div>

        <div className="rounded-[1.75rem] border border-slate-200 bg-white p-5 shadow-sm">
          <h2 className="text-xl font-black">Order evidence and updates</h2>
          <p className="mt-2 text-sm text-slate-600">Original screenshots are visible. Internal retailer invoices and retailer-to-warehouse tracking are hidden.</p>
          <div className="mt-4 flex flex-wrap gap-2">
            {screenshots.length === 0 ? <p className="text-sm text-slate-600">No screenshots uploaded.</p> : null}
            {screenshots.map((row) => <a key={row.id} href={row.screenshot_url} target="_blank" rel="noreferrer" className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white">Open screenshot</a>)}
          </div>
        </div>
      </section>
    </main>
  );
}
