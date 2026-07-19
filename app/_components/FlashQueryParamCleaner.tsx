"use client";

import { useEffect, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";

type FlashQueryParamCleanerProps = { keys?: string[] };
type FinancialCheck = {
  has_invoice: boolean;
  invoice_ref?: string | null;
  declared_qty?: number;
  declared_amount_gbp?: number;
  goods_qty?: number;
  goods_amount_gbp?: number;
  order_qty_variance?: number;
  order_value_variance_gbp?: number;
  delivery_total_gbp?: number;
  discount_total_gbp?: number;
  expected_invoice_total_gbp?: number;
  invoice_total_gbp?: number | null;
  invoice_variance_gbp?: number | null;
  financial_matched?: boolean;
  pending_supervisor_count?: number;
  error?: string;
};

function gbp(value: number | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 }).format(Number(value ?? 0));
}

function signedGbp(value: number | null | undefined) {
  const n = Number(value ?? 0);
  if (Math.abs(n) < 0.005) return gbp(0);
  return `${n > 0 ? "+" : ""}${gbp(n)}`;
}

function FinancialCheckPanel({ pathname, supplierInvoiceId }: { pathname: string | null; supplierInvoiceId: string }) {
  const [data, setData] = useState<FinancialCheck | null>(null);

  useEffect(() => {
    if (!pathname) return;
    const match = pathname.match(/^\/importer\/reconciliation\/([^/]+)$/);
    if (!match?.[1]) return;

    let cancelled = false;
    const query = new URLSearchParams({ order_id: match[1] });
    if (supplierInvoiceId) query.set("supplier_invoice_id", supplierInvoiceId);
    fetch(`/api/importer/reconciliation-financial-check?${query.toString()}`)
      .then((response) => response.json())
      .then((payload) => { if (!cancelled) setData(payload); })
      .catch(() => { if (!cancelled) setData({ has_invoice: false, error: "Could not load financial check." }); });

    return () => { cancelled = true; };
  }, [pathname, supplierInvoiceId]);

  if (!pathname?.startsWith("/importer/reconciliation/") || !data || !data.has_invoice) return null;
  const financialMatched = Boolean(data.financial_matched);
  const pendingSupervisor = Number(data.pending_supervisor_count ?? 0);

  return (
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">Selected invoice financial check</p>
          <h2 className="mt-1 text-xl font-semibold">{data.invoice_ref ?? "Supplier invoice"} total match</h2>
          <p className="mt-2 text-sm text-slate-600">This check uses only the selected invoice: goods lines + its delivery − its discount = its entered invoice total.</p>
        </div>
        <span className={`w-fit rounded-full px-3 py-1 text-xs font-semibold ${financialMatched ? "bg-emerald-100 text-emerald-800" : "bg-amber-100 text-amber-800"}`}>
          {financialMatched ? "Financially matched" : "Financial variance"}
        </span>
      </div>
      <div className="mt-5 grid gap-3 md:grid-cols-4">
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Invoice ref</p><p className="mt-1 font-semibold">{data.invoice_ref ?? "—"}</p></div>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Goods lines</p><p className="mt-1 text-xl font-semibold">{gbp(data.goods_amount_gbp)}</p></div>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Delivery</p><p className="mt-1 text-xl font-semibold">{gbp(data.delivery_total_gbp)}</p></div>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Discount</p><p className="mt-1 text-xl font-semibold">-{gbp(data.discount_total_gbp)}</p></div>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Expected invoice total</p><p className="mt-1 text-xl font-semibold">{gbp(data.expected_invoice_total_gbp)}</p></div>
        <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><p className="text-xs uppercase tracking-wide text-slate-500">Entered invoice total</p><p className="mt-1 text-xl font-semibold">{data.invoice_total_gbp === null ? "—" : gbp(data.invoice_total_gbp)}</p></div>
        <div className={`rounded-2xl border p-4 ${financialMatched ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Financial variance</p><p className="mt-1 text-xl font-semibold">{signedGbp(data.invoice_variance_gbp)}</p></div>
        <div className={`rounded-2xl border p-4 ${pendingSupervisor === 0 ? "border-emerald-200 bg-emerald-50" : "border-amber-200 bg-amber-50"}`}><p className="text-xs uppercase tracking-wide text-slate-500">Supervisor review</p><p className="mt-1 text-xl font-semibold">{pendingSupervisor}</p></div>
      </div>
    </section>
  );
}

export default function FlashQueryParamCleaner({ keys = ["success", "error"] }: FlashQueryParamCleanerProps) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const supplierInvoiceId = searchParams?.get("supplier_invoice_id") ?? "";

  useEffect(() => {
    if (!pathname || !searchParams) return;
    const current = new URLSearchParams(searchParams.toString());
    let changed = false;
    for (const key of keys) {
      if (current.has(key)) { current.delete(key); changed = true; }
    }
    if (!changed) return;
    const nextQuery = current.toString();
    router.replace(nextQuery ? `${pathname}?${nextQuery}` : pathname, { scroll: false });
  }, [keys, pathname, router, searchParams]);

  return <FinancialCheckPanel pathname={pathname} supplierInvoiceId={supplierInvoiceId} />;
}
