import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

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

function asObject(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return value as Row;
}

function accessFromPermissions(value: unknown) {
  const permissions = asObject(value);
  return bool(permissions.accounting_admin_testing) || bool(permissions.admin_testing);
}

function gbp(value: unknown) {
  return gbpFormatter.format(num(value));
}

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function short(value: unknown, max = 42) {
  const raw = text(value);
  if (!raw) return "—";
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw;
}

function toneClass(tone: Tone) {
  if (tone === "complete") return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (tone === "action") return "border-amber-200 bg-amber-50 text-amber-900";
  if (tone === "blocked") return "border-rose-200 bg-rose-50 text-rose-900";
  if (tone === "review") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function stateTone(value: unknown): Tone {
  const raw = text(value);
  if (["posted_closed", "posted"].includes(raw)) return "complete";
  if (["ready_for_posting", "ready_to_posting"].includes(raw)) return "action";
  if (["failed", "duplicate_risk", "correction_required", "blocked"].includes(raw)) return "blocked";
  if (["posted_not_closed", "posted_needs_review"].includes(raw)) return "review";
  return "muted";
}

function Pill({ value }: { value: unknown }) {
  return <span className={`inline-flex max-w-[150px] truncate rounded-full border px-2 py-0.5 text-[10px] font-bold leading-4 ${toneClass(stateTone(value))}`}>{pretty(value)}</span>;
}

function MiniState({ label, value }: { label: string; value: unknown }) {
  return (
    <span className={`inline-flex min-w-0 items-center gap-1 rounded-md border px-1.5 py-0.5 text-[10px] leading-4 ${toneClass(stateTone(value))}`} title={`${label}: ${pretty(value)}`}>
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

function filterHref(params: Record<string, string | number | undefined>) {
  const qp = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === "") continue;
    qp.set(key, String(value));
  }
  const query = qp.toString();
  return query ? `/internal/accounting-command-centre/closure?${query}` : "/internal/accounting-command-centre/closure";
}

function traceActionHref(row: Row) {
  const trace = asObject(row.trace_json);
  return text(trace.action_href);
}

function traceAuditNote(row: Row) {
  const trace = asObject(row.trace_json);
  return text(trace.audit_note);
}

function TraceDetails({ row }: { row: Row }) {
  const trace = asObject(row.trace_json);
  const href = text(trace.action_href);
  const json = JSON.stringify(trace, null, 2);
  return (
    <div className="mt-2 space-y-2">
      {href ? (
        <Link href={href} className="inline-flex rounded-lg border border-slate-300 bg-white px-2 py-1.5 text-[11px] font-bold text-slate-800 hover:bg-slate-100">
          Open detail
        </Link>
      ) : null}
      <details className="rounded-xl border border-slate-200 bg-slate-50 p-2">
        <summary className="cursor-pointer text-[11px] font-bold text-slate-700">Posting trace</summary>
        <pre className="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-lg bg-white p-2 text-[10px] leading-4 text-slate-700">{json}</pre>
      </details>
    </div>
  );
}

export default async function AccountingClosurePage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const qp = searchParams ? await Promise.resolve(searchParams) : {};
  const lane = firstParam(qp.lane) || "all";
  const state = firstParam(qp.state) || "all";
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
        <div className="mx-auto max-w-4xl rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
          <h1 className="mt-5 text-3xl font-bold tracking-tight">Accounting Closure Control</h1>
          <p className="mt-3 text-sm leading-6 text-slate-600">This page is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
        </div>
      </main>
    );
  }

  const { data, error } = await (supabase as any).rpc("internal_accounting_closure_control_rows_v2", {
    p_lane: lane,
    p_state: state,
    p_search: search || null,
    p_limit: pageSize,
    p_offset: offset,
  });

  const rows = ((data ?? []) as Row[]);
  const totalCount = rows.length > 0 ? Number(rows[0].total_count ?? 0) : 0;
  const hasPrev = page > 1;
  const hasNext = offset + rows.length < totalCount;
  const counts = rows.reduce<Record<string, number>>((acc, row) => {
    const key = text(row.closure_state) || "unknown";
    acc[key] = (acc[key] ?? 0) + 1;
    return acc;
  }, {});
  const visibleValue = rows.reduce((sum, row) => sum + num(row.source_amount_gbp), 0);

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1700px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
          <p className="mt-5 text-sm font-medium uppercase tracking-[0.2em] text-violet-500">Read-only closure gate</p>
          <div className="mt-2 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">Accounting Closure Control</h1>
              <p className="mt-2 max-w-5xl text-sm leading-6 text-slate-600">
                Posted is not closed. This read-only view compares frozen platform facts, batch rows, Sage object ids, contact payments, allocation status, duplicate/idempotency risk and blockers before any further endpoint expansion.
              </p>
            </div>
            <div className="rounded-2xl bg-slate-100 px-4 py-3 text-sm text-slate-700">
              <div className="font-medium text-slate-950">{text(staff.full_name)}</div>
              <div>{text(staff.role_type)}{accessFromPermissions((staff as Row).permissions_json) ? " · accounting admin testing" : ""}</div>
            </div>
          </div>
          <div className="mt-4 flex flex-wrap gap-2 text-xs font-semibold">
            <span className="rounded-full border border-violet-200 bg-violet-50 px-3 py-1 text-violet-900">Contract: ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1</span>
            <span className="rounded-full border border-amber-200 bg-amber-50 px-3 py-1 text-amber-900">No posting actions on this page</span>
            <span className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1 text-slate-700">Current lane: {pretty(lane)}</span>
          </div>
          {error ? <p className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Closure RPC unavailable: {error.message}. Run the latest Supabase migration before testing this page.</p> : null}
        </section>

        <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-8">
          <SummaryCard label="Visible rows" value={String(rows.length)} detail={`${totalCount} matching`} tone="muted" />
          <SummaryCard label="Visible value" value={gbp(visibleValue)} detail="Source amount shown" tone="muted" />
          <SummaryCard label="Closed" value={String(counts.posted_closed ?? 0)} detail="Posted + closure proven" tone="complete" />
          <SummaryCard label="Not closed" value={String(counts.posted_not_closed ?? 0)} detail="Posted but open" tone="review" />
          <SummaryCard label="Needs review" value={String(counts.posted_needs_review ?? 0)} detail="Artefact/status issue" tone="review" />
          <SummaryCard label="Duplicate risk" value={String(counts.duplicate_risk ?? 0)} detail="Idempotency warning" tone="blocked" />
          <SummaryCard label="Failed" value={String(counts.failed ?? 0)} detail="Posting failed" tone="blocked" />
          <SummaryCard label="Ready" value={String(counts.ready_for_posting ?? 0)} detail="Awaiting post" tone="action" />
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/accounting-command-centre/closure" className="grid gap-3 md:grid-cols-2 xl:grid-cols-[minmax(240px,1fr)_220px_220px_120px_auto] xl:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500 md:col-span-2 xl:col-span-1">
              Search
              <input name="q" defaultValue={search} placeholder="Order, batch, Sage id, reference, idempotency" className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950" />
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Lane
              <select name="lane" defaultValue={lane} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All lanes</option>
                <option value="customer_sales">Customer sales</option>
                <option value="supplier_goods_ap">Supplier goods AP</option>
                <option value="shipper_ap">Shipper AP</option>
                <option value="supplier_credit_note">Supplier credit note</option>
                <option value="customer_receipt_on_account">Customer receipt on account</option>
                <option value="supplier_invoice_payment">Supplier invoice payment</option>
                <option value="shipper_invoice_payment">Shipper invoice payment</option>
              </select>
            </label>
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Closure state
              <select name="state" defaultValue={state} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All states</option>
                <option value="posted_not_closed">Posted not closed</option>
                <option value="posted_closed">Posted closed</option>
                <option value="posted_needs_review">Posted needs review</option>
                <option value="duplicate_risk">Duplicate risk</option>
                <option value="failed">Failed</option>
                <option value="ready_for_posting">Ready for posting</option>
                <option value="blocked">Blocked</option>
                <option value="not_reached">Not reached</option>
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
              <Link href="/internal/accounting-command-centre/closure" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Reset</Link>
            </div>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-100 px-4 py-3">
            <h2 className="text-xl font-semibold">Closure grid</h2>
            <p className="mt-1 text-sm text-slate-500">Showing {rows.length} visible row(s) from {totalCount} matching row(s). This page is read-only by contract.</p>
          </div>
          <div className="overflow-x-auto rounded-b-3xl">
            <table className="min-w-[1280px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[140px]" />
                <col className="w-[125px]" />
                <col className="w-[170px]" />
                <col className="w-[120px]" />
                <col className="w-[175px]" />
                <col className="w-[170px]" />
                <col className="w-[155px]" />
                <col className="w-[300px]" />
              </colgroup>
              <thead className="sticky top-0 z-10 bg-slate-100 text-[11px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 text-left">State</th>
                  <th className="px-2 py-2 text-left">Lane</th>
                  <th className="px-2 py-2 text-left">Source</th>
                  <th className="px-2 py-2 text-right">Amount</th>
                  <th className="px-2 py-2 text-left">Sage object</th>
                  <th className="px-2 py-2 text-left">Batch / posted</th>
                  <th className="px-2 py-2 text-left">Allocation</th>
                  <th className="px-2 py-2 text-left">Why not closed / action / trace</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {rows.length === 0 ? (
                  <tr><td colSpan={8} className="px-3 py-8 text-center text-sm text-slate-500">No closure rows match this filter.</td></tr>
                ) : rows.map((row) => (
                  <tr key={text(row.closure_row_id)} className="align-top hover:bg-slate-50">
                    <td className="px-2 py-2"><Pill value={row.closure_state} />{text(row.duplicate_warning) ? <p className="mt-1 text-[11px] font-semibold text-rose-700">{short(row.duplicate_warning, 80)}</p> : null}</td>
                    <td className="px-2 py-2"><p className="font-bold text-slate-950">{pretty(row.closure_lane)}</p><p className="mt-0.5 text-[11px] text-slate-500">{short(row.platform_source_table, 26)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-mono text-[11px] font-bold text-slate-950" title={text(row.source_document_ref)}>{short(row.source_document_ref, 32)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500" title={text(row.platform_source_id)}>{text(row.order_ref) || short(row.platform_source_id, 22)}</p></td>
                    <td className="px-2 py-2 text-right font-bold text-slate-950">{gbp(row.source_amount_gbp)}</td>
                    <td className="px-2 py-2"><p className="font-semibold text-slate-900">{pretty(row.sage_object_type)}</p><p className="mt-0.5 truncate font-mono text-[11px] text-slate-500" title={text(row.sage_object_id)}>{short(row.sage_object_id, 26)}</p><p className="mt-0.5 truncate text-[11px] text-slate-500" title={text(row.sage_reference)}>{short(row.sage_reference, 30)}</p></td>
                    <td className="px-2 py-2"><p className="truncate font-semibold text-slate-900" title={text(row.posting_batch_ref)}>{short(row.posting_batch_ref, 28)}</p><p className="mt-0.5 text-[11px] text-slate-500">{text(row.posted_at) ? new Date(text(row.posted_at)).toLocaleString("en-GB") : "Not posted"}</p></td>
                    <td className="px-2 py-2"><div className="grid gap-1"><MiniState label="Alloc" value={row.cash_or_credit_allocation_status} /><MiniState label="Attach" value={row.attachment_state} /></div><p className="mt-1 truncate font-mono text-[11px] text-slate-500" title={text(row.sage_target_artefact_id)}>{short(row.sage_target_artefact_id, 28)}</p></td>
                    <td className="px-2 py-2">
                      <p className="text-[11px] font-semibold leading-4 text-slate-700" title={text(row.blocker)}>{short(row.blocker || row.next_action, 135)}</p>
                      {text(row.next_action) && text(row.next_action) !== "No action" ? <p className="mt-1 text-[11px] font-bold text-violet-800">Next: {short(row.next_action, 80)}</p> : null}
                      {traceAuditNote(row) ? <p className="mt-1 rounded-lg border border-amber-200 bg-amber-50 px-2 py-1 text-[10px] font-semibold leading-4 text-amber-800">Audit note: {short(traceAuditNote(row), 110)}</p> : null}
                      {!traceActionHref(row) && text(row.posting_batch_id) ? <p className="mt-1 text-[10px] font-semibold text-amber-700">Detail link unavailable because no matching posted batch row was found. Use the posting trace.</p> : null}
                      <TraceDetails row={row} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="flex flex-col gap-3 border-t border-slate-100 px-4 py-3 text-sm text-slate-600 lg:flex-row lg:items-center lg:justify-between">
            <p>Page {page} · {rows.length} visible · {totalCount} matching</p>
            <div className="flex gap-2">
              {hasPrev ? <Link href={filterHref({ lane, state, q: search || undefined, page_size: pageSize, page: page - 1 })} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Previous</Link> : <span className="rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-400">Previous</span>}
              {hasNext ? <Link href={filterHref({ lane, state, q: search || undefined, page_size: pageSize, page: page + 1 })} className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-800">Next</Link> : <span className="rounded-xl border border-slate-200 bg-slate-100 px-4 py-2 text-sm font-semibold text-slate-400">Next</span>}
            </div>
          </div>
        </section>

        <section className="rounded-3xl border border-violet-200 bg-violet-50 p-5 text-sm leading-6 text-violet-900">
          <h2 className="font-bold">Closure gate rule</h2>
          <p className="mt-2">After invoice/cash/credit posting routes are built, ACCOUNTING_CLOSURE_CONTROL_CONTRACT_v1 governs the next build phase before further endpoint expansion.</p>
          <p className="mt-2 font-semibold">Retailer refund IN, customer refund OUT, FX/card residuals, bank fees, holds, customer payment-on-account allocation and manual AP edge cases remain paused until this closure view proves at least one full order lifecycle.</p>
        </section>
      </div>
    </main>
  );
}
