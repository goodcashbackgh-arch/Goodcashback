import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Tone = "complete" | "progress" | "action" | "blocked" | "review" | "muted";
type Lane = { label: string; detail: string; tone: Tone; href: string };
type StatusRow = Record<string, unknown>;
type ProgressRow = Record<string, unknown>;

const gbpFormatter = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP", minimumFractionDigits: 2 });

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
  return ["complete", "progress", "action", "blocked", "review", "muted"].includes(raw) ? raw : "muted";
}

function lane(label: string, detail: string, tone: Tone, href: string): Lane {
  return { label, detail, tone, href };
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

function statusWord(state: Lane) {
  if (state.tone === "complete") return state.label.toLowerCase().includes("handoff") || state.label.toLowerCase().includes("ready") ? "ready for accounting" : "clean";
  if (state.tone === "blocked") return "blocked";
  if (state.tone === "muted") return "not reached";
  if (state.detail.toLowerCase().includes("wait")) return "waiting external";
  if (state.tone === "progress" || state.tone === "action" || state.tone === "review") return "in progress";
  return "not applicable";
}

function stateTone(value: unknown): Tone {
  const state = text(value);
  if (["complete", "clean", "approved_current", "submitted", "allocated", "accepted_current", "posted", "apportionment_approved"].includes(state)) return "complete";
  if (["open", "blocked", "rejected_resubmit_required", "receipt_issue", "allocation_incomplete"].includes(state)) return "blocked";
  if (["attention", "review_needed", "submitted_for_review", "apportionment_pending"].includes(state)) return "review";
  if (["missing", "incomplete", "not_posted", "not_ready"].includes(state)) return "action";
  if (["not_started", "not_reached"].includes(state)) return "muted";
  return "progress";
}

function stateLabel(value: unknown) {
  const state = text(value);
  if (state === "approved_current") return "Approved current";
  if (state === "accepted_current") return "Accepted current";
  if (state === "not_posted") return "Not posted";
  if (state === "not_ready") return "Not ready";
  if (state === "submitted_for_review") return "Submitted for review";
  if (state === "review_needed") return "Review needed";
  if (state === "allocation_incomplete") return "Allocation incomplete";
  if (state === "apportionment_pending") return "Apportionment pending";
  if (state === "apportionment_approved") return "Apportionment approved";
  if (state === "not_reached") return "Not reached";
  return pretty(state);
}

function laneFromState(title: string, value: unknown, href: string, detail?: string): Lane {
  const tone = stateTone(value);
  return lane(stateLabel(value), detail || `${title} ${pretty(value)}`, tone, href);
}

function fundingLane(row: StatusRow) {
  if (text(row.funding_state) === "complete") return lane("Complete", `Funded ${gbp(row.amount_received_gbp)} / accepted estimate ${gbp(row.accepted_estimate_gbp)}`, "complete", "/internal/funding");
  return lane("Incomplete", `Accepted estimate ${gbp(row.accepted_estimate_gbp)} · received ${gbp(row.amount_received_gbp)}`, "action", "/internal/funding");
}

function supplierLane(row: StatusRow) {
  return laneFromState("Supplier invoice", row.supplier_state, "/internal/invoice-review");
}

function exceptionCategories(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.map((item) => pretty(item)).filter((item) => item && item !== "—");
}

function exceptionLane(row: StatusRow, progress?: ProgressRow) {
  const summary = text(progress?.exception_summary_state);
  const categories = exceptionCategories(progress?.exception_categories_json);
  if (summary === "open") return lane("Open", categories.slice(0, 2).join(", ") || "Open exception/hold", "blocked", "/internal/exceptions");
  if (summary === "attention") return lane("Attention", categories.slice(0, 2).join(", ") || "Cross-lane attention", "review", "/internal/exceptions");
  const exceptionState = text(row.exception_state);
  const holdState = text(row.hold_state);
  if (exceptionState === "open" || holdState === "open") return lane("Action needed", `Exception ${pretty(exceptionState)} · hold ${pretty(holdState)}`, "blocked", "/internal/exceptions");
  return lane("None", "No recorded order exceptions/holds", "complete", "/internal/exceptions");
}

function dvaLane(row: StatusRow, progress?: ProgressRow) {
  if (progress && text(progress.dva_state)) return laneFromState("DVA/card", progress.dva_state, "/internal/dva-reconciliation/workspace");
  if (text(row.funding_state) === "complete" && ["approved_current", "complete"].includes(text(row.supplier_state))) return lane("Canonical check", "DVA/card is covered by the order status engine", "complete", "/internal/dva-reconciliation/workspace");
  return lane("Not reached", "Waits on funding/invoice facts", "muted", "/internal/dva-reconciliation/workspace");
}

function shippingLane(row: StatusRow) {
  const tracking = text(row.tracking_state);
  const shipment = text(row.shipment_state);
  if (tracking === "submitted" && shipment === "allocated") return lane("Clean / allocated", "Tracking submitted and shipment allocated", "complete", "/internal/shipping-control");
  if (shipment === "receipt_issue") return lane("Receipt issue", "Shipment receipt issue", "blocked", "/internal/shipping-control");
  if (shipment === "allocation_incomplete") return lane("Allocation missing", "Shipment allocation incomplete", "action", "/internal/shipping-control");
  if (tracking === "missing") return lane("Not reached", "No tracking submitted", "muted", "/internal/shipping-control");
  return lane("In progress", `Tracking ${pretty(tracking)} · shipment ${pretty(shipment)}`, "progress", "/internal/shipping-control");
}

function exportLane(row: StatusRow) {
  const exportState = text(row.export_evidence_state);
  const podState = text(row.pod_delivery_state);
  if (exportState === "accepted_current" && podState === "accepted_current") return lane("Complete", "Export evidence and POD accepted", "complete", "/internal/shipping-control");
  if (exportState === "accepted_current") return lane("Awaiting POD", `POD ${pretty(podState)}`, stateTone(podState), "/internal/shipping-control");
  if (exportState === "submitted_for_review") return lane("Review needed", "Export evidence submitted for review", "review", "/internal/shipping-control");
  if (exportState === "missing") return lane("Missing", "Final export evidence missing", "action", "/internal/shipping-control");
  return lane("In progress", `Export ${pretty(exportState)} · POD ${pretty(podState)}`, "progress", "/internal/shipping-control");
}

function customerSalesLane(row: StatusRow, progress?: ProgressRow) {
  const finalSettlement = text(progress?.final_settlement_state);
  const state = text(row.customer_sales_state);
  if (state === "posted") {
    const parts = [`Final sale ${gbp(row.signed_final_sale_value_gbp)}`];
    if (num(row.final_balance_due_gbp) > 0.01) parts.push(`balance due ${gbp(row.final_balance_due_gbp)}`);
    if (num(row.potential_credit_pending_review_gbp) > 0.01) parts.push(`potential credit ${gbp(row.potential_credit_pending_review_gbp)}`);
    return lane(finalSettlement === "blocked" ? "Balance due" : "Posted / marked", parts.join(" · "), finalSettlement === "blocked" ? "blocked" : "complete", "/internal/accounting-command-centre");
  }
  return laneFromState("Customer sales", row.customer_sales_state, "/internal/shipping-control/customer-invoice-release");
}

function shipperApLane(row: StatusRow) {
  return laneFromState("Shipper AP", row.shipper_ap_state, "/internal/shipping-control/shipper-documents");
}

function currentAction(row: StatusRow) {
  const tone = normalTone(row.status_tone);
  return { owner: text(row.next_owner) || "None", label: text(row.next_action) || "No action required", reason: text(row.current_stage_label) || pretty(row.current_stage), href: text(row.next_href) || "/internal/supervisor-command-centre", tone };
}

function fallbackProgress(states: Record<string, Lane>) {
  const applicable = [states.funding, states.supplier, states.dva, states.exceptions, states.shipping, states.customerSales, states.shipperAp, states.exportDelivery].filter((state) => state.tone !== "muted");
  const complete = applicable.filter((state) => state.tone === "complete").length;
  return { complete, total: applicable.length || 1, pct: Math.round((complete / (applicable.length || 1)) * 100) };
}

function progressFromCanonical(progress: ProgressRow | undefined, states: Record<string, Lane>) {
  const complete = num(progress?.gate_complete_count);
  const total = num(progress?.gate_total) || 12;
  if (progress && total > 0) return { complete, total, pct: Math.round((complete / total) * 100) };
  return fallbackProgress(states);
}

function SummaryCard({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: Tone }) {
  return <div className={`rounded-2xl border p-3 shadow-sm ${toneClass(tone)}`}><p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{label}</p><p className="mt-1 text-2xl font-extrabold">{value}</p><p className="mt-1 text-xs leading-4 opacity-90">{detail}</p></div>;
}

function LanePill({ title, state }: { title: string; state: Lane }) {
  return (
    <Link href={state.href} title={`${title}: ${state.label} — ${state.detail}`} className="group block rounded-xl border border-slate-200 bg-white px-2 py-1.5 hover:bg-slate-50">
      <div className="flex items-center justify-between gap-2"><span className="truncate text-[10px] font-bold uppercase tracking-wide text-slate-500">{title}</span><span className={`shrink-0 rounded-full px-2 py-0.5 text-[10px] font-bold ring-1 ${chipClass(state.tone)}`}>{statusWord(state)}</span></div>
      <p className="mt-1 truncate text-[11px] font-bold text-slate-950 group-hover:underline">{state.label}</p>
      <p className="mt-0.5 truncate text-[11px] text-slate-500">{state.detail}</p>
    </Link>
  );
}

function LaneStack({ firstTitle, first, secondTitle, second }: { firstTitle: string; first: Lane; secondTitle: string; second: Lane }) {
  return <div className="grid gap-1.5"><LanePill title={firstTitle} state={first} /><LanePill title={secondTitle} state={second} /></div>;
}

function rowSearchText(card: { row: StatusRow }) {
  return [card.row.order_ref, card.row.importer_name, card.row.retailer_name, card.row.raw_order_status, card.row.lifecycle_status, card.row.current_stage, card.row.current_stage_label, card.row.next_owner, card.row.next_action].map(text).join(" ").toLowerCase();
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

  const [statusResult, progressResult] = await Promise.all([
    (supabase as any).rpc("internal_platform_order_status_v1"),
    (supabase as any).rpc("internal_platform_order_progress_v1"),
  ]);
  const sourceRows = ((statusResult.data ?? []) as StatusRow[]).sort((a, b) => num(a.status_priority) - num(b.status_priority));
  const progressByOrderId = new Map<string, ProgressRow>();
  for (const row of (progressResult.data ?? []) as ProgressRow[]) {
    const orderId = text(row.order_id);
    if (orderId) progressByOrderId.set(orderId, row);
  }

  const cards = sourceRows.map((row) => {
    const progressRow = progressByOrderId.get(text(row.order_id));
    const states = {
      funding: fundingLane(row),
      supplier: supplierLane(row),
      exceptions: exceptionLane(row, progressRow),
      shipping: shippingLane(row),
      customerSales: customerSalesLane(row, progressRow),
      shipperAp: shipperApLane(row),
      exportDelivery: exportLane(row),
      dva: dvaLane(row, progressRow),
    };
    return { row, progressRow, states, actions: [currentAction(row)], progress: progressFromCanonical(progressRow, states) };
  }).filter((card) => {
    if (search && !rowSearchText(card).includes(search)) return false;
    if (!onlyAction) return true;
    return card.actions.some((action) => ["blocked", "action", "review"].includes(action.tone));
  });

  const actionRowCount = cards.filter((card) => card.actions.some((action) => ["blocked", "action", "review"].includes(action.tone))).length;
  const fundingActionCount = cards.filter((card) => ["blocked", "action", "review"].includes(card.states.funding.tone)).length;
  const supplierActionCount = cards.filter((card) => ["blocked", "action", "review"].includes(card.states.supplier.tone)).length;
  const dvaActionCount = cards.filter((card) => ["blocked", "action", "review"].includes(card.states.dva.tone)).length;
  const logisticsActionCount = cards.filter((card) => ["blocked", "action", "review"].includes(card.states.shipping.tone) || ["blocked", "action", "review"].includes(card.states.shipperAp.tone) || ["blocked", "action", "review"].includes(card.states.exportDelivery.tone)).length;
  const customerSalesActionCount = cards.filter((card) => ["blocked", "action", "review"].includes(card.states.customerSales.tone)).length;
  const blockedRows = cards.filter((card) => normalTone(card.row.status_tone) === "blocked").length;
  const progressError = progressResult.error ? `Progress: ${progressResult.error.message}` : "";
  const statusError = statusResult.error ? `Canonical status source: ${statusResult.error.message}` : "";
  const errorMessages = [statusError, progressError].filter(Boolean);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1600px] space-y-5">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
          <p className="mt-6 text-sm font-medium uppercase tracking-[0.2em] text-sky-500">Operational cockpit</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between"><div><h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Supervisor Command Centre</h1><p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">Compact v4 workbench for order-to-clean-delivery control. One row = one order or order-shipment grouping. The grid routes blockers to existing child task pages; it does not approve, post, freeze, batch or retry Sage.</p></div><div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700"><div className="font-medium text-slate-950">{text(staff.full_name)}</div><div>{text(staff.role_type)}</div></div></div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold"><span className="rounded-full border border-sky-200 bg-sky-50 px-3 py-1 text-sky-900">Supervisor owns operational readiness</span><span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">No Sage posting happens here</span><span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">12 fixed gates + exception overlay</span><Link href="/internal/accounting-command-centre" className="rounded-full border border-violet-200 bg-white px-3 py-1 font-bold text-violet-900 underline">Open Accounting Command Centre — read-only handoff</Link></div>
          {errorMessages.length > 0 ? <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900"><p className="font-bold">Some lanes could not be read</p>{errorMessages.map((message) => <p key={message} className="mt-1">{message}</p>)}</div> : null}
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-8"><SummaryCard label="Visible rows" value={String(cards.length)} detail="Filtered order rows" tone={cards.length > 0 ? "review" : "muted"} /><SummaryCard label="Action rows" value={String(actionRowCount)} detail="Need owner/action" tone={actionRowCount > 0 ? "action" : "complete"} /><SummaryCard label="Funding" value={String(fundingActionCount)} detail="Gaps/review rows" tone={fundingActionCount > 0 ? "blocked" : "complete"} /><SummaryCard label="Supplier invoice" value={String(supplierActionCount)} detail="Missing/review rows" tone={supplierActionCount > 0 ? "review" : "complete"} /><SummaryCard label="DVA/card" value={String(dvaActionCount)} detail="Allocation review" tone={dvaActionCount > 0 ? "action" : "complete"} /><SummaryCard label="Logistics/AP" value={String(logisticsActionCount)} detail="Shipper/export/AP rows" tone={logisticsActionCount > 0 ? "review" : "complete"} /><SummaryCard label="Customer sales" value={String(customerSalesActionCount)} detail="Draft/handoff rows" tone={customerSalesActionCount > 0 ? "action" : "complete"} /><SummaryCard label="Accounting handoff" value={`${cards.length - actionRowCount} clear`} detail={`${blockedRows} blocked; read-only here`} tone={blockedRows > 0 ? "action" : "complete"} /></section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-5"><form action="/internal/supervisor-command-centre" className="grid gap-3 lg:grid-cols-[minmax(260px,1fr)_170px_120px_auto] lg:items-end"><label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">Search orders, importers, retailers, bookings<input name="q" defaultValue={qp.q ?? ""} placeholder="ORD, importer, retailer, booking" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" /></label><label className="flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-sm font-semibold text-slate-700"><input type="checkbox" name="only_action" value="true" defaultChecked={onlyAction} />Action rows only</label><button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply</button><Link href="/internal/supervisor-command-centre" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-center text-sm font-semibold text-slate-800">Reset</Link></form></section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm"><div className="flex flex-col gap-2 border-b border-slate-100 px-4 py-3 lg:flex-row lg:items-center lg:justify-between"><div><h2 className="text-xl font-semibold">Supervisor workbench grid</h2><p className="mt-1 text-sm text-slate-500">Showing {cards.length} order row(s). Use the right-hand next action to move directly to the correct child task page.</p></div><p className="text-xs font-semibold text-slate-500">Read-only operational cockpit · links only · no posting controls</p></div>
          <div className="overflow-x-auto rounded-b-3xl"><table className="min-w-[1480px] table-fixed divide-y divide-slate-200 text-xs"><colgroup><col className="w-[210px]" /><col className="w-[210px]" /><col className="w-[120px]" /><col className="w-[235px]" /><col className="w-[235px]" /><col className="w-[235px]" /><col className="w-[235px]" /><col className="w-[200px]" /></colgroup><thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500"><tr><th className="px-3 py-2 text-left">Order ref</th><th className="px-3 py-2 text-left">Importer / retailer</th><th className="px-3 py-2 text-left">Age / status</th><th className="px-3 py-2 text-left">Funding / DVA</th><th className="px-3 py-2 text-left">Supplier / exceptions</th><th className="px-3 py-2 text-left">Shipper / export</th><th className="px-3 py-2 text-left">Customer sales / Shipper AP</th><th className="px-3 py-2 text-left">Next owner/action</th></tr></thead><tbody className="divide-y divide-slate-100 bg-white">{cards.length === 0 ? <tr><td colSpan={8} className="px-3 py-8 text-center text-sm text-slate-500">No order rows match this filter.</td></tr> : cards.map((card) => { const primary = card.actions[0]; const booking = "—"; const exceptionState = text(card.progressRow?.exception_summary_state) || "clean"; return <tr key={text(card.row.order_id)} className="align-top hover:bg-slate-50"><td className="px-3 py-3"><p className="truncate text-sm font-extrabold text-slate-950">{text(card.row.order_ref) || text(card.row.order_id)}</p><p className="mt-1 truncate text-[11px] text-slate-500">Type {pretty(card.row.order_type)} · Batch {booking}</p><div className="mt-2 h-2 overflow-hidden rounded-full bg-slate-200"><div className="h-full rounded-full bg-slate-950" style={{ width: `${card.progress.pct}%` }} /></div><p className="mt-1 text-[11px] text-slate-500">{card.progress.complete}/{card.progress.total} gates · {card.progress.pct}%</p><p className="mt-1 text-[11px] font-semibold text-slate-500">Exceptions: {pretty(exceptionState)}</p></td><td className="px-3 py-3"><p className="truncate font-bold text-slate-900">{text(card.row.importer_name) || "No importer"}</p><p className="mt-1 truncate text-[11px] text-slate-500">{text(card.row.retailer_name) || "No retailer"}</p></td><td className="px-3 py-3"><p className="font-bold text-slate-900">{ageLabel(card.row.created_at)}</p><p className="mt-1 line-clamp-3 text-[11px] leading-4 text-slate-500">{pretty(card.row.raw_order_status)}</p></td><td className="px-3 py-3"><LaneStack firstTitle="Funding" first={card.states.funding} secondTitle="DVA/card" second={card.states.dva} /></td><td className="px-3 py-3"><LaneStack firstTitle="Supplier invoice" first={card.states.supplier} secondTitle="Exceptions" second={card.states.exceptions} /></td><td className="px-3 py-3"><LaneStack firstTitle="Shipper/logistics" first={card.states.shipping} secondTitle="Export/delivery" second={card.states.exportDelivery} /></td><td className="px-3 py-3"><LaneStack firstTitle="Customer sales" first={card.states.customerSales} secondTitle="Shipper AP" second={card.states.shipperAp} /></td><td className="px-3 py-3"><span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ring-1 ${chipClass(primary.tone)}`}>{primary.owner}</span><p className="mt-2 line-clamp-2 font-bold leading-4 text-slate-950">{primary.label}</p><p className="mt-1 line-clamp-2 text-[11px] leading-4 text-slate-500">{primary.reason}</p><Link href={primary.href} className="mt-2 inline-flex rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-[11px] font-bold leading-4 text-slate-800 hover:bg-slate-100">Open action</Link></td></tr>; })}</tbody></table></div></section>
        <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900"><h2 className="font-bold">v4 control rule</h2><p className="mt-2">This page is the operational workbench, not the accounting workroom. Existing child task pages remain the controlled places to upload, review, reconcile and approve. No Sage posting happens here. Accounting status is read-only only. Accounting Command Centre is the only place for freeze, revalidation, posting batches, Sage Cloud Accounting API posting and Sage retries.</p></section>
      </div>
    </main>
  );
}
