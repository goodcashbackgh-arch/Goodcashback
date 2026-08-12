import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/utils/supabase/server";

type Row = Record<string, unknown>;
type SearchParamsValue = Record<string, string | string[] | undefined>;

const gbpFormatter = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
  minimumFractionDigits: 2,
});

const allowedLanes = new Set([
  "all",
  "customer_sales",
  "supplier_goods_ap",
  "supplier_credit_note",
  "shipper_ap",
  "mixed",
]);

const allowedStatuses = new Set([
  "all",
  "draft",
  "validated",
  "posted",
  "cancelled_or_superseded",
]);

const allowedPageSizes = new Set([20, 50, 100]);

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

function pretty(value: unknown) {
  const raw = text(value);
  return raw ? raw.replaceAll("_", " ") : "—";
}

function statusTone(status: unknown) {
  const raw = text(status);
  if (["draft", "validated", "posted"].includes(raw)) return "border-emerald-200 bg-emerald-50 text-emerald-900";
  if (raw === "cancelled") return "border-violet-200 bg-violet-50 text-violet-900";
  return "border-slate-200 bg-slate-50 text-slate-700";
}

function auditHref(params: Record<string, string | number | undefined>) {
  const qp = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === "") continue;
    qp.set(key, String(value));
  }
  const query = qp.toString();
  return query ? `/internal/accounting-command-centre/batch-history?${query}` : "/internal/accounting-command-centre/batch-history";
}

