import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";
import SageConnectionPanel from "./SageConnectionPanel";
import PostingBatchHistoryPanel from "./PostingBatchHistoryPanel";
import {
  createPostingBatchFromMatchingRowsAction,
  freezeMatchingCustomerSalesRowsAction,
  freezeMatchingShipperApRowsAction,
  freezeMatchingSupplierGoodsApRowsAction,
  freezeSelectedCustomerSalesRowsAction,
  freezeSelectedShipperApRowsAction,
  freezeSelectedSupplierGoodsApRowsAction,
  revalidateMatchingFrozenRowsAction,
} from "./actions";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;
type Tone = "complete" | "action" | "blocked" | "review" | "muted";

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

function firstParam(value: unknown) {
  if (Array.isArray(value)) return text(value[0]);
  return text(value);
}

function num(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function bool(value: unknown) {
  return value === true || text(value).toLowerCase() === "true";
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 38) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function bookingText(value: unknown) {
  const raw = text(value).trim();
  if (!raw) return "—";
  return raw.toLowerCase().startsWith("booking ") ? raw : `Booking ${raw}`;
}

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function statusTone(status: unknown): Tone {
  const raw = text(status);
  if (["ready_to_post", "ok_to_post", "posted", "mapping_frozen_ok", "payload_frozen_ok", "mapping_resolved_or_not_required"].includes(raw)) return "complete";
  if (["ready_to_freeze", "requires_revalidation", "not_revalidated", "not_posted", "not_frozen"].includes(raw)) return "action";
  if (["blocked_before_posting", "stale_reapproval_required", "blocked_source_not_ready", "posting_failed", "payload_not_ready", "mapping_changed_since_approval", "payload_changed_since_approval"].includes(raw)) return "blocked";
  if (["approved_frozen", "review", "warning_only"].includes(raw)) return "review";
  return "muted";
}

function actionLabel(row: Row) {
  const raw = text(row.next_action) || "Open";
  if (/post\s+to\s+sage/i.test(raw)) return "Review ready row";
  return raw;
}

function actionTitle(row: Row) {
  const raw = text(row.next_action) || "Open";
  if (/post\s+to\s+sage/i.test(raw)) return "Ready for future Sage posting. Live Sage posting is not built yet.";
  return raw;
}

function Pill({ value }: { value: unknown }) {
  return <span className={`inline-flex max-w-[130px] truncate rounded-full border px-2 py-0.5 text-[10px] font-bold leading-4 ${toneClass(statusTone(value))}`}>{pretty(value)}</span>;
}

function CompactState({ label, value }: { label: string; value: unknown }) {
  return (
    <span className={`inline-flex min-w-0 items-center gap-1 rounded-md border px-1.5 py-0.5 text-[10px] leading-4 ${toneClass(statusTone(value))}`} title={`${label}: ${pretty(value)}`}>
      <span className="shrink-0 font-bold opacity-70">{label}</span>
      <span className="truncate font-extrabold">{pretty(value)}</span>
    </span>
  );
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

function SectionLink({ title, detail, href, tone }: { title: string; detail: string; href: string; tone: Tone }) {
  return (
    <Link href={href} className={`block rounded-2xl border p-3 text-sm shadow-sm transition hover:-translate-y-0.5 hover:shadow-md ${toneClass(tone)}`}>
      <p className="text-[11px] font-bold uppercase tracking-wide opacity-70">{title}</p>
      <p className="mt-1 text-xs leading-5 opacity-90">{detail}</p>
    </Link>
  );
}

function pageHref(base: string, params: Record<string, string | number | undefined>) {
  const qp = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === "") continue;
    qp.set(key, String(value));
  }
  const query = qp.toString();
  return query ? `${base}?${query}` : base;
}

