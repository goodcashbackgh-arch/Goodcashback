import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type OrderRow = {
  id: string;
  order_ref: string | null;
  status: string | null;
  payment_auth_id: string | null;
  total_qty_declared: number | string | null;
  order_total_gbp_declared: number | string | null;
  quote_total_ghs: number | string | null;
  funded_at: string | null;
  created_at: string | null;
};

type CreditRow = { direction: string | null; amount_gbp: number | string | null };
type CreditBalanceRow = { importer_id: string | null; available_credit_gbp: number | string | null };
type FundingEventRow = { order_id: string | null; event_type: string | null; amount_gbp: number | string | null };

type CurrencyRelation = { currencies?: { code?: string | null }[] | { code?: string | null } | null }[] | { currencies?: { code?: string | null }[] | { code?: string | null } | null } | null;

type OrderSummary = {
  id: string;
  orderRef: string;
  title: string;
  description: string;
  dateLabel: string;
  declaredGbp: number;
  creditUsedGbp: number;
  remainingCashNeededGbp: number;
  remainingCashNeededLocal: number;
  fundingLabel: string;
  fundingFunded: boolean;
  statusLabel: string;
  statusTone: "amber" | "sky" | "emerald" | "rose" | "slate";
  group: "attention" | "active" | "complete";
};

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

function fundingTextClass(value: number) {
  if (value <= 0.01) return "text-emerald-700";
  return "text-amber-800";
}

function displayOrderTitle(orderRef: string | null, fallbackId: string) {
  const ref = orderRef || fallbackId;
  const cleaned = ref.replace(/^ORD-/i, "");
  const short = cleaned.length > 6 ? cleaned.slice(-6) : cleaned;
  return `Order ${short}`;
}

function goodsDescription(totalQty: unknown) {
  const qty = Number(totalQty ?? 0);
  if (Number.isFinite(qty) && qty > 0) return `Goods order · ${qty} ${qty === 1 ? "item" : "items"}`;
  return "Goods order";
}

function dateLabel(value: string | null) {
  if (!value) return "Date not available";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "Date not available";
  return `Ordered ${new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric" }).format(parsed)}`;
}

function statusToneClass(tone: OrderSummary["statusTone"]) {
  if (tone === "amber") return "bg-amber-50 text-amber-800 ring-amber-200";
  if (tone === "emerald") return "bg-emerald-50 text-emerald-700 ring-emerald-200";
  if (tone === "rose") return "bg-rose-50 text-rose-700 ring-rose-200";
  if (tone === "sky") return "bg-sky-50 text-sky-700 ring-sky-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function customerStatus(orderStatus: string | null, funded: boolean, remainingCashNeededGbp: number) {
  const status = String(orderStatus ?? "").toLowerCase();

  if (remainingCashNeededGbp > 0.01) {
    return { label: "Payment needed", tone: "amber" as const, group: "attention" as const };
  }

  if (status.includes("discrepancy") || status.includes("exception") || status.includes("hold") || status.includes("review")) {
    return { label: "Needs review", tone: "rose" as const, group: "attention" as const };
  }

  if (["completed", "archived", "delivered"].some((word) => status.includes(word))) {
    return { label: "Completed", tone: "emerald" as const, group: "complete" as const };
  }

  if (funded) {
    return { label: "Payment received", tone: "emerald" as const, group: "active" as const };
  }

  return { label: friendly(orderStatus), tone: "sky" as const, group: "active" as const };
}

function MobileOrderRow({ order, currencyCode }: { order: OrderSummary; currencyCode: string }) {
  return (
    <Link href={`/customer/orders/${order.id}/operations`} className="group block rounded-3xl border border-slate-200 bg-white p-4 shadow-sm transition hover:border-sky-200 hover:bg-sky-50/40">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-lg font-black text-slate-950">{order.title}</p>
          <p className="mt-0.5 truncate text-sm font-semibold text-slate-600">{order.description}</p>
        </div>
        <span className="shrink-0 text-lg font-black text-slate-950">{gbp(order.declaredGbp)}</span>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2 text-xs font-bold">
        <span className={`rounded-full px-2.5 py-1 ring-1 ${statusToneClass(order.statusTone)}`}>{order.statusLabel}</span>
        <span className={order.remainingCashNeededGbp > 0.01 ? "text-amber-800" : "text-emerald-700"}>{order.remainingCashNeededGbp > 0.01 ? `${gbp(order.remainingCashNeededGbp)} due` : "Nothing due"}</span>
      </div>
      <div className="mt-3 flex items-center justify-between gap-3 text-xs text-slate-500">
        <span className="truncate">{order.dateLabel}</span>
        <span className="font-black text-sky-700 transition group-hover:translate-x-0.5">Open →</span>
      </div>
      {order.creditUsedGbp > 0.01 ? <p className="mt-1 text-xs font-bold text-cyan-800">Account credit applied: {gbp(order.creditUsedGbp)}</p> : null}
      {order.remainingCashNeededGbp > 0.01 ? <p className="mt-1 text-xs font-semibold text-slate-500">Local guide: {localAmount(order.remainingCashNeededLocal, currencyCode)}</p> : null}
    </Link>
  );
}

