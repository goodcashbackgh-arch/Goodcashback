import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { cleanUiText } from "@/lib/ui/cleanUiText";
import { reverseTreasuryAllocationAction } from "./actions";

type SearchParams = {
  line_id?: string;
  status?: string;
  success?: string;
  error?: string;
};

type Row = Record<string, unknown>;

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return "";
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(value));
}

function friendly(value: unknown) {
  const raw = text(value);
  if (!raw) return "—";
  return cleanUiText(raw.replaceAll("_", " ").replace(/^./, (first) => first.toUpperCase()));
}

function statusTone(status: string) {
  if (status === "confirmed") return "border-emerald-200 bg-emerald-50 text-emerald-800";
  if (status === "held") return "border-amber-200 bg-amber-50 text-amber-800";
  if (status === "reversed") return "border-slate-200 bg-slate-100 text-slate-700";
  return "border-sky-200 bg-sky-50 text-sky-800";
}

function targetLabel(row: Row) {
  const type = text(row.allocation_type);
  if (type === "supplier_invoice") return text(row.supplier_invoice_ref) || "Supplier invoice";
  if (type === "retailer_refund") return "Retailer refund";
  if (type === "exception_hold") return "Exception / replacement hold";
  if (type === "not_charged_closure") return "Not charged closure";
  if (type === "fx_card_difference") return "FX / card difference";
  if (type === "bank_fee") return "Bank / payment fee";
  if (type === "unmatched_hold") return "Unmatched hold";
  return friendly(type);
}

function lineHref(lineId: string, status: string) {
  const params = new URLSearchParams();
  if (lineId) params.set("line_id", lineId);
  if (status) params.set("status", status);
  return `/internal/dva-reconciliation/reversal-control?${params.toString()}`;
}

