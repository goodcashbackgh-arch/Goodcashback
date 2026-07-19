import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { allocateSupplierPaymentBundleAction } from "./actions";

type SearchParams = { line_id?: string; order_id?: string; success?: string; error?: string };
type Row = Record<string, unknown>;

function text(value: unknown) {
  return typeof value === "string" ? value : value == null ? "" : String(value);
}

function num(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(value));
}

export default async function MultiInvoiceSupplierPaymentPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const qp = searchParams ? await searchParams : {};
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, role_type, full_name")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();
  if (!staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const [{ data: statementRows }, { data: candidateRows }] = await Promise.all([
    supabase
      .from("dva_statement_line_allocation_summary_vw")
      .select("dva_statement_line_id, importer_id, statement_date, reference_raw, retailer_name_ref, direction, statement_gbp_amount, confirmed_allocated_gbp, confirmed_unallocated_gbp, active_allocation_count, confirmed_balanced_yn")
      .eq("direction", "out")
      .order("statement_date", { ascending: false })
      .limit(300),
    supabase
      .from("supplier_payment_candidate_status_vw")
      .select("supplier_invoice_id, order_id, order_ref, importer_id, retailer_id, invoice_ref, review_status, invoice_total_gbp, confirmed_matched_gbp, remaining_unmatched_gbp, supplier_payment_ready_yn, blocker, selectable_yn")
      .order("order_ref", { ascending: false })
      .limit(500),
  ]);

  const statements = (statementRows ?? []) as Row[];
  const candidates = (candidateRows ?? []) as Row[];
  const selectedLineId = qp.line_id || text(statements.find((row) => !row.confirmed_balanced_yn && num(row.active_allocation_count) === 0)?.dva_statement_line_id);
  const selectedLine = statements.find((row) => text(row.dva_statement_line_id) === selectedLineId);
  const selectedImporterId = text(selectedLine?.importer_id);
  const eligibleCandidates = candidates.filter(
    (row) => !selectedImporterId || text(row.importer_id) === selectedImporterId,
  );

  const orderIds = [...new Set(eligibleCandidates.map((row) => text(row.order_id)).filter(Boolean))];
  const selectedOrderId = qp.order_id && orderIds.includes(qp.order_id) ? qp.order_id : orderIds[0] ?? "";
  const selectedOrderInvoices = eligibleCandidates.filter((row) => text(row.order_id) === selectedOrderId);
  const statementAmount = num(selectedLine?.statement_gbp_amount);
  const hasExistingAllocation = num(selectedLine?.active_allocation_count) > 0;

  const href = (lineId: string, orderId = "") => {
    const params = new URLSearchParams({ line_id: lineId });
    if (orderId) params.set("order_id", orderId);
    return `/internal/dva-reconciliation/multi-invoice?${params.toString()}`;
  };

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/dva-reconciliation/workspace" className="text-sm font-semibold text-sky-700">← Back to DVA/card workspace</Link>
          <p className="mt-6 text-sm font-semibold uppercase tracking-[0.2em] text-sky-600">Multi-invoice supplier payment</p>
          <h1 className="mt-2 text-3xl font-semibold">Allocate one physical OUT across several supplier invoices</h1>
          <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
            This is one atomic action. Every selected invoice must belong to the same order, the allocation amounts must total the full OUT exactly, and all resulting rows inherit one source resolution. A failure writes nothing.
          </p>
          <p className="mt-2 text-sm text-slate-500">{staff.full_name} · {staff.role_type}</p>
          {qp.success ? <p className="mt-4 rounded-xl border border-emerald-300 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">{qp.success}</p> : null}
          {qp.error ? <p className="mt-4 rounded-xl border border-rose-300 bg-rose-50 px-3 py-2 text-sm text-rose-900">{qp.error}</p> : null}
        </section>

        <section className="grid gap-4 lg:grid-cols-[1fr_1.4fr]">
          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">1. Select the physical OUT</h2>
            <div className="mt-4 max-h-[65vh] space-y-3 overflow-y-auto">
              {statements.map((row) => {
                const id = text(row.dva_statement_line_id);
                const active = id === selectedLineId;
                const blocked = Boolean(row.confirmed_balanced_yn) || num(row.active_allocation_count) > 0;
                return (
                  <Link
                    key={id}
                    href={href(id)}
                    className={`block rounded-2xl border p-4 ${active ? "border-sky-500 bg-sky-50 ring-2 ring-sky-200" : blocked ? "border-slate-200 bg-slate-100" : "border-slate-200 bg-white"}`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div>
                        <p className="font-semibold">{text(row.statement_date)} · {gbp(row.statement_gbp_amount)}</p>
                        <p className="mt-1 break-words text-sm text-slate-600">{text(row.reference_raw) || text(row.retailer_name_ref) || "No statement description"}</p>
                      </div>
                      <span className="rounded-full bg-white px-2 py-1 text-xs font-semibold ring-1 ring-slate-200">
                        {blocked ? "Already allocated" : "Open"}
                      </span>
                    </div>
                  </Link>
                );
              })}
            </div>
          </div>

          <div className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-xl font-semibold">2. Select one order and enter invoice allocations</h2>
            {!selectedLine ? <p className="mt-4 text-sm text-amber-800">Select an OUT statement line.</p> : null}
            {selectedLine ? (
              <div className="mt-4 rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-950">
                <p className="font-semibold">OUT total: {gbp(statementAmount)}</p>
                <p className="mt-1">Existing active allocations: {num(selectedLine.active_allocation_count)} · Unallocated: {gbp(selectedLine.confirmed_unallocated_gbp)}</p>
              </div>
            ) : null}

            <div className="mt-5 flex flex-wrap gap-2">
              {orderIds.map((orderId) => {
                const first = eligibleCandidates.find((row) => text(row.order_id) === orderId);
                return (
                  <Link
                    key={orderId}
                    href={href(selectedLineId, orderId)}
                    className={`rounded-full px-4 py-2 text-sm font-semibold ${orderId === selectedOrderId ? "bg-slate-950 text-white" : "border border-slate-300 bg-white text-slate-800"}`}
                  >
                    {text(first?.order_ref) || orderId} · {eligibleCandidates.filter((row) => text(row.order_id) === orderId).length} invoice(s)
                  </Link>
                );
              })}
            </div>

            {selectedOrderId ? (
              <form action={allocateSupplierPaymentBundleAction} className="mt-5 space-y-4">
                <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
                <input type="hidden" name="order_id" value={selectedOrderId} />
                {selectedOrderInvoices.map((invoice) => {
                  const invoiceId = text(invoice.supplier_invoice_id);
                  const selectable = Boolean(invoice.selectable_yn);
                  return (
                    <article key={invoiceId} className={`rounded-2xl border p-4 ${selectable ? "border-slate-200 bg-white" : "border-amber-200 bg-amber-50"}`}>
                      <input type="hidden" name="supplier_invoice_ids" value={invoiceId} />
                      <div className="grid gap-3 md:grid-cols-[1fr_180px] md:items-end">
                        <div>
                          <p className="font-semibold">Invoice {text(invoice.invoice_ref)}</p>
                          <p className="mt-1 text-sm text-slate-600">Total {gbp(invoice.invoice_total_gbp)} · already matched {gbp(invoice.confirmed_matched_gbp)} · remaining {gbp(invoice.remaining_unmatched_gbp)}</p>
                          <p className="mt-1 text-xs text-slate-500">Status {text(invoice.review_status)} · payment ready {invoice.supplier_payment_ready_yn ? "Yes" : "No"}</p>
                          {text(invoice.blocker) ? <p className="mt-1 text-xs font-semibold text-amber-800">Blocker: {text(invoice.blocker)}</p> : null}
                        </div>
                        <label className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                          Allocate GBP
                          <input
                            name={`amount_${invoiceId}`}
                            type="number"
                            min="0"
                            max={num(invoice.remaining_unmatched_gbp)}
                            step="0.01"
                            disabled={!selectable}
                            className="mt-1 w-full rounded-xl border border-slate-300 px-3 py-2 text-base font-semibold text-slate-950 disabled:bg-slate-100"
                            placeholder="0.00"
                          />
                        </label>
                      </div>
                    </article>
                  );
                })}
                <textarea name="notes" rows={3} className="w-full rounded-xl border border-slate-300 px-3 py-2 text-sm" placeholder="Optional allocation note" />
                <button
                  disabled={!selectedLine || hasExistingAllocation || selectedOrderInvoices.every((row) => !row.selectable_yn)}
                  className="rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white disabled:bg-slate-300 disabled:text-slate-600"
                >
                  Allocate full OUT atomically
                </button>
                <p className="text-xs text-slate-500">The database rejects partial totals, cross-order invoice combinations, duplicate invoices, over-allocation, unresolved funding provenance, or any previously allocated OUT.</p>
              </form>
            ) : <p className="mt-5 text-sm text-slate-500">No supplier-payment candidates are available for the selected importer.</p>}
          </div>
        </section>
      </div>
    </main>
  );
}
