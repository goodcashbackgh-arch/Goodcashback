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
    <main className="min-h-screen bg-slate-50 p-6 text-slate-950">
      <header className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.2em] text-sky-600">Customer portal</p>
          <h1 className="text-3xl font-semibold">Goodcashback Customer</h1>
          <p className="text-sm text-slate-600">{operator.full_name} · {importer.trading_name ?? importer.company_name}</p>
        </div>
        <Link href="/customer/orders/new" className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-semibold text-white">Create order</Link>
      </header>

      <section className="mt-6 grid gap-4 md:grid-cols-4">
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Total orders</div><div className="mt-2 text-2xl font-semibold">{rows.length}</div></div>
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Funded</div><div className="mt-2 text-2xl font-semibold">{rows.filter((order) => order.funded_at).length}</div></div>
        <div className="rounded-2xl border bg-white p-4"><div className="text-sm text-slate-500">Ledger credit GBP</div><div className="mt-2 text-2xl font-semibold">{gbp(creditBalanceGbp)}</div></div>
        <div className="rounded-2xl border bg-white p-4">
          <div className="text-sm text-slate-500">Ledger credit local</div>
          <div className="mt-2 text-2xl font-semibold">{effectiveRate ? localAmount(creditBalanceGbp * effectiveRate, currencyCode) : "—"}</div>
          <div className={rateDate === today ? "mt-1 text-xs text-emerald-700" : "mt-1 text-xs font-semibold text-amber-700"}>{rateDate === today ? "Today's FX rate" : rateDate ? `Latest available FX rate: ${rateDate}` : "No FX rate available"}</div>
        </div>
      </section>

      <section className="mt-6 rounded-2xl border bg-white p-4">
        <h2 className="text-lg font-semibold">Orders</h2>
        <div className="mt-4 overflow-x-auto">
          <table className="min-w-full text-sm">
            <thead className="bg-slate-50 text-left"><tr><th className="p-3">Order</th><th className="p-3">Retailer</th><th className="p-3">Auth ref</th><th className="p-3">GBP</th><th className="p-3">Local quote</th><th className="p-3">Funding</th><th className="p-3">Status</th><th className="p-3">Action</th></tr></thead>
            <tbody>
              {rows.map((order) => (
                <tr key={order.id} className="border-t align-top">
                  <td className="p-3"><div className="font-medium">{order.order_ref}</div><div className="text-xs text-slate-500">{order.id}</div></td>
                  <td className="p-3">{order.retailers?.name ?? "—"}</td>
                  <td className="p-3">{order.payment_auth_id ?? "—"}</td>
                  <td className="p-3">{gbp(order.order_total_gbp_declared)}</td>
                  <td className="p-3">{localAmount(order.quote_total_ghs, currencyCode)}</td>
                  <td className="p-3">{order.funded_at ? "Funded" : "Funding pending"}</td>
                  <td className="p-3">{friendly(order.status)}</td>
                  <td className="p-3"><Link className="font-semibold text-sky-700 underline" href={`/customer/orders/${order.id}/operations`}>Open</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
