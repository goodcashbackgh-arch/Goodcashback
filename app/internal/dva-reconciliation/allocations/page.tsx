import Link from "next/link";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import { reverseDvaStatementLineAllocationAction } from "../actions";
import { reverseMainBankShipperAllocationAction } from "../main-bank-shipper-actions";

type SearchParams = {
  status?: string;
  importer_id?: string;
  family?: string;
  allocation_error?: string;
  allocation_success?: string;
};

type AllocationFamily = "dva_allocation" | "main_bank_shipper_ap";

type AllocationDetailRow = {
  allocation_family: AllocationFamily;
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
  shipping_document_id: string | null;
  shipper_invoice_ref: string | null;
  shipper_id: string | null;
  shipper_name: string | null;
  sage_purchase_invoice_id: string | null;
};

type StatementControlRow = {
  statement_line_id: string;
  active_consumed_gbp: number | string | null;
  active_reserved_gbp: number | string | null;
  remaining_unconsumed_gbp: number | string | null;
  overconsumed_gbp: number | string | null;
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

function numeric(value: number | string | null | undefined) {
  const amount = typeof value === "number" ? value : Number(value ?? 0);
  return Number.isFinite(amount) ? amount : 0;
}

function pretty(value: string | null | undefined) {
  return value ? cleanUiText(value.replaceAll("_", " ")) : "—";
}

function tone(status: string | null | undefined) {
  if (status === "confirmed") return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (status === "held") return "border-amber-200 bg-amber-50 text-amber-800";
  if (status === "reversed") return "border-slate-200 bg-slate-100 text-slate-600";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function targetLabel(row: AllocationDetailRow) {
  if (row.allocation_family === "main_bank_shipper_ap") {
    return row.shipper_invoice_ref
      ? `Shipper AP · ${cleanUiText(row.shipper_invoice_ref)}`
      : "Main-bank shipper AP";
  }
  if (row.allocation_type === "supplier_invoice") return row.supplier_invoice_ref || "Supplier charge record";
  if (row.allocation_type === "retailer_refund") return "Retailer refund";
  if (row.allocation_type === "exception_hold") return "Exception / replacement hold";
  if (row.allocation_type === "not_charged_closure") return "Not charged closure";
  if (row.allocation_type === "fx_card_difference") return "FX/payment variance";
  if (row.allocation_type === "bank_fee") return "Bank/payment fee";
  if (row.allocation_type === "unmatched_hold") return "Unmatched hold";
  return pretty(row.allocation_type);
}

function sourceText(row: AllocationDetailRow) {
  return cleanUiText(row.statement_description || row.statement_reference || "No statement text");
}

function sourceState(statement: number, used: number, open: number, over: number) {
  if (over > 0.005) return "overconsumed";
  if (used <= 0.005) return "unmatched";
  if (open > 0.01) return "part allocated";
  if (statement > 0) return "balanced";
  return "review";
}

export default async function DvaAllocationReviewPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const requestedStatus = params.status || "confirmed";
  const status = ["confirmed", "held", "reversed"].includes(requestedStatus) ? requestedStatus : "confirmed";
  const importerId = params.importer_id || "";
  const requestedFamily = params.family || "all";
  const family = ["all", "dva_allocation", "main_bank_shipper_ap"].includes(requestedFamily) ? requestedFamily : "all";
  const workspacePath = `/internal/dva-reconciliation/workspace${importerId ? `?importer_id=${encodeURIComponent(importerId)}` : ""}`;
  const reviewParams = new URLSearchParams();
  reviewParams.set("status", status);
  if (importerId) reviewParams.set("importer_id", importerId);
  if (family !== "all") reviewParams.set("family", family);
  const reviewPath = `/internal/dva-reconciliation/allocations?${reviewParams.toString()}`;
  const supabase = await createClient();

  let query = supabase
    .from("statement_line_matching_review_v1")
    .select("allocation_family, allocation_id, importer_id, dva_statement_line_id, transaction_date, statement_date, statement_description, statement_reference, statement_direction, statement_gbp_amount, allocation_type, allocation_status, supplier_invoice_ref, dispute_id, order_ref, allocated_gbp_amount, notes, created_at, shipping_document_id, shipper_invoice_ref, shipper_id, shipper_name, sage_purchase_invoice_id")
    .eq("allocation_status", status)
    .order("created_at", { ascending: false })
    .limit(200);

  if (importerId) query = query.eq("importer_id", importerId);
  if (family !== "all") query = query.eq("allocation_family", family);

  const { data, error } = await query;
  const rows = (data ?? []) as AllocationDetailRow[];
  const lineIds = [...new Set(rows.map((row) => row.dva_statement_line_id).filter(Boolean))];

  let controlQuery = supabase
    .from("statement_line_control_position_v1")
    .select("statement_line_id, active_consumed_gbp, active_reserved_gbp, remaining_unconsumed_gbp, overconsumed_gbp")
    .limit(500);

  if (lineIds.length > 0) controlQuery = controlQuery.in("statement_line_id", lineIds);

  const { data: controlData } = await controlQuery;
  const controlByLineId = new Map(
    ((controlData ?? []) as StatementControlRow[]).map((row) => [row.statement_line_id, row])
  );

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-7xl space-y-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.25em] text-sky-600">Payment statement matching</p>
            <h1 className="mt-2 text-2xl font-bold tracking-tight">Active matching records</h1>
            <p className="mt-1 max-w-3xl text-sm text-slate-600">
              One card = one matching record across DVA allocations and main-bank shipper AP. Source used/open comes from the amount-aware statement control position.
            </p>
          </div>
          <Link href={workspacePath} className="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm hover:bg-slate-50">
            Back to workspace
          </Link>
        </div>

        {params.allocation_error ? (
          <div className="rounded-2xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm font-semibold text-rose-700">{cleanUiText(params.allocation_error)}</div>
        ) : null}

        {params.allocation_success ? (
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm font-semibold text-emerald-700">{cleanUiText(params.allocation_success)}</div>
        ) : null}

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form className="flex flex-wrap gap-3" action="/internal/dva-reconciliation/allocations">
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Status
              <select name="status" defaultValue={status} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="confirmed">Confirmed</option>
                <option value="held">Held</option>
                <option value="reversed">Reversed</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Allocation family
              <select name="family" defaultValue={family} className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900">
                <option value="all">All</option>
                <option value="dva_allocation">DVA allocations</option>
                <option value="main_bank_shipper_ap">Main-bank shipper AP</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-semibold text-slate-600">
              Importer ID
              <input name="importer_id" defaultValue={importerId} placeholder="Optional importer UUID" className="min-w-0 rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 sm:min-w-72" />
            </label>
            <button className="self-end rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white" type="submit">Apply filters</button>
          </form>
        </section>

        <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-700">
            Showing {rows.length} matching record(s)
          </div>

          {error ? (
            <div className="p-4 text-sm font-semibold text-rose-700">{cleanUiText(error.message)}</div>
          ) : rows.length === 0 ? (
            <div className="p-8 text-center text-sm text-slate-500">No matching records found for this filter.</div>
          ) : (
            <div className="divide-y divide-slate-100">
              {rows.map((row) => {
                const allocated = numeric(row.allocated_gbp_amount);
                const statement = numeric(row.statement_gbp_amount);
                const control = controlByLineId.get(row.dva_statement_line_id);
                const sourceUsedNow = control
                  ? numeric(control.active_consumed_gbp) + numeric(control.active_reserved_gbp)
                  : allocated;
                const sourceOpenNow = control
                  ? numeric(control.remaining_unconsumed_gbp)
                  : Math.max(0, statement - allocated);
                const sourceOverNow = control ? numeric(control.overconsumed_gbp) : 0;
                const direction = String(row.statement_direction || "—").toUpperCase();
                const sourceDate = row.transaction_date || row.statement_date || "No date";
                const currentSourceState = sourceState(statement, sourceUsedNow, sourceOpenNow, sourceOverNow);
                const reverseAction = row.allocation_family === "main_bank_shipper_ap"
                  ? reverseMainBankShipperAllocationAction
                  : reverseDvaStatementLineAllocationAction;

                return (
                  <article key={`${row.allocation_family}:${row.allocation_id}`} className="grid min-w-0 gap-3 p-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
                    <div className="min-w-0 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
                      <div className="flex min-w-0 flex-wrap items-center gap-2">
                        <span className={`rounded-full border px-2.5 py-1 text-xs font-semibold ${tone(row.allocation_status)}`}>{pretty(row.allocation_status)}</span>
                        <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs font-semibold text-slate-700">{direction}</span>
                        <span className="rounded-full border border-sky-200 bg-sky-50 px-2.5 py-1 text-xs font-semibold text-sky-800">{targetLabel(row)}</span>
                        <span className="rounded-full border border-violet-200 bg-violet-50 px-2.5 py-1 text-xs font-semibold text-violet-800">{pretty(row.allocation_family)}</span>
                        <span className="rounded-full border border-indigo-200 bg-indigo-50 px-2.5 py-1 text-xs font-semibold text-indigo-800">source {currentSourceState}</span>
                      </div>

                      <div className="mt-3 grid min-w-0 gap-3 sm:grid-cols-4">
                        <div className="min-w-0">
                          <p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">This row</p>
                          <p className="text-2xl font-bold text-slate-950">{gbp(allocated)}</p>
                        </div>
                        <div className="min-w-0">
                          <p className="text-[11px] font-bold uppercase tracking-wide text-slate-500">Source line</p>
                          <p className="text-lg font-semibold text-slate-900">{gbp(statement)}</p>
                          <p className="text-xs text-slate-500">{sourceDate}</p>
                        </div>
                        <div className="min-w-0 rounded-xl border border-emerald-200 bg-emerald-50 p-3">
                          <p className="text-[11px] font-bold uppercase tracking-wide text-emerald-700">Source used now</p>
                          <p className="text-xl font-extrabold text-emerald-900">{gbp(sourceUsedNow)}</p>
                        </div>
                        <div className="min-w-0 rounded-xl border border-amber-200 bg-amber-50 p-3">
                          <p className="text-[11px] font-bold uppercase tracking-wide text-amber-700">Source open now</p>
                          <p className="text-xl font-extrabold text-amber-900">{gbp(sourceOpenNow)}</p>
                        </div>
                      </div>

                      <div className="mt-3 min-w-0 rounded-xl bg-slate-50 p-3 text-sm text-slate-600">
                        <p className="break-words font-semibold text-slate-900 [overflow-wrap:anywhere]">→ {targetLabel(row)}</p>
                        <p className="mt-1 break-words [overflow-wrap:anywhere]">Source: {sourceText(row)}</p>
                        {row.allocation_family === "main_bank_shipper_ap" ? (
                          <p className="mt-1 break-words text-xs text-slate-500 [overflow-wrap:anywhere]">
                            Shipper {row.shipper_name || "—"} · Shipping document {row.shipping_document_id || "—"} · Sage AP {row.sage_purchase_invoice_id || "—"}
                          </p>
                        ) : (
                          <p className="mt-1 break-words text-xs text-slate-500 [overflow-wrap:anywhere]">Order {row.order_ref || "—"} · Dispute {row.dispute_id || "—"}</p>
                        )}
                      </div>
                    </div>

                    {row.allocation_status === "confirmed" || (row.allocation_family === "dva_allocation" && row.allocation_status === "held") ? (
                      <form action={reverseAction} className="grid min-w-0 gap-2 rounded-2xl border border-slate-200 bg-white p-4 lg:w-80 lg:max-w-80">
                        <p className="break-words text-xs font-semibold text-slate-600 [overflow-wrap:anywhere]">Reverse only this {gbp(allocated)} matching row.</p>
                        {row.allocation_family === "main_bank_shipper_ap" ? (
                          <p className="text-xs text-slate-500">Blocked automatically if this match has already been frozen into cash posting.</p>
                        ) : null}
                        <input type="hidden" name="allocation_id" value={row.allocation_id} />
                        <input type="hidden" name="return_path" value={reviewPath} />
                        <input name="reversal_reason" placeholder="Reason" className="min-w-0 rounded-xl border border-slate-200 px-3 py-2 text-sm text-slate-900" minLength={8} required />
                        <button className="whitespace-normal break-words rounded-xl bg-rose-600 px-3 py-2 text-sm font-semibold text-white hover:bg-rose-700 [overflow-wrap:anywhere]" type="submit">Reverse this match only</button>
                      </form>
                    ) : null}
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
