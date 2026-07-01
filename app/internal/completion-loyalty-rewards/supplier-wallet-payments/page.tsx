import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { createCompletionLoyaltySupplierWalletBatchAction } from "./actions";

type SearchParams = { success?: string; error?: string; q?: string };

type CandidateRow = {
  order_funding_event_id: string | null;
  order_ref: string | null;
  importer_name: string | null;
  retailer_name: string | null;
  supplier_invoice_ref: string | null;
  wallet_code: string | null;
  wallet_bank_account_mapping_code: string | null;
  wallet_sage_bank_account_id: string | null;
  amount_gbp: number | string | null;
  posting_date: string | null;
  readiness_status: string | null;
  blocker: string | null;
  existing_batch_id: string | null;
  existing_batch_ref: string | null;
  target_sage_purchase_invoice_id: string | null;
  total_count?: number | string | null;
};

function numeric(value: number | string | null | undefined) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(numeric(value));
}

function friendly(value: string | null | undefined) {
  if (!value) return "-";
  return value.replaceAll("_", " ");
}

function statusClass(value: string | null | undefined) {
  const status = value ?? "";
  if (status === "ready_to_freeze_loyalty_supplier_wallet_payment") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (status === "already_batched" || status === "frozen_ready_to_batch") return "bg-sky-100 text-sky-800 ring-sky-200";
  return "bg-rose-100 text-rose-800 ring-rose-200";
}

function canSelect(row: CandidateRow) {
  return row.readiness_status === "ready_to_freeze_loyalty_supplier_wallet_payment" && !row.blocker && Boolean(row.order_funding_event_id);
}