function MobileOrderGroup({ title, rows, defaultOpen, currencyCode }: { title: string; rows: OrderSummary[]; defaultOpen?: boolean; currencyCode: string }) {
  if (rows.length === 0) return null;
  return (
    <details open={defaultOpen} className="rounded-3xl border border-slate-200 bg-slate-50/70 p-3">
      <summary className="cursor-pointer list-none px-1 py-2 text-sm font-black text-slate-950">
        <span>{title}</span>
        <span className="ml-2 rounded-full bg-white px-2.5 py-1 text-xs font-black text-slate-600 ring-1 ring-slate-200">{rows.length}</span>
      </summary>
      <div className="mt-2 grid gap-3">
        {rows.map((order) => <MobileOrderRow key={order.id} order={order} currencyCode={currencyCode} />)}
      </div>
    </details>
  );
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
  const [{ data: orders, error: ordersError }, { data: creditRows }, { data: fundingEvents }, { data: fxRate }, { data: creditBalanceRows }] = await Promise.all([
    supabase
      .from("orders")
      .select("id, order_ref, status, payment_auth_id, total_qty_declared, order_total_gbp_declared, quote_total_ghs, funded_at, created_at")
      .eq("importer_id", importer.id)
      .order("created_at", { ascending: false }),
    supabase.from("importer_credit_ledger").select("direction, amount_gbp").eq("importer_id", importer.id),
    supabase.from("order_funding_events").select("order_id, event_type, amount_gbp").in("event_type", ["funding_contribution", "credit_applied", "manual_adjustment", "funding_reversed"]),
    supabase
      .from("fx_rates")
      .select("quote_rate, quote_card_markup_pct, rate_date")
      .eq("country_id", importer.country_id)
      .lte("rate_date", today)
      .order("rate_date", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase.rpc("customer_importer_credit_balance_v1"),
  ]);
  if (ordersError) throw ordersError;

  const rows = (orders ?? []) as unknown as OrderRow[];
  const orderIds = new Set(rows.map((order) => order.id));
  const fundingRows = ((fundingEvents ?? []) as FundingEventRow[]).filter((event) => event.order_id && orderIds.has(event.order_id));
  const fundingByOrder = new Map<string, { cash: number; credit: number; total: number }>();
  for (const event of fundingRows) {
    const orderId = event.order_id ?? "";
    const amount = Number(event.amount_gbp ?? 0);
    const current = fundingByOrder.get(orderId) ?? { cash: 0, credit: 0, total: 0 };
    if (event.event_type === "credit_applied") current.credit += Math.abs(amount);
    else if (event.event_type === "funding_reversed") current.cash -= Math.abs(amount);
    else current.cash += amount;
    current.total = current.cash + current.credit;
    fundingByOrder.set(orderId, current);
  }

  const fallbackCreditBalanceGbp = ((creditRows ?? []) as CreditRow[]).reduce((sum, row) => {
    const amount = Number(row.amount_gbp ?? 0);
    return sum + (row.direction === "credit" ? amount : -amount);
  }, 0);
  const rpcRows = (creditBalanceRows ?? []) as CreditBalanceRow[];
  const hasRpcCreditBalance = Array.isArray(creditBalanceRows) && rpcRows.length > 0;
  const rpcCreditBalanceGbp = rpcRows.reduce((sum, row) => sum + Number(row.available_credit_gbp ?? 0), 0);
  const creditBalanceGbp = hasRpcCreditBalance && Number.isFinite(rpcCreditBalanceGbp) ? rpcCreditBalanceGbp : fallbackCreditBalanceGbp;
  const rate = Number(fxRate?.quote_rate ?? 0);
  const markup = Number(fxRate?.quote_card_markup_pct ?? 0);
  const effectiveRate = rate ? rate * (1 + markup / 100) : 0;
  const currencyCode = currencyCodeFromCountries(importer.countries as CurrencyRelation);
  const rateDate = fxRate?.rate_date as string | undefined;
  const fxLabel = rateDate === today ? "Today's FX rate" : rateDate ? `Latest available FX rate: ${rateDate}` : "No FX rate available";

  const summaries: OrderSummary[] = rows.map((order) => {
    const funding = fundingByOrder.get(order.id) ?? { cash: 0, credit: 0, total: 0 };
    const declaredGbp = Number(order.order_total_gbp_declared ?? 0);
    const remainingCashNeededGbp = Math.max(declaredGbp - funding.credit - funding.cash, 0);
    const status = customerStatus(order.status, Boolean(order.funded_at), remainingCashNeededGbp);
    return {
      id: order.id,
      orderRef: order.order_ref ?? order.id,
      title: displayOrderTitle(order.order_ref, order.id),
      description: goodsDescription(order.total_qty_declared),
      dateLabel: dateLabel(order.created_at),
      declaredGbp,
      creditUsedGbp: funding.credit,
      remainingCashNeededGbp,
      remainingCashNeededLocal: effectiveRate ? remainingCashNeededGbp * effectiveRate : 0,
      fundingLabel: order.funded_at ? "Funded" : "Funding pending",
      fundingFunded: Boolean(order.funded_at),
      statusLabel: status.label,
      statusTone: status.tone,
      group: status.group,
    };
  });

  const needsAttention = summaries.filter((order) => order.group === "attention");
  const activeOrders = summaries.filter((order) => order.group === "active");
  const completedOrders = summaries.filter((order) => order.group === "complete");
  const fundedCount = rows.filter((order) => order.funded_at).length;

  return (
    <main className="min-h-screen bg-gradient-to-b from-sky-50 via-white to-slate-50 p-4 text-slate-950 xl:p-6">
      <header className="overflow-hidden rounded-[2rem] border border-sky-100 bg-white shadow-sm">
        <div className="bg-gradient-to-r from-sky-500 via-cyan-400 to-emerald-300 px-5 py-2" />
        <div className="flex flex-col gap-5 p-5 xl:flex-row xl:items-start xl:justify-between xl:p-7">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.28em] text-sky-600">Customer portal</p>
            <h1 className="mt-2 text-4xl font-black tracking-tight text-slate-950 xl:text-5xl">Goodcashback Customer</h1>
            <p className="mt-2 text-base text-slate-600">{operator.full_name} · {importer.trading_name ?? importer.company_name}</p>
            <p className="mt-3 text-sm font-semibold text-slate-500">{rows.length} orders · {needsAttention.length} need attention · {gbp(creditBalanceGbp)} available account credit</p>
          </div>
          <div className="grid gap-3 xl:min-w-64">
            <Link href="/customer/orders/new" className="rounded-2xl bg-slate-950 px-5 py-3 text-center text-sm font-black text-white shadow-sm transition hover:bg-slate-800">Create order</Link>
            <Link href="/importer" className="rounded-2xl border border-slate-200 bg-white px-5 py-3 text-center text-sm font-black text-slate-700 shadow-sm transition hover:bg-slate-50">Advanced workspace</Link>
          </div>
        </div>
      </header>

      <section className="mt-5 rounded-[1.5rem] border border-sky-100 bg-white p-4 shadow-sm xl:hidden">
        <div className="grid grid-cols-3 gap-3 text-center">
          <div><p className="text-xs font-black uppercase tracking-wide text-slate-500">Orders</p><p className="mt-1 text-2xl font-black">{rows.length}</p></div>
          <div><p className="text-xs font-black uppercase tracking-wide text-emerald-700">Funded</p><p className="mt-1 text-2xl font-black text-emerald-950">{fundedCount}</p></div>
          <div><p className="text-xs font-black uppercase tracking-wide text-cyan-700">Account credit</p><p className="mt-1 text-2xl font-black text-cyan-950">{gbp(creditBalanceGbp)}</p></div>
        </div>
        <p className="mt-3 rounded-2xl bg-amber-50 px-3 py-2 text-xs font-bold text-amber-800 ring-1 ring-amber-100">Account credit local guide: {effectiveRate ? localAmount(creditBalanceGbp * effectiveRate, currencyCode) : "—"} · {fxLabel}</p>
      </section>

      <section className="mt-5 hidden gap-4 xl:grid xl:grid-cols-4">
        <div className="rounded-[1.5rem] border border-slate-200 bg-white p-5 shadow-sm"><div className="text-sm font-semibold text-slate-500">Total orders</div><div className="mt-2 text-3xl font-black">{rows.length}</div></div>
        <div className="rounded-[1.5rem] border border-emerald-100 bg-emerald-50/70 p-5 shadow-sm"><div className="text-sm font-semibold text-emerald-700">Funded</div><div className="mt-2 text-3xl font-black text-emerald-950">{fundedCount}</div></div>
        <div className="rounded-[1.5rem] border border-cyan-100 bg-cyan-50/70 p-5 shadow-sm"><div className="text-sm font-semibold text-cyan-700">Available account credit</div><div className="mt-2 text-3xl font-black text-cyan-950">{gbp(creditBalanceGbp)}</div></div>
        <div className="rounded-[1.5rem] border border-amber-100 bg-amber-50/70 p-5 shadow-sm">
          <div className="text-sm font-semibold text-amber-700">Local guide</div>
          <div className="mt-2 text-3xl font-black text-amber-950">{effectiveRate ? localAmount(creditBalanceGbp * effectiveRate, currencyCode) : "—"}</div>
          <div className={rateDate === today ? "mt-2 text-xs font-bold text-emerald-700" : "mt-2 text-xs font-bold text-amber-800"}>{fxLabel}</div>
        </div>
      </section>

      <section className="mt-5 overflow-hidden rounded-[1.75rem] border border-slate-200 bg-white shadow-sm">
        <div className="flex flex-col gap-2 border-b border-slate-100 bg-slate-50/70 p-5 xl:flex-row xl:items-center xl:justify-between">
          <div>
            <h2 className="text-xl font-black">Orders</h2>
            <p className="text-sm text-slate-600">Order values close in GBP. Local figures are payment-stage guidance using the current/latest FX rate.</p>
          </div>
          <span className="w-full rounded-full bg-sky-100 px-3 py-2 text-center text-xs font-black text-sky-700 xl:w-auto xl:py-1">{rows.length} orders</span>
        </div>

        <div className="grid gap-4 p-4 xl:hidden">
          {summaries.length === 0 ? <p className="rounded-2xl bg-slate-50 p-4 text-sm font-semibold text-slate-600">No orders yet.</p> : null}
          <MobileOrderGroup title="Needs attention" rows={needsAttention} defaultOpen currencyCode={currencyCode} />
          <MobileOrderGroup title="In progress" rows={activeOrders} defaultOpen currencyCode={currencyCode} />
          <MobileOrderGroup title="Completed" rows={completedOrders} currencyCode={currencyCode} />
        </div>

        <div className="hidden overflow-x-auto xl:block">
          <table className="min-w-full text-sm">
            <thead className="bg-white text-left text-xs font-black uppercase tracking-wide text-slate-500">
              <tr>
                <th className="p-4">Order</th>
                <th className="p-4">Goods</th>
                <th className="p-4">Order value</th>
                <th className="p-4">Account credit</th>
                <th className="p-4">Current cash due</th>
                <th className="p-4">Funding</th>
                <th className="p-4">Status</th>
                <th className="p-4">Action</th>
              </tr>
            </thead>
            <tbody>
              {summaries.map((order) => {
                const netAfterCredit = Math.max(order.declaredGbp - order.creditUsedGbp, 0);
                return (
                  <tr key={order.id} className="border-t border-slate-100 align-top hover:bg-sky-50/40">
                    <td className="p-4"><div className="font-black">{order.title}</div><div className="text-xs text-slate-400">Ref: {order.orderRef}</div></td>
                    <td className="p-4"><div className="font-semibold text-slate-800">{order.description}</div><div className="text-xs text-slate-500">{order.dateLabel}</div></td>
                    <td className="p-4"><div className="font-black">{gbp(order.declaredGbp)}</div><div className="text-xs text-slate-500">GBP closure basis</div></td>
                    <td className="p-4"><div className="font-black text-cyan-800">{gbp(order.creditUsedGbp)}</div><div className="text-xs text-slate-500">Net after account credit {gbp(netAfterCredit)}</div></td>
                    <td className="p-4"><div className={`font-black ${fundingTextClass(order.remainingCashNeededGbp)}`}>{gbp(order.remainingCashNeededGbp)}</div><div className="text-xs text-slate-500">Local guide {effectiveRate ? localAmount(order.remainingCashNeededLocal, currencyCode) : "—"}</div></td>
                    <td className="p-4"><span className={statusPill(order.fundingFunded)}>{order.fundingLabel}</span></td>
                    <td className="p-4"><span className={`rounded-full px-3 py-1 text-xs font-bold ring-1 ${statusToneClass(order.statusTone)}`}>{order.statusLabel}</span></td>
                    <td className="p-4"><Link className="rounded-xl bg-slate-950 px-3 py-2 text-xs font-black text-white" href={`/customer/orders/${order.id}/operations`}>Open</Link></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
