import { randomUUID } from "node:crypto";
import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import { confirmSettlementSurplusCreditAction, resolveOrderSettlementAction } from "../actions";

type Row = Record<string, string | number | boolean | null>;
type StaffRow = { role_type: string | null };
type SearchParams = { settlement_success?: string; settlement_error?: string };

function num(value: unknown) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function gbp(value: unknown) {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" }).format(num(value));
}

function label(value: unknown) {
  return String(value ?? "—").replaceAll("_", " ");
}

function statusPill(status: unknown) {
  const value = String(status ?? "");
  if (value === "fully_resolved") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (value === "over_resolved_review") return "bg-rose-100 text-rose-800 ring-rose-200";
  if (value === "partially_resolved") return "bg-amber-100 text-amber-900 ring-amber-200";
  return "bg-cyan-100 text-cyan-800 ring-cyan-200";
}

export default async function SurplusEvidencePage({ searchParams }: { searchParams?: Promise<SearchParams> }) {
  const params = searchParams ? await searchParams : {};
  const supabase = await createClient();

  const { data: authData } = await supabase.auth.getUser();
  const userId = authData.user?.id;
  if (!userId) redirect("/login");

  const { data: staffData, error: staffError } = await supabase
    .from("staff")
    .select("role_type")
    .eq("auth_user_id", userId)
    .eq("active", true)
    .maybeSingle();

  const staff = staffData as StaffRow | null;
  if (staffError || !staff || !["admin", "supervisor"].includes(String(staff.role_type))) redirect("/internal");

  const [settlementResult, pendingEvidenceResult] = await Promise.all([
    supabase.rpc("internal_order_settlement_resolution_v1", { p_order_id: null }),
    supabase
      .from("order_surplus_evidence_position_v3")
      .select("order_id,order_ref,payment_auth_id,effective_receipt_gbp,evidence_value_gbp,evidence_surplus_gbp,evidence_status,evidence_basis,pending_surplus_gbp,pending_position_count,pending_credit_confirmed_count,open_dispute_count,active_hold_count"),
  ]);

  const { data, error } = settlementResult;
  const allRows = (data ?? []) as Row[];
  const rows = allRows.filter((row) => num(row.final_sale_document_count) > 0 && (num(row.gross_positive_difference_gbp) > 0.01 || num(row.total_classified_gbp) > 0.01));

  const pendingEvidenceRows = pendingEvidenceResult.error ? [] : ((pendingEvidenceResult.data ?? []) as Row[]);
  const pendingEvidenceByOrder = new Map(pendingEvidenceRows.map((row) => [String(row.order_id), row]));
  const pendingResidualReady = rows.filter((row) => {
    if (num(row.pending_evidence_count) <= 0) return false;
    const evidence = pendingEvidenceByOrder.get(String(row.order_id));
    return Boolean(
      evidence &&
      num(evidence.pending_position_count) > 0 &&
      num(evidence.evidence_surplus_gbp) > 0.01 &&
      num(evidence.open_dispute_count) === 0 &&
      num(evidence.active_hold_count) === 0 &&
      ["ready_posted_invoice_surplus", "ready_draft_invoice_surplus", "ready_strong_in_out_surplus"].includes(String(evidence.evidence_status)),
    );
  });
  const pendingReadyIds = new Set(pendingResidualReady.map((row) => String(row.order_id)));

  const ready = rows.filter((row) =>
    num(row.pending_evidence_count) <= 0 &&
    ["ready_for_resolution", "partially_resolved"].includes(String(row.resolution_status)) &&
    num(row.remaining_unresolved_gbp) > 0.01 &&
    row.operational_blocked_yn !== true &&
    (row.credit_action_allowed_yn === true || row.fx_action_allowed_yn === true),
  );
  const blocked = rows.filter((row) =>
    num(row.remaining_unresolved_gbp) > 0.01 &&
    !pendingReadyIds.has(String(row.order_id)) &&
    !ready.some((readyRow) => readyRow.order_id === row.order_id) &&
    String(row.resolution_status) !== "over_resolved_review",
  );
  const overResolved = rows.filter((row) => String(row.resolution_status) === "over_resolved_review");
  const resolved = rows.filter((row) => ["fully_resolved", "no_positive_difference"].includes(String(row.resolution_status)));

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 sm:py-8">
      <div className="mx-auto max-w-6xl space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/funding" className="text-sm font-semibold text-sky-700">Back to funding</Link>
          <p className="mt-6 text-sm font-black uppercase tracking-[0.22em] text-cyan-700">Settlement resolution</p>
          <h1 className="mt-2 text-3xl font-black">Resolve customer settlement differences</h1>
          <p className="mt-2 max-w-4xl text-sm text-slate-600">Credit, FX/card difference and unresolved value always reconcile to the total receipt difference.</p>
        </section>

        {params.settlement_success ? <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-semibold text-emerald-900">{params.settlement_success}</div> : null}
        {params.settlement_error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm font-semibold text-red-900">{params.settlement_error}</div> : null}
        {error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-900">{error.message}</div> : null}
        {pendingEvidenceResult.error ? <div className="rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-900">Pending receipt evidence unavailable: {pendingEvidenceResult.error.message}</div> : null}

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div className="rounded-2xl border border-cyan-200 bg-cyan-50 p-4"><p className="text-xs font-black uppercase text-cyan-700">Ready / partial</p><p className="mt-1 text-3xl font-black">{ready.length}</p></div>
          <div className="rounded-2xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-xs font-black uppercase text-emerald-700">Remaining value</p><p className="mt-1 text-3xl font-black">{gbp(ready.reduce((sum, row) => sum + num(row.remaining_unresolved_gbp), 0))}</p></div>
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4"><p className="text-xs font-black uppercase text-amber-700">Blocked</p><p className="mt-1 text-3xl font-black">{blocked.length}</p></div>
          <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-black uppercase text-slate-500">Resolved</p><p className="mt-1 text-3xl font-black">{resolved.length}</p></div>
        </section>

        {pendingResidualReady.length > 0 ? (
          <section className="space-y-3 rounded-3xl border border-cyan-200 bg-white p-5 shadow-sm">
            <div><h2 className="text-xl font-black">Original receipt residual ready to confirm</h2><p className="mt-1 text-sm text-slate-600">Confirm the existing pending receipt residual only after the established evidence model proves the customer credit amount.</p></div>
            {pendingResidualReady.map((row) => {
              const evidence = pendingEvidenceByOrder.get(String(row.order_id));
              if (!evidence) return null;
              const credit = num(evidence.evidence_surplus_gbp);
              return (
                <details key={String(row.order_id)} className="rounded-2xl border border-cyan-200 bg-cyan-50 shadow-sm" open>
                  <summary className="cursor-pointer list-none p-4">
                    <div className="grid gap-3 md:grid-cols-[1.25fr_0.75fr_0.75fr_0.75fr_auto] md:items-center">
                      <div><h3 className="text-lg font-black">{row.order_ref ?? row.order_id}</h3><p className="text-xs text-slate-600">Auth: {row.payment_auth_id ?? "—"}</p></div>
                      <div><p className="text-xs font-black uppercase text-slate-500">Receipt</p><p className="font-black">{gbp(evidence.effective_receipt_gbp)}</p></div>
                      <div><p className="text-xs font-black uppercase text-slate-500">Final value</p><p className="font-black">{gbp(evidence.evidence_value_gbp)}</p></div>
                      <div><p className="text-xs font-black uppercase text-slate-500">Credit</p><p className="font-black text-cyan-800">{gbp(credit)}</p></div>
                      <span className="rounded-full bg-cyan-100 px-3 py-1 text-xs font-black text-cyan-800 ring-1 ring-cyan-200">receipt residual</span>
                    </div>
                  </summary>
                  <div className="border-t border-cyan-100 p-4">
                    <div className="grid gap-2 sm:grid-cols-3">
                      <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Pending receipt residual</p><p className="font-black">{gbp(evidence.pending_surplus_gbp)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Evidence basis</p><p className="font-black">{label(evidence.evidence_basis)}</p></div>
                      <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Customer credit proven</p><p className="font-black text-cyan-800">{gbp(credit)}</p></div>
                    </div>
                    <form action={confirmSettlementSurplusCreditAction} className="mt-4 flex flex-wrap items-center justify-between gap-3">
                      <input type="hidden" name="order_id" value={String(row.order_id)} />
                      <input type="hidden" name="reason" value="supervisor_confirmed_credit" />
                      <input type="hidden" name="notes" value={`Pending receipt residual confirmed from ${label(evidence.evidence_basis)} evidence. Effective receipt ${gbp(evidence.effective_receipt_gbp)} less final evidence value ${gbp(evidence.evidence_value_gbp)} leaves ${gbp(credit)} customer credit.`} />
                      <p className="text-xs font-semibold text-slate-600">The existing evidence RPC will create the proven {gbp(credit)} credit and close the pending receipt classification.</p>
                      <button className="rounded-xl bg-cyan-700 px-4 py-2 text-sm font-black text-white">Confirm customer credit</button>
                    </form>
                  </div>
                </details>
              );
            })}
          </section>
        ) : null}

        <section className="space-y-3 rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div><h2 className="text-xl font-black">Ready to resolve</h2><p className="mt-1 text-sm text-slate-600">Enter credit, FX/card difference, or a split. The total cannot exceed the remaining amount.</p></div>
            <Link href="/internal/funding" className="rounded-xl border border-slate-200 px-3 py-2 text-sm font-bold text-slate-700">Funding overview</Link>
          </div>

          {ready.length === 0 ? <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">No settlement rows are ready.</div> : null}

          {ready.map((row) => {
            const remaining = num(row.remaining_unresolved_gbp);
            const confirmedFx = num(row.inbound_fx_receipt_residual_gbp) + num(row.settlement_fx_card_difference_gbp);
            return (
              <details key={String(row.order_id)} className="rounded-2xl border border-cyan-200 bg-cyan-50 shadow-sm">
                <summary className="cursor-pointer list-none p-4">
                  <div className="grid gap-3 md:grid-cols-[1.25fr_0.75fr_0.75fr_0.75fr_auto] md:items-center">
                    <div><h3 className="text-lg font-black">{row.order_ref ?? row.order_id}</h3><p className="text-xs text-slate-600">Auth: {row.payment_auth_id ?? "—"}</p></div>
                    <div><p className="text-xs font-black uppercase text-slate-500">Difference</p><p className="font-black">{gbp(row.gross_positive_difference_gbp)}</p></div>
                    <div><p className="text-xs font-black uppercase text-slate-500">Credit</p><p className="font-black">{gbp(row.confirmed_customer_credit_gbp)}</p></div>
                    <div><p className="text-xs font-black uppercase text-slate-500">Remaining</p><p className="font-black text-cyan-800">{gbp(remaining)}</p></div>
                    <span className={`rounded-full px-3 py-1 text-xs font-black ring-1 ${statusPill(row.resolution_status)}`}>{label(row.resolution_status)}</span>
                  </div>
                </summary>
                <div className="border-t border-cyan-100 p-4">
                  <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-6">
                    <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Receipt</p><p className="font-black">{gbp(row.order_attributed_receipt_gbp)}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Final value</p><p className="font-black">{gbp(row.final_order_value_gbp)}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Difference</p><p className="font-black">{gbp(row.gross_positive_difference_gbp)}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Credit confirmed</p><p className="font-black">{gbp(row.confirmed_customer_credit_gbp)}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">FX confirmed</p><p className="font-black">{gbp(confirmedFx)}</p></div>
                    <div className="rounded-xl bg-white p-3"><p className="text-xs font-black uppercase text-slate-500">Unresolved</p><p className="font-black text-cyan-800">{gbp(remaining)}</p></div>
                  </div>
                  <form action={resolveOrderSettlementAction} className="mt-4 grid gap-3 lg:grid-cols-2">
                    <input type="hidden" name="order_id" value={String(row.order_id)} />
                    <input type="hidden" name="action_key" value={randomUUID()} />
                    <label className="text-sm font-bold text-slate-700">Customer credit
                      <input name="customer_credit_gbp" type="number" min="0" max={remaining.toFixed(2)} step="0.01" defaultValue={remaining.toFixed(2)} className="mt-1 w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" />
                    </label>
                    <label className="text-sm font-bold text-slate-700">FX/card difference
                      <input name="fx_card_difference_gbp" type="number" min="0" max={remaining.toFixed(2)} step="0.01" defaultValue="0.00" className="mt-1 w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" />
                    </label>
                    <label className="text-sm font-bold text-slate-700">Reason
                      <select name="reason" defaultValue="supervisor_confirmed_settlement" className="mt-1 w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm">
                        <option value="supervisor_confirmed_settlement">Supervisor confirmed settlement</option>
                        <option value="discount_or_promo">Discount / promotion</option>
                        <option value="item_removed_before_charge">Item removed before charge</option>
                        <option value="customer_hold_excluded">Customer hold excluded</option>
                        <option value="customer_fx_card_difference">Customer FX / card difference</option>
                      </select>
                    </label>
                    <label className="text-sm font-bold text-slate-700">Notes
                      <input name="notes" className="mt-1 w-full rounded-xl border border-cyan-200 bg-white px-3 py-2 text-sm" defaultValue={`Receipt ${gbp(row.order_attributed_receipt_gbp)} less final order value ${gbp(row.final_order_value_gbp)}; ${gbp(remaining)} remains.`} />
                    </label>
                    <div className="lg:col-span-2 flex flex-wrap items-center justify-between gap-3">
                      <p className="text-xs font-semibold text-slate-600">Credit + FX must be no more than {gbp(remaining)}.</p>
                      <button className="rounded-xl bg-cyan-700 px-4 py-2 text-sm font-black text-white">Confirm resolution</button>
                    </div>
                  </form>
                </div>
              </details>
            );
          })}
        </section>

        <details className="rounded-3xl border border-amber-200 bg-white p-5 shadow-sm" open={blocked.length > 0}>
          <summary className="cursor-pointer text-xl font-black">Operationally blocked · {blocked.length}</summary>
          <div className="mt-4 grid gap-2">
            {blocked.map((row) => (
              <div key={String(row.order_id)} className="grid gap-2 rounded-xl bg-amber-50 p-3 text-sm md:grid-cols-[1fr_auto_auto]">
                <span className="font-bold">{row.order_ref ?? row.order_id}</span>
                <span>{label(row.operational_blocker ?? row.credit_action_blocker ?? row.fx_action_blocker)}</span>
                <span>{gbp(row.remaining_unresolved_gbp)}</span>
              </div>
            ))}
            {blocked.length === 0 ? <p className="text-sm text-slate-600">No blocked settlement rows.</p> : null}
          </div>
        </details>

        <details className="rounded-3xl border border-emerald-200 bg-white p-5 shadow-sm">
          <summary className="cursor-pointer text-xl font-black">Fully resolved · {resolved.length}</summary>
          <div className="mt-4 grid gap-2">
            {resolved.slice(0, 60).map((row) => (
              <div key={String(row.order_id)} className="grid gap-2 rounded-xl bg-emerald-50 p-3 text-sm md:grid-cols-[1fr_auto_auto_auto]">
                <span className="font-bold">{row.order_ref ?? row.order_id}</span>
                <span>Credit {gbp(row.confirmed_customer_credit_gbp)}</span>
                <span>FX {gbp(num(row.inbound_fx_receipt_residual_gbp) + num(row.settlement_fx_card_difference_gbp))}</span>
                <span>Remaining {gbp(row.remaining_unresolved_gbp)}</span>
              </div>
            ))}
          </div>
        </details>

        {overResolved.length > 0 ? (
          <details className="rounded-3xl border border-rose-200 bg-white p-5 shadow-sm" open>
            <summary className="cursor-pointer text-xl font-black text-rose-900">Over-resolved review · {overResolved.length}</summary>
            <div className="mt-4 grid gap-2">
              {overResolved.map((row) => <div key={String(row.order_id)} className="grid gap-2 rounded-xl bg-rose-50 p-3 text-sm md:grid-cols-[1fr_auto]"><span className="font-bold">{row.order_ref ?? row.order_id}</span><span>Excess classification {gbp(row.over_resolved_gbp)}</span></div>)}
            </div>
          </details>
        ) : null}
      </div>
    </main>
  );
}