function SelectableInput({ row }: { row: Row }) {
  const group = text(row.selection_group);
  if (!bool(row.selectable) || !text(row.source_id)) return <span className="text-xs text-slate-400">—</span>;
  if (group === "customer_sales") {
    return <input type="checkbox" name="sales_invoice_id" value={text(row.source_id)} defaultChecked className="h-4 w-4 rounded border-slate-300" />;
  }
  if (group === "supplier_goods_ap") {
    return <input type="checkbox" name="supplier_invoice_id" value={text(row.source_id)} defaultChecked className="h-4 w-4 rounded border-slate-300" />;
  }
  if (group === "shipper_ap") {
    return <input type="checkbox" name="shipping_document_id" value={text(row.source_id)} defaultChecked className="h-4 w-4 rounded border-slate-300" />;
  }
  return <span className="text-xs text-slate-400">—</span>;
}

function ControlStateCluster({ row }: { row: Row }) {
  return (
    <div className="grid max-w-[245px] grid-cols-2 gap-1">
      <CompactState label="Map" value={row.mapping_state} />
      <CompactState label="Pay" value={row.payload_state} />
      <CompactState label="Frz" value={row.freeze_state} />
      <CompactState label="Rev" value={row.revalidation_state} />
      <CompactState label="Gate" value={row.posting_gate} />
      <CompactState label="Sage" value={row.sage_status} />
      {text(row.blocker) ? <p className="col-span-2 truncate text-[11px] font-semibold leading-4 text-rose-700" title={text(row.blocker)}>{short(row.blocker, 90)}</p> : null}
    </div>
  );
}

