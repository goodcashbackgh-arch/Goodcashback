import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { reverseDvaStatementLineAllocationAction } from "../actions";

type SearchParams = {
  status?: string;
  importer_id?: string;
  allocation_error?: string;
  allocation_success?: string;
};

type AllocationDetailRow = {
  allocation_id: string;
  importer_id: string | null;
  dva_statement_line_id: string;
  transaction_date: string | null;
  statement_date: string | null;
  statement_description: string | null;
  statement_reference: string | null;
  statement_direction: "in" | "out" | string | null;
  statement_gbp_amount: number | string | null;
  allocation_type: string | null;
  allocation_status: string | null;
  supplier_invoice_ref: string | null;
  dispute_id: string | null;
  order_ref: string | null;
  allocated_gbp_amount: number | string | null;
  notes: string | null;
  created_at: string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function gbp(value: number | string | null | undefined) {
  const amount = typeof value === "number" ? value : Number(value ?? 0);
  return gbpFormatter.format(Number.isFinite(amount) ? amount : 0);
}

function pretty(value: string | null | undefined) {
  return value ? value.replaceAll("_", " ") : "—";
}

function tone(status: string | null | undefined) {
  if (status === "confirmed") return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (status === "reversed") return "border-rose-200 bg-rose-50 text-rose-800";
  if (status === "held") return "border-amber-200 bg-amber-50 text-amber-800";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

export default async function DvaAllocationReviewPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const status = params.status || "confirmed";
  const importerId = params.importer_id || "";
  const workspacePath = `/internal/dva-reconciliation/workspace${importerId ? `?importer_id=${encodeURIComponent(importerId)}` : ""}`;
  const supabase = await createClient();

  let query = supabase
    .from("dva_statement_line_allocation_detail_vw")
    .select("allocation_id, importer_id, dva_statement_line_id, transaction_date, statement_date, statement_description, statement_reference, statement_direction, statement_gbp_amount, allocation_type, allocation_status, supplier_invoice_ref, dispute_id, order_ref, allocated_gbp_amount, notes, created_at")
    .order("created_at", { ascending: false })
    .limit(200);

  if (status !== "all") query = query.eq("allocation_status", status);
  if (importerId) query = query.eq("importer_id", importerId);

  const { data, error } = await query;
  const rows = (data ?? []) as AllocationDetailRow[];

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.25em] text-sky-600">DVA/card reconciliation</p>
            <h1 className="mt-2 text-2xl font-bold tracking-tight">Allocation review</h1>
            <p className="mt-1 max-w-3xl text-sm text-slate-600">
              Supervisor review of active statement-line allocations before downstream accounting/Sage control. Reversed rows stay in the audit trail, but the normal working view is confirmed/held only.
            </p>
          </div>
          <Link
            href={workspacePath}
            className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm hover:bg-slate-50"
          >
            Back to workspace
          </Link>
        </div>

        {params.allocation_error ? (
          <div className="rounded-2xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm font-semibold text-rose-700">
            {params.allocation_error}
          </div>
        ) : null}

        {params.allocation_success ? (
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-700">
            {params.allocation_success}
          </div>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="flex flex-wrap gap-3" action="/internal/dva-reconciliation/allocations">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Status
              <select name="status" defaultValue={status} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="confirmed">Confirmed</option>
                <option value="held">Held</option>
                <option value="reversed">Reversed audit</option>
                <option value="all">All including reversed</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer ID
              <input
                name="importer_id"
                defaultValue={importerId}
                placeholder="Optional importer UUID"
                className="min-w-72 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900"
              />
            </label>
            <button className="self-end rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">
              Apply filters
            </button>
          </form>
        </section>

        <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">
            Showing {rows.length} allocation(s)
          </div>

          {error ? (
            <div className="p-4 text-sm font-semibold text-rose-700">{error.message}</div>
          ) : rows.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No allocations found for this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {rows.map((row) => {
                return (
                  <article key={row.allocation_id} className="grid gap-4 p-4 lg:grid-cols-[1.2fr_1fr_auto] lg:items-start">
                    <div className="space-y-2">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className={`rounded-full border px-2.5 py-1 text-xs font-semibold ${tone(row.allocation_status)}`}>
                          {pretty(row.allocation_status)}
                        </span>
                        <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs font-semibold text-slate-700">
                          {pretty(row.allocation_type)}
                        </span>
                        <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs font-semibold text-slate-700">
                          {String(row.statement_direction || "—").toUpperCase()}
                        </span>
                      </div>
                      <p className="font-semibold text-slate-950">{gbp(row.allocated_gbp_amount)} allocated</p>
                      <p className="text-sm text-slate-600">
                        Statement: {gbp(row.statement_gbp_amount)} · {row.transaction_date || row.statement_date || "No date"}
                      </p>
                      <p className="line-clamp-2 text-sm text-slate-500">{row.statement_description || row.statement_reference || "No statement description"}</p>
                    </div>

                    <div className="space-y-1 rounded-2xl bg-slate-50 p-3 text-sm text-slate-600">
                      <p><span className="font-semibold text-slate-700">Supplier invoice:</span> {row.supplier_invoice_ref || "—"}</p>
                      <p><span className="font-semibold text-slate-700">Order:</span> {row.order_ref || "—"}</p>
                      <p><span className="font-semibold text-slate-700">Dispute:</span> {row.dispute_id || "—"}</p>
                      <p><span className="font-semibold text-slate-700">Notes:</span> {row.notes || "—"}</p>
                    </div>

                    {row.allocation_status === "confirmed" || row.allocation_status === "held" ? (
                      <form action={reverseDvaStatementLineAllocationAction} className="grid min-w-64 gap-2 rounded-2xl border border-slate-200 bg-white p-3">
                        <input type="hidden" name="allocation_id" value={row.allocation_id} />
                        <input type="hidden" name="return_path" value={workspacePath} />
                        <label className="grid gap-1 text-xs font-semibold text-slate-600">
                          Reversal reason
                          <input
                            name="reversal_reason"
                            placeholder="Why reverse this allocation?"
                            className="rounded-xl border border-slate-200 px-3 py-2 text-sm text-slate-900"
                            minLength={8}
                            required
                          />
                        </label>
                        <button className="rounded-xl bg-rose-600 px-3 py-2 text-sm font-semibold text-white hover:bg-rose-700" type="submit">
                          Reverse this allocation only
                        </button>
                      </form>
                    ) : (
                      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-3 text-sm text-slate-500">No action available.</div>
                    )}
                  </article>
                );
              })}
            </div>
          )}
        </section>
      </div>
    </main>
  );
}