export default async function PostingBatchHistoryPage({
  searchParams,
}: {
  searchParams?: SearchParamsValue | Promise<SearchParamsValue>;
}) {
  const qp = searchParams ? await Promise.resolve(searchParams) : {};

  const requestedLane = firstParam(qp.lane) || "all";
  const requestedStatus = firstParam(qp.status) || "all";
  const requestedPageSize = Number(firstParam(qp.page_size) || 20);
  const requestedPage = Number(firstParam(qp.page) || 1);

  const lane = allowedLanes.has(requestedLane) ? requestedLane : "all";
  const status = allowedStatuses.has(requestedStatus) ? requestedStatus : "all";
  const pageSize = allowedPageSizes.has(requestedPageSize) ? requestedPageSize : 20;
  const page = Number.isInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1;
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
        <div className="mx-auto max-w-4xl rounded-3xl border border-amber-200 bg-amber-50 p-6 text-amber-900 shadow-sm">
          <Link href="/internal/accounting-command-centre" className="text-sm font-semibold text-sky-700">← Accounting Command Centre</Link>
          <h1 className="mt-5 text-3xl font-bold tracking-tight">Posting batch history access required</h1>
          <p className="mt-3 text-sm leading-6">This audit is admin-accounting controlled. Your current staff role is {pretty(staff.role_type)}.</p>
        </div>
      </main>
    );
  }

  const { data, error } = await (supabase as any).rpc("internal_sage_posting_batch_audit_v1", {
    p_lane: lane,
    p_status: status,
    p_limit: pageSize,
    p_offset: offset,
  });

  const rows = ((data ?? []) as Row[]);
  const totalCount = rows.length > 0 ? Number(rows[0].total_count ?? 0) : 0;
  const totalPages = totalCount > 0 ? Math.ceil(totalCount / pageSize) : 1;
  const showingFrom = rows.length > 0 ? offset + 1 : 0;
  const showingTo = rows.length > 0 ? offset + rows.length : 0;
  const hasPrev = page > 1;
  const hasNext = offset + rows.length < totalCount;

  return (
    <main className="min-h-screen bg-slate-50 px-4 py-5 text-slate-950 sm:px-6 lg:px-8">
      <div className="mx-auto max-w-[1500px] space-y-4">
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
          <div className="flex flex-wrap items-center gap-4 text-sm font-semibold">
            <Link href="/internal/accounting-command-centre" className="text-sky-700">← Accounting Command Centre</Link>
            <Link href="/internal" className="text-sky-700">Internal dashboard</Link>
          </div>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.2em] text-violet-500">Posting batch audit</p>
          <h1 className="mt-1 text-3xl font-semibold tracking-tight sm:text-4xl">Posting Batch History</h1>
          <p className="mt-2 text-sm leading-6 text-slate-600">Read-only history of accounting posting batches.</p>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          <form action="/internal/accounting-command-centre/batch-history" className="grid gap-3 md:grid-cols-2 xl:grid-cols-[220px_220px_140px_auto] xl:items-end">
            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Lane
              <select name="lane" defaultValue={lane} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All lanes</option>
                <option value="customer_sales">Customer sales</option>
                <option value="supplier_goods_ap">Supplier AP</option>
                <option value="supplier_credit_note">Supplier credit note</option>
                <option value="shipper_ap">Shipper AP</option>
                <option value="mixed">Mixed</option>
              </select>
            </label>

            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Status
              <select name="status" defaultValue={status} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="all">All statuses</option>
                <option value="draft">Draft</option>
                <option value="validated">Validated</option>
                <option value="posted">Posted</option>
                <option value="cancelled_or_superseded">Cancelled / superseded</option>
              </select>
            </label>

            <label className="grid gap-1 text-xs font-bold uppercase tracking-wide text-slate-500">
              Rows
              <select name="page_size" defaultValue={String(pageSize)} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-slate-950">
                <option value="20">20</option>
                <option value="50">50</option>
                <option value="100">100</option>
              </select>
            </label>

            <div className="flex flex-wrap gap-2">
              <button type="submit" className="rounded-xl bg-slate-950 px-4 py-2 text-sm font-bold text-white">Apply</button>
              <Link href="/internal/accounting-command-centre/batch-history" className="rounded-xl border border-slate-300 bg-white px-4 py-2 text-sm font-bold text-slate-800 hover:bg-slate-50">Reset</Link>
            </div>
          </form>
        </section>

        <section className="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm">
          {error ? <p className="mb-3 rounded-2xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-900">Posting batch history unavailable: {error.message}</p> : null}

          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-sm text-slate-600">Showing {showingFrom}–{showingTo} of {totalCount}</p>
            <p className="text-sm font-semibold text-slate-700">Page {page} of {totalPages}</p>
          </div>

          <div className="mt-3 overflow-x-auto">
            <table className="min-w-[900px] table-fixed divide-y divide-slate-200 text-xs">
              <colgroup>
                <col className="w-[180px]" />
                <col className="w-[100px]" />
                <col className="w-[130px]" />
                <col className="w-[110px]" />
                <col className="w-[90px]" />
                <col className="w-[90px]" />
                <col className="w-[190px]" />
                <col className="w-[70px]" />
              </colgroup>
              <thead className="bg-slate-100 text-[10px] uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 text-left">Batch</th>
                  <th className="px-2 py-2 text-left">Status</th>
                  <th className="px-2 py-2 text-left">Lane</th>
                  <th className="px-2 py-2 text-right">Value</th>
                  <th className="px-2 py-2 text-right">Included</th>
                  <th className="px-2 py-2 text-right">Excluded</th>
                  <th className="px-2 py-2 text-left">Created</th>
                  <th className="px-2 py-2 text-left">Action</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 bg-white">
                {!error && rows.length === 0 ? (
                  <tr><td colSpan={8} className="px-3 py-6 text-center text-sm text-slate-500">No posting batches match these filters.</td></tr>
                ) : rows.map((row) => {
                  const href = `/internal/accounting-command-centre/batches/${text(row.batch_id)}`;
                  return (
                    <tr key={text(row.batch_id)} className="hover:bg-slate-50">
                      <td className="px-2 py-2">
                        <Link href={href} className="truncate font-mono text-[11px] font-bold text-sky-700 underline">{text(row.batch_ref)}</Link>
                        <p className="truncate text-[10px] text-slate-500">{pretty(row.batch_kind)}</p>
                      </td>
                      <td className="px-2 py-2"><span className={`inline-flex rounded-full border px-2 py-0.5 text-[10px] font-bold ${statusTone(row.status)}`}>{pretty(row.status)}</span></td>
                      <td className="px-2 py-2 font-bold text-slate-800">{pretty(row.lane)}</td>
                      <td className="px-2 py-2 text-right font-bold text-slate-950">{gbpFormatter.format(num(row.total_amount_gbp))}</td>
                      <td className="px-2 py-2 text-right font-bold text-emerald-800">{text(row.included_count) || "0"}</td>
                      <td className="px-2 py-2 text-right font-bold text-amber-800">{text(row.excluded_count) || "0"}</td>
                      <td className="px-2 py-2"><p className="truncate text-slate-700">{text(row.created_at)}</p><p className="truncate text-[10px] text-slate-500">{text(row.created_by_name)}</p></td>
                      <td className="px-2 py-2"><Link href={href} className="rounded-lg border border-slate-300 bg-white px-2 py-1 text-[11px] font-bold text-slate-800 hover:bg-slate-50">Open</Link></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <div className="mt-4 flex items-center justify-between gap-3">
            {hasPrev ? (
              <Link href={auditHref({ lane, status, page_size: pageSize, page: page - 1 })} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-bold text-slate-800 hover:bg-slate-50">Previous</Link>
            ) : <span />}
            {hasNext ? (
              <Link href={auditHref({ lane, status, page_size: pageSize, page: page + 1 })} className="rounded-xl border border-slate-300 bg-white px-3 py-2 text-sm font-bold text-slate-800 hover:bg-slate-50">Next</Link>
            ) : <span />}
          </div>
        </section>
      </div>
    </main>
  );
}