export default async function AccountingCommandCentrePage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const qp = searchParams ? await Promise.resolve(searchParams) : {};
  const queue = firstParam(qp.queue) || "actionable";
  const lane = firstParam(qp.lane) || "all";
  const postingGate = firstParam(qp.posting_gate) || "all";
  const search = firstParam(qp.q);
  const pageSize = Math.min(Math.max(Number(firstParam(qp.page_size) || 50), 10), 200);
  const page = Math.max(Number(firstParam(qp.page) || 1), 1);
  const offset = (page - 1) * pageSize;

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: staff } = await supabase
    .from("staff")
    .select("id, full_name, role_type, permissions_json")
    .eq("auth_user_id", user.id)
    .eq("active", true)
    .maybeSingle();

  if (!staff) redirect("/auth/check");

  const canAccess = text(staff.role_type) === "admin" || accessFromPermissions((staff as Row).permissions_json);
  if (!canAccess) {
    return (
      <main className="min-h-screen bg-slate-50 px-4 py-6 text-slate-950 sm:px-6 lg:px-8">
        <div className="mx-auto max-w-4xl space-y-5">
          <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
            <h1 className="mt-5 text-3xl font-bold tracking-tight">Accounting Command Centre</h1>
            <p className="mt-3 text-sm leading-6 text-slate-600">This page is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
          </section>
          <section className="rounded-3xl border border-amber-200 bg-amber-50 p-5 text-sm leading-6 text-amber-900">
            <h2 className="font-bold">Access required</h2>
            <p className="mt-2">For testing, keep the user as supervisor and grant the narrow <code>accounting_admin_testing</code> flag in <code>staff.permissions_json</code>. Do not change their primary role away from supervisor just to access this page.</p>
          </section>
        </div>
      </main>
    );
  }

  const { data, error } = await (supabase as any).rpc("internal_accounting_command_centre_grid_v1", {
    p_queue: queue,
    p_lane: lane,
    p_posting_gate: postingGate,
    p_search: search || null,
    p_limit: pageSize,
    p_offset: offset,
  });

  const rows = ((data ?? []) as Row[]);
  const summary = asObject(rows[0]?.summary_counts);
  const totalCount = rows.length > 0 ? Number(rows[0].total_count ?? 0) : 0;
  const hasPrev = page > 1;
  const hasNext = offset + rows.length < totalCount;
  const selectedValue = rows.filter((row) => bool(row.selectable)).reduce((sum, row) => sum + num(row.amount_gbp), 0);
  const selectedCount = rows.filter((row) => bool(row.selectable)).length;

  const baseParams = {
    queue,
    lane,
    posting_gate: postingGate,
    q: search || undefined,
    page_size: pageSize,
  };

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1600px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal" className="text-sm font-semibold text-sky-700">← Internal dashboard</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Accounting cockpit</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Accounting Command Centre</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
                Single v5 accounting/Sage cockpit from approved facts to frozen/revalidated Sage-ready work. Daily accounting work starts here; legacy live-ready, mapping and posting-preview pages are drill-down diagnostics, not separate command centres.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">Accounting owns freeze, revalidation and posting readiness</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Operational blockers route back to Supervisor/child pages</span>
            <span className="rounded-full border border-amber-200 bg-amber-50 px-3 py-1 text-amber-900">Actual Sage posting is still not built</span>
          </div>
          {firstParam(qp.success) ? <p className="mt-4 rounded-2xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900">{firstParam(qp.success)}</p> : null}
          {firstParam(qp.error) ? <p className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-900">{firstParam(qp.error)}</p> : null}
          {error ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Grid RPC unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
        </section>

        <SageConnectionPanel />
        <PostingBatchHistoryPanel />

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
          <SectionLink title="Live ready" detail="Rows ready to freeze; replaces daily /sage-ready usage" href="/internal/accounting-command-centre?queue=live_ready_not_frozen" tone="action" />
          <SectionLink title="Frozen snapshots" detail="Frozen/revalidation rows; preview is drill-down" href="/internal/accounting-command-centre?queue=frozen_ready_to_post" tone="complete" />
          <SectionLink title="Posting batches" detail="Create no-Sage-call batches from ready snapshots" href="/internal/accounting-command-centre?queue=frozen_ready_to_post&posting_gate=ready_to_post" tone="review" />
          <SectionLink title="Sage settings" detail="Connection/settings panel lives above; legacy mapping remains diagnostic" href="/internal/sage-mapping" tone={num(summary.blocked_before_posting) > 0 ? "review" : "muted"} />
          <SectionLink title="Failures/results" detail="Failed and posted filters live here" href="/internal/accounting-command-centre?queue=posting_failed" tone="blocked" />
          <SectionLink title="Corrections/reversals" detail="Not built yet; stays here later" href="/internal/accounting-command-centre" tone="muted" />
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-8">
          <SummaryCard label="Live ready" value={String(summary.live_ready_not_frozen ?? 0)} detail="Not frozen" tone={num(summary.live_ready_not_frozen) > 0 ? "action" : "complete"} />
          <SummaryCard label="Ready to post" value={String(summary.frozen_ready_to_post ?? 0)} detail={gbp(summary.total_ready_value)} tone={num(summary.frozen_ready_to_post) > 0 ? "complete" : "muted"} />
          <SummaryCard label="Revalidate" value={String(summary.requires_revalidation ?? 0)} detail="Frozen stale check" tone={num(summary.requires_revalidation) > 0 ? "action" : "complete"} />
          <SummaryCard label="Blocked" value={String(summary.blocked_before_posting ?? 0)} detail="Must not post" tone={num(summary.blocked_before_posting) > 0 ? "blocked" : "complete"} />
          <SummaryCard label="Failed" value={String(summary.posting_failed ?? 0)} detail="Retry later only" tone={num(summary.posting_failed) > 0 ? "blocked" : "complete"} />
          <SummaryCard label="Posted" value={String(summary.posted ?? 0)} detail="Recorded history" tone={num(summary.posted) > 0 ? "complete" : "muted"} />
          <SummaryCard label="Selectable" value={String(summary.selectable ?? selectedCount)} detail="Visible clean rows" tone={selectedCount > 0 ? "action" : "muted"} />
          <SummaryCard label="Visible selected" value={gbp(selectedValue)} detail={`${selectedCount} visible row(s)`} tone={selectedCount > 0 ? "review" : "muted"} />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/accounting-command-centre" className="grid gap-3 md:grid-cols-2 xl:grid-cols-[minmax(220px,1fr)_170px_150px_170px_120px_auto] xl:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500 md:col-span-2 xl:col-span-1">
              Search
              <input name="q" defaultValue={search} placeholder="Order, source, counterparty, batch, idempotency" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Queue
              <select name="queue" defaultValue={queue} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="actionable">Actionable</option>
                <option value="live_ready_not_frozen">Live ready not frozen</option>
                <option value="frozen_ready_to_post">Frozen ready to post</option>
                <option value="requires_revalidation">Requires revalidation</option>
                <option value="blocked_before_posting">Blocked</option>
                <option value="posting_failed">Posting failed</option>
                <option value="posted">Posted</option>
                <option value="all">All documents</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Lane
              <select name="lane" defaultValue={lane} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All lanes</option>
                <option value="customer_sales">Customer sales</option>
                <option value="supplier_goods_ap">Supplier goods AP</option>
                <option value="shipper_ap">Shipper AP</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Posting gate
              <select name="posting_gate" defaultValue={postingGate} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All gates</option>
                <option value="ready_to_freeze">Ready to freeze</option>
                <option value="ready_to_post">Ready to post</option>
                <option value="requires_revalidation">Requires revalidation</option>
                <option value="blocked_before_posting">Blocked before posting</option>
                <option value="posted">Posted</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Page size
              <select name="page_size" defaultValue={String(pageSize)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="25">25</option>
                <option value="50">50</option>
                <option value="100">100</option>
                <option value="200">200</option>
              </select>
            </label>
            <div className="flex gap-2">
              <button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-semibold text-white">Apply</button>
              <Link href="/internal/accounting-command-centre" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Reset</Link>
            </div>
          </form>
        </section>

        <form className="rounded-3xl border border-slate-200 bg-white shadow-sm" action={freezeSelectedCustomerSalesRowsAction}>
          <input type="hidden" name="bulk_queue" value={queue} />
          <input type="hidden" name="bulk_lane" value={lane} />
          <input type="hidden" name="bulk_posting_gate" value={postingGate} />
          <input type="hidden" name="bulk_q" value={search} />
          <input type="hidden" name="bulk_page_size" value={String(pageSize)} />

          <div className="border-b border-slate-100 px-4 py-3">
            <div className="flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between">
              <div>
                <h2 className="text-xl font-semibold">Accounting workbench grid</h2>
                <p className="mt-1 text-sm text-slate-500">Showing {rows.length} of {totalCount} matching row(s). Operate from this grid; legacy pages are diagnostics.</p>
              </div>
              <label className="flex w-fit items-center gap-2 rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-xs font-semibold text-slate-700">
                <input type="checkbox" name="bulk_include_warnings" value="true" />
                Include warnings in all-matching actions
              </label>
            </div>
            <div className="mt-3 flex flex-wrap gap-2">
              <button formAction={freezeSelectedCustomerSalesRowsAction} className="rounded-lg bg-amber-700 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-800" type="submit">Freeze visible customer sales</button>
              <button formAction={freezeMatchingCustomerSalesRowsAction} className="rounded-lg bg-amber-900 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-950" type="submit">Freeze all matching customer sales</button>
              <button formAction={freezeSelectedSupplierGoodsApRowsAction} className="rounded-lg bg-amber-700 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-800" type="submit">Freeze visible supplier goods AP</button>
              <button formAction={freezeMatchingSupplierGoodsApRowsAction} className="rounded-lg bg-amber-900 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-950" type="submit">Freeze all matching supplier goods AP</button>
              <button formAction={freezeSelectedShipperApRowsAction} className="rounded-lg bg-amber-700 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-800" type="submit">Freeze visible shipper AP</button>
              <button formAction={freezeMatchingShipperApRowsAction} className="rounded-lg bg-amber-900 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-amber-950" type="submit">Freeze all matching shipper AP</button>
              <button formAction={revalidateMatchingFrozenRowsAction} className="rounded-lg bg-violet-700 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-violet-800" type="submit">Revalidate matching frozen</button>
              <button formAction={createPostingBatchFromMatchingRowsAction} className="rounded-lg bg-slate-950 px-3 py-1.5 text-[11px] font-bold text-white hover:bg-slate-800" type="submit">Create posting batch — no Sage call</button>
              <Link href="/internal/accounting-command-centre/posting-preview" className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-center text-[11px] font-bold text-slate-800 hover:bg-slate-50">Frozen snapshot drill-down</Link>
            </div>
          </div>

          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1040px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[46px]" />
                <col className="w-[122px]" />
                <col className="w-[126px]" />
                <col className="w-[160px]" />
                <col className="w-[166px]" />
                <col className="w-[82px]" />
                <col className="w-[242px]" />
                <col className="w-[96px]" />
              </colgroup>
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 text-left">Select</th>
                  <th className="px-2 py-2 text-left">Queue</th>
                  <th className="px-2 py-2 text-left">Lane / doc</th>
                  <th className="px-2 py-2 text-left">Source / ref</th>
                  <th className="px-2 py-2 text-left">Counterparty</th>
                  <th className="px-2 py-2 text-right">Amount</th>
                  <th className="px-2 py-2 text-left">Control states</th>
                  <th className="px-2 py-2 text-left">Action</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? (
                  <tr><td colSpan={8} className="px-3 py-8 text-center text-sm text-slate-500">No accounting rows match this filter.</td></tr>
                ) : rows.map((row) => (
                  <tr key={text(row.queue_row_id) || text(row.snapshot_id)} className="group align-middle hover:bg-slate-50">
                    <td className="px-2 py-2 align-middle"><SelectableInput row={row} /></td>
                    <td className="px-2 py-2 align-middle"><Pill value={row.work_queue} /></td>
                    <td className="px-2 py-2 align-middle"><p className="truncate font-bold text-slate-950">{pretty(row.document_lane)}</p><p className="mt-0.5 truncate text-[11px] leading-4 text-slate-500">{pretty(row.document_type)}</p></td>
                    <td className="px-2 py-2 align-middle"><p className="truncate font-mono text-[11px] font-bold text-slate-950">{text(row.order_ref) || text(row.reference_text) || short(row.source_id, 24)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{text(row.source_table)} · {short(row.source_id, 22)}</p></td>
                    <td className="px-2 py-2 align-middle"><p className="truncate font-semibold text-slate-900">{text(row.counterparty_name) || "—"}</p><p className="mt-0.5 truncate text-[11px] text-slate-500">{bookingText(row.booking_ref)}</p></td>
                    <td className="px-2 py-2 text-right align-middle font-bold text-slate-950">{gbp(row.amount_gbp)}<p className="text-[11px] font-normal text-slate-500">{text(row.currency_code) || "GBP"}</p></td>
                    <td className="px-2 py-2 align-middle"><ControlStateCluster row={row} /></td>
                    <td className="px-2 py-2 align-middle"><Link href={text(row.next_action_href) || "/internal/accounting-command-centre"} title={actionTitle(row)} className="inline-flex max-w-[86px] rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-[11px] font-bold leading-4 text-slate-800 hover:bg-slate-100">{short(actionLabel(row), 24)}</Link></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <div className="flex flex-col gap-3 border-t border-slate-100 px-4 py-3 text-sm text-slate-600 lg:flex-row lg:items-center lg:justify-between">
            <p>Page {page} · {rows.length} visible · {totalCount} matching</p>
            <div className="flex gap-2">
              {hasPrev ? <Link href={pageHref("/internal/accounting-command-centre", { ...baseParams, page: page - 1 })} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Previous</Link> : <span className="rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-400">Previous</span>}
              {hasNext ? <Link href={pageHref("/internal/accounting-command-centre", { ...baseParams, page: page + 1 })} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Next</Link> : <span className="rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-400">Next</span>}
            </div>
          </div>
        </form>

        <section className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900">
          <h2 className="font-bold">v5 control rule</h2>
          <p className="mt-2">This page is the single accounting/Sage cockpit. Frozen snapshot preview, Sage mapping and legacy live-ready routes remain drill-down diagnostics only. Operational exception resolution, shipper receipt approval, DVA investigation and invoice OCR correction stay outside this page. Actual Sage posting is still not built.</p>
          <p className="mt-2 font-semibold">Bulk mode distinguishes selected visible rows from all matching current filter. Posting batches created here make no Sage call and remain disabled until Sage OAuth and dry-run validation are proven.</p>
        </section>
      </div>
    </main>
  );
}
