import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type OrderRow = {
  id: string;
  order_ref: string | null;
  status: string | null;
  payment_auth_id: string | null;
  order_total_gbp_declared: number | string | null;
  quote_total_ghs: number | string | null;
  funded_at: string | null;
  created_at: string | null;
  retailers: { name: string | null } | null;
};

type CreditRow = { direction: string | null; amount_gbp: number | string | null };

type CurrencyRelation = { currencies?: { code?: string | null }[] | { code?: string | null } | null }[] | { currencies?: { code?: string | null }[] | { code?: string | null } | null } | null;

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function localAmount(value: unknown, code = "Local") {
  return `${code} ${new Intl.NumberFormat("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(Number(value ?? 0))}`;
}

function friendly(value: string | null | undefined) {
  if (!value) return "In progress";
  return value.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase());
}

function currencyCodeFromCountries(value: CurrencyRelation) {
  const country = Array.isArray(value) ? value[0] : value;
  const currency = Array.isArray(country?.currencies) ? country?.currencies[0] : country?.currencies;
  return currency?.code ?? "Local";
}

function statusPill(funded: boolean) {
  return funded
    ? "rounded-full bg-emerald-50 px-3 py-1 text-xs font-bold text-emerald-700 ring-1 ring-emerald-200"
    : "rounded-full bg-amber-50 px-3 py-1 text-xs font-bold text-amber-800 ring-1 ring-amber-200";
}

