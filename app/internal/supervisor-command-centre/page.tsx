import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type Tone = "complete" | "progress" | "action" | "blocked" | "review" | "muted";

type StatusRow = {
  order_id: string;
  order_ref: string | null;
  raw_order_status: string | null;
  lifecycle_status: string | null;
  order_type: string | null;
  importer_id: string | null;
  importer_name: string | null;
  retailer_id: string | null;
  retailer_name: string | null;
  created_at: string | null;
  accepted_estimate_gbp: number | string | null;
  amount_received_gbp: number | string | null;
  signed_final_sale_value_gbp: number | string | null;
  final_balance_due_gbp: number | string | null;
  potential_credit_pending_review_gbp: number | string | null;
  funding_state: string | null;
  supplier_state: string | null;
  reconciliation_state: string | null;
  exception_state: string | null;
  hold_state: string | null;
  tracking_state: string | null;
  shipment_state: string | null;
  export_evidence_state: string | null;
  pod_delivery_state: string | null;
  customer_sales_state: string | null;
  shipper_ap_state: string | null;
  current_stage: string | null;
  current_stage_label: string | null;
  next_owner: string | null;
  next_action: string | null;
  next_href: string | null;
  status_tone: string | null;
  status_priority: number | string | null;
};

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

function text(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  if (typeof value === "string") return value;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  if (typeof value === "boolean") return value ? "true" : "false";
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
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 72) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function ageLabel(value: unknown) {
  const createdAt = Date.parse(text(value));
  if (!Number.isFinite(createdAt)) return "—";
  const days = Math.max(0, Math.floor((Date.now() - createdAt) / 86_400_000));
  if (days === 0) return "today";
  if (days === 1) return "1d";
  return `${days}d`;
}

function normalTone(value: unknown): Tone {
  const raw = text(value) as Tone;
  if (["complete", "progress", "action", "blocked", "review", "muted"].includes(raw)) return raw;
  return "muted";
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "progress") return "border-sky-200 bg-sky-50 text-sky-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function chipClass(tone: Tone) {
  if (tone === "complete") return "bg-emerald-100 text-emerald-800 ring-emerald-200";
  if (tone === "progress") return "bg-sky-100 text-sky-800 ring-sky-200";
  if (tone === "action") return "bg-amber-100 text-amber-800 ring-amber-200";
  if (tone === "blocked") return "bg-rose-100 text-rose-800 ring-rose-200";
  if (tone === "review") return "bg-violet-100 text-violet-800 ring-violet-200";
  return "bg-slate-100 text-slate-700 ring-slate-200";
}

function stageSearchText(row: StatusRow) {
  return [
    row.order_ref,
    row.raw_order_status,
    row.lifecycle_status,
    row.importer_name,
    row.retailer_name,
    row.current_stage,
    row.current_stage_label,
    row.next_owner,
    row.next_action,
    row.funding_state,
    row.supplier_state,
    row.reconciliation_state,
    row.tracking_state,
    row.shipment_state,
    row.export_evidence_state,
    row.pod_delivery_state,
    row.customer_sales_state,
    row.shipper_ap_state,
  ].map(text).join(" ").toLowerCase();
}

function stateTone(value: unknown) {
  const state = text(value);
  if (["complete", "clean", "approved_current", "submitted", "allocated", "accepted_current", "posted", "apportionment_approved"].includes(state)) return "complete";
  if (["open", "rejected_resubmit_required", "receipt_issue", "allocation_incomplete"].includes(state)) return "blocked";
  if (["review_needed", "submitted_for_review", "apportionment_pending"].includes(state)) return "review";
  if (["missing", "incomplete", "not_posted", "not_ready"].includes(state)) return "action";
  if (["not_started"].includes(state)) return "muted";
  return "progress";
}

function SummaryCard({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: Tone }) {
  return (
    <div className={`rounded-2xl border p-3 shadow-sm ${toneClass(tone)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p>
      <p className="mt-1 text-2xl font-extrabold">{value}</p>
      <p className="mt-1 text-xs leading-4 opacity-90">{detail}</p>
    </div>
  );
}

function StatePill({ label, value }: { label: string; value: unknown }) {
  const tone = stateTone(value);
  return (
    <div className="rounded-xl border border-slate-200 bg-white px-2 py-1.5">
      <div className="flex items-center justify-between gap-2">
        <span className="truncate text-[10px] font-bold uppercase tracking-wide text-slate-500">{label}</span>
        <span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold ring-1 ${chipClass(tone)}`}>{pretty(value)}</span>
      </div>
    </div>
  );
}

function StateStack({ firstLabel, firstValue, secondLabel, secondValue }: { firstLabel: string; firstValue: unknown; secondLabel: string; secondValue: unknown }) {
  return (
    <div className="grid gap-1.5">
      <StatePill label={firstLabel} value={firstValue} />
      <StatePill label={secondLabel} value={secondValue} />
    </div>
  );
}