export default async function TreasuryReversalControlPage({
  searchParams,
}: {
  searchParams?: Promise<SearchParams>;
}) {
  const params = searchParams ? await searchParams : {};
  const requestedStatus = text(params.status) || "active";
  const status = ["active", "confirmed", "held", "reversed"].includes(requestedStatus) ? requestedStatus : "active";

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

  const detailResult = await supabase
    .from("dva_statement_line_allocation_detail_vw")
    .select(
      "allocation_id, importer_id, dva_statement_line_id, transaction_date, statement_date, statement_description, statement_reference, statement_direction, statement_gbp_amount, allocation_type, allocation_status, supplier_invoice_ref, dispute_id, order_ref, allocated_gbp_amount, notes, created_at",
    )
    .order("created_at", { ascending: false })
    .limit(500);

  const allDetailRows = (detailResult.data ?? []) as Row[];
  const visibleRows = allDetailRows.filter((row) => {
    const rowStatus = text(row.allocation_status);
    if (status === "active") return ["confirmed", "held"].includes(rowStatus);
    return rowStatus === status;
  });

  const requestedLineId = text(params.line_id);
  const selectedLineId = visibleRows.some((row) => text(row.dva_statement_line_id) === requestedLineId)
    ? requestedLineId
    : text(visibleRows[0]?.dva_statement_line_id);

  const selectedDetailRows = selectedLineId
    ? allDetailRows.filter((row) => text(row.dva_statement_line_id) === selectedLineId)
    : [];

  const [historyResult, resolverResult] = selectedLineId
    ? await Promise.all([
        supabase
          .from("dva_statement_line_allocations")
          .select(
            "id, dva_statement_line_id, allocation_type, supplier_invoice_id, dispute_id, order_id, allocated_gbp_amount, allocation_status, source_bank_account_mapping_code, source_wallet_code, notes, created_at, confirmed_at, reversed_at, reversal_reason",
          )
          .eq("dva_statement_line_id", selectedLineId)
          .order("created_at", { ascending: true }),
        (supabase as any).rpc("internal_statement_line_control_resolver_v2", {
          p_statement_line_id: selectedLineId,
        }),
      ])
    : [{ data: [], error: null }, { data: [], error: null }];

  const historyRows = (historyResult.data ?? []) as Row[];
  const resolverRows = (resolverResult.data ?? []) as Row[];
  const resolver = resolverRows[0] ?? null;

  const activeRows = historyRows.filter((row) => ["confirmed", "held"].includes(text(row.allocation_status)));
  const reversedRows = historyRows.filter((row) => text(row.allocation_status) === "reversed");
  const activeAllocated = activeRows.reduce((sum, row) => sum + num(row.allocated_gbp_amount), 0);
  const reversedAllocated = reversedRows.reduce((sum, row) => sum + num(row.allocated_gbp_amount), 0);
  const activeTypes = [...new Set(activeRows.map((row) => text(row.allocation_type)).filter(Boolean))];

  const lineGroups = new Map<string, Row[]>();
  for (const row of visibleRows) {
    const lineId = text(row.dva_statement_line_id);
    if (!lineId) continue;
    const group = lineGroups.get(lineId) ?? [];
    group.push(row);
    lineGroups.set(lineId, group);
  }

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-7xl space-y-6">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <Link href="/internal/dva-reconciliation/control-summary" className="text-sm font-semibold text-sky-700 hover:text-sky-900">
                ← Treasury statement-control summary
              </Link>
              <p className="mt-6 text-sm font-semibold uppercase tracking-[0.2em] text-rose-600">Treasury reversal control</p>
              <h1 className="mt-2 text-3xl font-semibold">Reverse one economic-use row without deleting evidence</h1>
              <p className="mt-3 max-w-5xl text-sm leading-6 text-slate-600">
                Reversal changes only the selected allocation row to reversed, preserves the original amount and audit history, and releases that value back to the statement-line control position.
              </p>
              <p className="mt-2 text-sm text-slate-500">{text(staff.full_name) || "Staff"} · {text(staff.role_type)}</p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Link href="/internal/dva-reconciliation/allocations" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">
                Existing allocation register
              </Link>
              <Link href="/internal/dva-reconciliation/statement-interpretation" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-xs font-bold text-slate-700 hover:bg-slate-50">
                Interpretation control
              </Link>
            </div>
          </div>

          {params.success ? (
            <div className="mt-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{params.success}</div>
          ) : null}
          {params.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">{params.error}</div>
          ) : null}
          {detailResult.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
              Allocation register unavailable: {detailResult.error.message}
            </div>
          ) : null}
          {historyResult.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
              Allocation history unavailable: {historyResult.error.message}
            </div>
          ) : null}
          {resolverResult.error ? (
            <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-900">
              Statement-line control position unavailable: {resolverResult.error.message}
            </div>
          ) : null}
        </section>

        <form method="get" className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-end gap-4">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Register view
              <select name="status" defaultValue={status} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-semibold text-slate-900">
                <option value="active">Active: confirmed and held</option>
                <option value="confirmed">Confirmed only</option>
                <option value="held">Held only</option>
                <option value="reversed">Reversed history</option>
              </select>
            </label>
            <label className="grid min-w-0 flex-1 gap-1 text-xs font-bold uppercase tracking-wide text-slate-500 sm:min-w-80">
              Statement-line ID
              <input name="line_id" defaultValue={selectedLineId} placeholder="Optional statement-line UUID" className="min-w-0 rounded-xl border border-slate-300 px-3 py-2 text-sm font-normal text-slate-900" />
            </label>
            <button className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white hover:bg-slate-800">Apply view</button>
            <Link href="/internal/dva-reconciliation/reversal-control" className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50">
              Clear
            </Link>
          </div>
        </form>

        <section className="grid gap-5 xl:grid-cols-[0.8fr_1.2fr]">
          <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-end justify-between gap-3">
              <div>
                <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Statement lines</p>
                <h2 className="mt-1 text-xl font-semibold">Select the economic-use chain</h2>
              </div>
              <span className="text-xs font-semibold text-slate-500">{lineGroups.size} lines</span>
            </div>

            <div className="mt-4 max-h-[76vh] space-y-3 overflow-y-auto pr-1">
              {lineGroups.size === 0 ? (
                <div className="rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No allocation rows match this register view.</div>
              ) : Array.from(lineGroups.entries()).map(([lineId, rows]) => {
                const first = rows[0];
                const selected = lineId === selectedLineId;
                const lineTotal = rows.reduce((sum, row) => sum + num(row.allocated_gbp_amount), 0);
                return (
                  <Link
                    key={lineId}
                    href={lineHref(lineId, status)}
                    className={`block rounded-2xl border p-4 transition ${selected ? "border-rose-400 bg-rose-50 ring-2 ring-rose-100" : "border-slate-200 bg-white hover:border-rose-200 hover:bg-rose-50"}`}
                  >
                    <div className="flex items-start justify-between gap-3">
                      <div className="min-w-0">
                        <p className="font-bold text-slate-950">{text(first.statement_date) || text(first.transaction_date) || "No date"} · {gbp(first.statement_gbp_amount)}</p>
                        <p className="mt-1 truncate text-sm text-slate-600">{text(first.statement_description) || text(first.statement_reference) || "No statement description"}</p>
                        <p className="mt-2 text-xs text-slate-500">{rows.length} matching row(s) · visible value {gbp(lineTotal)}</p>
                      </div>
                      <span className="rounded-full bg-white px-2.5 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">
                        {text(first.statement_direction).toUpperCase() || "?"}
                      </span>
                    </div>
                  </Link>
                );
              })}
            </div>
          </article>

          <div className="space-y-5">
            {!selectedLineId ? (
              <article className="rounded-3xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-600 shadow-sm">
                Select a statement line to inspect its complete allocation history.
              </article>
            ) : (
              <>
                <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                  <div className="flex flex-wrap items-start justify-between gap-4">
                    <div>
                      <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Current control position</p>
                      <h2 className="mt-1 text-xl font-semibold">Statement line {selectedLineId}</h2>
                      <p className="mt-2 text-sm text-slate-600">
                        {text(resolver?.statement_date) || text(selectedDetailRows[0]?.statement_date) || "No date"} · {gbp(resolver?.statement_gbp_amount || selectedDetailRows[0]?.statement_gbp_amount)} · {text(resolver?.effective_direction).toUpperCase() || text(selectedDetailRows[0]?.statement_direction).toUpperCase()}
                      </p>
                    </div>
                    <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700 ring-1 ring-slate-200">{friendly(resolver?.control_status)}</span>
                  </div>

                  <div className="mt-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
                    <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                      <p className="text-xs font-semibold text-slate-500">Statement amount</p>
                      <p className="mt-1 text-lg font-bold">{gbp(resolver?.statement_gbp_amount)}</p>
                    </div>
                    <div className="rounded-2xl bg-emerald-50 p-4 ring-1 ring-emerald-200">
                      <p className="text-xs font-semibold text-emerald-700">Active consumed</p>
                      <p className="mt-1 text-lg font-bold text-emerald-950">{gbp(resolver?.active_consumed_gbp || activeAllocated)}</p>
                    </div>
                    <div className="rounded-2xl bg-amber-50 p-4 ring-1 ring-amber-200">
                      <p className="text-xs font-semibold text-amber-700">Active reserved</p>
                      <p className="mt-1 text-lg font-bold text-amber-950">{gbp(resolver?.active_reserved_gbp)}</p>
                    </div>
                    <div className="rounded-2xl bg-sky-50 p-4 ring-1 ring-sky-200">
                      <p className="text-xs font-semibold text-sky-700">Remaining</p>
                      <p className="mt-1 text-lg font-bold text-sky-950">{gbp(resolver?.remaining_unconsumed_gbp)}</p>
                    </div>
                    <div className="rounded-2xl bg-slate-50 p-4 ring-1 ring-slate-200">
                      <p className="text-xs font-semibold text-slate-500">Reversed history</p>
                      <p className="mt-1 text-lg font-bold">{gbp(reversedAllocated)}</p>
                    </div>
                  </div>

                  <div className="mt-4 grid gap-3 lg:grid-cols-2">
                    <div className="rounded-2xl border border-slate-200 p-4 text-sm text-slate-700">
                      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Effective interpretation</p>
                      <p className="mt-2 font-semibold text-slate-950">{friendly(resolver?.effective_economic_classification)}</p>
                      <p className="mt-1 break-words text-xs leading-5 text-slate-500">{text(resolver?.effective_display_description) || "No display description"}</p>
                    </div>
                    <div className="rounded-2xl border border-slate-200 p-4 text-sm text-slate-700">
                      <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Active economic lanes</p>
                      <p className="mt-2 font-semibold text-slate-950">{activeTypes.length ? activeTypes.map(friendly).join(" · ") : "No active allocation rows"}</p>
                      <p className="mt-1 text-xs text-slate-500">Resolver next action: {friendly(resolver?.next_action)}</p>
                    </div>
                  </div>

                  {text(resolver?.blocker) ? (
                    <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950">
                      <p className="text-xs font-bold uppercase tracking-wide text-rose-700">Current blocker</p>
                      <p className="mt-1 font-semibold">{friendly(resolver?.blocker)}</p>
                    </div>
                  ) : null}
                </article>

                <article className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                  <div className="flex flex-wrap items-end justify-between gap-3">
                    <div>
                      <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">Allocation history</p>
                      <h2 className="mt-1 text-xl font-semibold">Reverse only the incorrect row</h2>
                    </div>
                    <p className="text-xs font-semibold text-slate-500">{historyRows.length} total rows</p>
                  </div>

                  <div className="mt-4 space-y-4">
                    {historyRows.length === 0 ? (
                      <div className="rounded-2xl border border-slate-200 bg-slate-50 p-5 text-sm text-slate-600">No allocation history exists for this statement line.</div>
                    ) : historyRows.map((row, index) => {
                      const detail = selectedDetailRows.find((candidate) => text(candidate.allocation_id) === text(row.id));
                      const rowStatus = text(row.allocation_status);
                      const reversible = ["confirmed", "held"].includes(rowStatus);
                      return (
                        <div key={text(row.id)} className={`rounded-2xl border p-4 ${rowStatus === "reversed" ? "border-slate-200 bg-slate-50" : "border-slate-200 bg-white"}`}>
                          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px] lg:items-start">
                            <div className="min-w-0">
                              <div className="flex flex-wrap items-center gap-2">
                                <span className={`rounded-full border px-2.5 py-1 text-xs font-bold ${statusTone(rowStatus)}`}>{friendly(rowStatus)}</span>
                                <span className="rounded-full border border-sky-200 bg-sky-50 px-2.5 py-1 text-xs font-bold text-sky-800">{friendly(row.allocation_type)}</span>
                                <span className="rounded-full border border-slate-200 bg-slate-50 px-2.5 py-1 text-xs font-bold text-slate-700">Row {index + 1}</span>
                              </div>
                              <p className="mt-3 text-2xl font-bold text-slate-950">{gbp(row.allocated_gbp_amount)}</p>
                              <p className="mt-2 font-semibold text-slate-900">→ {detail ? targetLabel(detail) : friendly(row.allocation_type)}</p>
                              <p className="mt-1 text-xs text-slate-500">Order {text(detail?.order_ref) || text(row.order_id) || "—"} · Dispute {text(row.dispute_id) || "—"}</p>
                              <p className="mt-2 text-xs text-slate-500">Source {text(row.source_bank_account_mapping_code) || "—"}{text(row.source_wallet_code) ? ` · wallet ${text(row.source_wallet_code)}` : ""}</p>
                              <p className="mt-2 text-xs text-slate-500">Created {text(row.created_at) || "—"}{text(row.confirmed_at) ? ` · confirmed ${text(row.confirmed_at)}` : ""}</p>
                              {text(row.notes) ? <p className="mt-3 break-words rounded-xl bg-slate-50 p-3 text-xs leading-5 text-slate-600">{text(row.notes)}</p> : null}
                              {rowStatus === "reversed" ? (
                                <div className="mt-3 rounded-xl border border-slate-200 bg-white p-3 text-xs text-slate-600">
                                  <p className="font-bold text-slate-800">Reversed {text(row.reversed_at) || "—"}</p>
                                  <p className="mt-1">Reason: {text(row.reversal_reason) || "—"}</p>
                                </div>
                              ) : null}
                            </div>

                            {reversible ? (
                              <form action={reverseTreasuryAllocationAction} className="rounded-2xl border border-rose-200 bg-rose-50 p-4">
                                <input type="hidden" name="allocation_id" value={text(row.id)} />
                                <input type="hidden" name="dva_statement_line_id" value={selectedLineId} />
                                <input type="hidden" name="current_status" value={status} />
                                <p className="text-xs font-bold uppercase tracking-wide text-rose-700">Controlled reversal</p>
                                <p className="mt-2 text-sm font-semibold text-rose-950">Reverse only this {gbp(row.allocated_gbp_amount)} row.</p>
                                <p className="mt-1 text-xs leading-5 text-rose-800">Sibling allocations remain active. Raw bank evidence and historical audit fields are not deleted.</p>
                                <textarea
                                  name="reversal_reason"
                                  rows={4}
                                  minLength={8}
                                  required
                                  placeholder="Explain why this exact economic-use row is incorrect."
                                  className="mt-3 w-full rounded-xl border border-rose-300 bg-white px-3 py-2 text-sm text-slate-900"
                                />
                                <button className="mt-3 w-full rounded-xl bg-rose-700 px-4 py-3 text-sm font-bold text-white hover:bg-rose-800">
                                  Reverse this row only
                                </button>
                              </form>
                            ) : (
                              <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">This row is historical and cannot be reversed again.</div>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </article>

                {activeRows.length === 0 ? (
                  <article className="rounded-3xl border border-emerald-200 bg-emerald-50 p-5 text-sm text-emerald-950 shadow-sm">
                    <p className="font-bold">No active allocation rows remain on this statement line.</p>
                    <p className="mt-1 text-xs leading-5">An audited interpretation correction can now proceed, subject to any other active reconciliation, loyalty, shipper-AP or cash-posting use checked by the database.</p>
                    <Link href={`/internal/dva-reconciliation/statement-interpretation?line_id=${encodeURIComponent(selectedLineId)}`} className="mt-3 inline-flex rounded-xl bg-emerald-900 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-800">
                      Open interpretation control →
                    </Link>
                  </article>
                ) : null}
              </>
            )}
          </div>
        </section>
      </div>
    </main>
  );
}