export default async function SupplierWalletPaymentsPage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const q = (params.q ?? "").trim();
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");
  if (!["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const { data, error } = await (supabase as any).rpc("internal_completion_loyalty_supplier_wallet_payment_candidates_v1", {
    p_search: q || null,
    p_limit: 100,
    p_offset: 0,
  });

  const rows = (data ?? []) as CandidateRow[];
  const readyRows = rows.filter(canSelect);
  const blockedRows = rows.filter((row) => row.readiness_status === "blocked");
  const existingRows = rows.filter((row) => row.existing_batch_id || row.existing_batch_ref);
  const total = rows[0]?.total_count ?? rows.length;

  return (
    <main className="min-h-screen bg-slate-50 px-6 py-8 text-slate-950">
      <div className="mx-auto max-w-7xl space-y-6">
        <header className="overflow-hidden rounded-3xl border border-emerald-100 bg-white shadow-sm">
          <div className="h-2 bg-gradient-to-r from-emerald-500 via-sky-400 to-violet-400" />
          <div className="p-6">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <Link href="/internal/completion-loyalty-rewards" className="text-sm font-bold text-emerald-700 hover:text-emerald-900">
                Back to completion loyalty rewards
              </Link>
              <Link href="/internal/accounting-command-centre/cash-posting" className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-bold text-slate-700 hover:bg-slate-50">
                Cash posting
              </Link>
            </div>
            <h1 className="mt-8 text-3xl font-semibold tracking-tight text-slate-950 sm:text-4xl">Supplier wallet payments</h1>
            <p className="mt-3 max-w-4xl text-sm leading-6 text-slate-600">
              Freeze completion-loyalty supplier payments from the resolved Virtual GBP or DVA GHS wallet into the normal cash posting batch flow. No Sage API call happens until the batch detail page posts it.
            </p>
            <p className="mt-4 rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">Signed in as {staff.full_name ?? "staff"} · {staff.role_type}</p>
          </div>
        </header>

        {params.success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-medium text-emerald-900">{params.success}</div> : null}
        {params.error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-900">{params.error}</div> : null}
        {error ? <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-medium text-rose-900">{error.message}</div> : null}

        <section className="grid gap-4 md:grid-cols-4">
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-5 text-emerald-950">
            <p className="text-sm font-medium">Ready</p>
            <p className="mt-2 text-3xl font-bold">{readyRows.length}</p>
          </div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-5 text-sky-950">
            <p className="text-sm font-medium">Frozen/batched</p>
            <p className="mt-2 text-3xl font-bold">{existingRows.length}</p>
          </div>
          <div className="rounded-2xl border border-rose-200 bg-rose-50 p-5 text-rose-950">
            <p className="text-sm font-medium">Blocked</p>
            <p className="mt-2 text-3xl font-bold">{blockedRows.length}</p>
          </div>
          <div className="rounded-2xl border border-slate-200 bg-white p-5 text-slate-950">
            <p className="text-sm font-medium">Total</p>
            <p className="mt-2 text-3xl font-bold">{String(total)}</p>
          </div>
        </section>

        <form method="get" className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
          <div className="grid gap-3 md:grid-cols-[1fr_auto_auto] md:items-end">
            <label className="block text-sm font-medium text-slate-700">
              Search
              <input
                name="q"
                defaultValue={q}
                placeholder="Order, importer, supplier, wallet, blocker"
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
              />
            </label>
            <button className="rounded-lg bg-slate-950 px-4 py-2 text-sm font-semibold text-white hover:bg-slate-800">Apply</button>
            {q ? <Link href="/internal/completion-loyalty-rewards/supplier-wallet-payments" className="rounded-lg border border-slate-300 px-4 py-2 text-center text-sm font-semibold text-slate-700 hover:bg-slate-50">Clear</Link> : null}
          </div>
        </form>

        <form action={createCompletionLoyaltySupplierWalletBatchAction} className="rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 p-4">
            <div>
              <h2 className="text-lg font-semibold text-slate-950">Candidate rows</h2>
              <p className="mt-1 text-xs text-slate-500">Select ready rows, create a cash batch, then post from the batch detail page.</p>
            </div>
            <div className="flex flex-wrap items-center gap-3">
              <input
                name="notes"
                placeholder="Batch notes"
                className="w-72 rounded-lg border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-slate-900 focus:outline-none focus:ring-1 focus:ring-slate-900"
              />
              <button disabled={readyRows.length === 0} className="rounded-lg bg-emerald-900 px-4 py-2 text-sm font-semibold text-white hover:bg-emerald-800 disabled:bg-slate-200 disabled:text-slate-500">
                Create supplier wallet cash batch
              </button>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-100 text-left text-xs font-bold uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-4 py-3">Select</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Order</th>
                  <th className="px-4 py-3">Importer</th>
                  <th className="px-4 py-3">Supplier</th>
                  <th className="px-4 py-3">Invoice</th>
                  <th className="px-4 py-3">Wallet</th>
                  <th className="px-4 py-3 text-right">Amount</th>
                  <th className="px-4 py-3">Batch</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? (
                  <tr>
                    <td colSpan={9} className="px-4 py-8 text-center text-slate-500">No supplier wallet payment candidates match this filter.</td>
                  </tr>
                ) : rows.map((row) => (
                  <tr key={row.order_funding_event_id ?? `${row.order_ref}-${row.wallet_code}`} className="align-top">
                    <td className="px-4 py-4">
                      <input
                        type="checkbox"
                        name="order_funding_event_id"
                        value={row.order_funding_event_id ?? ""}
                        disabled={!canSelect(row)}
                        className="h-4 w-4 rounded border-slate-300 text-emerald-700 focus:ring-emerald-700 disabled:opacity-40"
                      />
                    </td>
                    <td className="px-4 py-4">
                      <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-semibold ring-1 ${statusClass(row.readiness_status)}`}>{friendly(row.readiness_status)}</span>
                      {row.blocker ? <p className="mt-2 max-w-xs text-xs font-semibold text-rose-700">{friendly(row.blocker)}</p> : null}
                    </td>
                    <td className="px-4 py-4 font-semibold text-slate-950">{row.order_ref ?? "-"}</td>
                    <td className="px-4 py-4 text-slate-700">{row.importer_name ?? "-"}</td>
                    <td className="px-4 py-4 text-slate-700">{row.retailer_name ?? "-"}</td>
                    <td className="px-4 py-4">
                      <p className="font-semibold text-slate-950">{row.supplier_invoice_ref ?? "-"}</p>
                      <p className="mt-1 max-w-xs truncate text-xs text-slate-500">Sage PI {row.target_sage_purchase_invoice_id ?? "-"}</p>
                    </td>
                    <td className="px-4 py-4">
                      <p className="font-semibold text-slate-950">{friendly(row.wallet_code)}</p>
                      <p className="mt-1 max-w-xs truncate text-xs text-slate-500">{row.wallet_bank_account_mapping_code ?? "-"}</p>
                      <p className="mt-1 max-w-xs truncate text-xs text-slate-500">{row.wallet_sage_bank_account_id ?? "-"}</p>
                    </td>
                    <td className="px-4 py-4 text-right font-semibold text-slate-950">{money(row.amount_gbp)}</td>
                    <td className="px-4 py-4">
                      {row.existing_batch_id ? (
                        <Link href={`/internal/accounting-command-centre/cash-posting/batches/${row.existing_batch_id}`} className="font-semibold text-sky-700 hover:text-sky-900">
                          {row.existing_batch_ref ?? "Open batch"}
                        </Link>
                      ) : row.existing_batch_ref ? row.existing_batch_ref : "-"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </form>
      </div>
    </main>
  );
}