export default async function SupervisorCommandCentrePage({ searchParams }: { searchParams?: Promise<{ q?: string; only_action?: string }> }) {
  const qp = searchParams ? await searchParams : {};
  const search = (qp.q ?? "").trim().toLowerCase();
  const onlyAction = qp.only_action === "true";

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase.from("staff").select("id, full_name, role_type").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!staff) redirect("/auth/check");

  const { data, error } = await (supabase as any).rpc("internal_platform_order_status_v1");
  const allRows = ((data ?? []) as StatusRow[]).sort((a, b) => num(a.status_priority) - num(b.status_priority));
  const rows = allRows.filter((row) => {
    if (search && !stageSearchText(row).includes(search)) return false;
    if (!onlyAction) return true;
    return normalTone(row.status_tone) !== "complete";
  });

  const actionRows = rows.filter((row) => normalTone(row.status_tone) !== "complete");
  const blockedRows = rows.filter((row) => normalTone(row.status_tone) === "blocked");
  const reviewRows = rows.filter((row) => normalTone(row.status_tone) === "review");
  const logisticsRows = rows.filter((row) => ["tracking_missing", "shipment_batch_missing", "shipment_allocation_incomplete", "shipment_receipt_issue", "export_evidence_review_needed", "export_evidence_missing", "pod_delivery_review_needed", "awaiting_delivery_confirmation"].includes(text(row.current_stage)));
  const financeRows = rows.filter((row) => ["funding_incomplete", "customer_sale_not_posted", "final_balance_due"].includes(text(row.current_stage)));
  const supplierRows = rows.filter((row) => ["supplier_evidence_missing", "supplier_evidence_rejected", "supplier_evidence_review_needed", "supplier_reconciliation_incomplete"].includes(text(row.current_stage)));
  const completeRows = rows.filter((row) => normalTone(row.status_tone) === "complete");

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1600px] space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Operational cockpit</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Supervisor Command Centre</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">Canonical platform overview. One row = one order. Status, next owner and next action come from the shared operational status engine; lane cells remain read-only summary controls.</p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{text(staff.full_name)}</div><div>{text(staff.role_type)}</div></div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-sky-200 bg-sky-50 px-3 py-1 text-sky-900">Supervisor owns overview and routing</span>
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">Canonical status engine</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Read-only cockpit · no posting controls</span>
            <Link href="/internal/accounting-command-centre" className="rounded-full border border-violet-200 bg-white px-3 py-1 font-bold text-violet-900 underline">Open Accounting Command Centre</Link>
          </div>
          {error ? <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-900"><p className="font-bold">Canonical status source could not be read</p><p className="mt-1">{error.message}</p></div> : null}
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-8">
          <SummaryCard label="Visible rows" value={String(rows.length)} detail="Filtered order rows" tone={rows.length > 0 ? "review" : "muted"} />
          <SummaryCard label="Action rows" value={String(actionRows.length)} detail="Need owner/action" tone={actionRows.length > 0 ? "action" : "complete"} />
          <SummaryCard label="Blocked" value={String(blockedRows.length)} detail="Hard blockers" tone={blockedRows.length > 0 ? "blocked" : "complete"} />
          <SummaryCard label="Review" value={String(reviewRows.length)} detail="Supervisor review" tone={reviewRows.length > 0 ? "review" : "complete"} />
          <SummaryCard label="Supplier" value={String(supplierRows.length)} detail="Evidence/reconciliation" tone={supplierRows.length > 0 ? "action" : "complete"} />
          <SummaryCard label="Logistics" value={String(logisticsRows.length)} detail="Tracking/export/POD" tone={logisticsRows.length > 0 ? "action" : "complete"} />
          <SummaryCard label="Finance" value={String(financeRows.length)} detail="Funding/sale/balance" tone={financeRows.length > 0 ? "action" : "complete"} />
          <SummaryCard label="Complete" value={String(completeRows.length)} detail="No action required" tone="complete" />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5">
          <form action="/internal/supervisor-command-centre" className="grid gap-3 lg:grid-cols-[minmax(260px,1fr)_170px_120px_auto] lg:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Search orders, importers, retailers, stage or action
              <input name="q" defaultValue={qp.q ?? ""} placeholder="ORD, importer, retailer, export evidence, POD" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
            </label>
            <label className="flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold text-slate-700"><input type="checkbox" name="only_action" value="true" defaultChecked={onlyAction} />Action rows only</label>
            <button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply</button>
            <Link href="/internal/supervisor-command-centre" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-center text-sm font-semibold text-slate-800">Reset</Link>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="flex flex-col gap-2 border-b border-slate-100 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 className="text-xl font-semibold">Supervisor workbench grid</h2>
              <p className="mt-1 text-sm text-slate-500">Showing {rows.length} order row(s). The right-hand action is canonical; the middle lanes explain why.</p>
            </div>
            <p className="text-xs font-semibold text-slate-500">Read-only operational cockpit · links only · no posting controls</p>
          </div>

          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1480px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[210px]" />
                <col className="w-[210px]" />
                <col className="w-[180px]" />
                <col className="w-[235px]" />
                <col className="w-[235px]" />
                <col className="w-[235px]" />
                <col className="w-[235px]" />
                <col className="w-[220px]" />
              </colgroup>
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 text-left">Order ref</th>
                  <th className="px-3 py-2 text-left">Importer / retailer</th>
                  <th className="px-3 py-2 text-left">Current stage</th>
                  <th className="px-3 py-2 text-left">Funding / supplier</th>
                  <th className="px-3 py-2 text-left">Reconciliation / holds</th>
                  <th className="px-3 py-2 text-left">Tracking / shipment</th>
                  <th className="px-3 py-2 text-left">Export / sales / POD</th>
                  <th className="px-3 py-2 text-left">Next owner/action</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? (
                  <tr><td colSpan={8} className="px-3 py-8 text-center text-sm text-slate-500">No order rows match this filter.</td></tr>
                ) : rows.map((row) => {
                  const tone = normalTone(row.status_tone);
                  return (
                    <tr key={text(row.order_id)} className="align-top hover:bg-slate-50">
                      <td className="px-3 py-3">
                        <p className="truncate text-sm font-extrabold text-slate-950">{text(row.order_ref) || text(row.order_id)}</p>
                        <p className="mt-1 text-[11px] text-slate-500">Type {pretty(row.order_type)} · {ageLabel(row.created_at)}</p>
                        <p className="mt-1 line-clamp-2 text-[11px] leading-4 text-slate-500">Raw: {pretty(row.raw_order_status)} · Life: {pretty(row.lifecycle_status)}</p>
                      </td>
                      <td className="px-3 py-3">
                        <p className="truncate font-bold text-slate-900">{text(row.importer_name) || "No importer"}</p>
                        <p className="mt-1 truncate text-[11px] text-slate-500">{text(row.retailer_name) || "No retailer"}</p>
                      </td>
                      <td className="px-3 py-3">
                        <span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ring-1 ${chipClass(tone)}`}>{pretty(row.current_stage)}</span>
                        <p className="mt-2 line-clamp-3 font-bold leading-4 text-slate-950">{text(row.current_stage_label) || "—"}</p>
                        {num(row.final_balance_due_gbp) > 0.01 ? <p className="mt-1 text-[11px] font-bold text-amber-700">Balance due {gbp(row.final_balance_due_gbp)}</p> : null}
                        {num(row.potential_credit_pending_review_gbp) > 0.01 ? <p className="mt-1 text-[11px] font-bold text-amber-700">Potential credit {gbp(row.potential_credit_pending_review_gbp)}</p> : null}
                      </td>
                      <td className="px-3 py-3"><StateStack firstLabel="Funding" firstValue={row.funding_state} secondLabel="Supplier" secondValue={row.supplier_state} /></td>
                      <td className="px-3 py-3"><StateStack firstLabel="Reconciliation" firstValue={row.reconciliation_state} secondLabel="Exception / hold" secondValue={`${pretty(row.exception_state)} / ${pretty(row.hold_state)}`} /></td>
                      <td className="px-3 py-3"><StateStack firstLabel="Tracking" firstValue={row.tracking_state} secondLabel="Shipment" secondValue={row.shipment_state} /></td>
                      <td className="px-3 py-3"><div className="grid gap-1.5"><StatePill label="Export" value={row.export_evidence_state} /><StatePill label="Customer sales" value={row.customer_sales_state} /><StatePill label="POD" value={row.pod_delivery_state} /></div></td>
                      <td className="px-3 py-3">
                        <span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ring-1 ${chipClass(tone)}`}>{text(row.next_owner) || "None"}</span>
                        <p className="mt-2 line-clamp-2 font-bold leading-4 text-slate-950">{text(row.next_action) || "No action required"}</p>
                        <p className="mt-1 line-clamp-2 text-[11px] leading-4 text-slate-500">Stage: {short(row.current_stage_label, 56)}</p>
                        <Link href={text(row.next_href) || "/internal/supervisor-command-centre"} className="mt-2 inline-flex rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-[11px] font-bold leading-4 text-slate-800 hover:bg-slate-100">Open action</Link>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>

        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-bold">Control rule</h2><p className="mt-2">This page is the supervisor overview. It reads from the canonical platform operational status engine and routes work to existing child pages. It does not approve, upload, post, freeze, retry Sage, or override downstream locks.</p></section>
      </div>
    </main>
  );
}