export default async function CustomerDashboardPage() {
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

  const { data: operatorImporter } = await supabase
    .from("operator_importers")
    .select("importer_id")
    .eq("operator_id", operator.id)
    .is("revoked_at", null)
    .limit(1)
    .maybeSingle();
  if (!operatorImporter?.importer_id) redirect("/auth/check");

  const { data: importer } = await supabase
    .from("importers")
    .select("id, company_name, trading_name, country_id, countries(currencies(code))")
    .eq("id", operatorImporter.importer_id)
    .maybeSingle();
  if (!importer) redirect("/auth/check");

  const today = new Date().toISOString().slice(0, 10);
  const [{ data: orders, error: ordersError }, { data: creditRows }, { data: fxRate }] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, status, payment_auth_id, order_total_gbp_declared, quote_total_ghs, funded_at, created_at, retailers(name)")
      .eq("importer_id", importer.id)
      .order("created_at", { ascending: false }),
    supabase.from("importer_credit_ledger").select("direction, amount_gbp").eq("importer_id", importer.id),
    supabase
      .from("fx_rates")
      .select("quote_rate, quote_card_markup_pct, rate_date")
      .eq("country_id", importer.country_id)
      .lte("rate_date", today)
      .order("rate_date", { ascending: false })
      .limit(1)
      .maybeSingle(),
  ]);
  if (ordersError) throw ordersError;

  const rows = (orders ?? []) as unknown as OrderRow[];
  const creditBalanceGbp = ((creditRows ?? []) as CreditRow[]).reduce((sum, row) => {
    const amount = Number(row.amount_gbp ?? 0);
    return sum + (row.direction === "credit" ? amount : -amount);
  }, 0);
  const rate = Number(fxRate?.quote_rate ?? 0);
  const markup = Number(fxRate?.quote_card_markup_pct ?? 0);
  const effectiveRate = rate ? rate * (1 + markup / 100) : 0;
  const currencyCode = currencyCodeFromCountries(importer.countries as CurrencyRelation);
  const rateDate = fxRate?.rate_date as string | undefined;

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 text-slate-950 md:p-6">
      <header className="overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
        <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
        <div className="flex flex-col gap-5 p-5 md:flex-row md:items-start md:justify-between md:p-7">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Customer portal</p>
            <h1 className="mt-2 text-4xl font-black tracking-tight text-slate-950 md:text-5xl">Goodcashback Customer</h1>
            <p className="mt-2 text-base text-slate-600">{operator.full_name} · {importer.trading_name ?? importer.company_name}</p>
          </div>
          <Link href="/customer/orders/new" className="rounded-2xl bg-slate-950 px-5 py-3 text-center text-sm font-black text-white shadow-sm transition hover:bg-slate-800">Create order</Link>
        </div>
      </header>

      <section className="mt-5 rounded-[1.75rem] border border-sky-200 bg-sky-50/80 p-5 text-sm text-slate-800 shadow-sm">
        <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.18em] text-sky-700">Linked workspace</p>
            <h2 className="mt-1 text-lg font-black text-slate-950">Importer lane available</h2>
            <p className="mt-1 text-slate-600">Open the importer/operator dashboard to upload invoices, add tracking and reconcile order items.</p>
          </div>
          <Link href="/importer" className="rounded-2xl bg-sky-600 px-5 py-3 text-center font-black text-white shadow-sm transition hover:bg-sky-700">Open Importer Portal</Link>
        </div>
      </section>

      <section className="mt-5 grid gap-4 md:grid-cols-4">
        <div className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><div className="text-sm font-semibold text-slate-500">Total orders</div><div className="mt-2 text-3xl font-black">{rows.length}</div></div>
        <div className="rounded-[1.5rem] border border-emerald-100 bg-emerald-50/70 p-5 shadow-sm"><div className="text-sm font-semibold text-emerald-700">Funded</div><div className="mt-2 text-3xl font-black text-emerald-950">{rows.filter((order) => order.funded_at).length}</div></div>
        <div className="rounded-[1.5rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm"><div className="text-sm font-semibold text-cyan-700">Ledger credit GBP</div><div className="mt-2 text-3xl font-black text-cyan-950">{gbp(creditBalanceGbp)}</div></div>
        <div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-5 shadow-sm">
          <div className="text-sm font-semibold text-amber-700">Ledger credit local</div>
          <div className="mt-2 text-3xl font-black text-amber-950">{effectiveRate ? localAmount(creditBalanceGbp * effectiveRate, currencyCode) : "—"}</div>
          <div className={rateDate === today ? "mt-2 text-xs font-bold text-emerald-700" : "mt-2 text-xs font-bold text-amber-800"}>{rateDate === today ? "Today's FX rate" : rateDate ? `Latest available FX rate: ${rateDate}` : "No FX rate available"}</div>
        </div>
      </section>

      <section className="mt-5 overflow-hidden rounded-[1.75rem] border border-slate-200 bg-white shadow-sm">
        <div className="flex flex-col gap-2 border-b border-slate-100 bg-slate-50/70 p-5 md:flex-row md:items-center md:justify-between">
          <div>
            <h2 className="text-xl font-black">Orders</h2>
            <p className="text-sm text-slate-600">Customer order status, pro forma value and funding position.</p>
          </div>
          <span className="rounded-full bg-sky-100 px-3 py-1 text-xs font-black text-sky-700">{rows.length} orders</span>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-white text-left text-xs font-black uppercase tracking-wide text-slate-500"><tr><th className="p-4">Order</th><th className="p-4">Retailer</th><th className="p-4">Auth ref</th><th className="p-4">GBP</th><th className="p-4">Local quote</th><th className="p-4">Funding</th><th className="p-4">Status</th><th className="p-4">Action</th></tr></thead>
            <tbody>
              {rows.map((order) => (
                <tr key={order.id} className="border-t border-slate-100 align-top hover:bg-sky-50/40">
                  <td className="p-4"><div className="font-black">{order.order_ref}</div><div className="text-xs text-slate-400">{order.id}</div></td>
                  <td className="p-4 font-semibold">{order.retailers?.name ?? "—"}</td>
                  <td className="p-4 text-slate-700">{order.payment_auth_id ?? "—"}</td>
                  <td className="p-4 font-black">{gbp(order.order_total_gbp_declared)}</td>
                  <td className="p-4 font-semibold text-slate-700">{localAmount(order.quote_total_ghs, currencyCode)}</td>
                  <td className="p-4"><span className={statusPill(Boolean(order.funded_at))}>{order.funded_at ? "Funded" : "Funding pending"}</span></td>
                  <td className="p-4 font-semibold text-slate-700">{friendly(order.status)}</td>
                  <td className="p-4"><Link className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white" href={`/customer/orders/${order.id}/operations`}>Open</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
